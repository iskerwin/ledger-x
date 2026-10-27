"""Read-only checks for the automatic Dev and PR paths (manual full CI is separate)."""
import ast


def check_runner(source, function):
    node = next((item for item in ast.parse(source).body
                 if isinstance(item, ast.FunctionDef) and item.name == function), None)
    if node is None:
        raise ValueError(f'缺少选测入口 {function}')
    forbidden = {'validate', 'ship.validate', 'release_validation', 'ship.release_validation',
                 'release_validation_at_source', 'ship.release_validation_at_source'}
    calls = {ast.unparse(item.func) for item in ast.walk(node) if isinstance(item, ast.Call)}
    if calls & forbidden:
        raise ValueError(f'{function} 不得调用全量验证：{sorted(calls & forbidden)}')


def check_plan(plan, kind):
    if plan.get('full') or plan.get('scope') == 'full':
        raise ValueError('Dev/PR 计划不得升级为完整全量')
    if kind == 'dev' and 'LedgerUITests' in plan.get('app_targets', []):
        raise ValueError('Dev 不得用整套界面模块兜底')
    expanded = (plan.get('core_all') or plan.get('app_targets') or plan.get('narrow_targets')) \
        if kind == 'dev' else plan.get('swift') == 'all'
    if expanded and not any('扩大' in reason or '模块' in reason or '核心样本' in reason
                            for reason in plan.get('reasons', [])):
        raise ValueError('扩大测试模块必须在计划 reasons 明示')
