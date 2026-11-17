import SwiftUI
import LedgerKit

/// 帮助 › Ledger X 使用指南: how the Mac app is used. The phone's guide (`Ledger/Views/GuideView.swift`) is about the
/// phone; this one says where things are on the Mac. The text lives here, both languages side by side: long prose,
/// read as a whole.
struct MacGuide: View {
    static let id = "guide"
    @State private var query = ""

    struct Topic: Identifiable {
        let title: String
        let points: [String]
        var id: String { title }
    }

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let topics = Self.topics.compactMap { topic -> Topic? in
            guard !q.isEmpty, !topic.title.localizedCaseInsensitiveContains(q) else { return topic }
            let points = topic.points.filter { $0.localizedCaseInsensitiveContains(q) }
            return points.isEmpty ? nil : Topic(title: topic.title, points: points)
        }
        NavigationStack {
            List {
                ForEach(topics) { topic in
                    Section(topic.title) {
                        ForEach(topic.points, id: \.self) { point in
                            Text(point).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
                if topics.isEmpty {
                    Text(LS("没有找到相关内容")).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: Text(LS("搜索指南和问题")))
        }
        .frame(minWidth: 480, minHeight: 400)
    }

    static var topics: [Topic] { [
        Topic(title: tr("打开账本", "Opening a ledger"), points: [
            tr("「文件 › 打开账本…」（⌘O）选择账本所在的文件夹（有 main.bean 的那个）；「文件 › 打开最近使用」列出最近打开过的几本，一点即开。「设置 › 账本」显示当前账本的位置，也可以在那里切换。",
               "File › Open Ledger… (⌘O) chooses the folder the ledger is in (the one with main.bean); File › Open Recent lists the last few opened, one click away. Settings › Ledger shows where the open ledger is and switches to another."),
            tr("账本是文件夹里的普通 Beancount 文本，App 不另存数据。文件在别处改过，页面会自动重新读取。",
               "The ledger is plain Beancount text in the folder; the app keeps no data of its own. When a file is changed elsewhere, the pages read it again by themselves."),
            tr("账本有错误时，窗口底部出现一条提示，点它打开「错误」页，可以直接打开出错的文件；缺少的币种声明可以「补上声明」。",
               "When the ledger has errors, a bar at the bottom of the window opens Errors, where each one opens its file; a missing currency declaration can be added with Declare."),
        ]),
        Topic(title: tr("记一笔", "Adding an entry"), points: [
            tr("侧栏上方工具栏的「记一笔」（铅笔图标）或 ⌘N 打开记一笔窗口，在哪个页面都一样；窗口右上角只放当前页面自己的操作。",
               "Add Entry at the top of the sidebar, or ⌘N, opens the Add window from any page; the top right of the main window holds only the open page's own actions."),
            tr("快捷卡片上选支出、收入或转账；分录、直接写文本、AA 和组合付款在「完整表单」里。",
               "The quick card records expenses, income and transfers; split entries, plain text, sharing and several accounts are on Full form."),
            tr("↩ 保存并关闭，⇧⌘↩ 保存后接着记下一笔；金额里有算式时，↩ 先算出结果。",
               "↩ saves and closes, ⇧⌘↩ saves and starts the next one; with a sum in the amount, ↩ works it out first."),
            tr("开启报销后，分类区显示报销应收账户，不必选择支出分类；填金额、付款账户、收付款方和摘要即可。",
               "With Reimburse on, the category area shows the receivable account: enter the amount, paying account, payee and note without choosing an expense category."),
            tr("没保存就关闭窗口时，可以继续编辑、保留草稿或放弃。",
               "Closing the window before saving lets you keep editing, keep a draft or discard it."),
        ]),
        Topic(title: tr("明细", "Journal"), points: [
            tr("点一笔，原文在它下面展开；↑ ↓ 换一笔，按住 ⌘ 或 ⇧ 点选多笔，Esc 或再点一次收起。点表头按那一列排序。",
               "Click an entry to show its text under it; ↑ ↓ move to the next one, ⌘- or ⇧-click picks several, and Esc or another click puts it away. Click a column header to sort by it."),
            tr("选中一笔后，↩ 编辑，⌫ 删除（会先确认），⌘C 复制所选交易的原文。",
               "With an entry picked, ↩ edits it, ⌫ deletes it after asking, and ⌘C copies the text of what's picked."),
            tr("右键一笔，或用菜单栏的「交易」：编辑、复制为新交易（⌘D）、登记退款（支出才有）、调整当天顺序（同一天同一文件有几笔时才有）、加入订阅、复制原文、打开所在文件和删除。复制为新交易和登记退款打开预填好的记一笔窗口，调整顺序时拖动后保存。",
               "Right-click an entry, or use Transactions in the menu bar, to edit it, Duplicate as New (⌘D), Record Refund (for spending), Reorder This Day (when the day has several in one file), Add to Subscriptions, copy its text, open its file or delete it. Duplicate and Refund open the Add window filled in; to reorder, drag and save."),
            tr("原文下的「修改原文」直接改 Beancount 文本，⌘↩ 保存，Esc 取消；「更多」里还能添加附件。",
               "Edit Source under the text changes the Beancount text itself: ⌘↩ saves, Esc cancels. More also adds attachments."),
        ]),
        Topic(title: tr("搜索与时间", "Search and time"), points: [
            tr("⌘F 搜索标签、收付款方或文字，写法和手机的明细搜索一样。明细列出找到的交易，报表、收付款方和年度回顾只算这些；点一笔里的标签也会把它加进搜索。",
               "⌘F searches tags, payees or text, written as in the phone's journal search. The journal lists what it finds, and Reports, Payee and Year in Review count only that; clicking a tag in an entry adds it to the search."),
            tr("工具栏的书签按钮列出快速搜索，和手机明细里保存的是同一批：点一个就搜它，再点一次清除；「保存当前搜索…」把搜索框里的条件存成一个，「管理快速搜索…」可编辑、上移、下移或删除。",
               "The bookmark button in the toolbar lists the quick searches, the same ones saved in the phone's journal: pick one to search for it, pick it again to clear. Save Current Search… keeps what's in the search box; Manage Quick Searches… edits, moves or deletes them."),
            tr("工具栏左边的箭头切换上一期、下一期；点中间的时间可以按月、季度、年、近 30 天或全部时间看，也可以选某一天、某一段，或回到本期。明细和报表旁边还能只看一个账户。",
               "The arrows at the left of the toolbar step to the period before or after; click the period between them to view by month, quarter, year, the last 30 days or all time, pick a day or a span, or come back to now. The journal and reports can also keep to one account."),
        ]),
        Topic(title: tr("账户、预算、订阅与报销", "Accounts, budgets, subscriptions and reimbursements"), points: [
            tr("账户页右上角「管理账户」可搜索全部账户、新建账户或修改开户信息，关闭和重新开启账户。修改开户信息会保留其他元数据；关闭保留历史，重新开启会移除 close 指令。「核对余额…」把账面余额和你看到的实际余额对一下。",
               "Manage Accounts at the top right of Accounts searches every account, creates one, edits its opening details, closes or reopens it. Editing keeps other metadata; closing keeps history, and reopening removes the close directive. Check Balance… compares the book balance with the one you see."),
            tr("预算页右上角「管理预算」可添加预算，或从当前预算的「⋯」编辑、停用；调整默认从本月起生效，之前的记录保留。覆盖其他同日记录前会确认。「历史记录」可删除某条记录，删除后更早的预算可能重新生效。",
               "Manage Budgets at the top right of Budgets adds one, or a current budget's ⋯ menu edits or stops it. Changes start this month by default and keep earlier records. Overwriting another record on the same day asks first. History deletes a record; an earlier budget may then take effect again."),
            tr("订阅页右上角「添加订阅」，每个订阅的「⋯」或右键里可记一笔扣费、调价或更改、调整到期日、跳过下一期、暂停、取消、恢复、修正记录和删除；待记账旁有「记一笔」，可能的订阅旁有「加入…」。明细右键订阅的扣费可「并入上一期（补差）」或「改为单独一期」。",
               "Add Subscription is at the top right of Subscriptions; each one's ⋯ or right-click records a charge, changes the price or plan, moves the due date, skips the next charge, pauses, cancels, resumes, corrects or deletes it. Due charges have Record, possible subscriptions have Add…. In the journal, right-click a subscription's charge to count it as a top-up of the period before or a period of its own."),
            tr("报销页「待报销」旁点「登记回款…」，勾选这次回款的垫付（多币种时先选币种）后保存；进行中的报销单右键可登记回款或导出报销单，导出时选择保存位置，PDF、xlsx 和 CSV 放在一起。明细右键一笔垫付可改「支出类型与凭证」或移出报销单。",
               "Click Record payment… beside Waiting on Reimbursements, tick the advances paid back (pick the currency first when there are several) and save. Right-click an open claim to record its repayment or export it; choose where to save, and the PDF, xlsx and CSV go together. In the journal, right-click an advance to set its expense type and receipt, or take it off its claim."),
        ]),
        Topic(title: tr("个人往来", "People"), points: [
            tr("侧栏「往来 › 个人往来」按人列出借出、代付、AA 和借款：左边是每个人还欠多少（他欠我或我欠他），右边是这个人的余额和全部记录。",
               "Dealings › People lists lending, paying for others, sharing and borrowing by person: the left shows what each one owes or is owed, the right their balance and every entry with them."),
            tr("右上角「登记往来…」记借出、收回、借入或还钱；从某个人打开时已选好对方和币种，金额不填就按现在欠的全额记。第一次向某人借钱要填借款账户名（拼音，如 WangWu）。保存可用 ⌘Z 撤销。",
               "Record with Someone… at the top right records lending, collecting, borrowing or repaying; opened on a person, it has them and the currency set, and an empty amount is the whole outstanding sum. Borrowing from someone the first time needs a loan account name (such as WangWu). ⌘Z undoes it."),
        ]),
        Topic(title: tr("附件与对账单", "Attachments and statements"), points: [
            tr("「附件与对账单」页按账户列出。把文件拖到左边的某个账户上，或选中账户后点「添加对账单…」，就作为它的对账单保存；交易的附件在原文下的「更多 › 添加附件…」。",
               "Attachments & Statements lists them by account. Drop a file on an account at the left, or pick the account and click Add Statement…, to keep it as that account's statement; an entry's attachments are added from More › Add Attachment… under its text."),
            tr("右键删除时可以「只移除引用」，把文件留在账本文件夹里，或「移除并删除文件」，把文件移到废纸篓；其他记录还在用的文件不会删除。",
               "Deleting one asks whether to Remove Record Only, leaving the file in the ledger folder, or Remove and Delete File, which moves it to the Trash; a file other records still use isn't deleted."),
        ]),
        Topic(title: tr("同步与撤销", "Sync and undo"), points: [
            tr("账本文件夹是 git 仓库时，侧栏会出现「同步与改动」：查看本机改动和差异，写好提交说明后「提交并推送」，右上角「拉取」取回别处的改动。",
               "When the ledger folder is a git repository, Sync and Changes appears in the sidebar: see this Mac's changes and their differences, write a message and Commit and Push, or Pull at the top right to bring in changes made elsewhere."),
            tr("「编辑 › 撤销」（⌘Z）撤回刚才的保存，可连续撤多步，「重做」（⇧⌘Z）再写回；文件之后被别处改过就不撤回。退出 App 或打开别的账本后不能再撤销。",
               "Edit › Undo (⌘Z) takes back the last save, several in a row, and Redo (⇧⌘Z) writes it again; a file changed elsewhere since isn't touched. Undo ends when the app quits or another ledger is opened."),
        ]),
        Topic(title: tr("显示与设置", "View and settings"), points: [
            tr("⌘1 到 ⌘9 打开侧栏的前九页，「显示」菜单列出全部页面；⇧⌘H 隐藏所有金额。",
               "⌘1 to ⌘9 open the first nine pages in the sidebar, and the View menu lists them all; ⇧⌘H hides every amount."),
            tr("「设置」（⌘,）里选默认打开的页面、语言和外观。语言默认跟随系统，也可以选简体中文或 English；菜单栏里系统自带的菜单在下次打开 App 时换过来。",
               "Settings (⌘,) chooses the page to open with, the language and the appearance. The language follows the system unless you choose Simplified Chinese or English; the system's own menus switch the next time the app opens."),
            tr("BQL 查询页左边列出内置的、账本里的（query 指令和 .bql 文件）和最近运行的查询；⌘↩ 运行，结果可以复制或导出 CSV。",
               "BQL Query lists the built-in queries, the ledger's own (query directives and .bql files) and the ones run lately; ⌘↩ runs one, and the result can be copied or exported as CSV."),
        ]),
    ] }
}
