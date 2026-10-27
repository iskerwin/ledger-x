#!/usr/bin/env python3
"""GitHub-hosted worker entry; untrusted workflow inputs are never interpolated into shell code."""
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import ship


def prepare():
    sha = os.environ['LEDGER_SOURCE_SHA']
    command = os.environ.get('LEDGER_COMMAND', '')
    validate_inputs()
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ship.Failure('源码须为完整 40 位 SHA')
    ref = os.environ.get('GITHUB_REF', '')
    # A branch may run read-only tests of its own tip. Publication stays on main.
    if ref and ref != 'refs/heads/main':
        if command != 'test':
            raise ship.Failure('开发版和正式版只能在 main 上发布')
        if ship.git('rev-parse', 'HEAD') != sha:
            raise ship.Failure('分支上的测试只能验证该分支当前提交，且不发布')
        return
    ship.run(['git', 'fetch', 'origin', 'main'])
    if __import__('subprocess').run(['git', 'merge-base', '--is-ancestor', sha, 'origin/main'], cwd=ship.ROOT).returncode:
        raise ship.Failure('源码提交不在 main 上')
    # Retain the current orchestration for release; its source-bound validator uses an isolated worktree.
    if command != 'release':
        ship.run(['git', 'checkout', '-B', 'main', sha])
    else:
        # Resolve once before testing. run() and ship_release() retain this identity,
        # even if a later network operation sees different dev assets.
        import cloud
        with tempfile.TemporaryDirectory() as temp:
            ship.run(['gh', 'release', 'download', 'dev', '--repo', ship.repository(),
                      '--pattern', 'build-manifest.json', '--dir', temp])
            manifest = ship.read_json(Path(temp) / 'build-manifest.json')
        digest = cloud.accepted_manifest(manifest, os.environ['LEDGER_ACCEPTED_BUILD'])
        with open(os.environ['GITHUB_ENV'], 'a') as env:
            env.write(f'LEDGER_ACCEPTED_SHA256={digest}\n')
        os.environ['LEDGER_ACCEPTED_SHA256'] = digest


def validate_inputs():
    command = os.environ.get('LEDGER_COMMAND', '')
    if command not in ('test', 'dev', 'release'):
        raise ship.Failure('未知云端任务')
    if command == 'release' and not re.fullmatch(r'[1-9][0-9]*', os.environ.get('LEDGER_ACCEPTED_BUILD', '')):
        raise ship.Failure('请填写手机验收过的构建号，只填正整数，例如 123；校验值由程序自动获取')
    if os.environ.get('LEDGER_FULL') == 'true' and ship.selected_tests():
        raise ship.Failure('全量与指定测试不能混用')
    if command == 'release' and (ship.selected_tests() or os.environ.get('LEDGER_SIMULATOR_DEVICE')):
        raise ship.Failure('转正不允许筛选测试或更换机型')
    if command == 'release' and os.environ.get('LEDGER_FULL') == 'true':
        raise ship.Failure('Release 自动核对并补齐全量，不接受测试范围参数')
    selectors = os.environ.get('LEDGER_UI_TESTS', '').split()
    if any(not re.fullmatch(r'Ledger(?:UI)?Tests/[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)?', value) for value in selectors):
        raise ship.Failure('ui_tests 请填 Target/Class[/method]，例如 LedgerTests/AppearanceTests；多个用空格分隔')


def run():
    validate_inputs()
    command = os.environ['LEDGER_COMMAND']
    if command == 'release' and not re.fullmatch(r'[0-9a-f]{64}', os.environ.get('LEDGER_ACCEPTED_SHA256', '')):
        raise ship.Failure('缺少自动绑定的验收包校验值；请从 Ledger Release 工作流重新发起')
    return ship.worker_main(['ship.py', command] + (['--full'] if command == 'dev' and os.environ.get('LEDGER_FULL') == 'true' else []))


if __name__ == '__main__':
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        sys.exit('此入口只在 GitHub Actions 执行；本机使用 ship.py')
    try:
        sys.exit(prepare() if sys.argv[1:] == ['prepare'] else run())
    except Exception as error:
        sys.exit(str(error))
