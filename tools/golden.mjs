// Generates test fixtures and the expected results the Swift port must reproduce.
// Run from the repo root:  node tools/golden.mjs
// Uses tools/reference/ledger.js and the pure helpers in tools/reference/app.js (the original JavaScript implementation).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as LJ from './reference/ledger.js';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, 'reference');
const FIX = join(here, '..', 'LedgerKit', 'Tests', 'LedgerKitTests', 'Fixtures');
const TODAY = '2026-10-08';

// ---------------------------------------------------------------------------
// pull the pure helpers out of app.js
// ---------------------------------------------------------------------------
const appSrc = readFileSync(join(root, 'app.js'), 'utf8');
function grab(name) {
  const re = new RegExp(`^(?:async )?function ${name}\\(`, 'm');
  const m = re.exec(appSrc);
  if (!m) throw new Error('missing ' + name);
  const end = appSrc.indexOf('\n}\n', m.index);
  return appSrc.slice(m.index, end + 2);
}
function grabConst(name) {
  const re = new RegExp(`^const ${name} = .*$`, 'm');
  const m = re.exec(appSrc);
  if (!m) throw new Error('missing const ' + name);
  // multi-line object literal
  if (m[0].trim().endsWith('{')) { const end = appSrc.indexOf('\n};\n', m.index); return appSrc.slice(m.index, end + 3); }
  return m[0];
}
const helpers = [
  grabConst('ZH'), grabConst('SYM'), grabConst('money'), grabConst('signed'), grabConst('leaf'), grabConst('catOf'),
  grabConst('acctLabel'), grabConst('ym'), grabConst('shiftDay'), grabConst('addMonth'), grabConst('shortName'),
  grab('classify'), grab('derive').replace('new Date(Date.now() - 60 * 864e5).toISOString().slice(0, 10)', 'shiftDay(now, -60)'),
  grab('rankAccounts'), grab('newDraft'), grab('newRow'), grab('evalExpr'), grab('parseTagsLinks'), grab('multiTx'), grab('evalAmount'),
  grab('draftTx'), grab('draftText'), grab('templates'), grab('removeBlock'), grab('balanceLine'), grab('insertBalance'), grab('addLinkToHeader'), grab('addInclude'),
  grab('isComplex'), grab('rowsFromTxn'), grab('validateText'), grab('fileFor'),
].join('\n');
const ctx = new Function('LJ', 'S', 'LS', 'today', `
  const { toCNY, fmtNum, formatTxn, checkText, numText } = LJ;
  ${helpers}
  return { classify, derive, rankAccounts, newDraft, newRow, evalExpr, evalAmount, draftText, templates, removeBlock, balanceLine, insertBalance, addLinkToHeader, addInclude, isComplex, rowsFromTxn, validateText, fileFor, money, acctLabel };
`);
const S = { L: null };
const store = {};
const LS = { get: (k, d) => (k in store ? store[k] : d), set: (k, v) => (store[k] = v), del: (k) => delete store[k] };
const A = ctx(LJ, S, LS, () => TODAY);

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------
const syn = readFileSync(join(here, 'syn-full.bean'), 'utf8');
const synErr = readFileSync(join(here, 'syn-errors.bean'), 'utf8');

// a realistic multi-file ledger, deterministic
let seed = 42;
const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const pick = (a) => a[Math.floor(rnd() * a.length)];
const fmt = (n) => n.toFixed(2);
const line = (acct, n, c, sfx = '') => LJ.fmtPostingLine(acct, typeof n === 'number' ? fmt(n) : n, c, sfx);

