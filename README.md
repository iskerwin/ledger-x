# Ledger X

原生 SwiftUI 的 iOS Beancount 记账 / 查账 App。账本放在你自己的 GitHub 仓库里，App 通过 GitHub API 直接读写；写入的格式和手写的一致（金额右对齐到第 59 列，按日期插入），账本仍然可以用 Fava、bean-check、编辑器照常处理。

安装包由 GitHub Actions 在 Mac 机器上编译，**不签名**，用 SideStore / AltStore 自己签名安装。

## 安装

1. 打开本仓库的 [Releases](../../releases)，下载最新正式版（`v1.0` 等）里的 `Ledger.ipa`。
2. 在 SideStore 里点「+」导入，签名安装。免费 Apple ID 签名 7 天有效，由 SideStore 自动续签。
3. 第一次打开，填 GitHub 用户名、账本仓库名、分支，以及一个 fine-grained token：
   - Repository access 只选你的账本仓库；
   - Contents 设为 **Read and write**；
   - 可选 Actions **Read-only**，用来显示 bean-check 的结果。

Token 存在本机钥匙串里，只在手机和 GitHub 之间传输。

## 适用的账本结构

不需要改你的仓库。App 读取主文件（默认 `main.bean`）及其 `include` 的所有文件，并自动识别新内容写到哪里：

| 写什么 | 写到哪里 |
| --- | --- |
| 交易 | 最近一年交易所在的文件，年份换成当年，例如 `journals/2026.bean`；跨年时自动新建并在主文件里加 `include` |
| 余额断言、价格、开户 / 关户、商品、文档 | 账本里放同类内容最多的文件（例如 `accounts/balance.bean`、`prices.bean`） |

「设置 → 仓库结构」里可以改：主文件、交易文件（`{year}` 表示年份，也可以写固定文件名）、报销用的应收账户（默认 `Assets:Receivable:Reimbursement`）。

## 功能

| 页面 | 内容 |
| --- | --- |
| 记一笔 | 支出 / 收入 / 转账 / 分录 / 原文；常用交易（固定金额的点「记」直接保存，可撤销）；商户联想并带出上次的分类和付款账户；金额可写算式；外币实付、跨币种转账、信用卡还款、可报销；实时生成 Beancount 文本，点一下可全屏修改；离线也能记，联网后自动提交 |
| 概览 | 月 / 年支出、对比、收入、结余和储蓄率、净资产、12 个月柱状图（点柱子看金额）、分类、商户排行、待报销、负债、账本检查 |
| 流水 | 搜索（商户、说明、账户、`#tag`、`^link`、金额、`>100`、`2026-09`）、详情、编辑原文、删除、再记一笔、记退款、复制 |
| 账户 | 持仓（市值、成本、浮动盈亏、每一批、投资收入）、资产 / 负债、今年收支科目、明细带滚动余额和余额断言、对账 |
| 报销到账 | 勾选要报销的垫付，填到账金额和账户，生成入账交易（多收记 `Income:ReimbExcess`，少收记 `Expenses:Unreimbursed`），并给勾选的交易加上 `#reimbursed ^reimburse-…` |
| 设置 | 连接、仓库结构、默认付款账户、待同步队列、账本检查 |

顶部的眼睛按钮可以把所有金额模糊掉。账户显示为账本里的原名，中文描述放在后面（如 `Food:Drinks · 餐饮`）。

## 构建与发布

| 操作 | 结果 |
| --- | --- |
| 推送到 `main` | 跑测试 → 编译 → 更新预发布版 **dev**（`Ledger.ipa`、测试日志、模拟器里各页面的截图） |
| 推送 `v*` 标签，如 `git tag v1.1 && git push origin v1.1` | 跑测试 → 编译 → 发布正式版 **v1.1** |

版本号以标签为准，构建号是 Actions 的运行序号。测试不通过时不会发布安装包。

## 目录

- `LedgerKit/` — Beancount 解析、记账、格式化（Swift Package，没有 UI，可以单独 `swift test`）。支持全部指令、算式、多行字符串、`pushtag` / `pushmeta`、成本与批次（STRICT / FIFO / LIFO / HIFO / NONE / AVERAGE）、`pad`、自动补平、按精度推断的容差。
- `Ledger/` — App（SwiftUI，iOS 17+）。
- `project.yml` — XcodeGen 工程；有 Mac 的话 `brew install xcodegen && xcodegen` 就能用 Xcode 打开。
- `tools/golden.mjs` — 用 `tools/reference/` 里的原始 JavaScript 实现生成测试账本和标准答案（`node tools/golden.mjs`），Swift 的结果必须与之逐项一致。
