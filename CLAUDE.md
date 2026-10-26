# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

协作、授权、测试分层、发布与数据安全的约定在 AGENTS.md，必须遵守：

@AGENTS.md

## 项目是什么

Ledger X 是原生 SwiftUI 的 iOS 17+ 记账 App，账本是用户自己的 Beancount 纯文本（本机文件夹、GitHub、GitLab、Gitea/Forgejo、WebDAV）。不建立另一份账务数据库；共享设置写在账本里的 `ledger-x.json`，本机偏好/草稿/队列在本机，凭据在 Keychain。通过 IPA 源自签分发，不走 App Store。

开发手册在 `docs/development/`：02 记账与数据规范（强制数据契约）、03 技术架构与代码导航、04 本机测试与发布、05 测试样本、06 手机验收清单。改代码前先看 03 中对应模块的不变量。

## 命令

所有测试、编译和发布都在本机运行，入口是 `tools/ship.py`（细节见 docs/development/04）：

```sh
python3 tools/ship.py test        # 静态检查 → LedgerKit 核心测试 → Beancount 报表对照 → 新建模拟器 → 编译 → 附件与交互测试
python3 tools/ship.py dev         # test 全过后编译 IPA、推送 main、更新开发版与 IPA 源
python3 tools/ship.py release     # 仅 Kerwin 手机验收后执行：把当前开发版原样发布为正式版
python3 tools/ship.py version patch|minor|major|X.Y.Z
python3 tools/ship.py watch       # 另开终端看正在跑（或最近一次）的进度：阶段、用时、测试通过/失败数、当前用例
python3 tools/ship.py watch --once  # 只打印一次当前进度后退出（适合非交互环境）
```

版本流程（细节与授权见 AGENTS.md「发布」）：`version` 开新版本 → 开发并写 CHANGELOG「（开发中）」 → `dev` 发开发版 → Kerwin 手机验收 → `release` 转正式版 → CHANGELOG 标题改为「（YYYY-MM-DD 发布）」并提交推送。

单独的快速检查：

```sh
python3 tools/check_project.py                               # 文档链接、图片与样本哈希、工程配置
xcodegen generate                                            # 改了 project.yml 或增删文件后，单独跑 xcodebuild 前重新生成工程
python3 -m unittest discover -s tools/tests -p 'test_*.py'   # ship.py、发布说明与 IPA 源的回归
LEDGER_DEMO_PATH="$PWD/.demo-data" SAMPLE_OUT="$PWD/samples" swift test --package-path LedgerKit --filter PostingOrderTests
xcodebuild test-without-building -project Ledger.xcodeproj -scheme LedgerInteractionTests \
  -destination 'platform=iOS Simulator,name=Ledger Local Tests' -derivedDataPath build-demo \
  -only-testing:LedgerUITests/EditInteractionTests/<testMethod>   # 先跑过一次 ship.py test
```

- `.demo-data` 是固定提交的 `ledger-demo` 只读克隆（提交号在 `tools/fixtures/manifest.json`），ship.py 自动准备。
- 日志（`*.log`、`interaction-tests.xcresult`）、`build-demo/`、`dist/`、xcodegen 生成的 `Ledger.xcodeproj` 与 `Ledger/Info.plist` 都不入库。
- 改动冻结样本（`LedgerKit/Tests/LedgerKitTests/Fixtures`、`LedgerUITests/Fixtures`）必须同步 `tools/fixtures/manifest.json` 的 SHA256，标准答案按 docs/development/05 用独立计算更新，不能拿待测实现的输出覆盖。

## 架构要点

- **分层**：`LedgerKit/`（Swift 包，本地依赖）放解析、金额/汇率、文本生成、校验、报表、查询等业务规则；`Ledger/Sync/` 放 Store、存储后端、保存队列、同步、附件恢复；`Ledger/Views/` 放 SwiftUI 界面；`Ledger/LedgerApp.swift` 是入口与主导航。工程由 `project.yml`（XcodeGen）生成。
- **写账唯一路径**：draftText → `formatTxn` → `orderedPostings` → makeOps/applyOps → 提交前 checks。不得在界面里拼接或排序分录。格式规则（金额末位落在第 59 列 `NUM_END`、分录顺序、账户与标签写法、汇率方向按银行原样保留）见 02，实现在 `LedgerKit/Sources/LedgerKit/Format.swift`。
- **编辑往返**：模式转换和已有交易编辑用 `sameTxn` 验证无损往返，失败保留用户输入；多笔相同原文时只改仍匹配原锚点的一笔，歧义不猜（`EditorMode.swift`、`Editing.swift`、`EntryLocator.swift`）。
- **保存链**：`Store.commit` → 预检查 → 持久化队列 → `onQueued`（关卡片）→ 本机 rebuild → saveConfirmation → requestSavedSync。校验失败不调 `onQueued`；`waitForSavedSync` 保护切账本、连接、刷新、清缓存。
- **按账本隔离**：草稿、恢复文件、浏览条件和后台结果都按账本隔离；异步回调须核对账本标识、文件版本和请求令牌后才应用。
- **本地化**：界面文字以中文为键，英文在 `Ledger/en.json`；快捷指令、Siri 短语和权限说明由系统读取，英文在 `Ledger/*.xcstrings`。
- **工具**：`tools/fixtures/` 是 Beancount 独立对照与预期结果生成；`tools/release/` 是发布说明与 IPA 源（`ipa` 分支上的 dev.json / release.json 及镜像）。
