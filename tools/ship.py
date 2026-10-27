#!/usr/bin/env python3
"""Dispatch validation and publication to GitHub macOS; execute only on the runner.

  python3 tools/ship.py test                     cloud full validation, publishes nothing
  python3 tools/ship.py dev                      cloud checks, build and publish the dev build
  python3 tools/ship.py dev --full               run full validation before publishing the dev build
  python3 tools/ship.py release                  cloud promotion of the phone-accepted dev package (requires --accepted-build N)
  python3 tools/ship.py version patch|minor|major|X.Y.Z
                                                 commit a version bump and a new CHANGELOG section
  python3 tools/ship.py watch                    follow the running (or the last) test / dev / release from any terminal

Failed checks or builds stop before publication. A later network failure may
leave a pushed commit or partially updated release; status records what completed
and what needs checking. Logs stay in the repository root; packages in dist/.
"""
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/release'))  # release_notes
DIST = ROOT / 'dist'
FILES = ('Ledger.ipa', 'build-manifest.json', 'validation-evidence.json', 'release-notes.md')
XCODE = '/Applications/Xcode.app/Contents/Developer'
BEANCOUNT = ('/opt/homebrew/opt/beancount/libexec/bin/python', '/usr/local/opt/beancount/libexec/bin/python')
SIM_NAME = 'Ledger Local Tests'
PREFERRED = ('iPhone 17', 'iPhone 16', 'iPhone 17 Pro', 'iPhone 16 Pro', 'iPhone 15')
SIM_PREFS = Path.home() / 'Library/Preferences/com.apple.iphonesimulator.plist'
BOOT_TIMEOUT = 300
TEST_TIMEOUT = 300   # per interaction test, as in the former CI
STATUS = ROOT / '.ship/status.json'     # the run in progress (or the last one), for `watch`
HISTORY = ROOT / '.ship/history.json'   # totals of the last passing run, to show "41 / 64"
FULL_VALIDATION = ROOT / '.ship/full-validation.json'  # a passing suite bound to an unchanged, clean source commit

# the stages of each command, as step() names them (the start is enough), for `watch` to list what is still to come
PLAN = {
    'test': ('静态检查与流程回归', 'LedgerKit 核心测试', 'Beancount 报表对照', '新建专用模拟器', '编译 App 与测试包', '附件与交互测试'),
    'release': ('下载并校验开发版', '确认正式版全量验证', '发布正式版', '更新 IPA 源'),
}
PLAN['dev'] = ('静态检查与流程回归', '编译 Release 安装包', '打包并校验安装包', '推送 main 到 GitHub', '发布开发版', '更新 IPA 源')


class Failure(Exception):
    pass


class Progress:
    """What this run is doing, written to .ship/status.json at every stage, so `ship.py watch` in another terminal
    can follow a run started anywhere. Only a record: nothing here decides or changes what the run does."""

    def __init__(self):
        self.state = None

    def begin(self, command):
        self.state = dict(command=command, pid=os.getpid(), started=time.time(), stages=[], log=None,
                          result=None, message='')
        self.save()

    def enter(self, name):
        if self.state is None:
            return
        now = time.time()
        for stage in self.state['stages']:
            stage.setdefault('ended', now)
        self.state['stages'].append(dict(name=name, started=now))
        self.state['log'] = None
        self.save()

    def logging(self, log):
        if self.state is not None and log:
            self.state['log'] = log
            self.save()

    def note(self, text):
        if self.state is not None and self.state['stages']:
            self.state['stages'][-1]['note'] = text
            self.save()

    def effect(self, name, status):
        if self.state is not None:
            self.state.setdefault('effects', {})[name] = status
            self.save()

    def finish(self, ok, message=None, totals=None, interrupted=False):
        if self.state is None:
            return
        now = time.time()
        for stage in self.state['stages']:
            stage.setdefault('ended', now)
        if not ok and self.state['stages']:
            self.state['stages'][-1]['failed'] = True
        self.state.update(result='interrupted' if interrupted else 'passed' if ok else 'failed', ended=now)
        if message is not None:
            self.state['message'] = message
        self.save()
        if ok and totals:
            write_json(HISTORY, {**read_json(HISTORY), **totals})

    def save(self):
        write_json(STATUS, self.state)


progress = Progress()


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def write_json(path, value):
    path.parent.mkdir(exist_ok=True)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=1))
    temp.replace(path)


def step(text):
    print(f'\n▶ {text}', flush=True)
    progress.enter(text)


def done(text):
    """The run's closing line, on screen and kept for `watch`."""
    print(text)
    if progress.state is not None:
        progress.state['message'] = text.strip()


def report(text):
    """A stage's result line ("333 项通过"), on screen and for `watch`."""
    print(f'  {text}')
    progress.note(text)


def out(cmd, **kwargs):
    return subprocess.run([str(c) for c in cmd], cwd=ROOT, check=True, capture_output=True, text=True, **kwargs).stdout.strip()


def run(cmd, log=None, check=True, env=None, timeout=None):
    """Run a command; with `log`, its output goes to that file and the tail is shown on failure."""
    cmd = [str(c) for c in cmd]
    progress.logging(log)
    if log is None:
        result = subprocess.run(cmd, cwd=ROOT, env=env, timeout=timeout)
    else:
        with open(ROOT / log, 'w') as handle:
            result = subprocess.run(cmd, cwd=ROOT, env=env, timeout=timeout, stdout=handle, stderr=subprocess.STDOUT)
    if check and result.returncode:
        if log:
            print(''.join((ROOT / log).read_text(errors='replace').splitlines(True)[-40:]), file=sys.stderr)
        raise Failure(f'{" ".join(cmd[:3])} 失败（退出码 {result.returncode}）' + (f'，完整日志见 {log}' if log else ''))
    return result.returncode


def remote_run(effect, cmd):
    # A failed request may have reached the server. Persist this before sending it.
    progress.effect(effect, 'started')
    run(cmd)
    progress.effect(effect, 'done')


def failure_message(error, interrupted=False, state=None):
    label = '中断' if interrupted else '失败'
    message = f'✗ {label}：{error or type(error).__name__}'
    state = state if state is not None else progress.state or {}
    effects = state.get('effects', {})
    if not effects:
        return message + '\n未发起推送或发布。'
    states = {
        'main_push': ('main', '已推送', '未发起推送', '已发起推送，结果待核实'),
        'dev_release': ('开发版', '已发布', '未开始发布', '已发起更新，结果待核实'),
        'release': ('正式版', '已发布', '未开始发布', '已发起发布，结果待核实'),
        'ipa_source': ('IPA 安装源', '已更新', '尚未更新', '已发起更新，结果待核实'),
    }
    keys = ('release', 'ipa_source') if state.get('command') == 'release' \
        else ('main_push', 'dev_release', 'ipa_source')
    for key in keys:
        name, done, pending, uncertain = states[key]
        state = effects.get(key)
        message += f'\n{name}：{done if state == "done" else uncertain if state == "started" else pending}'
    return message


def git(*args):
    return out(['git', *args])


def gh_api(path):
    return json.loads(out(['gh', 'api', path]))