function realistic() {
  const files = {};
  files['main.bean'] = `option "title" "Test"
option "operating_currency" "CNY"
option "booking_method" "FIFO"

include "config/commodities.bean"
include "accounts/assets.bean"
include "accounts/balance.bean"
include "journals/2024.bean"
include "journals/2025.bean"
include "journals/2026.bean"
include "prices.bean"
`;
  files['config/commodities.bean'] = `2020-01-01 commodity CNY
2020-01-01 commodity HKD
2020-01-01 commodity USD
2020-01-01 commodity AAPL
  asset-class: "equity"
  price: "USD:yahoo/AAPL"
`;
  const opens = ['Assets:Bank:CGB CNY', 'Assets:Bank:BOCHK HKD', 'Assets:EWallet:Alipay CNY', 'Assets:Brokerage:IBKR:Cash USD', 'Assets:Brokerage:IBKR:Stock AAPL',
    'Assets:Receivable:Reimbursement', 'Liabilities:CreditCard:CMB CNY', 'Expenses:Food:Drinks', 'Expenses:Food:Meals', 'Expenses:Transit:Metro', 'Expenses:Shopping:Household',
    'Expenses:Subscription:Phone', 'Expenses:Housing:Rent', 'Expenses:Travel:Hotel', 'Expenses:Fee:Bank', 'Income:Salary:Work', 'Income:Invest:Gain', 'Income:Invest:Interest', 'Equity:Opening'];
  files['accounts/assets.bean'] = opens.map((o) => `2023-12-01 open ${o}`).join('\n') + '\n';
  const years = { 2024: [], 2025: [], 2026: [] };
  const push = (d, text) => years[d.slice(0, 4)].push(text);
  const payees = [['便利店', '香烟', 'Expenses:Food:Drinks', [18, 18, 18, 25]], ['喜市多', '早餐', 'Expenses:Food:Meals', [8.5, 12, 9.9]], ['地铁', '通勤', 'Expenses:Transit:Metro', [4, 6, 5]],
    ['淘宝', '纸巾', 'Expenses:Shopping:Household', [29.9, 45.5, 12.8]], ['瑞幸', '拿铁', 'Expenses:Food:Drinks', [9.9, 13.9]]];
  const funds = ['Assets:Bank:CGB', 'Assets:EWallet:Alipay', 'Liabilities:CreditCard:CMB'];
  let d = '2024-01-01';
  push(d, `${d} * "Opening" "期初"\n${line('Assets:Bank:CGB', 50000, 'CNY')}\n${line('Assets:Bank:BOCHK', 8000, 'HKD')}\n${line('Assets:Brokerage:IBKR:Cash', 3000, 'USD')}\n  Equity:Opening`);
  let stockLots = 0;
  while (d <= TODAY) {
    const day = +d.slice(8);
    const n = 1 + Math.floor(rnd() * 4);
    for (let k = 0; k < n; k++) {
      const [p, narr, acct, amts] = pick(payees);
      const amt = pick(amts);
      push(d, `${d} * "${p}" "${narr}"\n${line(acct, amt, 'CNY')}\n${line(pick(funds), -amt, 'CNY')}`);
    }
    if (day === 5) push(d, `${d} * "UniCom" "手机充值"\n${line('Expenses:Subscription:Phone', 19.9, 'CNY')}\n${line('Assets:EWallet:Alipay', -19.9, 'CNY')}`);
    if (day === 10) push(d, `${d} * "Work" "工资"\n${line('Income:Salary:Work', -15000, 'CNY')}\n${line('Assets:Bank:CGB', 15000, 'CNY')}`);
    if (day === 12) push(d, `${d} * "Landlord" "房租"\n${line('Expenses:Housing:Rent', 4500, 'CNY')}\n${line('Assets:Bank:CGB', -4500, 'CNY')}`);
    if (day === 20) push(d, `${d} * "CMB Credit Card" "Repayment"\n${line('Liabilities:CreditCard:CMB', 1000, 'CNY')}\n${line('Assets:Bank:CGB', -1000, 'CNY')}`);
    if (day === 15 && rnd() < 0.5) {
      const hk = Math.round(rnd() * 300 * 100) / 100 + 20, rate = 0.9 + rnd() * 0.05;
      push(d, `${d} * "大快活" "午餐" #fx\n${line('Expenses:Food:Meals', Math.round(hk * rate * 100) / 100, 'CNY', `@ ${(1 / rate).toFixed(5)} HKD`)}\n${line('Assets:Bank:BOCHK', -Math.round(hk * rate * (1 / rate) * 100) / 100, 'HKD')}`);
    }
    if (day === 25 && rnd() < 0.4) {
      const cny = 2000, hkd = Math.round(cny * (1.08 + rnd() * 0.04) * 100) / 100;
      push(d, `${d} * "Transfer" "CGB -> BOCHK" #transfer\n  exchange_rate: "1 CNY = ${(hkd / cny).toFixed(5)} HKD"\n${line('Assets:Bank:CGB', -cny, 'CNY')}\n${line('Assets:Bank:BOCHK', hkd, 'HKD', `@@ ${cny.toFixed(2)} CNY`)}`);
    }
    if (day === 3 && rnd() < 0.5) {
      const q = 1 + Math.floor(rnd() * 3), px = (150 + rnd() * 80).toFixed(2);
      push(d, `${d} * "IBKR" "Buy AAPL"\n  Assets:Brokerage:IBKR:Stock                      ${q} AAPL {${px} USD}\n  Assets:Brokerage:IBKR:Cash`);
      stockLots += q;
    }
    if (day === 28 && stockLots > 2 && rnd() < 0.3) {
      const q = 1, px = (170 + rnd() * 80).toFixed(2);
      push(d, `${d} * "IBKR" "Sell AAPL"\n  Assets:Brokerage:IBKR:Stock                     -${q} AAPL {} @ ${px} USD\n${line('Assets:Brokerage:IBKR:Cash', +px * q, 'USD')}\n  Income:Invest:Gain`);
      stockLots -= q;
    }
    if ((day === 18 || day === 26) && d >= '2026-07-01') push(d, `${d} * "Didi" "打车" #reimbursed\n${line('Assets:Receivable:Reimbursement', day === 18 ? 45.5 : 32, 'CNY')}\n${line('Assets:EWallet:Alipay', day === 18 ? -45.5 : -32, 'CNY')}`);
    if (day === 1) push(d, `${d} * "Office" "垫付打车" #reimbursed ^reimburse-work-${d.slice(0, 7).replace('-', '')}\n${line('Assets:Receivable:Reimbursement', 56, 'CNY')}\n${line('Assets:EWallet:Alipay', -56, 'CNY')}`);
    d = LJ_shift(d, 1);
  }
  // a pad
  push('2026-03-01', `2026-03-01 pad Assets:EWallet:Alipay Equity:Opening`);
  for (const y in years) files[`journals/${y}.bean`] = years[y].sort((a, b) => (a.slice(0, 10) < b.slice(0, 10) ? -1 : a.slice(0, 10) > b.slice(0, 10) ? 1 : 0)).join('\n\n') + '\n';
  // prices
  const pr = [];
  for (let m = '2024-01'; m <= TODAY.slice(0, 7); m = addM(m, 1)) {
    pr.push(`${m}-02 price USD                                    ${(7 + rnd() * 0.3).toFixed(4)} CNY`);
    pr.push(`${m}-02 price HKD                                    ${(0.9 + rnd() * 0.03).toFixed(4)} CNY`);
    pr.push(`${m}-02 price AAPL                                 ${(160 + rnd() * 80).toFixed(2)} USD`);
  }
  files['prices.bean'] = pr.join('\n') + '\n';
  // balance assertions: compute real balances first, then assert them (plus one deliberately wrong)
  files['accounts/balance.bean'] = '';
  const L0 = load(files);
  const bals = [];
  for (const acct of ['Assets:Bank:CGB', 'Assets:Bank:BOCHK', 'Liabilities:CreditCard:CMB', 'Assets:EWallet:Alipay']) {
    for (let m = '2024-02'; m <= '2026-09'; m = addM(m, 3)) {
      const date = m + '-01';
      const ccy = acct.includes('BOCHK') ? 'HKD' : 'CNY';
      let n = 0;
      for (const t of L0.txns) { if (t.date >= date) break; for (const p of t.postings) if (p.account === acct && p.currency === ccy) n += p.units; }
      if (acct === 'Assets:EWallet:Alipay' && date >= '2026-03-02') n += 500; // the pad fills this
      if (acct === 'Assets:Bank:CGB' && date === '2025-05-01') n += 1; // wrong on purpose
      bals.push(LJ_balance(date, acct, n, ccy));
    }
  }
  files['accounts/balance.bean'] = bals.join('\n') + '\n';
  return files;
}
function LJ_shift(d, k) { const t = new Date(d + 'T12:00:00Z'); t.setUTCDate(t.getUTCDate() + k); return t.toISOString().slice(0, 10); }
function addM(m, k) { let y = +m.slice(0, 4), mo = +m.slice(5) - 1 + k; y += Math.floor(mo / 12); mo = ((mo % 12) + 12) % 12; return `${y}-${String(mo + 1).padStart(2, '0')}`; }
function LJ_balance(date, acct, n, c) { const left = `${date} balance ${acct}`; const ns = n.toFixed(2); return left + ' '.repeat(Math.max(1, 59 - left.length - ns.length)) + ns + ' ' + c; }

