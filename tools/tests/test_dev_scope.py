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
    def test_dev_web_form_has_no_parameters_or_full_toggle(self):
        workflow = (ROOT/'.github/workflows/dev.yml').read_text()
        self.assertNotIn('    inputs:', workflow)
        self.assertNotIn('inputs.full', workflow)
        self.assertIn('LEDGER_SOURCE_SHA: ${{ github.sha }}', workflow)

    def test_calendar_source_runs_core_journal_and_subscription_regressions(self):
        plan = dev_scope.classify(['Ledger/Views/CalendarView.swift'])
        self.assertFalse(plan['core_all'])
        self.assertEqual(plan['core_filter'], 'CalendarMarkTests|SearchTests|SubTests')
        self.assertIn('LedgerUITests/EditInteractionTests/testGlassCalendarFixedRowsAndDaySelection', plan['ui_tests'])
        self.assertIn('LedgerUITests/EditInteractionTests/testGlassSubscriptionCalendarRangeAndSelectionAtLargeText', plan['ui_tests'])
        self.assertEqual(set(plan['ui_tests']), set(dev_scope.MAPPINGS['Ledger/Views/CalendarView.swift']['ui']) | set(dev_scope.CRITICAL_UI))
        self.assertEqual(plan['narrow_tests'], [])
        self.assertNotIn('LedgerUITests/EditInteractionTests/testTransferFeeCancelCompleteAndKeyboardDismissal', plan['ui_tests'])
        self.assertTrue(dev_scope.validate_selectors(plan, ROOT))

    def test_all_reviewed_mappings_resolve_to_existing_tests(self):
        for path in dev_scope.MAPPINGS:
            with self.subTest(path=path):
                self.assertTrue(dev_scope.validate_selectors(dev_scope.classify([path]), ROOT))

    def test_unknown_sources_expand_only_the_affected_modules(self):
        for path in ('Ledger/Views/Common.swift', 'Ledger/Sync/Store.swift', 'Ledger/Views/NewView.swift',
                     'LedgerKit/Sources/LedgerKit/Derived.swift', 'project.yml',
                     'tools/fixtures/manifest.json', 'LedgerTests/Fixtures/main.bean'):
            with self.subTest(path=path):
                plan = dev_scope.classify(['Ledger/Views/CalendarView.swift', path])
                self.assertNotIn('full', plan)
                self.assertNotIn('LedgerUITests', plan['app_targets'])
                if path.startswith('LedgerKit/'):
                    self.assertTrue(plan['core_all'])
                    self.assertEqual(plan['app_targets'], [])
                elif path.startswith('Ledger/Sync/'):
                    self.assertTrue(plan['core_all'])
                    self.assertIn('LedgerTests', plan['app_targets'])
                elif path.startswith('tools/fixtures/'):
                    self.assertTrue(plan['core_all'])
                    self.assertEqual(plan['app_targets'], [])
                    self.assertIn('LedgerTests/DemoBootstrapTests', plan['ui_tests'])
                else:
                    self.assertFalse(plan['core_all'])
                    self.assertEqual(plan['app_targets'], ['LedgerTests'] if path.startswith('LedgerTests/Fixtures/') else [])
                self.assertIn(path, '\n'.join(plan['reasons']))

    def test_docs_and_tooling_run_static_and_tools_without_unrelated_app_tests(self):
        plan = dev_scope.classify(['docs/development/04-云端测试与发布.md', 'tools/dev_scope.py',
                                   '.github/workflows/dev.yml', 'CHANGELOG.md'])
        self.assertFalse(plan['core_all'])
        self.assertEqual(plan['app_targets'], [])
        self.assertEqual(plan['core_filter'], '')
        self.assertEqual(plan['ui_tests'], [])

    def test_changed_tests_are_added_to_mapped_source_regressions(self):
        plan = dev_scope.classify(['Ledger/Views/CalendarView.swift', 'LedgerTests/AttachmentUploadTests.swift',
                                   'LedgerKit/Tests/LedgerKitTests/PostingOrderTests.swift'])
        self.assertFalse(plan['core_all'])
        self.assertIn('PostingOrderTests', plan['core_filter'].split('|'))
        self.assertIn('LedgerTests/AttachmentUploadTests', plan['ui_tests'])

    def test_first_dev_selects_modules_but_api_failure_does_not_masquerade_as_first_dev(self):
        with patch.object(ship, 'release_for_tag', return_value=None), \
             patch.object(ship, 'out', return_value='LedgerKit/Sources/LedgerKit/Derived.swift\0') as diff:
            plan = dev_scope.select('example/app', 'a'*40)
            self.assertTrue(plan['core_all'])
            self.assertNotIn('full', plan)
            self.assertIsNone(plan['base_sha'])
            diff.assert_called_once_with(['git', 'ls-files', '-z'])
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
            (root/'LedgerTests/ExistingTests.swift').write_text('final class ExistingTests: XCTestCase {}')
            (root/'LedgerUITests').mkdir()
            (root/'LedgerUITests/EditInteractionTests.swift').write_text(
                'final class EditInteractionTests: XCTestCase {\n' + '\n'.join(
                    f'func {name}() {{}}' for name in (*dev_scope.CALENDAR_TESTS,
                        *(selector.rsplit('/', 1)[1] for selector in dev_scope.CRITICAL_UI))) + '\n}')
            kit = root/'LedgerKit/Tests/LedgerKitTests'
            kit.mkdir(parents=True)
            for name in ('CalendarMarkTests', 'SearchTests', 'SubTests'):
                (kit/f'{name}.swift').write_text(f'final class {name}: XCTestCase {{}}')
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
                self.assertNotIn('full', plan)
                self.assertEqual(plan['app_targets'], ['LedgerTests'])
                self.assertIn('LedgerTests/ExistingTests', plan['ui_tests'])
                self.assertNotIn('LedgerTests/RemovedTests', plan['ui_tests'])

    def test_unrelated_history_and_stale_mappings_expand_to_current_modules(self):
        def download(repo, tag, folder, files):
            (folder/'build-manifest.json').write_text(json.dumps(dict(repository=repo, source_sha='a'*40)))
        with patch.object(ship, 'release_for_tag', return_value={"tag_name": "dev"}), \
             patch.object(ship, 'download', side_effect=download), patch.object(ship, 'tag_sha', return_value='a'*40), \
             patch.object(dev_scope.subprocess, 'run') as ancestry:
            ancestry.return_value.returncode = 1
            with patch.object(ship, 'out', return_value='LedgerKit/Sources/LedgerKit/Derived.swift\0'):
                self.assertTrue(dev_scope.select('example/app', 'b'*40)['core_all'])
            ancestry.return_value.returncode = 0
            with patch.object(ship, 'out', side_effect=['Ledger/Views/CalendarView.swift\0', '']), \
                 patch.object(dev_scope, 'validate_selectors', return_value=False):
                with self.assertRaisesRegex(ship.Failure, '界面回归映射已失效'):
                    dev_scope.select('example/app', 'b'*40)

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

    def test_narrow_failure_propagates_and_module_expansion_never_runs_full(self):
        plan = dev_scope.classify(['Ledger/Views/CalendarView.swift'])
        with tempfile.TemporaryDirectory() as temp, patch.object(ship, 'ROOT', Path(temp)), \
             patch.object(ship, 'validate_targeted', side_effect=[dict(scope='build'), ship.Failure('narrow failed')]):
            with self.assertRaises(ship.Failure):
                dev_scope.validate(plan)
        with patch.object(ship, 'validate') as full, \
             patch.object(ship, 'validate_targeted', return_value=dict(scope='build')) as targeted:
            proof = dev_scope.validate(dev_scope.classify(['Ledger/Sync/Store.swift']))
            self.assertEqual(proof['scope'], 'build')
            full.assert_not_called()
            targeted.assert_called_once_with()

    def test_empty_module_is_refused_instead_of_counting_zero_as_passed(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ship.Failure):
                dev_scope.expand_modules(dev_scope.classify(['Ledger/Sync/Store.swift']), Path(temp))

    def test_unmapped_views_and_build_settings_only_add_three_critical_flows(self):
        for path in ('Ledger/Views/NewView.swift', 'project.yml', 'Ledger/Views/GuideView.swift', 'Ledger/unknown.json'):
            with self.subTest(path=path):
                plan = dev_scope.expand_modules(dev_scope.classify([path]), ROOT)
                self.assertEqual(set(plan['ui_tests']), set(dev_scope.CRITICAL_UI))
                self.assertEqual(plan['app_targets'], [])
                self.assertFalse(plan['core_all'])

    def test_current_feature_groups_never_pull_in_the_entire_ui_class(self):
        plan = dev_scope.expand_modules(dev_scope.classify([
            'Ledger/Views/JournalView.swift', 'Ledger/Views/SubPickers.swift', 'Ledger/Views/CalendarView.swift',
            'Ledger/Sync/Demo.swift', 'LedgerKit/Sources/LedgerKit/Search.swift', 'project.yml']), ROOT)
        self.assertEqual(plan['app_targets'], [])
        self.assertIn('LedgerTests/DemoBootstrapTests', plan['ui_tests'])
        self.assertIn('DemoRepositoryTests', plan['core_filter'].split('|'))
        self.assertIn('LedgerUITests/EditInteractionTests/testJournalSearchAppliesOnSubmitAndClearRestores', plan['ui_tests'])
        self.assertNotIn('LedgerUITests/EditInteractionTests', plan['ui_tests'])
        self.assertNotIn('LedgerUITests/ColorInteractionTests', plan['ui_tests'])
        self.assertEqual(len([value for value in plan['ui_tests'] if value.startswith('LedgerUITests/')]), 14)



