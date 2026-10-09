import { parseFile, loadLedger, toCNY, fmtNum, formatTxn, insertEntry, weight, checkText, numText, alignText } from './ledger.js';

// =====================================================================
// storage
// =====================================================================
// one-time move of settings saved under the old 'zb.' prefix (token, pending queue…)
try {
  const old = []; for (let i = 0; i < localStorage.length; i++) old.push(localStorage.key(i));
  for (const k of old) {
    if (k && k.startsWith('zb.')) { const n = 'ledger.' + k.slice(3); if (localStorage.getItem(n) == null) localStorage.setItem(n, localStorage.getItem(k)); localStorage.removeItem(k); }
  }
} catch {}
try { indexedDB.deleteDatabase('zhangbu'); } catch {}

const LS = {
  get(k, d) { try { const v = localStorage.getItem('ledger.' + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('ledger.' + k, JSON.stringify(v)); } catch {} },
  del(k) { try { localStorage.removeItem('ledger.' + k); } catch {} },
};

const idb = (() => {
  let dbp;
  const open = () => (dbp ||= new Promise((res, rej) => {
    const r = indexedDB.open('ledger', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('blobs');
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  }));
  const tx = async (mode, fn) => {
    const db = await open();
    return new Promise((res, rej) => {
      const t = db.transaction('blobs', mode);
      const req = fn(t.objectStore('blobs'));
      t.oncomplete = () => res(req && req.result);
      t.onerror = () => rej(t.error);
    });
  };
  return {
    get: (k) => tx('readonly', (s) => s.get(k)).catch(() => undefined),
    set: (k, v) => tx('readwrite', (s) => s.put(v, k)).catch(() => {}),
    clear: () => tx('readwrite', (s) => s.clear()).catch(() => {}),
  };
})();

// =====================================================================
// GitHub
// =====================================================================
const cfg = () => LS.get('cfg', null);

async function gh(path, opts = {}) {
  const c = cfg();
  const res = await fetch('https://api.github.com' + path, {
    ...opts,
    cache: 'no-store',
    headers: {
      Authorization: 'Bearer ' + c.token,
      'X-GitHub-Api-Version': '2022-11-28',
      Accept: opts.raw ? 'application/vnd.github.raw+json' : 'application/vnd.github+json',
      ...(opts.body ? { 'Content-Type': 'application/json' } : {}),
    },
  });
  if (!res.ok) {
    let msg = res.status + '';
    try { msg += ' ' + (await res.json()).message; } catch {}
    const err = new Error(msg); err.status = res.status; throw err;
  }
  return opts.raw ? res.text() : res.json();
}

const repoPath = () => { const c = cfg(); return `/repos/${c.owner}/${c.repo}`; };
const encPath = (p) => p.split('/').map(encodeURIComponent).join('/');

async function fetchTree() {
  const c = cfg();
  const t = await gh(`${repoPath()}/git/trees/${encodeURIComponent(c.branch)}?recursive=1`);
  let commit = null;
  try { commit = (await gh(`${repoPath()}/commits/${encodeURIComponent(c.branch)}`)).sha; } catch {}
  const tree = {};
  for (const n of t.tree) if (n.type === 'blob') tree[n.path] = n.sha;
  return { sha: t.sha, tree, commit };
}

async function blobText(sha) {
  const hit = await idb.get('blob:' + sha);
  if (hit != null) return hit;
  const text = await gh(`${repoPath()}/git/blobs/${sha}`, { raw: true });
  await idb.set('blob:' + sha, text);
  return text;
}

function b64(str) {
  const bytes = new TextEncoder().encode(str);
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

async function putFile(path, text, sha, message) {
  const c = cfg();
  const body = { message, content: b64(text), branch: c.branch };
  if (sha) body.sha = sha;
  const r = await gh(`${repoPath()}/contents/${encPath(path)}`, { method: 'PUT', body: JSON.stringify(body) });
  await idb.set('blob:' + r.content.sha, text);
  return r.content.sha;
}

async function deleteFile(path, sha, message) {
  const c = cfg();
  await gh(`${repoPath()}/contents/${encPath(path)}`, { method: 'DELETE', body: JSON.stringify({ message, sha, branch: c.branch }) });
}

// latest run of the bean-check workflow (needs "Actions: Read-only" on the token)
async function loadCI() {
  try {
    const c = cfg();
    const r = await gh(`${repoPath()}/actions/workflows/bean-check.yml/runs?branch=${encodeURIComponent(c.branch)}&per_page=1`);
    const run = r.workflow_runs?.[0];
    S.ci = !run ? { state: 'none' } : { state: run.status !== 'completed' ? 'running' : run.conclusion === 'success' ? 'ok' : 'fail', url: run.html_url, sha: run.head_sha, at: run.updated_at };
  } catch (e) {
    S.ci = { state: e.status === 404 ? 'none' : e.status === 403 ? 'noperm' : 'error', msg: e.message };
  }
  LS.set('ci', S.ci);
}

function ciHTML() {
  const ci = S.ci;
  if (!ci) return '<span class="muted">bean-check：读取中…</span>';
  const when = ci.at ? new Date(ci.at).toLocaleString('zh-CN', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : '';
  const head = S.tree?.commit && ci.sha && ci.sha !== S.tree.commit ? '（还没检查到最新提交）' : '';
  switch (ci.state) {
    case 'ok': return `<span class="pos">✓ 官方 bean-check 通过</span> <span class="muted">${when}${head}</span>`;
    case 'fail': return `<span class="bad">✗ 官方 bean-check 未通过</span> <span class="muted">${when} · 点开看错误</span>`;
    case 'running': return '<span class="muted">官方 bean-check 运行中…</span>';
    case 'none': return '<span class="muted">还没有 bean-check 记录（工作流推送后自动运行）</span>';
    case 'noperm': return '<span class="muted">看不到 bean-check 结果：Token 需要加「Actions: Read-only」权限</span>';
    default: return `<span class="muted">bean-check 状态读取失败</span>`;
  }
}

// =====================================================================
// state
// =====================================================================
const S = {
  L: null,
  tree: LS.get('tree', null), // {sha, tree}
  pending: LS.get('pending', []), // ops
  syncState: 'idle', // idle | syncing | error | offline
  syncError: '',
  lastSync: LS.get('lastSync', null),
  tab: LS.get('tab', 'add') === 'settings' ? 'add' : LS.get('tab', 'add'),
  prevTab: null,
  month: null,
  period: LS.get('period', 'month'),
  search: { q: '', account: null, month: null, limit: 120 },
  acctView: null,
  expanded: {},
  draft: null,
  showClosed: false,
  ci: LS.get('ci', null),
  inbox: [],
};

const savePending = () => LS.set('pending', S.pending);

// files in repo, with pending inserts applied (so the UI shows them immediately)
async function readWithPending(path) {
  const sha = S.tree?.tree[path];
  let text = sha ? await blobText(sha) : '';
  if (!sha && path === S.main) throw new Error('仓库里找不到 ' + path);
  text = applyOps(text, path, S.pending);
  return text;
}

function applyOps(text, path, ops, strict = false) {
  for (const op of ops) {
    if (op.path !== path || op.failed) continue;
    if (op.kind === 'insert') text = insertEntry(text, op.text, op.date);
    else if (op.kind === 'link') text = addLinkToHeader(text, op) ?? text;
    else if (op.kind === 'include') { if (!text.includes(op.line)) text = addInclude(text, op.line); }
    else if (op.kind === 'remove') {
      const r = removeBlock(text, op.old);
      if (r != null) text = r;
      else if (strict) { const e = new Error(`要修改的交易在 GitHub 上已经变了：${op.label}。请在设置里删除这一项后重新编辑。`); e.status = 'conflict'; throw e; }
    } else if (op.kind === 'balance') text = insertBalance(text, op);
  }
  return text;
}

function removeBlock(text, old) {
  const lines = text.split('\n');
  const ol = old.split('\n').map((l) => l.trimEnd());
  for (let i = 0; i + ol.length <= lines.length; i++) {
    let ok = true;
    for (let k = 0; k < ol.length; k++) if (lines[i + k].trimEnd() !== ol[k]) { ok = false; break; }
    if (!ok) continue;
    let n = ol.length;
    if (lines[i + n] !== undefined && lines[i + n].trim() === '') n++;
    else if (i > 0 && lines[i - 1].trim() === '') { i--; n++; }
    lines.splice(i, n);
    return lines.join('\n');
  }
  return null;
}

function balanceLine(date, account, amount, currency) {
  const left = `${date} balance ${account}`;
  const ns = Number(amount).toFixed(2);
  return left + ' '.repeat(Math.max(1, 59 - left.length - ns.length)) + ns + ' ' + currency;
}

function insertBalance(text, op) {
  const lines = text.replace(/\s+$/, '').split('\n');
  if (op.replace) {
    const acc = op.account.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const same = new RegExp(`^${op.date}\\s+balance\\s+${acc}\\s[^;]*?\\s${op.currency}(\\s|;|$)`);
    const i = lines.findIndex((l) => same.test(l));
    if (i >= 0) { lines[i] = op.line; return lines.join('\n') + '\n'; }
  }
  const re = new RegExp('^\\d{4}-\\d{2}-\\d{2}\\s+balance\\s+' + op.account.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s');
  let last = -1;
  lines.forEach((l, i) => { if (re.test(l) && l.slice(0, 10) <= op.date) last = i; });
  if (last < 0) lines.forEach((l, i) => { if (re.test(l)) last = i; });
  if (last >= 0) lines.splice(last + 1, 0, op.line);
  else lines.push('', op.line);
  return lines.join('\n') + '\n';
}

function addLinkToHeader(text, op) {
  const lines = text.split('\n');
  let idx = lines[op.line - 1] === op.header ? op.line - 1 : lines.indexOf(op.header);
  if (idx < 0) return null;
  const add = op.add ?? ' ^' + op.link;
  if (lines[idx].includes(add.trim().split(' ').pop())) return text;
  lines[idx] = lines[idx].replace(/\s+$/, '') + add;
  return lines.join('\n');
}

function addInclude(text, line) {
  const lines = text.split('\n');
  let last = -1;
  lines.forEach((l, i) => { if (/^include\s+"journals\//.test(l)) last = i; });
  if (last < 0) return text.replace(/\s*$/, '\n') + line + '\n';
  lines.splice(last + 1, 0, line);
  return lines.join('\n');
}

S.main = 'main.bean';

async function rebuild() {
  const L = await loadLedger(readWithPending, S.main);
  derive(L);
  S.L = L;
}

// =====================================================================
// derived data
// =====================================================================
const ZH = {
  Food: '餐饮', Housing: '居住', Travel: '旅行', Transit: '交通', Shopping: '购物', Subscription: '订阅', Gifts: '人情',
  Lifestyle: '生活', Government: '政府', Healthcare: '医疗', Fee: '费用', Charity: '捐赠', Miscellaneous: '杂项',
  Salary: '工资', Freelance: '副业', Invest: '投资', Rewards: '返利', Sale: '变卖', ReimbExcess: '报销盈余',
  Bank: '银行', EWallet: '电子钱包', Cash: '现金', Brokerage: '券商', Crypto: '加密', Receivable: '应收', CreditCard: '信用卡', Loan: '借款',
  Assets: '资产', Liabilities: '负债', Income: '收入', Expenses: '支出', Equity: '权益',
};
const SYM = { CNY: '¥', HKD: 'HK$', USD: '$', EUR: '€', GBP: '£', SGD: 'S$', MOP: 'MOP$' };
const money = (n, c = 'CNY', d = 2) => (n < -1e-9 ? '-' : '') + (SYM[c] ?? '') + fmtNum(Math.abs(n), d) + (SYM[c] ? '' : ' ' + c);
const signed = (n, c) => (n > 1e-9 ? '+' : '') + money(n, c);
const leaf = (a) => a.split(':').slice(-1)[0];
const catOf = (a) => a.split(':').slice(0, 2).join(':');
const catLabel = (a) => { const p = a.split(':'); return p.length > 1 ? (ZH[p[1]] ?? p[1]) : a; };
const acctLabel = (a) => { const p = a.split(':'); if (p[0] === 'Expenses' || p[0] === 'Income') return (ZH[p[1]] ?? p[1]) + (p[2] ? ' / ' + p.slice(2).join(':') : ''); return p.slice(1).join(':'); };
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const today = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
const ym = (d) => d.slice(0, 7);
const shiftDay = (d, k) => { const t = new Date(d + 'T12:00:00'); t.setDate(t.getDate() + k); return `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, '0')}-${String(t.getDate()).padStart(2, '0')}`; };
const WEEK = '日一二三四五六';
const dayLabel = (d) => { const dt = new Date(d + 'T00:00:00'); return `${+d.slice(5, 7)}月${+d.slice(8)}日 周${WEEK[dt.getDay()]}`; };
const monthLabel = (m) => `${m.slice(0, 4)}年${+m.slice(5)}月`;
const addMonth = (m, k) => { let y = +m.slice(0, 4), mo = +m.slice(5) - 1 + k; y += Math.floor(mo / 12); mo = ((mo % 12) + 12) % 12; return `${y}-${String(mo + 1).padStart(2, '0')}`; };

function classify(t) {
  let exp = 0, inc = 0, hasExp = false, hasInc = false;
  for (const p of t.postings) {
    if (p.units == null || !p.currency) continue;
    const v = toCNY(t._L ?? S.L, p.units, p.currency, t.date) ?? 0;
    if (p.account.startsWith('Expenses:')) { exp += v; hasExp = true; }
    else if (p.account.startsWith('Income:')) { inc -= v; hasInc = true; }
  }
  if (hasExp) return { kind: exp < 0 ? 'refund' : 'expense', amount: -exp };
  if (hasInc) return { kind: 'income', amount: inc };
  const pos = t.postings.find((p) => p.units > 0);
  return { kind: 'transfer', amount: pos ? pos.units : 0, currency: pos?.currency };
}

function derive(L) {
  L._tpl = null; L._nw = null;
  const now = today();
  const recent = addMonth(ym(now), -6);
  const d60 = new Date(Date.now() - 60 * 864e5).toISOString().slice(0, 10);
  const acctUse = {}; const acctCcy = {}; const payees = new Map(); const short = {};
  const monthExp = {}; const monthInc = {}; const monthCat = {};
  for (const t of L.txns) {
    t._L = L;
    const w = t.date >= d60 ? 20 : t.date >= recent ? 4 : 1;
    for (const p of t.postings) {
      if (p.units == null || !p.currency) continue;
      acctUse[p.account] = (acctUse[p.account] || 0) + w;
      (acctCcy[p.account] ||= {}); acctCcy[p.account][p.currency] = (acctCcy[p.account][p.currency] || 0) + w;
      const m = ym(t.date);
      if (p.account.startsWith('Expenses:')) {
        const v = toCNY(L, p.units, p.currency, t.date) ?? 0;
        monthExp[m] = (monthExp[m] || 0) + v;
        (monthCat[m] ||= {}); monthCat[m][p.account] = (monthCat[m][p.account] || 0) + v;
      } else if (p.account.startsWith('Income:')) {
        monthInc[m] = (monthInc[m] || 0) - (toCNY(L, p.units, p.currency, t.date) ?? 0);
      }
    }
    if (t.payee) {
      const s = payees.get(t.payee) || { name: t.payee, n: 0, w: 0, last: null, narr: new Map() };
      s.n++; s.w += w; s.last = t;
      if (t.narration) s.narr.set(t.narration, (s.narr.get(t.narration) || 0) + 1);
      payees.set(t.payee, s);
    }
    if (t.tags.includes('transfer')) {
      const m = /^(.+?)\s*->\s*(.+)$/.exec(t.narration);
      const from = t.postings.find((p) => p.units < 0), to = t.postings.find((p) => p.units > 0);
      if (m && from && to) { (short[from.account] ||= {}); short[from.account][m[1]] = (short[from.account][m[1]] || 0) + 1; (short[to.account] ||= {}); short[to.account][m[2]] = (short[to.account][m[2]] || 0) + 1; }
    }
  }
  const top = (o) => Object.entries(o || {}).sort((a, b) => b[1] - a[1])[0]?.[0];
  L.acctUse = acctUse;
  L.acctCcy = Object.fromEntries(Object.keys(acctCcy).map((a) => [a, top(acctCcy[a])]));
  L.short = Object.fromEntries(Object.keys(short).map((a) => [a, top(short[a])]));
  L.payees = [...payees.values()].sort((a, b) => b.w - a.w);
  L.monthExp = monthExp; L.monthInc = monthInc; L.monthCat = monthCat;
  L.openAccounts = Object.values(L.accounts).filter((a) => !a.close || a.close > now).map((a) => a.name);
  L.currencies = [...new Set(['CNY', ...Object.keys(L.rates)])].filter((c) => /^[A-Z]{3,4}$/.test(c) && !L.commodities[c]?.['asset-class']?.includes('equity'));
  // open reimbursement / refund links
  const linkSum = {}, linkN = {}, linkC = {};
  for (const t of L.txns) for (const l of t.links) {
    for (const p of t.postings) if (p.account.startsWith('Assets:Receivable')) { linkSum[l] = (linkSum[l] || 0) + p.units; linkC[l] = p.currency; if (p.units > 0) linkN[l] = (linkN[l] || 0) + 1; }
  }
  L.openLinks = Object.entries(linkSum).filter(([k, v]) => k.startsWith('reimburse') && Math.abs(v) > 0.005).map(([k, v]) => ({ link: k, amount: Math.round(v * 100) / 100, currency: linkC[k] || 'CNY', n: linkN[k] || 0 }));
  // receivable items not yet tied to a reimburse-* link (recorded at spend time, claimed later)
  const cutoff = shiftDay(now, -180);
  L.unclaimed = []; L.unclaimedOld = 0;
  for (const t of L.txns) {
    if (t.links.some((l) => l.startsWith('reimburse'))) continue;
    for (const p of t.postings) if (p.account === 'Assets:Receivable:Reimbursement') {
      if (t.date >= cutoff) L.unclaimed.push({ t, amount: p.units, currency: p.currency });
      else L.unclaimedOld += p.units;
    }
  }
  L.allLinks = [...new Set(L.txns.flatMap((t) => t.links))];
  L.byLink = {};
  for (const t of L.txns) for (const l of t.links) (L.byLink[l] ||= []).push(t);
}

const shortName = (a) => S.L.short[a] || (/^(Cash|Personal|Business|Stock|ETF)$/.test(leaf(a)) && a.split(':').length > 3 ? a.split(':')[2] : leaf(a));

function rankAccounts(prefixes, boost = []) {
  const L = S.L;
  return L.openAccounts.filter((a) => prefixes.some((p) => a.startsWith(p)))
    .sort((a, b) => (boost.indexOf(b) >= 0) - (boost.indexOf(a) >= 0) || (boost.indexOf(a) - boost.indexOf(b)) || (L.acctUse[b] || 0) - (L.acctUse[a] || 0));
}

// =====================================================================
// Apple Pay inbox: inbox/*.json files written by an iOS Shortcut
// =====================================================================
const CCY_SIGNS = [[/HK\$|HKD|港/i, 'HKD'], [/MOP|澳门/i, 'MOP'], [/S\$|SGD/i, 'SGD'], [/US\$|USD|\$/, 'USD'], [/£|GBP/, 'GBP'], [/€|EUR/, 'EUR'], [/JPY|円/, 'JPY'], [/CN¥|RMB|CNY|¥|￥|元/, 'CNY']];
function parseMoney(raw) {
  const s = String(raw ?? '').replace(/\s/g, '');
  const m = /-?[\d,]*\.?\d+/.exec(s.replace(/[−–]/g, '-'));
  const n = m ? Math.abs(Number(m[0].replace(/,/g, ''))) : NaN;
  let ccy = 'CNY';
  for (const [re, c] of CCY_SIGNS) if (re.test(s)) { ccy = c; break; }
  return { n, ccy };
}
const CARD_HINTS = [[/中国银行|中行|BOC(?!HK)/i, 'BOC'], [/中银香港|BOCHK/i, 'BOCHK'], [/汇丰|HSBC/i, 'HSBC'], [/广发|CGB/i, 'CGB'], [/浦发|SPDB/i, 'SPDB'], [/中信|CITIC/i, 'CITIC'],
  [/光大|CEB/i, 'CEB'], [/华夏|HXB/i, 'HXB'], [/招商|招行|CMB/i, 'CMB'], [/建设|建行|CCB/i, 'CCB'], [/众安|ZA/i, 'ZABank'], [/Wise/i, 'Wise'], [/N26/i, 'N26'], [/八达通|Octopus/i, 'Octopus'], [/iFAST/i, 'IFASTGB']];
function guessFunding(card) {
  const map = LS.get('cardMap', {});
  if (card && map[card] && S.L.accounts[map[card]]) return map[card];
  const credit = /信用|credit/i.test(card || '');
  for (const [re, key] of CARD_HINTS) if (re.test(card || '')) {
    const cands = S.L.openAccounts.filter((a) => a.split(':').includes(key) || a.endsWith(':' + key));
    const pick = cands.find((a) => credit ? a.startsWith('Liabilities:CreditCard') : a.startsWith('Assets:')) || cands[0];
    if (pick) return pick;
  }
  return null;
}
function guessPayee(merchant) {
  const map = LS.get('merchantMap', {});
  if (map[merchant]) return map[merchant];
  const L = S.L;
  const exact = L.payees.find((p) => p.name === merchant);
  if (exact) return exact.name;
  const part = L.payees.find((p) => p.name.length >= 2 && (merchant || '').includes(p.name));
  return part ? part.name : merchant || '';
}

async function loadInbox() {
  const paths = Object.keys(S.tree?.tree || {}).filter((p) => /^inbox\/[^/]+\.json$/.test(p)).sort();
  const gone = new Set(S.pending.filter((o) => o.kind === 'deleteFile').map((o) => o.path));
  const items = [];
  for (const path of paths) {
    if (gone.has(path)) continue;
    try {
      const j = JSON.parse(await blobText(S.tree.tree[path]));
      const { n, ccy } = parseMoney(j.amount);
      const date = /^\d{4}-\d{2}-\d{2}/.test(j.time || '') ? j.time.slice(0, 10) : path.match(/(\d{4})(\d{2})(\d{2})/)?.slice(1).join('-') || today();
      items.push({ path, merchant: String(j.merchant || '').trim(), card: String(j.card || '').trim(), amount: n, currency: j.currency || ccy, date, time: j.time || '', note: j.note || '', raw: j });
    } catch (e) { items.push({ path, bad: true, merchant: path, amount: NaN, currency: 'CNY', date: today(), card: '' }); }
  }
  S.inbox = items;
}

function draftFromInbox(it) {
  const d = newDraft('expense');
  d.date = it.date;
  d.amount = Number.isFinite(it.amount) ? String(it.amount) : '';
  d.currency = it.currency;
  d.inboxItem = it;
  S.draft = d;
  const payee = guessPayee(it.merchant);
  if (payee) setDraft('payee', payee, false); // fills category + funding from that payee's history
  d.currency = it.currency;
  if (Number.isFinite(it.amount)) d.amount = String(it.amount);
  const fund = guessFunding(it.card);
  if (fund) d.funding = fund;
  if (it.note && !d.narration) d.narration = it.note;
  d.edited = null;
  return d;
}

function nextInbox(after) {
  const list = S.inbox.filter((x) => !S.pending.some((o) => o.kind === 'deleteFile' && o.path === x.path));
  const i = after ? list.findIndex((x) => x.path === after) : -1;
  return list[i + 1] || null;
}

// open the app with ?amount=&payee=&card=… to prefill an entry (for Siri / Shortcuts / bookmarks)
function draftFromURL() {
  const q = new URLSearchParams(location.search);
  if (!q.has('amount') && !q.has('payee') && !q.has('merchant')) return false;
  const { n, ccy } = parseMoney(q.get('amount'));
  const it = { merchant: q.get('payee') || q.get('merchant') || '', card: q.get('card') || '', amount: n, currency: q.get('currency') || ccy, date: q.get('date') || today(), note: q.get('narration') || '' };
  const d = draftFromInbox(it);
  d.inboxItem = null;
  if (q.get('account') && S.L.accounts[q.get('account')]) d.account = q.get('account');
  if (q.get('funding') && S.L.accounts[q.get('funding')]) d.funding = q.get('funding');
  try { history.replaceState({ ledger: 0 }, '', location.pathname); } catch {}
  S.tab = 'add';
  return true;
}

// =====================================================================
// sync
// =====================================================================
async function refresh({ quiet = false } = {}) {
  if (!cfg()) return;
  try {
    S.syncState = 'syncing'; renderStatus();
    const t = await fetchTree();
    const changed = !S.tree || t.sha !== S.tree.sha;
    S.tree = t; LS.set('tree', t);
    if (S.pending.length) await pushPending();
    if (changed || !S.L) await rebuild();
    await Promise.all([loadInbox(), loadCI()]);
    S.syncState = 'idle'; S.syncError = '';
    S.lastSync = new Date().toISOString(); LS.set('lastSync', S.lastSync);
    if (changed || !quiet) render();
  } catch (e) {
    console.error(e);
    S.syncState = navigator.onLine === false || e instanceof TypeError ? 'offline' : 'error';
    S.syncError = e.message;
    if (!S.L && S.tree) { try { await rebuild(); } catch {} }
    render();
  }
  renderStatus();
}

let pushing = null;
async function pushPending() {
  if (pushing) return pushing;
  pushing = (async () => {
    // group ops by file, apply to fresh text, one commit per file
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const ops = [...S.pending];
        if (!ops.length) return;
        const paths = [...new Set(ops.map((o) => o.path))];
        for (const path of paths) {
          const sha = S.tree.tree[path];
          const dels = ops.filter((o) => o.path === path && o.kind === 'deleteFile');
          if (dels.length) {
            if (sha) await deleteFile(path, sha, dels[0].label || `收件箱：处理 ${path}`);
            delete S.tree.tree[path];
            S.pending = S.pending.filter((o) => !dels.includes(o));
            savePending();
            continue;
          }
          const base = sha ? await blobText(sha) : '';
          // an edit/delete whose original text is gone (changed elsewhere) is parked, not pushed
          for (const o of ops) if (o.path === path && o.kind === 'remove' && !o.failed && removeBlock(applyOps(base, path, ops.slice(0, ops.indexOf(o)).filter((x) => x.path === path)), o.old) == null) {
            o.failed = `原交易在 GitHub 上已经变了，这次${o.label?.startsWith('删除') ? '删除' : '修改'}没有提交`;
            const twin = ops[ops.indexOf(o) + 1];
            if (twin && twin.kind === 'insert' && twin.silent) twin.failed = o.failed; // the re-insert half of an edit
          }
          savePending();
          const fileOps = ops.filter((o) => o.path === path && !o.failed);
          if (!fileOps.length) continue;
          const text = applyOps(base, path, fileOps, true);
          const labels = fileOps.map((o) => o.silent ? '' : o.label || (o.kind === 'insert' ? `记账：${o.date} ${o.summary}` : o.kind === 'balance' ? `对账：${o.account}` : '')).filter(Boolean);
          const msg = labels.length === 1 ? labels[0] : labels.length ? `${labels[0]} 等 ${labels.length} 项` : `更新 ${path}`;
          const newSha = await putFile(path, text, sha, msg);
          S.tree.tree[path] = newSha;
          S.pending = S.pending.filter((o) => !fileOps.includes(o));
          savePending();
        }
        // tree sha changed after commits; refetch for a consistent base
        const t = await fetchTree(); S.tree = t; LS.set('tree', t);
        return;
      } catch (e) {
        if ((e.status === 409 || e.status === 422) && attempt === 0) { const t = await fetchTree(); S.tree = t; LS.set('tree', t); continue; }
        throw e;
      }
    }
  })();
  try { await pushing; } finally { pushing = null; }
  if (S.pending.some((o) => !o.failed)) {
    // ops queued while the previous push was running
    if (!pushPending.depth) { pushPending.depth = 1; try { await pushPending(); } finally { pushPending.depth = 0; } }
  }
}

async function syncNow() {
  try {
    S.syncState = 'syncing'; renderStatus();
    await pushPending();
    await rebuild();
    await loadInbox();
    S.syncState = 'idle'; S.syncError = '';
    S.lastSync = new Date().toISOString(); LS.set('lastSync', S.lastSync);
  } catch (e) {
    S.syncState = navigator.onLine === false || e instanceof TypeError ? 'offline' : 'error'; S.syncError = e.message;
  }
  renderStatus();
}

// =====================================================================
// rendering
// =====================================================================
const $ = (s, el = document) => el.querySelector(s);
let main = $('#main'); // reassigned briefly while drawing the page under a back-swipe

const ICON = {
  add: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>',
  overview: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M5 20V11M12 20V5M19 20v-6"/></svg>',
  journal: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M5 5h14M5 10h14M5 15h14M5 20h9"/></svg>',
  accounts: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><rect x="3" y="6" width="18" height="13" rx="2"/><path d="M3 10h18M16 15h2"/></svg>',
  settings: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9 7 7M17 17l2.1 2.1M4.9 19.1 7 17M17 7l2.1-2.1"/></svg>',
  back: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M15 5l-7 7 7 7"/></svg>',
  prev: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M15 6l-6 6 6 6"/></svg>',
  next: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M9 6l6 6-6 6"/></svg>',
  reports: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 19h16M5 15l4-5 4 3 6-7"/></svg>',
  eye: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>',
  eyeoff: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3l18 18M10.6 5.1A10.6 10.6 0 0 1 12 5c6.4 0 10 7 10 7a17 17 0 0 1-3.2 4.1M6.5 6.6C3.8 8.3 2 12 2 12s3.6 7 10 7c1.7 0 3.2-.5 4.5-1.2M9.9 9.9a3 3 0 0 0 4.2 4.2"/></svg>',
  sync: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M20 11a8 8 0 0 0-14.3-4.9L4 8M4 4v4h4M4 13a8 8 0 0 0 14.3 4.9L20 16M20 20v-4h-4"/></svg>',
};
const TABS = [['add', '记一笔'], ['overview', '概览'], ['journal', '流水'], ['accounts', '账户'], ['reports', '报表']];

function renderNav() {
  const btn = ([k, l]) => `<button data-tab="${k}" ${S.tab === k ? 'aria-current="page"' : ''}>${ICON[k]}<span>${l}</span></button>`;
  $('#tabbar').innerHTML = TABS.map(btn).join('');
  $('#rail').innerHTML = `<div class="brand"><img src="icon.svg" alt="">Ledger</div>${TABS.map(btn).join('')}<div class="spacer"></div>${btn(['settings', '设置'])}`;
}
document.addEventListener('click', (e) => {
  const t = e.target.closest('[data-tab]');
  if (!t) return;
  if (t.closest('#tabbar, #rail')) { navReset(); go(t.dataset.tab); }   // top-level tabs start a fresh stack
  else { if (t.dataset.tab !== S.tab) navPush(); go(t.dataset.tab); }  // links inside a page drill down
});

// =====================================================================
// navigation stack (browser history + iOS-style edge swipe)
// =====================================================================
const NAV = { stack: [], suppress: 0 };
const snapshot = () => ({ tab: S.tab, acctView: S.acctView, search: { ...S.search }, period: S.period, month: S.month, prevTab: S.prevTab, scroll: window.scrollY });
function applySnap(n) {
  if (S.draft?.mode === 'edit' && n.tab !== 'add') S.draft = null; // leaving the editor cancels the edit
  S.tab = n.tab; S.acctView = n.acctView; S.search = { ...n.search }; S.period = n.period; S.month = n.month; S.prevTab = n.prevTab;
}
function navPush() {
  NAV.stack.push(snapshot());
  try { history.pushState({ ledger: NAV.stack.length }, ''); } catch {}
}
function navReset() {
  if (!NAV.stack.length) return;
  const n = NAV.stack.length; NAV.stack = [];
  NAV.suppress++;
  try { history.go(-n); } catch { NAV.suppress--; }
}
const canGoBack = () => NAV.stack.length > 0;
function navBack() { if (!canGoBack()) return false; history.back(); return true; }
// pop without waiting for popstate (used after saving an edit)
function navPopNow() {
  const prev = NAV.stack.pop(); if (!prev) return false;
  NAV.suppress++; try { history.back(); } catch { NAV.suppress--; }
  applySnap(prev);
  return prev;
}
window.addEventListener('popstate', () => {
  if (NAV.suppress) { NAV.suppress--; return; }
  const open = document.querySelector('.modal-back');
  if (open) open.remove();
  const prev = NAV.stack.pop();
  if (!prev) return;
  applySnap(prev);
  closeCombo?.();
  render();
  window.scrollTo(0, prev.scroll || 0);
  if (!swipeDone) enterAnim();
  swipeDone = false;
});
try { history.replaceState({ ledger: 0 }, ''); } catch {}

const reduceMotion = () => window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
function enterAnim() {
  if (reduceMotion() || window.innerWidth >= 900) return;
  main.animate?.([{ transform: 'translateX(-22%)', opacity: 0.6 }, { transform: 'none', opacity: 1 }], { duration: 220, easing: 'cubic-bezier(.2,.8,.2,1)' });
}

// Edge swipe: only in the installed (standalone) app, where iOS gives no back gesture.
const STANDALONE = window.navigator.standalone === true || window.matchMedia?.('(display-mode: standalone)').matches || /[?&]swipe=1/.test(location.search);
let sw = null, swipeDone = false;
function drawUnder(prev) {
  let under = document.getElementById('under');
  if (!under) { under = document.createElement('main'); under.id = 'under'; under.setAttribute('aria-hidden', 'true'); document.querySelector('.app').prepend(under); }
  const cur = snapshot(), curDraft = S.draft, real = main;
  try {
    applySnap(prev); S.draft = curDraft;
    main = under; rendering = true; renderInner();
  } catch (e) { console.warn(e); } finally {
    rendering = false; main = real; applySnap(cur); S.draft = curDraft; renderNav();
  }
  under.querySelectorAll('[id]').forEach((el) => el.removeAttribute('id'));
  under.style.setProperty('--under-scroll', `${-(prev.scroll || 0)}px`);
  return under;
}
document.addEventListener('touchstart', (e) => {
  if (!STANDALONE || e.touches.length !== 1 || window.innerWidth >= 900) return;
  const t = e.touches[0];
  if (t.clientX > 22) return;
  const modalBack = document.querySelector('.modal-back');
  if (!modalBack && !canGoBack()) return;
  sw = { x: t.clientX, y: t.clientY, t: performance.now(), dx: 0, active: false, modal: modalBack };
}, { passive: true });
document.addEventListener('touchmove', (e) => {
  if (!sw) return;
  const t = e.touches[0];
  const dx = t.clientX - sw.x, dy = t.clientY - sw.y;
  if (!sw.active) {
    if (Math.abs(dy) > 12 && Math.abs(dy) > dx) { sw = null; return; }
    if (dx < 10) return;
    sw.active = true;
    closeCombo?.();
    document.activeElement?.blur?.();
    if (sw.modal) { sw.el = sw.modal.querySelector('.modal'); }
    else {
      sw.el = main;
      sw.under = drawUnder(NAV.stack[NAV.stack.length - 1]);
      document.body.classList.add('swiping');
    }
    sw.el.style.transition = 'none';
  }
  e.preventDefault();
  sw.dx = Math.max(0, dx);
  const w = window.innerWidth, f = Math.min(1, sw.dx / w);
  sw.el.style.transform = `translateX(${sw.dx}px)`;
  if (sw.under) { sw.under.style.transform = `translateX(${-30 * (1 - f)}%)`; sw.under.style.setProperty('--dim', String(0.12 * (1 - f))); }
  if (sw.modal) sw.modal.style.background = `rgba(10,15,12,${0.38 * (1 - f)})`;
}, { passive: false });
function endSwipe() {
  if (!sw) return;
  const s0 = sw; sw = null;
  if (!s0.active) return;
  const w = window.innerWidth;
  const v = s0.dx / Math.max(1, performance.now() - s0.t);
  const go = s0.dx > w * 0.33 || (v > 0.5 && s0.dx > 40);
  const ms = reduceMotion() ? 0 : 200;
  s0.el.style.transition = `transform ${ms}ms cubic-bezier(.2,.8,.2,1)`;
  if (s0.under) s0.under.style.transition = `transform ${ms}ms cubic-bezier(.2,.8,.2,1)`;
  if (go) {
    s0.el.style.transform = `translateX(${w}px)`;
    if (s0.under) s0.under.style.transform = 'translateX(0)';
    setTimeout(() => {
      if (s0.modal) { s0.modal.remove(); return; }
      swipeDone = true;
      s0.el.style.transition = 'none'; s0.el.style.transform = '';
      navBack();
      setTimeout(() => { s0.under?.remove(); document.body.classList.remove('swiping'); }, 30);
    }, ms);
  } else {
    s0.el.style.transform = '';
    if (s0.under) s0.under.style.transform = 'translateX(-30%)';
    if (s0.modal) s0.modal.style.background = '';
    setTimeout(() => { s0.el.style.transition = ''; s0.under?.remove(); document.body.classList.remove('swiping'); }, ms);
  }
}
document.addEventListener('touchend', endSwipe);
document.addEventListener('touchcancel', endSwipe);

function go(tab, opts = {}) {
  if (tab === 'settings' && S.tab !== 'settings') S.prevTab = S.tab;
  S.tab = tab;
  if (tab !== 'settings') LS.set('tab', tab);
  S.acctView = opts.acct ?? null;
  render();
  window.scrollTo(0, 0);
}

function statusHTML() {
  const n = S.pending.filter((o) => !o.failed).length;
  const cls = S.syncState === 'error' || S.syncState === 'offline' ? 'err' : n ? 'pending' : '';
  const txt = S.syncState === 'syncing' ? '同步中…' : S.syncState === 'offline' ? `离线${n ? `，${n} 项待同步` : ''}` : S.syncState === 'error' ? '同步失败' : n ? `${n} 项待同步` : '已同步';
  return `<span class="sync-dot ${cls}" title="${esc(S.syncError)}"><i></i>${txt}</span>`;
}
function renderStatus() { document.querySelectorAll('[data-status]').forEach((el) => (el.innerHTML = statusHTML())); }

function topbar(title, extra = '') {
  const priv = LS.get('privacy', false);
  return `<div class="topbar"><h1>${title}</h1>${extra}<span data-status>${statusHTML()}</span>
    <button class="iconbtn" data-act="privacy" aria-pressed="${priv}" aria-label="${priv ? '显示金额' : '隐藏金额'}" title="${priv ? '显示金额' : '隐藏金额'}">${priv ? ICON.eyeoff : ICON.eye}</button>
    <button class="iconbtn" data-act="sync" aria-label="同步">${ICON.sync}</button>
    <button class="iconbtn mobile-only" data-tab="settings" aria-label="设置">${ICON.settings}</button></div>`;
}

let rendering = false;
function render() {
  if (rendering) return;
  rendering = true;
  try { renderInner(); } finally { rendering = false; }
}
function renderInner() {
  renderNav();
  if (!cfg()) { S.tab = 'settings'; renderSettings(true); return; }
  if (!S.L) { main.innerHTML = `<div class="loading">${S.syncState === 'error' ? '无法加载账本：' + esc(S.syncError) + '<br><br><button class="btn" data-tab="settings">检查设置</button>' : '正在读取账本…'}</div>`; return; }
  ({ add: renderAdd, overview: renderOverview, journal: renderJournal, accounts: renderAccounts, reports: renderReports, settings: () => renderSettings(false) }[S.tab] || renderAdd)();
}

function toast(msg, action, fn, ms = 2600) {
  document.querySelectorAll('.toast').forEach((t) => t.remove());
  const el = document.createElement('div'); el.className = 'toast';
  el.append(document.createTextNode(msg));
  if (action) {
    const b = document.createElement('button'); b.className = 'toast-btn'; b.textContent = action;
    b.addEventListener('click', () => { el.remove(); fn(); });
    el.append(b);
  }
  document.body.appendChild(el);
  setTimeout(() => el.remove(), action ? Math.max(ms, 6000) : ms);
}

// ---------------------------------------------------------------------
// 记一笔
// ---------------------------------------------------------------------
function newDraft(kind = 'expense') {
  const L = S.L;
  const funding = LS.get('defaultFunding', null) || rankAccounts(['Assets:', 'Liabilities:CreditCard'])[0];
  return { kind, date: today(), payee: '', narration: '', amount: '', currency: L.acctCcy[funding] || 'CNY', account: '', funding, to: '', toAmount: '', paid: '', reimb: false, link: '', tags: [], edited: null, refundOf: null,
    flag: '*', tagsText: '', rows: [newRow(), newRow(funding)], raw: '' };
}
function newRow(account = '') { return { account, amount: '', currency: (account && S.L.acctCcy[account]) || 'CNY', cost: '', price: '', flag: '' }; }

function evalExpr(s) {
  s = String(s ?? '').trim().replace(/^(-?\d+),(\d{1,2})$/, '$1.$2').replace(/[，,\s]/g, '').replace(/[×xX]/g, '*').replace(/÷/g, '/').replace(/[−–]/g, '-');
  if (!s || !/^[\d.+\-*/()]+$/.test(s)) return NaN;
  try { const v = Function('"use strict";return (' + s + ')')(); return Number.isFinite(v) ? v : NaN; } catch { return NaN; }
}

function parseTagsLinks(s) {
  const tags = [], links = [];
  for (const w of String(s || '').split(/[\s,，]+/).filter(Boolean)) {
    if (w.startsWith('^')) links.push(w.slice(1)); else tags.push(w.replace(/^#/, ''));
  }
  return { tags: tags.filter(Boolean), links: links.filter(Boolean) };
}

function multiTx(d) {
  const tl = parseTagsLinks(d.tagsText);
  const postings = d.rows.filter((r) => r.account.trim()).map((r) => {
    const a = String(r.amount || '').trim();
    let units = null;
    if (a) units = /^[-+]?\d+,\d{1,2}$/.test(a) ? a.replace(',', '.').replace(/^\+/, '') : /^[-+]?\d[\d,]*(\.\d+)?$/.test(a) ? a.replace(/,/g, '').replace(/^\+/, '') : Number.isFinite(evalExpr(a)) ? numText(evalExpr(a)) : a;
    if (typeof units === 'string' && /^-?\d+(\.\d*)?$/.test(units)) {
      // pad to the currency's usual decimals (at most 2), as in "12.50 CNY"
      const prec = Math.min(2, Number(S.L.commodities[r.currency]?.precision ?? 2));
      const dec = (units.split('.')[1] || '').length;
      if (dec < prec) units = Number(units).toFixed(prec);
    }
    const price = r.price.trim() ? (/^@/.test(r.price.trim()) ? r.price.trim() : '@ ' + r.price.trim()) : null;
    return { account: r.account.trim(), units, currency: units != null ? r.currency : null, flag: r.flag || null, cost: r.cost.trim() || null, price };
  });
  if (!d.date || postings.length < 1) return null;
  return { date: d.date, flag: d.flag || '*', payee: d.payee.trim(), narration: d.narration.trim(), tags: tl.tags, links: tl.links, postings };
}

function evalAmount(s) {
  s = String(s ?? '').trim().replace(/^(-?\d+),(\d{1,2})$/, '$1.$2').replace(/[，,\s]/g, '').replace(/[×xX]/g, '*').replace(/÷/g, '/').replace(/[−–]/g, '-');
  if (!s) return NaN;
  if (/^\d*\.?\d+$/.test(s)) return Number(s);
  if (!/^[\d.+\-*/()]+$/.test(s)) return NaN;
  try { const v = Function('"use strict";return (' + s + ')')(); return Number.isFinite(v) ? Math.round(v * 100) / 100 : NaN; } catch { return NaN; }
}

function draftTx(d) {
  const L = S.L;
  const amt = evalAmount(d.amount);
  if (!d.date || !(amt > 0)) return null;
  const tx = { date: d.date, payee: d.payee.trim(), narration: d.narration.trim(), tags: [...d.tags], links: d.link.trim() ? [d.link.trim().replace(/^\^/, '')] : [], meta: {}, postings: [] };
  if (d.kind === 'transfer') {
    if (!d.funding || !d.to) return null;
    const fc = d.currency, tc = L.acctCcy[d.to] || fc;
    const isRepay = d.to.startsWith('Liabilities:CreditCard');
    if (isRepay) {
      tx.payee = tx.payee || `${leaf(d.to)} Credit Card`; tx.narration = tx.narration || 'Repayment';
      tx.postings.push({ account: d.to, units: amt, currency: fc }, { account: d.funding, units: -amt, currency: fc });
    } else {
      tx.payee = tx.payee || 'Transfer'; tx.narration = tx.narration || `${shortName(d.funding)} -> ${shortName(d.to)}`;
      if (!tx.tags.includes('transfer')) tx.tags.unshift('transfer');
      if (tc !== fc && evalAmount(d.toAmount) > 0) {
        const ta = evalAmount(d.toAmount);
        tx.meta.exchange_rate = `1 ${fc} = ${(ta / amt).toFixed(5)} ${tc}`;
        tx.postings.push({ account: d.funding, units: -amt, currency: fc }, { account: d.to, units: ta, currency: tc, priceTotal: amt, priceCcy: fc });
      } else tx.postings.push({ account: d.funding, units: -amt, currency: fc }, { account: d.to, units: amt, currency: fc });
    }
    return tx;
  }
  if (!d.account || !d.funding) return null;
  const sign = d.kind === 'expense' ? 1 : -1; // income & refund reduce the category
  const fc = L.acctCcy[d.funding] || d.currency;
  let catAccount = d.account;
  if (d.kind === 'expense' && d.reimb) { catAccount = 'Assets:Receivable:Reimbursement'; if (!tx.tags.includes('reimbursed')) tx.tags.push('reimbursed'); }
  if (d.kind === 'refund' && !tx.tags.includes('refund')) tx.tags.push('refund');
  const cat = { account: catAccount, units: sign * amt, currency: d.currency };
  if (fc !== d.currency && evalAmount(d.paid) > 0) {
    const paid = evalAmount(d.paid);
    // per-unit price, as in "35.81 CNY @ 1.12705 HKD"
    cat.suffix = `@ ${(paid / amt).toFixed(5)} ${fc}`;
    tx.postings.push(cat, { account: d.funding, units: -sign * paid, currency: fc });
  } else {
    tx.postings.push(cat, { account: d.funding, units: -sign * amt, currency: d.currency });
  }
  return tx;
}

function draftText(d) {
  if (d.kind === 'raw' && d.mode !== 'edit') return d.raw || '';
  if (d.edited != null) return d.edited;
  if (d.kind === 'multi') {
    const tx = multiTx(d);
    if (!tx) return '';
    let text = formatTxn(tx);
    // write auto-balanced amounts out explicitly (skipped when lots/costs are involved)
    if (LS.get('explicit', true) && !tx.postings.some((p) => p.cost)) {
      const r = checkText(text, S.L);
      const t = r.ok && r.entries.find((e) => e.type === 'txn');
      const ip = t ? t.postings.filter((p) => p.interpolated) : [];
      if (ip.length) {
        tx.postings = tx.postings.flatMap((p) => (p.units == null && !p.price ? ip.filter((x) => x.account === p.account).map((x) => ({ ...p, units: numText(x.units), currency: x.currency })) : [p]));
        text = formatTxn(tx);
      }
    }
    return text;
  }
  const tx = draftTx(d);
  if (!tx) return '';
  let text = formatTxn(tx);
  // per-unit @ suffix (formatTxn handles @@ only)
  tx.postings.forEach((p) => { if (p.suffix) { const lines = text.split('\n'); const i = lines.findIndex((l) => l.startsWith('  ' + p.account + ' ')); if (i > 0) { lines[i] += ' ' + p.suffix; text = lines.join('\n'); } } });
  return text;
}

function validateText(text, single = true) {
  if (!text.trim()) return { ok: false, msg: '', entries: [] };
  const r = checkText(text, S.L);
  const txns = r.entries.filter((e) => e.type === 'txn');
  if (single && (txns.length !== 1 || r.entries.length !== 1)) return { ...r, ok: false, msg: r.msg || '这里应当正好是一笔交易', txn: txns[0] };
  if (txns.some((t) => t.postings.length < 2) && r.ok) return { ...r, ok: false, msg: '交易至少需要两条分录', txn: txns[0] };
  return { ...r, txn: txns[0] };
}

const TYPE_ZH = { txn: '交易', balance: '余额断言', price: '价格', open: '开户', close: '关户', commodity: '商品', pad: '补齐', note: '备注', event: '事件', document: '文档', query: '查询', custom: '自定义' };

function fileFor(e) {
  const L = S.L;
  const journal = `journals/${e.date.slice(0, 4)}.bean`;
  const most = (pred) => { const c = {}; for (const x of L.entries) if (pred(x) && x.file) c[x.file] = (c[x.file] || 0) + 1; return Object.entries(c).sort((a, b) => b[1] - a[1])[0]?.[0]; };
  const root = (a) => (a || '').split(':')[0];
  switch (e.type) {
    case 'balance': return most((x) => x.type === 'balance') || journal;
    case 'price': return most((x) => x.type === 'price') || journal;
    case 'open': case 'close': return most((x) => (x.type === 'open' || x.type === 'close') && root(x.account) === root(e.account)) || most((x) => x.type === 'open') || journal;
    case 'commodity': return most((x) => x.type === 'commodity') || journal;
    case 'document': return most((x) => x.type === 'document') || journal;
    default: return journal;
  }
}

// an existing assertion for the same account, date and currency (exact account)
function existingBalance(account, date, currency) {
  return S.L.balanceResults.find((r) => r.entry.account === account && r.entry.date === date && r.entry.currency === currency) || null;
}
function duplicateBalances(entries) {
  return (entries || []).filter((e) => e.type === 'balance').map((e) => ({ e, old: existingBalance(e.account, e.date, e.currency) })).filter((x) => x.old);
}

function queueEntries(text, extra = {}, single = false) {
  const v = validateText(text, single);
  if (!v.ok) { toast(v.msg || '内容有误'); return null; }
  const many = v.entries.length > 1;
  v.entries.forEach((e, i) => {
    const path = fileFor(e);
    if (/^journals\/\d{4}\.bean$/.test(path) && !S.tree.tree[path] && !S.pending.some((o) => o.path === path)) {
      S.pending.push({ kind: 'include', path: S.main, line: `include "${path}"`, silent: true });
    }
    const src = (e.src || '').replace(/\s+$/, '');
    const mark = i === 0 ? extra : { silent: extra.silent };
    if (e.type === 'balance') {
      const old = existingBalance(e.account, e.date, e.currency);
      S.pending.push({ kind: 'balance', path: old ? old.entry.file : path, account: e.account, date: e.date, currency: e.currency, replace: !!old, line: src, label: `${old ? '覆盖对账' : '对账'}：${e.account} ${e.date}`, summary: `${old ? '覆盖' : ''}余额断言 ${e.account}`, amountText: money(e.number, e.currency), ...mark });
      return;
    }
    let summary, amountText = '';
    if (e.type === 'txn') {
      summary = [e.payee, e.narration].filter(Boolean).join(' ') || '交易';
      const c = classify({ ...e, _L: S.L, postings: e.postings.filter((p) => p.units != null) });
      amountText = c.kind === 'transfer' ? money(c.amount, c.currency || 'CNY') : signed(c.amount, 'CNY');
    } else summary = `${TYPE_ZH[e.type] || e.type} ${e.account || e.currency || e.name || ''}`.trim();
    S.pending.push({ kind: 'insert', path, date: e.date, text: src, summary, amountText, label: many && i > 0 ? undefined : extra.label, ...mark });
  });
  return v.entries;
}

function renderEdit(d) {
  const text = draftText(d);
  const v = validateText(text);
  const e = d.editOf;
  main.innerHTML = `<div class="view">
    <div class="topbar"><button class="iconbtn" data-act="cancel-edit" aria-label="取消">${ICON.back}</button><h1>编辑交易</h1><span data-status>${statusHTML()}</span></div>
    <div class="editnote">正在修改 <b>${esc(e.date)} ${esc(e.summary)}</b>，位于 ${esc(e.path)}。改日期会按新日期重新排序。</div>
    <div class="preview">
      <textarea data-f="edited" class="tall" spellcheck="false" aria-label="Beancount 文本">${esc(text)}</textarea>
      <div class="vmsg">${vmsgHTML(v)}</div>
    </div>
    <div class="savebar"><button class="btn primary" data-act="save" ${v.ok ? '' : 'disabled'}>保存修改</button><button class="btn" data-act="cancel-edit">取消</button></div>
    <div class="dangerzone"><button class="btn danger" data-act="delete" data-armed="0">删除这笔交易</button></div>
  </div>`;
}

// frequent / monthly transactions from the last 120 days
function templates() {
  const L = S.L;
  if (L._tpl) return L._tpl;
  const since = shiftDay(today(), -120), cur = ym(today());
  const map = new Map();
  for (const t of L.txns) {
    if (t.date < since || t.synthetic || t.postings.length !== 2) continue;
    const cat = t.postings.find((p) => /^(Expenses|Income):/.test(p.account));
    const fund = t.postings.find((p) => p !== cat && /^(Assets|Liabilities):/.test(p.account));
    if (!cat || !fund || cat.price || fund.price || cat.cost || fund.currency !== cat.currency) continue;
    const kind = cat.account.startsWith('Income') ? 'income' : cat.units < 0 ? null : 'expense';
    if (!kind) continue;
    const id = [t.payee, t.narration, cat.account, cat.currency].join('|');
    let x = map.get(id);
    if (!x) map.set(id, (x = { id, kind, payee: t.payee, narration: t.narration, account: cat.account, funding: fund.account, currency: cat.currency, amounts: [], dates: [] }));
    x.amounts.push(Math.abs(cat.units)); x.dates.push(t.date); x.funding = fund.account; // txns are in date order → last one wins
  }
  const pinned = LS.get('tplPinned', []), hidden = new Set(LS.get('tplHidden', []));
  const prev = [1, 2, 3].map((k) => addMonth(cur, -k));
  const list = [];
  for (const x of map.values()) {
    if (hidden.has(x.id)) continue;
    const cnt = {}; x.amounts.forEach((a) => (cnt[a] = (cnt[a] || 0) + 1));
    const [topAmt, topN] = Object.entries(cnt).sort((a, b) => b[1] - a[1])[0];
    x.fixed = topN >= 2 && topN / x.amounts.length >= 0.6 ? Number(topAmt) : null;
    const months = new Set(x.dates.map(ym));
    const perMonth = {}; x.dates.forEach((d) => (perMonth[ym(d)] = (perMonth[ym(d)] || 0) + 1));
    x.monthly = prev.every((m) => months.has(m)) && Object.values(perMonth).every((n) => n <= 2);
    const days = x.dates.map((d) => +d.slice(8)).sort((a, b) => a - b);
    x.day = days[Math.floor(days.length / 2)];
    x.due = x.monthly && !months.has(cur) && +today().slice(8) >= x.day - 2;
    x.n = x.dates.length;
    x.pinned = pinned.includes(x.id);
    if (x.pinned || x.n >= 3) list.push(x);
  }
  list.sort((a, b) => (b.pinned - a.pinned) || (a.pinned && b.pinned ? pinned.indexOf(a.id) - pinned.indexOf(b.id) : 0) || (b.due - a.due) || (b.n - a.n));
  L._tpl = list;
  return list;
}

function tplLabel(x) { return x.payee || x.narration || leaf(x.account); }

function templateBar(d) {
  if (d.mode === 'edit' || d.inboxItem || !['expense', 'income'].includes(d.kind)) return '';
  const list = templates().filter((x) => x.kind === d.kind).slice(0, 8);
  if (!list.length) return '';
  const seen = {}; list.forEach((x) => { const k = tplLabel(x) + '|' + x.narration; seen[k] = (seen[k] || 0) + 1; });
  return `<div class="tpls"><div class="tpl-head"><span>常用</span><button class="linkbtn" data-act="tpl-manage">管理</button></div><div class="tpl-row">${list.map((x) => `
    <span class="tpl ${x.due ? 'due' : ''} ${x.pinned ? 'pinned' : ''}">
      <button class="tpl-fill" data-tpl-fill="${esc(x.id)}" title="${esc([x.payee, x.narration].filter(Boolean).join(' '))} · ${esc(acctLabel(x.account))}">
        <span class="tpl-name">${esc(tplLabel(x))}${x.payee && x.narration ? `<small> ${esc(x.narration)}</small>` : ''}${seen[tplLabel(x) + '|' + x.narration] > 1 ? `<small> · ${esc(leaf(x.account))}</small>` : ''}</span>
        <span class="tpl-amt num">${x.fixed != null ? money(x.fixed, x.currency) : '金额待填'}${x.due ? ' · 本月未记' : ''}</span>
      </button>
      ${x.fixed != null ? `<button class="tpl-go" data-tpl-save="${esc(x.id)}" aria-label="直接记一笔" title="直接记一笔">记</button>` : ''}
    </span>`).join('')}</div></div>`;
}

function draftFromTemplate(x) {
  const d = newDraft(x.kind);
  Object.assign(d, { payee: x.payee, narration: x.narration, account: x.account, funding: x.funding, currency: x.currency, amount: x.fixed != null ? String(x.fixed) : '', date: today() });
  return d;
}

async function saveTemplateNow(x) {
  const d = draftFromTemplate(x);
  const text = draftText(d);
  const before = S.pending.length;
  if (!queueInsert(text)) return;
  const op = S.pending.slice(before).find((o) => o.kind === 'insert');
  await commitQueued('已记');
  toast(`已记：${tplLabel(x)} ${money(x.fixed, x.currency)}`, '撤销', async () => {
    const i = S.pending.indexOf(op);
    if (i >= 0) { S.pending.splice(i, 1); savePending(); await rebuild(); render(); toast('已撤销'); return; }
    S.pending.push({ kind: 'remove', path: op.path, old: op.text, label: `撤销：${op.date} ${op.summary}` });
    await commitQueued('已删');
  });
}

function openTemplateManager() {
  const draw = () => {
    S.L._tpl = null;
    const pinned = LS.get('tplPinned', []), hidden = LS.get('tplHidden', []);
    const list = templates();
    return `<h3>常用交易</h3><div class="sub">根据最近 120 天里出现 3 次以上的交易自动生成。置顶的排在最前；隐藏的不再出现。</div>
      <div class="sheet" style="margin-top:12px">${list.map((x) => `<div class="kv"><span>${esc(tplLabel(x))}${x.payee && x.narration ? ` <span class="muted">${esc(x.narration)}</span>` : ''}<br><span class="muted small">${esc(acctLabel(x.account))} · ${x.n} 次${x.monthly ? ' · 每月' : ''}${x.fixed != null ? ' · 固定 ' + money(x.fixed, x.currency) : ''}</span></span>
        <span class="chips" style="flex-wrap:nowrap"><button class="chip" data-tpl-pin="${esc(x.id)}" aria-pressed="${pinned.includes(x.id)}">${pinned.includes(x.id) ? '已置顶' : '置顶'}</button><button class="chip" data-tpl-hide="${esc(x.id)}">隐藏</button></span></div>`).join('') || '<div class="empty">最近还没有重复出现的交易</div>'}</div>
      ${hidden.length ? `<div class="actions"><button class="btn small" data-tpl-unhide>恢复 ${hidden.length} 个已隐藏</button></div>` : ''}
      <div class="actions"><button class="btn" data-close>完成</button></div>`;
  };
  modal(draw, (e, m) => {
    const pin = e.target.closest('[data-tpl-pin]'), hide = e.target.closest('[data-tpl-hide]');
    if (pin) { const a = LS.get('tplPinned', []); const id = pin.dataset.tplPin; LS.set('tplPinned', a.includes(id) ? a.filter((x) => x !== id) : [...a, id]); m.draw(); }
    if (hide) { LS.set('tplHidden', [...LS.get('tplHidden', []), hide.dataset.tplHide]); LS.set('tplPinned', LS.get('tplPinned', []).filter((x) => x !== hide.dataset.tplHide)); m.draw(); }
    if (e.target.closest('[data-tpl-unhide]')) { LS.del('tplHidden'); m.draw(); }
  }, null, () => { S.L._tpl = null; render(); });
}

function inboxBanner(d) {
  const it = d.inboxItem;
  if (it) {
    const left = S.inbox.filter((x) => x.path !== it.path && !S.pending.some((o) => o.kind === 'deleteFile' && o.path === x.path)).length;
    return `<div class="inbox current"><div><b>Apple Pay</b> ${esc(it.merchant || '（无商户）')} · <span class="num">${esc(Number.isFinite(it.amount) ? money(it.amount, it.currency) : '金额未知')}</span>${it.card ? ` · ${esc(it.card)}` : ''}<div class="muted small">${esc(it.time || it.date)}${left ? `，后面还有 ${left} 笔` : ''}。确认分类和账户后点「记一笔」。</div></div>
      <div class="chips"><button class="chip" data-inbox="skip">跳过</button><button class="chip" data-inbox="drop">不记，删除</button><button class="chip" data-inbox="leave">退出</button></div></div>`;
  }
  const n = S.inbox.filter((x) => !S.pending.some((o) => o.kind === 'deleteFile' && o.path === x.path)).length;
  return n ? `<button class="inbox" data-inbox="start"><span><b>Apple Pay 收件箱</b>：${n} 笔待确认</span><span class="muted">处理 ›</span></button>` : '';
}

function vmsgHTML(v) {
  if (!v) return '';
  if (!v.ok) return (v.errors?.length ? v.errors.slice(0, 5).map((e) => `<div class="note bad">${esc(e.msg)}</div>`).join('') : v.msg ? `<div class="note bad">${esc(v.msg)}</div>` : '');
  const auto = (v.entries || []).flatMap((e) => (e.postings || []).filter((p) => p.interpolated || p.cost?.interpolated || p.price?.interpolated).map((p) =>
    p.interpolated ? `${p.account} ${numText(p.units)} ${p.currency}` : p.cost?.interpolated ? `${p.account} 成本 {${fmtNum(p.cost.number, 4)} ${p.cost.currency}}` : `${p.account} 价格 @ ${fmtNum(p.price.number, 5)} ${p.price.currency}`));
  const booked = (v.entries || []).flatMap((e) => (e.postings || []).filter((p) => p.booked).map((p) => `${p.account} 卖出成本 {${fmtNum(p.cost.number, 4)} ${p.cost.currency}}`));
  const n = v.entries?.length || 0;
  const soft = (v.warnings || []).map((w) => `<div class="note warnline">⚠ ${esc(w.msg)}（仅提示，bean-check 为准）</div>`).join('');
  const dups = duplicateBalances(v.entries);
  const warn = dups.map(({ e, old }) => `<div class="note warnline">⚠ ${esc(e.date)} ${esc(e.account)} 已有断言 ${esc(money(old.entry.number, e.currency))}（${old.ok ? '相符' : '不符'}），保存时会用新的 ${esc(money(e.number, e.currency))} 覆盖</div>`).join('');
  return soft + warn + `<div class="note ok">✓ ${n > 1 ? `${n} 条，` : ''}检查通过${auto.length ? `；自动补平：${esc(auto.join('，'))}` : ''}${booked.length ? `；${esc(booked.join('，'))}` : ''}</div>`;
}

function allCurrencies() {
  const L = S.L;
  const set = new Set([...L.currencies, ...Object.keys(L.commodities)]);
  for (const a in L.final) for (const c in L.final[a]) set.add(c);
  return [...set].filter(Boolean);
}

function multiForm(d, v) {
  const L = S.L;
  const ccys = allCurrencies();
  const residual = {};
  const t = v?.entries?.find((e) => e.type === 'txn');
  if (t) for (const p of t.postings) { const w = weight(p); if (w) residual[w.c] = (residual[w.c] || 0) + w.n; }
  const off = Object.entries(residual).filter(([, n]) => Math.abs(n) > 0.005);
  const payeeStat = L.payees.find((p) => p.name === d.payee);
  const narrSugg = payeeStat ? [...payeeStat.narr.entries()].sort((a, b) => b[1] - a[1]).slice(0, 6).map((x) => x[0]) : [];
  return `<div class="sheet form">
    <div class="field"><label for="f-date">日期</label><div class="daterow"><input id="f-date" type="date" data-f="date" value="${esc(d.date)}">
      <span class="chips">${[['今天', 0], ['昨天', -1]].map(([l, k]) => { const dd = shiftDay(today(), k); return `<button class="chip" data-set="date" data-val="${dd}" aria-pressed="${d.date === dd}">${l}</button>`; }).join('')}
      <button class="chip" data-act="toggle-flag" aria-pressed="${d.flag === '!'}" title="! 表示待确认">${d.flag === '!' ? '! 待确认' : '* 已确认'}</button></span></div></div>
    <div class="field"><label for="f-payee">商户</label><div class="combo"><input id="f-payee" data-f="payee" data-combo="payee" value="${esc(d.payee)}" placeholder="可留空" autocomplete="off"></div></div>
    <div class="field"><label for="f-narr">说明</label><div><input id="f-narr" data-f="narration" value="${esc(d.narration)}" placeholder="${esc(narrSugg[0] || '说明')}" autocomplete="off">
      ${narrSugg.length ? `<div class="chips">${narrSugg.map((n) => `<button class="chip" data-set="narration" data-val="${esc(n)}">${esc(n)}</button>`).join('')}</div>` : ''}</div></div>
    <div class="field"><label for="f-tl">标签</label><input id="f-tl" data-f="tagsText" value="${esc(d.tagsText)}" placeholder="#tag ^link，空格分隔" autocomplete="off" autocapitalize="off"></div>
  </div>
  <div class="section"><h2>分录</h2><span class="aside">金额留空的那一行会自动补平</span></div>
  <div class="prows">${d.rows.map((r, i) => `
    <div class="prow sheet">
      <div class="prow-top">
        <button class="flagbtn" data-rowflag="${i}" aria-pressed="${r.flag === '!'}" title="给这条分录标 !">!</button>
        <div class="combo grow"><input data-combo="row:${i}" data-prefixes="Assets:,Liabilities:,Expenses:,Income:,Equity:" value="${esc(r.account)}" placeholder="账户，如 Expenses:Food:Dining" autocomplete="off" autocapitalize="off"></div>
        <button class="iconbtn sm" data-delrow="${i}" aria-label="删除这一行">×</button>
      </div>
      <div class="prow-bot">
        <div class="amtwrap"><button class="pm" data-neg="${i}" aria-label="正负号">±</button><input class="amt" data-row="${i}" data-rf="amount" inputmode="decimal" value="${esc(r.amount)}" placeholder="${esc(autoHints(d, v)[i] || '自动')}" autocomplete="off"></div>
        <select data-row="${i}" data-rf="currency" aria-label="币种">${[...new Set([r.currency, ...ccys])].map((c) => `<option ${c === r.currency ? 'selected' : ''}>${esc(c)}</option>`).join('')}</select>
        <input data-row="${i}" data-rf="cost" value="${esc(r.cost)}" placeholder="{成本}" autocomplete="off" autocapitalize="characters">
        <input data-row="${i}" data-rf="price" value="${esc(r.price)}" placeholder="@ 价格" autocomplete="off" autocapitalize="characters">
      </div>
    </div>`).join('')}
  </div>
  <div class="chips mchips" style="margin-top:10px">${multiChips(d, v)}</div>
  <div class="help">成本写 <code>335.5 USD</code>、<code>{{总价 USD}}</code>、<code>{}</code>（按批次卖出）、<code>{100 USD, 2026-01-01, "标签"}</code>；价格写 <code>1.19 HKD</code> 或 <code>@@ 29.41 HKD</code>。金额可以写算式。</div>`;
}

function autoHints(d, v) {
  const t = v?.entries?.find((e) => e.type === 'txn');
  const ip = t ? t.postings.filter((p) => p.interpolated) : [];
  const out = {};
  d.rows.forEach((r, i) => { if (r.account && !r.amount.trim()) { const k = ip.findIndex((p) => p.account === r.account); if (k >= 0) { out[i] = numText(ip[k].units) + (ip[k].currency !== r.currency ? ' ' + ip[k].currency : ''); ip.splice(k, 1); } } });
  return out;
}

function multiChips(d, v) {
  const res = {};
  const t = v?.entries?.find((e) => e.type === 'txn');
  if (t) for (const p of t.postings) { const w = weight(p); if (w) res[w.c] = (res[w.c] || 0) + w.n; }
  const off = Object.entries(res).filter(([, n]) => Math.abs(n) > 0.005);
  return `<button class="chip" data-act="add-row">+ 添加一行</button>
    ${off.length === 1 ? `<button class="chip" data-act="balance-last">把差额 ${esc(numText(-off[0][1]))} ${esc(off[0][0])} 补到最后一行</button>` : ''}
    <button class="chip" data-act="toggle-explicit" aria-pressed="${LS.get('explicit', true)}" title="自动补平的金额是否写进文件">${LS.get('explicit', true) ? '写出补平金额' : '补平金额留空'}</button>`;
}

function rawForm(d, v) {
  const T = d.date || today();
  const tpls = [
    ['交易', `${T} * "" ""\n  Expenses:\n  Assets:`],
    ['余额', `${T} balance Assets:  0.00 CNY`],
    ['价格', `${T} price USD  7.10 CNY`],
    ['开户', `${T} open Assets:`],
    ['关户', `${T} close Assets:`],
    ['补齐', `${T} pad Assets: Equity:Opening-Balances`],
    ['备注', `${T} note Assets: ""`],
    ['事件', `${T} event "location" ""`],
    ['文档', `${T} document Assets: "documents/"`],
    ['自定义', `${T} custom "budget" Expenses: "monthly" 0.00 CNY`],
  ];
  return `<div class="sheet form" style="padding:12px 16px">
    <div class="sub">在右侧（手机上是下方）直接写 Beancount，任何指令都可以，一次可以写多条。交易写进当年的 journal，余额断言、价格、开户/关户、商品、文档会写进你账本里放同类内容的文件。</div>
    <div class="chips" style="margin-top:10px">${tpls.map(([l, t]) => `<button class="chip" data-tpl="${esc(t)}">+ ${l}</button>`).join('')}</div>
    <div class="chips" style="margin-top:10px"><button class="chip" data-act="align-raw">对齐金额列</button><span class="sub" style="align-self:center">保存时也会自动对齐</span></div>
  </div>`;
}

function renderAdd() {
  const L = S.L;
  const d = (S.draft ||= newDraft());
  if (d.mode === 'edit') return renderEdit(d);
  const kinds = [['expense', '支出'], ['income', '收入'], ['transfer', '转账'], ['refund', '退款'], ['multi', '分录'], ['raw', '原文']];
  const payeeStat = L.payees.find((p) => p.name === d.payee);
  const catPrefix = d.kind === 'income' ? ['Income:'] : ['Expenses:'];
  const boost = payeeStat ? L.txns.filter((t) => t.payee === d.payee).slice(-30).reverse().flatMap((t) => t.postings.map((p) => p.account)) : [];
  const cats = rankAccounts(catPrefix, [...new Set(boost)]).slice(0, 8);
  const funds = rankAccounts(['Assets:', 'Liabilities:'], [...new Set(boost)]).filter((a) => !a.startsWith('Assets:Receivable')).slice(0, 6);
  const fc = L.acctCcy[d.funding];
  const tc = L.acctCcy[d.to];
  const text = draftText(d);
  const v = text ? validateText(text, d.kind !== 'raw') : null;
  const targets = v?.entries?.length ? [...new Set(v.entries.map(fileFor))] : [`journals/${(d.date || today()).slice(0, 4)}.bean`];
  const narrSugg = payeeStat ? [...payeeStat.narr.entries()].sort((a, b) => b[1] - a[1]).slice(0, 6).map((x) => x[0]) : [];
  const recent = [...S.pending.filter((o) => o.kind === 'insert').map((o) => ({ ...o, pending: true })).reverse(),
    ...L.txns.slice(-12).reverse().filter((t) => !S.pending.some((o) => o.text && o.text.startsWith(`${t.date} * "${t.payee}" "${t.narration}"`)))].slice(0, 10);

  const acctField = (label, key, list, prefixes) => `
    <div class="field"><label>${label}</label><div>
      <div class="combo"><input type="search" data-combo="${key}" data-prefixes="${prefixes.join(',')}" value="${esc(d[key] ? acctLabel(d[key]) : '')}" placeholder="搜索账户" autocomplete="off"></div>
      <div class="chips">${list.map((a) => `<button class="chip" data-set="${key}" data-val="${esc(a)}" aria-pressed="${d[key] === a}">${esc(acctLabel(a))}</button>`).join('')}</div>
    </div></div>`;

  main.innerHTML = `<div class="view">${topbar('记一笔')}
  <div class="add-wrap"><div>
    ${inboxBanner(d)}
    <div class="seg six" role="group" aria-label="类型">${kinds.map(([k, l]) => `<button data-kind="${k}" aria-pressed="${d.kind === k}">${l}</button>`).join('')}</div>
    ${templateBar(d)}
    ${d.kind === 'multi' ? multiForm(d, v) : d.kind === 'raw' ? rawForm(d, v) : `<div class="sheet form">
      <div class="amount-line">
        <select data-f="currency" aria-label="币种">${L.currencies.map((c) => `<option ${c === d.currency ? 'selected' : ''}>${c}</option>`).join('')}</select>
        <input data-f="amount" inputmode="decimal" placeholder="0.00" value="${esc(d.amount)}" aria-label="金额" autocomplete="off">
        <button class="opbtn" data-op="+" aria-label="加">+</button>
      </div>
      <div class="calc" ${/[+\-*/×÷]/.test(d.amount.replace(/^-/, '')) ? '' : 'hidden'}>= <span class="num">${fmtNum(evalAmount(d.amount))}</span></div>
      <div class="field"><label for="f-date">日期</label><div class="daterow"><input id="f-date" type="date" data-f="date" value="${esc(d.date)}">
        <span class="chips">${[['今天', 0], ['昨天', -1], ['前天', -2]].map(([l, k]) => { const dd = shiftDay(today(), k); return `<button class="chip" data-set="date" data-val="${dd}" aria-pressed="${d.date === dd}">${l}</button>`; }).join('')}</span></div></div>
      ${d.kind === 'transfer' ? `
        ${acctField('转出', 'funding', funds, ['Assets:', 'Liabilities:'])}
        ${acctField('转入', 'to', rankAccounts(['Assets:', 'Liabilities:']).filter((a) => a !== d.funding).slice(0, 6), ['Assets:', 'Liabilities:'])}
        ${d.to && tc && tc !== d.currency ? `<div class="field"><label>到账 ${esc(tc)}</label><input data-f="toAmount" inputmode="decimal" placeholder="实际到账金额" value="${esc(d.toAmount)}"></div>` : ''}
      ` : `
        <div class="field"><label for="f-payee">商户</label><div class="combo"><input id="f-payee" data-f="payee" data-combo="payee" value="${esc(d.payee)}" placeholder="例如 便利店、淘宝" autocomplete="off"></div></div>
        <div class="field"><label for="f-narr">说明</label><div><input id="f-narr" data-f="narration" value="${esc(d.narration)}" placeholder="${esc(narrSugg[0] || '买了什么')}" autocomplete="off">
          ${narrSugg.length ? `<div class="chips">${narrSugg.map((n) => `<button class="chip" data-set="narration" data-val="${esc(n)}">${esc(n)}</button>`).join('')}</div>` : ''}</div></div>
        ${acctField(d.kind === 'income' ? '来源' : '分类', 'account', cats, catPrefix)}
        ${acctField(d.kind === 'income' ? '收到' : d.kind === 'refund' ? '退回到' : '付款', 'funding', funds, ['Assets:', 'Liabilities:'])}
        ${fc && fc !== d.currency ? `<div class="field"><label>实付 ${esc(fc)}</label><input data-f="paid" inputmode="decimal" placeholder="账户实际扣款" value="${esc(d.paid)}"></div>` : ''}
        ${d.kind === 'expense' ? `<div class="field"><label>报销</label><div>
          <label class="toggle"><input type="checkbox" data-f="reimb" ${d.reimb ? 'checked' : ''}>可报销（记入应收，打 #reimbursed）</label>
          ${d.reimb ? `<div class="combo"><input data-f="link" data-combo="link" value="${esc(d.link)}" placeholder="关联 ^link，如 reimburse-work-${today().replace(/-/g, '')}" autocomplete="off"></div>
            <div class="chips">${L.openLinks.filter((x) => x.link.startsWith('reimburse')).slice(-4).map((x) => `<button class="chip" data-set="link" data-val="${esc(x.link)}" aria-pressed="${d.link === x.link}">${esc(x.link)}</button>`).join('')}</div>` : ''}
        </div></div>` : ''}
        ${d.kind === 'refund' ? `<div class="field"><label>关联</label><div class="combo"><input data-f="link" data-combo="link" value="${esc(d.link)}" placeholder="^refund-… 可留空" autocomplete="off"></div></div>` : ''}
      `}
    </div>`}
  </div>
  <div>
    <div class="preview">
      <div class="note"><span>将写入 ${targets.map(esc).join('、')}</span>${d.kind === 'raw' ? '<span>可以一次写多条</span>' : d.edited != null ? '<button class="linkbtn" data-act="reset-edit">恢复自动生成</button>' : '<span>可直接修改</span>'}</div>
      <textarea data-f="${d.kind === 'raw' ? 'raw' : 'edited'}" class="${d.kind === 'raw' ? 'tall' : ''}" spellcheck="false" autocapitalize="off" autocorrect="off" aria-label="Beancount 文本" placeholder="${d.kind === 'raw' ? '直接写 Beancount，例如：\n2026-10-08 price USD 7.10 CNY\n2026-10-09 balance Assets:Cash 400.00 CNY' : '填好金额和账户后，这里会生成分录'}">${esc(text)}</textarea>
      <div class="vmsg">${vmsgHTML(v)}</div>
    </div>
    <div class="savebar"><button class="btn primary" data-act="save" ${v?.ok ? '' : 'disabled'}>记一笔</button><button class="btn" data-act="clear">清空</button></div>
    <div class="section"><h2>最近</h2></div>
    <div class="ledger">${recent.map((r) => r.pending ? pendingRow(r) : txRow(r)).join('') || '<div class="empty">还没有记录</div>'}</div>
  </div></div></div>`;
}

function pendingRow(o) {
  return `<div class="row"><span class="t">${esc(o.summary)}<span class="tag wait">待同步</span></span><span class="a num">${esc(o.amountText || '')}</span><span class="s">${esc(o.date)}</span><span></span></div>`;
}

function txRow(t, opts = {}) {
  const c = classify(t);
  const cat = t.postings.find((p) => p.account.startsWith('Expenses:') || p.account.startsWith('Income:'));
  let amt;
  if (opts.account) {
    const ps = t.postings.filter((p) => p.account === opts.account || p.account.startsWith(opts.account + ':'));
    const byC = {}; ps.forEach((p) => (byC[p.currency] = (byC[p.currency] || 0) + p.units));
    amt = Object.entries(byC).map(([cc, n]) => `<span class="${n > 0 ? 'pos' : ''}">${signed(n, cc)}</span>`).join(' ');
  } else if (c.kind === 'transfer') amt = `<span class="muted">${money(c.amount, c.currency)}</span>`;
  else amt = `<span class="${c.amount > 0 ? 'pos' : ''}">${signed(c.amount, 'CNY')}</span>`;
  const sub = cat ? acctLabel(cat.account) : t.postings.map((p) => shortName(p.account)).join(' → ');
  const tags = (t.flag === '!' ? '<span class="tag warn">待确认</span>' : t.synthetic ? '<span class="tag">pad</span>' : '') + t.tags.filter((x) => x !== 'transfer').map((x) => `<span class="tag">#${esc(x)}</span>`).join('');
  return `<button class="row" data-tx="${t.id}"><span class="t">${esc(t.payee || t.narration || '（无商户）')}${t.payee && t.narration ? ` <span>${esc(t.narration)}</span>` : ''}${tags}</span><span class="a num">${amt}</span>
    <span class="s">${opts.showDate ? esc(t.date) + '  ' : ''}${esc(sub)}</span><span class="b num">${opts.bal ?? ''}</span></button>`;
}

// ---------------------------------------------------------------------
// combobox
// ---------------------------------------------------------------------
let comboState = null;
function fuzzy(q, s) {
  q = q.toLowerCase(); s = s.toLowerCase();
  if (s.includes(q)) return 2;
  let i = 0; for (const ch of s) if (ch === q[i]) i++;
  return i === q.length ? 1 : 0;
}
function openCombo(input) {
  const key = input.dataset.combo;
  const q = input.value.trim();
  const L = S.L;
  let items = [];
  if (key === 'payee') {
    items = L.payees.filter((p) => !q || fuzzy(q, p.name)).slice(0, 12).map((p) => ({ val: p.name, label: p.name, hint: p.last ? acctLabel(p.last.postings[0].account) : '' }));
  } else if (key.startsWith('row:')) {
    const prefixes = input.dataset.prefixes.split(',');
    items = rankAccounts(prefixes).map((a) => ({ a, s: q ? Math.max(fuzzy(q, a), fuzzy(q, acctLabel(a))) : 1 })).filter((x) => x.s).sort((x, y) => y.s - x.s).slice(0, 14)
      .map(({ a }) => ({ val: a, label: a, hint: '' }));
    if (items.length === 1 && items[0].val === q) items = [];
  } else if (key === 'link') {
    items = L.allLinks.filter((l) => !q || fuzzy(q, l)).slice(-12).reverse().map((l) => ({ val: l, label: l }));
  } else {
    const prefixes = input.dataset.prefixes.split(',');
    items = rankAccounts(prefixes).map((a) => ({ a, s: q ? Math.max(fuzzy(q, a), fuzzy(q, acctLabel(a))) : 1 })).filter((x) => x.s).sort((x, y) => y.s - x.s).slice(0, 14)
      .map(({ a }) => ({ val: a, label: acctLabel(a), hint: a.split(':')[0] === 'Expenses' || a.split(':')[0] === 'Income' ? '' : ZH[a.split(':')[0]] }));
  }
  closeCombo();
  if (!items.length || (key === 'payee' && items.length === 1 && items[0].val === q)) return;
  const box = document.createElement('div'); box.className = 'combo-list'; box.setAttribute('role', 'listbox');
  box.innerHTML = items.map((it, i) => `<button type="button" data-pick="${esc(it.val)}" class="${i === 0 ? 'active' : ''}">${esc(it.label)}${it.hint ? `<small>${esc(it.hint)}</small>` : ''}</button>`).join('');
  input.parentElement.appendChild(box);
  comboState = { input, key, box, idx: 0 };
}
function closeCombo() { comboState?.box.remove(); comboState = null; }
function pickCombo(val) {
  const { key } = comboState; closeCombo();
  if (key.startsWith('row:')) {
    const r = S.draft.rows[+key.slice(4)];
    r.account = val;
    if (!r.ccyTouched && S.L.acctCcy[val]) r.currency = S.L.acctCcy[val];
    S.draft.edited = null;
    render();
    const next = document.querySelector(`[data-row="${key.slice(4)}"][data-rf="amount"]`); next?.focus();
    return;
  }
  setDraft(key, val, true);
}

function setDraft(key, val, rerender) {
  const d = S.draft;
  d[key] = val;
  if (key !== 'edited') d.edited = null;
  // an Apple Pay entry keeps its own amount, currency and card while the payee changes
  const keepInbox = key === 'payee' && d.inboxItem ? { currency: d.currency, amount: d.amount, funding: guessFunding(d.inboxItem.card) } : null;
  if (key === 'payee' && d.kind === 'multi') {
    const p = S.L.payees.find((x) => x.name === val);
    if (p?.last && !d.rows.some((r) => r.amount.trim())) d.rows = rowsFromTxn(p.last, false);
  } else if (key === 'payee') {
    const p = S.L.payees.find((x) => x.name === val);
    if (p?.last) {
      const t = p.last;
      const cat = t.postings.find((x) => x.account.startsWith(d.kind === 'income' ? 'Income:' : 'Expenses:'));
      const fund = t.postings.find((x) => x.account.startsWith('Assets:') || x.account.startsWith('Liabilities:'));
      if (cat) { d.account = cat.account; d.currency = cat.currency; }
      if (fund && !fund.account.startsWith('Assets:Receivable')) d.funding = fund.account;
    }
  }
  if (keepInbox) { d.currency = keepInbox.currency; d.amount = keepInbox.amount; if (keepInbox.funding) d.funding = keepInbox.funding; }
  if (key === 'funding' && d.kind !== 'transfer') { /* keep currency */ }
  if (key === 'funding' && d.kind === 'transfer') d.currency = S.L.acctCcy[val] || d.currency;
  if (rerender) renderKeepFocus();
}

function renderKeepFocus() {
  const a = document.activeElement;
  const sel = !a || !a.dataset ? null : a.dataset.f ? `[data-f="${a.dataset.f}"]` : a.dataset.row != null ? `[data-row="${a.dataset.row}"][data-rf="${a.dataset.rf}"]` : a.dataset.combo ? `[data-combo="${a.dataset.combo}"]` : null;
  const pos = a && 'selectionStart' in a ? a.selectionStart : null;
  render();
  if (sel) { const el = $(sel); if (el) { el.focus(); try { if (pos != null) el.setSelectionRange(pos, pos); } catch {} } }
}

main.addEventListener('input', (e) => {
  const el = e.target;
  if (el.dataset.combo?.startsWith('row:') && S.draft) { const i = +el.dataset.combo.slice(4); S.draft.rows[i].account = el.value.trim(); S.draft.edited = null; openCombo(el); updatePreview(); return; }
  if (el.dataset.row != null && S.draft) { const r = S.draft.rows[+el.dataset.row]; r[el.dataset.rf] = el.value; if (el.dataset.rf === 'currency') r.ccyTouched = true; S.draft.edited = null; updatePreview(); return; }
  if (el.dataset.combo && el.dataset.combo !== 'payee' && el.dataset.combo !== 'link') { openCombo(el); return; }
  if (!el.dataset.f || !S.draft) {
    if (el.id === 'q') { S.search.q = el.value; S.search.limit = 120; clearTimeout(qTimer); qTimer = setTimeout(() => renderJournalResults(), 120); }
    return;
  }
  const f = el.dataset.f;
  const val = el.type === 'checkbox' ? el.checked : el.value;
  S.draft[f] = val;
  if (f !== 'edited') S.draft.edited = null;
  if (el.dataset.combo) openCombo(el);
  // light update: refresh preview + validity without full re-render on typing
  if (f === 'raw') { S.draft.overwriteOK = false; const b = $('[data-act="save"]'); if (b) { b.textContent = '记一笔'; b.classList.remove('danger-fill'); } }
  if (['amount', 'narration', 'toAmount', 'paid', 'link', 'payee', 'edited', 'raw', 'tagsText'].includes(f)) updatePreview(f === 'edited' || f === 'raw');
  else renderKeepFocus();
});
let qTimer;

main.addEventListener('change', (e) => {
  const el = e.target;
  if (rendering || !el.isConnected || !S.draft || !el.dataset.f) return;
  if (['currency', 'date', 'reimb'].includes(el.dataset.f)) { S.draft[el.dataset.f] = el.type === 'checkbox' ? el.checked : el.value; S.draft.edited = null; render(); }
  if (el.dataset.f === 'payee') { setDraft('payee', el.value, true); }
});

function updatePreview(fromTextarea) {
  const d = S.draft;
  const calc = $('.calc');
  if (calc) { const expr = /[+\-*/×÷]/.test(String(d.amount).replace(/^-/, '')); calc.hidden = !expr; if (expr) calc.querySelector('span').textContent = Number.isFinite(evalAmount(d.amount)) ? fmtNum(evalAmount(d.amount)) : '?'; }
  const ta = $('.preview textarea');
  const text = draftText(d);
  if (!fromTextarea && ta) ta.value = text;
  const v = text ? validateText(text, d.kind !== 'raw' || d.mode === 'edit') : null;
  const btn = $('[data-act="save"]'); if (btn) btn.disabled = !v?.ok;
  const box = $('.preview .vmsg'); if (box) box.innerHTML = vmsgHTML(v);
  if (fromTextarea && d.kind !== 'raw') { const n = $('.preview .note span:last-child'); if (n && n.textContent === '可直接修改') n.outerHTML = '<button class="linkbtn" data-act="reset-edit">恢复自动生成</button>'; }
  if (d.kind === 'multi') {
    const mc = $('.mchips'); if (mc) mc.innerHTML = multiChips(d, v);
    const hints = autoHints(d, v);
    document.querySelectorAll('.prow-bot .amt').forEach((el) => { el.placeholder = hints[el.dataset.row] || '自动'; });
  }
  if (d.kind === 'raw' && v?.entries?.length) { const nt = $('.preview .note span'); if (nt) nt.textContent = '将写入 ' + [...new Set(v.entries.map(fileFor))].join('、'); }
}

main.addEventListener('keydown', (e) => {
  if (!comboState || e.target !== comboState.input) return;
  const btns = [...comboState.box.querySelectorAll('button')];
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    comboState.idx = (comboState.idx + (e.key === 'ArrowDown' ? 1 : -1) + btns.length) % btns.length;
    btns.forEach((b, i) => b.classList.toggle('active', i === comboState.idx));
    btns[comboState.idx].scrollIntoView({ block: 'nearest' });
  } else if (e.key === 'Enter') { e.preventDefault(); pickCombo(btns[comboState.idx].dataset.pick); }
  else if (e.key === 'Escape') closeCombo();
});
main.addEventListener('focusin', (e) => { const c = e.target.dataset?.combo; if (c) { if (c !== 'payee' && c !== 'link' && !c.startsWith('row:')) e.target.select?.(); openCombo(e.target); } });
document.addEventListener('pointerdown', (e) => {
  if (!comboState) return;
  const pick = e.target.closest('[data-pick]');
  if (pick) { e.preventDefault(); pickCombo(pick.dataset.pick); return; }
  if (e.target !== comboState.input) closeCombo();
});

function queueInsert(text, extra = {}) {
  const r = queueEntries(text, extra, true);
  return r ? r[0] : null;
}

async function commitQueued(word = '已记') {
  savePending();
  stamp(word);
  await rebuild();
  render();
  await syncNow();
  render();
}

async function saveDraft() {
  const d = S.draft;
  const text = draftText(d).trim();
  const v = validateText(text, d.kind !== 'raw' || d.mode === 'edit');
  if (!v.ok) { toast(v.msg); return; }
  if (d.mode === 'edit') {
    const e = d.editOf;
    if (text === e.old.trim()) { toast('没有改动'); return; }
    S.pending.push({ kind: 'remove', path: e.path, old: e.old, label: `修改：${e.date} ${e.summary}` });
    if (!queueEntries(text, { silent: true }, true)) { S.pending.pop(); return; }
    S.draft = null;
    if (!navPopNow()) S.tab = d.returnTab || 'journal';
    await commitQueued('已改');
    return;
  }
  if (d.kind === 'raw' && !d.overwriteOK) {
    const dups = duplicateBalances(v.entries);
    if (dups.length) {
      d.overwriteOK = true;
      const btn = $('[data-act="save"]'); if (btn) { btn.textContent = `确认覆盖 ${dups.length} 条断言`; btn.classList.add('danger-fill'); }
      toast('同一天已有断言，再点一次确认覆盖');
      return;
    }
  }
  if (d.kind === 'raw' || d.kind === 'multi') {
    if (!queueEntries(d.kind === 'raw' ? alignText(text) : text, {}, d.kind === 'multi')) return;
    const keep = d.kind;
    S.draft = { ...newDraft(keep), date: d.date };
    if (keep === 'multi') { S.draft.rows = d.rows.map((r) => ({ ...r, amount: '' })); S.draft.payee = ''; S.draft.narration = ''; }
    await commitQueued('已记');
    return;
  }
  if (!queueInsert(text)) return;
  if (d.inboxItem) {
    const it = d.inboxItem;
    S.pending.push({ kind: 'deleteFile', path: it.path, label: `收件箱：已入账 ${it.merchant}` });
    if (it.card && d.funding) { const m = LS.get('cardMap', {}); m[it.card] = d.funding; LS.set('cardMap', m); }
    if (it.merchant && d.payee && d.payee !== it.merchant) { const m = LS.get('merchantMap', {}); m[it.merchant] = d.payee; LS.set('merchantMap', m); }
    const nx = nextInbox(it.path);
    if (nx) { draftFromInbox(nx); await commitQueued('已记'); return; }
  }
  if (d.refundOf) {
    const o = d.refundOf;
    if (o.link) S.pending.push({ kind: 'link', path: o.path, line: o.line, header: o.header, link: o.link, silent: true });
  }
  const keep = { kind: d.kind === 'refund' ? 'expense' : d.kind, funding: d.funding, date: d.date };
  S.draft = { ...newDraft(keep.kind), funding: keep.funding, date: keep.date };
  S.draft.currency = S.L.acctCcy[keep.funding] || 'CNY';
  await commitQueued('已记');
}

async function deleteEdited() {
  const d = S.draft; const e = d.editOf;
  S.pending.push({ kind: 'remove', path: e.path, old: e.old, label: `删除：${e.date} ${e.summary}` });
  S.draft = null;
  if (!navPopNow()) S.tab = d.returnTab || 'journal';
  await commitQueued('已删');
}

async function startEdit(t) {
  const text = await readWithPending(t.file);
  const lines = text.split('\n');
  const old = lines.slice(t.startLine, t.endLine + 1).join('\n');
  navPush();
  S.draft = { ...newDraft(), mode: 'edit', edited: old, editOf: { path: t.file, old, date: t.date, summary: [t.payee, t.narration].filter(Boolean).join(' ') }, returnTab: S.tab };
  S.tab = 'add';
  render();
  window.scrollTo(0, 0);
}

function stamp(word = '已记') {
  const el = document.createElement('div'); el.className = 'seal'; el.textContent = word;
  document.body.appendChild(el); setTimeout(() => el.remove(), 1000);
}

function isComplex(t) {
  const real = t.postings.filter((p) => !p.interpolated);
  return t.postings.length > 2 || t.postings.some((p) => p.cost || (p.price && t.postings.length > 2) || p.flag || Object.keys(p.meta || {}).length) || t.flag !== '*' || t.postings.length !== real.length && t.postings.length > 1 && !t.tags.includes('transfer') && !t.postings.some((p) => /^(Expenses|Income):/.test(p.account));
}

function rowsFromTxn(t, withAmounts = true) {
  const rows = [];
  for (const p of t.postings) {
    if (p.interpolated && rows.some((r) => r.account === p.account && !r.amount)) continue;
    rows.push({
      account: p.account,
      amount: withAmounts && !p.interpolated && p.units != null ? numText(p.units) : '',
      currency: p.currency || 'CNY',
      cost: p.cost ? (p.cost.totalBraces ? `{{${p.cost.raw}}}` : p.booked ? `{${p.cost.raw}}` : p.cost.raw ? p.cost.raw : '{}') : '',
      price: p.price ? `${p.price.total ? '@@' : '@'} ${p.price.total ? numText(Math.abs(p.price.raw)) : numText(p.price.number)} ${p.price.currency}` : '',
      flag: p.flag || '',
    });
  }
  return rows.length ? rows : [newRow(), newRow()];
}

function multiDraftFromTxn(t) {
  const d = newDraft('multi');
  d.payee = t.payee; d.narration = t.narration; d.flag = t.flag === '!' ? '!' : '*';
  d.tagsText = [...t.tags.map((x) => '#' + x), ...t.links.map((x) => '^' + x)].join(' ');
  d.rows = rowsFromTxn(t, true);
  return d;
}

function draftFromTxn(t, kind) {
  if (!kind && isComplex(t)) return multiDraftFromTxn(t);
  const d = newDraft(kind);
  const c = classify(t);
  d.kind = kind || (c.kind === 'refund' ? 'refund' : c.kind);
  d.payee = t.payee; d.narration = t.narration;
  const cat = t.postings.find((p) => /^(Expenses|Income):/.test(p.account)) || t.postings.find((p) => p.account.startsWith('Assets:Receivable'));
  const fund = t.postings.find((p) => p !== cat && (p.account.startsWith('Assets:') || p.account.startsWith('Liabilities:')));
  if (d.kind === 'transfer') {
    const from = t.postings.find((p) => p.units < 0), to = t.postings.find((p) => p.units > 0);
    d.funding = from?.account; d.to = to?.account; d.amount = String(Math.abs(from?.units ?? '')); d.currency = from?.currency || 'CNY';
    if (to && from && to.currency !== from.currency) d.toAmount = String(to.units);
    d.payee = ''; d.narration = '';
  } else if (cat) {
    d.account = cat.account.startsWith('Assets:Receivable') ? (d.reimb = true, '') : cat.account;
    if (d.reimb) { d.account = rankAccounts(['Expenses:'])[0]; }
    d.amount = String(Math.abs(cat.units)); d.currency = cat.currency;
    if (fund) d.funding = fund.account;
    if (fund && fund.currency !== cat.currency) d.paid = String(Math.abs(fund.units));
  }
  return d;
}

function refundDraft(t) {
  const d = draftFromTxn(t, 'refund');
  d.kind = 'refund'; d.date = today(); d.reimb = false;
  d.narration = t.narration && !t.narration.endsWith('退款') ? t.narration + '退款' : t.narration;
  const existing = t.links.find((l) => l.startsWith('refund'));
  let h = 0; for (const ch of t.payee + t.narration + t.date) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  const base = existing || `refund-${t.date.replace(/-/g, '')}-${h.toString(36).slice(-4)}`;
  d.link = base;
  if (!existing) d.refundOf = { path: t.file, line: t.line, header: null, link: base, t };
  return d;
}

// ---------------------------------------------------------------------
// 概览
// ---------------------------------------------------------------------
function periodSum(obj, key) { let n = 0; for (const k in obj) if (k.startsWith(key)) n += obj[k]; return n; }
function periodCats(L, key) { const out = {}; for (const m in L.monthCat) if (m.startsWith(key)) for (const [a, v] of Object.entries(L.monthCat[m])) out[a] = (out[a] || 0) + v; return out; }

function renderOverview() {
  const L = S.L;
  const yearMode = S.period === 'year';
  const m = (S.month ||= ym(today()));
  const key = yearMode ? m.slice(0, 4) : m;
  const months = yearMode ? Array.from({ length: 12 }, (_, i) => `${key}-${String(i + 1).padStart(2, '0')}`) : Array.from({ length: 12 }, (_, i) => addMonth(m, i - 11));
  const exp = periodSum(L.monthExp, key);
  const inc = periodSum(L.monthInc, key);
  let prev, prevLabel, avgHTML = '';
  if (yearMode) {
    // same span last year (Jan..current month if this is the current year)
    const lastM = key === today().slice(0, 4) ? +today().slice(5, 7) : 12;
    const py = String(+key - 1);
    prev = 0; for (let i = 1; i <= lastM; i++) prev += L.monthExp[`${py}-${String(i).padStart(2, '0')}`] || 0;
    prevLabel = lastM === 12 ? `${py} 年` : `去年同期`;
  } else {
    prev = L.monthExp[addMonth(m, -1)] || 0; prevLabel = '上月';
    const avg = months.slice(0, 11).reduce((s, x) => s + (L.monthExp[x] || 0), 0) / 11;
    avgHTML = `<span>近 11 月均 <b class="num">${money(avg)}</b></span>`;
  }
  const net = inc - exp;
  const rate = inc > 0 ? Math.round((net / inc) * 100) : null;
  // net worth
  let nw = 0;
  const fin = L.final;
  for (const a in fin) if (a.startsWith('Assets:') || a.startsWith('Liabilities:')) for (const c in fin[a]) nw += toCNY(L, fin[a][c], c) ?? 0;
  let recv = 0; for (const a in fin) if (a.startsWith('Assets:Receivable')) for (const c in fin[a]) recv += toCNY(L, fin[a][c], c) ?? 0;
  // categories
  const cm = periodCats(L, key);
  const groups = {};
  for (const [a, v] of Object.entries(cm)) { const g = catOf(a); (groups[g] ||= { total: 0, leaves: {} }); groups[g].total += v; groups[g].leaves[a] = v; }
  const glist = Object.entries(groups).sort((a, b) => b[1].total - a[1].total);
  const maxG = Math.max(1, ...glist.map(([, g]) => g.total));
  // payees
  const pay = {};
  for (const t of L.txns) if (t.date.startsWith(key)) { const c = classify(t); if (c.kind === 'expense') pay[t.payee || t.narration || '—'] = (pay[t.payee || t.narration || '—'] || 0) - c.amount; }
  const topPay = Object.entries(pay).sort((a, b) => b[1] - a[1]).slice(0, 6);
  // liabilities
  const liab = Object.entries(fin).filter(([a]) => a.startsWith('Liabilities:')).flatMap(([a, cs]) => Object.entries(cs).filter(([, n]) => Math.abs(n) > 0.005).map(([c, n]) => ({ a, c, n }))).sort((x, y) => x.n - y.n);
  const errs = L.errors.length;
  const reimb = L.openLinks.filter((x) => x.amount > 0.005);
  const label = yearMode ? `${key}年` : monthLabel(m);

  main.innerHTML = `<div class="view">${topbar('概览', `<div class="monthbar"><div class="seg mini" role="group" aria-label="周期"><button data-period="month" aria-pressed="${!yearMode}">月</button><button data-period="year" aria-pressed="${yearMode}">年</button></div><button class="iconbtn" data-month="-1" aria-label="上一期">${ICON.prev}</button><strong>${label}</strong><button class="iconbtn" data-month="1" aria-label="下一期">${ICON.next}</button></div>`)}
  <div class="sheet">
    <div class="hero">
      <div class="label">${yearMode ? '本年支出' : '本月支出'}</div>
      <div class="big num"><small>¥</small>${fmtNum(exp)}</div>
      <div class="compare"><span>${prevLabel} <b class="num">${money(prev)}</b></span>${avgHTML}<span>${exp > prev ? '多花' : '少花'} <b class="num">${money(Math.abs(exp - prev))}</b></span></div>
    </div>
    <div class="stats">
      <button data-goto-income><div class="k">收入</div><div class="v num pos">${money(inc, 'CNY', 0)}</div></button>
      <button data-goto-income><div class="k">结余${rate != null ? ` · 储蓄率 ${rate}%` : ''}</div><div class="v num ${net < 0 ? 'bad' : ''}">${money(net, 'CNY', 0)}</div></button>
      <button data-tab="accounts"><div class="k">净资产</div><div class="v num">${money(nw, 'CNY', 0)}</div></button>
    </div>
  </div>
  <div class="section"><h2>${yearMode ? `${key} 年每月支出` : '近 12 个月支出'}</h2><span class="aside">点柱子看那个月</span></div>
  <div class="sheet chart" id="trend"></div>
  <div class="grid2">
    <div><div class="section"><h2>分类</h2><span class="aside">${glist.length ? '点开看细分' : ''}</span></div>
      <div class="sheet cats">${glist.map(([g, x]) => `
        <button class="cat" data-expand="${esc(g)}" aria-expanded="${!!S.expanded[g]}"><span class="name">${esc(catLabel(g))}<span>${esc(leaf(g))}</span></span><span class="num">${money(x.total)}<span class="muted"> ${exp && x.total > 0 ? Math.round((x.total / exp) * 100) + '%' : ''}</span></span><span class="bar"><i style="width:${Math.max(0, (x.total / maxG) * 100)}%"></i></span></button>
        ${S.expanded[g] ? Object.entries(x.leaves).sort((a, b) => b[1] - a[1]).map(([a, v]) => `<button class="cat sub" data-goto-search="${esc(a)}"><span class="name">${esc(leaf(a))}</span><span class="num">${money(v)}</span><span class="bar"><i style="width:${Math.max(0, (v / maxG) * 100)}%"></i></span></button>`).join('') : ''}`).join('') || `<div class="empty">${label}还没有支出</div>`}
      </div>
      <div class="section"><h2>花得最多的商户</h2></div>
      <div class="sheet">${topPay.map(([p, v]) => `<button class="kv" data-goto-q="${esc(p)}"><span>${esc(p)}</span><span class="num">${money(v)}</span></button>`).join('') || '<div class="empty">—</div>'}</div>
    </div>
    <div>
      <div class="section"><h2>待报销</h2><span class="aside num">${money(recv)}</span></div>
      <div class="sheet">${L.unclaimed.length ? `<button class="kv" data-reimb="__unclaimed"><span>未报销的垫付<br><span class="muted small">${L.unclaimed.length} 笔，最早 ${esc(L.unclaimed[0].t.date)} · 点击记报销到账</span></span><span class="num">${money(L.unclaimed.reduce((s, x) => s + x.amount, 0))}</span></button>` : ''}
        ${reimb.map((x) => `<button class="kv" data-reimb="${esc(x.link)}"><span>^${esc(x.link)}<br><span class="muted small">${x.n} 笔垫付 · 点击记到账</span></span><span class="num">${money(x.amount, x.currency)}</span></button>`).join('')}
        ${!L.unclaimed.length && !reimb.length ? '<div class="empty">没有待报销的款项</div>' : ''}</div>
      <div class="section"><h2>负债</h2><span class="aside num">${money(liab.reduce((s, x) => s + (toCNY(L, x.n, x.c) ?? 0), 0))}</span></div>
      <div class="sheet">${liab.map((x) => `<button class="kv" data-goto-acct="${esc(x.a)}"><span>${esc(acctLabel(x.a))}</span><span class="num">${money(x.n, x.c)}</span></button>`).join('') || '<div class="empty">没有负债</div>'}</div>
      <div class="section"><h2>账本检查</h2></div>
      <div class="sheet"><button class="kv" data-tab="settings"><span>${errs ? `<span class="bad">${errs} 个问题</span>` : '应用内检查全部通过'}</span><span class="muted">${L.balanceResults.filter((r) => r.ok).length}/${L.balanceResults.length} 余额断言</span></button>
        ${S.ci?.url ? `<a class="kv" href="${esc(S.ci.url)}" target="_blank" rel="noopener"><span>${ciHTML()}</span></a>` : `<div class="kv"><span>${ciHTML()}</span></div>`}</div>
    </div>
  </div></div>`;
  drawTrend(months, yearMode ? null : m);
}
function drawTrend(months, m) {
  const box = $('#trend'); if (!box) return;
  const w = Math.max(280, box.clientWidth - 24);
  box.innerHTML = trendSVG(months, m, w);
  bindTrend(months);
}
let rz, lastW = window.innerWidth; window.addEventListener('resize', () => { clearTimeout(rz); rz = setTimeout(() => { if (window.innerWidth === lastW) return; lastW = window.innerWidth; if ((S.tab === 'overview' || S.tab === 'reports') && S.L) render(); }, 150); });
function trendSVG(months, sel, W = 600) {
  const L = S.L;
  const vals = months.map((m) => L.monthExp[m] || 0);
  const max = Math.max(1, ...vals);
  const H = 170, top = 18, bottom = 22, gap = 8;
  const bw = (W - gap * (months.length - 1)) / months.length;
  const nice = niceMax(max);
  const y = (v) => top + (H - top - bottom) * (1 - v / nice);
  const grid = [0.5, 1].map((f) => `<line x1="0" x2="${W}" y1="${y(nice * f)}" y2="${y(nice * f)}" stroke="var(--rule)" stroke-dasharray="2 4"/><text class="val" x="${W}" y="${y(nice * f) - 4}" text-anchor="end" font-size="11" fill="var(--faint)">${fmtNum(nice * f, 0)}</text>`).join('');
  const bars = months.map((m, i) => {
    const v = vals[i], x = i * (bw + gap), h = Math.max(v > 0 ? 2 : 0, H - bottom - y(v));
    const r = Math.min(4, bw / 2, h);
    const yy = H - bottom - h;
    const path = h > 0 ? `M${x},${H - bottom} V${yy + r} Q${x},${yy} ${x + r},${yy} H${x + bw - r} Q${x + bw},${yy} ${x + bw},${yy + r} V${H - bottom} Z` : '';
    return `<g data-m="${m}" style="cursor:pointer"><rect x="${x - gap / 2}" y="0" width="${bw + gap}" height="${H}" fill="transparent"/>
      <path d="${path}" fill="${m === sel ? 'var(--jade)' : 'var(--jade-soft)'}"/>
      <text x="${x + bw / 2}" y="${H - 6}" text-anchor="middle" font-size="11" fill="${m === sel ? 'var(--ink)' : 'var(--faint)'}" font-weight="${m === sel ? 600 : 400}">${+m.slice(5)}月</text></g>`;
  }).join('');
  return `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="近 12 个月每月支出">${grid}<line x1="0" x2="${W}" y1="${H - bottom}" y2="${H - bottom}" stroke="var(--rule-strong)"/>${bars}</svg><div class="tip" hidden></div>`;
}
function niceMax(v) { const p = 10 ** Math.floor(Math.log10(v)); const n = v / p; return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * p; }
function bindTrend() {
  const box = $('#trend'); if (!box) return;
  const tip = box.querySelector('.tip');
  box.querySelectorAll('g[data-m]').forEach((g) => {
    g.addEventListener('pointerenter', () => {
      const m = g.dataset.m; const r = g.querySelector('path').getBoundingClientRect(); const b = box.getBoundingClientRect();
      tip.hidden = false; tip.textContent = `${monthLabel(m)}  ${money(S.L.monthExp[m] || 0)}`;
      tip.style.left = Math.min(Math.max(r.left - b.left + r.width / 2, 70), b.width - 70) + 'px'; tip.style.top = Math.max(r.top - b.top - 6, 14) + 'px';
    });
    g.addEventListener('pointerleave', () => (tip.hidden = true));
    g.addEventListener('click', () => { S.month = g.dataset.m; S.period = 'month'; render(); });
  });
}

// ---------------------------------------------------------------------
// 报表
// ---------------------------------------------------------------------
function netWorthSeries(L) {
  if (L._nw) return L._nw;
  const bal = {};
  const out = [];
  const first = L.txns.find((t) => !t.synthetic)?.date;
  if (!first) return (L._nw = []);
  let m = ym(first);
  const end = ym(today());
  let i = 0;
  const monthEnd = (mm) => shiftDay(addMonth(mm, 1) + '-01', -1);
  while (m <= end) {
    const last = monthEnd(m);
    while (i < L.txns.length && L.txns[i].date <= last) {
      for (const p of L.txns[i].postings) if (p.units != null && /^(Assets|Liabilities):/.test(p.account)) { const k = p.account.split(':')[0]; (bal[k] ||= {}); bal[k][p.currency] = (bal[k][p.currency] || 0) + p.units; }
      i++;
    }
    const at = last > today() ? today() : last;
    const sum = (k) => Object.entries(bal[k] || {}).reduce((s, [c, n]) => s + (toCNY(L, n, c, at) ?? 0), 0);
    out.push({ m, assets: sum('Assets'), liab: sum('Liabilities'), nw: sum('Assets') + sum('Liabilities') });
    m = addMonth(m, 1);
  }
  return (L._nw = out);
}

function lineSVG(pts, W, sel) {
  const H = 200, top = 16, bottom = 24, left = 4, right = 56;
  const vals = pts.map((p) => p.v);
  let lo = Math.min(0, ...vals), hi = Math.max(0, ...vals);
  const span = niceMax(Math.max(1, hi - lo) / 4);
  lo = Math.floor(lo / span) * span; hi = Math.ceil(hi / span) * span;
  const x = (i) => left + (W - left - right) * (pts.length > 1 ? i / (pts.length - 1) : 0.5);
  const y = (v) => top + (H - top - bottom) * (1 - (v - lo) / (hi - lo || 1));
  const ticks = []; for (let v = lo; v <= hi + 1e-9; v += span) ticks.push(v);
  const grid = ticks.map((v) => `<line x1="${left}" x2="${W - right}" y1="${y(v)}" y2="${y(v)}" stroke="${v === 0 ? 'var(--rule-strong)' : 'var(--rule)'}" ${v === 0 ? '' : 'stroke-dasharray="2 4"'}/><text class="val" x="${W - right + 6}" y="${y(v) + 4}" font-size="11" fill="var(--faint)">${fmtNum(v / 1000, 0)}k</text>`).join('');
  const path = pts.map((p, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(p.v).toFixed(1)}`).join('');
  const nearJan = (i) => pts.slice(i + 1, i + 4).some((q) => q.m.endsWith('-01'));
  const labels = pts.map((p, i) => ((i === 0 && !nearJan(0)) || (p.m.endsWith('-01') && i > 0) || i === pts.length - 1) && (i === pts.length - 1 || pts.length - 1 - i > 3) ? `<text x="${x(i)}" y="${H - 6}" font-size="11" text-anchor="${i === 0 ? 'start' : i === pts.length - 1 ? 'end' : 'middle'}" fill="var(--faint)">${p.m.endsWith('-01') && i ? p.m.slice(0, 4) : `${p.m.slice(2, 4)}/${+p.m.slice(5)}`}</text>` : '').join('');
  const lastP = pts[pts.length - 1];
  return `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="每月月末净资产">${grid}${labels}
    <path d="${path}" fill="none" stroke="var(--jade)" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>
    ${lastP ? `<circle cx="${x(pts.length - 1)}" cy="${y(lastP.v)}" r="4" fill="var(--jade)" stroke="var(--sheet)" stroke-width="2"/>` : ''}
    <line class="xh" x1="0" x2="0" y1="${top}" y2="${H - bottom}" stroke="var(--muted)" stroke-width="1" opacity="0"/>
    <circle class="xd" r="4" fill="var(--jade)" stroke="var(--sheet)" stroke-width="2" opacity="0"/>
    <rect class="hit" x="${left}" y="0" width="${W - left - right}" height="${H}" fill="transparent"/></svg><div class="tip" hidden></div>`;
}

function drawLine(boxId, pts, fmt) {
  const box = document.getElementById(boxId); if (!box || !pts.length) return;
  const W = Math.max(280, box.clientWidth - 24);
  box.innerHTML = lineSVG(pts, W);
  const svg = box.querySelector('svg'), tip = box.querySelector('.tip'), xh = svg.querySelector('.xh'), xd = svg.querySelector('.xd');
  const left = 4, right = 56, H = 200, top = 16, bottom = 24;
  const vals = pts.map((p) => p.v);
  let lo = Math.min(0, ...vals), hi = Math.max(0, ...vals);
  const span = niceMax(Math.max(1, hi - lo) / 4); lo = Math.floor(lo / span) * span; hi = Math.ceil(hi / span) * span;
  const move = (ev) => {
    const r = svg.getBoundingClientRect();
    const px = (ev.clientX - r.left) * (W / r.width);
    const i = Math.max(0, Math.min(pts.length - 1, Math.round(((px - left) / (W - left - right)) * (pts.length - 1))));
    const cx = left + (W - left - right) * (pts.length > 1 ? i / (pts.length - 1) : 0.5);
    const cy = top + (H - top - bottom) * (1 - (pts[i].v - lo) / (hi - lo || 1));
    xh.setAttribute('x1', cx); xh.setAttribute('x2', cx); xh.setAttribute('opacity', 0.5);
    xd.setAttribute('cx', cx); xd.setAttribute('cy', cy); xd.setAttribute('opacity', 1);
    tip.hidden = false; tip.textContent = fmt(pts[i]);
    tip.style.left = Math.min(Math.max(cx * (r.width / W) + 12, 80), r.width - 80) + 'px'; tip.style.top = Math.max(cy * (r.height / H) + 8, 20) + 'px';
  };
  const leave = () => { tip.hidden = true; xh.setAttribute('opacity', 0); xd.setAttribute('opacity', 0); };
  svg.addEventListener('pointermove', move); svg.addEventListener('pointerdown', move); svg.addEventListener('pointerleave', leave);
}

function renderReports() {
  const L = S.L;
  const nw = netWorthSeries(L);
  const lastNW = nw[nw.length - 1];
  const yearAgo = nw[nw.length - 13];
  // balance sheet at a date
  const years = [...new Set(L.txns.map((t) => t.date.slice(0, 4)))].sort();
  const bsDate = S.bsDate || today();
  const bs = {};
  for (const t of L.txns) { if (t.date > bsDate) break; for (const p of t.postings) if (p.units != null && /^(Assets|Liabilities):/.test(p.account)) { const k = p.account.split(':').slice(0, 2).join(':'); (bs[k] ||= {}); bs[k][p.account] = bs[k][p.account] || {}; bs[k][p.account][p.currency] = (bs[k][p.account][p.currency] || 0) + p.units; } }
  const cnyOf = (o) => Object.entries(o).reduce((s, [c, n]) => s + (toCNY(L, n, c, bsDate) ?? 0), 0);
  const bsGroups = Object.entries(bs).map(([g, accts]) => ({ g, total: Object.values(accts).reduce((s, o) => s + cnyOf(o), 0), accts: Object.entries(accts).map(([a, o]) => ({ a, v: cnyOf(o) })).filter((x) => Math.abs(x.v) > 0.5).sort((a, b) => Math.abs(b.v) - Math.abs(a.v)) })).filter((x) => x.accts.length);
  const side = (root) => bsGroups.filter((x) => x.g.startsWith(root)).sort((a, b) => Math.abs(b.total) - Math.abs(a.total));
  const totA = side('Assets').reduce((s, x) => s + x.total, 0), totL = side('Liabilities').reduce((s, x) => s + x.total, 0);
  // yearly income / expenses and categories
  const yr = {};
  for (const t of L.txns) for (const p of t.postings) {
    if (p.units == null || !/^(Income|Expenses):/.test(p.account)) continue;
    const y = t.date.slice(0, 4); const v = toCNY(L, p.units, p.currency, t.date) ?? 0;
    (yr[y] ||= { inc: 0, exp: 0, cat: {} });
    if (p.account.startsWith('Income')) yr[y].inc -= v; else { yr[y].exp += v; const g = catOf(p.account); yr[y].cat[g] = (yr[y].cat[g] || 0) + v; }
  }
  const ys = Object.keys(yr).sort();
  const cats = [...new Set(ys.flatMap((y) => Object.keys(yr[y].cat)))].sort((a, b) => (yr[ys.at(-1)].cat[b] || 0) - (yr[ys.at(-1)].cat[a] || 0));
  const curY = today().slice(0, 4), mNow = +today().slice(5, 7);
  main.innerHTML = `<div class="view">${topbar('报表')}
    <div class="sheet hero">
      <div class="label">净资产（折合人民币）</div>
      <div class="big num"><small>¥</small>${fmtNum(lastNW?.nw ?? 0)}</div>
      <div class="compare"><span>资产 <b class="num">${money(lastNW?.assets ?? 0)}</b></span><span>负债 <b class="num">${money(lastNW?.liab ?? 0)}</b></span>${yearAgo ? `<span>一年前 <b class="num">${money(yearAgo.nw)}</b>，变化 <b class="num ${lastNW.nw - yearAgo.nw >= 0 ? 'pos' : 'bad'}">${signed(lastNW.nw - yearAgo.nw, 'CNY')}</b></span>` : ''}</div>
    </div>
    <div class="section"><h2>净资产走势</h2><span class="aside">每月月末</span></div>
    <div class="sheet chart" id="nwchart"></div>

    <div class="section"><h2>年度收支</h2><span class="aside">${curY} 年截至 ${mNow} 月</span></div>
    <div class="sheet tablewrap"><table class="rtable">
      <thead><tr><th></th>${ys.map((y) => `<th>${y}</th>`).join('')}</tr></thead>
      <tbody>
        <tr><th>收入</th>${ys.map((y) => `<td class="num pos">${fmtNum(yr[y].inc, 0)}</td>`).join('')}</tr>
        <tr><th>支出</th>${ys.map((y) => `<td class="num">${fmtNum(yr[y].exp, 0)}</td>`).join('')}</tr>
        <tr><th>结余</th>${ys.map((y) => `<td class="num ${yr[y].inc - yr[y].exp < 0 ? 'bad' : ''}">${fmtNum(yr[y].inc - yr[y].exp, 0)}</td>`).join('')}</tr>
        <tr><th>储蓄率</th>${ys.map((y) => `<td class="num">${yr[y].inc > 0 ? Math.round(((yr[y].inc - yr[y].exp) / yr[y].inc) * 100) + '%' : '—'}</td>`).join('')}</tr>
        <tr><th>月均支出</th>${ys.map((y) => `<td class="num">${fmtNum(yr[y].exp / (y === curY ? mNow : 12), 0)}</td>`).join('')}</tr>
      </tbody></table></div>

    <div class="section"><h2>支出分类对比</h2><span class="aside">按今年排序</span></div>
    <div class="sheet tablewrap"><table class="rtable">
      <thead><tr><th></th>${ys.map((y) => `<th>${y}</th>`).join('')}</tr></thead>
      <tbody>${cats.map((g) => `<tr><th>${esc(catLabel(g))} <span class="muted small">${esc(leaf(g))}</span></th>${ys.map((y) => `<td class="num">${yr[y].cat[g] ? fmtNum(yr[y].cat[g], 0) : '—'}</td>`).join('')}</tr>`).join('')}</tbody></table></div>

    <div class="section"><h2>资产负债表</h2><span class="aside">截至 ${esc(bsDate)}</span></div>
    <div class="chips" style="margin-bottom:10px">${[['今天', today()], ...years.slice(0, -1).reverse().map((y) => [`${y} 年末`, `${y}-12-31`])].map(([l, d]) => `<button class="chip" data-bs-date="${d}" aria-pressed="${bsDate === d}">${l}</button>`).join('')}</div>
    <div class="grid2">
      ${[['Assets', '资产', totA], ['Liabilities', '负债', totL]].map(([root, label, tot]) => `<div><div class="sheet">
        <div class="kv"><b>${label}</b><b class="num">${money(tot)}</b></div>
        ${side(root).map((x) => `<div class="kv bs-g"><span>${esc(ZH[x.g.split(':')[1]] || x.g.split(':')[1])}</span><span class="num">${money(x.total)}</span></div>${x.accts.map((a) => `<button class="kv bs-a" data-goto-acct="${esc(a.a)}"><span>${esc(a.a.split(':').slice(2).join(':') || leaf(a.a))}</span><span class="num muted">${money(a.v)}</span></button>`).join('')}`).join('')}
      </div></div>`).join('')}
    </div>
    <div class="sheet" style="margin-top:12px"><div class="kv"><b>净资产</b><b class="num">${money(totA + totL)}</b></div></div>
  </div>`;
  drawLine('nwchart', nw.map((p) => ({ m: p.m, v: p.nw })), (p) => `${monthLabel(p.m)}  ${money(p.v)}`);
}

// ---------------------------------------------------------------------
// 流水
// ---------------------------------------------------------------------
function matchTxn(t, q) {
  if (!q) return true;
  return q.split(/\s+/).every((w) => {
    if (w === '!') return t.flag === '!';
    if (w.startsWith('#')) return t.tags.some((x) => x.includes(w.slice(1)));
    if (w.startsWith('^')) return t.links.some((x) => x.includes(w.slice(1)));
    if (/^[<>]?\d+(\.\d+)?$/.test(w)) {
      const n = Number(w.replace(/^[<>]/, ''));
      const amts = t.postings.map((p) => Math.abs(p.units));
      if (w[0] === '>') return amts.some((a) => a > n);
      if (w[0] === '<') return amts.every((a) => a < n);
      return amts.some((a) => Math.abs(a - n) < 0.005) || t.date.includes(w);
    }
    if (/^\d{4}-\d{2}(-\d{2})?$/.test(w)) return t.date.startsWith(w);
    const lw = w.toLowerCase();
    return (t.payee + ' ' + t.narration).toLowerCase().includes(lw) || t.postings.some((p) => p.account.toLowerCase().includes(lw) || acctLabel(p.account).includes(w));
  });
}

function renderJournal() {
  const s = S.search;
  main.innerHTML = `<div class="view">${topbar('流水')}
    <div class="searchbar"><input id="q" type="search" placeholder="搜索商户、说明、账户、#标签、^链接、金额、2026-09" value="${esc(s.q)}" autocomplete="off">
      <div class="chips">${s.account ? `<button class="chip" aria-pressed="true" data-clear="account">${esc(acctLabel(s.account))}<span class="x">✕</span></button>` : ''}
      ${s.month ? `<button class="chip" aria-pressed="true" data-clear="month">${monthLabel(s.month)}<span class="x">✕</span></button>` : ''}
      ${['#reimbursed', '#refund', '#transfer', '#fx', '!'].map((x) => `<button class="chip" data-q="${x}">${x === '!' ? '! 待确认' : x}</button>`).join('')}</div></div>
    <div id="results"></div></div>`;
  renderJournalResults();
}

function renderJournalResults() {
  const box = $('#results'); if (!box) return;
  const s = S.search; const L = S.L;
  const list = [];
  for (let i = L.txns.length - 1; i >= 0; i--) {
    const t = L.txns[i];
    if (s.month && ym(t.date) !== s.month) continue;
    if (s.account && !t.postings.some((p) => p.account === s.account || p.account.startsWith(s.account + ':'))) continue;
    if (!matchTxn(t, s.q.trim())) continue;
    list.push(t);
  }
  let out = 0, inn = 0;
  for (const t of list) { const c = classify(t); if (c.kind === 'expense' || c.kind === 'refund') out -= c.amount; else if (c.kind === 'income') inn += c.amount; }
  const shown = list.slice(0, s.limit);
  let html = `<div class="sumline"><span>${list.length} 笔</span><span class="num">${out ? `支出 ${money(out)}` : ''}${inn ? `　收入 ${money(inn)}` : ''}</span></div><div class="ledger">`;
  let last = '';
  for (const t of shown) {
    if (t.date !== last) {
      const dayOut = shown.filter((x) => x.date === t.date).reduce((sum, x) => { const c = classify(x); return sum + (c.kind === 'expense' || c.kind === 'refund' ? -c.amount : 0); }, 0);
      html += `<div class="day"><span>${dayLabel(t.date)}${t.date.slice(0, 4) !== today().slice(0, 4) ? ' ' + t.date.slice(0, 4) : ''}</span><span class="num">${dayOut ? money(dayOut) : ''}</span></div>`;
      last = t.date;
    }
    html += txRow(t, { account: s.account });
  }
  if (!shown.length) html += '<div class="empty">没有找到匹配的交易</div>';
  html += '</div>';
  if (list.length > shown.length) html += `<div style="text-align:center;margin:16px"><button class="btn" data-act="more">再显示 ${Math.min(200, list.length - shown.length)} 笔</button></div>`;
  box.innerHTML = html;
}

// ---------------------------------------------------------------------
// 账户
// ---------------------------------------------------------------------
function renderAccounts() {
  if (S.acctView === '__holdings') return renderHoldings();
  if (S.acctView) return renderRegister(S.acctView);
  const L = S.L; const fin = L.final;
  const groups = [['Assets', '资产'], ['Liabilities', '负债']];
  const year = today().slice(0, 4);
  let html = `<div class="view">${topbar('账户', `<label class="toggle" style="font-size:13px;color:var(--muted)"><input type="checkbox" data-act="closed" ${S.showClosed ? 'checked' : ''}>显示已关闭/为零</label>`)}`;
  const hs = holdings();
  if (hs.length) {
    const v = hs.reduce((s, r) => s + (toCNY(L, r.value ?? r.cost, r.q) ?? 0), 0), c = hs.reduce((s, r) => s + (toCNY(L, r.cost, r.q) ?? 0), 0);
    html += `<div class="acct-group"><div class="sheet"><button class="acct-row" data-goto-acct="__holdings"><span class="n"><b>持仓</b> <span>${hs.map((r) => esc(r.c)).filter((x, i, a) => a.indexOf(x) === i).join('、')}</span></span><span class="v num"><div>${money(v)}</div><div class="${v - c >= 0 ? 'pos' : 'bad'}">${signed(v - c, 'CNY')}</div></span></button></div></div>`;
  }
  for (const [g, label] of groups) {
    const accts = Object.keys(L.accounts).filter((a) => a.startsWith(g + ':')).sort();
    let total = 0;
    const rows = accts.map((a) => {
      const cs = Object.entries(fin[a] || {}).filter(([, n]) => Math.abs(n) > 0.0049);
      const closed = L.accounts[a].close && L.accounts[a].close <= today();
      if (!S.showClosed && (closed || !cs.length)) return '';
      cs.forEach(([c, n]) => (total += toCNY(L, n, c) ?? 0));
      const fails = L.balanceResults.filter((r) => !r.ok && r.entry.account === a).length;
      const p = a.split(':');
      return `<button class="acct-row ${closed ? 'closed' : ''}" data-goto-acct="${esc(a)}"><span class="n">${esc(p.slice(2).join(':') || p[1])} <span>${esc(ZH[p[1]] ?? p[1])}</span>${fails ? '<span class="tag warn">断言失败</span>' : ''}</span>
        <span class="v num">${cs.length ? cs.map(([c, n]) => `<div>${money(n, c, Math.abs(n) < 1 && c.length > 3 ? 4 : 2)}</div>`).join('') : '<div class="muted">0</div>'}</span></button>`;
    }).join('');
    html += `<div class="acct-group"><h3><span>${label}</span><span class="num">${money(total)}</span></h3><div class="sheet">${rows || '<div class="empty">—</div>'}</div></div>`;
  }
  // income / expense YTD
  const ytd = {};
  for (const t of L.txns) if (t.date.startsWith(year)) for (const p of t.postings) if (p.units != null && /^(Income|Expenses):/.test(p.account)) { const g = catOf(p.account); ytd[g] = (ytd[g] || 0) + (toCNY(L, p.units, p.currency, t.date) ?? 0); }
  const ie = Object.entries(ytd).sort((a, b) => Math.abs(b[1]) - Math.abs(a[1]));
  html += `<div class="acct-group"><h3><span>${year} 年收支科目</span></h3><div class="sheet">${ie.map(([g, v]) => `<button class="acct-row" data-goto-acct="${esc(g)}"><span class="n">${esc(catLabel(g))} <span>${esc(g)}</span></span><span class="v num ${v < 0 ? 'pos' : ''}">${money(-v)}</span></button>`).join('')}</div></div>`;
  main.innerHTML = html + '</div>';
}

function latestPrice(L, c, quote) {
  let best = null;
  for (const p of L.prices) if (p.currency === c && p.quote === quote && (!best || p.date >= best.date)) best = p;
  return best;
}

function holdings() {
  const L = S.L;
  const rows = [];
  for (const [acct, lots] of Object.entries(L.inventory || {})) {
    const byC = {};
    for (const l of lots) if (l.cost && Math.abs(l.units) > 1e-9) (byC[l.currency + '|' + l.cost.currency] ||= []).push(l);
    for (const [k, ls] of Object.entries(byC)) {
      const [c, q] = k.split('|');
      const units = ls.reduce((s, l) => s + l.units, 0);
      const cost = ls.reduce((s, l) => s + l.units * l.cost.number, 0);
      const px = latestPrice(L, c, q);
      const value = px ? units * px.number : null;
      rows.push({ acct, c, q, units, cost, avg: cost / units, px, value, pnl: value != null ? value - cost : null, lots: ls.slice().sort((a, b) => (a.cost.date < b.cost.date ? -1 : 1)) });
    }
  }
  return rows.sort((a, b) => (b.value ?? b.cost) - (a.value ?? a.cost));
}

function renderHoldings() {
  const L = S.L;
  const rows = holdings();
  const cny = (n, c) => toCNY(L, n, c) ?? 0;
  const totV = rows.reduce((s, r) => s + cny(r.value ?? r.cost, r.q), 0);
  const totC = rows.reduce((s, r) => s + cny(r.cost, r.q), 0);
  const pnl = totV - totC;
  const year = today().slice(0, 4);
  const inv = {};
  for (const t of L.txns) for (const p of t.postings) if (p.units != null && p.account.startsWith('Income:Invest')) {
    const k = leaf(p.account); (inv[k] ||= { ytd: 0, all: 0 });
    const v = -(toCNY(L, p.units, p.currency, t.date) ?? 0); inv[k].all += v; if (t.date.startsWith(year)) inv[k].ytd += v;
  }
  const pxDate = rows.map((r) => r.px?.date).filter(Boolean).sort().pop();
  const ZHI = { Gain: '已实现收益', Dividend: '股息', Interest: '利息', StockAward: '股票奖励' };
  main.innerHTML = `<div class="view">
    <div class="topbar"><button class="iconbtn" data-act="back" aria-label="返回">${ICON.back}</button><h1>持仓</h1><span data-status>${statusHTML()}</span></div>
    <div class="sheet hero">
      <div class="label">市值合计（折合人民币）</div>
      <div class="big num"><small>¥</small>${fmtNum(totV)}</div>
      <div class="compare"><span>成本 <b class="num">${money(totC)}</b></span><span>浮动盈亏 <b class="num ${pnl >= 0 ? 'pos' : 'bad'}">${signed(pnl, 'CNY')}${totC ? `（${pnl >= 0 ? '+' : ''}${((pnl / totC) * 100).toFixed(1)}%）` : ''}</b></span>${pxDate ? `<span>价格日期 <b>${esc(pxDate)}</b></span>` : ''}</div>
    </div>
    <div class="section"><h2>持仓明细</h2><span class="aside">点开看每一批</span></div>
    <div class="sheet">${rows.map((r, i) => `
      <button class="hold" data-hold="${i}" aria-expanded="${!!S.expanded['h' + i]}">
        <span class="h-name"><b>${esc(r.c)}</b> <span class="muted">${esc(acctLabel(r.acct))}</span><br><span class="muted small num">${fmtNum(r.units, 4)} 股 · 均价 ${fmtNum(r.avg, 2)} ${esc(r.q)}${r.px ? ` · 现价 ${fmtNum(r.px.number, 2)}` : ' · 没有价格'}</span></span>
        <span class="h-val num">${r.value != null ? money(r.value, r.q) : money(r.cost, r.q)}<br>${r.pnl != null ? `<span class="${r.pnl >= 0 ? 'pos' : 'bad'} small">${signed(r.pnl, r.q)} ${r.cost ? `${r.pnl >= 0 ? '+' : ''}${((r.pnl / r.cost) * 100).toFixed(1)}%` : ''}</span>` : ''}</span>
      </button>
      ${S.expanded['h' + i] ? `<div class="lots">${r.lots.map((l) => `<div class="lot"><span>${esc(l.cost.date || '')}${l.cost.label ? ` · ${esc(l.cost.label)}` : ''}</span><span class="num">${fmtNum(l.units, 4)} × ${fmtNum(l.cost.number, 4)} ${esc(l.cost.currency)}</span><span class="num ${r.px ? (r.px.number >= l.cost.number ? 'pos' : 'bad') : ''}">${r.px ? signed(l.units * (r.px.number - l.cost.number), r.q) : ''}</span></div>`).join('')}
        <div class="lot"><button class="linkbtn" data-goto-acct="${esc(r.acct)}">查看 ${esc(acctLabel(r.acct))} 明细</button></div></div>` : ''}`).join('') || '<div class="empty">没有按成本记账的持仓</div>'}</div>
    ${Object.keys(inv).length ? `<div class="section"><h2>投资收入</h2><span class="aside">折合人民币</span></div>
    <div class="sheet"><div class="kv muted small"><span></span><span>${year} 年 · 累计</span></div>${Object.entries(inv).map(([k, v]) => `<button class="kv" data-goto-acct="Income:Invest:${esc(k)}"><span>${esc(ZHI[k] || k)}</span><span class="num">${money(v.ytd)} · ${money(v.all)}</span></button>`).join('')}</div>` : ''}
    <div class="help">市值用 prices.bean 里最新的价格计算；每天自动更新价格的工作流跑起来后会更准。</div>
  </div>`;
}

function renderRegister(acct) {
  const L = S.L;
  const items = [];
  const bal = {};
  for (const e of L.entries) {
    if (e.type === 'txn') {
      const ps = e.postings.filter((p) => p.account === acct || p.account.startsWith(acct + ':'));
      if (!ps.length) continue;
      ps.forEach((p) => { if (p.units != null) bal[p.currency] = (bal[p.currency] || 0) + p.units; });
      items.push({ t: e, bal: Object.entries(bal).filter(([, n]) => Math.abs(n) > 0.0049).map(([c, n]) => money(n, c)).join(' ') });
    } else if (e.type === 'balance' && (e.account === acct || e.account.startsWith(acct + ':'))) {
      items.push({ b: L.balanceResults.find((r) => r.entry === e) });
    } else if (e.type === 'document' && e.account === acct) items.push({ d: e });
  }
  const c = cfg();
  const docUrl = (p) => { const i = p.indexOf('/documents/'); return i >= 0 ? `https://github.com/${c.owner}/${c.repo}/blob/${c.branch}${p.slice(i)}` : null; };
  const shown = items.slice(-300).reverse();
  const isIE = /^(Income|Expenses)/.test(acct);
  main.innerHTML = `<div class="view">
    <div class="topbar"><button class="iconbtn" data-act="back" aria-label="返回">${ICON.back}</button><h1 style="font-size:18px">${esc(acctLabel(acct) || acct)}</h1><span data-status>${statusHTML()}</span></div>
    <div class="sheet hero" style="padding:18px 20px"><div class="label">${esc(acct)}${L.accounts[acct]?.close ? ` · 已于 ${esc(L.accounts[acct].close)} 关闭` : ''}</div>
      <div class="big num" style="font-size:32px">${Object.entries(bal).filter(([, n]) => Math.abs(n) > 0.0049).map(([cc, n]) => money(isIE ? -n : n, cc)).join('<br>') || '0.00'}</div>
      <div class="compare"><button class="linkbtn" data-goto-search="${esc(acct)}">在流水中搜索</button>${/^(Assets|Liabilities):/.test(acct) && !L.accounts[acct]?.close ? `<button class="linkbtn" data-check="${esc(acct)}">对账</button>` : ''}${acct.startsWith('Assets:Receivable') && L.unclaimed.length ? `<button class="linkbtn" data-reimb="__unclaimed">记报销到账</button>` : ''}</div></div>
    <div class="section"><h2>明细</h2><span class="aside">${items.length > 300 ? '最近 300 条' : items.length + ' 条'}</span></div>
    <div class="ledger">${shown.map((it) => {
      if (it.t) return txRow(it.t, { account: acct, bal: it.bal, showDate: true });
      if (it.b) { const r = it.b; const canEdit = r.entry.account === acct && /^(Assets|Liabilities):/.test(acct); return `<${canEdit ? 'button' : 'div'} class="assert ${r.ok ? '' : 'fail'}" ${canEdit ? `data-recheck="${esc(r.entry.date)}|${esc(r.entry.currency)}" title="点击修改这条断言"` : ''}><span>${esc(r.entry.date)} 余额断言 <span class="num">${money(r.entry.number, r.entry.currency)}</span></span><span>${r.ok ? '✓ 相符' : `✗ 实际 <span class="num">${money(r.got, r.entry.currency)}</span>`}</span></${canEdit ? 'button' : 'div'}>`; }
      if (it.d) { const u = docUrl(it.d.path); return `<div class="assert"><span>${esc(it.d.date)} 对账单</span>${u ? `<a href="${esc(u)}" target="_blank" rel="noopener">${esc(it.d.path.split('/').pop())}</a>` : esc(it.d.path.split('/').pop())}</div>`; }
      return '';
    }).join('') || '<div class="empty">没有记录</div>'}</div></div>`;
}

// ---------------------------------------------------------------------
// detail modal
// ---------------------------------------------------------------------
function openTx(id) {
  const t = S.L.txns[id]; if (!t) return;
  const c = cfg();
  const related = [...new Set(t.links.flatMap((l) => S.L.byLink[l] || []))].filter((x) => x !== t);
  const raw = t.src || rawText(t);
  const back = document.createElement('div'); back.className = 'modal-back';
  back.innerHTML = `<div class="modal" role="dialog" aria-modal="true" aria-label="交易详情">
    <h3>${esc(t.payee || t.narration || '交易')}</h3><div class="sub">${esc(t.date)}${t.payee && t.narration ? ' · ' + esc(t.narration) : ''}</div>
    <div class="chips" style="margin-top:8px">${t.tags.map((x) => `<span class="tag">#${esc(x)}</span>`).join('')}${t.links.map((x) => `<span class="tag">^${esc(x)}</span>`).join('')}</div>
    <div class="postings">${t.postings.map((p) => `<div><span>${esc(p.account)}</span><span class="num">${money(p.units, p.currency, Math.abs(p.units) < 1 && /\.\d{3}/.test(String(p.units)) ? 4 : 2)}${p.price ? ` <span class="muted">@ ${fmtNum(p.price.number, 4)} ${esc(p.price.currency)}</span>` : ''}${p.cost ? ` <span class="muted">{${fmtNum(p.cost.number, 4)} ${esc(p.cost.currency)}}</span>` : ''}${p.interpolated ? ' <span class="muted">(自动)</span>' : ''}</span></div>`).join('')}</div>
    ${Object.keys(t.meta).length ? `<div class="sub">${Object.entries(t.meta).map(([k, v]) => `${esc(k)}: ${esc(v)}`).join('<br>')}</div>` : ''}
    ${related.length ? `<div class="section" style="margin-top:16px"><h2>关联交易</h2><span class="aside">${related.length}</span></div><div class="ledger">${related.map((r) => txRow(r, { showDate: true })).join('')}</div>` : ''}
    <pre>${esc(window.innerWidth < 700 ? raw.replace(/ {3,}(?=-?\d)/g, '  ') : raw)}</pre>
    <div class="actions">
      ${t.synthetic ? '<span class="sub">这笔是 pad 自动补出来的，要改请改对应的 pad 或余额断言。</span>' : `<button class="btn small" data-edit="${t.id}">编辑</button>
      <button class="btn small" data-again="${t.id}">再记一笔</button>
      ${classify(t).kind === 'expense' ? `<button class="btn small" data-refund="${t.id}">记退款</button>` : ''}`}
      <button class="btn small" data-copy="${t.id}">复制文本</button>
      <a class="btn small" style="text-decoration:none;color:inherit" target="_blank" rel="noopener" href="https://github.com/${esc(c.owner)}/${esc(c.repo)}/blob/${esc(c.branch)}/${esc(t.file)}#L${t.line}">在 GitHub 打开</a>
      <button class="btn small" data-close style="margin-left:auto">关闭</button>
    </div></div>`;
  back.addEventListener('click', (e) => {
    if (e.target === back || e.target.closest('[data-close]')) { back.remove(); return; }
    if (e.target.closest('[data-edit]')) { back.remove(); startEdit(t); return; }
    const again = e.target.closest('[data-again]'), refund = e.target.closest('[data-refund]'), copy = e.target.closest('[data-copy]'), row = e.target.closest('[data-tx]');
    if (again) { navPush(); S.draft = draftFromTxn(t); S.draft.date = today(); back.remove(); go('add'); }
    if (refund) { navPush(); S.draft = refundDraft(t); attachHeader(S.draft); back.remove(); go('add'); }
    if (copy) { navigator.clipboard?.writeText(raw).then(() => toast('已复制')); }
    if (row) { back.remove(); openTx(+row.dataset.tx); }
  });
  const esc_ = (e) => { if (e.key === 'Escape') back.remove(); };
  document.addEventListener('keydown', esc_);
  new MutationObserver((_, ob) => { if (!back.isConnected) { document.removeEventListener('keydown', esc_); ob.disconnect(); } }).observe(document.body, { childList: true });
  document.body.appendChild(back);
  back.querySelector('[data-close]').focus();
}

// header line text of an existing txn (for adding a ^link to it)
function attachHeader(d) {
  if (!d.refundOf) return;
  const t = d.refundOf.t;
  readWithPending(t.file).then((text) => { d.refundOf.header = text.split('\n')[t.line - 1]; delete d.refundOf.t; });
}

function rawText(t) {
  const lines = [`${t.date} ${t.flag} "${t.payee}" "${t.narration}"${t.tags.map((x) => ' #' + x).join('')}${t.links.map((x) => ' ^' + x).join('')}`];
  for (const [k, v] of Object.entries(t.meta)) lines.push(`  ${k}: "${v}"`);
  for (const p of t.postings) {
    let s = p.interpolated ? '  ' + p.account : formatTxn({ date: '', payee: '', narration: '', postings: [{ account: p.account, units: p.units, currency: p.currency }] }).split('\n')[1];
    if (p.cost) s += ` {${p.cost.number} ${p.cost.currency}}`;
    if (p.price) s += p.price.total ? ` @@ ${p.price.raw} ${p.price.currency}` : ` @ ${p.price.number} ${p.price.currency}`;
    lines.push(s);
  }
  return lines.join('\n');
}

// ---------------------------------------------------------------------
// small modal helper
// ---------------------------------------------------------------------
function modal(build, onClick, onInput, onClose) {
  const back = document.createElement('div'); back.className = 'modal-back';
  const box = document.createElement('div'); box.className = 'modal'; box.setAttribute('role', 'dialog'); box.setAttribute('aria-modal', 'true');
  back.appendChild(box);
  const close = () => { back.remove(); document.removeEventListener('keydown', onKey); onClose?.(); };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  const draw = () => { box.innerHTML = build(); };
  draw();
  back.addEventListener('click', (e) => { if (e.target === back || e.target.closest('[data-close]')) { close(); return; } onClick?.(e, { close, draw, box }); });
  back.addEventListener('input', (e) => onInput?.(e, { close, draw, box }));
  document.addEventListener('keydown', onKey);
  document.body.appendChild(back);
  return { close, draw, box };
}

// 报销到账: either an existing ^reimburse-* link, or pick from unclaimed receivables
function openReimb(source) {
  const L = S.L;
  const fromLink = source !== '__unclaimed';
  const x = fromLink ? L.openLinks.find((o) => o.link === source) : null;
  if (fromLink && !x) return;
  const pool = fromLink ? [] : L.unclaimed;
  const past = L.txns.filter((t) => t.tags.includes('reimbursement'));
  const payees = [...new Set(past.map((t) => t.payee).filter(Boolean).reverse())].slice(0, 4);
  const accts = rankAccounts(['Assets:'], past.slice(-10).reverse().flatMap((t) => t.postings.filter((p) => p.units > 0).map((p) => p.account))).filter((a) => !a.startsWith('Assets:Receivable')).slice(0, 5);
  const shortfall = L.accounts['Expenses:Unreimbursed'] ? 'Expenses:Unreimbursed' : 'Expenses:Miscellaneous';
  const st = { date: today(), payee: payees[0] || '', amount: '', account: accts[0], link: fromLink ? source : '', linkTouched: fromLink, sel: new Set(pool.map((_, i) => i)) };
  const owed = () => fromLink ? x.amount : Math.round([...st.sel].reduce((s, i) => s + pool[i].amount, 0) * 100) / 100;
  const link = () => st.linkTouched ? st.link : `reimburse-work-${st.date.replace(/-/g, '')}`;
  const ccy = fromLink ? x.currency : 'CNY';
  const got = () => (st.amount === '' ? owed() : evalAmount(st.amount));
  const gen = () => {
    const g = got(), o = owed();
    if (!(g > 0) || !(o > 0) || !st.account) return '';
    const diff = Math.round((g - o) * 100) / 100;
    const ps = [{ account: 'Assets:Receivable:Reimbursement', units: -o, currency: ccy }];
    if (diff > 0.004) ps.push({ account: 'Income:ReimbExcess', units: -diff, currency: ccy });
    if (diff < -0.004) ps.push({ account: shortfall, units: -diff, currency: ccy });
    ps.push({ account: st.account, units: g, currency: ccy });
    const dm = /(\d{8})$/.exec(link());
    return formatTxn({ date: st.date, payee: st.payee, narration: `报销入账-${dm ? dm[1] : st.date.replace(/-/g, '')}`, tags: ['reimbursement'], links: [link()], postings: ps });
  };
  const preview = () => {
    const g = got(), diff = g - owed();
    return `${Math.abs(diff) > 0.004 && g > 0 ? `<div class="sub ${diff < 0 ? 'bad' : ''}">${diff > 0 ? `多收 ${money(diff, ccy)}，记入 Income:ReimbExcess` : `少收 ${money(-diff, ccy)}，记入 ${shortfall}`}</div>` : ''}
      <pre>${esc(compact(gen()))}</pre>
      ${!fromLink && st.sel.size ? `<div class="sub">选中的 ${st.sel.size} 笔会加上 <code>#reimbursed ^${esc(link())}</code></div>` : ''}`;
  };
  const items = fromLink ? (L.byLink[source] || []) : [];
  modal(() => `
    <h3>报销到账</h3>
    <div class="sub">${fromLink ? `^${esc(source)} · 待收 ${money(x.amount, ccy)}` : `选中 ${st.sel.size}/${pool.length} 笔，合计 <b data-owed>${money(owed())}</b>`}</div>
    ${fromLink ? '' : `<div class="picklist">${pool.map((it, i) => `<label class="pick"><input type="checkbox" data-pick-i="${i}" ${st.sel.has(i) ? 'checked' : ''}><span class="pd">${esc(it.t.date.slice(5))}</span><span class="pn">${esc([it.t.payee, it.t.narration].filter(Boolean).join(' '))}</span><span class="num">${money(it.amount)}</span></label>`).join('')}</div>
      <div class="chips" style="margin-top:6px"><button class="chip" data-sel="all">全选</button><button class="chip" data-sel="none">全不选</button></div>`}
    <div class="form" style="margin-top:8px">
      <div class="field"><label>到账日期</label><input type="date" data-r="date" value="${esc(st.date)}"></div>
      ${fromLink ? '' : `<div class="field"><label>关联</label><input data-r="link" value="${esc(link())}" autocomplete="off"></div>`}
      <div class="field"><label>付款方</label><div><input data-r="payee" value="${esc(st.payee)}" placeholder="例如 公司名称" autocomplete="off"><div class="chips">${payees.map((p) => `<button class="chip" data-rset="payee" data-val="${esc(p)}" aria-pressed="${st.payee === p}">${esc(p)}</button>`).join('')}</div></div></div>
      <div class="field"><label>到账金额</label><input data-r="amount" inputmode="decimal" value="${esc(st.amount)}" placeholder="${fmtNum(owed())}"></div>
      <div class="field"><label>到账账户</label><div class="chips">${accts.map((a) => `<button class="chip" data-rset="account" data-val="${esc(a)}" aria-pressed="${st.account === a}">${esc(acctLabel(a))}</button>`).join('')}</div></div>
    </div>
    <div data-preview>${preview()}</div>
    ${items.length ? `<details class="sub"><summary>包含的交易</summary><div class="ledger" style="margin-top:8px">${items.map((t) => txRow(t, { showDate: true })).join('')}</div></details>` : ''}
    <div class="actions"><button class="btn primary" data-rsave>记到账</button><button class="btn" data-close>取消</button></div>`,
  async (e, m) => {
    const set = e.target.closest('[data-rset]');
    if (set) { st[set.dataset.rset] = set.dataset.val; m.draw(); return; }
    const sel = e.target.closest('[data-sel]');
    if (sel) { st.sel = sel.dataset.sel === 'all' ? new Set(pool.map((_, i) => i)) : new Set(); m.draw(); return; }
    if (e.target.closest('[data-rsave]')) {
      const text = gen(); if (!text) { toast('请选择垫付并填写到账账户'); return; }
      const lk = link();
      // tag the claimed items
      for (const i of st.sel) {
        const t = pool[i].t;
        const header = (await readWithPending(t.file)).split('\n')[t.startLine];
        S.pending.push({ kind: 'link', path: t.file, line: t.startLine + 1, header, add: ' #reimbursed ^' + lk, silent: true });
      }
      if (!queueInsert(text, { label: `报销到账：^${lk}${st.sel.size ? ` ${st.sel.size} 笔` : ''}` })) return;
      m.close(); await commitQueued('已记');
    }
  },
  (e, m) => {
    if (e.target.dataset.pickI != null) { const i = +e.target.dataset.pickI; e.target.checked ? st.sel.add(i) : st.sel.delete(i); m.box.querySelector('.sub').innerHTML = `选中 ${st.sel.size}/${pool.length} 笔，合计 <b>${money(owed())}</b>`; m.box.querySelector('[data-r=amount]').placeholder = fmtNum(owed()); }
    const k = e.target.dataset.r;
    if (k) { st[k] = e.target.value; if (k === 'link') st.linkTouched = true; if (k === 'date' && !st.linkTouched && m.box.querySelector('[data-r=link]')) m.box.querySelector('[data-r=link]').value = link(); }
    m.box.querySelector('[data-preview]').innerHTML = preview();
  });
}

const compact = (t) => (window.innerWidth < 700 ? t.replace(/ {3,}(?=-?\d)/g, '  ') : t);

// 余额对账
function openCheck(acct, preset = {}) {
  const L = S.L;
  const ccys = [...new Set([...Object.keys(L.final[acct] || {}).filter((c) => Math.abs(L.final[acct][c]) > 0.0049), L.acctCcy[acct] || 'CNY'])];
  const files = {}; L.balances.forEach((b) => (files[b.file] = (files[b.file] || 0) + 1));
  const balFile = Object.entries(files).sort((a, b) => b[1] - a[1])[0]?.[0] || 'accounts/balance.bean';
  const st = { date: preset.date || shiftDay(today(), 1), currency: preset.currency || ccys[0], actual: preset.actual ?? '', armed: false };
  if (preset.currency && !ccys.includes(preset.currency)) ccys.push(preset.currency);
  const bookAt = () => { let n = 0; for (const t of L.txns) { if (t.date >= st.date) break; for (const p of t.postings) if ((p.account === acct || p.account.startsWith(acct + ':')) && p.currency === st.currency) n += p.units; } return Math.round(n * 100) / 100; };
  const info = () => {
    const book = bookAt(); const a = evalAmount(st.actual);
    const line = Number.isFinite(a) ? balanceLine(st.date, acct, a, st.currency) : '';
    const diff = Number.isFinite(a) ? Math.round((a - book) * 100) / 100 : null;
    return `<div class="kv"><span>账本余额（${esc(st.date)} 之前）</span><span class="num">${money(book, st.currency)}</span></div>
      ${diff != null ? `<div class="kv"><span>差额</span><span class="num ${Math.abs(diff) > 0.004 ? 'bad' : 'pos'}">${Math.abs(diff) > 0.004 ? signed(diff, st.currency) + '，先补记漏掉的交易' : '✓ 一致'}</span></div>` : ''}
      ${old() ? `<div class="kv warnrow"><span>⚠ ${esc(st.date)} 已有断言</span><span class="num">${money(old().entry.number, st.currency)}（${old().ok ? '相符' : '不符'}）</span></div>` : ''}
      ${line ? `<pre>${esc(compact(line))}</pre><div class="sub">${old() ? `会覆盖 ${esc(old().entry.file)} 里原来那一行。` : `写入 ${esc(balFile)}，放在这个账户已有断言的后面。`}</div>` : ''}`;
  };
  const old = () => existingBalance(acct, st.date, st.currency);
  const saveLabel = () => (old() ? (st.armed ? '再点一次确认覆盖' : '覆盖原断言') : '写入断言');
  modal(() => `
    <h3>对账</h3><div class="sub">${esc(acct)}</div>
    <div class="form" style="margin-top:12px">
      <div class="field"><label>实际余额</label><div class="amtwrap"><button class="pm" data-cneg aria-label="正负号">±</button><input data-c="actual" inputmode="decimal" placeholder="${acct.startsWith('Liabilities') ? '负债填负数，如 -1200' : '银行 App 里看到的余额'}" value="${esc(st.actual)}"></div></div>
      ${ccys.length > 1 ? `<div class="field"><label>币种</label><div class="chips">${ccys.map((c) => `<button class="chip" data-cset="currency" data-val="${c}" aria-pressed="${st.currency === c}">${c}</button>`).join('')}</div></div>` : ''}
      <div class="field"><label>断言日期</label><div><input type="date" data-c="date" value="${esc(st.date)}"><div class="sub">Beancount 在当天开始时检查，所以填明天 = 核对今天日终余额。</div></div></div>
    </div>
    <div class="sheet" data-info style="margin-top:12px;padding:4px 0">${info()}</div>
    <div class="actions"><button class="btn primary ${old() ? 'danger-fill' : ''}" data-csave>${saveLabel()}</button><button class="btn" data-close>取消</button></div>`,
  async (e, m) => {
    const set = e.target.closest('[data-cset]');
    if (set) { st[set.dataset.cset] = set.dataset.val; st.armed = false; m.draw(); return; }
    if (e.target.closest('[data-cneg]')) {
      const a = String(st.actual).trim(); st.actual = a.startsWith('-') ? a.slice(1) : '-' + a; st.armed = false;
      const inp = m.box.querySelector('[data-c=actual]'); inp.value = st.actual; inp.focus();
      m.box.querySelector('[data-info]').innerHTML = info();
      const b = m.box.querySelector('[data-csave]'); b.textContent = saveLabel(); b.classList.toggle('danger-fill', !!old());
      return;
    }
    if (e.target.closest('[data-csave]')) {
      const a = evalAmount(st.actual); if (!Number.isFinite(a)) { toast('请填写实际余额'); return; }
      const line = balanceLine(st.date, acct, a, st.currency);
      const o = old();
      if (o && !st.armed) { st.armed = true; e.target.closest('[data-csave]').textContent = saveLabel(); return; }
      S.pending.push({ kind: 'balance', path: o ? o.entry.file : balFile, account: acct, date: st.date, currency: st.currency, replace: !!o, line, label: `${o ? '覆盖对账' : '对账'}：${acct} ${st.date}` });
      m.close(); await commitQueued(o ? '已改' : '已对');
    }
  },
  (e, m) => {
    const k = e.target.dataset.c; if (!k) return;
    st[k] = e.target.value; st.armed = false;
    m.box.querySelector('[data-info]').innerHTML = info();
    const b = m.box.querySelector('[data-csave]'); b.textContent = saveLabel(); b.classList.toggle('danger-fill', !!old());
  });
}

// ---------------------------------------------------------------------
// 设置
// ---------------------------------------------------------------------
function renderSettings(first) {
  const c = cfg() || { token: '', owner: 'iskerwin', repo: 'ledger', branch: 'main' };
  const L = S.L;
  const funds = L ? rankAccounts(['Assets:', 'Liabilities:CreditCard']).filter((x) => !x.startsWith('Assets:Receivable')).slice(0, 12) : [];
  main.innerHTML = `<div class="view settings">
    ${first ? `<div class="welcome"><h1>Ledger</h1><p class="muted">连接你在 GitHub 上的 Beancount 仓库。账目只在你的设备和 GitHub 之间传输。</p>` : `<div class="topbar">${!first ? `<button class="iconbtn" data-act="back-tab" aria-label="返回">${ICON.back}</button>` : ''}<h1>设置</h1><span data-status>${statusHTML()}</span></div>`}
    <form class="sheet form" id="cfg">
      <div class="field"><label for="c-token">Token</label><input id="c-token" name="token" type="password" value="${esc(c.token)}" placeholder="github_pat_…" autocomplete="off" required></div>
      <div class="field"><label for="c-owner">用户</label><input id="c-owner" name="owner" value="${esc(c.owner)}" required></div>
      <div class="field"><label for="c-repo">仓库</label><input id="c-repo" name="repo" value="${esc(c.repo)}" required></div>
      <div class="field"><label for="c-branch">分支</label><input id="c-branch" name="branch" value="${esc(c.branch)}" required></div>
      <div class="field"><label></label><div><button class="btn primary" type="submit">${first ? '连接' : '保存并重新加载'}</button></div></div>
    </form>
    <div class="help">需要一个 <a href="https://github.com/settings/personal-access-tokens/new" target="_blank" rel="noopener">fine-grained token</a>：
      <ol><li>Repository access 选 Only select repositories → 你的账本仓库</li><li>Permissions → Contents 设为 Read and write</li><li>生成后粘贴到上面。Token 只保存在这台设备的浏览器里。</li></ol></div>
    ${first ? '</div>' : ''}
    ${L ? `
    <div class="section"><h2>默认付款账户</h2></div>
    <div class="sheet form"><div class="field"><label>账户</label><div class="chips">${funds.map((a) => `<button class="chip" data-default-fund="${esc(a)}" aria-pressed="${LS.get('defaultFunding') === a}">${esc(acctLabel(a))}</button>`).join('')}</div></div></div>
    ${Object.keys(LS.get('cardMap', {})).length || Object.keys(LS.get('merchantMap', {})).length ? `<div class="section"><h2>Apple Pay 对应关系</h2><span class="aside"><button class="linkbtn bad" data-act="reset-maps">清空</button></span></div>
    <div class="sheet">${Object.entries(LS.get('cardMap', {})).map(([k, v]) => `<div class="kv"><span>卡：${esc(k)}</span><span class="muted">${esc(v)}</span></div>`).join('')}${Object.entries(LS.get('merchantMap', {})).map(([k, v]) => `<div class="kv"><span>商户：${esc(k)}</span><span class="muted">${esc(v)}</span></div>`).join('')}</div>` : ''}
    <div class="section"><h2>待同步</h2><span class="aside">${S.pending.length} 项</span></div>
    <div class="sheet errlist">${S.pending.map((o, i) => `<div class="kv"><span>${o.failed ? `<span class="bad">${esc(o.failed)}</span><br>` : ''}${o.kind === 'insert' ? esc(o.date + ' ' + o.summary) : o.kind === 'link' ? '给原交易加 ^' + esc(o.link) : o.kind === 'include' ? '在 main.bean 加 include' : esc(o.label || o.kind)}</span><button class="linkbtn bad" data-drop="${i}">删除</button></div>`).join('') || '<div class="empty">没有待同步的内容</div>'}</div>
    ${S.syncError ? `<div class="help bad">上次同步出错：${esc(S.syncError)}</div>` : ''}
    <div class="section"><h2>账本检查</h2><span class="aside">${L.balanceResults.filter((r) => r.ok).length}/${L.balanceResults.length} 余额断言通过</span></div>
    <div class="sheet" style="margin-bottom:8px">${S.ci?.url ? `<a class="kv" href="${esc(S.ci.url)}" target="_blank" rel="noopener"><span>${ciHTML()}</span></a>` : `<div class="kv"><span>${ciHTML()}</span></div>`}</div>
    <div class="sheet errlist">${L.errors.map((e) => e.entry.type === 'txn' && e.entry.id != null ? `<button class="kv" data-tx="${e.entry.id}"><span>${esc(e.msg)}</span><span class="muted">${esc(e.entry.file)}:${e.entry.line}</span></button>`
      : e.entry.account ? `<button class="kv" data-goto-acct="${esc(e.entry.account)}"><span>${esc(e.msg)}</span><span class="muted">${esc(e.entry.file)}:${e.entry.line}</span></button>`
      : `<a class="kv" target="_blank" rel="noopener" href="https://github.com/${esc(c.owner)}/${esc(c.repo)}/blob/${esc(c.branch)}/${esc(e.entry.file)}#L${e.entry.line}"><span>${esc(e.msg)}</span><span class="muted">${esc(e.entry.file)}:${e.entry.line}</span></a>`).join('') || '<div class="empty">没有发现问题</div>'}</div>
    <div class="section"><h2>数据</h2></div>
    <div class="sheet"><div class="kv"><span>${L.files.length} 个文件，${L.txns.length} 笔交易</span><span class="muted">${S.lastSync ? '上次同步 ' + new Date(S.lastSync).toLocaleString('zh-CN') : ''}</span></div>
      <div class="kv"><span>外观</span><span class="chips">${[['', '跟随系统'], ['light', '浅色'], ['dark', '深色']].map(([k, l]) => `<button class="chip" data-theme-set="${k}" aria-pressed="${(LS.get('theme', '') || '') === k}">${l}</button>`).join('')}</span></div>
      <div class="kv"><span>清除本机缓存（不影响 GitHub 上的数据）</span><button class="linkbtn bad" data-act="wipe">清除</button></div></div>` : ''}
  </div>`;
  $('#cfg').addEventListener('submit', async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    const n = Object.fromEntries([...f.entries()].map(([k, v]) => [k, String(v).trim()]));
    LS.set('cfg', n);
    S.tree = null; S.L = null; LS.del('tree');
    main.innerHTML = '<div class="loading">正在读取账本…</div>';
    S.tab = LS.get('tab', 'add') === 'settings' ? 'add' : LS.get('tab', 'add');
    await refresh();
  });
}

// ---------------------------------------------------------------------
// global click handlers
// ---------------------------------------------------------------------
main.addEventListener('click', async (e) => {
  const el = e.target.closest('button, [data-tx]');
  if (!el) return;
  const ds = el.dataset;
  if (ds.kind) {
    const old = S.draft;
    if (ds.kind === 'multi' && old && old.kind !== 'multi' && old.kind !== 'raw') {
      // carry what was typed in a simple form over into rows
      const nd = newDraft('multi'); nd.date = old.date; nd.payee = old.payee; nd.narration = old.narration;
      const tx = old.kind !== 'raw' ? (() => { try { const v = validateText(draftText(old)); return v.txn; } catch { return null; } })() : null;
      if (tx) { nd.rows = rowsFromTxn(tx, true); nd.tagsText = [...tx.tags.map((x) => '#' + x), ...tx.links.map((x) => '^' + x)].join(' '); nd.payee = tx.payee; nd.narration = tx.narration; }
      S.draft = nd; render(); return;
    }
    if (ds.kind === 'raw' && old && old.kind !== 'raw') { const nd = newDraft('raw'); nd.date = old.date; nd.raw = draftText(old) || ''; S.draft = nd; render(); return; }
    S.draft = { ...newDraft(ds.kind), date: old?.date || today(), amount: old?.amount || '', funding: old?.funding }; S.draft.currency = S.L.acctCcy[S.draft.funding] || 'CNY'; render(); return;
  }
  if (ds.neg != null) {
    const r = S.draft.rows[+ds.neg];
    const a = r.amount.trim();
    r.amount = a.startsWith('-') ? a.slice(1) : '-' + a;
    S.draft.edited = null;
    const inp = document.querySelector(`[data-row="${ds.neg}"][data-rf="amount"]`);
    if (inp) { inp.value = r.amount; inp.focus(); try { inp.setSelectionRange(r.amount.length, r.amount.length); } catch {} }
    updatePreview();
    return;
  }
  if (ds.tplFill) { const x = templates().find((t) => t.id === ds.tplFill); if (x) { S.draft = draftFromTemplate(x); render(); if (x.fixed == null) $('[data-f="amount"]')?.focus(); } return; }
  if (ds.tplSave) { const x = templates().find((t) => t.id === ds.tplSave); if (x) await saveTemplateNow(x); return; }
  if (ds.inbox) {
    const cur = S.draft?.inboxItem;
    if (ds.inbox === 'start') { const it = nextInbox(null); if (it) { draftFromInbox(it); render(); } return; }
    if (ds.inbox === 'leave') { S.draft = newDraft(); render(); return; }
    if (ds.inbox === 'skip') { const it = nextInbox(cur?.path); if (it) draftFromInbox(it); else { S.draft = newDraft(); toast('收件箱处理完了'); } render(); return; }
    if (ds.inbox === 'drop' && cur) {
      S.pending.push({ kind: 'deleteFile', path: cur.path, label: `收件箱：丢弃 ${cur.merchant} ${Number.isFinite(cur.amount) ? cur.amount : ''}` });
      const it = nextInbox(cur.path);
      if (it) draftFromInbox(it); else S.draft = newDraft();
      await commitQueued('已删');
      return;
    }
    return;
  }
  if (ds.rowflag != null) { const r = S.draft.rows[+ds.rowflag]; r.flag = r.flag === '!' ? '' : '!'; S.draft.edited = null; render(); return; }
  if (ds.delrow != null) { S.draft.rows.splice(+ds.delrow, 1); if (!S.draft.rows.length) S.draft.rows.push(newRow()); S.draft.edited = null; render(); return; }
  if (ds.tpl) { const d = S.draft; d.raw = (d.raw.replace(/\s+$/, '') + (d.raw.trim() ? '\n\n' : '') + ds.tpl); render(); const ta = $('.preview textarea'); if (ta) { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); } return; }
  if (ds.set) { setDraft(ds.set, ds.val, true); return; }
  if (ds.op) { S.draft.amount = (S.draft.amount || '') + ds.op; S.draft.edited = null; const a = $('[data-f="amount"]'); a.value = S.draft.amount; a.focus(); updatePreview(); return; }
  if (ds.tx != null && ds.tx !== '') { openTx(+ds.tx); return; }
  if (ds.month) { S.month = addMonth(S.month, +ds.month * (S.period === 'year' ? 12 : 1)); render(); return; }
  if (ds.period) { S.period = ds.period; LS.set('period', ds.period); render(); return; }
  if (ds.reimb) { openReimb(ds.reimb); return; }
  if (ds.check) { openCheck(ds.check); return; }
  if (ds.recheck) { const [date, currency] = ds.recheck.split('|'); const o = existingBalance(S.acctView, date, currency); openCheck(S.acctView, { date, currency, actual: o ? String(o.entry.number) : '' }); return; }
  if (ds.hold != null) { S.expanded['h' + ds.hold] = !S.expanded['h' + ds.hold]; render(); return; }
  if (ds.bsDate) { S.bsDate = ds.bsDate; render(); return; }
  if (ds.expand) { S.expanded[ds.expand] = !S.expanded[ds.expand]; render(); return; }
  if (ds.gotoSearch || ds.gotoQ || 'gotoIncome' in ds || ds.gotoAcct) navPush();
  if (ds.gotoSearch) { S.search = { q: '', account: ds.gotoSearch, month: S.tab === 'overview' ? S.month : null, limit: 120 }; go('journal'); return; }
  if (ds.gotoQ) { S.search = { q: ds.gotoQ, account: null, month: S.month, limit: 120 }; go('journal'); return; }
  if ('gotoIncome' in ds) { S.search = { q: '', account: 'Income', month: S.month, limit: 120 }; go('journal'); return; }
  if (ds.gotoAcct) { S.tab = 'accounts'; S.acctView = ds.gotoAcct; render(); window.scrollTo(0, 0); return; }
  if (ds.clear) { S.search[ds.clear] = null; renderJournal(); return; }
  if (ds.q) { S.search.q = (S.search.q.trim() + ' ' + ds.q).trim(); renderJournal(); return; }
  if (ds.defaultFund) { LS.set('defaultFunding', ds.defaultFund); render(); return; }
  if (ds.themeSet != null) { LS.set('theme', ds.themeSet); applyTheme(); render(); return; }
  if (ds.drop != null) { S.pending.splice(+ds.drop, 1); savePending(); await rebuild(); render(); return; }
  switch (ds.act) {
    case 'save': await saveDraft(); break;
    case 'add-row': S.draft.rows.push(newRow()); S.draft.edited = null; render(); document.querySelector(`[data-combo="row:${S.draft.rows.length - 1}"]`)?.focus(); break;
    case 'toggle-explicit': LS.set('explicit', !LS.get('explicit', true)); S.draft.edited = null; render(); break;
    case 'align-raw': S.draft.raw = alignText(S.draft.raw); render(); break;
    case 'tpl-manage': openTemplateManager(); break;
    case 'privacy': LS.set('privacy', !LS.get('privacy', false)); applyPrivacy(); render(); break;
    case 'reset-maps': LS.del('cardMap'); LS.del('merchantMap'); render(); break;
    case 'toggle-flag': S.draft.flag = S.draft.flag === '!' ? '*' : '!'; S.draft.edited = null; render(); break;
    case 'balance-last': {
      const d = S.draft; const v = validateText(draftText(d)); const t = v.entries?.find((x) => x.type === 'txn'); if (!t) break;
      const res = {}; for (const p of t.postings) { const w = weight(p); if (w) res[w.c] = (res[w.c] || 0) + w.n; }
      const [c, n] = Object.entries(res).find(([, x]) => Math.abs(x) > 0.005) || [];
      const r = [...d.rows].reverse().find((x) => x.account);
      if (!r || c == null) break;
      if (r.amount.trim() && r.currency === c && !r.cost && !r.price) r.amount = numText(evalExpr(r.amount) - n);
      else { d.rows.push({ ...newRow(), account: r.account, currency: c, amount: numText(-n) }); }
      d.edited = null; render(); break;
    }
    case 'cancel-edit': { if (navBack()) break; const r = S.draft?.returnTab || 'journal'; S.draft = null; S.tab = r; render(); break; }
    case 'delete':
      if (el.dataset.armed !== '1') { el.dataset.armed = '1'; el.textContent = '再点一次确认删除'; setTimeout(() => { if (el.isConnected) { el.dataset.armed = '0'; el.textContent = '删除这笔交易'; } }, 4000); }
      else await deleteEdited();
      break;
    case 'clear': S.draft = newDraft(S.draft.kind); render(); break;
    case 'reset-edit': S.draft.edited = null; render(); break;
    case 'sync': await refresh(); if (S.pending.length === 0 && S.syncState === 'idle') toast('已是最新'); break;
    case 'more': S.search.limit += 200; renderJournalResults(); break;
    case 'back': if (navBack()) break; S.acctView = null; render(); break;
    case 'back-tab': if (navBack()) break; S.tab = S.prevTab || (LS.get('tab', 'add') === 'settings' ? 'add' : LS.get('tab', 'add')); render(); break;
    case 'closed': S.showClosed = !S.showClosed; render(); break;
    case 'wipe': await idb.clear(); LS.del('tree'); S.tree = null; S.L = null; render(); await refresh(); break;
  }
});

function applyPrivacy() { document.body.classList.toggle('privacy', !!LS.get('privacy', false)); }
function applyTheme() {
  const t = LS.get('theme', '');
  if (t) document.documentElement.dataset.theme = t; else delete document.documentElement.dataset.theme;
}

// =====================================================================
// boot
// =====================================================================
async function boot() {
  applyTheme();
  applyPrivacy();
  render();
  if (!cfg()) return;
  if (S.tree) { try { await rebuild(); await loadInbox(); render(); } catch (e) { console.warn('cache', e); } }
  if (S.L && draftFromURL()) render();
  await refresh({ quiet: !!S.L });
  if (location.search && S.L && draftFromURL()) render();
}
document.addEventListener('keydown', (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey || !S.L) return;
  const tag = (e.target.tagName || '').toLowerCase();
  if (tag === 'input' || tag === 'textarea' || tag === 'select' || document.querySelector('.modal-back')) return;
  if (e.key === 'n') { e.preventDefault(); if (S.draft?.mode === 'edit') S.draft = null; navReset(); go('add'); $('[data-f="amount"]')?.focus(); }
  else if (e.key === '/') { e.preventDefault(); navReset(); go('journal'); $('#q')?.focus(); }
  else if (e.key === 'g') { navReset(); go('overview'); }
  else if (e.key === 'r') { navReset(); go('reports'); }
});
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && cfg()) refresh({ quiet: true }); });
window.addEventListener('online', () => cfg() && refresh({ quiet: true }));
if ('serviceWorker' in navigator && location.protocol === 'https:') navigator.serviceWorker.register('sw.js').catch(() => {});
boot();