function load(files, rootFile = 'main.bean') {
  // loadLedger is async in JS; do the same work synchronously
  const entries = [], fl = [], options = {}, plugins = [], errors = [];
  const seen = new Set();
  const dirOf = (p) => (p.includes('/') ? p.slice(0, p.lastIndexOf('/') + 1) : '');
  const visit = (path) => {
    if (seen.has(path)) return; seen.add(path);
    if (!(path in files)) { errors.push({ entry: { file: path, line: 0 }, msg: `读不到 ${path}：missing` }); return; }
    fl.push(path);
    const r = LJ.parseFile(files[path], path);
    entries.push(...r.entries); errors.push(...r.errors); plugins.push(...r.plugins);
    for (const k in r.options) (options[k] ||= []).push(...r.options[k]);
    for (const inc of r.includes) visit(inc.startsWith('/') ? inc.slice(1) : dirOf(path) + inc);
  };
  visit(rootFile);
  return LJ.build(entries, fl, { options, plugins, errors });
}

// ---------------------------------------------------------------------------
// expected results
// ---------------------------------------------------------------------------
const r6 = (n) => (n == null ? null : Math.round(n * 1e6) / 1e6);
function summary(L) {
  S.L = L; A.derive(L);
  const fin = {};
  for (const a of Object.keys(L.final).sort()) { fin[a] = {}; for (const c of Object.keys(L.final[a]).sort()) fin[a][c] = r6(L.final[a][c]); }
  const inv = {};
  for (const a of Object.keys(L.inventory).sort()) inv[a] = L.inventory[a].map((l) => [r6(l.units), l.currency, l.cost ? r6(l.cost.number) : null, l.cost?.currency ?? null, l.cost?.date ?? null, l.cost?.label ?? null]);
  const rates = {};
  for (const c of Object.keys(L.rates).sort()) rates[c] = r6(LJ.toCNY(L, 1, c));
  const monthExp = {};
  for (const m of Object.keys(L.monthExp).sort()) monthExp[m] = r6(L.monthExp[m]);
  return {
    entries: L.entries.length,
    txns: L.txns.map((t) => [t.date, t.flag, t.payee, t.narration, t.tags, t.links, t.synthetic ? 1 : 0, t.postings.map((p) => [p.account, r6(p.units), p.currency, p.interpolated ? 1 : 0, p.cost ? r6(p.cost.number) : null, p.price ? r6(p.price.number) : null])]),
    errors: L.errors.map((e) => e.msg),
    balanceResults: L.balanceResults.map((r) => [r.entry.date, r.entry.account, r.ok ? 1 : 0, r6(r.got)]),
    final: fin, inventory: inv, rates, monthExp,
    openAccounts: L.openAccounts.slice().sort(),
    currencies: L.currencies.slice().sort(),
    acctCcy: Object.fromEntries(Object.keys(L.acctCcy).sort().map((k) => [k, L.acctCcy[k]])),
    payeesTop: L.payees.slice(0, 5).map((p) => p.name),
    templates: A.templates().map((x) => [x.id, x.kind, x.fixed, x.monthly ? 1 : 0, x.due ? 1 : 0, x.n, x.funding]),
    classify: L.txns.map((t) => { const c = A.classify(t); return [c.kind, r6(c.amount)]; }),
    complex: L.txns.map((t) => (A.isComplex(t) ? 1 : 0)),
  };
}

