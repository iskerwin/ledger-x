#!/usr/bin/env python3
"""Lightweight GitHub Actions client. No Xcode, simulator, signing credentials or local build."""
import argparse
import json
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / '.ship/cloud.json'
WORKFLOW = 'ledger.yml'


def output(command, **kwargs):
    return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=True, **kwargs).stdout.strip()


def accepted_manifest(manifest, build):
    if str(manifest.get('build')) != build or not re.fullmatch(r'[0-9a-f]{64}', str(manifest.get('sha256', ''))):
        raise ValueError('当前开发版不是你验收的构建号，或清单缺少有效 SHA256；未发起转正')
    return manifest['sha256']


def dispatch(args):
    import ship
    ship.require_clean_main()
    repo = ship.repository()
    sha = ship.git('rev-parse', 'HEAD')
    inputs = dict(command=args.command, source_sha=sha, full=str(args.full).lower(),
                  core_filter=args.core_filter or '', ui_tests='\n'.join(args.ui_test), device=args.device or '')
    if args.command == 'release':
        if not args.accepted_build:
            raise ValueError('转正式版须先由 Kerwin 手机验收，再指定 --accepted-build 构建号')
        with __import__('tempfile').TemporaryDirectory() as temp:
            output(['gh', 'release', 'download', 'dev', '--repo', repo, '--pattern', 'build-manifest.json', '--dir', temp])
            manifest = json.loads((Path(temp) / 'build-manifest.json').read_text())
        inputs.update(accepted_build=args.accepted_build, accepted_sha256=accepted_manifest(manifest, args.accepted_build))
    request = uuid.uuid4().hex
    inputs['request_id'] = request
    # Source must be on main before GitHub can check it. A failed cloud check publishes no IPA.
    output(['git', 'push', 'origin', 'HEAD:refs/heads/main'])
    output(['gh', 'api', '--method', 'POST', f'repos/{repo}/actions/workflows/{WORKFLOW}/dispatches',
            '--input', '-'], input=json.dumps(dict(ref='main', inputs=inputs)))
    STATE.parent.mkdir(exist_ok=True)
    state = dict(repository=repo, request_id=request, source_sha=sha, command=args.command)
    STATE.write_text(json.dumps(state, indent=2))
    print(f'已推送 main {sha[:7]}，已发起云端 {args.command}；尚无测试或发布结论。', flush=True)
    print(f'https://github.com/{repo}/actions/workflows/{WORKFLOW}', flush=True)
    for _ in range(15):
        runs = json.loads(output(['gh', 'api', f'repos/{repo}/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=50']))['workflow_runs']
        match = next((run for run in runs if request in run['display_title']), None)
        if match:
            state['run_id'] = match['id']
            STATE.write_text(json.dumps(state, indent=2))
            print(match['html_url'])
            return 0
        time.sleep(2)
    print('GitHub 已接受请求，运行编号尚未查到；用 ship.py watch 重查。')
    return 0


def watch(once):
    state = json.loads(STATE.read_text())
    repo = state['repository']
    if 'run_id' not in state:
        runs = json.loads(output(['gh', 'api', f'repos/{repo}/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=100']))['workflow_runs']
        match = next((run for run in runs if state['request_id'] in run['display_title']), None)
        if not match:
            raise ValueError('任务尚未出现，请查看仓库 Actions；不代表任务失败或通过')
        state['run_id'] = match['id']
        STATE.write_text(json.dumps(state, indent=2))
    if once:
        return subprocess.run(['gh', 'run', 'view', str(state['run_id']), '--repo', repo], cwd=ROOT).returncode
    return subprocess.run(['gh', 'run', 'watch', str(state['run_id']), '--repo', repo, '--exit-status'], cwd=ROOT).returncode


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('test', 'dev', 'release'):
        p = sub.add_parser(name)
        p.add_argument('--full', action='store_true')
        p.add_argument('--core-filter')
        p.add_argument('--ui-test', action='append', default=[])
        p.add_argument('--device')
        p.add_argument('--accepted-build')
    p = sub.add_parser('watch')
    p.add_argument('--once', action='store_true')
    args = parser.parse_args(argv)
    try:
        if args.command == 'watch':
            return watch(args.once)
        if args.full and (args.core_filter or args.ui_test):
            raise ValueError('--full 不能和指定测试混用')
        if args.command != 'release' and args.accepted_build:
            raise ValueError('--accepted-build 只用于手机验收后的转正')
        if args.command == 'release' and (args.core_filter or args.ui_test or args.device or args.full):
            raise ValueError('转正自动核对并补齐同一源码的全量记录，不接受测试筛选')
        if args.command == 'dev' and not args.full and not (args.core_filter or args.ui_test):
            raise ValueError('开发版须指定与改动相关的测试（--core-filter / --ui-test），或显式 --full；未发起推送或发布')
        if any(not re.fullmatch(r'Ledger(?:UI)?Tests/[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)?', value) for value in args.ui_test):
            raise ValueError('--ui-test 须为 Target/Class[/method]')
        return dispatch(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'云端任务未确认完成：{error}；请核查 main、Actions、Release 与安装源实际状态。', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
