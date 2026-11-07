"""Check emitted build commands without invoking Swift, Xcode or a simulator."""
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import dev_scope
import mac_release
import pr_gate
import ship


class SmallBuildTests(unittest.TestCase):
    def test_cache_refreshes_with_source_and_restores_only_compatible_builds(self):
        action = (Path(__file__).resolve().parents[2] / '.github/actions/ledger-run/action.yml').read_text()
        key = action.split('        key: ', 1)[1].splitlines()[0]
        fallback = action.split('        restore-keys: |\n', 1)[1].splitlines()[0].strip()
        self.assertTrue(key.startswith(fallback))
        self.assertIn('runner.os', fallback)
        self.assertIn('runner.arch', fallback)
        self.assertIn("hashFiles('LedgerKit/Package.swift', 'project.yml', 'tools/select_xcode.sh')", fallback)
        self.assertIn("hashFiles('Ledger/**', 'LedgerKit/**', 'LedgerTests/**', 'LedgerUITests/**')", key)
        cache_paths = action.split('        path: |', 1)[1].split('        key:', 1)[0]
        for result in ('xcresult', '.ship', 'dist/', '\n          build/'):
            self.assertNotIn(result, cache_paths)
        self.assertNotIn('cache-hit', action)

    def test_dev_build_and_execution_use_the_same_minimum_scheme(self):
        for selectors, expected in (
            ('LedgerTests/AppearanceTests', 'LedgerHostedTests'),
            ('LedgerUITests/EditInteractionTests/testUntouchedFormClosesWithoutPrompt', 'LedgerUITests'),
            ('LedgerTests/SyncAppearanceTests LedgerUITests/EditInteractionTests/testUntouchedFormClosesWithoutPrompt',
             'LedgerInteractionTests'),
        ):
            calls = []
            with self.subTest(selectors=selectors), tempfile.TemporaryDirectory() as temp, \
                 patch.object(ship, 'ROOT', Path(temp)), \
                 patch.dict(os.environ, LEDGER_COMMAND='dev', LEDGER_UI_TESTS=selectors, LEDGER_CORE_FILTER=''), \
                 patch.object(ship, 'validate_development', return_value={'scope': 'build'}), \
                 patch.object(ship, 'fresh_simulator', return_value=('fake-id', 'fake-device')), \
                 patch.object(ship, 'run', side_effect=lambda cmd, **kw: calls.append(cmd)), \
                 patch.object(ship, 'out', return_value='{}'), \
                 patch.object(ship, 'checked_selected_results', return_value=1), \
                 patch.object(ship.subprocess, 'run'):
                ship.validate_targeted()
            builds = [cmd for cmd in calls if 'build-for-testing' in cmd]
            executions = [cmd for cmd in calls if 'test-without-building' in cmd]
            self.assertEqual(len(builds), 1)
            self.assertEqual(len(executions), 1)
            for cmd in builds + executions:
                self.assertEqual(cmd[cmd.index('-scheme') + 1], expected)
            self.assertLessEqual({'-only-testing:' + s for s in selectors.split()}, set(executions[0]))

    def test_pr_gate_runs_the_dev_plan_with_the_dev_executor_and_keeps_a_proof(self):
        import dev_scope
        plan = dict(dev_scope.classify(['Ledger/Views/CalendarView.swift']), base_sha='b'*40, source_sha='a'*40)
        seen = {}
        def validate(selected):
            seen.update(plan=selected, command=os.environ.get('LEDGER_COMMAND'))
            return dict(validator='github-actions', run_url='https://github.com/example/app/actions/runs/1',
                        scope='build', auto_selection=selected)
        def git(*args):
            return {('rev-parse', 'HEAD'): 'a'*40, ('status', '--porcelain'): ''}.get(args, 'tree')
        with tempfile.TemporaryDirectory() as temp, patch.object(pr_gate, 'PROOF', Path(temp)/'pr-proof.json'), \
             patch.dict(os.environ, dict(GITHUB_REPOSITORY='example/app')), \
             patch.object(dev_scope, 'select', return_value=plan) as select, \
             patch.object(dev_scope, 'validate', side_effect=validate), \
             patch.object(ship, 'git', side_effect=git), patch('builtins.print'):
            self.assertEqual(pr_gate.main(['gate']), 0)
            select.assert_called_once_with('example/app', 'a'*40)
            self.assertEqual(seen, dict(plan=plan, command='dev'))
            proof = ship.read_json(pr_gate.PROOF)
        self.assertEqual((proof['tree'], proof['source_sha'], proof['auto_selection']), ('tree', 'a'*40, plan))
        self.assertIsNotNone(dev_scope.pr_proof(proof, dict(plan, source_sha='c'*40), 'tree', 'example/app'))

    def gate_with(self, paths, run):
        import dev_scope
        plan = dict(dev_scope.classify(paths), base_sha='b'*40, source_sha='a'*40)
        def git(*args):
            return {('rev-parse', 'HEAD'): 'a'*40, ('status', '--porcelain'): ''}.get(args, 'tree')
        proof = dict(validator='github-actions', scope='build', auto_selection=plan)
        with tempfile.TemporaryDirectory() as temp, patch.object(pr_gate, 'PROOF', Path(temp)/'pr-proof.json'), \
             patch.dict(os.environ, dict(GITHUB_REPOSITORY='example/app')), \
             patch.object(dev_scope, 'select', return_value=plan), patch.object(dev_scope, 'validate', return_value=proof), \
             patch.object(ship, 'git', side_effect=git), patch.object(ship, 'run', side_effect=run), \
             patch.object(ship, 'step'), patch('builtins.print'):
            try:
                return pr_gate.main(['gate']), pr_gate.PROOF.exists()
            except ship.Failure:
                return 1, pr_gate.PROOF.exists()

    def test_pr_gate_compiles_the_mac_app_when_its_sources_change(self):
        for path in ('LedgerMac/LedgerMacApp.swift', 'LedgerKit/Sources/LedgerKit/Build.swift', 'project.yml'):
            commands = []
            self.assertEqual(self.gate_with([path], lambda cmd, **_: commands.append(cmd)), (0, True))
            builds = [cmd for cmd in commands if cmd[0] == 'xcodebuild']
            self.assertEqual(len(builds), 1, path)
            self.assertEqual(builds[0][builds[0].index('-scheme') + 1], 'LedgerMac')

    def test_pr_gate_skips_the_mac_build_for_changes_that_cannot_reach_it(self):
        commands = []
        self.assertEqual(self.gate_with(['Ledger/Views/CalendarView.swift', 'docs/a.md'], lambda cmd, **_: commands.append(cmd)), (0, True))
        self.assertEqual(commands, [])

    def test_a_failed_mac_build_fails_the_gate_and_leaves_no_proof(self):
        def run(cmd, **_):
            if cmd[0] == 'xcodebuild':
                raise ship.Failure('Mac 编译失败')
        self.assertEqual(self.gate_with(['LedgerMac/LedgerMacApp.swift'], run), (1, False))


