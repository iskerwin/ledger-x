"""Validation boundaries, using only fictional files and local temporary repositories."""
from contextlib import ExitStack
import hashlib
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


if __name__ == '__main__':
    unittest.main()