def repository():
    return out(['gh', 'repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'])


def use_xcode():
    """Use the full Xcode even while xcode-select still points at the Command Line Tools."""
    if subprocess.run(['xcodebuild', '-version'], capture_output=True).returncode:
        if not Path(XCODE).exists():
            raise Failure('找不到 Xcode；请安装 Xcode 并执行 sudo xcode-select -s /Applications/Xcode.app/Contents/Developer')
        os.environ['DEVELOPER_DIR'] = XCODE
    return ' '.join(out(['xcodebuild', '-version']).split())


def demo_snapshot():
    """The fixed public demo commit, read-only, in .demo-data."""
    commit = json.loads((ROOT / 'tools/fixtures/manifest.json').read_text())['demoCommit']
    path = ROOT / '.demo-data'
    if not (path / '.git').exists():
        run(['git', 'clone', '-q', 'https://github.com/iskerwin/ledger-demo', path])
    require_clean_demo()
    if git('-C', path, 'rev-parse', 'HEAD') != commit:
        run(['git', '-C', path, 'fetch', '-q', 'origin'])
        run(['git', '-C', path, 'checkout', '-q', '--detach', commit])
    verify_demo_snapshot(commit)
    return commit


def require_clean_demo():
    if git('-C', ROOT / '.demo-data', 'status', '--porcelain', '--untracked-files=all', '--ignored'):
        raise Failure('本机演示快照有修改或额外文件；未覆盖这些文件，请先检查 .demo-data')


def content_digest(files):
    """Bind paths and bytes, independent of file times and archive ordering."""
    records = [(name, hashlib.sha256(data).hexdigest()) for name, data in files]
    return hashlib.sha256(json.dumps(sorted(records), ensure_ascii=True).encode()).hexdigest()


def demo_digest(folder):
    files = []
    for path in sorted(folder.rglob('*')):
        name = path.relative_to(folder)
        if any(part.startswith('.') for part in name.parts):
            continue  # same exclusion as the App's demo copy phase
        if path.is_symlink():
            raise Failure('演示快照不能包含符号链接')
        if path.is_file():
            files.append((name.as_posix(), path.read_bytes()))
    return content_digest(files)


def verify_demo_snapshot(commit, expected_digest=None):
    if git('-C', ROOT / '.demo-data', 'rev-parse', 'HEAD') != commit:
        raise Failure('演示快照提交在验证或打包期间发生变化')
    require_clean_demo()
    digest = demo_digest(ROOT / '.demo-data')
    if expected_digest is not None and digest != expected_digest:
        raise Failure('演示快照内容在验证或打包期间发生变化')
    return digest


def beancount_python():
    for candidate in (*BEANCOUNT, sys.executable):
        if Path(candidate).exists() and subprocess.run([candidate, '-c', 'import beancount'], capture_output=True).returncode == 0:
            return candidate
    raise Failure('找不到 Beancount；请执行 brew install beancount')


def executed(text):
    """Total from the last XCTest summary line: (tests, failures)."""
    found = re.findall(r'Executed (\d+) tests?, with (\d+) failures?', text)
    if not found:
        raise Failure('日志中没有测试汇总行')
    return tuple(map(int, found[-1]))


# Simulator: a fresh dedicated device each run; readiness is observed, never assumed after a delay.

def select_device(runtimes, sdk):
    ios = [r for r in runtimes if r.get('isAvailable') and (r.get('platform') == 'iOS' or r.get('name', '').startswith('iOS '))]
    if not ios:
        raise Failure('没有可用的 iOS 模拟器运行时；在 Xcode → Settings → Components 下载')
    requested = os.environ.get('LEDGER_SIMULATOR_DEVICE')
    if requested:
        ios = [r for r in ios if any(d.get('name') == requested for d in r.get('supportedDeviceTypes', []))]
        if not ios:
            raise Failure(f'没有支持指定机型 {requested} 的运行时')
    key = lambda r: tuple(int(p) for p in r['version'].split('.') if p.isdigit())
    # A runtime may carry only unusual models (iOS 27.1: iPhone Duo); the UI tests expect a regular iPhone.
    regular = [r for r in ios if any(d.get('name') in PREFERRED for d in r.get('supportedDeviceTypes', []))] or ios
    matching = [r for r in regular if key(r)[:2] == tuple(int(p) for p in sdk.split('.')[:2])]
    runtime = max(matching or regular, key=key)
    phones = [d for d in runtime.get('supportedDeviceTypes', []) if d.get('name', '').startswith('iPhone')]
    if not phones:
        raise Failure(f'{runtime["name"]} 不支持任何 iPhone 机型')
    requested = os.environ.get('LEDGER_SIMULATOR_DEVICE')
    if requested:
        phones = [d for d in phones if d['name'] == requested]
        if not phones:
            raise Failure(f'{runtime["name"]} 不支持指定机型 {requested}')
    phones.sort(key=lambda d: (PREFERRED.index(d['name']) if d['name'] in PREFERRED else len(PREFERRED), d['name']))
    return runtime, phones[0]


def disable_hardware_keyboard(udid):
    # A connected hardware keyboard hides the software keyboard; XCUITest then never sees app.keyboards.
    subprocess.run(['defaults', 'write', 'com.apple.iphonesimulator', 'ConnectHardwareKeyboard', '-bool', 'false'], check=True)
    buddy = '/usr/libexec/PlistBuddy'
    for entry in (':DevicePreferences dict', f':DevicePreferences:{udid} dict'):
        subprocess.run([buddy, '-c', f'Add {entry}', str(SIM_PREFS)], capture_output=True)
    subprocess.run([buddy, '-c', f'Delete :DevicePreferences:{udid}:ConnectHardwareKeyboard', str(SIM_PREFS)], capture_output=True)
    subprocess.run([buddy, '-c', f'Add :DevicePreferences:{udid}:ConnectHardwareKeyboard bool false', str(SIM_PREFS)], check=True)
    subprocess.run(['killall', 'cfprefsd'], capture_output=True)


