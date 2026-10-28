# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

协作、授权、测试分层、发布与数据安全的约定在 AGENTS.md，必须遵守：

@AGENTS.md

## 项目是什么

Ledger X 是原生 SwiftUI 的 iOS 17+ 记账 App，账本是用户自己的 Beancount 纯文本（本机文件夹、GitHub、GitLab、Gitea/Forgejo、WebDAV）。不建立另一份账务数据库；共享设置写在账本里的 `ledger-x.json`，本机偏好/草稿/队列在本机，凭据在 Keychain。通过 IPA 源自签分发，不走 App Store。

开发手册在 `docs/development/`：02 记账与数据规范（强制数据契约）、03 技术架构与代码导航、04 云端测试与发布、05 测试样本、06 手机验收清单。改代码前先看 03 中对应模块的不变量。

## 命令与流程

测试、模拟器、编译、打包和发布全部在 GitHub macOS runner 执行，本机只编辑、跑 `ship.py check`、推送分支、开 Pull Request 和发起任务；不直接推 main。完整流程与命令见 [04 云端测试与发布](docs/development/04-云端测试与发布.md)。

流程：分支 → PR（「Ledger CI / gate」与开发版同一套选测和执行程序，必须通过）→ 需要上手机确认时发预览包 → 合并 → 开发版（main 与 PR 测过的文件树一致时复用 PR 测试记录，只编译发布）→ 手机验收 → 正式版。

```sh
python3 tools/ship.py check                               # 本机：与云端第一步相同的静态检查和工具测试
python3 tools/ship.py preview                             # 已推送的分支：静态检查 + 编译，约 10 分钟出手机预览包（构建 N.k，不能转正）
python3 tools/ship.py test --core-filter PostingOrderTests
python3 tools/ship.py test --ui-test LedgerUITests/EditInteractionTests/testCalendarUsesFullRowWidthWithoutHint
python3 tools/ship.py dev                                 # 最新 main：复用 PR 记录或自动选测，通过后打包发布
python3 tools/ship.py test                                # 云端全量，只验证
python3 tools/ship.py release --accepted-build N           # 仅 Kerwin 手机验收后授权，原 IPA 转正
python3 tools/ship.py watch --once
python3 tools/ship.py version patch|minor|major|X.Y.Z      # 在分支上本地提交版本，经 PR 合并
```

`test` / `preview` 针对当前已推送的分支；`dev` / `release` 只在与 GitHub 一致的 main 上发起，`dev` 不接受测试参数或 `--full`。筛选回归不算全量。开发版和正式版只能对着 main 上的源码；云端失败时源码可以已在 main，但安装包不发布。正式版须匹配已验收构建号与 SHA256，在该安装包的同一源码上全量通过，沿用原版本号和构建号，不重新编译 IPA。失败日志、截图与 `.xcresult` 保存在 Actions artifacts（日志 7 天，全量证据 30 天），实际范围与链接写入验证记录。

本机可运行 `python3 tools/ship.py check`（即 `check_project.py` 加全部工具测试）和 `git diff --check`。不在本机启动 Xcode、Swift 测试或模拟器。冻结样本与独立预期规则仍见 05。

## 架构要点

- **分层**：`LedgerKit/`（Swift 包，本地依赖）放解析、金额/汇率、文本生成、校验、报表、查询等业务规则；`Ledger/Sync/` 放 Store、存储后端、保存队列、同步、附件恢复；`Ledger/Views/` 放 SwiftUI 界面；`Ledger/LedgerApp.swift` 是入口与主导航。工程由 `project.yml`（XcodeGen）生成。
- **写账唯一路径**：draftText → `formatTxn` → `orderedPostings` → makeOps/applyOps → 提交前 checks。不得在界面里拼接或排序分录。格式规则（金额末位落在第 59 列 `NUM_END`、分录顺序、账户与标签写法、汇率方向按银行原样保留）见 02，实现在 `LedgerKit/Sources/LedgerKit/Format.swift`。
- **编辑往返**：模式转换和已有交易编辑用 `sameTxn` 验证无损往返，失败保留用户输入；多笔相同原文时只改仍匹配原锚点的一笔，歧义不猜（`EditorMode.swift`、`Editing.swift`、`EntryLocator.swift`）。
- **保存链**：`Store.commit` → 预检查 → 持久化队列 → `onQueued`（关卡片）→ 本机 rebuild → saveConfirmation → requestSavedSync。校验失败不调 `onQueued`；`waitForSavedSync` 保护切账本、连接、刷新、清缓存。
- **按账本隔离**：草稿、恢复文件、浏览条件和后台结果都按账本隔离；异步回调须核对账本标识、文件版本和请求令牌后才应用。
- **本地化**：界面文字以中文为键，英文在 `Ledger/en.json`；快捷指令、Siri 短语和权限说明由系统读取，英文在 `Ledger/*.xcstrings`。
- **工具**：`tools/fixtures/` 是 Beancount 独立对照与预期结果生成；`tools/release/` 是发布说明与 IPA 源（`ipa` 分支上的 dev.json / release.json 及镜像）。
