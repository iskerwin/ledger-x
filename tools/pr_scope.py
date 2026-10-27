#!/usr/bin/env python3
"""Which checks a pull request must run. Classification only: nothing is published."""
import re
from pathlib import Path

IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
FUNC = re.compile(
    r'^[ \t]+(?:(?:public|private|internal|fileprivate|open|final|override|static|class|mutating|nonisolated)\s+)*'
    r'func\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>\n]*>)?\s*\(')
HUNK = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@')
ROOT = Path(__file__).resolve().parents[1]
# Reviewed file dependencies. Unknown core files still run the entire module.
KIT_SOURCE_TESTS = {'LedgerKit/Sources/LedgerKit/Search.swift': ('SearchTests',)}
LOCALIZATION_FILES = frozenset(('Ledger/en.json', 'Ledger/Localizable.xcstrings',
                                'Ledger/AppShortcuts.xcstrings', 'Ledger/InfoPlist.xcstrings'))


def _norm(path):
    return path.replace('\\', '/').lstrip('./')


def _funcs(text):
    lines = text.splitlines()
    starts = []
    for index, line in enumerate(lines, 1):
        match = FUNC.match(line)
        if match:
            starts.append((match.group(1), index))
    funcs = []
    for place, (name, start) in enumerate(starts):
        end = starts[place + 1][1] if place + 1 < len(starts) else len(lines) + 1
        funcs.append(dict(name=name, start=start, end=end, body='\n'.join(lines[start - 1:end - 1])))
    return funcs


def _diff_files(diff):
    files = {}
    path = None
    chunk = []
    for line in diff.splitlines(keepends=True):
        if line.startswith('diff --git '):
            if path:
                files[path] = ''.join(chunk)
            match = re.match(r'diff --git a/(.+?) b/(.+)$', line.strip())
            path = _norm(match.group(2)) if match else None
            chunk = []
        elif path is not None:
            chunk.append(line)
    if path:
        files[path] = ''.join(chunk)
    return files


def _changed_lines(file_diff):
    """Line numbers in the new file that a hunk added or deleted."""
    lines = set()
    new = None
    for line in file_diff.splitlines():
        match = HUNK.match(line)
        if match:
            new = int(match.group(1))
            continue
        if new is None or line.startswith('\\'):
            continue
        if line.startswith('+'):
            lines.add(new)
            new += 1
        elif line.startswith('-'):
            lines.add(new)
        elif line.startswith(' '):
            new += 1
    return lines


def _tests_affected_by(name, bodies):
    """The test methods that are `name` or that call it, directly or through a helper."""
    found = set()
    stack = [name]
    seen = set()
    while stack:
        current = stack.pop()
        if current in seen:
            continue
        seen.add(current)
        if current.startswith('test'):
            found.add(current)
            continue
        pattern = re.compile(r'\b' + re.escape(current) + r'\s*\(')
        for caller, body in bodies.items():
            if caller != current and pattern.search(body):
                stack.append(caller)
    return found


def _methods(text, file_diff):
    """Test methods to run for one changed file, or None to run the whole class.

    A change outside any method (imports, the class line) keeps the whole class: those lines can
    affect every case. A helper runs the tests that call it. When every such test is a calendar
    case, the rest of the calendar cases in the file run too, and the other flows in the class do not.
    """
    funcs = _funcs(text)
    if not funcs:
        return None
    changed = []
    for line in _changed_lines(file_diff):
        owner = next((fn['name'] for fn in funcs if fn['start'] <= line < fn['end']), None)
        if owner is None:
            return None
        changed.append(owner)
    if not changed:
        return None
    bodies = {fn['name']: fn['body'] for fn in funcs}
    affected = set()
    for name in changed:
        affected |= _tests_affected_by(name, bodies)
    if not affected:
        return None
    tests = [fn['name'] for fn in funcs if fn['name'].startswith('test')]
    if all('calendar' in name.lower() for name in affected):
        chosen = [name for name in tests if 'calendar' in name.lower()]
    else:
        chosen = [name for name in tests if name in affected]
    return chosen or None


def _source(path, sources):
    if sources is not None and path in sources:
        return sources[path]
    file = ROOT / path
    if file.is_file():
        return file.read_text(encoding='utf-8')
    return None


def _narrow(paths, selectors, diff, sources):
    files = _diff_files(diff)
    narrowed = []
    for selector in selectors:
        target, stem = selector.split('/')
        suffix = f'{target}/{stem}.swift'
        path = next((_norm(item) for item in paths if _norm(item).endswith(suffix)), None)
        methods = None
        if path and path in files:
            text = _source(path, sources)
            if text is not None:
                methods = _methods(text, files[path])
        if methods:
            narrowed.extend(f'{selector}/{name}' for name in methods)
        else:
            narrowed.append(selector)
    return tuple(sorted(set(narrowed)))


def classify(paths, diff=None, sources=None):
    """Return swift ('' | 'all' | filter), whether to compile the app tests, and which tests to run.

    Docs and tools changes stay on static checks. Unmapped LedgerKit source runs the package tests.
    A few LedgerKit test files run only those classes. App, project or UI test edits compile the
    test bundles. With the pull-request diff, a changed test file runs the cases that diff
    touches, not the whole class. Calendar-only edits also run the other calendar cases in that
    file. The full suite is not a pull-request check.
    """
    kit_source = False
    kit_tests = []
    xcode_build = False
    xcode_tests = []
    for path in (_norm(p) for p in paths):
        if path.startswith('LedgerKit/'):
            parts = path.split('/')
            stem = Path(path).stem
            if path in KIT_SOURCE_TESTS:
                kit_tests.extend(KIT_SOURCE_TESTS[path])
            elif '/Tests/' in '/' + path and path.endswith('.swift') and 'Fixtures' not in parts and IDENT.fullmatch(stem):
                kit_tests.append(stem)
            else:
                kit_source = True
        if path == 'project.yml' or path.startswith(('Ledger/', 'LedgerTests/', 'LedgerUITests/')):
            xcode_build = True
        for target in ('LedgerTests', 'LedgerUITests'):
            prefix = target + '/'
            if path.startswith(prefix) and path.endswith('.swift') and '/Fixtures/' not in path:
                stem = Path(path).stem
                if IDENT.fullmatch(stem):
                    xcode_tests.append(f'{target}/{stem}')
                else:
                    xcode_build = True
    if xcode_tests:
        xcode_build = True
    if kit_source:
        swift = 'all'
    elif kit_tests:
        swift = '|'.join(sorted(set(kit_tests)))
    else:
        swift = ''
    if diff is not None and xcode_tests:
        xcode_tests = _narrow(paths, xcode_tests, diff, sources)
    else:
        xcode_tests = tuple(sorted(set(xcode_tests)))
    return dict(swift=swift, xcode_build=xcode_build, xcode_tests=xcode_tests)
