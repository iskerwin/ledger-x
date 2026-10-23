"""IPA source regressions: a source must never be written without the versions GitHub has published."""
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools/release/ipa_source.py'
TAGS = 'aaa\trefs/tags/dev\nbbb\trefs/tags/v1.0.1\nccc\trefs/tags/v1.0.1^{}\n'


def release(tag, body, prerelease=False):
    return {'tag_name': tag, 'draft': False, 'prerelease': prerelease, 'body': body,
            'published_at': '2026-10-22T00:00:00Z', 'created_at': '2026-10-22T00:00:00Z',
            'assets': [{'name': 'Ledger.ipa', 'browser_download_url': f'https://example.invalid/{tag}/Ledger.ipa', 'size': 1,
                        'digest': 'sha256:' + tag.encode().hex().ljust(64, '0')}]}


class IpaSourceTests(unittest.TestCase):
    def run_script(self, releases, out):
        def fake(cmd, *args, **kwargs):
            if cmd[:2] == ['git', 'hash-object']:
                return 'f' * 40
            if cmd[:3] == ['gh', 'api', '--paginate']:
                return json.dumps([releases])
            if cmd[:2] == ['git', 'ls-remote']:
                return TAGS
            raise AssertionError(cmd)
        with patch.object(subprocess, 'check_output', side_effect=fake), patch('time.sleep'), \
                patch.object(sys, 'argv', ['ipa_source.py', 'example/ledger-x', out]):
            runpy.run_path(str(SCRIPT), run_name='__main__')

    def test_an_empty_release_list_writes_nothing(self):
        with tempfile.TemporaryDirectory() as out:
            with self.assertRaises(SystemExit) as stop:
                self.run_script([], out)
            self.assertIn('正式版', str(stop.exception.code))
            self.assertIn('开发版', str(stop.exception.code))
            self.assertEqual(list(Path(out).iterdir()), [])

    def test_releases_without_their_ipa_write_nothing(self):
        bare = [dict(release('dev', '版本 1.0.2 · 构建 11 ·', True), assets=[]), dict(release('v1.0.1', '版本 1.0.1 · 构建 6 ·'), assets=[])]
        with tempfile.TemporaryDirectory() as out:
            with self.assertRaises(SystemExit):
                self.run_script(bare, out)
            self.assertEqual(list(Path(out).iterdir()), [])

    def test_a_short_list_is_read_again_until_complete(self):
        lists = [[], [release('dev', '版本 1.0.2 · 构建 11 ·', True), release('v1.0.1', '版本 1.0.1 · 构建 6 ·')]]
        def fake(cmd, *args, **kwargs):
            if cmd[:2] == ['git', 'hash-object']:
                return 'f' * 40
            if cmd[:3] == ['gh', 'api', '--paginate']:
                return json.dumps([lists.pop(0) if len(lists) > 1 else lists[0]])
            if cmd[:2] == ['git', 'ls-remote']:
                return TAGS
            raise AssertionError(cmd)
        with tempfile.TemporaryDirectory() as out, patch.object(subprocess, 'check_output', side_effect=fake), patch('time.sleep'), \
                patch.object(sys, 'argv', ['ipa_source.py', 'example/ledger-x', out]):
            runpy.run_path(str(SCRIPT), run_name='__main__')
            dev = json.loads((Path(out) / 'dev.json').read_text())
            self.assertEqual([v['buildVersion'] for v in dev['apps'][0]['versions']], ['11', '6'])

    def test_published_versions_are_written(self):
        releases = [release('dev', '版本 1.0.2 · 构建 11 ·', True), release('v1.0.1', '版本 1.0.1 · 构建 6 ·')]
        with tempfile.TemporaryDirectory() as out:
            self.run_script(releases, out)
            dev = json.loads((Path(out) / 'dev.json').read_text())
            versions = [(v['version'], v['buildVersion']) for v in dev['apps'][0]['versions']]
            self.assertEqual(versions, [('1.0.2', '11'), ('1.0.1', '6')])
            release_source = json.loads((Path(out) / 'mirror/release.json').read_text())
            self.assertEqual([v['version'] for v in release_source['apps'][0]['versions']], ['1.0.1'])

    def test_every_version_carries_the_ipa_sha256(self):
        # the installer checks the downloaded package against it, so a proxy (the mirror) cannot swap the IPA unseen
        releases = [release('dev', '版本 1.0.2 · 构建 11 ·', True), release('v1.0.1', '版本 1.0.1 · 构建 6 ·')]
        with tempfile.TemporaryDirectory() as out:
            self.run_script(releases, out)
            for name in ('dev.json', 'release.json', 'mirror/dev.json', 'mirror/release.json'):
                for v in json.loads((Path(out) / name).read_text())['apps'][0]['versions']:
                    tag = 'dev' if v['buildVersion'] == '11' else 'v1.0.1'
                    self.assertEqual(v['sha256'], tag.encode().hex().ljust(64, '0'), name)


if __name__ == '__main__':
    unittest.main()