class MacReleaseTests(unittest.TestCase):
    def publish(self, newest='abc1234567', published=True):
        commands = []
        with patch.object(ship, 'git', return_value='abc1234567'), patch.object(ship, 'step'), patch('builtins.print'), \
             patch.dict('os.environ', {'GITHUB_REPOSITORY': 'example/app'}), \
             patch.object(ship, 'run', side_effect=lambda cmd, **_: commands.append(cmd)), \
             patch.object(ship, 'out', return_value=f'{newest}\trefs/heads/main\n'), \
             patch.object(ship, 'release_for_tag', return_value={'tag_name': 'mac'} if published else None):
            self.assertEqual(mac_release.main(), 0)
        return [cmd for cmd in commands if cmd[0] == 'gh']

    def test_the_newest_main_replaces_the_app_and_moves_the_tag(self):
        calls = self.publish()
        self.assertEqual([cmd[1:3] for cmd in calls], [['release', 'upload'], ['api', '-X'], ['release', 'edit']])
        self.assertIn('--clobber', calls[0])
        self.assertIn('sha=abc1234567', calls[1])

    def test_the_first_publish_is_a_prerelease_of_that_commit(self):
        calls = self.publish(published=False)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1:4], ['release', 'create', 'mac'])
        self.assertIn('--prerelease', calls[0])
        self.assertEqual(calls[0][calls[0].index('--target') + 1], 'abc1234567')

    def test_anything_but_the_newest_main_publishes_nothing(self):
        self.assertEqual(self.publish(newest='fff0000000'), [])

    def test_it_stays_out_of_the_phone_releases(self):
        calls = self.publish() + self.publish(published=False)
        self.assertFalse(any('--latest' in cmd for cmd in calls))
        notes = next(cmd[cmd.index('--notes') + 1] for cmd in calls if '--notes' in cmd)
        release = dict(tag_name='mac', body=notes)
        self.assertEqual(ship.next_build([release, dict(tag_name='dev', body='构建 7')]), '8')
        self.assertEqual(ship.release_tags('abc\trefs/tags/mac\n'), set())

    def test_it_runs_for_whatever_the_gate_builds_the_mac_app_for(self):
        workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/mac.yml').read_text()
        for path in ('LedgerMac/**', 'LedgerKit/Sources/**', 'LedgerKit/Package.swift', 'project.yml'):
            self.assertIn(f"- '{path}'", workflow)
        self.assertTrue(dev_scope.needs_mac_build(['LedgerMac/a.swift']) and dev_scope.needs_mac_build(['LedgerKit/Sources/a.swift'])
                        and dev_scope.needs_mac_build(['LedgerKit/Package.swift']) and dev_scope.needs_mac_build(['project.yml']))
        self.assertIn('group: ledger-mac', workflow)
        self.assertIn('cancel-in-progress: false', workflow)


if __name__ == '__main__':
    unittest.main()
