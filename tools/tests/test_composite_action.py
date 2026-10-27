"""Shared action must load without workflow-only contexts or publishing in its PR smoke check."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CompositeActionTests(unittest.TestCase):
    def test_composite_does_not_reference_workflow_only_configuration_contexts(self):
        action = (ROOT/'.github/actions/ledger-run/action.yml').read_text()
        expressions = re.findall(r'\$\{\{(.*?)\}\}', action, re.S)
        for expression in expressions:
            with self.subTest(expression=expression):
                self.assertNotRegex(expression, r'\b(?:vars|secrets)\s*[.\[]')
        self.assertIn('${{ inputs.cache_epoch }}', action)

    def test_all_callers_forward_cache_configuration_and_pr_loads_the_real_component(self):
        for filename in ('ci.yml', 'dev.yml', 'release.yml'):
            workflow = (ROOT/'.github/workflows'/filename).read_text()
            calls = workflow.split('uses: ./.github/actions/ledger-run')[1:]
            self.assertTrue(calls)
            for call in calls:
                self.assertIn("cache_epoch: ${{ vars.LEDGER_CACHE_EPOCH || '1' }}", call.split('\n      - ', 1)[0])
        ci = (ROOT/'.github/workflows/ci.yml').read_text()
        gate = ci.split('\n  gate:', 1)[1].split('\n  test:', 1)[0]
        self.assertIn('uses: ./.github/actions/ledger-run', gate)
        self.assertIn("check_only: 'true'", gate)
        self.assertLess(gate.index('uses: ./.github/actions/ledger-run'), gate.index('run: python3 tools/pr_gate.py'))

    def test_load_only_check_skips_every_preparation_validation_and_publication_step(self):
        action = (ROOT/'.github/actions/ledger-run/action.yml').read_text()
        steps = re.split(r'^    - ', action, flags=re.M)[1:]
        self.assertGreater(len(steps), 8)
        checks = 0
        for step in steps:
            if "if: inputs.check_only == 'true'" in step:
                checks += 1
                self.assertNotIn('uses:', step)
                self.assertNotIn('cloud_worker.py', step)
            else:
                self.assertIn("inputs.check_only != 'true'", step)
        self.assertEqual(checks, 1)


if __name__ == '__main__':
    unittest.main()
