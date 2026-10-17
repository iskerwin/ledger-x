# Ledger X 的 iPhone 记账体验

![Ledger X 记账 概览与账户实拍](hero-20261017-forest.png)

买完一杯咖啡，顺手记下；月底打开手机，知道钱花在哪；出差垫付了多少、信用卡还要还多少，也能随时查清。Ledger X 把 Beancount 的记账、查账和报表带到 iPhone 上，让日常记录更顺手，也让你继续掌握自己的账本。

它使用原生 SwiftUI 界面，账本仍是可读、可编辑的纯文本文件。可以先在手机上新建账本，也可以连接自己的 Git 仓库，和电脑上的 Fava、编辑器一起使用。

## 随手记下一笔消费

点底部「记一笔」，分类、金额和付款账户就在一张卡片里。常用分类直接点选，更多分类可以搜索；买了几样东西，直接用计算器键盘算出合计。想连续补记，就点「保存再记」。

<p>
  <img src="../screenshots/latest/add.png" alt="记账卡片展示分类、金额、付款账户和计算器键盘" width="32%">
  <img src="../screenshots/latest/categories.png" alt="全部分类支持搜索与子分类选择" width="32%">
  <img src="../screenshots/latest/detail.png" alt="交易详情可编辑、复制和退款" width="32%">
</p>

一顿饭的组合付款、一笔消费里的优惠，或者需要报销的垫付，也可以继续补充。记录之后想修改，打开交易就能编辑、复制或登记退款，分录和源文本也保留在详情里。

## 让记录回答实际问题

这个月花了多少，还剩多少？概览把支出、收入、结余和趋势放在一起。报表首页再往前一步，直接回答「钱花在哪」「比以前如何」「还能用多久」。

<p>
  <img src="../screenshots/latest/overview.png" alt="概览显示月度收支和趋势" width="32%">
  <img src="../screenshots/latest/reports.png" alt="报表首页按分类解释钱花在哪" width="32%">
  <img src="../screenshots/latest/comparison.png" alt="与上月同期比较并定位变化来源" width="32%">
</p>

看到某个分类比上月多花了，可以继续查看相关交易，把变化追到具体消费。年底想回顾整年，年度回顾会汇总收支、储蓄率、净资产变化，以及工资、订阅、报销等记录。

## 明细查得快 也能按天回看

找本月的大额支出，或者核对一笔报销，不必从长列表里慢慢翻。明细页提供「本月、大额、待确认、报销」等快捷筛选，结果直接显示笔数与收支合计。经常用的条件还能保存下来。

<p>
  <img src="../screenshots/latest/journal.png" alt="明细按本月筛选并汇总收支" width="32%">
  <img src="../screenshots/latest/calendar.png" alt="月历在明细列表上方展开" width="32%">
  <img src="../screenshots/latest/day.png" alt="当天窗口汇总分币种收支与交易" width="32%">
</p>

喜欢按日期回忆消费，可以展开月历，点某一天查看当天收支、分币种图表、交易与票据。搜索也支持商户、科目、标签和日期组合，适合从「那次出差」一路查到具体一笔。

## 账户和持仓放在一起看

银行卡、钱包、信用卡与投资账户，可以在一个地方查看。账户页同时提供待核对和投资持仓入口，让余额核对成为日常习惯。

<p>
  <img src="../screenshots/latest/accounts.png" alt="账户页汇总净资产并提供核对与持仓入口" width="32%">
  <img src="../screenshots/latest/card.png" alt="信用卡详情展示剩余应还与还款入口" width="32%">
  <img src="../screenshots/latest/holdings.png" alt="投资持仓显示市值成本盈亏和买入批次" width="32%">
</p>

信用卡详情把剩余应还、还款日和记录还款放在前面，也支持照银行账单填写本期应还与最低还款。持仓则展示市值、成本、浮动盈亏和买入批次。数据来自你的记录，查账时能继续追溯到账户流水。

## 账本由自己保管

Ledger X 直接读写 Beancount 文件。你可以把账本留在本机，放进「文件」App 中的文件夹，或连接 GitHub、GitLab、Gitea / Forgejo、WebDAV。使用 Git 仓库时，手机上保存的记录可以同步为提交，电脑拉取之后继续使用原来的工具。

<p>
  <img src="../screenshots/latest/sync.png" alt="同步页区分本机保存与同步状态" width="32%">
  <img src="../screenshots/latest/privacy.png" alt="隐藏金额后仍可浏览概览" width="32%">
  <img src="../screenshots/latest/dark.png" alt="原生深色模式概览" width="32%">
</p>

离线时先保存在本机，同步页能查看待同步状态与失败原因；提交前会在本机检查借贷、账户、余额断言等问题。App 也提供面容 ID / 触控 ID 锁定和隐藏金额，方便在不同场合查看账本。

已经习惯 Beancount 的用户，可以继续使用 BQL 查询、自定义报表和源文本编辑；刚开始尝试的用户，则可以先用界面完成记账与查账，逐步熟悉账本。

## 安装后直接体验

从 [项目 README 的安装说明](../../README.md#快速体验打开演示账本) 添加 SideStore / AltStore 源，或前往 [Releases](https://github.com/iskerwin/ledger-x/releases) 下载。打开 App 后点「先看看演示账本」，不需要联网、注册，也不用先配置仓库和 Token。演示数据可以随意改、随时重置；演示账本有新版本时，在 App 里一键更新，不用重装。

准备记录自己的生活时，选择「复制为我的空账本」，保留常用账户与分类，从第一笔真实消费开始。

**Ledger X，让 Beancount 随手可用，让每一笔记录都有处可查。**

---

本文界面实拍于 2026 年 10 月 17 日的 main 开发版，包含尚未发布的 0.2.1 改进；当前发布版本及安装方式以项目说明为准。截图使用 App 内置的虚构演示账本（来自 ledger-demo）。项目目前为预览版，支持 iOS 17 及以上、简体中文和 English。
