#!/usr/bin/env python3
"""Generate user-facing development notes from changes since the previous dev."""
from collections import Counter
import json
import re
import subprocess

GROUPS = ('新增', '修复', '改进')
ALIASES = {'新功能': '新增', '新增': '新增', '修复': '修复', '优化': '改进', '更新': '改进', '改进': '改进'}


def entries(text, version):
    result = {name: [] for name in GROUPS}
    active = False
    found = False
    group = None
    for line in text.splitlines():
        if line.startswith('## '):
            active = bool(re.match(r'^## ' + re.escape(version) + r'(?:\s|（|\(|$)', line))
            found |= active
            group = None
        elif active and line.startswith('### '):
            group = ALIASES.get(line[4:].strip())
        elif active and group and line.startswith('- '):
            result[group].append(line[2:].strip())
    if not found:
        raise ValueError(f'CHANGELOG.md has no section for version {version}')
    return result


def changes(current, previous, version):
    now = entries(current, version)
    if previous:
        try:
            before = entries(previous, version)
        except ValueError:
            before = {name: [] for name in GROUPS}  # First build of a new version.
    else:
        before = {name: [] for name in GROUPS}
    result = {}
    for name in GROUPS:
        seen = Counter(before[name])
        result[name] = []
        for item in now[name]:
            if seen[item]:
                seen[item] -= 1
            else:
                result[name].append(item)
    return result


def render(current, previous, repo, sha, version, build, proof, channel="dev"):
    label = {"dev": "开发版", "release": "正式版"}[channel]
    updates = changes(current, previous, version)
    parts = [f'# Ledger X {version} {label}', f'版本 {version} · 构建 {build} · main {sha[:7]} 。']
    for name in GROUPS:
        if updates[name]:
            parts += [f'## {name}', '\n'.join(f'- {item}' for item in updates[name])]
    if not any(updates.values()):
        parts += ['## 本次更新', '- 本次没有新增用户可见的功能或修复记录，为重新构建或发布流程维护。']
    github = f'https://raw.githubusercontent.com/{repo}/ipa/{channel}.json'
    mirror = f'https://gh-proxy.com/https://raw.githubusercontent.com/{repo}/ipa/mirror/{channel}.json'
    parts += ['---', f'## 添加{label} IPA 源',
              f'- GitHub：{github}\n- 镜像（gh-proxy.com）：{mirror}',
              '在支持 IPA 源的安装工具（如 SideStore、AltStore、Zeus）中添加其中一个地址；国内网络建议用镜像，安装包也会经镜像下载。',
              '## 验证记录',
              f'本机验证通过：核心测试 {proof["core_tests"]} 项、Beancount 报表对照、模拟器附件与交互测试 '
              f'{proof["interaction_tests"]} 项（{proof["xcode"]}，{proof["simulator"]}）；'
              'iOS 设备 Release 编译、签名与安装包完整性检查已通过。'
              + ('手机验收已由 Kerwin 完成。' if channel == 'release' else '手机验收待 Kerwin 执行。'),
              f'- [源码提交](https://github.com/{repo}/commit/{sha})',
              f'安装更新前先备份并确认未同步内容；安装后按 [手机验收清单](https://github.com/{repo}/blob/{sha}/docs/development/06-手机验收清单.md) 验证。']
    return '\n\n'.join(parts) + '\n'


def previous_changelog(repo):
    result = subprocess.run(['gh', 'api', f'repos/{repo}/git/ref/tags/dev'], text=True, capture_output=True)
    if result.returncode:
        if 'HTTP 404' in result.stderr:
            return ''  # New repository: no prior development release.
        raise RuntimeError(result.stderr)
    ref = json.loads(result.stdout)['object']
    # git show dereferences either lightweight or annotated tags.
    return subprocess.check_output(['git', 'show', f"{ref['sha']}:CHANGELOG.md"], text=True)

