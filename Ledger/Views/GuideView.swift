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
                            VStack(alignment: .leading, spacing: AppSpacing.icon) {
                                ForEach(x.points, id: \.self) { p in
                                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.icon) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text(p).fixedSize(horizontal: false, vertical: true)
                                    }
                                    .font(.subheadline)
                                }
                            }
                            .padding(.vertical, AppSpacing.detail)
                        } label: {
                            Label(x.title, systemImage: x.symbol).labelStyle(ControlLabelStyle())
                        }
                    }
                }
            }
            if !faq.isEmpty {
                Section(LS("常见问题")) {
                    ForEach(faq) { x in
                        DisclosureGroup {
                            Text(x.a).font(.subheadline).fixedSize(horizontal: false, vertical: true).padding(.vertical, AppSpacing.detail)
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
        .appSearchable(text: $q, prompt: LS("搜索指南和问题"))
        .navigationTitle(LS("使用指南"))
        .navigationBarTitleDisplayMode(.inline)
    }

    static var topics: [Topic] { [
        Topic(symbol: "book.closed", title: tr("账本与同步", "Ledger and sync"), points: [
            tr("同步中的箭头表示正在处理，灰色表示已同步、正常等待或离线，橙色表示需要检查的暂存，红色表示失败；具体原因可点开同步状态查看。",
               "Sync arrows show work in progress; grey means synced, waiting normally or offline, orange means a held change needs checking, and red means failure. Open sync status for the reason."),
            tr("账本是你仓库里的普通 Beancount 文本，App 不另存数据。每次保存就是一次提交，电脑上 git pull 就能看到。",
               "The ledger is plain Beancount text in your repository; the app keeps no data of its own. Every save is one commit, which git pull brings to your computer."),
            tr("离线时改动暂存在本机，联网后自动提交；设置 →「同步与最近改动」→「待同步」可以看到还没提交的改动。",
               "Changes made offline wait on this phone and are committed once online; Settings → Sync and recent changes → Pending lists what hasn't gone yet."),
            tr("保存前 App 会先检查：借贷平衡、账户已开、余额断言、余额不足、信用额度。最终以仓库里的 bean-check 为准。",
               "Before saving the app checks balance, open accounts, balance assertions, overdrafts and credit limits; bean-check in the repository has the final word."),
            tr("设置 →「同步与最近改动」→「已同步记录」打开最近改动，左滑一条可以撤回 App 做的修改；在电脑上改过的地方不能从 App 撤回。",
               "Settings → Sync and recent changes → Synced changes opens Recent changes; swipe one to take back a change made in the app. It won't undo what was edited elsewhere."),
        ]),
        Topic(symbol: "plus.circle", title: tr("记一笔", "Adding an entry"), points: [
            tr("任何页面点底部中间的「记一笔」打开卡片：上面选支出 / 收入 / 转账，点宫格选科目。带「…」的大类会选上次用过的子类，并列出子类可改选。",
               "Tap Add in the middle of the tab bar on any page. Pick expense, income or transfer at the top and a category in the grid; a category with “…” picks the one you used last and lists the others under it."),
            tr("自带键盘：长按 + 输入 ×，长按 − 输入 ÷，长按退格清空。有算式时「保存」先变成「=」。",
               "The keypad: hold + for ×, hold − for ÷, hold delete to clear. With a sum typed, Save first becomes =."),
            tr("转账：上面两张卡片是转出和转入账户，显示尾号和余额（信用卡显示欠款），输入金额后显示转账后的余额；中间的圆形按钮对调两边。同一个账户换另一种币种也可以，转入选同一个账户即可。",
               "Transfers: the two cards are the accounts sent from and to, with their last digits and balance (what's owed on a card), and the balance after this transfer once an amount is in; the round button between them swaps the two. To exchange within one account, pick the same account to send to."),
            tr("手续费、汇率和到账金额都在金额旁的币种按钮里（币种、汇率与手续费），支出和转账一样；填了手续费后金额下面会显示一行，点它可以改。",
               "Fees, rates and the amount received are under the currency button beside the amount (Currency, Rate & Fee), for expenses and transfers alike; once a fee is set, a line under the amount shows it and opens it again."),
            tr("金额下面一行是付款账户、日期和「更多」：报销、优惠、标签、AA、组合付款和本期补差都在「更多」里，设了哪项它就变成主题色并写出来。收入和转账这一格是「标签」，收入的「填写对方」在右上角「⋯」。要存到另一个账本，在「⋯」→ 切换账本。",
               "Under the amount is one row: the paying account, the day and More. Reimburse, discount, tags, sharing, several accounts and this period's top-up are under More, which turns the theme colour and names what is set. For income and transfers that cell is Tags; income's Other party is under ⋯. To save to another ledger, use ⋯ → Switch Ledger."),
            tr("「保存再记」保存后留在卡片上接着记，「保存」保存并关闭。",
               "Save & next keeps the card open for the next entry; Save stores it and closes the card."),
            tr("收付款方和摘要都可以不填。收付款方不填时省略，摘要不填写成 \"\"；引号由 App 自动加。",
               "Payee and note are optional: an empty payee is left out and an empty note is written \"\"; the app adds the quotes."),
            tr("右上角「⋯」→ 完整表单：分录、直接写 Beancount 文本、AA、外币实付都在这里。",
               "⋯ → Full form for split entries, plain Beancount text, sharing with others and paying in another currency."),
            tr("完整表单右上角「清空」把这一页填的内容一次清掉（日期保留），编辑已有交易时是「还原」，回到原记录；提示条上可以撤销。分录或文本没填完也可以直接切换类型或点「快捷记账」返回，没填完的内容会保留，切回去接着填。",
               "Clear at the top right of the full form empties the page in one tap (the date stays); when editing an entry it's Revert, back to the entry as it was. Undo is on the banner. A split or text entry that isn't finished doesn't keep you there: switch type or go back to Quick entry, and it's kept for when you switch back."),
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
            tr("垫付的钱在记一笔里点「更多」→「报销」：有剩余的备用金会默认选上，用备用金付的直接冲抵；自己垫付的进入待报销。",
               "For money advanced, tap More → Reimburse: petty cash with money left is picked by default and offsets the expense; advanced by yourself, it waits to be claimed."),
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
            tr("只查某一项：科目:餐饮、账户:招商（账户名或显示名称）、收付款方:滴滴、摘要:午饭（也可写 备注:）、对方:王五（英文 account: payee: note: person: 也行）。前面加 - 表示排除，如 -加班；有空格的词加引号。金额：35、>100、<50、100~200。",
               "One field only: account:, payee:, note:, person: (or 科目: 账户: 收付款方: 摘要: 对方:). A leading - leaves things out, like -overtime; quote words with spaces. Amounts: 35, >100, <50, 100~200."),
            tr("搜索框空着时点它，会列出这些写法的例子，点一下就能用。",
               "Tap the empty search box for examples of all this; tap one to use it."),
            tr("左上角的月历按钮展开网格日历，快捷筛选和标签暂时收起，已加的条件照常显示。标题下方是月度支出、收入和结余；日期固定六行，日期下面红点表示支出、绿点表示收入，两种都有时红左绿右，点在日期下居中，点越大金额越大，只有其他交易时显示灰点。点一天就打开当天的交易，弹层开着时点别的日期直接换到那一天，用下拉或右上角完成关闭；当天弹层先开得矮一些，露出上方日期，可上拉到半屏或全屏。星期从周几开始跟手机系统的设置，和搜索里的「本周」一样。箭头、左右滑动或点标题的年月滚轮都能换月，「回到本月」回到当前。订阅日历共用网格，扣费日是主题色单点，只能选择今天至未来两个月范围，点日期筛出当天扣费，「显示整月」取消筛选。月历只有外面一张卡片，没有内层框，也不套玻璃。",
               "The calendar button at the top left opens a month grid in place of quick filters and tags; active filters stay visible. Monthly spending, income and net sit below the title. Six fixed rows show a red dot for spending and a green dot for income under each date, red on the left when both appear, centred under the date; larger dots mean larger amounts, and grey means other entries only. Tap a date to open that day’s transactions; tap another date to switch, and swipe the sheet down or tap Done to close it. The day sheet starts low, leaving the dates above it tappable, and can be pulled up to half or full height. The week starts on the phone’s first day of the week, the same day as a This week search. Use arrows, swipe, or tap the title for the month and year wheels; Back to this month returns to now. Subscriptions share the grid with single theme-colour charge dots. Select a date from today through the next two months to filter charges, or Show whole month to clear it. The calendar is a single card, with no inner frame and no glass."),
            tr("明细的样子在「设置 → 外观 → 明细样式」里选：简洁（默认，只有文字）、图标（每笔前面是分类图标，颜色和报表里这个分类的颜色一样，在分类管理改过颜色的按改过的）、紧凑（每笔一行，备注和标签点开再看）。明细、账户页、搜索结果和日历当天都跟着变，只存在这台手机。",
               "Pick how transactions look in Settings → Appearance → Transaction list: Simple (the default, words only), Icon (each starts with its category's icon, in the colour the reports give it, or the one you picked) or Compact (one line each; open one for its note and tags). The journal, account pages, search results and a calendar day all follow; it is kept on this phone only."),
            tr("点开一笔交易可以编辑源文本、复制为新交易、登记退款、调整当天顺序、加入订阅。",
               "Open an entry to edit its text, copy it as a new one, record a refund, reorder the day or make it a subscription."),
            tr("退款默认只退商品金额；原交易有银行手续费、而且银行也退回了的，在退款表单打开「同时退回手续费」，手续费退回到当初付它的账户。",
               "A refund takes back the goods only; if the original had a bank fee and the bank refunded it too, turn on Also refund the fee in the refund form, and it goes back to the account that paid it."),
        ]),
        Topic(symbol: "paperclip", title: tr("附件与票据", "Attachments and statements"), points: [
            tr("交易附件：打开一笔交易 →「附件」→「添加附件」，可拍照、从照片或文件选。照片会转成 JPG；支持 JPG、PNG、HEIC、PDF 等常见格式，其他格式能保存但可能无法在 App 内预览。",
               "A transaction's attachment: open the entry → Attachments → Add Attachment, from the camera, Photos or Files. Photos are saved as JPG; JPG, PNG, HEIC, PDF and other common formats preview in the app, other files are kept but may not."),
            tr("交易附件默认存到仓库的 documents/receipts/；账户的对账单在账户详情点「添加票据 / 对账单」，存到银行或机构的文件夹，两者分开放。",
               "Transaction attachments go to documents/receipts/ by default; an account's statements are added from the account page (Add document / statement) and go to the bank's or institution's folder, apart from them."),
            tr("账户页的「交易附件」列出所有交易的附件，不分账户；账户详情只显示这个账户的对账单。",
               "Transaction Attachments on the Accounts page lists every transaction's attachments whichever account paid; an account's page shows only its statements."),
            tr("删除附件或对账单（左滑或长按 → 删除）时可选「只移除引用」，文件留在仓库；或「移除并删除文件」，同步后仓库里的文件也删掉。其他记录还在用的文件不会删。",
               "Deleting an attachment or statement (swipe, or press and hold → Delete) offers Remove Record Only, which keeps the file in the repository, or Remove and Delete File, which deletes it too once synced. A file other records still use is never deleted."),
            tr("选了「移除并删除文件」后，手机上保留副本 30 天：删除后提示条上的「撤销」可以马上恢复；之后到账户页 →「交易附件」最下面的「最近删除」点「恢复」，文件会传回仓库，记录也恢复。附件和对账单都在这里。",
               "After Remove and Delete File a copy stays on this phone for 30 days: Undo on the banner right after deleting brings it back at once; later, Accounts → Transaction Attachments → Recently Deleted at the bottom → Restore puts the file back in the repository along with its record. Attachments and statements are both listed there."),
        ]),
        Topic(symbol: "building.columns", title: tr("账户与核对", "Accounts and checking"), points: [
            tr("账户和科目详情按月分组：每月显示流出、流入和月末余额（科目显示当月合计），点一下展开当月的流水。",
               "An account's or category's page is grouped by month with money out, in and the month-end balance (a category shows its total); tap a month to open it."),
            tr("每个大类的图标在记一笔、管理账户、账户页和报表里都一样；在管理账户里长按大类可以更换图标和颜色（记一笔里长按分类也可以），只存在这台手机。颜色用在管理账户、账户页、报表和记一笔的付款账户那一格上，记一笔的宫格仍是黑白、选中时用主题色。",
               "Each group has one icon on the Add card, Manage accounts, the Accounts page and in reports; hold a group under Manage accounts (or a category on the Add card) to change its icon and colour, kept on this phone. The colour shows in Manage accounts, Accounts, reports and the Add card's account cell; the Add grid stays black and white and uses the theme colour when picked."),
            tr("账户页的分组（银行、信用卡…）和管理账户里的科目大类都可以点标题收起。",
               "Groups on the Accounts page (banks, cards…) and the categories under Manage accounts fold away with a tap on their heading."),
            tr("银行卡、电子钱包和储值卡、现金和信用卡的账户页顶部可以画成一张卡：在「设置 → 外观 → 账户卡片」选「卡面」。卡的颜色是这个账户大类的颜色（管理账户里长按大类可改），每张卡自带一种纹理和名称首字的水印，方便同色的卡互相区分。账户名用常见银行或钱包的英文简称（如 Assets:Bank:CMB、Assets:EWallet:Alipay），或显示名里有它的中文名（如「招商银行一卡通」）时，卡面改用接近它的配色，右下角水印是它的单色图标（照各家标志简化），目前认得招商、工商、建设、中国、农业、交通、浦发、中信、汇丰、花旗、恒生、中银香港、渣打、众安、Mox、支付宝、微信支付、Wise、八达通、AlipayHK、PayMe、PayPal、Revolut。长按卡面选「编辑卡面」可以按账户改机构、颜色、纹理和水印（文字、图标或不显示），调水印大小和透明度；水印选「图标」时点一个内置图标就换，也可以从照片或文件选自己的图标，自己的图标默认变成单色剪影，跟卡面风格一致，白底图片会自动去背景（去不干净调「强度」），也可选原色。这些设置和图标只存在这台手机、按账本分开，「恢复默认」回到自动。银行卡和钱包写着当前余额、多久没核对、近 30 天走势、其他币种和本月流入流出；信用卡写着尾号、剩余应还、已还多少和还款日。下面的数字和按钮不变；证券、加密货币、应收和贷款仍是普通样式。",
               "The top of a bank, wallet or stored-value card, cash or credit card account can be drawn as a card: choose Card in Settings → Appearance → Account Cards. It takes the colour of the account's group (long-press the group in Manage accounts to change it), and each card gets its own texture and the first letter of its name as a watermark, so cards of one colour still tell apart. When the account is named with a common bank or wallet's short name (Assets:Bank:CMB, Assets:EWallet:Alipay) or its shown name contains the Chinese name (招商银行一卡通), the card uses colours close to that bank's, with its one-colour icon (a simplified form of its mark) as the watermark. Known so far: CMB, ICBC, CCB, Bank of China, ABC, BoCom, SPDB, CITIC, HSBC, Citi, Hang Seng, BOCHK, Standard Chartered, ZA Bank, Mox, Alipay, WeChat Pay, Wise, Octopus, AlipayHK, PayMe, PayPal and Revolut. Hold a card face and choose Edit Card Face to change its institution, colour, texture and watermark (text, an icon, or none) and the watermark's size and opacity. For an icon, tap one of the built-in icons, or choose your own from Photos or Files. Your own icon becomes a one-colour silhouette by default, to match the card; a white background is removed (raise Strength if some is left), or keep its original colours. These settings and icons stay on this phone, apart for each ledger; Reset goes back to automatic. Banks and wallets show the balance, how long since it was checked, the last 30 days, other currencies and this month's money in and out; credit cards show the last four digits, what is left to pay, how much is paid and the due date. The figures and buttons below stay the same; brokerage, crypto, receivable and loan accounts stay plain."),
            tr("银行卡和信用卡可以把卡号、有效期和安全码存在手机里：账户卡片选「卡面」后，长按卡面选「卡片信息」填写（都可以不填）。这些只存在这台手机的钥匙串里，不写进账本，也不随备份或 iCloud 同步；打开时都是隐藏的，点「显示」或「编辑」要先验证面容 ID 或密码，30 秒后或离开 App 时自动隐藏。显示时每一项旁边可以复制，复制的内容只留在这台手机、60 秒后从剪贴板清除。账本里没设尾号时，卡面、账户列表、记一笔和交易详情都显示这里卡号的后 4 位，卡面还写有效期（隐私模式下不写）；关闭账户时这些信息一起删除。",
               "Bank and credit cards can keep their number, expiry and security code on the phone: with Account Cards set to Card, long-press the card and choose Card Details (every field is optional). They stay only in this phone's keychain: never in the ledger, a backup or iCloud. They open hidden; Show and Edit ask for Face ID or the passcode first, and they hide again after 30 seconds or when you leave the app. While shown, each field can be copied; the copy stays on this phone and is cleared from the clipboard after 60 seconds. When the ledger sets no last digits, the card face, the account list, the Add card and transaction details show this number's last 4, and the card face its expiry (not in privacy mode); closing the account deletes them."),
            tr("金额的数字可以换成圆体：「设置 → 外观 → 金额数字」选「圆体」，交易、汇总和每日小计里的金额都改用圆润的数字，中文不变；页面顶部的大号金额一直是圆体。",
               "Amounts can use rounded digits: choose Rounded in Settings → Appearance → Amount digits. Amounts in transactions, summaries and daily totals then use rounded figures; the large amounts at the top of a page always do."),
            tr("账户详情页点「余额核对」，输入银行 App 里的余额，一致时写入余额断言，不一致会显示差额。断言日期下面有「明天」「今天」：核对今天日终的余额选明天。报销回款、账户备注和「从哪天起」的日期下面同样有今天、昨天、前天。",
               "On an account, Check balance takes the balance from your bank; when it matches, a balance assertion is written, otherwise the difference is shown. Under the date are Tomorrow and Today: for today's closing balance pick Tomorrow. The dates of a reimbursement payment, an account note and \u{201C}From\u{201D} have Today, Yesterday and the day before under them too."),
            tr("在账户编辑里设账单日 / 核对日，到期会提醒对账；信用卡还可设还款日和额度。",
               "Set a statement day in the account's settings for a reminder to check it; cards also take a due day and a limit."),
            tr("账户页顶部的卡片：「净资产」下面一行是比上月末多了或少了多少，点它进统计范围；「收支」下面一行是今年的月均支出和比去年同期多花或少花的比例（去年同期没有记录时显示月均结余），点它看年度回顾。",
               "The card at the top of Accounts: under Net worth, the change since the end of last month (tap it for What's counted); under Income & spending, this year's monthly spending and how it compares with the same days last year (the monthly savings when there is no last year to compare), tap it for the year in review."),
            tr("哪些账户计入净资产、哪些列入资产负债表：设置 → 统计范围，或账户页 → 管理账户，也可在账户详情页直接开关。",
               "Which accounts count in net worth and appear on the balance sheet: Settings → What's counted, Accounts → Manage accounts, or the switches on an account's page."),
            tr("持有外币或证券时，账户页有「更新价格」，旁边是最新价格的日期；可从 Yahoo Finance 获取或手动填写，每项写一条 price 指令。",
               "Holding other currencies or securities, the Accounts page shows Update Prices with the latest price's date; fetch them from Yahoo Finance or type them in, one price directive each."),
        ]),
        Topic(symbol: "chart.bar.xaxis", title: tr("报表", "Reports"), points: [
            tr("报表页有损益表、资产负债表、试算平衡表、预算、现金流预测、订阅、报销、工资、事件、收付款方和值得留意。",
               "Reports has the income statement, balance sheet, trial balance, budgets, forecast, subscriptions, reimbursements, salary, events, payees and things to check."),
            tr("单项趋势图和排行条使用主题色；收入与支出同时比较时，收入绿色、支出红色，并用图例、线型或符号区分。分类和多币种构成保留各自颜色，同一分类不会因为换月或排名变化而换色；颜色只帮助识别，具体金额和含义看名称、图例与数字。",
               "Single-series trends and ranking bars use the theme colour. When income and spending are compared, income is green and spending red, with legends, line styles or symbols to distinguish them. Categories and currency compositions keep their own colours; a category keeps its colour when the month or rank changes. Use names, legends and figures for the precise amounts and meaning."),
            tr("现金流预测的曲线用主题色，可能余额不足的最低点用红色三角标出，并显示日期和金额；预算正常用主题色，进度过快用橙色，超支用红色并配斜纹和文字。",
               "Forecast curves use the theme colour; a negative low point is marked with a red triangle and its date and amount. Budgets use the theme colour normally, orange when spending is ahead of time, and red with hatching and text when over budget."),
            tr("概览和报表顶部的月份条可以左右滑动换月（向右是上个月），和点箭头一样。报表翻到别的月份时，标题旁出现「本月」，点它回到当前；概览翻到别的月份（按年时是别的年份）或在趋势图上点了某个月时，摘要卡右上角出现「回到本月」（按年时是「回到今年」或「回到全年」），点它回到当前。趋势图、月度收支图、净资产图和现金流预测图上点按选中一个月（预测图是一天），按住左右滑动依次查看。",
               "Swipe the month bar at the top of the overview and reports to change month (to the right goes back), as the arrows do. Away from the current month on reports, This Month beside the title brings you back; on the overview, away from the current month (or year) or with a month picked on the trend chart, Back to This Month (Back to This Year, Back to Year) at the top right of the summary card does. On the trend, monthly, net worth and forecast charts, tap a month (a day on the forecast) to pick it, or hold and slide sideways to go through them."),
            tr("报表、概览、账户页导航栏的币种按钮：上面选看哪些币种（可多选，长按只看一种），下面选原币、按成本、按市值或折算为某种货币，所有页面一起变。对账用原币加单个币种，看总数用折算。有几种货币时，账户页、资产负债表和损益表顶部改为每种货币一行的表格（资产 · 负债 · 净额，或收入 · 支出 · 结余），账户页的收支也按原币统计。",
               "The currency button on reports, the overview and accounts: pick which currencies to see (several, or press and hold for one) and how to value them: units, at cost, at market value or converted to one currency. Every page follows. Use units and one currency to reconcile, converted to see the total. With several currencies, the top of Accounts, the balance sheet and the income statement becomes a table with a row per currency (assets · debts · net, or income · spending · saved), and the Accounts income tab counts in each currency as booked."),
            tr("订阅：后来补交的差价左滑那笔扣费选「并入上一期（补差）」，计入累计已付但不算新的一期；服务商延长了期限，就在订阅详情右上角「⋯」→「调整到期日」。",
               "Subscriptions: swipe a later top-up and merge it into the previous period, so it counts as paid but not as a new period; when the provider extends the period, use ⋯ → Move due date at the top of the subscription."),
            tr("可以写 BQL 查询，常用的可保存；账本里的 query 指令也会列出来。查询结果用正文色保留原始正负号：负数可能是收入、贷方或数量，不直接代表亏损。",
               "BQL queries can be written and saved; query directives in the ledger are listed too. Results keep their original signs in the normal text colour: a negative number can be income, a credit or a quantity, and does not necessarily mean a loss."),
        ]),
        Topic(symbol: "hand.tap", title: tr("手势", "Gestures"), points: [
            tr("各页底部的操作提示（点按图表、点按扇区、左滑、长按）在你第一次用过这个手势后就不再显示；全部手势都列在这里。",
               "The hints under each page (tap a chart, tap a slice, swipe, press and hold) go away once you have used that gesture; all of them are listed here."),
            tr("图表：概览的趋势图、报表的月度收支图、净资产图和现金流预测图，点按选中一个月（预测图是一天），按住左右滑动依次查看。",
               "Charts: on the overview's trend chart and the reports' monthly, net worth and forecast charts, tap a month (a day on the forecast) to pick it, or hold and slide sideways to go through them."),
            tr("概览的支出构成和收付款方排行：点按扇区或一行展开，看其中的分类或交易。",
               "Spending by category and top payees on the overview: tap a slice or a row to open it up."),
            tr("列表里的一行左滑（或长按）出现它的操作：删除、隐藏、忽略、编辑连接等，各页不同。",
               "Swipe a row to the left (or press and hold it) for what can be done with it: delete, hide, ignore, edit the connection and so on, depending on the page."),
            tr("月份条左右滑动换月；导航栏币种面板里长按一种货币只看它，再长按恢复。",
               "Swipe the month bar to change the month; in the currency panel, press and hold a currency to see only that one, again to undo."),
        ]),
        Topic(symbol: "laptopcomputer", title: tr("在电脑上编辑", "Editing on a computer"), points: [
            tr("改之前先 git pull，改完 git push；回到 App 下拉刷新就能看到。",
               "git pull before editing and git push after; pull to refresh in the app to see it."),
            tr("App 认得的写法（元数据、标签、链接）见项目里的「账本写法参考」；照着写，App 和 Fava、bean-check 都能识别。",
               "The conventions the app reads (metadata, tags, links) are in the ledger-writing reference; written that way, the app, Fava and bean-check all understand them."),
            tr("App 支持 check_commodity、implicit_prices、noduplicates、leafonly 四个插件（main.bean 里声明了才执行），账本检查页把它们标为「App 支持」，其他插件标为「App 不支持」、不执行；include、option、plugin 只在电脑上改 main.bean。",
               "The app supports check_commodity, implicit_prices, noduplicates and leafonly (run when main.bean declares them); the ledger check marks them Supported by the app and other plugins Not supported, which aren't run. include, option and plugin are edited in main.bean on a computer."),
        ]),
        Topic(symbol: "lock", title: tr("隐私与备份", "Privacy and backups"), points: [
            tr("导航栏的眼睛按钮隐藏所有金额；设置里可以开启面容 ID / 触控 ID 锁定。识别失败或点取消后停在锁定页，可以再试，或点「使用设备密码解锁」输入 iPhone 密码。开启锁定后，快捷指令和 Siri 只在 iPhone 已解锁时运行：「本月支出」「待付款项」不读出金额，「快速记一笔」存为草稿并发通知，请你在 App 里确认后保存。",
               "The eye button hides every amount; Face ID / Touch ID lock is in Settings. If recognition fails or you cancel, the lock screen stays: try again, or tap Unlock with Passcode and enter the iPhone passcode. With the lock on, Shortcuts and Siri run only on an unlocked iPhone: Spent This Month and Upcoming Payments don't read amounts out, and Quick Entry keeps the entry as a draft and sends a notification to confirm it in the app."),
            tr("访问令牌存在钥匙串里，只留在这台手机，不会写进账本或仓库，也不随手机备份带到新设备。",
               "The access token lives in the Keychain on this phone only: never in the ledger or the repository, and not carried to a new device by a backup."),
            tr("设置 → 备份与导出：自动备份到 iCloud Drive 的文件夹，也可以导出 zip 或 CSV。",
               "Settings → Backup & export backs up to a folder in iCloud Drive and exports zip or CSV."),
        ]),
    ] }

    static var faq: [QA] { [
        QA(q: tr("保存后显示「待同步」是什么意思？", "What does “waiting to sync” mean after saving?"),
           a: tr("改动已经记在本机，正在或等待提交到仓库。联网后会自动提交；一直没提交的，到设置 →「同步与最近改动」，点底部的「重新同步」。",
                 "The change is on this phone and is being or will be committed. It goes out once online; if it stays, open Settings → Sync and recent changes and tap Sync now at the bottom.")),
        QA(q: tr("「账本同步」页出现「读不出来的记录」怎么办？", "The Sync page lists records that couldn't be read."),
           a: tr("手机上保存的待同步改动、上次推送的记录或附件记录读不出来时，App 不会用空记录覆盖它，而是另存一份，列在 设置 →「同步与最近改动」里。点「分享原文件」可以发到电脑上查看里面的内容，确认不需要后点「放弃」删除。「上次推送的记录」在这里时同步会暂停，放弃后继续同步，之后请核对账本有没有重复的交易。",
                 "When the changes waiting to sync, the note of the last push, or an attachment record on this phone can't be read, the app doesn't write an empty one over it; it sets it aside under Settings → Sync and recent changes. Tap Share Original File to look at it on a computer, and Discard once you no longer need it. While the note of the last push is here, syncing is paused; after discarding it, syncing resumes, so check the ledger for a duplicated entry.")),
        QA(q: tr("提交前检查拦下来了怎么办？", "The pre-save check stopped my entry. Now what?"),
           a: tr("看提示里的原因：可以返回修改；确定没问题就「仍然提交」；暂时不确定可「暂存本机」，之后在 设置 →「同步与最近改动」→「待同步」里左滑「推送」或「移除」。提示「不平衡」时，各分录合计要恰好为 0：误差和 bean-check 一样只按写了小数的金额放宽（两位小数允许 0.005），写整数金额就必须完全相等。账户在开户日之前、关户日之后，或用了开户时没允许的币种，bean-check 一定会拒绝，这种情况不能「仍然提交」，只能返回修改或暂存。",
                 "Read the reason: go back and fix it, submit anyway if you're sure, or keep it on this phone and later push or remove it under Settings → Sync and recent changes → Pending. For “unbalanced”, the postings must add up to 0: as in bean-check, only amounts written with decimals allow a margin (0.005 for two decimals), and whole numbers must match exactly. An account used before it opened, after it closed or in a currency its open line doesn't allow is always rejected by bean-check, so that can't be submitted anyway: go back or keep it on this phone.")),
        QA(q: tr("余额断言不符怎么办？", "A balance assertion fails."),
           a: tr("说明账本和银行对不上：在这个账户的明细里找漏记或记错的交易。确认银行余额后，可以用「余额核对」重新核对。",
                 "The ledger and the bank disagree: look in the account for a missing or wrong entry, then check the balance again.")),
        QA(q: tr("在电脑上改了账本，App 里没变化？", "I edited the ledger on my computer and the app doesn't show it."),
           a: tr("确认已经 git push，然后在 App 里下拉刷新；离开 App 超过一分钟再回来时，它也会自动拉取。",
                 "Make sure it's pushed, then pull to refresh; the app also fetches when you come back to it after a minute or more.")),
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
        QA(q: tr("试算平衡表里有「折算差额」，是账错了吗？", "The trial balance shows a conversion difference. Is something wrong?"),
           a: tr("不是。外币和证券按今天的价格折算，和记账时的汇率不同，就会出现这个差额。用币种按钮选「原币」就没有这个差额：每种货币各自平衡，换汇的差额列在「货币兑换」。",
                 "No. Foreign currencies and securities are converted at today's prices, which differ from those when they were recorded. Show units and it's gone: each currency balances by itself, with exchanges under Conversions.")),
        QA(q: tr("「货币兑换」是什么？", "What is Conversions?"),
           a: tr("用人民币换美元、刷人民币卡付外币消费、用美元买股票时，一种货币减少、另一种增加，单看每种货币都不平衡。这行把差额补上（Fava 里叫 Equity:Conversions），不是一个真实账户，也不用记账。",
                 "Exchanging CNY for USD, paying for something in USD with a CNY card or buying shares with USD takes from one currency and adds to another, so neither balances alone. This line makes up the difference (Equity:Conversions in Fava); it's not a real account and needs no entries.")),
        QA(q: tr("订阅付了一笔后又补了差价，怎么记？", "I paid a subscription and then paid the difference."),
           a: tr("补的那笔照常记：订阅详情底部的「记一笔扣费」（手动续费的订阅叫「记一笔续费」）可直接打开「本期补差」；已经记了的在订阅详情左滑选「并入上一期（补差）」。它带上 topup: TRUE，计入累计已付，显示为「122.00 + 补差 20.00」，不算新的一期，也不会提示调价。",
                 "Record it as usual: Record a Charge at the bottom of the subscription (Record the Renewal for one renewed by hand) opens with Top-up; or swipe an existing one in the subscription and merge it into the previous period. It gets topup: TRUE, counts as paid and shows as “122.00 + top-up 20.00”, but isn't a new period or a price change.")),
        QA(q: tr("订阅实际到期日和周期算出来的不一样？", "The subscription really ends on another day than the cycle says."),
           a: tr("订阅详情右上角「⋯」→「调整到期日」，填实际的下次扣费日。会新增一条带 next: 的记录，之后按原周期从那天继续算；在历史里左滑可撤销。",
                 "On the subscription, ⋯ at the top → Move due date, and enter the real next charge. It adds a record with next:, and the cycle continues from that day; swipe it in History to undo.")),
        QA(q: tr("删掉的附件怎么恢复？", "How do I get a deleted attachment back?"),
           a: tr("删除时选的是「移除并删除文件」：30 天内到账户页 →「交易附件」，最下面的「最近删除」里点那个文件的「恢复」，文件会先传回仓库，再恢复记录（对账单也在这里）。也可以在 设置 →「同步与最近改动」→「已同步记录」里左滑那条标着「可恢复文件」的删除 →「撤回」。选的是「只移除引用」：文件一直在仓库里，在已同步记录里撤回即可恢复记录。",
                 "If you chose Remove and Delete File: within 30 days go to Accounts → Transaction Attachments and tap Restore on the file under Recently Deleted at the bottom; the file goes back to the repository first, then the record (statements are listed there too). Or in Settings → Sync and recent changes → Synced changes, swipe the deletion marked File can be restored → Undo. If you chose Remove Record Only, the file never left the repository; undo it in Synced changes to bring the record back.")),
        QA(q: tr("附件打不开或一直在加载？", "An attachment won't open or keeps loading."),
           a: tr("附件每次打开都从仓库下载，网络慢时会等一会儿，失败会显示「无法下载」并可重试。JPG、PNG、HEIC、PDF 等常见格式都能预览，其他格式能保存但可能无法在 App 内预览，可用右上角分享到别的 App 打开。",
                 "An attachment is downloaded from the repository each time it opens, so a slow network takes a moment; a failure says it couldn't download, with Retry. JPG, PNG, HEIC, PDF and other common formats preview; other files may not, so share them to another app from the top corner.")),
        QA(q: tr("换手机后设置还在吗？", "Do my settings survive a new phone?"),
           a: tr("跟账本有关的都在仓库的 ledger-x.json 里，所有设备共用：主文件、文件规则、记账偏好（默认付款账户、币种）、统计范围、大额支出、已核对和已忽略的提示、常用交易置顶与隐藏、工资条模板、收付款方拼音；保存的查询在 queries/ 里。主题、语言、宫格图标、提醒、面容 ID 只存在这台手机。账本的访问令牌也只留在这台手机，换手机后要在账本管理里重新填一次。设置 → 仓库结构与共用设置可以一页看全。",
                 "Everything about the ledger is in ledger-x.json in the repository and shared by every device: main file, file rules, entry defaults, what's counted, the large-expense threshold, checked and ignored notices, pinned and hidden frequent entries, payslip templates and payee spellings; saved queries are in queries/. Theme, language, grid icons, reminders and Face ID stay on each phone. Access tokens stay on this phone too: enter them again in Ledgers on a new phone. Settings → Repository & shared settings shows it all.")),
    ] }
}
