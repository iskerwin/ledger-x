import SwiftUI
import LedgerKit

/// 使用指南 and 常见问题, in 设置. The text lives here (both languages side by side) rather than in en.json: it is
/// long prose, read as a whole.
struct GuideView: View {
    @State private var q = ""

    struct Topic: Identifiable {
        let symbol: String
        let title: String
        let points: [String]
        var id: String { title }
    }
    struct QA: Identifiable {
        let q: String
        let a: String
        var id: String { q }
    }

    var body: some View {
        let t = q.trimmingCharacters(in: .whitespaces)
        let topics = Self.topics.filter { t.isEmpty || $0.title.contains(t) || $0.points.contains { $0.localizedCaseInsensitiveContains(t) } }
        let faq = Self.faq.filter { t.isEmpty || $0.q.localizedCaseInsensitiveContains(t) || $0.a.localizedCaseInsensitiveContains(t) }
        List {
            if !topics.isEmpty {
                Section(LS("使用指南")) {
                    ForEach(topics) { x in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(x.points, id: \.self) { p in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text(p).fixedSize(horizontal: false, vertical: true)
                                    }
                                    .font(.subheadline)
                                }
                            }
                            .padding(.vertical, 4)
                        } label: {
                            Label(x.title, systemImage: x.symbol)
                        }
                    }
                }
            }
            if !faq.isEmpty {
                Section(LS("常见问题")) {
                    ForEach(faq) { x in
                        DisclosureGroup {
                            Text(x.a).font(.subheadline).fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
                        } label: {
                            Text(x.q)
                        }
                    }
                }
            }
            if topics.isEmpty && faq.isEmpty {
                Text(LS("没有找到相关内容")).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $q, prompt: LS("搜索指南和问题"))
        .navigationTitle(LS("使用指南"))
        .navigationBarTitleDisplayMode(.inline)
    }

    static var topics: [Topic] { [
        Topic(symbol: "book.closed", title: tr("账本与同步", "Ledger and sync"), points: [
            tr("账本是你仓库里的普通 Beancount 文本，App 不另存数据。每次保存就是一次提交，电脑上 git pull 就能看到。",
               "The ledger is plain Beancount text in your repository; the app keeps no data of its own. Every save is one commit, which git pull brings to your computer."),
            tr("离线时改动暂存在本机，联网后自动提交；设置 → 同步队列可以看到还没提交的改动。",
               "Changes made offline wait on this phone and are committed once online; Settings → Sync queue lists what hasn't gone yet."),
            tr("保存前 App 会先检查：借贷平衡、账户已开、余额断言、余额不足、信用额度。最终以仓库里的 bean-check 为准。",
               "Before saving the app checks balance, open accounts, balance assertions, overdrafts and credit limits; bean-check in the repository has the final word."),
            tr("设置 → 最近改动里可以撤回 App 做的修改；在电脑上改过的地方不能从 App 撤回。",
               "Settings → Recent changes takes back changes made in the app; it won't undo what was edited elsewhere."),
        ]),
        Topic(symbol: "plus.circle", title: tr("记一笔", "Adding an entry"), points: [
            tr("任何页面点底部中间的「记一笔」打开卡片：上面选支出 / 收入 / 转账，点宫格选科目。带「…」的大类会选上次用过的子类，并列出子类可改选。",
               "Tap Add in the middle of the tab bar on any page. Pick expense, income or transfer at the top and a category in the grid; a category with “…” picks the one you used last and lists the others under it."),
            tr("自带键盘：长按 + 输入 ×，长按 − 输入 ÷，长按退格清空。有算式时「完成」先变成「=」。",
               "The keypad: hold + for ×, hold − for ÷, hold delete to clear. With a sum typed, Done first becomes =."),
            tr("「保存再记」保存后留在卡片上接着记，「完成」保存并关闭。",
               "Save & next keeps the card open for the next entry; Done saves and closes it."),
            tr("收付款方和备注都可以不填。收付款方不填时省略，备注不填写成 \"\"；引号由 App 自动加。",
               "Payee and note are optional: an empty payee is left out and an empty note is written \"\"; the app adds the quotes."),
            tr("右上角「⋯」→ 完整表单：分录、直接写 Beancount 文本、AA、外币实付都在这里。",
               "⋯ → Full form for split entries, plain Beancount text, sharing with others and paying in another currency."),
            tr("常用交易：近期重复出现的交易会列在卡片顶部，固定金额的点「入账」一步记好，提示条上可以撤销。",
               "Frequent entries appear at the top of the card; ones with a fixed amount are saved with one tap on Save, with undo on the banner."),
            tr("宫格的图标、名称、顺序可以在「⋯」→ 分类图标与排序里改，或长按某个分类。只存在本机，不改账本。",
               "Change the grid's icons, names and order under ⋯ → Category icons & order, or hold a category. Kept on this phone; the ledger doesn't change."),
        ]),
        Topic(symbol: "square.split.2x1", title: tr("组合付款与优惠", "Several accounts and discounts"), points: [
            tr("一笔支出由几个账户一起付：点付款账户 →「组合付款…」，添加其他账户和各自金额，选的付款账户付余下的部分。",
               "To pay one expense from several accounts: tap the paying account → Pay with several…, add the others and their amounts; the chosen account pays the rest."),
            tr("优惠（立减、红包、券）单独填：支出按原价记，优惠记为收入，默认 Income:Rewards。",
               "A discount (instant cut, red packet, coupon) is entered on its own: the expense keeps its full price and the discount is income, Income:Rewards by default."),
            tr("可报销和 AA 的支出不单列优惠，直接填实付金额。",
               "Reimbursable and shared expenses don't take a discount: enter what was paid."),
        ]),
        Topic(symbol: "doc.text", title: tr("报销与备用金", "Reimbursements and petty cash"), points: [
            tr("垫付的钱在记一笔里打开「报销」：有剩余的备用金会默认选上，用备用金付的直接冲抵；自己垫付的进入待报销。",
               "For money advanced, turn on Reimburse: petty cash with money left is picked by default and offsets the expense; advanced by yourself, it waits to be claimed."),
            tr("报表 → 报销：待报销、备用金、每张报销单和历史都在这里。左滑一笔可改支出类型、凭证类型或移出这张单子。",
               "Reports → Reimbursements has what's waiting, petty cash, every claim and the history. Swipe a line to change its type, receipt or take it off the claim."),
            tr("在一张报销单或备用金里点「导出报销单」，可生成 PDF（含附件）、按公司模板的 xlsx 和 CSV。",
               "Export from a claim or petty cash makes a PDF with the attachments, an xlsx in the company template and a CSV."),
        ]),
        Topic(symbol: "person.2", title: tr("往来与 AA", "People and sharing"), points: [
            tr("借出、替别人付、别人替你付都记在 Assets:Receivable:Personal，每一行用 person: 写明是谁；账户 → 往来按人汇总。",
               "Lending, paying for someone and being paid for go to Assets:Receivable:Personal with person: on each line; Accounts → People sums them up per person."),
            tr("AA：在完整表单打开「AA 分摊」，选人后自动平分；别人还钱时在往来页登记。",
               "Sharing: turn on Split in the full form and pick people; it's divided evenly. Record their payback on the People page."),
        ]),
        Topic(symbol: "list.bullet.rectangle.portrait", title: tr("明细与日历", "Journal and calendar"), points: [
            tr("搜索可以用收付款方、摘要、科目、对方、#标签、金额或 2026-09 这样的月份。几个条件用空格隔开，要同时满足，比如「2026-09 餐饮 >50」。",
               "Search by payee, note, account, person, #tag, amount or a month like 2026-09. Separate conditions with spaces; all must hold, e.g. “2026-09 餐饮 >50”."),
            tr("日期范围：2026-07 2026-08、2026-07~2026-08 或 Fava 的写法 2026-07 - 2026-08；也可写 2026、2026-Q3、2026-07-15。",
               "Date ranges: 2026-07 2026-08, 2026-07~2026-08 or Fava's 2026-07 - 2026-08; also 2026, 2026-Q3, 2026-07-15."),
            tr("只查某一项：科目:餐饮、账户:招商（账户名或显示名称）、收付款方:滴滴、备注:午饭、对方:王五（英文 account: payee: note: person: 也行）。前面加 - 表示排除，如 -加班；有空格的词加引号。金额：35、>100、<50、100~200。",
               "One field only: account:, payee:, note:, person: (or 科目: 账户: 收付款方: 备注: 对方:). A leading - leaves things out, like -overtime; quote words with spaces. Amounts: 35, >100, <50, 100~200."),
            tr("搜索框空着时点它，会列出这些写法的例子，点一下就能用。",
               "Tap the empty search box for examples of all this; tap one to use it."),
            tr("左上角切换到日历：格子底色越深花得越多，主题色的数字是支出，+ 开头的是收入；点一天看当天交易。",
               "Switch to the calendar at the top left: darker cells spent more, the theme-coloured figure is spending and + is income; tap a day for its entries."),
            tr("点开一笔交易可以编辑源文本、复制为新交易、登记退款、调整当天顺序、加入订阅。",
               "Open an entry to edit its text, copy it as a new one, record a refund, reorder the day or make it a subscription."),
        ]),
        Topic(symbol: "building.columns", title: tr("账户与核对", "Accounts and checking"), points: [
            tr("账户和科目详情按月分组：每月显示流出、流入和月末余额（科目显示当月合计），点一下展开当月的流水。",
               "An account's or category's page is grouped by month with money out, in and the month-end balance (a category shows its total); tap a month to open it."),
            tr("账户页的分组（银行、信用卡…）和管理账户里的科目大类都可以点标题收起。",
               "Groups on the Accounts page (banks, cards…) and the categories under Manage accounts fold away with a tap on their heading."),
            tr("账户详情页点「余额核对」，输入银行 App 里的余额，一致时写入余额断言，不一致会显示差额。",
               "On an account, Check balance takes the balance from your bank; when it matches, a balance assertion is written, otherwise the difference is shown."),
            tr("在账户编辑里设账单日 / 核对日，到期会提醒对账；信用卡还可设还款日和额度。",
               "Set a statement day in the account's settings for a reminder to check it; cards also take a due day and a limit."),
            tr("哪些账户计入净资产、哪些列入资产负债表：设置 → 统计范围，或账户页 → 管理账户，也可在账户详情页直接开关。",
               "Which accounts count in net worth and appear on the balance sheet: Settings → What's counted, Accounts → Manage accounts, or the switches on an account's page."),
        ]),
        Topic(symbol: "chart.bar.xaxis", title: tr("报表", "Reports"), points: [
            tr("报表页有损益表、资产负债表、试算平衡表、预算、现金流预测、订阅、报销、工资、事件、收付款方和值得留意。",
               "Reports has the income statement, balance sheet, trial balance, budgets, forecast, subscriptions, reimbursements, salary, events, payees and things to check."),
            tr("可以写 BQL 查询，常用的可保存；账本里的 query 指令也会列出来。",
               "BQL queries can be written and saved; query directives in the ledger are listed too."),
        ]),
        Topic(symbol: "laptopcomputer", title: tr("在电脑上编辑", "Editing on a computer"), points: [
            tr("改之前先 git pull，改完 git push；回到 App 下拉刷新就能看到。",
               "git pull before editing and git push after; pull to refresh in the app to see it."),
            tr("App 认得的写法（元数据、标签、链接）见项目里的「账本写法参考」；照着写，App 和 Fava、bean-check 都能识别。",
               "The conventions the app reads (metadata, tags, links) are in the ledger-writing reference; written that way, the app, Fava and bean-check all understand them."),
            tr("App 不执行 plugin；include、option、plugin 只在电脑上改 main.bean。",
               "The app doesn't run plugins; include, option and plugin are edited in main.bean on a computer."),
        ]),
        Topic(symbol: "lock", title: tr("隐私与备份", "Privacy and backups"), points: [
            tr("导航栏的眼睛按钮隐藏所有金额；设置里可以开启面容 ID 解锁。",
               "The eye button hides every amount; Face ID unlock is in Settings."),
            tr("访问令牌存在钥匙串里，不会写进账本或仓库。",
               "The access token lives in the Keychain, never in the ledger or the repository."),
            tr("设置 → 备份与导出：自动备份到 iCloud Drive 的文件夹，也可以导出 zip 或 CSV。",
               "Settings → Backup & export backs up to a folder in iCloud Drive and exports zip or CSV."),
        ]),
    ] }

    static var faq: [QA] { [
        QA(q: tr("保存后显示「待同步」是什么意思？", "What does “waiting to sync” mean after saving?"),
           a: tr("改动已经记在本机，正在或等待提交到仓库。联网后会自动提交；一直没提交的，到设置 → 同步队列点「立即同步」。",
                 "The change is on this phone and is being or will be committed. It goes out once online; if it stays, tap Sync now under Settings → Sync queue.")),
        QA(q: tr("提交前检查拦下来了怎么办？", "The pre-save check stopped my entry. Now what?"),
           a: tr("看提示里的原因：可以返回修改；确定没问题就「仍然提交」；暂时不确定可「暂存本机」，之后在同步队列里左滑推送或删除。",
                 "Read the reason: go back and fix it, submit anyway if you're sure, or keep it on this phone and later push or delete it from the sync queue.")),
        QA(q: tr("余额断言不符怎么办？", "A balance assertion fails."),
           a: tr("说明账本和银行对不上：在这个账户的明细里找漏记或记错的交易。确认银行余额后，可以用「余额核对」重新核对。",
                 "The ledger and the bank disagree: look in the account for a missing or wrong entry, then check the balance again.")),
        QA(q: tr("在电脑上改了账本，App 里没变化？", "I edited the ledger on my computer and the app doesn't show it."),
           a: tr("确认已经 git push，然后在 App 里下拉刷新，或回到 App 时它会自动拉取。",
                 "Make sure it's pushed, then pull to refresh; the app also fetches when you come back to it.")),
        QA(q: tr("撤回时提示已经在别处修改？", "Undo says it was changed elsewhere."),
           a: tr("那一处在 App 之外被改过，为了不覆盖你的改动，App 不会撤回。请在电脑上手动改，或在明细里编辑那笔交易。",
                 "That place was edited outside the app, so it won't be overwritten. Change it on your computer or edit the entry in the journal.")),
        QA(q: tr("怎么同时按日期和账户（或科目）找？", "How do I search by date and account (or category) at once?"),
           a: tr("在明细搜索框里用空格隔开写，比如「2026-07 2026-08 科目:餐饮」或「2026-09 账户:招商 >100」，所有条件都要满足。也可以先在账户详情点「查看明细」限定账户，再输入日期。",
                 "Separate them with spaces in the journal's search box, e.g. “2026-07 2026-08 account:Food” or “2026-09 account:CMB >100”; every condition must hold. Or open the account and tap View entries, then type the dates.")),
        QA(q: tr("怎么修改或删除一笔交易？", "How do I change or delete an entry?"),
           a: tr("在明细里点开它 →「编辑」，改源文本或删除；「复制为新交易」会打开记一笔卡片。",
                 "Open it in the journal → Edit to change its text or delete it; Copy as new opens the Add card.")),
        QA(q: tr("宫格里找不到某个科目？", "A category isn't in the grid."),
           a: tr("可能被隐藏了：「⋯」→ 分类图标与排序里重新打开。账本里没有的科目要先在账户页 → 管理账户里开户。",
                 "It may be hidden: show it again under ⋯ → Category icons & order. A category the ledger doesn't have yet is opened under Accounts → Manage accounts.")),
        QA(q: tr("外币消费怎么记？", "How do I record spending in another currency?"),
           a: tr("在卡片上把币种改成外币，然后到完整表单填「实付」，也就是账户实际扣了多少本币。",
                 "Change the currency on the card, then fill in the amount charged to your account on the full form.")),
        QA(q: tr("用了备用金冲抵，但其实是自己垫付的？", "I offset an expense with petty cash by mistake."),
           a: tr("报表 → 报销 → 那笔备用金，左滑那一笔选「移出」，它就回到待报销。",
                 "Reports → Reimbursements → that petty cash, swipe the line and take it off; it goes back to waiting to be claimed.")),
        QA(q: tr("优惠为什么算作收入？", "Why is a discount counted as income?"),
           a: tr("这样支出保留原价，统计里能看到省了多少钱；不想这样记，就不填优惠，直接把金额填成实付。",
                 "So the expense keeps its full price and you can see what you saved. If you'd rather not, leave the discount out and enter what you paid.")),
        QA(q: tr("净资产和资产负债表的数字不一样？", "Net worth and the balance sheet show different numbers."),
           a: tr("两边可以各自排除账户（设置 → 统计范围），排除得不一样，数字就不同。资产负债表有排除时，页面底部会注明。",
                 "Each can leave out its own accounts (Settings → What's counted); when they differ, so do the figures. The balance sheet says so at the bottom.")),
        QA(q: tr("试算表里有「折算差额」，是账错了吗？", "The trial balance shows a conversion difference. Is something wrong?"),
           a: tr("不是。外币和证券按今天的价格折算，和记账时的汇率不同，就会出现这个差额。",
                 "No. Foreign currencies and securities are converted at today's prices, which differ from those when they were recorded.")),
        QA(q: tr("换手机后设置还在吗？", "Do my settings survive a new phone?"),
           a: tr("跟账本有关的都在仓库的 ledger-x.json 里，所有设备共用：主文件、文件规则、记账偏好（默认付款账户、币种）、统计范围、大额支出、已核对和已忽略的提示、常用交易置顶与隐藏、工资条模板、商户拼音；保存的查询在 queries/ 里。主题、语言、宫格图标、提醒、面容 ID 只存在这台手机。设置 → 仓库结构与共用设置可以一页看全。",
                 "Everything about the ledger is in ledger-x.json in the repository and shared by every device: main file, file rules, entry defaults, what's counted, the large-expense threshold, checked and ignored notices, pinned and hidden frequent entries, payslip templates and payee spellings; saved queries are in queries/. Theme, language, grid icons, reminders and Face ID stay on each phone. Settings → Repository & shared settings shows it all.")),
    ] }
}
