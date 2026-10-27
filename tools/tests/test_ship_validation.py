"""Validation boundaries, using only fictional files and local temporary repositories."""
from contextlib import ExitStack
import hashlib
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ship


class DemoSnapshotTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.demo = self.root/'.demo-data'
        self.demo.mkdir()
        self.git('init', '-q')
        (self.demo/'main.bean').write_text('; fictional snapshot\n')
        (self.demo/'.gitignore').write_text('ignored/\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Fictional snapshot')
        self.commit = self.git('rev-parse', 'HEAD')
        (self.root/'tools/fixtures').mkdir(parents=True)
        (self.root/'tools/fixtures/manifest.json').write_text(json.dumps({'demoCommit': self.commit}))
        root_patch = patch.object(ship, 'ROOT', self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.demo), *args], text=True).strip()

    def test_demo_rejects_modified_staged_untracked_and_ignored_files_without_overwriting(self):
        for kind in ('modified', 'staged', 'untracked', 'ignored'):
            with self.subTest(kind=kind):
                path = self.demo/('main.bean' if kind in ('modified', 'staged') else
                                  'extra.bean' if kind == 'untracked' else 'ignored/extra.bean')
                path.parent.mkdir(exist_ok=True)
                path.write_text('; fictional local change\n')
                if kind == 'staged':
                    self.git('add', 'main.bean')
                with self.assertRaises(ship.Failure):
                    ship.demo_snapshot()
                self.assertEqual(path.read_text(), '; fictional local change\n')
                if kind in ('modified', 'staged'):
                    self.git('restore', '--staged', '--worktree', 'main.bean')
                else:
                    path.unlink()
                    if kind == 'ignored':
                        path.parent.rmdir()

    def test_clean_demo_selects_the_pinned_commit(self):
        self.assertEqual(ship.demo_snapshot(), self.commit)

    def test_demo_digest_detects_content_change_even_when_git_status_is_unchanged(self):
        digest = ship.verify_demo_snapshot(self.commit)
        self.git('update-index', '--assume-unchanged', 'main.bean')
        (self.demo/'main.bean').write_text('; fictional change hidden from git status')
        self.assertEqual(self.git('status', '--porcelain'), '')
        with self.assertRaises(ship.Failure):
            ship.verify_demo_snapshot(self.commit, digest)

    def test_changed_copy_is_rejected_before_compiling(self):
        original = ship.shutil.copytree
        for change_source in (False, True):
            with self.subTest(change_source=change_source):
                def copy(source, target, **kwargs):
                    original(source, target, **kwargs)
                    changed = source if change_source else target
                    (changed/'main.bean').write_text('; fictional copy-time change')
                (self.root/'Ledger').mkdir(exist_ok=True)
                with patch.object(ship.shutil, 'copytree', side_effect=copy), \
                     patch.object(ship, 'run') as run, patch.object(ship, 'step'):
                    with self.assertRaises(ship.Failure):
                        ship.build_ipa('1.0.0', '1', self.commit)
                    run.assert_not_called()
                self.git('restore', 'main.bean')

    def test_package_demo_contents_must_match_validation_evidence(self):
        folder = self.root/'package'
        folder.mkdir()
        with zipfile.ZipFile(folder/'Ledger.ipa', 'w') as archive:
            archive.writestr('Payload/Ledger.app/Info.plist', plistlib.dumps(dict(
                CFBundleShortVersionString='1.0.0', CFBundleVersion='1',
                CFBundleIdentifier='com.iskerwin.ledger')))
            archive.writestr('Payload/Ledger.app/Demo/main.bean', '; different fictional snapshot')
            archive.writestr('Payload/Ledger.app/_CodeSignature/CodeResources', 'fixture')
        data = (folder/'Ledger.ipa').read_bytes()
        manifest = dict(repository='example/app', source_sha='source', tree='tree',
                        version='1.0.0', build='1', sha256=hashlib.sha256(data).hexdigest(), size=len(data))
        proof = dict(validator='local', scope='build', source_sha='source', tree='tree',
                     static_checks=True, tools_tests=True, release_build=True,
                     demo_commit=self.commit, demo_sha256='0'*64)
        with self.assertRaises(ValueError):
            ship.verify_package(folder, manifest, proof, 'example/app')


