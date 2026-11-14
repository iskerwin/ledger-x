"""Dev output and stage limits, using tiny Python children; no builds or simulator."""
import fcntl
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from contextlib import ExitStack
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ship


class DevExecutionTests(unittest.TestCase):
    def test_output_is_visible_before_the_child_finishes_and_is_saved(self):
        seen = threading.Event()
        errors = []
        class Output(io.StringIO):
            def write(self, value):
                if 'live line' in value:
                    seen.set()
                return super().write(value)
        with tempfile.TemporaryDirectory() as temp, patch.object(ship, 'ROOT', Path(temp)), \
             patch.object(ship, 'progress', ship.Progress()), patch.dict(os.environ, dict(LEDGER_COMMAND='dev')), \
             patch('sys.stdout', new_callable=Output) as output:
            gate = Path(temp)/'gate'
            with gate.open('w+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                script = 'import fcntl,sys; print("live line",flush=True); f=open(sys.argv[1]); fcntl.flock(f,fcntl.LOCK_EX); print("done",flush=True)'
                def run():
                    try:
                        ship.run([sys.executable, '-u', '-c', script, str(gate)], log='live.log', timeout=3)
                    except BaseException as error:
                        errors.append(error)
                thread = threading.Thread(target=run)
                thread.start()
                try:
                    self.assertTrue(seen.wait(2), 'Dev output must arrive while the process is still running')
                    self.assertTrue(thread.is_alive())
                    self.assertIn('live line', (Path(temp)/'live.log').read_text())
                finally:
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    thread.join(5)
                self.assertFalse(thread.is_alive())
                self.assertEqual(errors, [])
                self.assertIn('done', output.getvalue())

    def test_a_silent_process_times_out_instead_of_waiting_for_the_job_limit(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(ship, 'ROOT', Path(temp)), \
             patch.object(ship, 'progress', ship.Progress()), patch.dict(os.environ, dict(LEDGER_COMMAND='dev')):
            with self.assertRaisesRegex(ship.Failure, '超过阶段时限'):
                ship.run([sys.executable, '-c', 'import signal; signal.pause()'], log='silent.log', timeout=0.15)

    def test_stage_limits_apply_to_dev_without_changing_full_or_manual_testing(self):
        for command, expected in (('dev', 720), ('test', None), ('release', None)):
            with self.subTest(command=command), patch.dict(os.environ, dict(LEDGER_COMMAND=command)):
                self.assertEqual(ship.dev_limit(720), expected)

    def test_dev_build_and_execution_have_separate_deadlines_and_selected_cases(self):
        calls = []
        selector = 'LedgerUITests/Example/testSave'
        with tempfile.TemporaryDirectory() as temp, patch.object(ship, 'ROOT', Path(temp)), \
             patch.dict(os.environ, dict(LEDGER_COMMAND='dev', LEDGER_CORE_FILTER='', LEDGER_UI_TESTS=selector)), \
             patch.object(ship, 'validate_development', return_value=dict(scope='build')), patch.object(ship, 'step'), \
             patch.object(ship, 'fresh_simulator', return_value=('fixture-device', 'fixture simulator')), \
             patch.object(ship, 'run', side_effect=lambda cmd, **kwargs: calls.append((cmd, kwargs))), \
             patch.object(ship, 'out', return_value='{}'), patch.object(ship, 'checked_selected_results', return_value=1), \
             patch.object(ship.subprocess, 'run'):
            proof = ship.validate_targeted()
        builds = [(cmd, options) for cmd, options in calls if 'build-for-testing' in cmd]
        tests = [(cmd, options) for cmd, options in calls if 'test-without-building' in cmd]
        self.assertEqual(len(builds), 1)
        self.assertEqual(builds[0][1]['timeout'], 1200)
        self.assertEqual(len(tests), 1)
        self.assertEqual(tests[0][1]['timeout'], 1500)
        self.assertIn('-only-testing:' + selector, tests[0][0])
        self.assertEqual(proof['selected_interaction']['selectors'], [selector])

    def run_selected_batches(self, selectors, *, fail_batch=None, missing_batch=None, command='dev'):
        calls, results = [], {}
        def run(cmd, **options):
            calls.append((cmd, options))
            if 'test-without-building' not in cmd and 'test' not in cmd:
                return
            selected = [arg.removeprefix('-only-testing:') for arg in cmd if arg.startswith('-only-testing:')]
            batch = len(results) + 1
            if batch == fail_batch:
                raise ship.Failure('fixture test failed')
            # At 90 seconds per case plus setup/teardown, the old single 26-case invocation times out.
            if options['timeout'] is not None and len(selected) * 90 + 120 > options['timeout']:
                raise ship.Failure('fixture stage timeout')
            path = cmd[cmd.index('-resultBundlePath') + 1]
            results[path] = selected[:-1] if batch == missing_batch else selected
        def out(cmd):
            selected = results[cmd[cmd.index('--path') + 1]]
            if 'summary' in cmd:
                return json.dumps(dict(result='Passed', totalTestCount=len(selected), passedTests=len(selected),
                                       failedTests=0, skippedTests=0, expectedFailures=0))
            return json.dumps(dict(testNodes=[dict(nodeType='UI test bundle', name='LedgerUITests', children=[
                dict(nodeType='Test Case', nodeIdentifier=selector, result='Passed') for selector in selected])]))
        with tempfile.TemporaryDirectory() as temp, ExitStack() as stack:
            stack.enter_context(patch.object(ship, 'ROOT', Path(temp)))
            stack.enter_context(patch.dict(os.environ, dict(LEDGER_COMMAND=command, LEDGER_CORE_FILTER='',
                                                           LEDGER_UI_TESTS='\n'.join(selectors), LEDGER_SIMULATOR_DEVICE='')))
            for name, value in [('validate_development', lambda: dict(scope='build')), ('step', lambda text: None),
                                ('fresh_simulator', lambda: ('fixture', 'fixture simulator')), ('run', run), ('out', out)]:
                stack.enter_context(patch.object(ship, name, value))
            shutdown = stack.enter_context(patch.object(ship.subprocess, 'run'))
            try:
                return ship.validate_targeted(), calls
            finally:
                shutdown.assert_called_once_with(['xcrun', 'simctl', 'shutdown', 'fixture'], capture_output=True)

    def test_cumulative_ui_plan_finishes_in_bounded_batches_without_losing_cases_or_evidence(self):
        selectors = [f'LedgerUITests/Example/testCase{index}' for index in range(26)]
        proof, calls = self.run_selected_batches(selectors)
        self.assertEqual(sum('build-for-testing' in cmd for cmd, _ in calls), 1)
        runs = [(cmd, options) for cmd, options in calls if 'test-without-building' in cmd]
        self.assertEqual(len(runs), 5)
        actual = []
        for cmd, options in runs:
            batch = [arg.removeprefix('-only-testing:') for arg in cmd if arg.startswith('-only-testing:')]
            self.assertLessEqual(len(batch), 6)
            self.assertEqual(options['timeout'], 1500)
            self.assertEqual(cmd[cmd.index('-maximum-test-execution-time-allowance') + 1], '180')
            actual.extend(batch)
        self.assertEqual(actual, selectors)
        record = proof['selected_interaction']
        self.assertEqual(record['selectors'], selectors)
        self.assertEqual(record['passed'], 26)
        self.assertEqual(len({batch['result'] for batch in record['batches']}), 5)
        self.assertEqual(len({batch['log'] for batch in record['batches']}), 5)

    def test_failed_or_missing_case_in_a_later_batch_cannot_leave_a_passing_proof(self):
        selectors = [f'LedgerUITests/Example/testCase{index}' for index in range(14)]
        with self.assertRaisesRegex(ship.Failure, 'fixture test failed'):
            self.run_selected_batches(selectors, fail_batch=2)
        with self.assertRaisesRegex(ship.Failure, '没有实际执行'):
            self.run_selected_batches(selectors, missing_batch=2)

    def test_manual_targeted_execution_keeps_its_existing_single_run_and_allowance(self):
        selectors = [f'LedgerUITests/Example/testCase{index}' for index in range(26)]
        proof, calls = self.run_selected_batches(selectors, command='test')
        runs = [(cmd, options) for cmd, options in calls if 'test' in cmd]
        self.assertEqual(len(runs), 1)
        self.assertIsNone(runs[0][1]['timeout'])
        self.assertEqual(proof['selected_interaction']['passed'], 26)
        self.assertNotIn('batches', proof['selected_interaction'])

    def test_batch_logs_show_test_progress_and_keep_counts_for_watch(self):
        log = "Test Case '-[Example testSave]' passed (0.1 seconds).\nTest Case '-[Example testOpen]' started.\n"
        with tempfile.TemporaryDirectory() as temp, patch.object(ship, 'ROOT', Path(temp)):
            for name in ('batch-1-interaction-tests.log', 'batch-2-narrow-interaction-tests.log'):
                (Path(temp) / name).write_text(log)
                info = ship.log_progress(name, log)
                self.assertEqual(info['passed'], 1)
                self.assertEqual(info['current'], 'Example testOpen')
            self.assertEqual(ship.run_totals(0), {'batch-1-interaction-tests.log': 1,
                                                 'batch-2-narrow-interaction-tests.log': 1})


if __name__ == '__main__':
    unittest.main()