def fresh_simulator():
    for group in json.loads(out(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices'].values():
        for device in group:
            if device['name'] == SIM_NAME:
                subprocess.run(['xcrun', 'simctl', 'delete', device['udid']], capture_output=True)
    sdk = out(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'])
    runtime, device = select_device(json.loads(out(['xcrun', 'simctl', 'list', 'runtimes', '-j']))['runtimes'], sdk)
    udid = out(['xcrun', 'simctl', 'create', SIM_NAME, device['identifier'], runtime['identifier']])
    disable_hardware_keyboard(udid)
    try:
        subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True, capture_output=True, timeout=120)
        subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True, capture_output=True, timeout=BOOT_TIMEOUT)
        subprocess.run(['xcrun', 'simctl', 'getenv', udid, 'HOME'], check=True, capture_output=True, timeout=60)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise Failure(f'模拟器环境失败（测试尚未开始）：{error}。这不是测试结论，可直接重跑')
    return udid, f'{device["name"]} · {runtime["name"]}'


def validate_development():
    """Fast publication checks; targeted tests are run during development, separately from packaging."""
    xcode = use_xcode()
    demo = demo_snapshot()
    digest = verify_demo_snapshot(demo)
    step('静态检查与流程回归')
    run([sys.executable, 'tools/check_project.py'])
    run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tools/tests', '-p', 'test_*.py'], log='tools-tests.log',
        env={k: v for k, v in os.environ.items() if k not in ('LEDGER_CORE_FILTER', 'LEDGER_UI_TESTS', 'LEDGER_SIMULATOR_DEVICE')})
    return dict(validator='github-actions' if os.environ.get('GITHUB_ACTIONS') == 'true' else 'local',
                **({'run_url': f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"}
                   if os.environ.get('GITHUB_ACTIONS') == 'true' else {}), scope='build', static_checks=True, tools_tests=True,
                validated_at=datetime.now(timezone.utc).isoformat(timespec='seconds'),
                macos=platform.mac_ver()[0], xcode=xcode, demo_commit=demo, demo_sha256=digest)


def checked_interaction_results(summary, tests):
    """Check completed cases in both bundles against xcresult's overall summary."""
    targets = {}
    seen = set()

    def walk(nodes, target=None):
        for node in nodes:
            kind = node.get('nodeType')
            if kind in ('Unit test bundle', 'UI test bundle'):
                target = node.get('name')
                if target not in ('LedgerTests', 'LedgerUITests') or target in targets:
                    raise ValueError('测试目标不完整或重复')
                targets[target] = 0
            if kind in ('Test Plan', 'Unit test bundle', 'UI test bundle', 'Test Suite', 'Test Case') \
                    and node.get('result') != 'Passed':
                raise ValueError('包含失败、跳过或未完成的测试')
            if kind == 'Test Case':
                identity = node.get('nodeIdentifierURL')
                if target not in targets or not identity or identity in seen:
                    raise ValueError('测试用例身份缺失或重复')
                seen.add(identity)
                targets[target] += 1
            walk(node.get('children', []), target)

    try:
        walk(tests['testNodes'])
        if set(targets) != {'LedgerTests', 'LedgerUITests'} or not all(targets.values()):
            raise ValueError('LedgerTests 与 LedgerUITests 必须各有实际通过的测试')
        count = sum(targets.values())
        if summary['result'] != 'Passed' or summary['totalTestCount'] != count or summary['passedTests'] != count \
                or any(summary[key] != 0 for key in ('failedTests', 'skippedTests', 'expectedFailures')):
            raise ValueError('测试汇总未全部通过或与用例明细不一致')
    except (KeyError, TypeError, ValueError) as error:
        raise Failure(f'附件与交互测试结果不完整：{error}，见 interaction-tests.xcresult') from error
    return targets


def interaction_results():
    command = ['xcrun', 'xcresulttool', 'get', 'test-results']
    try:
        summary = json.loads(out([*command, 'summary', '--path', 'interaction-tests.xcresult', '--compact']))
        tests = json.loads(out([*command, 'tests', '--path', 'interaction-tests.xcresult', '--compact']))
    except (ValueError, subprocess.CalledProcessError) as error:
        raise Failure('无法读取附件与交互测试结果，未认定全量通过，见 interaction-tests.xcresult') from error
    return checked_interaction_results(summary, tests)


def validate():
    """Full regression suite, used explicitly or before a stable release."""
    proof = validate_development()

    step('LedgerKit 核心测试')
    env = dict(os.environ, LEDGER_DEMO_PATH=str(ROOT / '.demo-data'), SAMPLE_OUT=str(ROOT / 'samples'))
    run(['swift', 'test', '--package-path', 'LedgerKit'], log='swift-tests.log', env=env)
    core, failed = executed((ROOT / 'swift-tests.log').read_text(errors='replace'))
    if failed or not core:
        raise Failure(f'核心测试 {failed} 项失败，见 swift-tests.log')
    report(f'{core} 项通过')

    step('Beancount 报表对照')
    run([beancount_python(), 'tools/fixtures/check_reports.py', 'LedgerKit/Tests/LedgerKitTests/Fixtures/realistic/main.bean',
         'samples/reports.json'], log='reports-check.log')
    reports = next((line for line in (ROOT / 'reports-check.log').read_text().splitlines() if line.startswith('Reports match')), None)
    if not reports:
        raise Failure('报表对照没有给出一致结论，见 reports-check.log')
    report(reports)

    step('新建专用模拟器')
    udid, simulator = fresh_simulator()
    report(simulator)

    step('编译 App 与测试包（不含内置演示）')
    shutil.rmtree(ROOT / 'Ledger/Demo', ignore_errors=True)
    run(['xcodegen', 'generate', '--quiet'])
    destination = f'platform=iOS Simulator,id={udid}'
    run(['xcodebuild', 'build-for-testing', '-project', 'Ledger.xcodeproj', '-scheme', 'LedgerInteractionTests',
         '-destination', destination, '-derivedDataPath', 'build-demo', 'CODE_SIGNING_ALLOWED=NO'], log='demo-build.log')

    step('附件与交互测试（不并行，约 20 分钟）')
    shutil.rmtree(ROOT / 'interaction-tests.xcresult', ignore_errors=True)
    code = run(['xcodebuild', 'test-without-building', '-project', 'Ledger.xcodeproj', '-scheme', 'LedgerInteractionTests',
                '-destination', destination, '-derivedDataPath', 'build-demo', '-parallel-testing-enabled', 'NO',
                '-test-timeouts-enabled', 'YES', '-maximum-test-execution-time-allowance', str(TEST_TIMEOUT),
                '-resultBundlePath', 'interaction-tests.xcresult'], log='interaction-tests.log', check=False)
    text = (ROOT / 'interaction-tests.log').read_text(errors='replace')
    failures = re.findall(r"Test Case '-\[(\S+ \S+)\]' failed", text)
    if code or failures or not re.search(r'\*\* TEST (EXECUTE )?SUCCEEDED \*\*', text):
        for name in failures:
            print(f'  ✗ {name}', file=sys.stderr)
        raise Failure('交互测试未通过，见 interaction-tests.log 与 interaction-tests.xcresult'
                      + ('' if failures else '（没有失败的测试用例，可能是环境问题）'))
    targets = interaction_results()
    interaction = sum(targets.values())
    report(f'App 内 {targets["LedgerTests"]} 项、界面 {targets["LedgerUITests"]} 项通过')
    subprocess.run(['xcrun', 'simctl', 'shutdown', udid], capture_output=True)

    verify_demo_snapshot(proof['demo_commit'], proof['demo_sha256'])
    return dict(proof, scope='full', simulator=simulator, core_tests=core, reports=reports,
                interaction_tests=interaction, test_targets=targets)


# Packages, evidence and releases.

def selected_tests():
    return bool(os.environ.get('LEDGER_UI_TESTS', '').strip() or os.environ.get('LEDGER_CORE_FILTER', '').strip())


def validate_targeted():
    """Selected regressions are recorded separately; they never count as a full suite."""
    proof = validate_development()
    core_filter = os.environ.get('LEDGER_CORE_FILTER', '').strip()
    selectors = os.environ.get('LEDGER_UI_TESTS', '').split()
    if core_filter:
        step('指定 LedgerKit 回归')
        run(['swift', 'test', '--package-path', 'LedgerKit', '--filter', core_filter],
            log='swift-tests.log', env=dict(os.environ, LEDGER_DEMO_PATH=str(ROOT / '.demo-data'), SAMPLE_OUT=str(ROOT / 'samples')))
        count, failed = executed((ROOT / 'swift-tests.log').read_text())
        if failed or count == 0:
            raise Failure('指定核心测试失败或没有实际执行用例')
        proof['selected_core'] = dict(filter=core_filter, passed=count)
    if selectors:
        if any(not re.fullmatch(r'Ledger(?:UI)?Tests/[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)?', value) for value in selectors):
            raise Failure('指定界面测试必须使用 Target/Class[/method]')
        step('指定 App 内与界面回归')
        udid, simulator = fresh_simulator()
        try:
            run(['xcodegen', 'generate', '--quiet'])
            shutil.rmtree(ROOT / 'interaction-tests.xcresult', ignore_errors=True)
            run(['xcodebuild', 'test', '-project', 'Ledger.xcodeproj', '-scheme', 'LedgerInteractionTests',
                 '-destination', f'platform=iOS Simulator,id={udid}', '-derivedDataPath', 'build-demo',
                 '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
                 '-maximum-test-execution-time-allowance', str(TEST_TIMEOUT),
                 '-resultBundlePath', 'interaction-tests.xcresult', 'CODE_SIGNING_ALLOWED=NO',
                 *['-only-testing:' + value for value in selectors]], log='interaction-tests.log')
            command = ['xcrun', 'xcresulttool', 'get', 'test-results']
            summary = json.loads(out([*command, 'summary', '--path', 'interaction-tests.xcresult', '--compact']))
            tests = json.loads(out([*command, 'tests', '--path', 'interaction-tests.xcresult', '--compact']))
            count = checked_selected_results(summary, tests, selectors)
            proof['selected_interaction'] = dict(selectors=selectors, passed=count, simulator=simulator)
        finally:
            subprocess.run(['xcrun', 'simctl', 'shutdown', udid], capture_output=True)
    return proof


def checked_selected_results(summary, tests, selectors):
    cases = []
    def walk(nodes, target=''):
        for node in nodes:
            if node.get('nodeType') in ('Unit test bundle', 'UI test bundle'):
                target = node.get('name', '')
            if node.get('nodeType') == 'Test Case':
                if node.get('result') != 'Passed':
                    raise Failure('指定测试包含失败、跳过或未完成的用例')
                identity = str(node.get('nodeIdentifier', '')).removesuffix('()')
                if not identity or target not in ('LedgerTests', 'LedgerUITests'):
                    raise Failure('指定测试缺少用例或目标身份')
                cases.append(identity if identity.startswith(target + '/') else target + '/' + identity)
            walk(node.get('children', []), target)
    walk(tests.get('testNodes', []))
    if not cases or len(cases) != len(set(cases)) or summary.get('result') != 'Passed' or \
            summary.get('totalTestCount') != len(cases) or summary.get('passedTests') != len(cases) or \
            any(summary.get(key) != 0 for key in ('failedTests', 'skippedTests', 'expectedFailures')):
        raise Failure('指定测试结果缺失、重复或汇总不一致')
    for selector in selectors:
        # xcresult identifiers include the target, class and method.
        if not any(case == selector or case.startswith(selector + '/') for case in cases):
            raise Failure(f'指定测试没有实际执行：{selector}')
    return len(cases)


def release_validation_at_source(manifest, proof):
    """Keep current release tooling while testing the package's original source in isolation."""
    global ROOT
    if os.environ.get('GITHUB_ACTIONS') != 'true' or git('rev-parse', 'HEAD') == manifest['source_sha']:
        return release_validation(manifest, proof)
    try:
        verify_proof(proof, manifest, require_full=True)
        return proof
    except ValueError:
        pass
    original = ROOT
    with tempfile.TemporaryDirectory() as temp:
        source = Path(temp) / 'source'
        run(['git', 'worktree', 'add', '--detach', source, manifest['source_sha']])
        try:
            ROOT = source
            return release_validation(manifest, proof)
        finally:
            ROOT = original
            for name in ('tools-tests.log', 'swift-tests.log', 'reports-check.log', 'demo-build.log',
                         'interaction-tests.log', 'interaction-tests.xcresult'):
                item = source / name
                if item.is_dir():
                    shutil.copytree(item, original / name, dirs_exist_ok=True)
                elif item.is_file():
                    shutil.copy(item, original / name)
            run(['git', 'worktree', 'remove', '--force', source])


def semver(value):
    if not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', value):
        raise ValueError('版本必须为 X.Y.Z，不含前缀、空白或前导零')
    return tuple(map(int, value.split('.')))


def next_version(current, choice):
    major, minor, patch = semver(current)
    result = {'patch': f'{major}.{minor}.{patch+1}', 'minor': f'{major}.{minor+1}.0',
              'major': f'{major+1}.0.0'}.get(choice, choice)
    if semver(result) <= (major, minor, patch):
        raise ValueError('所选版本必须高于当前版本')
    return result


def next_build(releases, listed=()):
    """Build numbers keep rising across every dev and published release, and every build the IPA sources have listed:
    a dev release's notes are replaced on each publish, so they alone cannot hold the highest number."""
    builds = [int(m[1]) for r in releases if (m := re.search(r'构建 (\d+)', r.get('body') or ''))]
    builds += [int(b) for b in listed]
    return str(max(builds, default=0) + 1)


def release_tags(ls_remote):
    """The dev and vX.Y.Z tags in `git ls-remote --tags` output."""
    names = {line.split('refs/tags/')[-1].removesuffix('^{}') for line in ls_remote.splitlines() if 'refs/tags/' in line}
    return {t for t in names if t == 'dev' or re.fullmatch(r'v\d+\.\d+\.\d+', t)}


def check_release_list(releases, tags):
    """GitHub's release list has come back empty for a moment (2026-10-22), which once restarted the build numbers
    at 1: every tagged release must be in it before anything is numbered or published."""
    have = {r.get('tag_name') for r in releases}
    missing = sorted(tags - have)
    if missing:
        raise Failure(f'GitHub 返回的发布列表缺少 {"、".join(missing)}，没有编译和发布；稍后重试')


def fetch_releases(repo, tags, attempts=6, wait=2.0):
    """The release list, read again while it lacks a tagged release: GitHub has answered with an empty list about one
    time in three (2026-10-23). Only a complete list is used; after `attempts` short ones nothing is published."""
    for attempt in range(attempts):
        releases = [r for page in json.loads(out(['gh', 'api', '--paginate', '--slurp', f'repos/{repo}/releases?per_page=100']))
                    for r in page]
        if tags <= {r.get('tag_name') for r in releases}:
            return releases
        if attempt + 1 < attempts:
            time.sleep(wait * (attempt + 1))
    check_release_list(releases, tags)
    return releases


def source_builds(log):
    """Every build number in the history of the ipa branch's sources (`git log -p` of dev.json and release.json)."""
    return re.findall(r'"buildVersion": "(\d+)"', log)


def verify_proof(proof, manifest, require_full=False):
    if proof.get('source_sha') != manifest['source_sha'] or proof.get('tree') != manifest['tree']:
        raise ValueError('验证记录与安装包的源码或文件树不一致')
    if proof.get('validator') not in ('local', 'github-actions'):
        raise ValueError('验证记录必须来自受支持的验证器')
    if proof.get('validator') == 'github-actions' and not re.fullmatch(
            r'https://github.com/' + re.escape(manifest.get('repository', '')) + r'/actions/runs/[0-9]+', str(proof.get('run_url', ''))):
        raise ValueError('云端验证记录缺少本仓库的运行链接')
    for key in ('demo_commit', 'demo_sha256'):
        if manifest.get(key) is not None and proof.get(key) != manifest[key]:
            raise ValueError('验证记录与安装包的演示快照不一致')
    if require_full and (not proof.get('demo_commit') or
                         not re.fullmatch(r'[0-9a-f]{64}', str(proof.get('demo_sha256', '')))):
        raise ValueError('全量验证记录缺少演示快照内容摘要，需要补跑')
    if require_full and not all(proof.get(key) is True for key in ('static_checks', 'tools_tests')):
        raise ValueError('全量验证记录缺少静态检查或工具回归，需要补跑')
    if proof.get('scope') == 'build' and not require_full:
        if not all(proof.get(k) is True for k in ('static_checks', 'tools_tests', 'release_build')):
            raise ValueError('开发版验证记录不完整：缺少静态检查、工具回归或 Release 构建')
        return
    if proof.get('scope') not in (None, 'full') \
            or any(type(proof.get(key)) is not int or proof[key] <= 0 for key in ('core_tests', 'interaction_tests')) \
            or not str(proof.get('reports', '')).startswith('Reports match'):
        raise ValueError('验证记录不完整：缺少核心测试、报表对照或交互测试结果')
    if require_full or 'test_targets' in proof:
        targets = proof.get('test_targets')
        if not isinstance(targets, dict) or set(targets) != {'LedgerTests', 'LedgerUITests'} \
                or any(type(n) is not int or n <= 0 for n in targets.values()) \
                or sum(targets.values()) != proof['interaction_tests']:
            raise ValueError('全量验证记录缺少两个测试目标的完整通过数，需要补跑')


def verify_package(folder, manifest, proof, repo):
    semver(manifest['version'])
    if manifest['repository'] != repo:
        raise ValueError('安装包清单的仓库不一致')
    verify_proof(proof, manifest)
    ipa = folder / 'Ledger.ipa'
    if hashlib.sha256(ipa.read_bytes()).hexdigest() != manifest['sha256'] or ipa.stat().st_size != manifest['size']:
        raise ValueError('安装包大小或 SHA256 不匹配')
    with zipfile.ZipFile(ipa) as package:
        if package.testzip():
            raise ValueError('安装包 ZIP 校验失败')
        info = plistlib.loads(package.read('Payload/Ledger.app/Info.plist'))
        for key, value in [('CFBundleShortVersionString', manifest['version']),
                           ('CFBundleVersion', manifest['build']), ('CFBundleIdentifier', 'com.iskerwin.ledger')]:
            if info.get(key) != value:
                raise ValueError(f'安装包 {key} 与清单不一致')
        for name in ('Payload/Ledger.app/Demo/main.bean', 'Payload/Ledger.app/_CodeSignature/CodeResources'):
            if name not in package.namelist():
                raise ValueError(f'安装包缺少 {name}')
        prefix = 'Payload/Ledger.app/Demo/'
        names = [entry.filename for entry in package.infolist()
                 if entry.filename.startswith(prefix) and not entry.is_dir()]
        if len(names) != len(set(names)):
            raise ValueError('安装包演示资源有重复路径')
        digest = content_digest((name[len(prefix):], package.read(name)) for name in names)
        for record in (manifest, proof):
            if record.get('demo_sha256') is not None and record['demo_sha256'] != digest:
                raise ValueError('安装包内的演示内容与验证记录不一致')
        if manifest.get('demo_commit') and info.get('LedgerDemoCommit') != manifest['demo_commit']:
            raise ValueError('安装包内的演示提交与清单不一致')
        return digest


def verify_source(repo, manifest):
    """The package's source must be a pushed main commit with the recorded tree."""
    sha = manifest['source_sha']
    if gh_api(f'repos/{repo}/git/commits/{sha}')['tree']['sha'] != manifest['tree']:
        raise ValueError('远端源码文件树不匹配')
    run(['git', 'fetch', '-q', 'origin', 'main'])
    if subprocess.run(['git', 'merge-base', '--is-ancestor', sha, 'FETCH_HEAD'], cwd=ROOT).returncode:
        raise ValueError('安装包的源码提交不在 GitHub main 上')


def build_ipa(version, build, demo):
    step(f'编译 Release 安装包 {version}（构建 {build}，内置演示）')
    digest = verify_demo_snapshot(demo)
    bundled = ROOT / 'Ledger/Demo'
    shutil.rmtree(bundled, ignore_errors=True)
    shutil.copytree(ROOT / '.demo-data', bundled, ignore=shutil.ignore_patterns('.git', '.github'))
    try:
        verify_demo_snapshot(demo, digest)
        if demo_digest(bundled) != digest:
            raise Failure('复制到 App 的演示内容与固定快照不一致')
        if not (bundled / 'main.bean').is_file():
            raise Failure('演示快照缺少 main.bean')
        run(['xcodegen', 'generate', '--quiet'])
        shutil.rmtree(ROOT / 'build', ignore_errors=True)
        run(['xcodebuild', '-project', 'Ledger.xcodeproj', '-scheme', 'Ledger', '-configuration', 'Release',
             '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS', '-derivedDataPath', 'build',
             f'MARKETING_VERSION={version}', f'CURRENT_PROJECT_VERSION={build}',
             f'LEDGER_DEMO_COMMIT={demo}', 'LEDGER_DEMO_MIRROR=',
             'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY='], log='build.log')
    finally:
        shutil.rmtree(bundled, ignore_errors=True)
    step('打包并校验安装包')
    payload = ROOT / 'Payload'
    shutil.rmtree(payload, ignore_errors=True)
    payload.mkdir()
    app = payload / 'Ledger.app'
    run(['ditto', 'build/Build/Products/Release-iphoneos/Ledger.app', app])
    run(['xattr', '-cr', payload])
    if not (app / 'Demo/main.bean').is_file():
        raise Failure('安装包缺少内置演示')
    run(['codesign', '-f', '-s', '-', app])
    run(['codesign', '-v', app])
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleShortVersionString') != version or info.get('CFBundleVersion') != build:
        raise Failure('安装包版本或构建号与预期不一致')
    ipa = DIST / 'Ledger.ipa'
    ipa.unlink(missing_ok=True)
    run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--noqtn', '--keepParent', payload, ipa])
    run(['unzip', '-tq', ipa])
    if 'Payload/Ledger.app/_CodeSignature/CodeResources' not in zipfile.ZipFile(ipa).namelist():
        raise Failure('安装包缺少签名资源')
    shutil.rmtree(payload)
    return ipa


def download(repo, tag, folder, files=FILES):
    for name in files:
        run(['gh', 'release', 'download', tag, '--repo', repo, '--pattern', name, '--dir', folder])


def release_for_tag(repo, tag):
    result = subprocess.run(['gh', 'api', f'repos/{repo}/releases/tags/{tag}'], text=True, capture_output=True)
    if result.returncode:
        if 'HTTP 404' in result.stderr:
            return None
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)


