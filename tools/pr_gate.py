#!/usr/bin/env python3
"""Pull-request gate. Static checks, tool tests, and tests relevant to the diff. Never publishes."""
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_scope
import ship

# A hung compile or a dialog that never arrives should fail the job, not sit until the
# runner's outer limit. Per-test allowance is xcodebuild's own cap; the others bound the process.
SWIFT_LIMIT = 12 * 60
BUILD_LIMIT = 20 * 60
UI_LIMIT = 25 * 60
TEST_ALLOWANCE = 180
BOOT_LIMIT = 120


def _base(base):
    if not re.fullmatch(r'[0-9a-f]{40}', base):
        raise ship.Failure('PR 基线必须是完整 SHA')
    return base


def changed_paths(base):
    base = _base(base)
    out = subprocess.check_output(['git', 'diff', '--name-only', f'{base}...HEAD'], cwd=ship.ROOT, text=True)
    return [line.strip() for line in out.splitlines() if line.strip()]


def changed_diff(base):
    base = _base(base)
    return subprocess.check_output(['git', 'diff', f'{base}...HEAD'], cwd=ship.ROOT, text=True)


def mark(message):
    print(f'{time.strftime("%H:%M:%SZ", time.gmtime())} {message}', flush=True)


def run_limited(cmd, timeout, **kwargs):
    try:
        return ship.run(cmd, timeout=timeout, **kwargs)
    except subprocess.TimeoutExpired as error:
        raise ship.Failure(f'{" ".join(str(part) for part in error.cmd[:3])} 超过 {int(error.timeout)} 秒，已停止') from error


def main(argv):
    started = time.monotonic()
    base = _base(argv[1] if len(argv) > 1 else os.environ.get('PR_BASE_SHA', ''))
    paths = changed_paths(base)
    plan = pr_scope.classify(paths, diff=changed_diff(base))
    print(f'PR 范围：swift={plan["swift"] or "无"}，编译 App 测试={plan["xcode_build"]}，'
          f'执行 {", ".join(plan["xcode_tests"]) or "无"}；不发布安装包', flush=True)
    run_limited([sys.executable, 'tools/check_project.py'], 5 * 60)
    run_limited([sys.executable, '-m', 'unittest', 'discover', '-s', 'tools/tests', '-p', 'test_*.py'],
                5 * 60, log='tools-tests.log')
    if plan['swift']:
        mark('开始核心测试')
        phase = time.monotonic()
        ship.demo_snapshot()
        command = ['swift', 'test', '--package-path', 'LedgerKit', *ship.TYPECHECK_FLAGS]
        if plan['swift'] != 'all':
            command += ['--filter', plan['swift']]
        run_limited(command, SWIFT_LIMIT, log='swift-tests.log', env=dict(
            os.environ, LEDGER_DEMO_PATH=str(ship.ROOT / '.demo-data'), SAMPLE_OUT=str(ship.ROOT / 'samples')))
        count, failed = ship.executed((ship.ROOT / 'swift-tests.log').read_text(errors='replace'))
        if failed or count == 0:
            raise ship.Failure('相关核心测试失败或没有实际执行')
        mark(f'核心测试 {count} 项通过（{(time.monotonic() - phase) / 60:.1f} 分钟）')
    if plan['xcode_build']:
        ship.use_xcode()
        udid = None
        if plan['xcode_tests']:
            mark('开始准备模拟器')
            phase = time.monotonic()
            udid, simulator = ship.fresh_simulator(boot_timeout=BOOT_LIMIT, ready_timeout=BOOT_LIMIT)
            mark(f'模拟器已就绪：{simulator}（{(time.monotonic() - phase) / 60:.1f} 分钟）')
            destination = f'platform=iOS Simulator,id={udid}'
        else:
            destination = 'generic/platform=iOS Simulator'
        try:
            run_limited(['xcodegen', 'generate', '--quiet'], 3 * 60)
            mark('开始编译 App 测试包')
            phase = time.monotonic()
            run_limited(['xcodebuild', 'build-for-testing', '-project', 'Ledger.xcodeproj',
                         '-scheme', 'LedgerInteractionTests', '-destination', destination,
                         '-derivedDataPath', 'build-demo', 'CODE_SIGNING_ALLOWED=NO'],
                        BUILD_LIMIT, log='demo-build.log')
            mark(f'编译完成（{(time.monotonic() - phase) / 60:.1f} 分钟）')
            if plan['xcode_tests']:
                mark(f'开始界面与 App 内测试 {len(plan["xcode_tests"])} 项，每项最多 {TEST_ALLOWANCE} 秒')
                phase = time.monotonic()
                run_limited(['xcodebuild', 'test-without-building', '-project', 'Ledger.xcodeproj',
                             '-scheme', 'LedgerInteractionTests', '-destination', destination,
                             '-derivedDataPath', 'build-demo', '-parallel-testing-enabled', 'NO',
                             '-test-timeouts-enabled', 'YES',
                             '-maximum-test-execution-time-allowance', str(TEST_ALLOWANCE),
                             '-resultBundlePath', 'interaction-tests.xcresult',
                             *['-only-testing:' + name for name in plan['xcode_tests']]],
                            UI_LIMIT, log='interaction-tests.log')
                mark(f'界面与 App 内测试完成（{(time.monotonic() - phase) / 60:.1f} 分钟）')
        finally:
            if udid:
                subprocess.run(['xcrun', 'simctl', 'shutdown', udid], capture_output=True)
    mark(f'PR 门禁通过；未发布安装包（共 {(time.monotonic() - started) / 60:.1f} 分钟）')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv))
    except (OSError, ship.Failure, subprocess.CalledProcessError) as error:
        print(f'PR 门禁未通过：{error}；未发布安装包', file=sys.stderr)
        sys.exit(1)
