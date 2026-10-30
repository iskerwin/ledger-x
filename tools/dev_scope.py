#!/usr/bin/env python3
"""Development-release test selection. PR selection remains in pr_scope.py."""
from contextlib import contextmanager
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

import pr_scope
import scope_guard

# Explicitly reviewed dependencies, not a guess based on Swift/test name similarity.
# UI coverage is explicit: missing mappings never select an entire UI test bundle.
CRITICAL_UI = tuple('LedgerUITests/EditInteractionTests/' + name for name in (
    'testExistingExpenseTypeRoundTripClosesWithoutPrompt',
    'testQuickAndFullFormsShareAmount',
    'testUntouchedFormClosesWithoutPrompt',
))
CALENDAR_TESTS = (
    'testTheCalendarTakesTheQuickFiltersPlaceAndKeepsItsHeight',
    'testTheCalendarDotsSitUnderTheirDate',
    'testGlassCalendarFixedRowsAndDaySelection',
    'testGlassCalendarFixedRowsAndDaySelectionAtLargeText',
    'testGlassSubscriptionCalendarRangeAndSelection',
    'testGlassSubscriptionCalendarRangeAndSelectionAtLargeText',
    'testGlassCalendarAccessibilityTextRemainsReadable',
    'testCalendarUsesFullRowWidthWithoutHint',
    'testCalendarFiguresSitInEqualColumns',
)
# no layout depends on the device any more, so nothing runs on the narrow screen (Kerwin, 2026-10-29)
NARROW_CALENDAR_TESTS = ()
MAPPINGS = {
    'Ledger/Views/CalendarView.swift': dict(
        core=('CalendarMarkTests', 'SearchTests', 'SubTests'),
        ui=tuple('LedgerUITests/EditInteractionTests/' + name for name in CALENDAR_TESTS),
        narrow=tuple('LedgerUITests/EditInteractionTests/' + name for name in NARROW_CALENDAR_TESTS),
        reason='共用月历：明细、订阅、系统月历回退、常用/较大字号'),
    'Ledger/Views/SyncAppearance.swift': dict(
        core=(), ui=('LedgerTests/SyncAppearanceTests',), narrow=(),
        reason='同步状态显示及其颜色/图标规则'),
}
MAPPINGS.update({
    'Ledger/Views/JournalView.swift': dict(
        core=('CalendarMarkTests', 'SearchTests', 'SubTests'),
        ui=MAPPINGS['Ledger/Views/CalendarView.swift']['ui'] + tuple('LedgerUITests/EditInteractionTests/' + name for name in (
            'testJournalSearchAppliesOnSubmitAndClearRestores', 'testTheJournalScrollsToTheEntryJustSaved')),
        narrow=MAPPINGS['Ledger/Views/CalendarView.swift']['narrow'],
        reason='明细：月历、搜索与保存后定位'),
    'Ledger/Views/SubPickers.swift': dict(
        core=('SubTests',),
        ui=tuple('LedgerUITests/EditInteractionTests/' + name for name in CALENDAR_TESTS[4:6]),
        narrow=(),
        reason='订阅日期选择：常用/较大字号'),
    'Ledger/Sync/Demo.swift': dict(
        core=('DemoRepositoryTests',), ui=('LedgerTests/DemoBootstrapTests',), narrow=(),
        reason='演示加载及切换后的文件、队列隔离'),
    'LedgerKit/Sources/LedgerKit/DemoRepository.swift': dict(
        core=('DemoRepositoryTests',), ui=('LedgerTests/DemoBootstrapTests',), narrow=(),
        reason='演示仓库读取和 App 加载回归'),
    'LedgerKit/Sources/LedgerKit/Search.swift': dict(
        core=('SearchTests',), ui=('LedgerUITests/EditInteractionTests/testJournalSearchAppliesOnSubmitAndClearRestores',),
        narrow=(), reason='查询解析和明细搜索提交/清除'),
})
SAFE_FILES = {'README.md', 'AGENTS.md', 'CLAUDE.md', 'CHANGELOG.md'}


def _ui(*names):
    return tuple('LedgerUITests/EditInteractionTests/' + name for name in names)


