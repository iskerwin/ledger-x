# Ledger X

原生 SwiftUI 的 iOS Beancount 记账 / 查账 App。账本放在你自己的 GitHub 仓库里，App 通过 GitHub API 直接读写；写入的格式和手写的一致（金额右对齐到第 59 列，按日期插入），账本仍然可以用 Fava、bean-check、编辑器照常处理。

安装包由 GitHub Actions 在 Mac 机器上编译，**不签名**，用 SideStore / AltStore 自己签名安装。

## 安装

1. 打开本仓库的 [Releases](../../releases)，下载最新正式版（`v1.1` 等）里的 `Ledger.ipa`。
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
| 记账 | 支出 / 收入 / 转账 / 分录 / 文本；常用交易（固定金额可一键入账，支持撤销）；收付款方联想并带出上次的科目与付款账户；金额支持算式；外币实付、跨币种转账、信用卡还款、可报销；实时生成 Beancount 文本，点按可全屏编辑；离线可记，联网后自动提交 |
| 概览 | 月 / 年支出及环比、收入、结余与储蓄率、净资产、12 个月柱形图（点按查看金额）、支出构成、商户支出排行、应收报销款、负债、账本校验 |
| 明细 | 搜索（收付款方、摘要、科目、`#tag`、`^link`、金额、`>100`、`2026-09`）、详情、编辑源文本、删除、复制为新交易、登记退款、复制 |
| 账户 | 净资产与资产负债率、按类型分组的账户（银行存款、第三方支付、证券账户、信用卡……）、投资持仓（市值、成本、浮动盈亏、批次、投资收益）、本年收支科目、账户明细（滚动余额、余额断言）、余额核对；余额断言可左滑 / 长按编辑或删除，编辑会替换原行而不是新增一行 |
| 报表 | 与 Fava 一致的 **损益表**（期间可选、月度收支图、科目树）、**资产负债表**（任意截止日、净资产走势、未结转损益）、**试算平衡表**；**BQL 查询**：内置常用查询、自动列出账本中的 `query` 指令与 `*.bql` 文件、可编辑运行并保存为「我的查询」、结果可复制或导出 CSV |
| 报销回款 | 勾选待报销垫款，填写回款金额与收款账户，生成入账交易（超额计入 `Income:ReimbExcess`，短收计入 `Expenses:Unreimbursed`），并为所选交易添加 `#reimbursed ^reimburse-…` |
| 设置（右上角齿轮） | 语言（简体中文 / English / 跟随系统）、外观（12 种主题色、浅色 / 深色）、面容 ID / 触控 ID 锁定（可设自动锁定时间）、隐藏金额、记账偏好、GitHub 连接、仓库结构、同步队列、账本校验 |

导航栏的眼睛按钮可模糊所有金额。科目显示为账本中的原名，中文说明附在其后（如 `Food:Drinks · 餐饮`）。

### BQL 支持范围

`SELECT [DISTINCT] … FROM … WHERE … GROUP BY … ORDER BY … LIMIT`、`BALANCES`、`JOURNAL`；比较、正则 `~`、`IN`、`IS NULL`、算术与日期加减；常用列（`date year month payee narration account position units cost_number balance tags links` 等）与函数（`SUM COUNT MIN MAX FIRST LAST YEAR MONTH QUARTER PARENT LEAF ROOT CONVERT VALUE COST UNITS NUMBER CURRENCY ABS NEG GREP TODAY` 等）。暂不支持 `PIVOT BY`。

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
