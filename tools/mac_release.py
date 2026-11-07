#!/usr/bin/env python3
"""Publishes the Mac app of the newest main at a fixed address: the `mac` prerelease, which is never the latest release
and which Dev, Release and the IPA sources don't read."""
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_gate
import ship

TAG = 'mac'


def main():
    repo = os.environ.get('GITHUB_REPOSITORY') or ship.repository()
    sha = ship.git('rev-parse', 'HEAD')
    pr_gate.build_mac()
    # checked after the build: an older source, or a branch, never replaces the newest main's app
    if ship.out(['git', 'ls-remote', 'origin', 'refs/heads/main']).split()[0] != sha:
        print(f'{sha[:7]} 不是最新的 main，未发布', flush=True)
        return 0
    ship.step('发布 Mac App')
    notes = f'源码 {sha[:7]}'
    if ship.release_for_tag(repo, TAG):
        ship.run(['gh', 'release', 'upload', TAG, '--repo', repo, 'LedgerMac.zip', '--clobber'])
        ship.run(['gh', 'api', '-X', 'PATCH', f'repos/{repo}/git/refs/tags/{TAG}', '-f', f'sha={sha}', '-F', 'force=true'])
        ship.run(['gh', 'release', 'edit', TAG, '--repo', repo, '--prerelease', '--notes', notes])
    else:
        ship.run(['gh', 'release', 'create', TAG, 'LedgerMac.zip', '--repo', repo, '--target', sha, '--prerelease',
                  '--title', 'Ledger X for Mac', '--notes', notes])
    print(f'已发布 Mac App，源码 {sha[:7]}', flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ship.Failure, subprocess.CalledProcessError) as error:
        print(f'Mac App 未发布：{error}', file=sys.stderr)
        sys.exit(1)
