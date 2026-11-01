#!/usr/bin/env python3
"""Static project/documentation checks; does not build or test the App."""
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.parse import unquote
import dev_scope
import pr_scope
import scope_guard

ROOT = Path(__file__).resolve().parents[1]
errors = []


def require(condition, message):
    if not condition:
        errors.append(message)


for p in [ROOT/'README.md', ROOT/'AGENTS.md', ROOT/'CLAUDE.md', *list((ROOT/'docs').rglob('*.md'))]:
    contents = p.read_text()
    links = re.findall(r'\]\(([^)]+)\)', contents) + re.findall(r'<img[^>]+src=[\"\']([^\"\']+)', contents)
    for link in links:
        if '://' in link or link.startswith(('#','mailto:')):
            continue
        target = unquote(link.split('#', 1)[0])
        require(not target or (p.parent/target).exists(), f'{p.relative_to(ROOT)}: missing link {link}')

asset_path = ROOT/'docs/promo/assets.json'
if asset_path.exists():
    import struct
    assets = json.loads(asset_path.read_text())['images']
    for name, expected in assets.items():
        p = ROOT/name
        if not p.is_file():
            errors.append(f'Missing product image: {name}')
            continue
        data = p.read_bytes()
        require(data[:8] == b'\x89PNG\r\n\x1a\n', f'Invalid PNG: {name}')
        require(hashlib.sha256(data).hexdigest() == expected['sha256'], f'Product image checksum changed: {name}')
        require(len(data) >= 24 and struct.unpack('>II',data[16:24]) == (expected['width'],expected['height']), f'PNG dimensions differ: {name}')
    for folder in ('docs/promo/screenshots','docs/promo'):
        for p in (ROOT/folder).glob('*.png'):
            require(str(p.relative_to(ROOT)) in assets, f'Unrecorded product image: {p.name}')

manifest = json.loads((ROOT/'tools/fixtures/manifest.json').read_text())
for name, expected in manifest['fixtureSHA256'].items():
    p = ROOT/name
    require(p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest() == expected,
            f'Test fixture changed without updating its independent expected results: {name}')

paths = [p for p in ROOT.rglob('*') if p.is_file() and '.git' not in p.parts
         and not any(part in ('.build','build','build-demo','dist','__pycache__','.demo-data','Ledger.xcodeproj') or part.endswith('.xcresult') for part in p.parts)]
for p in paths:
    require(p.suffix not in ('.js','.mjs','.html','.webmanifest'), f'Unexpected non-native source file: {p.relative_to(ROOT)}')
    require(p.name not in ('package.json','sw.js','service-worker.js'), f'Unexpected runtime file: {p.name}')

project = (ROOT/'project.yml').read_text()
schemes = project.split('\nschemes:', 1)[-1]
for scheme, expected in (('LedgerHostedTests', {'LedgerTests'}), ('LedgerUITests', {'LedgerUITests'}),
                         ('LedgerInteractionTests', {'LedgerTests', 'LedgerUITests'})):
    block = re.search(r'^  ' + scheme + r':\n(.*?)(?=^  \w+:|\Z)', schemes, re.M | re.S)
    contents = block.group(1) if block else ''
    require(set(re.findall(r'^        (Ledger(?:UI)?Tests): \[test\]$', contents, re.M)) == expected
            and set(re.findall(r'^        - (Ledger(?:UI)?Tests)$', contents, re.M)) == expected,
            f'{scheme} must build and run exactly its selected test bundles')
