"""Prevent a small-scope path from silently entering the full validator."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import scope_guard


class ScopeGuardTests(unittest.TestCase):
    def test_full_calls_and_full_plans_are_rejected(self):
        for call in ('validate()', 'ship.validate()', 'release_validation({}, {})'):
            with self.subTest(call=call), self.assertRaises(ValueError):
                scope_guard.check_runner('def run():\n    ' + call, 'run')
        for kind, plan in (('dev', {'full': True}), ('pr', {'scope': 'full'})):
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                scope_guard.check_plan(plan, kind)

    def test_module_expansion_requires_a_visible_reason(self):
        for kind, plan in (('dev', {'core_all': True}),
                           ('dev', {'app_targets': ['LedgerTests']}),
                           ('pr', {'swift': 'all'})):
            with self.subTest(kind=kind, plan=plan), self.assertRaises(ValueError):
                scope_guard.check_plan(plan, kind)
            scope_guard.check_plan(dict(plan, reasons=['unknown.swift → 扩大到核心/App 内测试模块']), kind)

    def test_targeted_calls_and_explicit_manual_full_path_are_distinct(self):
        scope_guard.check_runner('def run():\n    ship.validate_targeted()', 'run')
        scope_guard.check_runner('def run():\n    dev_scope.validate(plan)', 'run')
        with self.assertRaises(ValueError):
            scope_guard.check_runner('def other(): pass', 'run')


if __name__ == '__main__':
    unittest.main()