def tag_sha(repo, tag):
    obj = gh_api(f'repos/{repo}/git/ref/tags/{tag}')['object']
    if obj['type'] != 'commit':
        raise ValueError('发布标签必须直接指向源码提交')
    return obj['sha']


def tag_exists(repo, tag):
    result = subprocess.run(['gh', 'api', f'repos/{repo}/git/ref/tags/{tag}'], text=True, capture_output=True)
    if result.returncode and 'HTTP 404' not in result.stderr:
        raise RuntimeError(result.stderr)
    return result.returncode == 0


def publish(repo, tag, folder, manifest, notes):
    """Create the published release; an existing version is never moved or replaced."""
    if release_for_tag(repo, tag) or tag_exists(repo, tag):
        raise ValueError(f'{tag} 已发布；先用 python3 tools/ship.py version 选择新版本，再发布开发版')
    progress.effect('release', 'started')
    run(['gh', 'release', 'create', tag, '--repo', repo, '--target', manifest['source_sha'], '--draft',
         '--title', f'Ledger X {manifest["version"]}', '--notes-file', notes])
    run(['gh', 'release', 'upload', tag, '--repo', repo, *[folder/name for name in FILES]])
    run(['gh', 'release', 'edit', tag, '--repo', repo, '--draft=false', '--prerelease=false', '--latest'])
    progress.effect('release', 'done')


