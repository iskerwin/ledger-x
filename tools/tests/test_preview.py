"""Preview builds: numbering, publication to the preview prerelease only, and the dev source listing."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import plistlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ship

ROOT = Path(__file__).resolve().parents[2]
DEMO_SHA = ship.content_digest([('main.bean', b'; fictional sample')])


class PreviewNumberTests(unittest.TestCase):
    def test_previews_count_up_after_the_last_dev_and_never_take_its_number(self):
        releases = [dict(tag_name='dev', body='版本 1.0.8 · 构建 41 · main abc')]
        self.assertEqual(ship.preview_build(releases), '41.1')
        self.assertEqual(ship.preview_build(releases, previous='版本 1.0.8 · 构建 41.1 · fix/x'), '41.2')
        # a new dev since the last preview starts the count again
        self.assertEqual(ship.preview_build(releases + [dict(tag_name='preview', body='构建 40.3')],
                                            previous='版本 1.0.8 · 构建 40.3 · fix/x'), '41.1')
        # the next dev still rises past every preview
        self.assertEqual(ship.next_build(releases + [dict(tag_name='preview', body='版本 1.0.8 · 构建 41.2 ·')]), '42')

    def test_failure_report_names_the_preview_not_main(self):
        state = dict(command='preview', effects={})
        self.assertIn('未发布预览包', ship.failure_message(ship.Failure('x'), state=state))
        state = dict(command='preview', effects=dict(preview_release='done', ipa_source='started'))
        message = ship.failure_message(ship.Failure('x'), state=state)
        self.assertIn('预览包：已发布', message)
        self.assertNotIn('main', message)


class PreviewPublishTests(unittest.TestCase):
    def test_preview_builds_publishes_only_the_preview_prerelease_and_updates_sources(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root/'project.yml').write_text('MARKETING_VERSION: "1.0.8"')
            calls = []
            def build(version, number, demo):
                self.assertEqual((version, number), ('1.0.8', '41.1'))
                (root/'dist').mkdir(exist_ok=True)
                with zipfile.ZipFile(root/'dist/Ledger.ipa', 'w') as archive:
                    archive.writestr('Payload/Ledger.app/Info.plist', plistlib.dumps(dict(
                        CFBundleShortVersionString=version, CFBundleVersion=number,
                        CFBundleIdentifier='com.iskerwin.ledger', LedgerDemoCommit='demo')))
                    archive.writestr('Payload/Ledger.app/Demo/main.bean', '; fictional sample')
                    archive.writestr('Payload/Ledger.app/_CodeSignature/CodeResources', 'signature fixture')
                return root/'dist/Ledger.ipa'
            def git(*args):
                return {('rev-parse', 'HEAD'): 'a'*40, ('status', '--porcelain'): ''}.get(args, 'tree')
            with ExitStack() as mocks:
                for mocked in (
                    patch.object(ship, 'ROOT', root), patch.object(ship, 'DIST', root/'dist'),
                    patch.object(ship, 'STATUS', root/'status.json'), patch.object(ship, 'progress', ship.Progress()),
                    patch.object(ship, 'repository', return_value='example/app'), patch.object(ship, 'git', side_effect=git),
                    patch.object(ship, 'validate_development', return_value=dict(validator='github-actions', scope='build',
                        run_url='https://github.com/example/app/actions/runs/5', static_checks=True, tools_tests=True,
                        xcode='Xcode 26.6', demo_commit='demo', demo_sha256=DEMO_SHA)),
                    patch.object(ship, 'fetch_releases', return_value=[dict(tag_name='dev', body='构建 41')]),
                    patch.object(ship, 'out', return_value=''), patch.object(ship, 'listed_builds', return_value=[]),
                    patch.object(ship, 'build_ipa', side_effect=build),
                    patch.object(ship, 'gh_api', return_value=[dict(number=13)]),
                    patch.object(ship, 'release_for_tag', return_value=None),
                    patch.object(ship, 'run', side_effect=lambda cmd, **kw: calls.append([str(c) for c in cmd])),
                    patch.dict(os.environ, dict(GITHUB_REF_NAME='fix/x')), patch('builtins.print'),
                ):
                    mocks.enter_context(mocked)
                sources = mocks.enter_context(patch.object(ship, 'update_sources'))
                ship.progress.begin('preview')
                ship.ship_preview()
                sources.assert_called_once_with('example/app')
            releases = [cmd for cmd in calls if cmd[:2] == ['gh', 'release']]
            self.assertEqual(len(releases), 1)
            self.assertEqual(releases[0][2:4], ['create', 'preview'])
            self.assertIn('--prerelease', releases[0])
            self.assertFalse([cmd for cmd in calls if cmd[:2] == ['git', 'push'] or 'dev' in cmd[2:4]])
            manifest = json.loads((root/'dist/build-manifest.json').read_text())
            self.assertEqual((manifest['channel'], manifest['build'], manifest['branch']), ('preview', '41.1', 'fix/x'))
            notes = (root/'dist/release-notes.md').read_text()
            self.assertIn('版本 1.0.8 · 构建 41.1 · fix/x aaaaaaa · PR #13', notes)
            self.assertIn('不能转正', notes)
            # a preview can never be promoted
            with self.assertRaises(ship.Failure):
                ship.promoted_identity(manifest)


class PreviewSourceTests(unittest.TestCase):
    def release(self, tag, body):
        return {'tag_name': tag, 'draft': False, 'prerelease': tag != 'v1.0.7', 'body': body,
                'published_at': '2026-10-28T00:00:00Z', 'created_at': '2026-10-28T00:00:00Z',
                'assets': [{'name': 'Ledger.ipa', 'browser_download_url': f'https://example.invalid/{tag}/Ledger.ipa', 'size': 1}]}

    def versions(self, releases):
        tags = ''.join(f'x\trefs/tags/{r["tag_name"]}\n' for r in releases)
        def fake(cmd, *args, **kwargs):
            if cmd[:2] == ['git', 'hash-object']:
                return 'f' * 40
            if cmd[:3] == ['gh', 'api', '--paginate']:
                return json.dumps([releases])
            if cmd[:2] == ['git', 'ls-remote']:
                return tags
            raise AssertionError(cmd)
        with tempfile.TemporaryDirectory() as out, patch.object(subprocess, 'check_output', side_effect=fake), \
             patch('time.sleep'), patch.object(sys, 'argv', ['ipa_source.py', 'example/ledger-x', out]):
            runpy.run_path(str(ROOT/'tools/release/ipa_source.py'), run_name='__main__')
            dev = json.loads((Path(out)/'dev.json').read_text())['apps'][0]['versions']
            release = json.loads((Path(out)/'release.json').read_text())['apps'][0]['versions']
        return [v['buildVersion'] for v in dev], [v['buildVersion'] for v in release]

    def test_a_reused_dev_release_is_dated_by_its_package(self):
        dev = self.release('dev', '版本 1.0.8 · 构建 41 ·')
        dev['published_at'] = '2026-10-21T17:58:29Z'
        dev['assets'][0]['updated_at'] = '2026-10-27T23:40:07Z'
        tags = 'x\trefs/tags/dev\n'
        def fake(cmd, *args, **kwargs):
            if cmd[:2] == ['git', 'hash-object']:
                return 'f' * 40
            if cmd[:3] == ['gh', 'api', '--paginate']:
                return json.dumps([[dev]])
            if cmd[:2] == ['git', 'ls-remote']:
                return tags
            raise AssertionError(cmd)
        with tempfile.TemporaryDirectory() as out, patch.object(subprocess, 'check_output', side_effect=fake), \
             patch('time.sleep'), patch.object(sys, 'argv', ['ipa_source.py', 'example/ledger-x', out]):
            runpy.run_path(str(ROOT/'tools/release/ipa_source.py'), run_name='__main__')
            versions = json.loads((Path(out)/'dev.json').read_text())['apps'][0]['versions']
        self.assertEqual(versions[0]['date'], '2026-10-27T23:40:07Z')

    def test_dev_source_lists_the_newest_of_dev_and_preview_first_and_release_ignores_previews(self):
        published = self.release('v1.0.7', '版本 1.0.7 · 构建 30 ·')
        newer = [self.release('dev', '版本 1.0.8 · 构建 41 ·'), self.release('preview', '版本 1.0.8 · 构建 41.2 ·'), published]
        self.assertEqual(self.versions(newer), (['41.2', '41', '30'], ['30']))
        merged = [self.release('preview', '版本 1.0.8 · 构建 41.2 ·'), self.release('dev', '版本 1.0.8 · 构建 42 ·'), published]
        self.assertEqual(self.versions(merged), (['42', '41.2', '30'], ['30']))


class SourceRetryTests(unittest.TestCase):
    def test_a_rejected_source_push_is_regenerated_and_sent_again(self):
        pushes = []
        def command(cmd, **kwargs):
            cmd = [str(c) for c in cmd]
            if cmd[0] == sys.executable:
                site = Path(cmd[-1])
                (site/'mirror').mkdir(parents=True, exist_ok=True)
                for name in ('dev.json', 'release.json', 'mirror/dev.json', 'mirror/release.json'):
                    (site/name).write_text('{}')
            if cmd[:3] == ['git', 'worktree', 'add']:
                Path(cmd[-2]).mkdir(parents=True, exist_ok=True)
            if 'push' in cmd:
                pushes.append(cmd)
                return 1 if len(pushes) == 1 else 0
            return 0
        class Changed:
            returncode = 1
        with tempfile.TemporaryDirectory() as temp, patch.object(ship, 'DIST', Path(temp)), patch.object(ship, 'step'), \
             patch.object(ship, 'remote_has', return_value=True), patch.object(ship, 'run', side_effect=command), \
             patch.object(ship.subprocess, 'run', return_value=Changed()), patch.object(ship, 'progress', ship.Progress()):
            ship.progress.begin('preview')
            ship.update_sources('example/app')
            self.assertEqual(ship.progress.state['effects']['ipa_source'], 'done')
        self.assertEqual(len(pushes), 2)


if __name__ == '__main__':
    unittest.main()