class PRProofTests(unittest.TestCase):
    PLAN = dict(base_sha='b'*40, source_sha='a'*40, core_filter='SearchTests',
                ui_tests=['LedgerUITests/EditInteractionTests/testQuickAndFullFormsShareAmount'], narrow_tests=[])
    PROOF = dict(tree='tree', source_sha='m'*40, run_url='https://github.com/example/app/actions/runs/9',
                 auto_selection=dict(PLAN, source_sha='m'*40),
                 selected_core=dict(filter='SearchTests', passed=5),
                 selected_interaction=dict(selectors=PLAN['ui_tests'], passed=1, simulator='iPhone'))

    def test_reused_only_for_the_same_tree_baseline_and_selection(self):
        import dev_scope
        kept = dev_scope.pr_proof(self.PROOF, self.PLAN, 'tree', 'example/app')
        self.assertEqual(kept['selected_core'], self.PROOF['selected_core'])
        self.assertEqual(kept['auto_selection'], self.PLAN)
        self.assertEqual(kept['reused_pr']['run_url'], self.PROOF['run_url'])
        for change in (dict(tree='other'), dict(run_url='https://github.com/other/app/actions/runs/9'), dict(run_url='')):
            with self.subTest(change=change):
                self.assertIsNone(dev_scope.pr_proof(dict(self.PROOF, **change), self.PLAN, 'tree', 'example/app'))
        for key, value in (('base_sha', 'c'*40), ('core_filter', '.*'), ('ui_tests', []), ('narrow_tests', ['x'])):
            with self.subTest(key=key):
                self.assertIsNone(dev_scope.pr_proof(self.PROOF, dict(self.PLAN, **{key: value}), 'tree', 'example/app'))

    def test_lookup_skips_runs_without_a_live_proof(self):
        import dev_scope
        import ship
        def api(path):
            if path.endswith('per_page=30'):
                return dict(workflow_runs=[dict(id=1), dict(id=2)])
            run = path.split('/runs/')[1].split('/')[0]
            return dict(artifacts=[dict(name=f'ledger-pr-proof-{run}', expired=run == '1')])
        def download(cmd, **kwargs):
            Path(cmd[-1], 'pr-proof.json').write_text(json.dumps(self.PROOF))
        with patch.object(ship, 'gh_api', side_effect=api), patch.object(ship, 'run', side_effect=download) as run:
            kept = dev_scope.reusable_pr_proof('example/app', self.PLAN, 'tree')
        self.assertEqual(kept['reused_pr']['source_sha'], 'm'*40)
        self.assertEqual(run.call_count, 1)
        self.assertIn('2', run.call_args.args[0])


if __name__ == '__main__':
    unittest.main()