require(re.search(r'MARKETING_VERSION: "\d+\.\d+\.\d+"', project), 'Project must declare a semantic base version')
require('INFOPLIST_KEY_CFBundleDisplayName: Ledger X' in project, 'App display name must be Ledger X')
require('LEDGER_DEMO_MIRROR: ""' in project, 'Default App mirror must be explicitly configured')
ship = (ROOT/'tools/ship.py').read_text()
ci = (ROOT/'.github/workflows/ci.yml').read_text()
dev = (ROOT/'.github/workflows/dev.yml').read_text()
release = (ROOT/'.github/workflows/release.yml').read_text()
preview = (ROOT/'.github/workflows/preview.yml').read_text()
runner = (ROOT/'.github/actions/ledger-run/action.yml').read_text()
workflow = '\n'.join((ci, dev, release, preview, runner, (ROOT/'tools/select_xcode.sh').read_text()))
for name, publication in (('Dev', dev), ('Release', release)):
    require('workflow_dispatch:' in publication and 'pull_request:' not in publication
            and 'runs-on: macos-26' in publication and 'group: ledger-publication' in publication
            and 'cancel-in-progress: false' in publication and "if: github.ref == 'refs/heads/main'" in publication
            and 'contents: write' in publication and 'actions: write' in publication,
            f'{name} must be manual, main-only and share a non-cancelling publication lock')
# A preview builds any branch, never promotes, and queues apart from Dev/Release.
require('workflow_dispatch:' in preview and 'pull_request:' not in preview and 'group: ledger-preview' in preview
        and 'group: ledger-publication' not in preview and 'LEDGER_COMMAND: preview' in preview
        and 'actions: write' not in preview and 'uses: ./.github/actions/ledger-run' in preview,
        'Preview must be manual, separate from the publication lock and unable to promote')
require("tag_exists(repo, 'preview')" not in ship and "'release', 'create', 'preview'" in ship and "'--latest'" not in ship.split('def ship_preview', 1)[1].split('\ndef ', 1)[0],
        'Preview publishes only the preview prerelease')
require("'git', 'push'" not in (ROOT/'tools/cloud.py').read_text(),
        'The local client must not push: main changes only through pull requests')
gate = ci.split('\n  gate:', 1)[-1].split('\n  test:', 1)[0]
require('pull_request:' in ci and 'runs-on: macos-26' in gate
        and "cancel-in-progress: ${{ github.event_name == 'pull_request' }}" in ci
        and 'contents: read' in ci and 'contents: write' not in ci and 'actions: write' not in gate
        and "if: github.event_name == 'pull_request'" in gate
        and 'tools/pr_gate.py' in gate and 'persist-credentials: false' in gate,
        'Pull requests need one read-only gate and must not publish')
require("if: inputs.check_only != 'true' && always()" in runner and 'actions/upload-artifact@v7' in runner,
        'Cloud runs must preserve failed-run evidence outside the load-only PR check')
require('actions/checkout@v7' in workflow and 'actions/setup-python@v7' in workflow and 'actions/cache@v6' in runner,
        'Cloud workflow must use current major versions of checkout, setup-python and cache')
require('Xcode_26.6.app' in workflow and 'bash tools/select_xcode.sh' in runner and 'bash tools/select_xcode.sh' in gate
        and 'inputs.cache_epoch' in runner and 'contents: write' not in ci
        and all('uses: ./.github/actions/ledger-run' in item for item in (ci, dev, release, preview)),
        'Cloud workflow must pin Xcode 26.6 and split read and write permissions')
require(not re.search(r'\b(?:vars|secrets)\s*[.\[]', runner)
        and all("cache_epoch: ${{ vars.LEDGER_CACHE_EPOCH || '1' }}" in item for item in (ci, dev, release, preview))
        and "check_only: 'true'" in gate,
        'Shared action must receive workflow configuration through inputs and load in the PR gate')
require('retention-days: 7' in runner and 'retention-days: 30' in runner,
        'Cloud artifacts must use the short retention windows')
require('build/' not in runner.split('actions/cache@v6', 1)[-1].split('key:', 1)[0],
        'Release builds stay uncached; only test compile products may be restored')
require(all(step in ship for step in ("'swift', 'test'", 'tools/fixtures/check_reports.py', 'build-for-testing', 'test-without-building')),
        'Cloud validation must keep full core, reports and interaction coverage')
