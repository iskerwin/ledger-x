"""Check emitted build commands without invoking Swift, Xcode or a simulator."""
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
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


if __name__ == '__main__':
    unittest.main()
