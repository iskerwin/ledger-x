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
    # A branch may run read-only tests of its own tip, or build a preview of it. Dev and Release stay on main.
    if (ref and ref != 'refs/heads/main') or command == 'preview':
        if command not in ('test', 'preview'):
            raise ship.Failure('开发版和正式版只能在 main 上发布')
        if ship.git('rev-parse', 'HEAD') != sha:
            raise ship.Failure('分支上的任务只能针对该分支当前提交')
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
    if command not in ('test', 'dev', 'preview', 'release'):
        raise ship.Failure('未知云端任务')
    if command == 'release' and not re.fullmatch(r'[1-9][0-9]*', os.environ.get('LEDGER_ACCEPTED_BUILD', '')):
        raise ship.Failure('请填写手机验收过的构建号，只填正整数，例如 123；校验值由程序自动获取')
    if os.environ.get('LEDGER_FULL') == 'true' and ship.selected_tests():
        raise ship.Failure('全量与指定测试不能混用')
    if command == 'preview' and (ship.selected_tests() or os.environ.get('LEDGER_FULL') == 'true'):
        raise ship.Failure('预览包只做静态检查和编译，不接受测试参数')
    if command == 'release' and (ship.selected_tests() or os.environ.get('LEDGER_SIMULATOR_DEVICE')):
        raise ship.Failure('转正不允许筛选测试或更换机型')
    if command == 'release' and os.environ.get('LEDGER_FULL') == 'true':
        raise ship.Failure('Release 自动核对并补齐全量，不接受测试范围参数')
    if command == 'dev' and os.environ.get('LEDGER_FULL') == 'true':
        raise ship.Failure('Dev 只运行相关模块测试，不接受全量参数；全量验证在 Release 转正前执行')
    selectors = os.environ.get('LEDGER_UI_TESTS', '').split()
    if any(not re.fullmatch(r'Ledger(?:UI)?Tests/[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)?', value) for value in selectors):
        raise ship.Failure('ui_tests 请填 Target/Class[/method]，例如 LedgerTests/AppearanceTests；多个用空格分隔')


def plan_release():
    """Before any tests: check the accepted build, then say which source the full suite is for and whether this run
    must still run it (no reusable record yet, and that source's tooling can run it as two halves)."""
    import cloud
    build = os.environ.get('LEDGER_ACCEPTED_BUILD', '')
    if not re.fullmatch(r'[1-9][0-9]*', build):
        raise ship.Failure('请填写手机验收过的构建号，只填正整数，例如 123；校验值由程序自动获取')
    with tempfile.TemporaryDirectory() as temp:
        ship.run(['gh', 'release', 'download', 'dev', '--repo', ship.repository(),
                  '--pattern', 'build-manifest.json', '--dir', temp])
        manifest = ship.read_json(Path(temp) / 'build-manifest.json')
    cloud.accepted_manifest(manifest, build)
    sha = manifest['source_sha']
    if not re.fullmatch(r'[0-9a-f]{40}', str(sha)):
        raise ship.Failure('开发版清单缺少有效的源码提交')
    halves = 'LEDGER_SHARD' in ship.git('show', f'{sha}:tools/ship.py')
    full = halves and not ship.cloud_full_validation(manifest)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'source_sha={sha}\nfull={"true" if full else "false"}\n')
    print(f'源码 {sha[:7]}：' + ('分两份跑全量' if full else '已有全量记录可复用' if halves else
                                 '该源码的工具不支持分两份，转正时按原方式跑全量'), flush=True)


def run():
    validate_inputs()
    command = os.environ['LEDGER_COMMAND']
    if command == 'release' and not re.fullmatch(r'[0-9a-f]{64}', os.environ.get('LEDGER_ACCEPTED_SHA256', '')):
        raise ship.Failure('缺少自动绑定的验收包校验值；请从 Ledger Release 工作流重新发起')
    return ship.worker_main(['ship.py', command])


if __name__ == '__main__':
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        sys.exit('此入口只在 GitHub Actions 执行；本机使用 ship.py')
    try:
        sys.exit(prepare() if sys.argv[1:] == ['prepare'] else plan_release() if sys.argv[1:] == ['plan'] else run())
    except Exception as error:
        sys.exit(str(error))
