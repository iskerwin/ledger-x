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

    def test_pr_source_only_builds_app_and_hosted_test_edit_keeps_its_class(self):
        for path, action, expected in (
            ('Ledger/Views/SyncAppearance.swift', 'build', 'Ledger'),
            ('Ledger/en.json', 'build', 'Ledger'),
            ('LedgerTests/AppearanceTests.swift', 'build-for-testing', 'LedgerHostedTests'),
        ):
            calls = []
            with self.subTest(path=path), patch.object(pr_gate, 'changed_paths', return_value=[path]), \
                 patch.object(pr_gate, 'changed_diff', return_value=''), \
                 patch.object(pr_gate, 'run_limited', side_effect=lambda cmd, *a, **kw: calls.append(cmd)), \
                 patch.object(ship, 'use_xcode'), \
                 patch.object(ship, 'fresh_simulator', return_value=('fake-id', 'fake-device')), \
                 patch.object(pr_gate.subprocess, 'run'):
                self.assertEqual(pr_gate.main(['gate', 'a' * 40]), 0)
            builds = [cmd for cmd in calls if cmd[0] == 'xcodebuild' and action in cmd]
            self.assertEqual(len(builds), 1)
            self.assertEqual(builds[0][builds[0].index('-scheme') + 1], expected)
            executions = [cmd for cmd in calls if 'test-without-building' in cmd]
            if path.startswith('LedgerTests/'):
                self.assertEqual(len(executions), 1)
                self.assertIn('-only-testing:LedgerTests/AppearanceTests', executions[0])
            else:
                self.assertEqual(executions, [])


if __name__ == '__main__':
    unittest.main()