class FullValidationResultsTests(unittest.TestCase):
    def reports(self):
        summary = dict(result='Passed', totalTestCount=2, passedTests=2, failedTests=0,
                       skippedTests=0, expectedFailures=0)
        tree = dict(testNodes=[dict(name='LedgerInteractionTests', nodeType='Test Plan', result='Passed', children=[
            dict(name=name, nodeType=kind, result='Passed', children=[
                dict(name='testSave()', nodeType='Test Case', result='Passed', nodeIdentifierURL=f'test://{name}/testSave')])
            for name, kind in [('LedgerTests', 'Unit test bundle'), ('LedgerUITests', 'UI test bundle')]])])
        return summary, tree

    def validate(self, summary, tree):
        with tempfile.TemporaryDirectory() as temp, ExitStack() as stack:
            root = Path(temp)
            def run(cmd, log=None, **kwargs):
                if log:
                    (root/log).write_text({'swift-tests.log': 'Executed 10 tests, with 0 failures\n',
                        'reports-check.log': 'Reports match Beancount\n',
                        'interaction-tests.log': '** TEST EXECUTE SUCCEEDED **\n'}.get(log, ''))
                return 0
            for name, value in [('ROOT', root), ('run', run), ('step', lambda text: None),
                                ('report', lambda text: None), ('beancount_python', lambda: 'python'),
                                ('fresh_simulator', lambda: ('fake', 'fictional simulator')),
                                ('validate_development', lambda: dict(validator='local', demo_commit='demo', demo_sha256='a'*64)),
                                ('verify_demo_snapshot', lambda *args: 'a'*64),
                                ('out', lambda cmd: json.dumps(summary if 'summary' in cmd else tree))]:
                stack.enter_context(patch.object(ship, name, value))
            stack.enter_context(patch.object(ship.subprocess, 'run'))
            return ship.validate()

    def test_zero_missing_skipped_failed_or_inconsistent_results_cannot_pass(self):
        for kind in ('zero', 'missing_app', 'missing_ui', 'skipped', 'failed_case', 'incomplete', 'count_mismatch'):
            with self.subTest(kind=kind):
                summary, tree = self.reports()
                bundles = tree['testNodes'][0]['children']
                if kind == 'zero':
                    summary.update(totalTestCount=0, passedTests=0)
                    tree['testNodes'] = []
                elif kind.startswith('missing_'):
                    bundles.pop(0 if kind == 'missing_app' else 1)
                    summary.update(totalTestCount=1, passedTests=1)
                elif kind == 'skipped':
                    summary.update(skippedTests=1, passedTests=1)
                elif kind == 'failed_case':
                    bundles[0]['children'][0]['result'] = 'Failed'
                elif kind == 'incomplete':
                    bundles[1]['result'] = 'Unknown'
                elif kind == 'count_mismatch':
                    summary.update(totalTestCount=3, passedTests=3)
                with self.assertRaises(ship.Failure):
                    self.validate(summary, tree)

    def test_both_targets_have_separate_nonzero_counts(self):
        proof = self.validate(*self.reports())
        self.assertEqual(proof['interaction_tests'], 2)
        self.assertEqual(proof['test_targets'], dict(LedgerTests=1, LedgerUITests=1))

    def test_legacy_full_evidence_without_target_counts_is_not_reusable(self):
        proof = dict(validator='local', scope='full', source_sha='source', tree='tree', demo_commit='demo',
                     demo_sha256='a'*64, core_tests=10, interaction_tests=2, reports='Reports match Beancount')
        with self.assertRaises(ValueError):
            ship.verify_proof(proof, dict(source_sha='source', tree='tree'), require_full=True)

    def test_full_evidence_checks_all_stages_and_exact_target_totals(self):
        proof = dict(validator='local', scope='full', source_sha='source', tree='tree', demo_commit='demo',
                     demo_sha256='a'*64, static_checks=True, tools_tests=True, core_tests=10,
                     interaction_tests=2, test_targets=dict(LedgerTests=1, LedgerUITests=1),
                     reports='Reports match Beancount')
        manifest = dict(source_sha='source', tree='tree')
        ship.verify_proof(proof, manifest, require_full=True)
        for change in (dict(static_checks=False), dict(tools_tests=False), dict(core_tests=-1),
                       dict(core_tests=True), dict(test_targets=dict(LedgerTests=2)),
                       dict(test_targets=dict(LedgerTests=1, LedgerUITests=0)),
                       dict(interaction_tests=3)):
            with self.subTest(change=change), self.assertRaises(ValueError):
                ship.verify_proof(dict(proof, **change), manifest, require_full=True)


