#!/usr/bin/env python3
"""Which checks a pull request must run. Classification only: nothing is published."""
import re
from pathlib import Path

IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')


def _norm(path):
    return path.replace('\\', '/').lstrip('./')


def classify(paths):
    """Return swift ('' | 'all' | filter), whether to compile the app tests, and which classes to run.

    Docs and tools changes stay on static checks. LedgerKit source runs the whole package tests.
    A few LedgerKit test files run only those classes. App, project or UI test edits compile the
    test bundles; changed test classes are executed. The full suite is not a pull-request check.
    """
    kit_source = False
    kit_tests = []
    xcode_build = False
    xcode_tests = []
    for path in (_norm(p) for p in paths):
        if path.startswith('LedgerKit/'):
            parts = path.split('/')
            stem = Path(path).stem
            if '/Tests/' in '/' + path and path.endswith('.swift') and 'Fixtures' not in parts and IDENT.fullmatch(stem):
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
    return dict(swift=swift, xcode_build=xcode_build, xcode_tests=tuple(sorted(set(xcode_tests))))
