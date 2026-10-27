"""Cloud dispatch, scoped evidence and promotion safeguards; no network or simulator."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cloud
import cloud_worker
import ship


class CloudTests(unittest.TestCase):
    def test_public_entry_dispatches_instead_of_building_locally(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(cloud, 'main', return_value=0) as dispatch, \
                patch.object(ship, 'worker_main') as worker:
            self.assertEqual(ship.main(['ship.py', 'dev', '--ui-test', 'LedgerUITests/Example/testSave']), 0)
            dispatch.assert_called_once_with(['dev', '--ui-test', 'LedgerUITests/Example/testSave'])
            worker.assert_not_called()

    def test_selected_dispatch_pushes_exact_source_and_carries_filters(self):
        calls = []
        def output(cmd, **kwargs):
            calls.append((cmd, kwargs))
            if cmd[:2] == ['gh', 'api'] and '/runs?' in cmd[2]:
                request = json.loads(calls[-2][1]['input'])['inputs']['request_id']
                return json.dumps(dict(workflow_runs=[dict(display_title=request, id=123, html_url='https://example.test/run')]))
            return ''
        args = argparse.Namespace(command='dev', full=False, core_filter='CalendarMarkTests',
            ui_test=['LedgerUITests/Example/testSave'], device='iPhone SE (3rd generation)', accepted_build=None)
        with tempfile.TemporaryDirectory() as temp, patch.object(cloud, 'STATE', Path(temp)/'state.json'), \
             patch.object(cloud, 'output', side_effect=output), patch.object(ship, 'require_clean_main'), \
             patch.object(ship, 'repository', return_value='example/app'), patch.object(ship, 'git', return_value='a'*40):
            self.assertEqual(cloud.dispatch(args), 0)
            self.assertEqual(calls[0][0], ['git', 'push', 'origin', 'HEAD:refs/heads/main'])
            payload = json.loads(calls[1][1]['input'])
            self.assertEqual(payload['inputs']['ui_tests'], args.ui_test[0])
            self.assertEqual(payload['inputs']['source_sha'], 'a'*40)
            self.assertEqual(json.loads(cloud.STATE.read_text())['run_id'], 123)

    def test_release_requires_the_accepted_build_and_valid_package_digest(self):
        self.assertEqual(cloud.accepted_manifest(dict(build='40', sha256='a'*64), '40'), 'a'*64)
        for record in (dict(build='41', sha256='a'*64), dict(build='40', sha256='bad')):
            with self.assertRaises(ValueError):
                cloud.accepted_manifest(record, '40')
        with patch.object(cloud, 'output') as network, patch.object(ship, 'require_clean_main'), \
             patch.object(ship, 'repository'), patch.object(ship, 'git'):
            args = argparse.Namespace(command='release', full=False, core_filter=None, ui_test=[], device=None, accepted_build=None)
            with self.assertRaises(ValueError):
                cloud.dispatch(args)
            network.assert_not_called()

    def test_worker_rejects_missing_acceptance_and_mixed_test_scopes(self):
        for env in (dict(LEDGER_COMMAND='release'), dict(LEDGER_COMMAND='dev', LEDGER_FULL='true', LEDGER_CORE_FILTER='Example')):
            with patch.dict(os.environ, env, clear=True), patch.object(ship, 'worker_main') as worker:
                with self.assertRaises(ship.Failure):
                    cloud_worker.run()
                worker.assert_not_called()

    def test_prepare_rejects_injected_or_non_main_source(self):
        with patch.dict(os.environ, dict(LEDGER_SOURCE_SHA='main; echo bad'), clear=True), patch.object(ship, 'run') as run:
            with self.assertRaises(ship.Failure):
                cloud_worker.prepare()
            run.assert_not_called()

    def test_selected_evidence_requires_every_requested_test_without_skips(self):
        summary = dict(result='Passed', totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0, expectedFailures=0)
        tree = dict(testNodes=[dict(nodeType='UI test bundle', name='LedgerUITests', children=[
            dict(nodeType='Test Case', nodeIdentifier='Example/testSave()', result='Passed')])])
        selector = ['LedgerUITests/Example/testSave']
        self.assertEqual(ship.checked_selected_results(summary, tree, selector), 1)
        for change in (dict(skippedTests=1), dict(totalTestCount=0), dict(result='Failed')):
            with self.assertRaises(ship.Failure):
                ship.checked_selected_results(dict(summary, **change), tree, selector)
        with self.assertRaises(ship.Failure):
            ship.checked_selected_results(summary, tree, ['LedgerUITests/Example/testOther'])

    def test_cloud_evidence_requires_its_own_repository_run_link(self):
        manifest = dict(source_sha='a'*40, tree='tree', repository='example/app')
        proof = dict(validator='github-actions', source_sha='a'*40, tree='tree', scope='build',
            static_checks=True, tools_tests=True, release_build=True, run_url='https://github.com/example/app/actions/runs/123')
        ship.verify_proof(proof, manifest)
        for url in ('', 'https://github.com/other/app/actions/runs/123'):
            with self.assertRaises(ValueError):
                ship.verify_proof(dict(proof, run_url=url), manifest)

    def test_targeted_test_command_cannot_leave_full_validation_record(self):
        proof = dict(scope='build', selected_core=dict(filter='Example', passed=1))
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, dict(LEDGER_CORE_FILTER='Example')), \
             patch.object(ship, 'ROOT', Path(temp)), patch.object(ship, 'STATUS', Path(temp)/'.ship/status.json'), \
             patch.object(ship, 'FULL_VALIDATION', Path(temp)/'.ship/full-validation.json'), \
             patch.object(ship, 'HISTORY', Path(temp)/'.ship/history.json'), patch.object(ship, 'progress', ship.Progress()), \
             patch.object(ship, 'git', return_value='a'*40), patch.object(ship, 'validate_targeted', return_value=proof), \
             patch.object(ship, 'validate') as full, patch.object(ship, 'run_totals', return_value={}):
            self.assertEqual(ship.worker_main(['ship.py', 'test']), 0)
            self.assertFalse(ship.FULL_VALIDATION.exists())
            full.assert_not_called()
            self.assertTrue((Path(temp)/'.ship/selected-validation.json').exists())


if __name__ == '__main__':
    unittest.main()