function writeFiles(dir, files) {
  for (const [p, text] of Object.entries(files)) { const f = join(dir, p); mkdirSync(dirname(f), { recursive: true }); writeFileSync(f, text); }
}

const sets = {
  full: { 'main.bean': syn },
  errors: { 'main.bean': synErr },
  realistic: realistic(),
};
const out = {};
for (const [name, files] of Object.entries(sets)) {
  writeFiles(join(FIX, name), files);
  const L = load(files);
  out[name] = summary(L);
  console.log(name, 'txns', L.txns.length, 'errors', L.errors.length, 'balances', L.balanceResults.filter((r) => r.ok).length + '/' + L.balanceResults.length);
}

// ---------------------------------------------------------------------------
// formatting / editing cases
// ---------------------------------------------------------------------------
const L = load(sets.realistic); S.L = L; A.derive(L);
const cases = {};
cases.numText = [0, 1, -1, 12.5, 0.1 + 0.2, 1234567.891, 19.9, -0.005, 1e-7, 33.333333333333, 100, 2.675].map((n) => [n, LJ.numText(n)]);
cases.fmtNum = [[1234567.891, 2], [-0.004, 2], [0, 0], [-1234.5, 0], [999.995, 2], [12.345, 4], [1e6, 2]].map(([n, d]) => [n, d, LJ.fmtNum(n, d)]);
cases.money = [[12.5, 'CNY'], [-3, 'HKD'], [1000, 'AAPL'], [0.5, 'USD']].map(([n, c]) => [n, c, A.money(n, c)]);
cases.evalAmount = ['12', '12.5', '12+8.5', '3×4', '1,234.50', '12,5', '-5', '(1+2)*3', '10/3', 'abc', '', '2-', '.5'].map((s) => [s, Number.isFinite(A.evalAmount(s)) ? A.evalAmount(s) : null]);
cases.formatTxn = [
  { date: '2026-10-01', payee: '便利店', narration: '香烟', tags: [], links: [], meta: {}, postings: [{ account: 'Expenses:Food:Drinks', units: 18, currency: 'CNY' }, { account: 'Assets:Bank:CGB', units: -18, currency: 'CNY' }] },
  { date: '2026-10-01', flag: '!', payee: 'Transfer', narration: 'CGB -> BOCHK', tags: ['transfer'], links: ['abc'], meta: { exchange_rate: '1 CNY = 1.08000 HKD' }, postings: [{ account: 'Assets:Bank:CGB', units: -2000, currency: 'CNY' }, { account: 'Assets:Bank:BOCHK', units: 2160, currency: 'HKD', priceTotal: 2000, priceCcy: 'CNY' }] },
  { date: '2026-10-02', payee: '', narration: 'buy', tags: [], links: [], meta: {}, postings: [{ account: 'Assets:Brokerage:IBKR:Stock', units: '2', currency: 'AAPL', cost: '180.50 USD' }, { account: 'Assets:Brokerage:IBKR:Cash', units: null, currency: null, flag: '!', meta: { note: 'cash leg', date: '2026-10-02' } }] },
];
cases.formatTxn = cases.formatTxn.map((tx) => [tx, LJ.formatTxn(tx)]);
const sampleFile = sets.realistic['journals/2026.bean'].split('\n').slice(0, 40).join('\n') + '\n';
const entry1 = LJ.formatTxn(cases.formatTxn[0][0]);
cases.insertEntry = [
  [sampleFile, entry1, '2026-01-02'], [sampleFile, entry1, '2025-12-31'], [sampleFile, entry1, '2026-12-31'], ['', entry1, '2026-01-01'],
  ['2026-01-01 balance Assets:A  1.00 CNY\n2026-01-03 balance Assets:A  2.00 CNY\n', '2026-01-02 balance Assets:A  1.50 CNY', '2026-01-02'],
  ['; header\n\n2026-01-01 open Assets:A\n', '2026-01-02 open Assets:B', '2026-01-02'],
].map(([t, e, d]) => [t, e, d, LJ.insertEntry(t, e, d)]);
cases.alignText = [
  '2026-10-01 * "a" "b"\n  Expenses:Food   12.5 CNY\n  Assets:Bank:CGB -12.50 CNY ; comment\n  ! Assets:X  3 USD @ 7 CNY',
  '2026-10-01 balance Assets:Bank:CGB 100.00 CNY\n2026-10-01 price USD 7.1 CNY\n2026-10-01 balance Assets:X 1.001 ~ 0.01 USD',
  '  Assets:钱包:微信 5 USD\n  Expenses:Food 1+2 CNY\n  lowercase 1 CNY',
].map((t) => [t, LJ.alignText(t)]);
const blk = '2026-01-05 * "UniCom" "手机充值"\n' + LJ.fmtPostingLine('Expenses:Subscription:Phone', '19.90', 'CNY') + '\n' + LJ.fmtPostingLine('Assets:EWallet:Alipay', '-19.90', 'CNY');
cases.removeBlock = [[sampleFile, sampleFile.split('\n\n')[2]], [sampleFile, blk], [sampleFile, 'nope']].map(([t, o]) => [t, o, A.removeBlock(t, o)]);
const balText = sets.realistic['accounts/balance.bean'];
cases.insertBalance = [
  { account: 'Assets:Bank:CGB', date: '2026-10-09', currency: 'CNY', replace: false, line: A.balanceLine('2026-10-09', 'Assets:Bank:CGB', 1234.5, 'CNY') },
  { account: 'Assets:Bank:CGB', date: '2025-05-01', currency: 'CNY', replace: true, line: A.balanceLine('2025-05-01', 'Assets:Bank:CGB', 99, 'CNY') },
  { account: 'Assets:New', date: '2026-10-09', currency: 'CNY', replace: false, line: A.balanceLine('2026-10-09', 'Assets:New', -5, 'CNY') },
].map((op) => [op, A.insertBalance(balText, op)]);
cases.addInclude = [[sets.realistic['main.bean'], 'include "journals/2027.bean"'], ['option "x" "y"\n\n', 'include "journals/2027.bean"']].map(([t, l]) => [t, l, A.addInclude(t, l)]);
cases.addLinkToHeader = [[sampleFile, { line: 1, header: sampleFile.split('\n')[0], link: 'refund-x' }], [sampleFile, { line: 99, header: 'nope', link: 'y' }]].map(([t, op]) => [t, op, A.addLinkToHeader(t, op)]);
cases.checkText = [
  '2026-10-01 * "x" "y"\n  Expenses:Food:Meals  10.00 CNY\n  Assets:Bank:CGB',
  '2026-10-01 * "x" "y"\n  Expenses:Food:Meals  10.00 CNY\n  Assets:Bank:CGB  -9.00 CNY',
  '2026-10-01 * "x" "y"\n  Expenses:Nope  10.00 CNY\n  Assets:Bank:CGB',
  '2026-10-01 * "IBKR" "sell"\n  Assets:Brokerage:IBKR:Stock  -1 AAPL {} @ 200 USD\n  Assets:Brokerage:IBKR:Cash  200.00 USD\n  Income:Invest:Gain',
  '2026-10-01 * "IBKR" "sell too much"\n  Assets:Brokerage:IBKR:Stock  -1000 AAPL {} @ 200 USD\n  Assets:Brokerage:IBKR:Cash  200000.00 USD\n  Income:Invest:Gain',
  '2026-10-01 balance Assets:Bank:CGB 1.00 CNY\n2026-10-01 price USD 7.1 CNY\n2026-10-02 open Assets:New CNY',
  'include "x.bean"', '', 'garbage line',
].map((t) => { const r = LJ.checkText(t, L); return [t, r.ok ? 1 : 0, r.msg ?? null, r.warnings.length, r.entries.length]; });
cases.validate = cases.checkText.map(([t]) => { const v = A.validateText(t, true); return [t, v.ok ? 1 : 0, v.msg ?? null]; });

