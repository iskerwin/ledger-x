<p align="center">
  <img src="docs/promo/hero.png" alt="Ledger X" width="100%">
</p>

<h1 align="center">Ledger X</h1>

<p align="center">
  原生 SwiftUI 的 iOS <a href="https://beancount.github.io">Beancount</a> 记账 / 查账 App<br>
  账本放在你自己的 GitHub 仓库，手机上记账、对账、看报表、跑 BQL 查询
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/iskerwin/ledger-x?label=%E4%B8%8B%E8%BD%BD&color=2B806A"></a>
  <img src="https://img.shields.io/badge/iOS-17%2B-black">
  <img src="https://img.shields.io/badge/SwiftUI-native-orange">
  <img src="https://img.shields.io/badge/%E8%AF%AD%E8%A8%80-%E4%B8%AD%E6%96%87%20%7C%20English-blue">
</p>

---

## 为什么做它

Beancount 很好用，但它活在电脑上：记一笔要打开编辑器，看报表要启动 Fava。Ledger X 把这两件事搬到手机上，同时 **不改变你的账本**：

- **账本仍是纯文本。** App 通过 GitHub API 直接读写仓库里的 `.bean` 文件，写入格式与手写一致（金额右对齐、按日期插入到正确位置）。电脑上 `git pull` 后，Fava、bean-check、编辑器照常使用。
- **数据只在手机和 GitHub 之间。** 没有服务器、没有账号体系；Token 存在 iOS 钥匙串里。
- **原生、离线可用。** 解析器用 Swift 完整重写，几千笔交易秒开；没网时记的账先排队，联网后自动提交。

## 功能特色

### 记账：几秒钟记完一笔

<p>
  <img src="docs/screenshots/add.png" width="24%">
  <img src="docs/screenshots/add-filled.png" width="24%">
  <img src="docs/screenshots/multi.png" width="24%">
  <img src="docs/screenshots/edit-text.png" width="24%">
</p>

- 支出 / 收入 / 转账 / 多分录 / 直接写 Beancount 文本，五种方式切换
- **常用交易**：自动从近 120 天找出重复出现的交易，固定金额的一键入账，可撤销
- 输入收付款方即联想，自动带出上次用的科目和付款账户
- 金额支持算式（`23.5+12×2`）、外币实付、跨币种转账、信用卡还款、可报销垫款
- 底部实时生成 Beancount 文本，点按可全屏手改，保存前即时校验（平衡、账户是否开立、批次是否足够）

### 概览：一眼看清这个月

<p>
  <img src="docs/screenshots/overview.png" width="24%">
  <img src="docs/screenshots/journal.png" width="24%">
  <img src="docs/screenshots/detail.png" width="24%">
  <img src="docs/screenshots/reimb.png" width="24%">
</p>

- 月 / 年支出与环比、收入、结余、储蓄率、净资产
- 12 个月柱形图，点按某个月，下方图表跟着切换到那个月
- 支出构成、商户排行、负债用环形图展示，点按扇区展开明细（分类 → 子科目、商户 → 交易、负债 → 账户）
- 账本校验与 bean-check 结果
- 明细支持组合搜索：收付款方、摘要、科目、`#tag`、`^link`、金额、`>100`、`2026-09`
- 交易详情可编辑源文本、删除、复制为新交易、登记退款
- **报销**：勾选垫付的交易，填写回款金额，自动生成入账交易并打上 `#reimbursed ^link`

### 账户与余额核对

<p>
  <img src="docs/screenshots/accounts.png" width="24%">
  <img src="docs/screenshots/register.png" width="24%">
  <img src="docs/screenshots/check.png" width="24%">
  <img src="docs/screenshots/holdings.png" width="24%">
</p>

- 净资产卡片 + 资产负债率；账户按类型分组（银行存款、第三方支付、证券、信用卡……），带图标与小计
- 账户明细带滚动余额，余额断言一目了然（相符 / 不符）
- **管理账户**：新建、修改开户信息（显示名称、币种、批次方法）、关闭 / 重新开启，以及跨文件重命名、合并科目
- **余额核对**：输入银行 App 里的余额，自动算差额，生成 `balance` 断言；左滑或长按可编辑、删除，编辑会替换原行而不是新增
- 投资持仓：市值、成本、浮动盈亏、每一批次（STRICT / FIFO / LIFO / HIFO / AVERAGE）、投资收益；一次性手动更新所有证券与外币价格，过期价格会标出

### 报表与 BQL 查询：口袋里的 Fava

<p>
  <img src="docs/screenshots/income.png" width="24%">
  <img src="docs/screenshots/balance.png" width="24%">
  <img src="docs/screenshots/trial.png" width="24%">
  <img src="docs/screenshots/query.png" width="24%">
</p>

