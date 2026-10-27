"""Pull-request scope stays on the files that changed and never means the full suite."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pr_gate
import pr_scope
import ship


class PRScopeTests(unittest.TestCase):
    def test_docs_and_tools_do_not_compile_the_app(self):
        plan = pr_scope.classify(['docs/development/04-云端测试与发布.md', 'tools/ship.py', 'README.md'])
        self.assertEqual(plan['swift'], '')
        self.assertFalse(plan['xcode_build'])
        self.assertEqual(plan['xcode_tests'], ())

    def test_ledgerkit_source_runs_the_package_tests(self):
        plan = pr_scope.classify(['LedgerKit/Sources/LedgerKit/Format.swift'])
        self.assertEqual(plan['swift'], 'all')
        self.assertFalse(plan['xcode_build'])

    def test_one_ledgerkit_test_file_is_filtered(self):
        plan = pr_scope.classify(['LedgerKit/Tests/LedgerKitTests/PostingOrderTests.swift'])
        self.assertEqual(plan['swift'], 'PostingOrderTests')
        self.assertFalse(plan['xcode_build'])

    def test_source_and_test_edits_run_the_whole_package(self):
        plan = pr_scope.classify([
            'LedgerKit/Sources/LedgerKit/Format.swift',
            'LedgerKit/Tests/LedgerKitTests/PostingOrderTests.swift'])
        self.assertEqual(plan['swift'], 'all')

    def test_app_test_file_compiles_and_runs_that_class(self):
        plan = pr_scope.classify(['LedgerTests/AppearanceTests.swift'])
        self.assertTrue(plan['xcode_build'])
        self.assertEqual(plan['xcode_tests'], ('LedgerTests/AppearanceTests',))
        self.assertEqual(plan['swift'], '')

    def test_app_source_compiles_without_running_the_full_ui_suite(self):
        plan = pr_scope.classify(['Ledger/Views/CalendarView.swift', 'project.yml'])
        self.assertTrue(plan['xcode_build'])
        self.assertEqual(plan['xcode_tests'], ())

    def test_gate_rejects_a_base_that_is_not_a_full_sha(self):
        with self.assertRaises(ship.Failure):
            pr_gate.changed_paths('main')


if __name__ == '__main__':
    unittest.main()
