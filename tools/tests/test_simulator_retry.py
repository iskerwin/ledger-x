"""A simulator that hangs while starting is replaced once before the job fails."""
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ship


class SimulatorRetryTests(unittest.TestCase):
    def start(self, hangs):
        created, calls = [], []
        def out(cmd, **kwargs):
            if cmd[:4] == ['xcrun', 'simctl', 'list', 'devices']:
                return '{"devices": {}}'
            if cmd[:4] == ['xcrun', 'simctl', 'list', 'runtimes']:
                return '{"runtimes": []}'
            if cmd[:3] == ['xcrun', 'simctl', 'create']:
                created.append(f'sim-{len(created) + 1}')
                return created[-1]
            return '26.0'
        def run(cmd, **kwargs):
            calls.append(cmd)
            if cmd[2] == 'getenv' and len([c for c in calls if c[2] == 'getenv']) <= hangs:
                raise subprocess.TimeoutExpired(cmd, 60)
        with patch.object(ship, 'out', side_effect=out), patch.object(ship.subprocess, 'run', side_effect=run), \
             patch.object(ship, 'select_device', return_value=({'identifier': 'rt', 'name': 'iOS 26'}, {'identifier': 'dt', 'name': 'iPhone'})), \
             patch.object(ship, 'disable_hardware_keyboard'), patch('builtins.print'):
            return ship.fresh_simulator(), created, calls

    def test_a_hung_start_gets_one_new_simulator(self):
        (udid, _), created, calls = self.start(hangs=1)
        self.assertEqual(created, ['sim-1', 'sim-2'])
        self.assertEqual(udid, 'sim-2')
        self.assertIn(['xcrun', 'simctl', 'delete', 'sim-1'], calls)

    def test_a_second_hang_fails_as_an_environment_failure(self):
        with self.assertRaises(ship.Failure) as failure:
            self.start(hangs=2)
        self.assertIn('测试尚未开始', str(failure.exception))


if __name__ == '__main__':
    unittest.main()
