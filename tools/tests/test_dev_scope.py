"""Automatic dev scope uses the package baseline and preserves all required regressions."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import dev_scope
import ship

ROOT = Path(__file__).resolve().parents[2]


class DevScopeTests(unittest.TestCase):
    def test_dev_web_form_only_has_an_optional_full_toggle(self):
        workflow = (ROOT/'.github/workflows/dev.yml').read_text()
        inputs = workflow.split('    inputs:', 1)[1].split('\npermissions:', 1)[0]
        self.assertEqual(re.findall(r'^      (\w+):', inputs, re.M), ['full'])
        self.assertIn('default: false', inputs)
        self.assertIn('LEDGER_SOURCE_SHA: ${{ github.sha }}', workflow)

    def test_calendar_source_runs_core_journal_subscription_and_narrow_regressions(self):
        plan = dev_scope.classify(['Ledger/Views/CalendarView.swift'])
        self.assertFalse(plan['full'])
        self.assertEqual(plan['core_filter'], 'CalendarMarkTests|SearchTests|SubTests')
        self.assertIn('LedgerUITests/EditInteractionTests/testGlassCalendarFixedRowsAndDaySelection', plan['ui_tests'])
        self.assertIn('LedgerUITests/EditInteractionTests/testGlassSubscriptionCalendarRangeAndSelectionAtLargeText', plan['ui_tests'])
        self.assertEqual(len(plan['ui_tests']), 9)
        self.assertEqual(len(plan['narrow_tests']), 4)
        self.assertNotIn('LedgerUITests/EditInteractionTests/testUntouchedFormClosesWithoutPrompt', plan['ui_tests'])
        self.assertTrue(dev_scope.validate_selectors(plan, ROOT))

    def test_all_reviewed_mappings_resolve_to_existing_tests(self):
        for path in dev_scope.MAPPINGS:
            with self.subTest(path=path):
                self.assertTrue(dev_scope.validate_selectors(dev_scope.classify([path]), ROOT))

    def test_shared_sources_project_and_demo_changes_expand_to_full(self):
        for path in ('Ledger/Views/Common.swift', 'Ledger/Sync/Store.swift', 'Ledger/Views/NewView.swift',
                     'LedgerKit/Sources/LedgerKit/Derived.swift', 'project.yml',
                     'tools/fixtures/manifest.json', 'LedgerTests/Fixtures/main.bean'):
            with self.subTest(path=path):
                plan = dev_scope.classify(['Ledger/Views/CalendarView.swift', path])
                self.assertTrue(plan['full'])
                self.assertIn(path, '\n'.join(plan['reasons']))

    def test_docs_and_tooling_run_static_and_tools_without_unrelated_app_tests(self):
        plan = dev_scope.classify(['docs/development/04-云端测试与发布.md', 'tools/dev_scope.py',
                                   '.github/workflows/dev.yml', 'CHANGELOG.md'])
        self.assertFalse(plan['full'])
        self.assertEqual(plan['core_filter'], '')
        self.assertEqual(plan['ui_tests'], [])

    def test_changed_tests_are_added_to_mapped_source_regressions(self):
        plan = dev_scope.classify(['Ledger/Views/CalendarView.swift', 'LedgerTests/AttachmentUploadTests.swift',
                                   'LedgerKit/Tests/LedgerKitTests/PostingOrderTests.swift'])
        self.assertFalse(plan['full'])
        self.assertIn('PostingOrderTests', plan['core_filter'].split('|'))
        self.assertIn('LedgerTests/AttachmentUploadTests', plan['ui_tests'])

    def test_no_previous_dev_runs_full_but_api_failure_does_not_masquerade_as_first_dev(self):
        with patch.object(ship, 'release_for_tag', return_value=None), patch.object(ship, 'out') as diff:
            plan = dev_scope.select('example/app', 'a'*40)
            self.assertTrue(plan['full'])
            self.assertIsNone(plan['base_sha'])
            diff.assert_not_called()
        with patch.object(ship, 'release_for_tag', side_effect=RuntimeError('HTTP 403')), \
             patch.object(ship, 'validate') as validate:
            with self.assertRaises(RuntimeError):
                dev_scope.select('example/app', 'a'*40)
            validate.assert_not_called()

    def test_diff_covers_multiple_commits_and_deleted_files_since_the_package(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def git(*args):
                return subprocess.check_output(['git', '-C', temp, *args], text=True).strip()
            def commit(message):
                git('add', '.')
                git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                    '-c', 'commit.gpgsign=false', 'commit', '-qm', message)
                return git('rev-parse', 'HEAD')
            git('init', '-q')
            (root/'Ledger/Views').mkdir(parents=True)
            (root/'LedgerTests').mkdir()
            (root/'LedgerTests/RemovedTests.swift').write_text('final class RemovedTests {}')
            (root/'Ledger/Views/CalendarView.swift').write_text('// original fictional calendar')
            base = commit('fictional previous package')
            (root/'Ledger/Views/CalendarView.swift').write_text('// first PR calendar change')
            commit('fictional first PR')
            (root/'CHANGELOG.md').write_text('fictional second PR')
            (root/'LedgerTests/RemovedTests.swift').unlink()
            head = commit('fictional second PR')
            def download(repo, tag, folder, files):
                self.assertEqual(files, ('build-manifest.json',))
                (folder/'build-manifest.json').write_text(json.dumps(dict(repository=repo, source_sha=base)))
            with patch.object(ship, 'ROOT', root), patch.object(ship, 'release_for_tag', return_value=dict(tag_name='dev')), \
                 patch.object(ship, 'download', side_effect=download), patch.object(ship, 'tag_sha', return_value=base):
                plan = dev_scope.select('example/app', head)
                self.assertEqual(plan['base_sha'], base)
                self.assertEqual(plan['source_sha'], head)
                self.assertEqual(plan['paths'], ['CHANGELOG.md', 'Ledger/Views/CalendarView.swift', 'LedgerTests/RemovedTests.swift'])
                self.assertTrue(plan['full'], 'Deleted/missing tests must expand rather than silently disappear')

    def test_unrelated_history_and_stale_mappings_expand_to_full(self):
        def download(repo, tag, folder, files):
            (folder/'build-manifest.json').write_text(json.dumps(dict(repository=repo, source_sha='a'*40)))
        with patch.object(ship, 'release_for_tag', return_value={"tag_name": "dev"}), \
             patch.object(ship, 'download', side_effect=download), patch.object(ship, 'tag_sha', return_value='a'*40), \
             patch.object(dev_scope.subprocess, 'run') as ancestry:
            ancestry.return_value.returncode = 1
            self.assertTrue(dev_scope.select('example/app', 'b'*40)['full'])
            ancestry.return_value.returncode = 0
            with patch.object(ship, 'out', side_effect=['Ledger/Views/CalendarView.swift\0', '']), \
                 patch.object(dev_scope, 'validate_selectors', return_value=False):
                plan = dev_scope.select('example/app', 'b'*40)
                self.assertTrue(plan['full'])
                self.assertIn('规则已过期', plan['reasons'][-1])

    def test_mismatched_baseline_is_refused_without_guessing(self):
        for record, tag in ((dict(repository='other/app', source_sha='a'*40), 'a'*40),
                            (dict(repository='example/app', source_sha='bad'), 'a'*40),
                            (dict(repository='example/app', source_sha='a'*40), 'b'*40)):
            def download(repo, tag, folder, files):
                (folder/'build-manifest.json').write_text(json.dumps(record))
            with self.subTest(record=record, tag=tag), patch.object(ship, 'release_for_tag', return_value={'tag_name': 'dev'}), \
                 patch.object(ship, 'download', side_effect=download), patch.object(ship, 'tag_sha', return_value=tag):
                with self.assertRaises(ship.Failure):
                    dev_scope.select('example/app', 'c'*40)

    def test_calendar_executes_two_devices_keeps_both_results_and_restores_environment(self):
        plan = dict(dev_scope.classify(['Ledger/Views/CalendarView.swift']), base_sha='a'*40, source_sha='b'*40)
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def targeted():
                calls.append({key: os.environ.get(key) for key in ('LEDGER_CORE_FILTER', 'LEDGER_UI_TESTS', 'LEDGER_SIMULATOR_DEVICE')})
                (root/'interaction-tests.xcresult').mkdir()
                (root/'interaction-tests.log').write_text('fixture passed')
                return dict(scope='build', selected_interaction=dict(passed=len(calls), simulator=str(len(calls))))
            with patch.object(ship, 'ROOT', root), patch.object(ship, 'validate_targeted', side_effect=targeted), \
                 patch.dict(os.environ, dict(LEDGER_CORE_FILTER='original', LEDGER_UI_TESTS='original', LEDGER_SIMULATOR_DEVICE='original')):
                proof = dev_scope.validate(plan)
                self.assertEqual(os.environ['LEDGER_CORE_FILTER'], 'original')
                self.assertEqual(os.environ['LEDGER_SIMULATOR_DEVICE'], 'original')
                self.assertEqual(calls[0]['LEDGER_CORE_FILTER'], plan['core_filter'])
                self.assertEqual(calls[1]['LEDGER_CORE_FILTER'], '')
                self.assertEqual(calls[1]['LEDGER_SIMULATOR_DEVICE'], 'iPhone SE (3rd generation)')
                self.assertTrue((root/'interaction-tests-regular.xcresult').is_dir())
                self.assertTrue((root/'interaction-tests.xcresult').is_dir())
                self.assertEqual(proof['selected_interaction']['passed'], 1)
                self.assertEqual(proof['additional_interaction'][0]['passed'], 2)
                self.assertEqual(proof['scope'], 'build')
                self.assertEqual(proof['auto_selection'], plan)

    def test_narrow_failure_propagates_and_full_fallback_really_runs_full(self):
        plan = dev_scope.classify(['Ledger/Views/CalendarView.swift'])
        with tempfile.TemporaryDirectory() as temp, patch.object(ship, 'ROOT', Path(temp)), \
             patch.object(ship, 'validate_targeted', side_effect=[dict(scope='build'), ship.Failure('narrow failed')]):
            with self.assertRaises(ship.Failure):
                dev_scope.validate(plan)
        with patch.object(ship, 'validate', return_value=dict(scope='full')) as full, \
             patch.object(ship, 'validate_targeted') as targeted:
            proof = dev_scope.validate(dev_scope.classify(['Ledger/Sync/Store.swift']))
            self.assertEqual(proof['scope'], 'full')
            full.assert_called_once_with()
            targeted.assert_not_called()


if __name__ == '__main__':
    unittest.main()
