"""The full suite as two halves: how they are split, joined and picked up by Release; no network or simulator."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cloud_worker
import ship

SHA = 'a' * 40
RUN = 'https://github.com/example/app/actions/runs/123'


def half(number, cases, first):
    proof = dict(validator='github-actions', run_url=RUN, source_sha=SHA, tree='tree', demo_commit='demo',
                 demo_sha256='b' * 64, xcode='Xcode 26.6', macos='26.0', static_checks=True, tools_tests=True,
                 scope='shard', shard=number, simulator='fictional iPhone', first_half=first, cases=cases,
                 validated_at=f'2026-11-20T0{number}:00:00+00:00')
    if number == 1:
        proof.update(core_tests=10, reports='Reports match Beancount')
    return proof


class SplitTests(unittest.TestCase):
    def test_every_other_ui_test_in_source_order_ignoring_comments(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp, 'LedgerUITests')
            folder.mkdir()
            (folder / 'A.swift').write_text(
                'final class ATests: XCTestCase {\n    func testOne() {}\n    // func testCommented() {}\n'
                '    private func helper() {}\n    func testTwo() {}\n        func testNested() {}\n}\n'
                'extension ATests {\n    func testThree() {}\n}\n')
            (folder / 'B.swift').write_text('final class BTests: XCTestCase {\n    func testFour() {}\n}\n')
            self.assertEqual(ship.ui_test_methods(Path(temp)), [
                'LedgerUITests/ATests/testOne', 'LedgerUITests/ATests/testTwo', 'LedgerUITests/ATests/testThree',
                'LedgerUITests/BTests/testFour'])
            self.assertEqual(ship.first_half(Path(temp)), ['LedgerUITests/ATests/testOne', 'LedgerUITests/ATests/testThree'])

    def test_the_repository_splits_into_two_nonempty_halves(self):
        cases = ship.ui_test_methods()
        self.assertGreater(len(cases), 50)
        self.assertEqual(len(cases), len(set(cases)))
        self.assertTrue(0 < len(ship.first_half()) < len(cases))

    def test_shard_must_be_one_or_two(self):
        for value, expected in (('', None), ('1', 1), ('2', 2)):
            with patch.dict(os.environ, dict(LEDGER_SHARD=value)):
                self.assertEqual(ship.shard(), expected)
        with patch.dict(os.environ, dict(LEDGER_SHARD='3')), self.assertRaises(ship.Failure):
            ship.shard()

    def test_tool_tests_inside_a_half_do_not_inherit_its_number(self):
        envs = []
        def run(cmd, log=None, env=None, **kwargs):
            if log == 'tools-tests.log':
                envs.append(env)
            return 0
        with patch.dict(os.environ, dict(LEDGER_SHARD='1')), patch.object(ship, 'use_xcode', return_value='Xcode'), \
                patch.object(ship, 'demo_snapshot', return_value='demo'), \
                patch.object(ship, 'verify_demo_snapshot', return_value='b' * 64), \
                patch.object(ship, 'step'), patch.object(ship, 'run', side_effect=run):
            ship.validate_development()
        self.assertEqual(len(envs), 1)
        self.assertFalse('LEDGER_SHARD' in envs[0], 'the tool tests got the half number')

    def test_halves_check_what_ran(self):
        first = ['LedgerUITests/A/testOne']
        summary = lambda n: dict(result='Passed', totalTestCount=n, passedTests=n, failedTests=0, skippedTests=0,
                                 expectedFailures=0)
        def tree(*cases):
            return dict(testNodes=[dict(nodeType='UI test bundle', name='LedgerUITests', children=[
                dict(nodeType='Test Case', nodeIdentifier=case.split('/', 1)[1] + '()', result='Passed') for case in cases])])
        def results(number, *cases):
            with patch.object(ship, 'out', side_effect=lambda cmd: json.dumps(
                    summary(len(cases)) if 'summary' in cmd else tree(*cases))):
                return ship.shard_results(number, first)
        self.assertEqual(results(1, *first), first)
        self.assertEqual(results(2, 'LedgerUITests/A/testTwo'), ['LedgerUITests/A/testTwo'])
        with self.assertRaises(ship.Failure):
            results(1, 'LedgerUITests/A/testTwo')
        with self.assertRaises(ship.Failure):
            results(2, 'LedgerUITests/A/testTwo', *first)


# the record must link to this repository's runs, as the cloud's GITHUB_REPOSITORY says
@patch.dict(os.environ, dict(GITHUB_REPOSITORY='example/app'))
class CombineTests(unittest.TestCase):
    def halves(self):
        first = ['LedgerUITests/A/testOne', 'LedgerUITests/A/testThree']
        return half(1, first, first), half(2, ['LedgerTests/S/testSave', 'LedgerUITests/A/testTwo'], first)

    def test_two_halves_of_one_source_make_a_reusable_full_record(self):
        full = ship.combine_shards(*self.halves())
        self.assertEqual(full['scope'], 'full')
        self.assertEqual(full['interaction_tests'], 4)
        self.assertEqual(full['test_targets'], dict(LedgerTests=1, LedgerUITests=3))
        self.assertEqual((full['core_tests'], full['reports']), (10, 'Reports match Beancount'))
        self.assertNotIn('cases', full)
        ship.verify_proof(full, dict(source_sha=SHA, tree='tree', repository='example/app', demo_commit='demo',
                                     demo_sha256='b' * 64), require_full=True)

    def test_anything_short_of_one_whole_suite_is_refused(self):
        def change(which, **values):
            halves = list(self.halves())
            halves[which] = dict(halves[which], **values)
            return halves
        cases = {
            'same half twice': [self.halves()[0], self.halves()[0]],
            'other source': change(1, source_sha='c' * 40),
            'other tree': change(1, tree='other'),
            'other demo': change(1, demo_sha256='d' * 64),
            'other split': change(1, first_half=['LedgerUITests/A/testOne']),
            'other run': change(1, run_url=RUN.replace('123', '456')),
            'another repository': [dict(h, run_url=RUN.replace('example', 'other')) for h in self.halves()],
            'first half not run exactly': change(0, cases=['LedgerUITests/A/testOne']),
            'overlap': change(1, cases=['LedgerTests/S/testSave', 'LedgerUITests/A/testOne']),
            'no app tests': change(1, cases=['LedgerUITests/A/testTwo']),
            'unknown target': change(1, cases=['OtherTests/S/testSave', 'LedgerTests/S/testSave']),
            'no core tests': change(0, core_tests=0),
            'no static checks': change(1, static_checks=False),
        }
        for name, (first, second) in cases.items():
            with self.subTest(name), self.assertRaises(ship.Failure):
                ship.combine_shards(first, second)

    def test_combine_command_writes_the_full_record(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(ship, 'FULL_VALIDATION', Path(temp, 'full.json')):
            paths = []
            for number, proof in enumerate(self.halves(), 1):
                paths.append(Path(temp, f'{number}.json'))
                paths[-1].write_text(json.dumps(proof))
            self.assertEqual(ship.worker_main(['ship.py', 'combine', *map(str, paths)]), 0)
            self.assertEqual(json.loads(ship.FULL_VALIDATION.read_text())['interaction_tests'], 4)

    def test_a_half_records_itself_and_never_a_full_record(self):
        proof = half(2, ['LedgerUITests/A/testTwo'], ['LedgerUITests/A/testOne'])
        git = lambda *args: '' if args[0] == 'status' else SHA if args[-1] == 'HEAD' else 'tree'
        with tempfile.TemporaryFile(mode='w') as lock, tempfile.TemporaryDirectory() as temp, ExitStack() as stack:
            root = Path(temp)
            stack.enter_context(patch('builtins.open', return_value=lock))
            stack.enter_context(patch.dict(os.environ, dict(LEDGER_SHARD='2', LEDGER_CORE_FILTER='', LEDGER_UI_TESTS='')))
            for name, value in [('ROOT', root), ('STATUS', root / '.ship/status.json'),
                                ('FULL_VALIDATION', root / '.ship/full-validation.json'), ('SHARD', root / '.ship/shard.json'),
                                ('HISTORY', root / '.ship/history.json'), ('progress', ship.Progress()), ('git', git),
                                ('validate', lambda: proof), ('run_totals', lambda started: {})]:
                stack.enter_context(patch.object(ship, name, value))
            self.assertEqual(ship.worker_main(['ship.py', 'test']), 0)
            self.assertFalse(ship.FULL_VALIDATION.exists())
            self.assertEqual(json.loads(ship.SHARD.read_text())['source_sha'], SHA)


# the record must link to this repository's runs, as the cloud's GITHUB_REPOSITORY says
@patch.dict(os.environ, dict(GITHUB_REPOSITORY='example/app'))
class ReleaseTests(unittest.TestCase):
    def test_release_takes_the_record_this_run_joined(self):
        manifest = dict(repository='example/app', source_sha=SHA, tree='tree', demo_commit='demo', demo_sha256='b' * 64)
        first = ['LedgerUITests/A/testOne']
        full = ship.combine_shards(half(1, first, first), half(2, ['LedgerTests/S/testSave'], first))
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, dict(GITHUB_ACTIONS='true')), \
                patch.object(ship, 'RUN_FULL_VALIDATION', Path(temp, 'full-validation.json')), \
                patch.object(ship, 'cloud_full_validation') as cloud, patch.object(ship, 'release_validation') as validate:
            ship.RUN_FULL_VALIDATION.write_text(json.dumps(full))
            result = ship.release_validation_at_source(manifest, dict(scope='build'))
            self.assertTrue(result['release_build'])
            cloud.assert_not_called()
            validate.assert_not_called()
            # a record of another source is not taken
            ship.RUN_FULL_VALIDATION.write_text(json.dumps(dict(full, tree='other')))
            self.assertIsNone(ship.run_full_validation(manifest))

    def test_plan_runs_the_halves_only_without_a_record_and_with_tooling_that_can(self):
        manifest = dict(repository='example/app', source_sha=SHA, build=75, sha256='e' * 64)
        def download(cmd, **kwargs):
            Path(cmd[-1], 'build-manifest.json').write_text(json.dumps(manifest))
        for tooling, record, expected in (("os.environ.get('LEDGER_SHARD')", None, 'true'),
                                          ("os.environ.get('LEDGER_SHARD')", dict(scope='full'), 'false'),
                                          ('old tooling', None, 'false')):
            with self.subTest(tooling=tooling, record=bool(record)), tempfile.TemporaryDirectory() as temp, \
                    patch.dict(os.environ, dict(LEDGER_ACCEPTED_BUILD='75', GITHUB_OUTPUT=str(Path(temp, 'out')))), \
                    patch.object(ship, 'repository', return_value='example/app'), \
                    patch.object(ship, 'run', side_effect=download), patch.object(ship, 'git', return_value=tooling), \
                    patch.object(ship, 'cloud_full_validation', return_value=record):
                cloud_worker.plan_release()
                self.assertEqual(Path(temp, 'out').read_text(), f'source_sha={SHA}\nfull={expected}\n')
        with patch.dict(os.environ, dict(LEDGER_ACCEPTED_BUILD='74')), patch.object(ship, 'repository', return_value='example/app'), \
                patch.object(ship, 'run', side_effect=download), self.assertRaises(ValueError):
            cloud_worker.plan_release()


if __name__ == '__main__':
    unittest.main()