require("tools/fixtures/manifest.json" in ship and 'https://github.com/iskerwin/ledger-demo' in ship,
        'Tests and packages must use the fixed public demo snapshot')
require(not re.search(r'github\.com/iskerwin/ledger(?:\.git)?(?:["\'/\s]|$)', ship + workflow),
        'Tooling must not reference the private ledger repository')
require('release delete' not in ship and '--force' not in ship.replace("'--force', tree", '').replace("'--force', source", '') and 'push -f' not in ship,
        'Publication must not delete releases or force-push')
require('源码已在 main，未发布安装包' in ship, 'A cloud failure must say main is already pushed and no IPA was published')
require('warn-long-expression-type-checking=200' in project and 'warn-long-expression-type-checking=200' in ship,
        'Debug and test builds must warn on slow type-checking')
require(ship.index('proof = validate_targeted()') < ship.index("remote_run('main_push'"),
        'Publication worker validates and builds before publishing')
require(ship.index('proof = dev_scope.validate(plan)') < ship.index('ipa = build_ipa('),
        'Automatic development selection must validate before building an IPA')

# Automatic CI/Dev must never use the full validator as a fallback. Explicit manual
# CI remains allowed to run full, as does Release at the accepted package's source.
try:
    for source, function in (((ROOT/'tools/dev_scope.py').read_text(), 'validate'),
                             ((ROOT/'tools/dev_scope.py').read_text(), 'select'),
                             ((ROOT/'tools/pr_gate.py').read_text(), 'main'),
                             (ship, 'ship_dev'), (ship, 'validate_targeted')):
        scope_guard.check_runner(source, function)
    for path in ('Ledger/Views/SyncAppearance.swift', 'LedgerKit/Sources/LedgerKit/Search.swift',
                 'Ledger/en.json', 'LedgerTests/AppearanceTests.swift', 'project.yml',
                 'LedgerKit/Sources/LedgerKit/Unknown.swift', 'Ledger/Sync/Unknown.swift',
                 'tools/fixtures/unknown.bean', 'unknown-file'):
        scope_guard.check_plan(dev_scope.classify([path]), 'dev')
        scope_guard.check_plan(pr_scope.classify([path]), 'pr')
except ValueError as error:
    require(False, str(error))

# every Chinese text shown through LS has its English; every English entry is still shown somewhere
english = json.loads((ROOT/'Ledger/en.json').read_text())
sources = ''.join(p.read_text() for d in ('Ledger', 'LedgerKit/Sources') for p in (ROOT/d).rglob('*.swift'))
shown = {m.replace('\\"', '"').replace('\\n', '\n') for m in re.findall(r'LS\(\s*"((?:[^"\\]|\\.)*)"', sources)}
for key in sorted(shown):
    require(key in english or not re.search(r'[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]', key), f'Ledger/en.json: no English for {key!r}')
for key in english:
    require(key in shown or '"' + key.replace('"', '\\"').replace('\n', '\\n') + '"' in sources, f'Ledger/en.json: {key!r} is no longer used')

# what iOS reads from the bundle itself, not through LS (shortcut names, their parameters and Siri phrases, the
# permission prompts): each one has its English in a string catalog, or an English iPhone shows it in Chinese
def catalog(name):
    path = ROOT/'Ledger'/name
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    return {k: v.get('localizations', {}).get('en', {}).get('stringUnit', {}).get('value') for k, v in data['strings'].items()}

def literal(m):
    # a Swift literal as its catalog key: \(\.$amount) is ${amount}, \(.applicationName) is ${applicationName}
    m = re.sub(r'\\\(\\?\.\$?(\w+)\)', r'${\1}', m)
    return m.replace('\\"', '"')