// drafts → text
const base = A.newDraft('expense');
const drafts = [
  { ...base, kind: 'expense', payee: '便利店', narration: '香烟', amount: '18', currency: 'CNY', account: 'Expenses:Food:Drinks', funding: 'Assets:Bank:CGB' },
  { ...base, kind: 'expense', payee: '大快活', narration: '午餐', amount: '45.6', currency: 'CNY', account: 'Expenses:Food:Meals', funding: 'Assets:Bank:BOCHK', paid: '50' },
  { ...base, kind: 'expense', payee: 'Didi', narration: '打车', amount: '30+26', currency: 'CNY', account: 'Expenses:Transit:Metro', funding: 'Assets:EWallet:Alipay', reimb: true, link: 'reimburse-work-202610', tags: [] },
  { ...base, kind: 'income', payee: 'Work', narration: '工资', amount: '15000', currency: 'CNY', account: 'Income:Salary:Work', funding: 'Assets:Bank:CGB' },
  { ...base, kind: 'refund', payee: '淘宝', narration: '纸巾退款', amount: '12.8', currency: 'CNY', account: 'Expenses:Shopping:Household', funding: 'Assets:Bank:CGB', link: 'refund-x', tags: [] },
  { ...base, kind: 'transfer', amount: '2000', currency: 'CNY', funding: 'Assets:Bank:CGB', to: 'Assets:Bank:BOCHK', toAmount: '2190.5' },
  { ...base, kind: 'transfer', amount: '1000', currency: 'CNY', funding: 'Assets:Bank:CGB', to: 'Liabilities:CreditCard:CMB' },
  { ...base, kind: 'transfer', amount: '300', currency: 'CNY', funding: 'Assets:Bank:CGB', to: 'Assets:EWallet:Alipay' },
  { ...base, kind: 'multi', payee: '超市', narration: '分摊', tagsText: '#trip ^lnk', rows: [{ account: 'Expenses:Food:Meals', amount: '30', currency: 'CNY', cost: '', price: '', flag: '' }, { account: 'Assets:Receivable:Reimbursement', amount: '20,5', currency: 'CNY', cost: '', price: '', flag: '!' }, { account: 'Assets:Bank:CGB', amount: '', currency: 'CNY', cost: '', price: '', flag: '' }] },
  { ...base, kind: 'multi', payee: 'IBKR', narration: 'buy', rows: [{ account: 'Assets:Brokerage:IBKR:Stock', amount: '2', currency: 'AAPL', cost: '180 USD', price: '', flag: '' }, { account: 'Assets:Brokerage:IBKR:Cash', amount: '', currency: 'USD', cost: '', price: '', flag: '' }] },
  { ...base, kind: 'multi', payee: 'HK', narration: 'fx', rows: [{ account: 'Expenses:Food:Meals', amount: '10*3', currency: 'HKD', cost: '', price: '0.92 CNY', flag: '' }, { account: 'Assets:Bank:CGB', amount: '', currency: 'CNY', cost: '', price: '', flag: '' }] },
  { ...base, kind: 'expense', amount: '0', account: 'Expenses:Food:Meals', funding: 'Assets:Bank:CGB' },
];
cases.drafts = drafts.map((d) => { const strip = { ...d }; delete strip.rows; return [{ ...strip, rows: d.rows.map((r) => ({ ...r })) }, A.draftText(d)]; });
cases.rowsFromTxn = L.txns.filter((t) => A.isComplex(t)).slice(0, 6).map((t) => [L.txns.indexOf(t), A.rowsFromTxn(t, true).map((r) => [r.account, r.amount, r.currency, r.cost, r.price, r.flag])]);
cases.fileFor = L.entries.filter((e, i) => i % 97 === 0).slice(0, 30).map((e) => [e.type, e.date, e.account ?? e.currency ?? '', A.fileFor(e)]);
cases.newDraft = [base.funding, base.currency];

writeFileSync(join(FIX, 'expected.json'), JSON.stringify(out));
writeFileSync(join(FIX, 'cases.json'), JSON.stringify(cases, null, 1));
console.log('wrote', FIX);