- **损益表**：本月 / 上月 / 本年 / 上年 / 近 12 个月 / 自定义区间，月度收支图，可展开的科目树
- **资产负债表**：任意截止日，净资产走势，未结转损益（与 Fava 一致）
- **试算平衡表**：全部科目余额与借贷平衡校验
- **BQL 查询**：`SELECT … WHERE … GROUP BY … ORDER BY … LIMIT`、`BALANCES`、`JOURNAL`，常用列与函数（`SUM` `CONVERT` `PARENT` `ROOT` `YEAR` `MONTH` …）
  - 内置常用查询；自动列出账本里的 `query` 指令和 `*.bql` 文件
  - 可编辑、运行、保存为「我的查询」，结果可复制或导出 CSV，附语法参考

### 导入、预算、提醒

- **导入账单**：支付宝 CSV、微信 xlsx、银行 CSV / Excel；按收付款方自动匹配上次的科目，按支付方式匹配付款账户（会记住你的选择），按订单号和金额标出已记过的交易，确认后一次入账
- **预算**：Fava 同款 `custom "budget"`，按日 / 周 / 月 / 季 / 年设定额度，概览页和报表页显示进度、时间线与超支
- **订阅管理**：周 / 月 / 季 / 半年 / 年或自定义周期，写成 `custom "subscription"`；赠送或延长时设置下次扣费日，之后按原周期继续；到期提醒、一键入账，还能从历史账单里找出周期性扣费
- **信用卡账单**：在开户信息里设置账单日、还款日（`statement_day` / `due_day` 元数据），账户页显示本期账单、已还、剩余应还、未出账消费和可用额度，一键记录还款；概览列出 15 天内到期的账单，到期前按应还金额提醒
- **现金流预测**：根据工资等周期性收入、房租等固定支出、订阅、信用卡账单和日常消费均值，推算未来 30～90 天可用资金走势，余额可能不足时提前提醒
- **快捷指令与 Apple Pay**：提供「快速记一笔」「记一笔（在 App 中确认）」「本月支出」「待付款项」等快捷指令操作；配合钱包「交易」自动化，Apple Pay 付款后自动按商户分类入账，不确定时发通知请你确认（设置 → 快捷指令与 Apple Pay 有步骤说明）
- **提交前检查**：每次写入前先在本机按修改后的账本算一遍，新造成的余额断言失败、借贷不平、未开户科目会被拦下；资产账户余额变负、信用卡超出额度（开户元数据 `credit_limit`）也会提醒。可以返回修改、仍然提交，或先暂存本机
- **本地提醒**：信用卡还款日、订阅扣费、固定交易本月未入账、长期未做余额核对、预算超支
- **票据附件**：拍照或选文件，上传到账本仓库的 `documents/`，写入 `document` 指令并与交易关联，在详情页预览
- **批量编辑**：明细页多选交易，统一改科目、加标签或链接
- **价格自动获取**：从 Yahoo Finance 获取证券与汇率，可设为每天自动写入
- **iPad**：侧边栏分栏布局，支持横屏

### 好看，也安全

<p>
  <img src="docs/screenshots/theme-orange.png" width="24%">
  <img src="docs/screenshots/dark.png" width="24%">
  <img src="docs/screenshots/en.png" width="24%">
  <img src="docs/screenshots/settings.png" width="24%">
</p>

- iOS 26 Liquid Glass 风格；12 种 Apple 系统主题色，浅色 / 深色 / 跟随系统
- **简体中文 / English** 双语界面，可随时切换
- **面容 ID / 触控 ID 锁定**，可设自动锁定时间；多任务界面自动遮挡
- 一键模糊所有金额，适合在人前打开

## 快速体验：用演示账本试一试

