"""Local validation and publication safety; fake archives and APIs, never real ledgers or builds."""
import hashlib
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


if __name__ == '__main__':
    unittest.main()
