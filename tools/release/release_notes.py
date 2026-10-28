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


def render(current, previous, repo, sha, version, build, proof, channel="dev", ipa_sha256=None):
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
    if proof.get('scope') == 'build':
        validation = ('本次发布通过静态检查、发布工具回归、iOS 设备 Release 编译、签名与安装包完整性检查'
                      f'（{proof["xcode"]}）。本次未执行完整全量验证；实际运行的相关/模块测试按下列记录列出，'
                      '独立 Beancount 报表全量对照留到转正前执行。')
    else:
        validation = (f'{"GitHub macOS 验证通过" if proof.get("validator") == "github-actions" else "本机验证通过"}：核心测试 {proof["core_tests"]} 项、Beancount 报表对照、模拟器附件与交互测试 '
                      f'{proof["interaction_tests"]} 项（{proof["xcode"]}，{proof["simulator"]}）；'
                      'iOS 设备 Release 编译、签名与安装包完整性检查已通过。')
    if proof.get('selected_core'):
        selected = proof['selected_core']
        validation += f' 指定核心回归 {selected["passed"]} 项通过（筛选：{selected["filter"]}）。'
    if proof.get('selected_interaction'):
        selected = proof['selected_interaction']
        validation += f' 指定 App 内/界面回归 {selected["passed"]} 项通过（{selected["simulator"]}；{", ".join(selected["selectors"])}）。'
    for selected in proof.get('additional_interaction', []):
        validation += f' 补充机型回归 {selected["passed"]} 项通过（{selected["simulator"]}；{", ".join(selected["selectors"])}）。'
    if proof.get('auto_selection'):
        plan = proof['auto_selection']
        validation += (f' 自动选测基线：{plan["base_sha"] or "首次开发版"} → {plan["source_sha"]}。'
                       + '；'.join(plan['reasons']) + '。')
    if proof.get('reused_pr'):
        validation += (' 以上相关测试由 PR 检查在同一份代码（文件树一致、选测相同）上完成，开发版没有重复运行：'
                       f'[PR 检查记录]({proof["reused_pr"]["run_url"]})。')
    if proof.get('run_url'):
        validation += f' [GitHub Actions 验证记录]({proof["run_url"]})。'
    parts += ['---', f'## 添加{label} IPA 源',
              f'- GitHub：{github}\n- 镜像（gh-proxy.com）：{mirror}',
              '在支持 IPA 源的安装工具（如 SideStore、AltStore、Zeus）中添加其中一个地址；国内网络建议用镜像，安装包也会经镜像下载。',
              '## 验证记录',
              validation
              + ('手机验收已由 Kerwin 完成。' if channel == 'release' else '手机验收待 Kerwin 执行。'),
              *([f'- 安装包 SHA256：`{ipa_sha256}`（经镜像下载时可用它核对，IPA 源里也带着同一个值）'] if ipa_sha256 else []),
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

