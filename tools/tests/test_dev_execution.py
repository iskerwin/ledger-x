"""Dev output and stage limits, using tiny Python children; no builds or simulator."""
import fcntl
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
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


if __name__ == '__main__':
    unittest.main()
