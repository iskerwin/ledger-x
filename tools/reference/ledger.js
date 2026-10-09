// ledger.js — a Beancount reader/writer that runs in the browser and in Node.
// Covers the Beancount v2/v3 input language: all directives, flags, arithmetic,
// multi-line strings, pushtag/pushmeta, costs ({}, {{}}, #, date, label, *),
// prices (@, @@), lot booking (STRICT/FIFO/LIFO/HIFO/NONE/AVERAGE), pad,
// interpolation of one missing number per currency, and precision-based tolerances.

const EPS = 1e-9;

// ---------------------------------------------------------------------------
// lexical helpers
// ---------------------------------------------------------------------------

const ACCOUNT_RE = /^([A-Z\p{Lu}][\p{L}\p{N}\-]*)((?::[\p{Lu}\p{N}\p{Lo}][\p{L}\p{N}\-]*)+)/u;
const CURRENCY_RE = /^(\/?[A-Z][A-Z0-9'._\-]{0,22}[A-Z0-9]|\/?[A-Z])(?![A-Za-z0-9'._\-])/;
const DATE_RE = /^(\d{4})[-/](\d{2})[-/](\d{2})/;
const FLAGS = new Set(['*', '!', '&', '#', '?', '%', 'P', 'S', 'T', 'C', 'U', 'R', 'M']);

// remove ; comment outside of strings
function stripComment(s) {
  let q = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === '\\' && q) { i++; continue; }
    if (c === '"') q = !q;
    else if (c === ';' && !q) return s.slice(0, i);
  }
  return s;
}

function quoteBalance(s) {
  let q = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === '\\' && q) { i++; continue; }
    if (c === '"') q = !q;
    else if (c === ';' && !q) break;
  }
  return q; // true = an unterminated string continues on the next line
}

