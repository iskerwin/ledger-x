"""Local validation and publication safety; fake archives and APIs, never real ledgers or builds."""
import hashlib
import io
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools'))
import ship


class ShipTests(unittest.TestCase):
    def fixture(self, folder):
        with zipfile.ZipFile(folder/'Ledger.ipa', 'w') as archive:
            archive.writestr('Payload/Ledger.app/Info.plist', plistlib.dumps(dict(
                CFBundleShortVersionString='1.0.0', CFBundleVersion='4', CFBundleIdentifier='com.iskerwin.ledger')))
            archive.writestr('Payload/Ledger.app/Demo/main.bean', '; fictional sample')
            archive.writestr('Payload/Ledger.app/_CodeSignature/CodeResources', 'signature fixture')
        data = (folder/'Ledger.ipa').read_bytes()
        manifest = dict(version='1.0.0', build='4', repository='example/app', source_sha='a'*40,
                        tree='tree', sha256=hashlib.sha256(data).hexdigest(), size=len(data))
        proof = dict(source_sha='a'*40, tree='tree', validator='local', core_tests=308, interaction_tests=32,
                     reports='Reports match Beancount (5 valuations, 9 months, 21 month ends)',
                     xcode='Xcode 27.1', simulator='iPhone 17 · iOS 27.0')
        return manifest, proof

    def test_selected_versions_are_strictly_increasing(self):
        self.assertEqual(ship.next_version('1.2.3', 'patch'), '1.2.4')
        self.assertEqual(ship.next_version('1.2.3', 'minor'), '1.3.0')
        self.assertEqual(ship.next_version('1.2.3', 'major'), '2.0.0')
        self.assertEqual(ship.next_version('1.2.3', '3.0.0'), '3.0.0')
        for version in ['1.2.3', '1.2.2', 'v2.0.0', '02.0.0', '2.0.0\n', '$(whoami)', '2.0', '']:
            with self.subTest(version=version), self.assertRaises(ValueError):
                ship.next_version('1.2.3', version)

    def test_build_numbers_rise_past_every_release(self):
        releases = [dict(body='版本 1.0.0 · 构建 3 · main abc'), dict(body='版本 0.9.0 · 构建 12.2 · main def'),
                    dict(body=None), dict(body='没有构建号')]
        self.assertEqual(ship.next_build(releases), '13')
        self.assertEqual(ship.next_build([]), '1')

    def test_build_numbers_rise_past_every_build_the_sources_listed(self):
        # the dev release's notes were replaced by a build numbered 1; the sources' history still had 11
        releases = [dict(tag_name='dev', body='版本 1.0.2 · 构建 1 · main abc'), dict(tag_name='v1.0.1', body='版本 1.0.1 · 构建 6 · main def')]
        log = '-        "buildVersion": "11",\n+        "buildVersion": "1",\n         "buildVersion": "6",\n'
        self.assertEqual(ship.source_builds(log), ['11', '1', '6'])
        self.assertEqual(ship.next_build(releases, ship.source_builds(log)), '12')

    def test_a_short_release_list_is_read_again(self):
        full = json.dumps([[dict(tag_name='dev'), dict(tag_name='v1.0.1')]])
        answers = [json.dumps([[]]), json.dumps([[]]), full]
        with patch.object(ship, 'out', side_effect=lambda cmd: answers.pop(0)), patch.object(ship.time, 'sleep') as slept:
            releases = ship.fetch_releases('example/ledger-x', {'dev', 'v1.0.1'})
        self.assertEqual([r['tag_name'] for r in releases], ['dev', 'v1.0.1'])
        self.assertEqual(slept.call_count, 2)
        with patch.object(ship, 'out', return_value=json.dumps([[]])), patch.object(ship.time, 'sleep'):
            with self.assertRaises(ship.Failure):
                ship.fetch_releases('example/ledger-x', {'dev'})

    def test_a_release_list_missing_a_tagged_release_stops_publishing(self):
        tags = ship.release_tags('aaa\trefs/tags/dev\nbbb\trefs/tags/v1.0.1\nccc\trefs/tags/v1.0.1^{}\nddd\trefs/tags/other\n')
        self.assertEqual(tags, {'dev', 'v1.0.1'})
        with self.assertRaises(ship.Failure):
            ship.check_release_list([], tags)
        with self.assertRaises(ship.Failure):
            ship.check_release_list([dict(tag_name='dev')], tags)
        ship.check_release_list([dict(tag_name='dev'), dict(tag_name='v1.0.1')], tags)
        ship.check_release_list([], set())

    def test_package_rejects_changed_bytes_identity_and_proof(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            manifest, proof = self.fixture(folder)
            ship.verify_package(folder, manifest, proof, 'example/app')
            for updates in [dict(version='1.0.1'), dict(build='5'), dict(sha256='invalid'),
                            dict(size=1), dict(source_sha='b'*40), dict(tree='other'), dict(repository='other/repo')]:
                with self.subTest(updates=updates), self.assertRaises(ValueError):
                    ship.verify_package(folder, dict(manifest, **updates), proof, 'example/app')

    def test_package_needs_complete_local_validation(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            manifest, proof = self.fixture(folder)
            for updates in [dict(core_tests=0), dict(interaction_tests=0), dict(reports=''),
                            dict(reports='beancount: 1 errors'), dict(validator='ci')]:
                with self.subTest(updates=updates), self.assertRaises(ValueError):
                    ship.verify_package(folder, manifest, dict(proof, **updates), 'example/app')

    def test_test_totals_come_from_the_last_summary(self):
        log = ('Executed 10 tests, with 0 failures (0 unexpected) in 0.1 seconds\n'
               'Executed 308 tests, with 2 failures (0 unexpected) in 15.2 seconds\n')
        self.assertEqual(ship.executed(log), (308, 2))
        self.assertEqual(ship.executed('Executed 1 test, with 1 failure (0 unexpected)'), (1, 1))
        with self.assertRaises(ship.Failure):
            ship.executed('** BUILD INTERRUPTED **')

    def test_simulator_prefers_matching_runtime_and_iphone(self):
        phone = lambda name: dict(name=name, identifier=f'com.apple.{name}')
        runtimes = [
            dict(name='iOS 26.0', version='26.0', platform='iOS', isAvailable=True, identifier='ios26',
                 supportedDeviceTypes=[phone('iPhone 17')]),
            dict(name='iOS 27.0', version='27.0', platform='iOS', isAvailable=True, identifier='ios27',
                 supportedDeviceTypes=[phone('iPad Pro'), phone('iPhone 16e'), phone('iPhone 16')]),
            dict(name='iOS 28.0', version='28.0', platform='iOS', isAvailable=False, identifier='ios28',
                 supportedDeviceTypes=[phone('iPhone 17')]),
        ]
        runtime, device = ship.select_device(runtimes, '27.0')
        self.assertEqual((runtime['identifier'], device['name']), ('ios27', 'iPhone 16'))
        # No runtime for the SDK: the newest available one is used.
        self.assertEqual(ship.select_device(runtimes, '27.1')[0]['identifier'], 'ios27')
        # A runtime matching the SDK but with only unusual models gives way to one with a regular iPhone.
        duo = dict(name='iOS 27.1', version='27.1', platform='iOS', isAvailable=True, identifier='ios271',
                   supportedDeviceTypes=[phone('iPhone Duo')])
        runtime, device = ship.select_device([*runtimes, duo], '27.1')
        self.assertEqual((runtime['identifier'], device['name']), ('ios27', 'iPhone 16'))
        with self.assertRaises(ship.Failure):
            ship.select_device([dict(runtimes[2])], '28.0')

    def test_published_version_is_never_replaced_or_moved(self):
        manifest = dict(version='1.0.0', source_sha='a'*40)
        for existing in [dict(release=dict(draft=False), tag=True), dict(release=None, tag=True)]:
            with self.subTest(existing=existing), \
                 patch.object(ship, 'release_for_tag', return_value=existing['release']), \
                 patch.object(ship, 'tag_exists', return_value=existing['tag']), \
                 patch.object(ship, 'run') as mutation:
                with self.assertRaises(ValueError):
                    ship.publish('example/app', 'v1.0.0', Path('.'), manifest, Path('notes.md'))
                mutation.assert_not_called()

    def test_release_publishes_the_accepted_dev_package_unchanged(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)
            manifest, proof = self.fixture(source)
            manifest['repository'] = 'example/app'
            (source/'build-manifest.json').write_text(json.dumps(manifest))
            (source/'validation-evidence.json').write_text(json.dumps(proof))
            (source/'release-notes.md').write_text('dev notes')
            def download(repo, tag, folder, files=ship.FILES):
                self.assertEqual(tag, 'dev')
                for name in files: (folder/name).write_bytes((source/name).read_bytes())
            with patch.object(ship, 'repository', return_value='example/app'), \
                 patch.object(ship, 'download', side_effect=download), \
                 patch.object(ship, 'verify_source'), \
                 patch.object(ship, 'tag_sha', return_value='a'*40), \
                 patch.object(ship, 'git', return_value='## 1.0.0\n### 新增\n- 记账。'), \
                 patch.object(ship, 'update_sources'), \
                 patch.object(ship, 'publish', side_effect=lambda *args: calls.append((*args[:4], args[4].read_text()))), \
                 patch('builtins.print'):
                calls = []
                ship.ship_release()
                [(repo, tag, folder, published, notes)] = calls
                self.assertEqual((repo, tag), ('example/app', 'v1.0.0'))
                self.assertEqual(published['sha256'], manifest['sha256'])
                self.assertIn('Ledger X 1.0.0 正式版', notes)
            with patch.object(ship, 'repository', return_value='example/app'), \
                 patch.object(ship, 'download', side_effect=download), \
                 patch.object(ship, 'verify_source'), \
                 patch.object(ship, 'tag_sha', return_value='b'*40), \
                 patch.object(ship, 'publish') as publish:
                with self.assertRaises(ValueError):
                    ship.ship_release()
                publish.assert_not_called()

    def test_usage_errors_do_nothing(self):
        for argv in (['ship.py'], ['ship.py', 'deploy'], ['ship.py', 'version'], ['ship.py', 'dev', 'extra']):
            with self.subTest(argv=argv):
                self.assertEqual(ship.main(argv), 2)


class WatchTests(unittest.TestCase):
    """`ship.py watch`: what a run records and how its progress is read back; fake logs, no builds."""

    TESTS_LOG = ("Test Case '-[UITests.Edit testA]' started.\n"
                 "Test Case '-[UITests.Edit testA]' passed (1.0 seconds).\n"
                 "Test Case '-[UITests.Edit testB]' started.\n"
                 "Test Case '-[UITests.Edit testB]' failed (2.0 seconds).\n"
                 "Test Case '-[UITests.Edit testC]' started.\n")

    def test_test_logs_give_passed_failed_and_the_running_case(self):
        info = ship.log_progress('interaction-tests.log', self.TESTS_LOG)
        self.assertEqual((info['passed'], info['failed'], info['current']), (1, ['UITests.Edit testB'], 'UITests.Edit testC'))

    def test_build_logs_give_the_steps_and_the_last_file(self):
        log = ('note: Using global toolchain override\n'
               'SwiftCompile normal arm64 Compiling\\ Store.swift /tmp/Ledger/Sync/Store.swift\n'
               '    cd /tmp\n'
               'Ld /tmp/Ledger.app/Ledger normal\n'
               'SwiftCompile normal arm64 /tmp/Ledger/Views/OverviewView.swift\n')
        self.assertEqual(ship.log_progress('build.log', log), dict(steps=3, last='SwiftCompile OverviewView.swift'))

    def state(self, **extra):
        state = dict(command='dev', pid=1, started=1000.0, log='interaction-tests.log', result=None, message='',
                     stages=[dict(name='静态检查与流程回归', started=1000.0, ended=1003.0),
                             dict(name='LedgerKit 核心测试', started=1003.0, ended=1130.0, note='333 项通过'),
                             dict(name='附件与交互测试（不并行，约 10 分钟）', started=1130.0)])
        state.update(extra)
        return state

    def test_a_running_dev_shows_done_current_and_coming_stages(self):
        screen = ship.render(self.state(), {'interaction-tests.log': 64}, {'interaction-tests.log': self.TESTS_LOG}, 1530.0)
        self.assertIn('发布开发版（dev） · 进行中，已用 8:50', screen)
        self.assertIn('✓ LedgerKit 核心测试', screen)
        self.assertIn('333 项通过', screen)
        self.assertIn('▶ 附件与交互测试', screen)
        self.assertIn('1 / 64 通过 · 1 失败', screen)
        self.assertIn('失败：UITests.Edit testB', screen)
        self.assertIn('当前：UITests.Edit testC', screen)
        # stages not reached yet are listed; those already passed are not listed twice
        self.assertIn('○ 编译 Release 安装包', screen)
        self.assertIn('○ 更新 IPA 源', screen)
        self.assertNotIn('○ 静态检查', screen)
        self.assertIn('日志：interaction-tests.log', screen)

    def test_a_finished_run_shows_its_result_and_nothing_still_to_come(self):
        failed = self.state(result='failed', ended=1600.0, message='✗ 交互测试未通过\n未推送、未发布。')
        failed['stages'][-1].update(ended=1600.0, failed=True)
        screen = ship.render(failed, {}, {}, 9999.0)
        self.assertIn('✗ 失败，用时 10:00', screen)
        self.assertIn('✗ 附件与交互测试', screen)
        self.assertIn('未推送、未发布。', screen)
        self.assertNotIn('○', screen)
        self.assertNotIn('日志：', screen)

    def test_a_run_whose_process_is_gone_is_shown_as_interrupted(self):
        screen = ship.render(self.state(), {}, {}, 1200.0, alive=False)
        self.assertIn('已中断', screen)
        self.assertIn('✗ 附件与交互测试', screen)

    def test_a_run_records_its_stages_result_and_totals(self):
        with tempfile.TemporaryDirectory() as temp, \
                patch.object(ship, 'STATUS', Path(temp)/'status.json'), patch.object(ship, 'HISTORY', Path(temp)/'history.json'):
            run = ship.Progress()
            run.begin('test')
            run.enter('LedgerKit 核心测试')
            run.logging('swift-tests.log')
            run.note('333 项通过')
            run.enter('附件与交互测试')
            run.finish(True, totals={'swift-tests.log': 333})
            state = json.loads((Path(temp)/'status.json').read_text())
            self.assertEqual(state['result'], 'passed')
            self.assertEqual([s['name'] for s in state['stages']], ['LedgerKit 核心测试', '附件与交互测试'])
            self.assertTrue(all('ended' in s for s in state['stages']))
            self.assertEqual(state['stages'][0]['note'], '333 项通过')
            self.assertEqual(json.loads((Path(temp)/'history.json').read_text()), {'swift-tests.log': 333})
            # a failed run keeps the totals of the last passing one
            run.begin('test')
            run.enter('LedgerKit 核心测试')
            run.finish(False, '✗ 核心测试失败', totals={'swift-tests.log': 1})
            self.assertTrue(json.loads((Path(temp)/'status.json').read_text())['stages'][-1]['failed'])
            self.assertEqual(json.loads((Path(temp)/'history.json').read_text()), {'swift-tests.log': 333})

    def test_watch_without_any_run_says_so(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(ship, 'STATUS', Path(temp)/'none.json'), \
                patch('sys.stdout', new_callable=io.StringIO) as screen:
            self.assertEqual(ship.main(['ship.py', 'watch', '--once']), 0)
        self.assertIn('还没有 ship.py 的运行记录', screen.getvalue())


if __name__ == '__main__':
    unittest.main()
