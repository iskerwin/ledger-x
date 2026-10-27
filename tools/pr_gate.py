#!/usr/bin/env python3
"""Pull-request gate. Static checks, tool tests, and tests relevant to the diff. Never publishes."""
import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_scope
import ship


def changed_paths(base):
    if not re.fullmatch(r'[0-9a-f]{40}', base):
        raise ship.Failure('PR 基线必须是完整 SHA')
    out = subprocess.check_output(['git', 'diff', '--name-only', f'{base}...HEAD'], cwd=ship.ROOT, text=True)
    return [line.strip() for line in out.splitlines() if line.strip()]


def main(argv):
    base = argv[1] if len(argv) > 1 else os.environ.get('PR_BASE_SHA', '')
    paths = changed_paths(base)
    plan = pr_scope.classify(paths)
    print(f'PR 范围：swift={plan["swift"] or "无"}，编译 App 测试={plan["xcode_build"]}，'
          f'执行 {", ".join(plan["xcode_tests"]) or "无"}；不发布安装包', flush=True)
    ship.run([sys.executable, 'tools/check_project.py'])
    ship.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tools/tests', '-p', 'test_*.py'],
             log='tools-tests.log')
    if plan['swift']:
        ship.demo_snapshot()
        command = ['swift', 'test', '--package-path', 'LedgerKit', *ship.TYPECHECK_FLAGS]
        if plan['swift'] != 'all':
            command += ['--filter', plan['swift']]
        ship.run(command, log='swift-tests.log', env=dict(
            os.environ, LEDGER_DEMO_PATH=str(ship.ROOT / '.demo-data'), SAMPLE_OUT=str(ship.ROOT / 'samples')))
        count, failed = ship.executed((ship.ROOT / 'swift-tests.log').read_text(errors='replace'))
        if failed or count == 0:
            raise ship.Failure('相关核心测试失败或没有实际执行')
        print(f'核心测试 {count} 项通过', flush=True)
    if plan['xcode_build']:
        ship.use_xcode()
        udid = None
        if plan['xcode_tests']:
            udid, _simulator = ship.fresh_simulator()
            destination = f'platform=iOS Simulator,id={udid}'
        else:
            destination = 'generic/platform=iOS Simulator'
        try:
            ship.run(['xcodegen', 'generate', '--quiet'])
            ship.run(['xcodebuild', 'build-for-testing', '-project', 'Ledger.xcodeproj',
                      '-scheme', 'LedgerInteractionTests', '-destination', destination,
                      '-derivedDataPath', 'build-demo', 'CODE_SIGNING_ALLOWED=NO'], log='demo-build.log')
            if plan['xcode_tests']:
                ship.run(['xcodebuild', 'test-without-building', '-project', 'Ledger.xcodeproj',
                          '-scheme', 'LedgerInteractionTests', '-destination', destination,
                          '-derivedDataPath', 'build-demo', '-parallel-testing-enabled', 'NO',
                          '-test-timeouts-enabled', 'YES',
                          '-maximum-test-execution-time-allowance', str(ship.TEST_TIMEOUT),
                          '-resultBundlePath', 'interaction-tests.xcresult',
                          *['-only-testing:' + name for name in plan['xcode_tests']]],
                         log='interaction-tests.log')
        finally:
            if udid:
                subprocess.run(['xcrun', 'simctl', 'shutdown', udid], capture_output=True)
    print('PR 门禁通过；未发布安装包', flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv))
    except (OSError, ship.Failure, subprocess.CalledProcessError) as error:
        print(f'PR 门禁未通过：{error}；未发布安装包', file=sys.stderr)
        sys.exit(1)