// A tiny cursor-based scanner over one logical line.
class Scan {
  constructor(s) { this.s = s; this.i = 0; }
  ws() { while (this.i < this.s.length && /\s/.test(this.s[this.i])) this.i++; return this; }
  eof() { this.ws(); return this.i >= this.s.length; }
  peek(n = 1) { return this.s.slice(this.i, this.i + n); }
  rest() { return this.s.slice(this.i); }
  eat(str) { this.ws(); if (this.s.startsWith(str, this.i)) { this.i += str.length; return true; } return false; }
  string() {
    this.ws();
    if (this.s[this.i] !== '"') return null;
    let out = '', j = this.i + 1;
    for (; j < this.s.length; j++) {
      const c = this.s[j];
      if (c === '\\' && j + 1 < this.s.length) { const n = this.s[++j]; out += n === 'n' ? '\n' : n === 't' ? '\t' : n; continue; }
      if (c === '"') { this.i = j + 1; return out; }
      out += c;
    }
    return null;
  }
  account() { this.ws(); const m = ACCOUNT_RE.exec(this.rest()); if (!m) return null; this.i += m[0].length; return m[0]; }
  currency() { this.ws(); const m = CURRENCY_RE.exec(this.rest()); if (!m) return null; this.i += m[0].length; return m[0]; }
  date() { this.ws(); const m = DATE_RE.exec(this.rest()); if (!m) return null; this.i += m[0].length; return `${m[1]}-${m[2]}-${m[3]}`; }
  tagOrLink() {
    this.ws();
    const m = /^([#^])([A-Za-z0-9\-_/.\p{L}]+)/u.exec(this.rest());
    if (!m) return null;
    this.i += m[0].length;
    return { kind: m[1] === '#' ? 'tag' : 'link', value: m[2] };
  }
  // arithmetic expression: + - * / ( ) unary, numbers with optional thousands commas
  number() {
    const save = this.i;
    const self = this;
    let digits = 0, ok = true;
    function lit() {
      self.ws();
      const m = /^(\d[\d,]*(?:\.\d*)?|\.\d+)/.exec(self.rest());
      if (!m) { ok = false; return 0; }
      self.i += m[0].length;
      const t = m[0].replace(/,/g, '');
      digits = Math.max(digits, (t.split('.')[1] || '').length);
      return Number(t);
    }
    function factor() {
      self.ws();
      const c = self.s[self.i];
      if (c === '-') { self.i++; return -factor(); }
      if (c === '+') { self.i++; return factor(); }
      if (c === '(') { self.i++; const v = expr(); self.ws(); if (self.s[self.i] === ')') self.i++; else ok = false; return v; }
      return lit();
    }
    function term() {
      let v = factor();
      for (;;) {
        const j = self.i; self.ws();
        const c = self.s[self.i];
        if (c === '*' || c === '/') { self.i++; const r = factor(); v = c === '*' ? v * r : v / r; }
        else { self.i = j; return v; }
      }
    }
    function expr() {
      let v = term();
      for (;;) {
        const j = self.i; self.ws();
        const c = self.s[self.i];
        // a binary +/- must be followed by something numeric
        if ((c === '+' || c === '-') && /^[+-]\s*[\d.(]/.test(self.s.slice(self.i))) { self.i++; const r = term(); v = c === '+' ? v + r : v - r; }
        else { self.i = j; return v; }
      }
    }
    this.ws();
    if (!/^[-+(.\d]/.test(this.rest())) return null;
    const v = expr();
    if (!ok || !Number.isFinite(v)) { this.i = save; return null; }
    return { value: v, digits };
  }
}

// metadata value: string, date, number[ currency], account, currency, tag, bool
function parseValue(raw) {
  const sc = new Scan(raw.trim());
  if (!raw.trim()) return null;
  const st = sc.string(); if (st != null) return st;
  const save = sc.i;
  if (/^(TRUE|FALSE)$/.test(raw.trim())) return raw.trim() === 'TRUE';
  const d = sc.date(); if (d && sc.eof()) return d;
  sc.i = save;
  const n = sc.number();
  if (n) { const c = sc.currency(); if (sc.eof()) return c ? { number: n.value, currency: c } : n.value; }
  return raw.trim();
}

// ---------------------------------------------------------------------------
// parsing
// ---------------------------------------------------------------------------

export function parseFile(text, file) {
  const out = [];
  const includes = [];
  const options = {};
  const plugins = [];
  const errors = [];
  const tagStack = [];
  const metaStack = {};
  const raw = text.split(/\r?\n/);

  // logical lines (join multi-line strings)
  const lines = [];
  for (let i = 0; i < raw.length; i++) {
    let s = raw[i];
    const start = i;
    while (quoteBalance(s) && i + 1 < raw.length) s += '\n' + raw[++i];
    lines.push({ s, start, end: i });
  }

  let cur = null;
  let postIndent = null;
  const flush = () => { if (cur) { cur.src = raw.slice(cur.startLine, cur.endLine + 1).join('\n'); out.push(cur); cur = null; postIndent = null; } };
  const err = (ln, msg) => errors.push({ entry: { file, line: ln.start + 1, type: 'syntax' }, msg });

  for (const ln of lines) {
    const full = ln.s;
    if (!full.trim()) { flush(); continue; }
    const indented = /^[ \t]/.test(full);
    if (!indented) {
      flush();
      if (/^[;*#:!&%|]/.test(full) && !DATE_RE.test(full)) continue; // comments, org-mode headers
      const line = stripComment(full).trimEnd();
      if (!line.trim()) continue;
      const sc = new Scan(line);
      // undated directives
      const kw = /^(include|option|plugin|pushtag|poptag|pushmeta|popmeta)\b/.exec(line);
      if (kw) {
        sc.i = kw[0].length;
        if (kw[1] === 'include') { const p = sc.string(); if (p != null) includes.push(p); }
        else if (kw[1] === 'option') { const k = sc.string(), v = sc.string(); if (k != null) (options[k] ||= []).push(v); }
        else if (kw[1] === 'plugin') { const n = sc.string(), c = sc.string(); plugins.push({ name: n, config: c }); }
        else if (kw[1] === 'pushtag') { const t = sc.tagOrLink(); if (t) tagStack.push(t.value); }
        else if (kw[1] === 'poptag') { const t = sc.tagOrLink(); const k = t ? tagStack.lastIndexOf(t.value) : -1; if (k >= 0) tagStack.splice(k, 1); else err(ln, 'poptag 没有对应的 pushtag'); }
        else if (kw[1] === 'pushmeta') { const m = /^\s*([a-z][\w\-]*):\s*(.*)$/.exec(sc.rest()); if (m) (metaStack[m[1]] ||= []).push(parseValue(m[2])); }
        else if (kw[1] === 'popmeta') { const m = /^\s*([a-z][\w\-]*):/.exec(sc.rest()); if (m && metaStack[m[1]]?.length) metaStack[m[1]].pop(); }
        continue;
      }
      const date = sc.date();
      if (!date) { err(ln, '无法识别：' + line.slice(0, 60)); continue; }
      sc.ws();
      const base = { date, file, line: ln.start + 1, startLine: ln.start, endLine: ln.end, meta: {} };
      for (const k in metaStack) if (metaStack[k].length) base.meta[k] = metaStack[k][metaStack[k].length - 1];
      const word = /^([a-z]+)\b/.exec(sc.rest());
      const flagCh = sc.peek();
      if ((word && word[1] === 'txn') || (FLAGS.has(flagCh) && (/\s/.test(sc.s[sc.i + 1] ?? ' ')))) {
        const flag = word && word[1] === 'txn' ? '*' : flagCh;
        sc.i += word && word[1] === 'txn' ? 3 : 1;
        const strs = [];
        for (;;) { const s = sc.string(); if (s == null) break; strs.push(s); }
        const tags = [...tagStack], links = [];
        for (;;) { const t = sc.tagOrLink(); if (!t) break; (t.kind === 'tag' ? tags : links).push(t.value); }
        if (!sc.eof()) err(ln, '交易标题行多余内容：' + sc.rest());
        let payee = '', narration = '';
        if (strs.length >= 2) [payee, narration] = strs; else if (strs.length === 1) narration = strs[0];
        cur = { ...base, type: 'txn', flag, payee, narration, hasPayee: strs.length >= 2, tags: [...new Set(tags)], links, postings: [] };
        continue;
      }
      if (!word) { err(ln, '无法识别的指令'); continue; }
      const kind = word[1];
      sc.i += kind.length;
      let e = null;
      switch (kind) {
        case 'open': {
          const account = sc.account();
          const currencies = [];
          for (;;) { const c = sc.currency(); if (!c) break; currencies.push(c); if (!sc.eat(',')) break; }
          const booking = sc.string();
          e = { ...base, type: 'open', account, currencies, booking: booking || null };
          break;
        }
        case 'close': e = { ...base, type: 'close', account: sc.account() }; break;
        case 'commodity': e = { ...base, type: 'commodity', currency: sc.currency() }; break;
        case 'balance': {
          const account = sc.account();
          const n = sc.number();
          let tolerance = null;
          if (sc.eat('~')) { const t = sc.number(); tolerance = t ? t.value : null; }
          const currency = sc.currency();
          if (tolerance == null && sc.eat('~')) { const t = sc.number(); tolerance = t ? t.value : null; }
          if (!account || !n || !currency) { err(ln, 'balance 格式不对'); break; }
          e = { ...base, type: 'balance', account, number: n.value, digits: n.digits, tolerance, currency };
          break;
        }
        case 'pad': e = { ...base, type: 'pad', account: sc.account(), source: sc.account() }; break;
        case 'note': e = { ...base, type: 'note', account: sc.account(), comment: sc.string() }; break;
        case 'document': {
          const account = sc.account(), path = sc.string();
          const tags = [], links = [];
          for (;;) { const t = sc.tagOrLink(); if (!t) break; (t.kind === 'tag' ? tags : links).push(t.value); }
          e = { ...base, type: 'document', account, path, tags, links };
          break;
        }
        case 'event': e = { ...base, type: 'event', name: sc.string(), description: sc.string() }; break;
        case 'query': e = { ...base, type: 'query', name: sc.string(), query: sc.string() }; break;
        case 'price': {
          const currency = sc.currency(); const n = sc.number(); const quote = sc.currency();
          if (!currency || !n || !quote) { err(ln, 'price 格式不对'); break; }
          e = { ...base, type: 'price', currency, number: n.value, quote };
          break;
        }
        case 'custom': {
          const name = sc.string(); const values = [];
          while (!sc.eof()) {
            const s = sc.string(); if (s != null) { values.push(s); continue; }
            const d = sc.date(); if (d) { values.push(d); continue; }
            const a = sc.account(); if (a) { values.push(a); continue; }
            const n = sc.number(); if (n) { const c = sc.currency(); values.push(c ? { number: n.value, currency: c } : n.value); continue; }
            const m = /^(TRUE|FALSE)\b/.exec(sc.ws().rest()); if (m) { sc.i += m[0].length; values.push(m[0] === 'TRUE'); continue; }
            break;
          }
          e = { ...base, type: 'custom', name, values };
          break;
        }
        default: err(ln, '未知指令：' + kind);
      }
      if (e) { if (!sc.eof() && e.type !== 'custom') err(ln, `${kind} 多余内容：${sc.rest()}`); cur = e; }
      continue;
    }

    // indented line
    if (/^\s*;/.test(full)) continue;
    if (!cur) { err(ln, '缩进行不属于任何指令'); continue; }
    const line = stripComment(full).trimEnd();
    if (!line.trim()) continue;
    cur.endLine = ln.end;
    const indent = /^[ \t]*/.exec(line)[0].replace(/\t/g, '    ').length;
    const mm = /^\s+([a-z][\w\-]*):(?:\s+(.*)|\s*)$/.exec(line);
    if (mm) {
      const v = parseValue(mm[2] || '');
      if (cur.type === 'txn' && cur.postings.length && indent > postIndent) cur.postings[cur.postings.length - 1].meta[mm[1]] = v;
      else cur.meta[mm[1]] = v;
      continue;
    }
    if (cur.type !== 'txn') { err(ln, '这里只能写 key: value 元数据'); continue; }
    const p = parsePosting(line);
    if (!p) { (cur.bad ||= []).push(line.trim()); continue; }
    postIndent = indent;
    cur.postings.push(p);
  }
  flush();
  return { entries: out, includes, options, plugins, errors };
}

function parsePosting(line) {
  const sc = new Scan(line);
  sc.ws();
  let flag = null;
  const f = sc.peek();
  if (FLAGS.has(f) && /\s/.test(sc.s[sc.i + 1] ?? '')) { flag = f; sc.i++; }
  const account = sc.account();
  if (!account) return null;
  const p = { account, flag, units: null, currency: null, digits: null, cost: null, price: null, meta: {} };
  const n = sc.number();
  if (n) { p.units = n.value; p.digits = n.digits; p.unitsExpr = n; }
  const c = sc.currency();
  if (c) p.currency = c;
  if (n && !c) return null;
  sc.ws();
  if (sc.peek() === '{') {
    const total = sc.peek(2) === '{{';
    sc.i += total ? 2 : 1;
    const close = total ? '}}' : '}';
    const end = sc.s.indexOf(close, sc.i);
    if (end < 0) return null;
    const inner = sc.s.slice(sc.i, end);
    sc.i = end + close.length;
    p.cost = parseCostSpec(inner, total);
    if (!p.cost) return null;
  }
  sc.ws();
  if (sc.peek() === '@') {
    const total = sc.peek(2) === '@@';
    sc.i += total ? 2 : 1;
    const pn = sc.number();
    const pc = sc.currency();
    p.price = { number: null, currency: pc || null, total, raw: pn ? pn.value : null };
    if (pn && p.units != null) p.price.number = total ? Math.abs(pn.value / p.units) : pn.value;
  }
  if (!sc.eof()) return null;
  return p;
}

function parseCostSpec(inner, totalBraces) {
  const spec = { perUnit: null, total: null, currency: null, date: null, label: null, merge: false, totalBraces, raw: inner.trim() };
  if (!inner.trim()) return spec;
  for (const part of splitTopLevel(inner)) {
    const t = part.trim();
    if (!t) continue;
    if (t === '*') { spec.merge = true; continue; }
    const sc = new Scan(t);
    const s = sc.string(); if (s != null) { spec.label = s; continue; }
    const d = sc.date(); if (d && sc.eof()) { spec.date = d; continue; }
    sc.i = 0;
    // [number] [# number] currency
    const a = sc.number();
    let b = null;
    if (sc.eat('#')) b = sc.number();
    const c = sc.currency();
    if (!c && !a && !b) return null;
    if (c) spec.currency = c;
    if (totalBraces) { if (a) spec.total = a.value; }
    else { if (a) spec.perUnit = a.value; if (b) spec.total = b.value; }
    if (!sc.eof()) return null;
  }
  return spec;
}

function splitTopLevel(s) {
  const out = []; let q = false, depth = 0, cur = '';
  for (const ch of s) {
    if (ch === '"') q = !q;
    if (!q && ch === '(') depth++;
    if (!q && ch === ')') depth--;
    if (ch === ',' && !q && !depth) { out.push(cur); cur = ''; } else cur += ch;
  }
  out.push(cur);
  return out;
}

// ---------------------------------------------------------------------------
// weights, interpolation, booking
// ---------------------------------------------------------------------------

export function weight(p) {
  if (p.units == null || p.currency == null) return null;
  if (p.cost && p.cost.number != null && p.cost.currency) return { n: p.units * p.cost.number, c: p.cost.currency };
  if (p.price && p.price.currency && (p.price.number != null || (p.price.total && p.price.raw != null))) {
    if (p.price.total) return { n: Math.sign(p.units) * Math.abs(p.price.raw), c: p.price.currency };
    return { n: p.units * p.price.number, c: p.price.currency };
  }
  return { n: p.units, c: p.currency };
}

// per-currency tolerance inferred from the precision of the numbers in the txn
function tolerances(t) {
  const tol = {};
  for (const p of t.postings) {
    if (p.units == null || p.digits == null || p.interpolated) continue;
    const v = 0.5 * 10 ** -p.digits;
    if (p.currency) tol[p.currency] = Math.max(tol[p.currency] || 0, v);
  }
  return tol;
}

const round = (n, d) => { const f = 10 ** d; return Math.round(n * f) / f; };

// fill one unknown per weight currency: missing units, price number or cost number
function interpolate(t, errors) {
  const unknown = [];
  for (const p of t.postings) {
    if (p.units == null) unknown.push({ p, what: 'units' });
    else if (p.cost && p.cost.number == null && !p.booked && p.cost.currency) unknown.push({ p, what: 'cost' });
    else if (p.price && p.price.raw == null && p.price.currency) unknown.push({ p, what: 'price' });
  }
  if (!unknown.length) return;
  const res = {}, dig = {};
  for (const p of t.postings) {
    const w = weight(p);
    if (!w) continue;
    res[w.c] = (res[w.c] || 0) + w.n;
    if (p.digits != null && p.currency === w.c) dig[w.c] = Math.max(dig[w.c] ?? 0, p.digits);
  }
  const spread = unknown.filter((u) => u.what === 'units' && !u.p.currency);
  const fixed = unknown.filter((u) => !(u.what === 'units' && !u.p.currency));
  for (const u of fixed) {
    const p = u.p;
    const c = u.what === 'units' ? (p.cost?.currency || p.price?.currency || p.currency) : u.what === 'cost' ? p.cost.currency : p.price.currency;
    const r = res[c] || 0;
    if (u.what === 'units') {
      if (p.cost || p.price) { errors.push({ entry: t, msg: '缺数量的分录不能带成本或价格' }); continue; }
      p.units = round(-r, Math.min(dig[c] ?? 2, 8)); p.interpolated = true; p.digits = dig[c] ?? 2;
    } else if (u.what === 'cost') {
      p.cost.number = Math.abs(-r / p.units); p.cost.interpolated = true;
    } else {
      p.price.number = Math.abs(-r / p.units); p.price.raw = p.price.total ? Math.abs(r) : p.price.number; p.price.interpolated = true;
    }
    res[c] = 0;
  }
  if (spread.length > 1) errors.push({ entry: t, msg: '只能有一条分录省略金额' });
  if (spread.length) {
    const m = spread[0].p;
    const ccys = Object.keys(res).filter((c) => Math.abs(res[c]) > EPS);
    const idx = t.postings.indexOf(m);
    const fill = ccys.map((c) => ({ ...m, units: round(-res[c], Math.min(dig[c] ?? 2, 8)), currency: c, digits: dig[c] ?? 2, interpolated: true, meta: m.meta }));
    t.postings.splice(idx, 1, ...(fill.length ? fill : []));
    if (!fill.length) t.postings.splice(idx, 0); // balanced already: drop the empty posting
  }
}

function matchLot(lot, spec) {
  if (spec.currency && lot.cost.currency !== spec.currency) return false;
  if (spec.perUnit != null && Math.abs(lot.cost.number - spec.perUnit) > 1e-7) return false;
  if (spec.date && lot.cost.date !== spec.date) return false;
  if (spec.label != null && lot.cost.label !== spec.label) return false;
  return true;
}

function bookTxn(t, inv, methodOf, errors) {
  for (const p of t.postings) {
    if (!p.cost || p.units == null || !p.currency) continue;
    const lots = (inv[p.account] ||= []);
    const same = lots.filter((l) => l.currency === p.currency && l.cost);
    const reducing = same.some((l) => Math.sign(l.units) === -Math.sign(p.units));
    const method = methodOf(p.account);
    if (!reducing || method === 'NONE') {
      // augmentation: resolve per-unit cost now (may still be missing → interpolation)
      const spec = p.cost;
      if (spec.perUnit != null || spec.total != null) {
        p.cost.number = (spec.perUnit ?? 0) + (spec.total != null ? spec.total / Math.abs(p.units) : 0);
      }
      p.cost.date = spec.date || t.date;
      p.augment = true;
      continue;
    }
    // reduction
    let cands = same.filter((l) => Math.sign(l.units) === -Math.sign(p.units) && matchLot(l, p.cost));
    if (!cands.length) { errors.push({ entry: t, soft: true, msg: `${p.account} 找不到匹配的 ${p.currency} 批次 {${p.cost.raw}}` }); continue; }
    let need = Math.abs(p.units);
    const avail = cands.reduce((s, l) => s + Math.abs(l.units), 0);
    if (avail + 1e-9 < need) errors.push({ entry: t, soft: true, msg: `${p.account} 的 ${p.currency} 不够减：需要 ${fmtNum(need, 4)}，只有 ${fmtNum(avail, 4)}` });
    if (method === 'STRICT' && cands.length > 1 && Math.abs(avail - need) > 1e-9) {
      const costs = new Set(cands.map((l) => l.cost.number + '|' + l.cost.date + '|' + l.cost.label));
      if (costs.size > 1) errors.push({ entry: t, soft: true, msg: `${p.account} 有多个 ${p.currency} 批次符合 {${p.cost.raw}}，STRICT 无法确定，已按 FIFO 处理` });
    }
    if (method === 'LIFO') cands = cands.slice().reverse();
    else if (method === 'HIFO') cands = cands.slice().sort((a, b) => b.cost.number - a.cost.number);
    // AVERAGE: cost basis is the average of all matching lots; units come off oldest first
    const avg = method === 'AVERAGE' ? cands.reduce((s, l) => s + Math.abs(l.units) * l.cost.number, 0) / avail : null;
    let costSum = 0; const booked = [];
    for (const l of cands) {
      if (need <= 1e-12) break;
      const take = Math.min(need, Math.abs(l.units));
      costSum += take * l.cost.number; need -= take;
      booked.push({ lot: l, take });
    }
    const took = Math.abs(p.units) - need;
    p.cost.number = avg != null ? avg : took ? costSum / took : 0;
    p.cost.currency = p.cost.currency || cands[0].cost.currency;
    p.booked = booked;
  }
}

function applyInventory(t, inv) {
  for (const p of t.postings) {
    if (p.units == null || !p.currency) continue;
    const lots = (inv[p.account] ||= []);
    if (p.booked) {
      for (const b of p.booked) {
        if (b.lot) { b.lot.units += Math.sign(p.units) * b.take; }
      }
      for (let i = lots.length - 1; i >= 0; i--) if (Math.abs(lots[i].units) < 1e-9) lots.splice(i, 1);
      continue;
    }
    if (p.cost && p.augment) {
      const key = (l) => l.currency === p.currency && l.cost && l.cost.number === p.cost.number && l.cost.currency === p.cost.currency && l.cost.date === p.cost.date && l.cost.label === (p.cost.label ?? null);
      const hit = lots.find(key);
      if (hit) hit.units += p.units;
      else lots.push({ units: p.units, currency: p.currency, cost: { number: p.cost.number, currency: p.cost.currency, date: p.cost.date, label: p.cost.label ?? null } });
      continue;
    }
    const hit = lots.find((l) => l.currency === p.currency && !l.cost);
    if (hit) hit.units += p.units; else lots.push({ units: p.units, currency: p.currency, cost: null });
  }
}

// ---------------------------------------------------------------------------
// loading
// ---------------------------------------------------------------------------

// readFile(path) => Promise<string>; paths relative to repo root
export async function loadLedger(readFile, root = 'main.bean') {
  const entries = [], files = [], options = {}, plugins = [], errors = [];
  const seen = new Set();
  const dirOf = (p) => (p.includes('/') ? p.slice(0, p.lastIndexOf('/') + 1) : '');
  async function visit(path) {
    if (seen.has(path)) return;
    seen.add(path);
    let text;
    try { text = await readFile(path); } catch (e) { errors.push({ entry: { file: path, line: 0, type: 'include' }, msg: `读不到 ${path}：${e.message}` }); return; }
    files.push(path);
    const r = parseFile(text, path);
    entries.push(...r.entries); errors.push(...r.errors); plugins.push(...r.plugins);
    for (const k in r.options) (options[k] ||= []).push(...r.options[k]);
    for (const inc of r.includes) {
      if (/[*?]/.test(inc)) continue; // globs are not resolvable over the API
      await visit(normalize(inc.startsWith('/') ? inc.slice(1) : dirOf(path) + inc));
    }
  }
  await visit(root);
  return build(entries, files, { options, plugins, errors });
}

function normalize(p) {
  const parts = [];
  for (const s of p.split('/')) { if (s === '..') parts.pop(); else if (s && s !== '.') parts.push(s); }
  return parts.join('/');
}

const ORDER = { open: -2, balance: -1, document: 1, close: 2 };

export function build(entries, files = [], extra = {}) {
  entries.forEach((e, i) => (e._seq = i));
  entries.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : ((ORDER[a.type] ?? 0) - (ORDER[b.type] ?? 0)) || (a._seq - b._seq)));
  const options = extra.options || {};
  const L = {
    entries, files, options, plugins: extra.plugins || [], errors: [...(extra.errors || [])],
    accounts: {}, txns: [], balances: [], prices: [], commodities: {}, pads: [], events: [], notes: [], documents: [],
    base: options.operating_currency?.[0] || 'CNY',
  };
  const defaultBooking = (options.booking_method?.[0] || 'STRICT').toUpperCase();
  const methodOf = (a) => (L.accounts[a]?.booking || defaultBooking).toUpperCase();

  // running state
  const inv = {};           // account -> lots
  const bal = {};           // account -> ccy -> n
  const add = (a, c, n) => { (bal[a] ||= {}); bal[a][c] = (bal[a][c] || 0) + n; };
  const subtotal = (acct, c) => { let s = 0; for (const a in bal) if ((a === acct || a.startsWith(acct + ':')) && bal[a][c]) s += bal[a][c]; return s; };
  const pending = {};       // account -> pad entry
  L.balanceResults = [];
  const synthetic = [];

  for (const e of entries) {
    switch (e.type) {
      case 'open':
        if (L.accounts[e.account] && !L.accounts[e.account].implicit) L.errors.push({ entry: e, msg: `重复开立账户：${e.account}` });
        L.accounts[e.account] = { name: e.account, open: e.date, close: null, currencies: e.currencies, booking: e.booking, meta: e.meta };
        break;
      case 'close':
        if (L.accounts[e.account]) L.accounts[e.account].close = e.date;
        else L.errors.push({ entry: e, msg: `关闭了不存在的账户：${e.account}` });
        break;
      case 'commodity': L.commodities[e.currency] = e.meta; break;
      case 'price': L.prices.push(e); break;
      case 'event': L.events.push(e); break;
      case 'note': L.notes.push(e); break;
      case 'document': L.documents.push(e); break;
      case 'pad':
        L.pads.push(e);
        pending[e.account] = { pad: e, used: new Set() };
        break;
      case 'txn': {
        const t = e;
        if (t.bad) L.errors.push({ entry: t, msg: `无法解析：${t.bad.join(' | ')}` });
        bookTxn(t, inv, methodOf, L.errors);
        interpolate(t, L.errors);
        for (const p of t.postings) {
          const acc = L.accounts[p.account];
          if (!acc) { L.accounts[p.account] = { name: p.account, open: null, close: null, implicit: true }; L.errors.push({ entry: t, msg: `账户未开立：${p.account}` }); }
          else if (acc.open && t.date < acc.open) L.errors.push({ entry: t, msg: `${p.account} 在 ${acc.open} 才开立` });
          else if (acc.close && t.date > acc.close) L.errors.push({ entry: t, msg: `${p.account} 已于 ${acc.close} 关闭` });
          if (acc?.currencies?.length && p.currency && !acc.currencies.includes(p.currency)) L.errors.push({ entry: t, msg: `${p.account} 不允许 ${p.currency}` });
        }
        const sums = {};
        for (const p of t.postings) { const w = weight(p); if (w) sums[w.c] = (sums[w.c] || 0) + w.n; }
        const tol = tolerances(t);
        for (const [c, v] of Object.entries(sums)) if (Math.abs(v) > (tol[c] ?? 0.005) + 1e-9) L.errors.push({ entry: t, msg: `不平衡 ${fmtNum(v, 4)} ${c}` });
        applyInventory(t, inv);
        for (const p of t.postings) if (p.units != null && p.currency) add(p.account, p.currency, p.units);
        L.txns.push(t);
        break;
      }
      case 'balance': {
        L.balances.push(e);
        let got = subtotal(e.account, e.currency);
        const tol = e.tolerance ?? (e.digits > 0 ? 10 ** -e.digits * Number(options.inferred_tolerance_multiplier?.[0] ?? 0.5) * 2 : 0);
        const pd = pending[e.account];
        if (pd && !pd.used.has(e.currency)) {
          pd.used.add(e.currency);
          const diff = e.number - got;
          if (Math.abs(diff) > tol + 1e-9) {
            const t = {
              type: 'txn', date: pd.pad.date, flag: 'P', payee: '', narration: `(Padding inserted for Balance of ${fmtNum(e.number)} ${e.currency} for difference ${fmtNum(diff)} ${e.currency})`,
              tags: [], links: [], meta: {}, file: pd.pad.file, line: pd.pad.line, startLine: pd.pad.startLine, endLine: pd.pad.endLine, synthetic: true, src: pd.pad.src,
              postings: [
                { account: pd.pad.account, units: round(diff, 8), currency: e.currency, digits: e.digits, meta: {} },
                { account: pd.pad.source, units: round(-diff, 8), currency: e.currency, digits: e.digits, meta: {} },
              ],
            };
            for (const p of t.postings) add(p.account, p.currency, p.units);
            applyInventory(t, inv);
            synthetic.push(t);
            got = subtotal(e.account, e.currency);
          }
        }
        const ok = Math.abs(got - e.number) <= tol + 1e-9;
        L.balanceResults.push({ entry: e, got, ok, diff: got - e.number });
        if (!ok) L.errors.push({ entry: e, msg: `余额断言失败：${e.account} 应为 ${fmtNum(e.number)} ${e.currency}，实际 ${fmtNum(got)}（差 ${fmtNum(got - e.number)}）` });
        break;
      }
      default: break;
    }
  }
  if (synthetic.length) {
    L.txns.push(...synthetic);
    L.txns.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : (a._seq ?? 1e12) - (b._seq ?? 1e12)));
  }
  for (const pd of L.pads) if (!pending[pd.account] || pending[pd.account].pad === pd && !pending[pd.account].used.size) L.errors.push({ entry: pd, msg: `pad ${pd.account} 之后没有余额断言，没有生效` });
  L.txns.forEach((t, i) => (t.id = i));
  L.final = bal;
  L.inventory = inv;
  buildRates(L);
  return L;
}

// ---------------------------------------------------------------------------
// currency conversion
// ---------------------------------------------------------------------------

function buildRates(L) {
  const base = L.base;
  const pairs = [];
  for (const p of L.prices) pairs.push({ date: p.date, base: p.currency, quote: p.quote, rate: p.number });
  for (const t of L.txns) for (const p of t.postings) {
    if (p.price && p.price.number && p.currency && p.price.currency && p.currency !== p.price.currency) pairs.push({ date: t.date, base: p.currency, quote: p.price.currency, rate: p.price.number });
    if (p.cost && p.cost.number && p.currency && p.cost.currency && p.currency !== p.cost.currency) pairs.push({ date: t.date, base: p.currency, quote: p.cost.currency, rate: p.cost.number });
  }
  const latest = {};
  const series = {};
  pairs.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  const solve = () => {
    const v = { [base]: 1 };
    let changed = true;
    while (changed) {
      changed = false;
      for (const k in latest) {
        const [a, b] = k.split('>');
        if (v[b] != null && v[a] == null) { v[a] = latest[k] * v[b]; changed = true; }
        else if (v[a] != null && v[b] == null) { v[b] = v[a] / latest[k]; changed = true; }
      }
    }
    return v;
  };
  let i = 0;
  while (i < pairs.length) {
    const d = pairs[i].date;
    while (i < pairs.length && pairs[i].date === d) { const p = pairs[i++]; if (p.rate) latest[p.base + '>' + p.quote] = p.rate; }
    const v = solve();
    for (const c in v) (series[c] ||= []).push({ date: d, v: v[c] });
  }
  L.rates = series;
}

export function toCNY(L, n, c, date) {
  if (c === L.base) return n;
  const s = L.rates[c];
  if (!s || !s.length) return null;
  let lo = 0, hi = s.length - 1, best = 0;
  if (!date) best = hi;
  else while (lo <= hi) { const m = (lo + hi) >> 1; if (s[m].date <= date) { best = m; lo = m + 1; } else hi = m - 1; }
  return n * s[best].v;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

export function fmtNum(n, d = 2) {
  if (n == null || isNaN(n)) return '';
  const s = Math.abs(n).toFixed(d);
  const [i, f] = s.split('.');
  return (n < -EPS ? '-' : '') + i.replace(/\B(?=(\d{3})+(?!\d))/g, ',') + (f ? '.' + f : '');
}

export function balancesAt(L, date) {
  const bal = {};
  for (const t of L.txns) {
    if (date && t.date > date) break;
    for (const p of t.postings) { if (p.units == null) continue; (bal[p.account] ||= {}); bal[p.account][p.currency] = (bal[p.account][p.currency] || 0) + p.units; }
  }
  return bal;
}

// Check a piece of text the user is about to add: parses every directive in it,
// and runs transactions through booking/interpolation against the ledger as it is now.
export function checkText(text, L) {
  const r = parseFile(text, 'draft');
  const errors = [...r.errors];
  if (r.includes.length || Object.keys(r.options).length || r.plugins.length) errors.push({ msg: 'include / option / plugin 请直接改 main.bean' });
  const inv = structuredCloneSafe(L?.inventory || {});
  const methodOf = (a) => (L?.accounts[a]?.booking || L?.options?.booking_method?.[0] || 'STRICT').toUpperCase();
  for (const e of r.entries) {
    if (e.type === 'txn') {
      if (e.bad) errors.push({ entry: e, msg: '无法解析：' + e.bad[0] });
      if (e.postings.length < 1) errors.push({ entry: e, msg: '交易至少需要一条分录' });
      const errs = [];
      bookTxn(e, inv, methodOf, errs);
      interpolate(e, errs);
      errors.push(...errs);
      const sums = {};
      for (const p of e.postings) { const w = weight(p); if (w) sums[w.c] = (sums[w.c] || 0) + w.n; }
      const tol = tolerances(e);
      for (const [c, v] of Object.entries(sums)) if (Math.abs(v) > (tol[c] ?? 0.005) + 1e-9) errors.push({ entry: e, msg: `不平衡：差 ${fmtNum(v, 4)} ${c}` });
      for (const p of e.postings) if (L && !L.accounts[p.account] && !r.entries.some((x) => x.type === 'open' && x.account === p.account)) errors.push({ entry: e, msg: '账户未开立：' + p.account });
      applyInventory(e, inv);
    } else if (['balance', 'pad', 'note', 'document', 'close'].includes(e.type)) {
      for (const a of [e.account, e.source].filter(Boolean)) if (L && !L.accounts[a] && !r.entries.some((x) => x.type === 'open' && x.account === a)) errors.push({ entry: e, msg: '账户未开立：' + a });
    } else if (e.type === 'open' && L?.accounts[e.account] && !L.accounts[e.account].implicit) errors.push({ entry: e, msg: '账户已经开立过：' + e.account });
  }
  if (!r.entries.length && !errors.length) errors.push({ msg: '没有可以写入的内容' });
  const hard = errors.filter((e) => !e.soft);
  return { ok: !hard.length, errors: hard, warnings: errors.filter((e) => e.soft), entries: r.entries, msg: hard[0]?.msg };
}

function structuredCloneSafe(inv) {
  const out = {};
  for (const a in inv) out[a] = inv[a].map((l) => ({ ...l, cost: l.cost ? { ...l.cost } : null }));
  return out;
}

// ---------------------------------------------------------------------------
// writing (matches the user's formatting: number ends at col 59)
// ---------------------------------------------------------------------------

export const NUM_END = 59;

export function numText(n) {
  if (typeof n === 'string') return n;
  const s = String(round(n, 10));
  const d = (s.split('.')[1] || '').length;
  return n.toFixed(Math.max(2, Math.min(d, 10)));
}

export function fmtPostingLine(account, units, currency, suffix = '', flag = null) {
  const left = '  ' + (flag ? flag + ' ' : '') + account;
  if (units == null || units === '') return left + (currency ? '  ' + currency : '') + (suffix ? ' ' + suffix : '');
  const ns = numText(units);
  const pad = Math.max(2, NUM_END - left.length - ns.length);
  return left + ' '.repeat(pad) + ns + ' ' + currency + (suffix ? ' ' + suffix : '');
}

const q = (s) => '"' + String(s ?? '').replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';

const metaLine = (indent, k, v) => `${indent}${k}: ${typeof v === 'string' && !/^(\d{4}-\d{2}-\d{2}|TRUE|FALSE|-?[\d.]+(\s+[A-Z][A-Z0-9'._-]*)?)$/.test(v) ? q(v) : v}`;

// tx: {date, flag?, payee, narration, tags[], links[], meta{}, postings:[{account, units|string|null, currency, flag?, cost?: "335.5 USD"|"{...}", price?: "@ 1.19 HKD", priceTotal?, priceCcy?, meta?}]}
export function formatTxn(tx) {
  const head = [tx.date, tx.flag || '*'];
  if (tx.payee || tx.hasPayee !== false) head.push(q(tx.payee));
  head.push(q(tx.narration));
  for (const t of tx.tags || []) head.push('#' + t);
  for (const l of tx.links || []) head.push('^' + l);
  const lines = [head.join(' ')];
  for (const [k, v] of Object.entries(tx.meta || {})) lines.push(metaLine('  ', k, v));
  for (const p of tx.postings) {
    const sfx = [];
    if (p.cost) sfx.push(/^\{/.test(p.cost) ? p.cost : `{${p.cost}}`);
    if (p.price) sfx.push(/^@/.test(p.price) ? p.price : `@ ${p.price}`);
    if (p.priceTotal != null) sfx.push(`@@ ${Number(p.priceTotal).toFixed(2)} ${p.priceCcy}`);
    lines.push(fmtPostingLine(p.account, p.units, p.currency, sfx.join(' '), p.flag));
    for (const [k, v] of Object.entries(p.meta || {})) lines.push(metaLine('    ', k, v));
  }
  return lines.join('\n');
}

// insert a formatted entry into a file, keeping date order
// (after the last dated entry whose date <= new date)
export function insertEntry(text, entryText, date) {
  const lines = text.replace(/\s+$/, '').split('\n');
  if (lines.length === 1 && lines[0] === '') return entryText + '\n';
  const blocks = [];
  for (let i = 0; i < lines.length; i++) {
    const m = /^(\d{4}-\d{2}-\d{2})\s/.exec(lines[i]);
    if (m) blocks.push({ i, date: m[1] });
  }
  let lastLE = -1;
  for (let b = 0; b < blocks.length; b++) if (blocks[b].date <= date) lastLE = b;
  let insertAt;
  if (lastLE === -1) {
    if (blocks.length) {
      insertAt = blocks[0].i;
      return [...lines.slice(0, insertAt), ...entryText.split('\n'), '', ...lines.slice(insertAt)].join('\n') + '\n';
    }
    insertAt = lines.length;
  } else {
    let j = blocks[lastLE].i + 1;
    while (j < lines.length && lines[j].trim() !== '' && !/^\d{4}-/.test(lines[j]) && /^[ \t]/.test(lines[j])) j++;
    insertAt = j;
  }
  const before = lines.slice(0, insertAt);
  const after = lines.slice(insertAt);
  while (after.length && after[0].trim() === '') after.shift();
  // single-line directives in a run of single-line directives (balance/price/open) stay compact
  const single = !entryText.includes('\n');
  const prevSingle = before.length && /^\d{4}-/.test(before[before.length - 1]);
  const nextSingle = after.length && /^\d{4}-/.test(after[0]) && !/^[ \t]/.test(after[1] ?? '');
  const sepBefore = single && prevSingle ? [] : [''];
  const sepAfter = !after.length ? [] : single && nextSingle ? [] : [''];
  return [...before, ...sepBefore, ...entryText.split('\n'), ...sepAfter, ...after].join('\n') + '\n';
}

// Re-align plain-number amounts to the ledger's column (postings, balance, price lines).
// Never changes content: expressions, comments and anything unrecognised are left alone.
export function alignText(text) {
  const NUM = String.raw`-?\d[\d,]*(?:\.\d+)?`;
  const CUR = String.raw`[A-Z][A-Z0-9'._\-]*`;
  const post = new RegExp(String.raw`^(\s+)((?:[!*&#?%PSTCURM]\s+)?[A-Z\p{Lu}][^\s]*)\s+(${NUM})\s+(${CUR})(\s.*)?$`, 'u');
  const dirx = new RegExp(String.raw`^(\d{4}-\d{2}-\d{2}\s+(?:balance\s+\S+|price\s+\S+))\s+(${NUM})(\s*~\s*${NUM})?\s+(${CUR})(\s.*)?$`);
  return text.split('\n').map((l) => {
    let m = post.exec(l);
    if (m && ACCOUNT_RE.test(m[2].replace(/^[!*&#?%PSTCURM]\s+/, ''))) {
      const left = '  ' + m[2].replace(/\s+/, ' ');
      const pad = Math.max(2, NUM_END - left.length - m[3].length);
      return left + ' '.repeat(pad) + m[3] + ' ' + m[4] + (m[5] ? ' ' + m[5].trim() : '');
    }
    m = dirx.exec(l);
    if (m) {
      const left = m[1].replace(/\s+/g, ' ');
      const pad = Math.max(1, NUM_END - left.length - m[2].length);
      return left + ' '.repeat(pad) + m[2] + (m[3] ? ' ~ ' + m[3].replace(/[\s~]/g, '') : '') + ' ' + m[4] + (m[5] ? ' ' + m[5].trim() : '');
    }
    return l;
  }).join('\n');
}
