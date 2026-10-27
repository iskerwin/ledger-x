"""Pull-request scope stays on the files that changed and never means the full suite."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pr_gate
import pr_scope
import ship

ROOT = Path(__file__).resolve().parents[2]


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

    def test_calendar_helpers_run_calendar_cases_only(self):
        path = 'LedgerUITests/EditInteractionTests.swift'
        text = (ROOT / path).read_text()
        lines = [index for index, line in enumerate(text.splitlines(), 1)
                 if 'func assertNoDaySummary' in line or 'func checkGlassCalendar' in line
                 or 'func testCalendarUsesFullRowWidthWithoutHint' in line]
        self.assertEqual(len(lines), 3)
        plan = pr_scope.classify([path], diff=_diff(path, lines), sources={path: text})
        names = re.findall(r'^\s+func (test\w+)\(', text, re.M)
        expected = tuple(sorted(f'LedgerUITests/EditInteractionTests/{name}'
                                for name in names if 'calendar' in name.lower()))
        self.assertGreaterEqual(len(expected), 9)
        self.assertEqual(plan['xcode_tests'], expected)
        self.assertNotIn('LedgerUITests/EditInteractionTests', plan['xcode_tests'])
        self.assertNotIn('LedgerUITests/EditInteractionTests/testCloseProtectsChangesAndContinueKeepsForm',
                         plan['xcode_tests'])

    def test_a_shared_helper_does_not_pull_in_unrelated_cases(self):
        path = 'LedgerUITests/SampleTests.swift'
        source = '\n'.join([
            'import XCTest',
            'final class SampleTests: XCTestCase {',
            '    func testOther() { launch() }',
            '    func testCalendarOne() { mark() }',
            '    func testCalendarTwo() { launch() }',
            '    private func mark() {}',
            '    private func launch() {}',
            '}',
            '',
        ])
        def at(snippet):
            return source.splitlines().index(snippet) + 1
        calendar = pr_scope.classify([path], diff=_diff(path, [at('    private func mark() {}')]), sources={path: source})
        self.assertEqual(calendar['xcode_tests'], (
            'LedgerUITests/SampleTests/testCalendarOne',
            'LedgerUITests/SampleTests/testCalendarTwo',
        ))
        shared = pr_scope.classify([path], diff=_diff(path, [at('    private func launch() {}')]), sources={path: source})
        self.assertEqual(shared['xcode_tests'], (
            'LedgerUITests/SampleTests/testCalendarTwo',
            'LedgerUITests/SampleTests/testOther',
        ))
        whole = pr_scope.classify([path], diff=_diff(path, [1]), sources={path: source})
        self.assertEqual(whole['xcode_tests'], ('LedgerUITests/SampleTests',))

    def test_pull_request_gate_times_out_instead_of_hanging(self):
        pull = (ROOT / '.github/workflows/pr.yml').read_text()
        gate = (ROOT / 'tools/pr_gate.py').read_text()
        self.assertIn('\n    timeout-minutes: 60\n', pull)
        self.assertIn('TEST_ALLOWANCE = 180', gate)
        self.assertIn('BOOT_LIMIT = 120', gate)
        self.assertIn("'-test-timeouts-enabled', 'YES'", gate)
        self.assertIn("'-maximum-test-execution-time-allowance', str(TEST_ALLOWANCE)", gate)
        self.assertIn('boot_timeout=BOOT_LIMIT, ready_timeout=BOOT_LIMIT', gate)
        self.assertIn('run_limited(command, SWIFT_LIMIT', gate)
        self.assertIn('BUILD_LIMIT, log=', gate)
        self.assertIn('UI_LIMIT, log=', gate)


def _diff(path, lines):
    hunks = [f'@@ -{line},1 +{line},1 @@\n-old\n+new\n' for line in lines]
    return f'diff --git a/{path} b/{path}\n' + ''.join(hunks)


if __name__ == '__main__':
    unittest.main()