system_read = {
    'Localizable.xcstrings': {literal(m) for pattern in (r'LocalizedStringResource = "((?:[^"\\]|\\.)*)"', r'IntentDescription\("((?:[^"\\]|\\.)*)"',
                                                         r'@Parameter\(title: "((?:[^"\\]|\\.)*)"', r'shortTitle: "((?:[^"\\]|\\.)*)"',
                                                         r'Summary\("((?:[^"\\]|\\.)*)"')
                              for m in re.findall(pattern, sources)},
    'AppShortcuts.xcstrings': {literal(m) for phrases in re.findall(r'phrases: \[([^\]]*)\]', sources)
                               for m in re.findall(r'"((?:[^"\\]|\\.)*)"', phrases)},
    'InfoPlist.xcstrings': set(re.findall(r'^\s+(NS\w+UsageDescription):', project, re.M)),
}
# the permission prompts in Chinese are the ones in project.yml (the catalog's are what the phone shows)
plist_zh = json.loads((ROOT/'Ledger/InfoPlist.xcstrings').read_text())['strings'] if (ROOT/'Ledger/InfoPlist.xcstrings').exists() else {}
for key, value in re.findall(r'^\s+(NS\w+UsageDescription): (.+)$', project, re.M):
    zh = plist_zh.get(key, {}).get('localizations', {}).get('zh-Hans', {}).get('stringUnit', {}).get('value')
    require(zh == value.strip(), f'Ledger/InfoPlist.xcstrings: {key} in Chinese differs from project.yml')
for name, keys in system_read.items():
    english_of = catalog(name)
    for key in sorted(keys):
        require(english_of.get(key), f'Ledger/{name}: no English for {key!r}')
    for key in english_of:
        require(key in keys, f'Ledger/{name}: {key!r} is no longer used')

# a sheet hung on RootView sits outside the theme colour and language set inside it: each sets both again,
# or its buttons fall back to the fixed AccentColor whatever the theme
def closing(text, start, opening, close):
    depth = 0
    for i in range(start, len(text)):
        depth += text[i] == opening
        depth -= text[i] == close
        if depth == 0:
            return i
    return len(text)

app = (ROOT/'Ledger/LedgerApp.swift').read_text()
root = app[app.index('struct RootView'):]
root = root[:re.search(r'\n(?:private )?struct ', root[1:]).start() + 1]
for m in re.finditer(r'\.(?:sheet|fullScreenCover)\(', root):
    after = closing(root, m.end() - 1, '(', ')') + 1
    body_start = root.index('{', after)
    body = root[body_start:closing(root, body_start, '{', '}') + 1]
    line = app[:app.index(root)].count('\n') + root[:m.start()].count('\n') + 1
    require('.tint(Color.jadeInk)' in body and '.environment(\\.locale, AppLanguage.current.locale)' in body,
            f'Ledger/LedgerApp.swift:{line}: a sheet on RootView must set .tint(Color.jadeInk) and the app language itself')

# every institution the card face knows has its built-in icon, and every icon an institution: a single-colour
# vector drawn in the card's ink
face = (ROOT/'Ledger/Views/AccountFace.swift').read_text()
looks = set(re.findall(r'^\s*"(\w+)": look\(', face, re.M))
marks_dir = ROOT/'Ledger/Assets.xcassets/FaceMarks'
marks = {p.stem for p in marks_dir.glob('*.imageset')}
require(looks and looks == marks, f'Ledger/Assets.xcassets/FaceMarks: icons {sorted(marks - looks)} have no institution, institutions {sorted(looks - marks)} have no icon')
for name in sorted(marks & looks):
    spec = json.loads((marks_dir/f'{name}.imageset/Contents.json').read_text())
    files = [i.get('filename') for i in spec.get('images', [])]
    require(files == [f'{name}.svg'] and (marks_dir/f'{name}.imageset/{name}.svg').exists()
            and spec.get('properties', {}).get('template-rendering-intent') == 'template'
            and spec.get('properties', {}).get('preserves-vector-representation') is True,
            f'Ledger/Assets.xcassets/FaceMarks/{name}.imageset: one {name}.svg, template rendering, vector kept')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'Project boundaries, documentation links, {len(manifest["fixtureSHA256"])} frozen fixtures, {len(english)} English texts and cloud publication rules match.')