class PublicationStatusTests(unittest.TestCase):
    def test_formal_release_reports_partial_uploads_and_stops_after_failure(self):
        for failed in (None, 'create', 'upload', 'edit'):
            with self.subTest(failed=failed), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                actions = []
                def request(cmd):
                    self.assertEqual(ship.progress.state['effects']['release'], 'started')
                    actions.append(cmd[2])
                    if cmd[2] == failed:
                        raise ship.Failure('fictional request failed')
                with patch.object(ship, 'STATUS', root/'status.json'), patch.object(ship, 'progress', ship.Progress()), \
                     patch.object(ship, 'release_for_tag', return_value=None), patch.object(ship, 'tag_exists', return_value=False), \
                     patch.object(ship, 'run', side_effect=request):
                    ship.progress.begin('release')
                    if failed:
                        with self.assertRaises(ship.Failure):
                            ship.publish('example/app', 'v1.0.0', root, dict(version='1.0.0', source_sha='source'), root/'notes.md')
                    else:
                        ship.publish('example/app', 'v1.0.0', root, dict(version='1.0.0', source_sha='source'), root/'notes.md')
                    expected = ['create', 'upload', 'edit']
                    self.assertEqual(actions, expected if failed is None else expected[:expected.index(failed) + 1])
                    self.assertEqual(ship.progress.state['effects']['release'], 'started' if failed else 'done')

    def test_remote_request_records_uncertainty_before_sending_and_completion_after_success(self):
        for failed in (False, True):
            with self.subTest(failed=failed), tempfile.TemporaryDirectory() as temp:
                status = Path(temp)/'status.json'
                with patch.object(ship, 'STATUS', status), patch.object(ship, 'progress', ship.Progress()):
                    ship.progress.begin('dev')
                    def request(cmd):
                        self.assertEqual(json.loads(status.read_text())['effects']['main_push'], 'started')
                        if failed:
                            raise ship.Failure('fictional connection lost')
                    with patch.object(ship, 'run', side_effect=request):
                        if failed:
                            with self.assertRaises(ship.Failure):
                                ship.remote_run('main_push', ['fake-push'])
                        else:
                            ship.remote_run('main_push', ['fake-push'])
                    self.assertEqual(json.loads(status.read_text())['effects']['main_push'],
                                     'started' if failed else 'done')

    def test_watch_preserves_remote_action_status_when_the_process_disappears(self):
        state = dict(command='dev', started=100, result=None, stages=[],
                     effects=dict(main_push='done', dev_release='started'))
        screen = ship.render(state, {}, {}, 110, alive=False)
        self.assertIn('已中断', screen)
        self.assertIn('main：已推送', screen)
        self.assertIn('开发版：已发起更新，结果待核实', screen)
        self.assertIn('（未运行）', screen)

    def test_errors_and_interruptions_report_completed_and_uncertain_remote_actions(self):
        cases = [
            ('dev', {}, ship.Failure('checks failed'), 1, 'failed', ['未发起推送或发布']),
            ('dev', dict(main_push='done'), ship.Failure('upload failed'), 1, 'failed',
             ['main：已推送', '开发版：未开始发布', 'IPA 安装源：尚未更新']),
            ('dev', dict(main_push='done', dev_release='started'), ship.Failure('connection lost'), 1, 'failed',
             ['main：已推送', '开发版：已发起更新，结果待核实']),
            ('dev', dict(main_push='done', dev_release='done'), ship.Failure('sources failed'), 1, 'failed',
             ['开发版：已发布', 'IPA 安装源：尚未更新']),
            ('release', dict(release='done', ipa_source='started'), ship.Failure('sources push lost'), 1, 'failed',
             ['正式版：已发布', 'IPA 安装源：已发起更新，结果待核实']),
            ('dev', {}, subprocess.CalledProcessError(1, ['fake-command']), 1, 'failed', ['失败']),
            ('dev', dict(main_push='done'), KeyboardInterrupt(), 130, 'interrupted', ['中断', 'main：已推送']),
        ]
        for command, effects, error, code, result, messages in cases:
            with self.subTest(command=command, error=type(error).__name__, effects=effects), \
                 tempfile.TemporaryDirectory() as temp, tempfile.TemporaryFile(mode='w') as lock, ExitStack() as stack:
                root = Path(temp)
                output = io.StringIO()
                def action(*args, **kwargs):
                    ship.progress.state['effects'] = effects
                    raise error
                for name, value in [('STATUS', root/'status.json'), ('HISTORY', root/'history.json'),
                                    ('progress', ship.Progress()), ('ship_dev', action), ('ship_release', action)]:
                    stack.enter_context(patch.object(ship, name, value))
                stack.enter_context(patch('builtins.open', return_value=lock))
                stack.enter_context(patch('sys.stderr', output))
                self.assertEqual(ship.main(['ship.py', command]), code)
                state = json.loads((root/'status.json').read_text())
                self.assertEqual(state['result'], result)
                for message in messages:
                    self.assertIn(message, output.getvalue())
                    self.assertIn(message, state['message'])
                self.assertNotIn('未推送、未发布', output.getvalue())


if __name__ == '__main__':
    unittest.main()
