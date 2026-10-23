#!/usr/bin/env python3
"""Static project/documentation checks; does not build or test the App."""
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.parse import unquote

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
require(re.search(r'MARKETING_VERSION: "\d+\.\d+\.\d+"', project), 'Project must declare a semantic base version')
require('INFOPLIST_KEY_CFBundleDisplayName: Ledger X' in project, 'App display name must be Ledger X')
require('LEDGER_DEMO_MIRROR: ""' in project, 'Default App mirror must be explicitly configured')
ship = (ROOT/'tools/ship.py').read_text()
require(not (ROOT/'.github/workflows').exists(), 'Validation and publication run locally with tools/ship.py, not GitHub Actions')
require(all(step in ship for step in ("'swift', 'test'", 'tools/fixtures/check_reports.py', 'build-for-testing', 'test-without-building')),
        'Local validation must keep full core, reports and interaction coverage')
require("tools/fixtures/manifest.json" in ship, 'Tests and packages must use the fixed demo snapshot')
require('release delete' not in ship and '--force' not in ship.replace("'--force', tree", '') and 'push -f' not in ship,
        'Publication must not delete releases or force-push')
require(ship.index('validate()') < ship.index("'git', 'push'"), 'main is pushed only after local validation passed')

# every Chinese text shown through LS has its English; every English entry is still shown somewhere
english = json.loads((ROOT/'Ledger/en.json').read_text())
sources = ''.join(p.read_text() for d in ('Ledger', 'LedgerKit/Sources') for p in (ROOT/d).rglob('*.swift'))
shown = {m.replace('\\"', '"').replace('\\n', '\n') for m in re.findall(r'LS\(\s*"((?:[^"\\]|\\.)*)"', sources)}
for key in sorted(shown):
    require(key in english or not re.search(r'[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]', key), f'Ledger/en.json: no English for {key!r}')
for key in english:
    require(key in shown or '"' + key.replace('"', '\\"').replace('\n', '\\n') + '"' in sources, f'Ledger/en.json: {key!r} is no longer used')

if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'Project boundaries, documentation links, {len(manifest["fixtureSHA256"])} frozen fixtures, {len(english)} English texts and local publication rules match.')