# Shared components: these files hold what many pages use, so a change selects the UI tests of the component it
# touches (found from the diff: the top-level type, or the function of an `extension View`), not of the whole file,
# which would be ~25 UI tests. Reviewed by hand like MAPPINGS. A change to an unmapped component says so in the
# plan; its full coverage is the release run (#34 changed PeriodBar and the month bar test only ran there).
MONTH_BAR_UI = _ui('testMonthArrowsHaveAFullSizeTapArea', 'testAMonthBarSwipesToTheNextMonth', 'testTheOverviewPeriodPickerSlides',
                   'testMonthSwitchersShowTheWayBackBesideTheTitle', 'testTheMonthTitleStaysPutAtLargerTextSizes',
                   'testTheOverviewMonthBarKeepsItsArrowsBesideTheMonth', 'testTheOverviewCardKeepsItsHeightWithTheWayBack')
ACTION_UI = _ui('testCardBillActionsStayOnOneRowAtNormalTextSize', 'testCardBillActionsStackAtAccessibilityTextSize',
                'testCardBillActionCanBeReachedAfterScrollingPastIt', 'testAccountActionsRemainReadableAndUsableAtLargestTextSize')
CHART_UI = _ui('testTheTrendChartIsReadAndSlidAlong', 'testSwipingUpOnTheTrendChartScrollsThePage',
               'testChartsPerCurrencyKeepTheirHeightWhenAMonthIsPicked')
HINT_UI = _ui('testGestureHintsGoOnceTheGestureIsUsed', 'testARowsSwipeActionsAreInItsLongPressMenu')
PICKER_UI = _ui('testAccountPickerCancelAndComplete', 'testAccountPickerKeepsGroupsInSight', 'testSeparateFeeAccountPickerStaysOpenAndApplies')
FIGURE_UI = _ui('testOverviewFiguresSitCentredInEqualColumns', 'testOverviewFiguresStackAtAccessibilityTextSize',
                'testCalendarFiguresSitInEqualColumns')
COMPONENT_UI = {
    'Ledger/Views/ControlStyle.swift': {
        **dict.fromkeys(('PeriodBar', 'MonthSwipe', 'monthSwipe', 'SlidingTitle'), MONTH_BAR_UI),
        **dict.fromkeys(('ActionRow', 'ActionCapsuleStyle', 'ActionRowLayout', 'PressedLook', 'RowCapsuleStyle',
                         'rowButton', 'secondaryButton'), ACTION_UI),
        **dict.fromkeys(('ChartPick', 'SidePan', 'chartPick', 'chartPickMonth'), CHART_UI),
        **dict.fromkeys(('HintFooter', 'Learned', 'rowActions'), HINT_UI),
        **dict.fromkeys(('PageSkeleton', 'PageLoading'), _ui('testPagesShowTheirShapeWhileTheLedgerLoads')),
        'appSearchable': _ui('testAListsSearchStaysInSightWhileScrolling', 'testQuickSearchesScrollWithTheJournal'),
    },
    'Ledger/Views/Common.swift': {
        **dict.fromkeys(('ToastView', 'SavedCheck'), _ui('testSaveToastStaysUpAfterTheCardCloses')),
        'DateField': _ui('testFormDateHasTheSameThreeDays'),
        **dict.fromkeys(('AccountPicker', 'AccountField', 'ChosenAccountIcon', 'accountMark', 'fuzzy'), PICKER_UI),
        **dict.fromkeys(('Sensitive', 'sensitive', 'Amount', 'PrivacyButton', 'masked'),
                        _ui('testHiddenAmountsStayHiddenInAccessibilityAtLargeTextSize')),
        'EmptyAdd': _ui('testAnEmptyBudgetListOffersToAddOne'),
    },
    'Ledger/Views/Theme.swift': {
        **dict.fromkeys(('Figure', 'FigureRow'), FIGURE_UI),
        **dict.fromkeys(('Card', 'cardRow'), _ui('testOverviewCardKeepsItsHeightBetweenMonthAndYear', 'testAccountsCardKeepsItsHeightBetweenTabs')),
        'AppTheme': ('LedgerUITests/ColorInteractionTests',),
    },
}
TOP = re.compile(r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|final)\s+)*'
                 r'(struct|enum|class|extension|protocol|func|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)')