def remote_has(branch):
    return subprocess.run(['git', 'ls-remote', '--exit-code', 'origin', f'refs/heads/{branch}'],
                          cwd=ROOT, capture_output=True).returncode == 0


def update_sources(repo):
    """Regenerate the IPA sources (dev.json, release.json and mirrors) and push them to the ipa branch."""
    step('更新 IPA 源（ipa 分支）')
    site = DIST / 'site'
    shutil.rmtree(site, ignore_errors=True)
    run([sys.executable, 'tools/release/ipa_source.py', repo, site])
    with tempfile.TemporaryDirectory() as temp:
        tree = Path(temp) / 'ipa'
        if remote_has('ipa'):
            run(['git', 'fetch', '-q', 'origin', 'ipa'])
            run(['git', 'worktree', 'add', '-q', '--detach', tree, 'FETCH_HEAD'])
        else:
            # A new repository: the ipa branch starts empty, apart from the sources.
            run(['git', 'worktree', 'add', '-q', '--orphan', '-b', f'ipa-sources-{tree.parent.name}', tree])
        try:
            (tree / 'mirror').mkdir(exist_ok=True)
            for name in ('dev.json', 'release.json', 'mirror/dev.json', 'mirror/release.json'):
                shutil.copy(site / name, tree / name)
            run(['git', '-C', tree, 'add', 'dev.json', 'release.json', 'mirror/dev.json', 'mirror/release.json'])
            if subprocess.run(['git', '-C', str(tree), 'diff', '--cached', '--quiet']).returncode:
                run(['git', '-C', tree, 'commit', '-qm', 'Update installation sources'])
                remote_run('ipa_source', ['git', '-C', tree, 'push', '-q', 'origin', 'HEAD:refs/heads/ipa'])
            progress.effect('ipa_source', 'done')
        finally:
            run(['git', 'worktree', 'remove', '--force', tree])