不用准备自己的账本，5 分钟就能把所有功能过一遍。[**ledger-demo**](https://github.com/iskerwin/ledger-demo) 是一份完全虚构的 Beancount 账本：约 2000 笔交易、每月余额断言、信用卡还款、美股定投、报销垫款、旅行标签和预置的 BQL 查询，App 的每个页面都有数据可看。

1. **安装 App**：打开 [Releases](../../releases/latest) 下载最新的 `Ledger.ipa`，用 [SideStore](https://sidestore.io) 或 AltStore 导入并签名安装（免费 Apple ID 签名 7 天有效，SideStore 会自动续签）。
2. **Fork 演示账本**：打开 [iskerwin/ledger-demo](https://github.com/iskerwin/ledger-demo)，点右上角 **Fork**。
3. **创建 Token**：GitHub → Settings → Developer settings → **Fine-grained tokens** → Generate new token

   | 设置 | 值 |
   | --- | --- |
   | Repository access | Only select repositories → 你 fork 的 `ledger-demo` |
   | Contents | **Read and write** |
   | Actions（可选） | Read-only，用来显示 bean-check 结果 |

4. **连接**：打开 App，填写你的 GitHub 用户名、仓库 `ledger-demo`、分支 `main` 和 Token，点「连接」。

### 推荐试试这些

| 页面 | 操作 |
| --- | --- |
| 记账 | 常用交易里点「入账」一键记一笔；手动记一笔支出，看底部实时生成的 Beancount 文本 |
| 概览 | 切换月 / 年、点柱形；点「待报销垫款」把最近几笔打车登记为报销回款 |
| 明细 | 搜索 `#trip-tokyo`、`^refund-618`、`星巴克`、`>1000`、`2025-10` |
| 账户 | 打开「Bank:CMB」做一次余额核对；左滑余额断言试试编辑 / 删除；查看「投资持仓」的批次与浮动盈亏 |
| 报表 | 损益表切换本年 / 上年；资产负债表看净资产走势；运行「账本中的查询」，改写一条保存为「我的查询」 |
| 设置 | 换主题色、切换 English、开启面容 ID 锁定 |

在 App 里记的每一笔都会成为你 fork 仓库里的一次 Git 提交，可以在 GitHub 上直接看到改动。想恢复初始数据，在 GitHub 上对 fork 执行 Sync fork（丢弃改动）即可。

## 使用自己的账本

账本可以放在这些地方（设置 → 账本 → 添加账本，可同时保存多个并随时切换）：

| 存储位置 | 说明 |
| --- | --- |
| GitHub | fine-grained token，Contents 读写；每次保存是一次提交，可显示 bean-check 结果 |
| GitLab | gitlab.com 或自建，Personal / Project access token（api 权限） |
| Gitea / Forgejo | 自建或 Codeberg，应用令牌（repository 读写） |
| 文件夹 | 「文件」App 里的任意文件夹：我的 iPhone、iCloud Drive、坚果云、OneDrive，或 Working Copy 管理的本地 Git 仓库 |
| WebDAV | 坚果云、Nextcloud、群晖等，填账本文件夹地址、账号和应用密码 |

以下以 GitHub 为例。

### 1. Token 权限

与上面相同：Repository access 只选你的账本仓库，Contents 设为 **Read and write**，Actions 可选 Read-only。Token 存在 iOS 钥匙串里，只在手机和 GitHub 之间传输。

### 2. 连接账本

填写 GitHub 用户名、仓库名、分支和 Token，点「连接」。App 会读取主文件（默认 `main.bean`）及其 `include` 的所有文件。

### 3. 不需要改你的仓库结构

App 会自动识别新内容写到哪里：

| 写入的内容 | 位置 |
| --- | --- |
| 交易 | 最近一年交易所在的文件，如 `journals/2026.bean`；跨年时自动新建并在主文件中加 `include` |
| 余额断言、价格、开户 / 关户等 | 账本里放同类指令最多的文件，如 `accounts/balance.bean`、`prices.bean` |

如有不同，可在「设置 → 仓库结构」里指定主文件、交易文件（`{year}` 代表年份）和报销用的应收科目。

### 4. 日常使用小贴士

- **记账**：常用交易点「入账」一步完成；其他交易填金额 → 选科目 → 保存。
- **对账**：账户页 → 某个账户 → 余额核对，填银行 App 里的余额；断言日期默认是明天（Beancount 在当日开始时检查）。
- **查账**：明细页搜索 `^reimburse`、`#travel`、`>500`、`2026-09` 等，可组合。
- **查询**：报表页 → 新建查询，或把常用 BQL 写进仓库的 `queries/*.bql`（`-- 标题` 作为查询名），App 会自动列出。
- **离线**：没网也能记，右上角云朵图标显示待同步数量，联网后自动提交。
- **电脑端**：每次保存都是一次 Git 提交，提交信息写明改了什么；`git pull` 即可同步。

## 开发与构建

| 操作 | 结果 |
| --- | --- |
| 推送到 `main` | 跑测试 → 编译 → 更新预发布版 **dev**（`Ledger.ipa`、测试日志、模拟器截图） |
| 推送 `v*` 标签，如 `git tag v1.2 && git push origin v1.2` | 跑测试 → 编译 → 发布正式版 |

- `LedgerKit/` — Beancount 解析、记账、格式化、BQL 引擎与报表（Swift Package，无 UI，可单独 `swift test`）。支持全部指令、算式、多行字符串、`pushtag` / `pushmeta`、成本与批次、`pad`、自动补平、按精度推断的容差。
- `Ledger/` — App（SwiftUI，iOS 17+）。界面文字以中文为键，英文翻译在 `Ledger/en.json`。
- `project.yml` — XcodeGen 工程：`brew install xcodegen && xcodegen` 后用 Xcode 打开。
- `tools/golden.mjs` — 用 `tools/reference/` 中的 JavaScript 参考实现生成测试账本和标准答案，Swift 解析结果须与之逐项一致。

截图中的数据均为测试用的虚构账本。