def components(text, lines):
    """The component each changed line of a shared file belongs to: its top-level type, or inside an extension
    the function it is in. Lines before the first declaration (imports) belong to the whole file: None."""
    owners = set()
    source = text.splitlines()
    for line in sorted(lines):
        top = member = None
        for number in range(min(line, len(source)), 0, -1):
            current = source[number - 1]
            match = TOP.match(current)
            if match:
                top = match
                break
            if member is None:
                inner = pr_scope.FUNC.match(current)
                if inner:
                    member = inner.group(1)
        if top is None:
            owners.add(None)
        else:
            owners.add(member if top.group(1) == 'extension' and member else top.group(2))
    return owners


def classify(paths, diff='', sources=None):
    """Union all changed-file requirements; unknown/deleted coverage expands, never disappears."""
    paths = sorted(set(paths))
    core, ui, narrow, reasons = set(), set(), set(), []
    core_all = False
    targets = set()
    critical = False
    for path in paths:
        critical |= (path.startswith('Ledger/') and path not in pr_scope.LOCALIZATION_FILES) or path == 'project.yml'
        mapping = MAPPINGS.get(path)
        shared = COMPONENT_UI.get(path)
        file_diff = pr_scope._diff_files(diff).get(path) if diff else None
        text = pr_scope._source(path, sources) if shared and file_diff else None
        if shared and text is not None:
            critical = True
            for name in sorted(components(text, pr_scope._changed_lines(file_diff)), key=lambda n: n or ''):
                if name in shared:
                    ui.update(shared[name])
                    reasons.append(f'{path} → 共用组件 {name} 的界面测试')
                else:
                    reasons.append(f'{path} → 共用组件 {name or "（文件开头）"} 没有对应界面测试，完整覆盖留到转正前')
            continue
        if path in pr_scope.LOCALIZATION_FILES:
            reasons.append(f'{path} → 本地化静态校验与安装包编译，不运行无关表单流程')
        elif mapping:
            core.update(mapping['core'])
            ui.update(mapping['ui'])
            narrow.update(mapping['narrow'])
            reasons.append(f'{path} → {mapping["reason"]}')
        elif path.startswith(('LedgerKit/Tests/LedgerKitTests/', 'LedgerTests/', 'LedgerUITests/')) \
                and path.endswith('.swift') and '/Fixtures/' not in path:
            # Reuse the unchanged PR rules only for changed test files, never for app source.
            plan = pr_scope.classify([path], diff=diff, sources=sources)
            if plan['swift']:
                core.add(plan['swift'])
            ui.update(plan['xcode_tests'])
            reasons.append(f'{path} → 改动的测试及共用辅助函数影响的用例')
        elif path.startswith('tools/fixtures/'):
            core_all = True
            ui.add('LedgerTests/DemoBootstrapTests')
            critical = True
            reasons.append(f'{path} → 核心样本、演示加载与关键界面流程')
        elif path in SAFE_FILES or path.startswith(('docs/', 'tools/', '.github/')):
            reasons.append(f'{path} → 静态检查与工具测试')
        elif path.startswith('LedgerKit/'):
            core_all = True
            reasons.append(f'{path} → 扩大到核心测试模块')
        elif path.startswith('Ledger/Sync/'):
            core_all = True
            targets.add('LedgerTests')
            reasons.append(f'{path} → 扩大到核心与 App 内测试模块；界面只跑关键流程')
        elif path.startswith('LedgerTests/Fixtures/'):
            targets.add('LedgerTests')
            reasons.append(f'{path} → App 内测试夹具，覆盖 App 内模块')
        elif path.startswith(('Ledger/', 'LedgerTests/', 'LedgerUITests/')) or path == 'project.yml':
            critical = True
            reasons.append(f'{path} → 编译与关键界面流程；完整界面覆盖留到转正前')
        else:
            core_all = True
            targets.add('LedgerTests')
            critical = True
            reasons.append(f'{path} → 扩大到核心、App 内测试模块与关键界面流程；不扩大界面套件')
    if critical:
        ui.update(CRITICAL_UI)
    return dict(core_all=core_all, app_targets=sorted(targets), narrow_targets=[],
                core_filter='.*' if core_all else '|'.join(sorted(core)), ui_tests=sorted(ui),
                narrow_tests=sorted(narrow), paths=paths, reasons=reasons or ['源码与上次开发版相同，只做静态与工具检查'])


