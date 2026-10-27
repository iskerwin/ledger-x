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
            if '/dispatches' in ' '.join(cmd):
                return json.dumps(dict(workflow_run_id=123, html_url='https://example.test/run'))
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
            self.assertTrue(payload['return_run_details'])
            self.assertIn('repos/example/app/actions/workflows/dev.yml/dispatches', calls[1][0])
            self.assertNotIn('command', payload['inputs'])
            self.assertNotIn('request_id', payload['inputs'])
            self.assertEqual(json.loads(cloud.STATE.read_text())['run_id'], 123)

    def test_each_command_dispatches_only_its_workflows_inputs(self):
        for command, filename in (('test', 'ci.yml'), ('dev', 'dev.yml'), ('release', 'release.yml')):
            calls = []
            def output(cmd, **kwargs):
                calls.append((cmd, kwargs))
                if cmd[:3] == ['gh', 'release', 'download']:
                    Path(cmd[-1], 'build-manifest.json').write_text(json.dumps(dict(build='123', sha256='a'*64)))
                if '/dispatches' in ' '.join(cmd):
                    return json.dumps(dict(workflow_run_id=456, html_url='https://example.test/run'))
                return ''
            args = argparse.Namespace(command=command, full=command == 'dev', core_filter=None,
                                      ui_test=[], device=None, accepted_build='123' if command == 'release' else None)
            with self.subTest(command=command), tempfile.TemporaryDirectory() as temp, \
                 patch.object(cloud, 'STATE', Path(temp)/'state.json'), patch.object(cloud, 'output', side_effect=output), \
                 patch.object(ship, 'require_clean_main'), patch.object(ship, 'repository', return_value='example/app'), \
                 patch.object(ship, 'git', return_value='a'*40):
                self.assertEqual(cloud.dispatch(args), 0)
                dispatch = next(call for call in calls if '/dispatches' in ' '.join(call[0]))
                self.assertIn(f'repos/example/app/actions/workflows/{filename}/dispatches', dispatch[0])
                payload = json.loads(dispatch[1]['input'])
                if command == 'release':
                    self.assertEqual(payload['inputs'], dict(accepted_build='123'))
                elif command == 'test':
                    self.assertNotIn('full', payload['inputs'])
                else:
                    self.assertEqual(payload['inputs']['full'], 'true')
                self.assertEqual(json.loads(cloud.STATE.read_text())['workflow'], filename)

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

    def test_web_inputs_fail_before_source_checkout_or_testing(self):
        for inputs in (
            dict(LEDGER_COMMAND='dev'),
            dict(LEDGER_COMMAND='dev', LEDGER_FULL='true', LEDGER_CORE_FILTER='Example'),
            dict(LEDGER_COMMAND='test', LEDGER_UI_TESTS='Example; echo bad'),
            dict(LEDGER_COMMAND='release', LEDGER_ACCEPTED_BUILD='123\nother'),
            dict(LEDGER_COMMAND='release', LEDGER_ACCEPTED_BUILD='0'),
            dict(LEDGER_COMMAND='release', LEDGER_ACCEPTED_BUILD='123', LEDGER_FULL='true'),
        ):
            env = dict(LEDGER_SOURCE_SHA='a'*40, GITHUB_REF='refs/heads/main', **inputs)
            with self.subTest(inputs=inputs), patch.dict(os.environ, env, clear=True), \
                 patch.object(ship, 'run') as run:
                with self.assertRaises(ship.Failure):
                    cloud_worker.prepare()
                run.assert_not_called()

    def test_release_automatically_binds_digest_and_refuses_a_different_build(self):
        for build in ('123', '124'):
            with self.subTest(build=build), tempfile.TemporaryDirectory() as temp:
                env_file = Path(temp)/'env'
                env = dict(LEDGER_COMMAND='release', LEDGER_SOURCE_SHA='a'*40,
                           LEDGER_ACCEPTED_BUILD='123', GITHUB_REF='refs/heads/main', GITHUB_ENV=str(env_file))
                def run(cmd, **kwargs):
                    if cmd[:3] == ['gh', 'release', 'download']:
                        Path(cmd[-1], 'build-manifest.json').write_text(json.dumps(dict(build=build, sha256='b'*64)))
                with patch.dict(os.environ, env, clear=True), patch.object(ship, 'run', side_effect=run), \
                     patch.object(ship, 'repository', return_value='example/app'), \
                     patch.object(ship.subprocess, 'run') as ancestry:
                    ancestry.return_value.returncode = 0
                    if build == '124':
                        with self.assertRaises(ValueError):
                            cloud_worker.prepare()
                        self.assertFalse(env_file.exists())
                    else:
                        cloud_worker.prepare()
                        self.assertEqual(env_file.read_text(), f'LEDGER_ACCEPTED_SHA256={"b"*64}\n')
                        self.assertEqual(os.environ['LEDGER_ACCEPTED_SHA256'], 'b'*64)
                        with patch.object(ship, 'worker_main', return_value=0) as worker:
                            self.assertEqual(cloud_worker.run(), 0)
                            worker.assert_called_once_with(['ship.py', 'release'])

    def test_release_cannot_run_without_the_prepared_digest(self):
        env = dict(LEDGER_COMMAND='release', LEDGER_ACCEPTED_BUILD='123')
        with patch.dict(os.environ, env, clear=True), patch.object(ship, 'worker_main') as worker:
            with self.assertRaises(ship.Failure):
                cloud_worker.run()
            worker.assert_not_called()

    def test_watch_uses_returned_run_id_and_preserves_legacy_requests(self):
        for legacy in (False, True):
            with self.subTest(legacy=legacy), tempfile.TemporaryDirectory() as temp:
                path = Path(temp)/'state.json'
                state = dict(repository='example/app', command='dev', workflow='dev.yml')
                state.update(dict(request_id='old-request') if legacy else dict(run_id=123))
                path.write_text(json.dumps(state))
                response = json.dumps(dict(workflow_runs=[dict(id=123, display_title='dev · old-request')]))
                with patch.object(cloud, 'STATE', path), patch.object(cloud, 'output', return_value=response) as output, \
                     patch.object(cloud.subprocess, 'run') as run:
                    run.return_value.returncode = 0
                    self.assertEqual(cloud.watch(True), 0)
                    self.assertEqual(run.call_args.args[0], ['gh', 'run', 'view', '123', '--repo', 'example/app'])
                    if legacy:
                        self.assertIn('/actions/workflows/ledger.yml/runs?', output.call_args.args[0][2])
                    else:
                        output.assert_not_called()

    def test_prepare_rejects_injected_or_non_main_source(self):
        with patch.dict(os.environ, dict(LEDGER_SOURCE_SHA='main; echo bad'), clear=True), patch.object(ship, 'run') as run:
            with self.assertRaises(ship.Failure):
                cloud_worker.prepare()
            run.assert_not_called()

    def test_bare_dev_is_refused_before_dispatch(self):
        with patch.object(cloud, 'dispatch') as dispatch:
            self.assertEqual(cloud.main(['dev']), 1)
            dispatch.assert_not_called()

    def test_prepare_allows_a_branch_test_of_its_own_head_without_fetching(self):
        env = dict(LEDGER_SOURCE_SHA='a'*40, LEDGER_COMMAND='test', GITHUB_REF='refs/heads/feature')
        with patch.dict(os.environ, env, clear=True), patch.object(ship, 'git', return_value='a'*40), \
             patch.object(ship, 'run') as run:
            cloud_worker.prepare()
            run.assert_not_called()

    def test_prepare_refuses_publication_or_a_different_commit_on_a_branch(self):
        for env in (
            dict(LEDGER_SOURCE_SHA='a'*40, LEDGER_COMMAND='dev', GITHUB_REF='refs/heads/feature'),
            dict(LEDGER_SOURCE_SHA='a'*40, LEDGER_COMMAND='test', GITHUB_REF='refs/heads/feature'),
        ):
            head = 'b'*40 if env['LEDGER_COMMAND'] == 'test' else 'a'*40
            with self.subTest(command=env['LEDGER_COMMAND']), patch.dict(os.environ, env, clear=True), \
                 patch.object(ship, 'git', return_value=head), patch.object(ship, 'run') as run:
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

    def test_promotion_reuses_exact_cloud_full_evidence_without_running_tests(self):
        manifest = dict(repository='example/app', source_sha='a'*40, tree='tree', demo_commit='demo', demo_sha256='b'*64)
        proof = dict(validator='github-actions', run_url='https://github.com/example/app/actions/runs/123',
            source_sha='a'*40, tree='tree', demo_commit='demo', demo_sha256='b'*64, scope='full',
            static_checks=True, tools_tests=True, core_tests=10, interaction_tests=2,
            reports='Reports match Beancount', test_targets=dict(LedgerTests=1, LedgerUITests=1))
        with patch.dict(os.environ, dict(GITHUB_ACTIONS='true')), \
             patch.object(ship, 'cloud_full_validation', return_value=proof), \
             patch.object(ship, 'release_validation') as validate:
            result = ship.release_validation_at_source(manifest, dict(scope='build'))
            self.assertTrue(result['release_build'])
            validate.assert_not_called()
        def download(cmd, **kwargs):
            Path(cmd[-1], 'full-validation.json').write_text(json.dumps(dict(proof, tree='wrong')))
        with patch.object(ship, 'gh_api', side_effect=[dict(workflow_runs=[dict(id=123)]),
                dict(artifacts=[dict(name='ledger-full-proof-123', expired=False)])]), \
             patch.object(ship, 'run', side_effect=download):
            self.assertIsNone(ship.cloud_full_validation(manifest))

        def matching_download(cmd, **kwargs):
            Path(cmd[-1], 'full-validation.json').write_text(json.dumps(proof))
        with patch.object(ship, 'gh_api', side_effect=[dict(workflow_runs=[dict(id=123)]),
                dict(artifacts=[dict(name='ledger-full-proof-123', expired=False)])]) as api, \
             patch.object(ship, 'run', side_effect=matching_download):
            self.assertEqual(ship.cloud_full_validation(manifest), proof)
            self.assertEqual(api.call_args_list[0].args[0],
                             f'repos/example/app/actions/runs?status=success&head_sha={"a"*40}&per_page=30')

    def test_targeted_test_command_cannot_leave_full_validation_record(self):
        proof = dict(scope='build', selected_core=dict(filter='Example', passed=1))
        with tempfile.TemporaryFile(mode='w') as lock, tempfile.TemporaryDirectory() as temp, \
             patch('builtins.open', return_value=lock), patch.dict(os.environ, dict(LEDGER_CORE_FILTER='Example')), \
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