def require_clean_main():
    if git('branch', '--show-current') != 'main':
        raise Failure('请在 main 分支上执行')
    if git('status', '--porcelain'):
        raise Failure('工作区有未提交的改动；先提交或还原后再发布')
    if subprocess.run(['git', 'remote', 'get-url', 'origin'], cwd=ROOT, capture_output=True).returncode:
        raise Failure('还没有 GitHub 仓库：先创建仓库并 git remote add origin <地址>')
    if not remote_has('main'):
        return  # first publication of a new repository
    run(['git', 'fetch', '-q', 'origin', 'main'])
    if subprocess.run(['git', 'merge-base', '--is-ancestor', 'FETCH_HEAD', 'HEAD'], cwd=ROOT).returncode:
        raise Failure('本地 main 落后于或偏离 GitHub main；先 git pull 再发布')


def ship_dev(full=False):
    import release_notes
    repo = repository()
    require_clean_main()
    sha = git('rev-parse', 'HEAD')
    proof = validate() if full else validate_targeted() if selected_tests() else validate_development()
    version = re.search(r'MARKETING_VERSION: "([^"]+)"', (ROOT / 'project.yml').read_text())[1]
    releases = fetch_releases(repo, release_tags(out(['git', 'ls-remote', '--tags', 'origin'])))
    listed = []
    if remote_has('ipa'):
        run(['git', 'fetch', '-q', 'origin', 'ipa'])
        listed = source_builds(out(['git', 'log', 'FETCH_HEAD', '-p', '--format=', '--', 'dev.json', 'release.json']))
    build = next_build(releases, listed)
    shutil.rmtree(DIST, ignore_errors=True)
    DIST.mkdir()
    verify_demo_snapshot(proof['demo_commit'], proof['demo_sha256'])
    ipa = build_ipa(version, build, proof['demo_commit'])
    proof['release_build'] = True
    # Tests and the build must not have changed tracked files; the package is exactly this commit.
    if git('rev-parse', 'HEAD') != sha or git('status', '--porcelain'):
        raise Failure('验证或编译期间源码有变化：\n' + git('status', '--short') + '\n先还原（git checkout -- <文件>）后重新发布')
    tree = git('rev-parse', f'{sha}^{{tree}}')
    proof = dict(schema=2, source_sha=sha, tree=tree, **proof)
    manifest = dict(schema=2, repository=repo, source_sha=sha, tree=tree, version=version, build=build,
                    sha256=hashlib.sha256(ipa.read_bytes()).hexdigest(), size=ipa.stat().st_size,
                    channel='self-signing', phone_acceptance='pending', xcode=proof['xcode'],
                    demo_commit=proof['demo_commit'], demo_sha256=proof['demo_sha256'],
                    built_at=datetime.now(timezone.utc).isoformat(timespec='seconds'))
    (DIST / 'validation-evidence.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
    (DIST / 'build-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    verify_package(DIST, manifest, proof, repo)

    if os.environ.get('GITHUB_ACTIONS') == 'true':
        if git('ls-remote', 'origin', 'refs/heads/main').split()[0] != sha:
            raise Failure('main 已更新，本次旧源码安装包不发布；请重新发起开发版')
    else:
        step('推送 main 到 GitHub')
        remote_run('main_push', ['git', 'push', 'origin', 'HEAD:refs/heads/main'])

    step('发布开发版')
    notes = release_notes.render((ROOT / 'CHANGELOG.md').read_text(), release_notes.previous_changelog(repo),
                                 repo, sha, version, build, proof, ipa_sha256=manifest['sha256'])
    (DIST / 'release-notes.md').write_text(notes)
    assets = [DIST / name for name in FILES]
    title = f'Ledger X {version} 开发版'
    previous = release_for_tag(repo, 'dev')
    progress.effect('dev_release', 'started')
    if previous:
        run(['gh', 'release', 'upload', 'dev', '--repo', repo, *assets, '--clobber'])
        run(['gh', 'api', '-X', 'PATCH', f'repos/{repo}/git/refs/tags/dev', '-f', f'sha={sha}', '-F', 'force=true'])
        run(['gh', 'release', 'edit', 'dev', '--repo', repo, '--prerelease', '--title', title, '--notes-file', DIST / 'release-notes.md'])
    else:
        run(['gh', 'release', 'create', 'dev', '--repo', repo, *assets, '--target', sha, '--prerelease',
             '--title', title, '--notes-file', DIST / 'release-notes.md'])
    progress.effect('dev_release', 'done')
    update_sources(repo)
    done(f'\n✓ 已发布 Ledger X {version} 开发版（构建 {build}），main {sha[:7]}'
         f'\n  https://github.com/{repo}/releases/tag/dev\n  手机验收：待 Kerwin 执行')


def release_validation(manifest, proof):
    """A build-only dev needs full tests of its exact source before promotion; never rebuild its IPA."""
    step('确认正式版全量验证')
    if proof.get('scope') != 'build':
        try:
            verify_proof(proof, manifest, require_full=True)
        except ValueError:
            pass  # old evidence cannot prove the demo bytes; revalidate the original IPA
        else:
            return proof
    if git('status', '--porcelain'):
        raise Failure('全量验证开发版源码前，请先提交或还原工作区改动')
    sha = manifest['source_sha']
    if git('rev-parse', 'HEAD') != sha:
        raise Failure('正式版需要测试开发版的同一源码；本地 HEAD 与安装包提交不同，请在独立工作区检出该提交后再执行 release')
    cached = read_json(FULL_VALIDATION)
    try:
        verify_proof(cached, manifest, require_full=True)
    except ValueError:
        cached = {}
    if cached and cached.get('demo_commit') == proof['demo_commit']:
        return dict(cached, release_build=True)
    full = validate()
    if git('rev-parse', 'HEAD') != sha or git('status', '--porcelain'):
        raise Failure('全量验证期间源码有变化，未发布正式版')
    if full['demo_commit'] != proof['demo_commit']:
        raise Failure('全量验证与开发版的演示快照不同，未发布正式版')
    full = dict(full, schema=2, source_sha=sha, tree=git('rev-parse', f'{sha}^{{tree}}'), release_build=True)
    verify_proof(full, manifest, require_full=True)
    write_json(FULL_VALIDATION, full)
    return full


def ship_release():
    """Publish the current dev package unchanged; it is what Kerwin accepted on the phone."""
    import release_notes
    repo = repository()
    with tempfile.TemporaryDirectory() as temp:
        folder = Path(temp)
        step('下载并校验开发版')
        download(repo, 'dev', folder)
        manifest = json.loads((folder/'build-manifest.json').read_text())
        proof = json.loads((folder/'validation-evidence.json').read_text())
        demo_digest = verify_package(folder, manifest, proof, repo)
        manifest.setdefault('demo_commit', proof.get('demo_commit'))
        manifest.setdefault('demo_sha256', demo_digest)
        verify_source(repo, manifest)
        if tag_sha(repo, 'dev') != manifest['source_sha']:
            raise ValueError('开发版标签与安装包源码不一致')
        if os.environ.get('GITHUB_ACTIONS') == 'true':
            if str(manifest['build']) != os.environ.get('LEDGER_ACCEPTED_BUILD') or manifest['sha256'] != os.environ.get('LEDGER_ACCEPTED_SHA256'):
                raise Failure('当前开发版与手机验收的构建号或 SHA256 不一致，禁止转正')
        proof = release_validation_at_source(manifest, proof)
        verify_package(folder, manifest, proof, repo)
        (folder/'build-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        (folder/'validation-evidence.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
        tag = f'v{manifest["version"]}'
        # Complete version notes from the exact source, not the rolling dev delta.
        changelog = git('show', f'{manifest["source_sha"]}:CHANGELOG.md')
        (folder/'release-notes.md').write_text(release_notes.render(
            changelog, '', repo, manifest['source_sha'], manifest['version'], manifest['build'], proof, channel='release',
            ipa_sha256=manifest['sha256']))
        step(f'发布正式版 {tag}')
        publish(repo, tag, folder, manifest, folder/'release-notes.md')
    update_sources(repo)
    done(f'\n✓ 已发布正式版 {tag}（构建 {manifest["build"]}）\n  https://github.com/{repo}/releases/tag/{tag}')


def select_version(choice):
    require_clean_main()
    project = ROOT / 'project.yml'
    current = re.search(r'MARKETING_VERSION: "([^"]+)"', project.read_text())[1]
    version = next_version(current, choice)
    changelog = ROOT / 'CHANGELOG.md'
    text = changelog.read_text()
    if f'## {version}' in text:
        raise ValueError('该版本的 CHANGELOG 已存在，请核对')
    project.write_text(project.read_text().replace(f'MARKETING_VERSION: "{current}"', f'MARKETING_VERSION: "{version}"'))
    position = text.index('## ')
    changelog.write_text(text[:position] + f'## {version}（开发中）\n\n' + text[position:])
    run([sys.executable, 'tools/check_project.py'])
    run(['git', 'add', 'project.yml', 'CHANGELOG.md'])
    run(['git', 'commit', '-qm', f'Prepare Ledger X {version}'])
    print(f'✓ 已提交版本 {version}；下一次 python3 tools/ship.py dev 会推送并发布')


# Watching a run: reads .ship/status.json and the stage's log; never writes, never locks.

TITLES = {'test': '本机全部测试（test）', 'dev': '发布开发版（dev）', 'release': '发布正式版（release）'}
TESTS = ('swift-tests.log', 'interaction-tests.log')


def log_progress(name, text):
    """What a stage's log says so far: for tests (passed, failed, the one running), for builds (steps, the last)."""
    if name in TESTS:
        done = re.findall(r"Test Case '-\[(\S+ \S+)\]' (passed|failed)", text)
        finished = {case for case, _ in done}
        started = [case for case in re.findall(r"Test Case '-\[(\S+ \S+)\]' started", text) if case not in finished]
        return dict(passed=sum(r == 'passed' for _, r in done), failed=[c for c, r in done if r == 'failed'],
                    current=started[-1] if started else None)
    actions = re.findall(r'^([A-Z][A-Za-z]+) (.*)$', text, re.M)
    last = None
    if actions:
        verb, rest = actions[-1]
        files = re.findall(r'[\w.+-]+\.(?:swift|m|c|plist|xcassets|app|json)\b', rest)
        last = f'{verb} {files[-1]}' if files else verb
    return dict(steps=len(actions), last=last)


def width(text):
    import unicodedata
    return sum(2 if unicodedata.east_asian_width(ch) in 'WF' else 1 for ch in text)


def clock(seconds):
    seconds = int(max(seconds, 0))
    return f'{seconds // 3600}:{seconds // 60 % 60:02d}:{seconds % 60:02d}' if seconds >= 3600 else f'{seconds // 60}:{seconds % 60:02d}'


def render(state, history, logs, now, alive=True):
    """The watch screen for one moment. `logs` maps log names to their text so far; `alive`: the run's process exists."""
    if not state:
        return '还没有 ship.py 的运行记录；执行 python3 tools/ship.py test 或 dev 后再看。'
    command = state.get('command', '')
    stages = state.get('stages', [])
    result = state.get('result')
    end = state.get('ended', now)
    if result == 'passed':
        status = f'✓ 完成，用时 {clock(end - state["started"])}'
    elif result == 'failed':
        status = f'✗ 失败，用时 {clock(end - state["started"])}'
    elif result == 'interrupted':
        status = f'✗ 已中断，用时 {clock(end - state["started"])}'
    elif not alive:
        status = '✗ 已中断（进程不在了）'
    else:
        status = f'进行中，已用 {clock(now - state["started"])}'
    lines = [f'Ledger X · {TITLES.get(command, command)} · {status}', '']
    names = [stage['name'] for stage in stages]
    pending = [p for p in state.get('plan', PLAN.get(command, ())) if not any(n.startswith(p) for n in names)]
    pad = max([width(n) for n in names + pending] or [0]) + 2
    for i, stage in enumerate(stages):
        unfinished = i == len(stages) - 1 and 'ended' not in stage and result is None
        running = unfinished and alive
        mark = '✗' if stage.get('failed') or (unfinished and not alive) else '▶' if running else '✓'
        spent = clock(stage.get('ended', now) - stage['started'])
        detail = stage.get('note', '')
        log = state.get('log') if i == len(stages) - 1 else None
        extra = None
        if log and log in logs and not detail:
            info = log_progress(log, logs[log])
            expected = history.get(log)
            if log in TESTS:
                count = f'{info["passed"]} / {expected}' if expected else f'{info["passed"]}'
                detail = f'{count} 通过 · {len(info["failed"])} 失败'
                if info['current'] and running:
                    extra = f'当前：{info["current"]}'
                if info['failed']:
                    extra = '失败：' + '、'.join(info['failed'][-3:]) + (f'\n      当前：{info["current"]}' if info['current'] and running else '')
            else:
                detail = f'{info["steps"]} / {expected} 步' if expected else f'{info["steps"]} 步'
                if info['last'] and running:
                    extra = f'最近：{info["last"]}'
        lines.append(f'  {mark} {stage["name"]}{" " * (pad - width(stage["name"]))}{spent:>7}  {detail}'.rstrip())
        if extra:
            lines.append(f'      {extra}')
    for name in pending if result is None and alive else ():
        lines.append(f'  ○ {name}')
    if result in ('failed', 'interrupted') or (result is None and not alive):
        for name in pending:
            lines.append(f'  — {name}（未运行）')
    if state.get('log') and result is None:
        lines += ['', f'日志：{state["log"]}']
    if state.get('message'):
        lines += ['', state['message']]
    if result is None and not alive:
        lines += ['', failure_message('进程已退出，未留下最终结论', interrupted=True, state=state)]
    return '\n'.join(lines)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def watch(once=False):
    """Follow the run in .ship/status.json until it ends (or show the last one), redrawn every second."""
    tty = sys.stdout.isatty() and not once
    while True:
        state = read_json(STATUS)
        logs = {}
        if state.get('log') and (ROOT / state['log']).exists() and (ROOT / state['log']).stat().st_mtime >= state['started']:
            logs[state['log']] = (ROOT / state['log']).read_text(errors='replace')
        running = bool(state) and state.get('result') is None and alive(state.get('pid', 0))
        screen = render(state, read_json(HISTORY), logs, time.time(), alive=running or bool(state.get('result')))
        print(('\033[H\033[J' if tty else '') + screen, flush=True)
        if once or not running:
            return 0
        time.sleep(1)


def run_totals(started):
    """Test and build-step counts of the logs this run wrote, kept for the next run's "41 / 64"."""
    totals = {}
    for name in (*TESTS, 'demo-build.log', 'build.log'):
        path = ROOT / name
        if path.exists() and path.stat().st_mtime >= started:
            info = log_progress(name, path.read_text(errors='replace'))
            totals[name] = info['passed'] if name in TESTS else info['steps']
    return totals


def worker_main(argv):
    command = argv[1] if len(argv) > 1 else ''
    usage = __doc__.split('\n\n')[1]
    if command == 'watch' and argv[2:] in ([], ['--once']):
        return watch(once=argv[2:] == ['--once'])
    full = command == 'dev' and argv[2:] == ['--full']
    if command not in ('test', 'dev', 'release', 'version') or len(argv) != (3 if command == 'version' or full else 2):
        print(usage, file=sys.stderr)
        return 2
    # One publication at a time on this Mac.
    lock = open(Path(tempfile.gettempdir()) / 'ledger-x-ship.lock', 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('已有另一个 ship.py 在运行', file=sys.stderr)
        return 1
    if command != 'version':
        progress.begin(command)
    else:
        progress.state = None
    try:
        if command == 'test':
            source = None if git('status', '--porcelain') else git('rev-parse', 'HEAD')
            FULL_VALIDATION.unlink(missing_ok=True)
            proof = validate_targeted() if selected_tests() else validate()
            if source and not selected_tests() and git('rev-parse', 'HEAD') == source and not git('status', '--porcelain'):
                write_json(FULL_VALIDATION, dict(proof, schema=2, source_sha=source,
                                               tree=git('rev-parse', f'{source}^{{tree}}')))
            if selected_tests():
                write_json(ROOT / '.ship/selected-validation.json', dict(proof, source_sha=git('rev-parse', 'HEAD')))
                done('✓ 指定测试通过；未执行全量验证，不发布安装包')
            else:
                done(f'\n✓ 全部通过：核心 {proof["core_tests"]} 项，交互 {proof["interaction_tests"]} 项；{proof["reports"]}')
        elif command == 'dev':
            if full:
                progress.state['plan'] = list(PLAN['test'] + PLAN['dev'][1:])
            ship_dev(full=full)
        elif command == 'release':
            ship_release()
        else:
            select_version(argv[2])
    except KeyboardInterrupt as error:
        message = failure_message(error, interrupted=True)
        print(f'\n{message}', file=sys.stderr)
        progress.finish(False, message, interrupted=True)
        return 130
    except Exception as error:
        message = failure_message(error)
        print(f'\n{message}', file=sys.stderr)
        progress.finish(False, message)
        return 1
    progress.finish(True, totals=progress.state and run_totals(progress.state['started']))
    return 0


def main(argv):
    if len(argv) > 1 and argv[1] == 'version':
        return worker_main(argv)
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        return worker_main(argv)
    import cloud
    return cloud.main(argv[1:])


if __name__ == '__main__':
    sys.exit(main(sys.argv))