def validate_selectors(plan, root):
    """A stale/deleted mapping must not silently turn into zero coverage."""
    for name in plan['core_filter'].split('|') if plan['core_filter'] and not plan['core_all'] else ():
        file = root / 'LedgerKit/Tests/LedgerKitTests' / f'{name}.swift'
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', name) or not file.is_file():
            return False
        if not re.search(r'\bclass\s+' + re.escape(name) + r'\b', file.read_text()):
            return False
    for selector in {*plan['ui_tests'], *plan['narrow_tests']}:
        target, name, *method = selector.split('/')
        file = root / target / f'{name}.swift'
        if not file.is_file():
            return False
        text = file.read_text()
        if not re.search(r'\bclass\s+' + re.escape(name) + r'\b', text):
            return False
        if method and not re.search(r'\bfunc\s+' + re.escape(method[0]) + r'\s*\(', text):
            return False
    return True


def module_tests(root, target):
    import ship
    selectors = set()
    for file in (root / target).rglob('*.swift'):
        for name in re.findall(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b', file.read_text()):
            selectors.add(f'{target}/{name}')
    if not selectors:
        raise ship.Failure(f'{target} 没有可执行的测试类，未发布；不能把空模块算作通过')
    return selectors


def expand_modules(plan, root):
    """Resolve broad modules and replace stale selectors with current tests of the same layer."""
    targets = set(plan['app_targets'])
    narrow_targets = set(plan['narrow_targets'])
    if not validate_selectors(plan, root):
        for name in plan['core_filter'].split('|') if plan['core_filter'] and not plan['core_all'] else ():
            if not validate_selectors(dict(plan, core_filter=name, ui_tests=[], narrow_tests=[]), root):
                plan['core_all'] = True
                break
        for key, affected in (('ui_tests', targets), ('narrow_tests', narrow_targets)):
            for selector in plan[key]:
                check = dict(plan, core_filter='', ui_tests=[selector], narrow_tests=[])
                if not validate_selectors(check, root):
                    if selector.startswith('LedgerUITests/'):
                        import ship
                        raise ship.Failure(f'界面回归映射已失效：{selector}；请更新映射，不能改跑整套界面测试')
                    affected.add(selector.split('/')[0])
        plan['reasons'].append('测试已删除或对应规则已过期，替换为当前受影响模块的测试')
    if plan['core_all']:
        plan['core_filter'] = '.*'
    for key, expanded in (('ui_tests', targets), ('narrow_tests', narrow_targets)):
        selectors = {value for value in plan[key] if value.split('/')[0] not in expanded}
        for target in expanded:
            selectors.update(module_tests(root, target))
        plan[key] = sorted(selectors)
    plan.update(app_targets=sorted(targets), narrow_targets=sorted(narrow_targets))
    return plan


def select(repo, sha):
    import ship
    base = None
    if ship.release_for_tag(repo, 'dev'):
        with tempfile.TemporaryDirectory() as temp:
            ship.download(repo, 'dev', Path(temp), files=('build-manifest.json',))
            manifest = ship.read_json(Path(temp) / 'build-manifest.json')
        base = manifest.get('source_sha', '')
        if not re.fullmatch(r'[0-9a-f]{40}', base) or manifest.get('repository') != repo:
            raise ship.Failure('上次开发版清单缺少可信源码基线，未发布；请核实开发版记录')
        if ship.tag_sha(repo, 'dev') != base:
            raise ship.Failure('上次开发版标签与清单源码不一致，未发布；请核实开发版记录')
    if base is None:
        paths = ship.out(['git', 'ls-files', '-z']).strip('\0').split('\0')
        plan = classify([path for path in paths if path and not path.startswith(('LedgerTests/', 'LedgerUITests/'))])
        plan['reasons'].insert(0, '没有上次开发版，按当前源码所含模块选测，不执行完整全量流程')
    elif subprocess.run(['git', 'merge-base', '--is-ancestor', base, sha], cwd=ship.ROOT).returncode:
        paths = ship.out(['git', 'ls-files', '-z']).strip('\0').split('\0')
        plan = classify([path for path in paths if path and not path.startswith(('LedgerTests/', 'LedgerUITests/'))])
        plan['reasons'].insert(0, '基线不是当前源码的祖先，按当前源码所含模块选测，不执行完整全量流程')
    else:
        # Two-dot diff covers all net changes since the package, including multiple PRs/deletions.
        paths = ship.out(['git', 'diff', '--name-only', '-z', '--no-renames', base, sha, '--']).strip('\0').split('\0')
        paths = [path for path in paths if path]
        diff = ship.out(['git', 'diff', '--unified=0', '--no-renames', base, sha, '--'])
        plan = classify(paths, diff=diff)
    plan = expand_modules(plan, ship.ROOT)
    scope_guard.check_plan(plan, 'dev')
    return dict(plan, base_sha=base, source_sha=sha, mode='automatic')


# what decides which tests a plan runs; a PR proof is reusable only when all of these match
SELECTION = ('base_sha', 'core_filter', 'ui_tests', 'narrow_tests')


def pr_proof(proof, plan, tree, repo):
    """What Dev keeps from a PR gate that ran this same plan on this same tree; None when anything differs."""
    selection = proof.get('auto_selection') or {}
    if proof.get('tree') != tree or any(selection.get(key) != plan.get(key) for key in SELECTION):
        return None
    if not re.fullmatch(f'https://github.com/{re.escape(repo)}/actions/runs/[0-9]+', str(proof.get('run_url', ''))):
        return None
    kept = {key: proof[key] for key in ('selected_core', 'selected_interaction', 'additional_interaction') if key in proof}
    return dict(kept, auto_selection=plan, reused_pr=dict(run_url=proof['run_url'], source_sha=proof.get('source_sha')))


def reusable_pr_proof(repo, plan, tree):
    """The newest passing PR gate whose proof matches; with `require up to date` on main, the merge has that tree."""
    import ship
    runs = ship.gh_api(f'repos/{repo}/actions/workflows/ci.yml/runs?event=pull_request&status=success&per_page=30')
    for item in runs['workflow_runs']:
        name = f'ledger-pr-proof-{item["id"]}'
        artifacts = ship.gh_api(f'repos/{repo}/actions/runs/{item["id"]}/artifacts')['artifacts']
        if not any(a['name'] == name and not a['expired'] for a in artifacts):
            continue
        with tempfile.TemporaryDirectory() as temp:
            ship.run(['gh', 'run', 'download', str(item['id']), '--repo', repo, '--name', name, '--dir', temp])
            proof = ship.read_json(Path(temp) / 'pr-proof.json')
        kept = pr_proof(proof, plan, tree, repo)
        if kept:
            return kept
    return None


def describe(plan):
    lines = ['## Dev 自动测试范围',
             f'- 基线：{plan["base_sha"] or "无（首次开发版）"}',
             f'- 当前源码：{plan["source_sha"]}',
             '- 范围：相关核心/存储、本次回归与关键界面流程；完整全量在转正前执行',
             '', *['- ' + reason for reason in plan['reasons']]]
    lines += ['', f'- 核心测试：{plan["core_filter"] or "无需运行；静态与工具测试始终执行"}',
              *['- App/界面：' + name for name in plan['ui_tests']]]
    lines += ['- 窄屏（iPhone SE 第三代）：' + name for name in plan['narrow_tests']]
    return '\n'.join(lines) + '\n'


@contextmanager
def environment(core, selectors, device=None):
    changes = dict(LEDGER_CORE_FILTER=core, LEDGER_UI_TESTS='\n'.join(selectors),
                   LEDGER_SIMULATOR_DEVICE=device or '')
    previous = {key: os.environ.get(key) for key in changes}
    os.environ.update(changes)
    try:
        yield
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def validate(plan):
    import ship
    scope_guard.check_plan(plan, 'dev')
    with environment(plan['core_filter'], plan['ui_tests']):
        proof = ship.validate_targeted()
    if plan['narrow_tests']:
        # Keep both actual result bundles and logs when reusing the existing targeted runner.
        for name, kept in (('interaction-tests.xcresult', 'interaction-tests-regular.xcresult'),
                           ('interaction-tests.log', 'regular-interaction-tests.log')):
            source, target = ship.ROOT / name, ship.ROOT / kept
            if source.exists():
                if target.is_dir():
                    shutil.rmtree(target)
                elif target.exists():
                    target.unlink()
                shutil.move(source, target)
        with environment('', plan['narrow_tests'], 'iPhone SE (3rd generation)'):
            extra = ship.validate_targeted()
        proof['additional_interaction'] = [extra['selected_interaction']]
    return dict(proof, auto_selection=plan)
