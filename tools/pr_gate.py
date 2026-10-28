#!/usr/bin/env python3
"""Pull-request gate: the same automatic plan and executor as Dev, on the PR's merge result. Never publishes.
A passing gate leaves .ship/pr-proof.json; Dev reuses it when main is that same tree and the plan is unchanged."""
import os
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dev_scope
import ship

PROOF = ship.ROOT / '.ship/pr-proof.json'


def main(argv):
    started = time.monotonic()
    repo = os.environ.get('GITHUB_REPOSITORY') or ship.repository()
    sha = ship.git('rev-parse', 'HEAD')
    plan = dev_scope.select(repo, sha)
    summary = dev_scope.describe(plan).replace('## Dev 自动测试范围', '## PR 测试范围（与开发版相同）')
    print(summary, flush=True)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as target:
            target.write(summary)
    # Dev's executor: the same schemes, phase limits, per-test allowance and streamed logs.
    os.environ['LEDGER_COMMAND'] = 'dev'
    proof = dev_scope.validate(plan)
    if ship.git('rev-parse', 'HEAD') != sha or ship.git('status', '--porcelain'):
        raise ship.Failure('测试期间源码有变化，未留下 PR 测试记录')
    ship.write_json(PROOF, dict(proof, schema=1, source_sha=sha, tree=ship.git('rev-parse', f'{sha}^{{tree}}')))
    print(f'PR 门禁通过；未发布安装包（共 {(time.monotonic() - started) / 60:.1f} 分钟）', flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv))
    except (OSError, ship.Failure, subprocess.CalledProcessError) as error:
        print(f'PR 门禁未通过：{error}；未发布安装包', file=sys.stderr)
        sys.exit(1)
