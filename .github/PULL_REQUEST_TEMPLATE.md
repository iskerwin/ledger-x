## 用户能看到的变化

写清入口或触发情形。没有界面变化就写「无」。

## 相关测试

- [ ] 说明这次改了哪一层，以及 PR 检查会跑的测试（LedgerKit 类名，或 `LedgerTests` / `LedgerUITests` 的类名）。只改文档或工具时写明不编译 App。
- [ ] 合并前「Ledger CI / gate」为通过。这个检查只读，不发布安装包，也不能代替开发版或正式版。

## 发布

不要在这个 PR 里发开发版或正式版。合并进 main 之后：

1. `python3 tools/ship.py dev` 默认根据上次开发版之后的改动自动选相关测试，或显式 `--full`。测试通过才发布开发版；未知源码影响扩大到全量。
2. Kerwin 在手机上验收这一版的构建号。
3. `python3 tools/ship.py release --accepted-build N` 在同一源码上跑完全量，再把同一个安装包转成正式版。版本号和构建号不变。
