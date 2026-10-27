#!/usr/bin/env python3
"""GitHub-hosted worker entry; untrusted workflow inputs are never interpolated into shell code."""
import json
import os
import re
import sys
import ship


def prepare():
    sha = os.environ['LEDGER_SOURCE_SHA']
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ship.Failure('源码须为完整 40 位 SHA')
    ship.run(['git', 'fetch', 'origin', 'main'])
    if __import__('subprocess').run(['git', 'merge-base', '--is-ancestor', sha, 'origin/main'], cwd=ship.ROOT).returncode:
        raise ship.Failure('源码提交不在 main 上')
    # Retain the current orchestration for release; its source-bound validator uses an isolated worktree.
    if os.environ['LEDGER_COMMAND'] != 'release':
        ship.run(['git', 'checkout', '-B', 'main', sha])


def run():
    command = os.environ['LEDGER_COMMAND']
    if command not in ('test', 'dev', 'release'):
        raise ship.Failure('未知云端任务')
    if command == 'release' and (not os.environ.get('LEDGER_ACCEPTED_BUILD') or not os.environ.get('LEDGER_ACCEPTED_SHA256')):
        raise ship.Failure('手机验收构建号和 SHA256 必填')
    if os.environ.get('LEDGER_FULL') == 'true' and ship.selected_tests():
        raise ship.Failure('全量与指定测试不能混用')
    if command == 'release' and (ship.selected_tests() or os.environ.get('LEDGER_SIMULATOR_DEVICE')):
        raise ship.Failure('转正不允许筛选测试或更换机型')
    return ship.worker_main(['ship.py', command] + (['--full'] if command == 'dev' and os.environ.get('LEDGER_FULL') == 'true' else []))


if __name__ == '__main__':
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        sys.exit('此入口只在 GitHub Actions 执行；本机使用 ship.py')
    try:
        sys.exit(prepare() if sys.argv[1:] == ['prepare'] else run())
    except Exception as error:
        sys.exit(str(error))
