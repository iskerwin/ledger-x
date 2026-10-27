"""Reviewed minimum coverage for small changes; unknown dependencies stay broad."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import dev_scope
import pr_scope


class SmallScopeTests(unittest.TestCase):
    def test_search_source_keeps_required_class_without_unrelated_core_modules(self):
        # TxQuery is exercised by SearchTests; App search interaction stays in Dev.
        path = 'LedgerKit/Sources/LedgerKit/Search.swift'
        pr = pr_scope.classify([path])
        self.assertLessEqual({'SearchTests'}, set(pr['swift'].split('|')))
        self.assertNotEqual(pr['swift'], 'all')
        dev = dev_scope.classify([path])
        self.assertLessEqual({'SearchTests'}, set(dev['core_filter'].split('|')))
        self.assertIn('LedgerUITests/EditInteractionTests/testJournalSearchAppliesOnSubmitAndClearRestores', dev['ui_tests'])

    def test_localization_has_static_coverage_and_no_unrelated_form_flows(self):
        for path in ('Ledger/en.json', 'Ledger/Localizable.xcstrings',
                     'Ledger/AppShortcuts.xcstrings', 'Ledger/InfoPlist.xcstrings'):
            with self.subTest(path=path):
                plan = dev_scope.classify([path])
                # check_project validates keys, English values and system prompt consistency.
                self.assertEqual(plan['core_filter'], '')
                self.assertEqual(plan['ui_tests'], [])
                self.assertTrue(any('本地化' in reason for reason in plan['reasons']))
                self.assertTrue(pr_scope.classify([path])['xcode_build'])

    def test_mixed_localization_source_and_test_changes_keep_the_union(self):
        paths = ['Ledger/en.json', 'Ledger/Views/CalendarView.swift',
                 'LedgerTests/AppearanceTests.swift']
        plan = dev_scope.classify(paths)
        required = set(dev_scope.classify(paths[1:])['ui_tests'])
        self.assertLessEqual(required, set(plan['ui_tests']))
        self.assertIn('LedgerTests/AppearanceTests', plan['ui_tests'])
        pr = pr_scope.classify(['LedgerKit/Sources/LedgerKit/Search.swift',
                                'LedgerKit/Tests/LedgerKitTests/PostingOrderTests.swift'])
        self.assertLessEqual({'SearchTests', 'PostingOrderTests'}, set(pr['swift'].split('|')))

    def test_unknown_core_and_resources_are_not_treated_as_localization(self):
        self.assertEqual(pr_scope.classify(['LedgerKit/Sources/LedgerKit/Unknown.swift'])['swift'], 'all')
        for path in ('Ledger/unknown.json', 'Ledger/Assets.xcassets/Contents.json'):
            self.assertLessEqual(set(dev_scope.CRITICAL_UI), set(dev_scope.classify([path])['ui_tests']))

    def test_stale_reviewed_core_mapping_expands_with_a_reason(self):
        plan = pr_scope.classify(['LedgerKit/Sources/LedgerKit/Search.swift'], sources={
            'LedgerKit/Tests/LedgerKitTests/SearchTests.swift': '// class removed or renamed'})
        self.assertEqual(plan['swift'], 'all')
        self.assertTrue(any('扩大' in reason for reason in plan['reasons']))


if __name__ == '__main__':
    unittest.main()
