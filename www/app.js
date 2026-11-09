'use strict';

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

/** DOM builder: el('div', {class: 'x', onclick: fn}, 'text', childNode, [more]) */
function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k.startsWith('on') && typeof v === 'function') node.addEventListener(k.slice(2), v);
    else if (k === 'class') node.className = v;
    else if (k === 'dataset') Object.assign(node.dataset, v);
    else if (k === 'style') node.style.cssText = v; // CSSOM is allowed by the page's CSP, style="" attributes are not
    else if (k in node && typeof v !== 'string') node[k] = v;
    else node.setAttribute(k, v === true ? '' : v);
  }
  appendAll(node, ...children);
  return node;
}
function appendAll(node, ...children) {
  for (const c of children.flat(Infinity)) {
    if (c === null || c === undefined || c === false) continue;
    node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return node;
}
function clear(node, ...children) { node.replaceChildren(); return appendAll(node, ...children); }

async function api(path, options = {}) {
  const opts = { headers: { 'X-Requested-With': 'PoshAcmeDashboard' }, ...options };
  if (opts.body && typeof opts.body !== 'string') {
    opts.body = JSON.stringify(opts.body);
    opts.headers['Content-Type'] = 'application/json';
  }
  const res = await fetch('api/' + path, opts);
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { /* not json */ }
  if (!res.ok) throw new Error((data && data.error) || `${res.status} ${res.statusText}`);
  return data;
}

function toast(msg, bad = false) {
  const t = el('div', { class: 'toast' + (bad ? ' bad' : '') }, msg);
  $('#toasts').append(t);
  setTimeout(() => t.remove(), bad ? 7000 : 4000);
}

const DAY = 86400000;
const fmtDate = (iso) => iso ? new Date(iso).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : '—';
const fmtDateTime = (iso) => iso ? new Date(iso).toLocaleString(undefined, { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—';
function fmtRelative(iso) {
  if (!iso) return '—';
  const diff = new Date(iso) - Date.now();
  const abs = Math.abs(diff);
  const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });
  if (abs < 3600e3) return rtf.format(Math.round(diff / 60e3), 'minute');
  if (abs < DAY) return rtf.format(Math.round(diff / 3600e3), 'hour');
  return rtf.format(Math.round(diff / DAY), 'day');
}
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

async function copyText(text) {
  try { await navigator.clipboard.writeText(text); toast('Copied to clipboard'); }
  catch { window.prompt('Copy:', text); }
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const HEALTH = {
  'valid':       { label: 'Valid',          cls: 'ok',   rank: 4 },
  'renewal-due': { label: 'Renewal due',    cls: 'warn', rank: 3 },
  'expiring':    { label: 'Expiring',       cls: 'bad',  rank: 1 },
  'expired':     { label: 'Expired',        cls: 'bad',  rank: 0 },
  'pending':     { label: 'Not issued',     cls: '',     rank: 2 },
  'invalid':     { label: 'Failed',         cls: 'bad',  rank: 2 },
};
const SERVER_LABELS = {
  LE_PROD: "Let's Encrypt", LE_STAGE: "Let's Encrypt (staging)", ZEROSSL_PROD: 'ZeroSSL',
  GOOGLE_PROD: 'Google Trust Services', GOOGLE_STAGE: 'Google (staging)', SSLCOM_RSA: 'SSL.com RSA',
  SSLCOM_ECC: 'SSL.com ECC', ACTALIS_PROD: 'Actalis',
};
const KEY_TYPES = ['2048', '3072', '4096', 'ec-256', 'ec-384'];
const TESTABLE_PLUGINS = ['GoDaddy'];

const state = {
  info: null,
  overview: null,
  tasks: null,
  jobs: [],
  plugins: null,
  templates: null,
  pluginDetail: new Map(),
  rows: [],
  filter: { health: null, search: '', server: '' },
  sort: { key: 'expires', desc: false },
  drawerKey: null,
  selectedJob: null,
  lastLoaded: null,
  deploy: null,
};

function serverLabel(url) {
  if (!url) return '—';
  const known = state.info && Object.entries(state.info.wellKnownServers).find(([, u]) => u === url);
  if (known) return SERVER_LABELS[known[0]] || known[0];
  try { return new URL(url).host; } catch { return url; }
}
const isStaging = (url) => /stag|test/i.test(url || '');

function flattenOrders(overview) {
  const rows = [];
  for (const s of overview.servers) {
    for (const a of s.accounts) {
      for (const o of a.orders) {
        rows.push({
          ...o,
          key: `${s.name}|${a.id}|${o.name}`,
          serverName: s.name,
          serverUrl: s.location,
          serverIsCurrent: s.isCurrent,
          account: a.id,
          accountObj: a,
          expires: o.cert ? o.cert.notAfter : o.certExpires,
        });
      }
    }
  }
  return rows;
}

function rowByKey(key) { return state.rows.find((r) => r.key === key); }

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

async function loadAll() {
  const btn = $('#refresh');
  btn.disabled = true;
  try {
    const [overview, tasks] = await Promise.all([api('overview'), api('tasks').catch(() => null)]);
    state.overview = overview;
    state.tasks = tasks;
    state.rows = flattenOrders(overview);
    state.lastLoaded = Date.now();
    renderAll();
    loadDeployments();
  } catch (e) {
    toast('Refresh failed: ' + e.message, true);
  } finally {
    btn.disabled = false;
  }
}

function usedOnCell(r) {
  const d = r.deployments;
  if (!d) return el('span', { class: 'muted' }, '—');
  return el('div', {},
    el('span', {}, plural(d.total, 'server')),
    d.outdated ? el('div', {}, el('span', { class: 'pill bad' }, `${d.outdated} old`)) : null,
    !d.outdated && d.problem ? el('div', {}, el('span', { class: 'pill warn' }, `${d.problem} problem${d.problem === 1 ? '' : 's'}`)) : null,
    !d.outdated && !d.problem && d.current === d.total ? el('div', { class: 'muted small' }, 'all up to date') : null);
}

function renderAll() {
  renderBanners();
  renderServerFilter();
  renderKpis();
  renderTable();
  renderServers();
  renderRenewal();
  if (state.drawerKey) {
    const r = rowByKey(state.drawerKey);
    if (r) renderDrawer(r); else closeDrawer();
  }
  updateClock();
}

function updateClock() {
  if (state.lastLoaded) $('#updated').textContent = 'Updated ' + fmtRelative(new Date(state.lastLoaded).toISOString());
}

// ---------------------------------------------------------------------------
// Banners
// ---------------------------------------------------------------------------

function renderBanners() {
  const host = $('#banners');
  const out = [];
  const expired = state.rows.filter((r) => r.health === 'expired' && !isStaging(r.serverUrl));
  const expiring = state.rows.filter((r) => r.health === 'expiring' && !isStaging(r.serverUrl));
  if (expired.length) out.push(el('div', { class: 'banner bad' }, el('strong', {}, plural(expired.length, 'certificate') + ' expired: '), expired.map((r) => r.mainDomain).join(', ')));
  if (expiring.length) out.push(el('div', { class: 'banner bad' }, el('strong', {}, plural(expiring.length, 'certificate') + ' expire within 7 days: '), expiring.map((r) => r.mainDomain).join(', ')));
  if (state.tasks && state.tasks.supported && !state.tasks.error && state.tasks.tasks.length === 0 && state.rows.length) {
    out.push(el('div', { class: 'banner warn' },
      el('span', {}, el('strong', {}, 'No renewal scheduled task found. '),
        'Certificates will not renew automatically. ',
        el('a', { href: '#', onclick: (e) => { e.preventDefault(); showTab('renewal'); } }, 'Set up auto-renewal'))));
  }
  if (state.info && state.info.readOnlyMode) {
    out.push(el('div', { class: 'banner info banner-action' },
      el('span', {}, el('strong', {}, 'Read-only mode. '), 'Nothing can be renewed or changed, no email is sent, and your Posh-ACME config is not touched.'),
      state.info.canTestCredentials ? el('button', { class: 'btn sm', onclick: godaddyTestDialog }, 'Test GoDaddy credentials') : null));
  } else if (state.info && !state.info.canWrite) {
    out.push(el('div', { class: 'banner info' }, 'You have read-only access. Actions are disabled.'));
  }
  clear(host, out);
}

// ---------------------------------------------------------------------------
// KPIs, filters, table
// ---------------------------------------------------------------------------

function renderServerFilter() {
  const sel = $('#server-filter');
  const servers = state.overview.servers;
  const keep = state.filter.server;
  clear(sel,
    el('option', { value: '' }, 'All servers'),
    servers.map((s) => el('option', { value: s.name }, serverLabel(s.location) + (s.isCurrent ? ' (current)' : ''))));
  sel.value = servers.some((s) => s.name === keep) ? keep : '';
  state.filter.server = sel.value;
  sel.classList.toggle('hidden', servers.length < 2);
}

function rowsForServer() {
  return state.rows.filter((r) => !state.filter.server || r.serverName === state.filter.server);
}

function renderKpis() {
  const rows = rowsForServer();
  const count = (...h) => rows.filter((r) => h.includes(r.health)).length;
  const tiles = [
    { key: null,          label: 'Certificates',   value: rows.length, color: 'var(--accent)', hint: plural(new Set(rows.map((r) => r.account)).size, 'account') },
    { key: 'valid',       label: 'Valid',          value: count('valid'), color: 'var(--ok)', hint: 'Not yet due' },
    { key: 'renewal-due', label: 'Renewal due',    value: count('renewal-due'), color: 'var(--warn)', hint: 'Past renew-after date' },
    { key: 'expiring',    label: 'Expiring ≤ 7 days', value: count('expiring'), color: 'var(--bad)', hint: 'Needs attention' },
    { key: 'expired',     label: 'Expired',        value: count('expired'), color: 'var(--bad)', hint: '' },
    { key: 'pending',     label: 'Not issued / failed', value: count('pending', 'invalid'), color: 'var(--muted)', hint: 'No certificate yet' },
  ];
  clear($('#kpis'), tiles.map((t) => el('button', {
    class: 'kpi' + (state.filter.health === t.key && t.key !== null ? ' active' : ''),
    style: `--kpi-color:${t.color}`,
    onclick: () => { state.filter.health = state.filter.health === t.key ? null : t.key; renderKpis(); renderTable(); },
  }, el('div', { class: 'label' }, t.label), el('div', { class: 'value' }, t.value), el('div', { class: 'hint' }, t.hint))));
}

function statusPill(health) {
  const h = HEALTH[health] || { label: health, cls: '' };
  return el('span', { class: 'pill ' + h.cls }, el('span', { class: 'dot' }), h.label);
}

function lifeCell(r) {
  if (!r.cert || !r.cert.notAfter) return el('span', { class: 'muted' }, r.status ? `Order ${r.status}` : '—');
  const start = new Date(r.cert.notBefore), end = new Date(r.cert.notAfter);
  const days = Math.floor((end - Date.now()) / DAY);
  const pct = Math.max(0, Math.min(100, ((end - Date.now()) / (end - start)) * 100));
  const cls = days < 0 ? 'bad' : days <= 7 ? 'bad' : r.health === 'renewal-due' ? 'warn' : '';
  return el('div', { class: 'life ' + cls, title: fmtDateTime(r.cert.notAfter) },
    el('span', { class: 'days' }, days < 0 ? `Expired ${-days}d ago` : `${days} days`),
    el('span', { class: 'muted small' }, ' · ' + fmtDate(r.cert.notAfter)),
    el('div', { class: 'bar' }, el('span', { style: `width:${pct.toFixed(1)}%` })));
}

function sortValue(r, key) {
  switch (key) {
    case 'health': return (HEALTH[r.health] || {}).rank ?? 9;
    case 'expires': return r.expires ? new Date(r.expires).getTime() : Infinity;
    case 'renewAfter': return r.renewAfter ? new Date(r.renewAfter).getTime() : Infinity;
    case 'plugin': return (r.plugin || []).join(',').toLowerCase();
    case 'account': return r.account;
    case 'usedOn': return r.deployments ? -(r.deployments.outdated * 1000 + r.deployments.problem * 100 + r.deployments.total) : 1;
    default: return String(r[key] || '').toLowerCase();
  }
}

function filteredRows() {
  const q = state.filter.search.trim().toLowerCase();
  let rows = rowsForServer();
  if (state.filter.health === 'pending') rows = rows.filter((r) => r.health === 'pending' || r.health === 'invalid');
  else if (state.filter.health) rows = rows.filter((r) => r.health === state.filter.health);
  if (q) {
    rows = rows.filter((r) => [r.name, r.mainDomain, ...(r.sans || []), ...(r.plugin || []), r.friendlyName, r.account, r.cert && r.cert.thumbprint]
      .some((v) => v && String(v).toLowerCase().includes(q)));
  }
  const { key, desc } = state.sort;
  return rows.sort((a, b) => {
    const va = sortValue(a, key), vb = sortValue(b, key);
    const c = va < vb ? -1 : va > vb ? 1 : 0;
    return desc ? -c : c;
  });
}

function renderTable() {
  const rows = filteredRows();
  $$('#cert-table th[data-sort]').forEach((th) => {
    th.classList.toggle('sorted', th.dataset.sort === state.sort.key);
    th.classList.toggle('desc', th.dataset.sort === state.sort.key && state.sort.desc);
  });
  const multiServer = state.overview.servers.length > 1;
  clear($('#cert-table tbody'), rows.map((r) => el('tr', { onclick: () => openDrawer(r.key) },
    el('td', {}, statusPill(r.health)),
    el('td', { class: 'cell-domain' },
      r.mainDomain || r.name,
      el('div', { class: 'sub' },
        r.sans && r.sans.length ? `+${plural(r.sans.length, 'SAN')}` : 'Single name',
        r.name !== r.mainDomain && r.name !== (r.mainDomain || '').replace('*', '!') ? ` · ${r.name}` : '',
        multiServer || isStaging(r.serverUrl) ? ` · ${serverLabel(r.serverUrl)}` : '')),
    el('td', {}, lifeCell(r)),
    el('td', { title: fmtDateTime(r.renewAfter) }, r.renewAfter ? fmtDate(r.renewAfter) : el('span', { class: 'muted' }, '—'),
      r.renewAfter ? el('div', { class: 'muted small' }, fmtRelative(r.renewAfter)) : null),
    el('td', {}, (r.plugin || []).length ? r.plugin.join(', ') : el('span', { class: 'muted' }, 'none')),
    el('td', { class: 'col-optional' }, usedOnCell(r)),
    el('td', { class: 'col-optional' }, el('span', { class: 'mono' }, r.account), r.accountObj.contact.length ? el('div', { class: 'muted small' }, r.accountObj.contact[0]) : null),
    el('td', { class: 'actions-col', onclick: (e) => e.stopPropagation() },
      el('div', { class: 'row-actions write-only' },
        el('button', { class: 'btn sm', disabled: !(r.plugin || []).length, onclick: () => renewOrder(r) }, 'Renew'))),
  )));
  const empty = $('#cert-empty');
  if (!state.rows.length) {
    clear(empty, el('p', {}, el('strong', {}, 'No certificates yet.')),
      el('p', {}, 'Posh-ACME config folder: ', el('code', {}, state.overview.configRoot)),
      state.info.canWrite ? el('button', { class: 'btn primary', onclick: newCertificateDialog }, '+ New certificate') : null);
  } else {
    clear(empty, 'No certificates match the current filter.');
  }
  empty.classList.toggle('hidden', rows.length > 0);
}

// ---------------------------------------------------------------------------
// Drawer
// ---------------------------------------------------------------------------

function openDrawer(key) {
  const r = rowByKey(key);
  if (!r) return;
  state.drawerKey = key;
  renderDrawer(r);
  $('#drawer').classList.add('open');
  $('#drawer').setAttribute('aria-hidden', 'false');
  $('#scrim').classList.remove('hidden');
}

function closeDrawer() {
  state.drawerKey = null;
  $('#drawer').classList.remove('open');
  $('#drawer').setAttribute('aria-hidden', 'true');
  $('#scrim').classList.add('hidden');
}

function kv(pairs) {
  return el('dl', { class: 'kv' }, pairs.filter(([, v]) => v !== undefined).map(([k, v]) => [el('dt', {}, k), el('dd', {}, v ?? '—')]));
}

function fileUrl(r, kind) {
  return `api/servers/${encodeURIComponent(r.serverName)}/accounts/${encodeURIComponent(r.account)}/orders/${encodeURIComponent(r.name)}/files/${kind}`;
}

function renderDrawer(r) {
  clear($('#drawer-status'), statusPill(r.health), r.isCurrent ? el('span', { class: 'pill accent', style: 'margin-left:6px' }, 'current order') : null);
  $('#drawer-title').textContent = r.mainDomain || r.name;
  $('#drawer-sub').textContent = `${serverLabel(r.serverUrl)} · account ${r.account}`;

  const hasCert = !!(r.cert && r.cert.notAfter);
  clear($('#drawer-actions'),
    el('button', { class: 'btn primary', disabled: !(r.plugin || []).length, onclick: () => renewOrder(r) }, 'Renew now'),
    el('button', { class: 'btn', onclick: () => pluginDialog(r) }, 'Validation settings'),
    el('div', { class: 'spacer' }),
    hasCert ? el('button', { class: 'btn danger', onclick: () => revokeDialog(r) }, 'Revoke') : null,
    el('button', { class: 'btn danger', onclick: () => deleteDialog(r) }, 'Delete'));

  const c = r.cert;
  const body = [];
  if (r.error) body.push(el('div', { class: 'banner bad' }, r.error));
  if ((r.plugin || []).includes('Manual')) {
    body.push(el('div', { class: 'banner warn' }, 'This order uses the Manual DNS plugin, so it cannot renew automatically. Change the validation plugin or renew it from a PowerShell prompt.'));
  }

  body.push(el('h3', {}, 'Names'));
  body.push(el('div', { class: 'chips' }, [r.mainDomain, ...(r.sans || [])].filter(Boolean).map((d) => el('span', { class: 'chip' }, d))));
  body.push(...drawerDeployments(r));

  if (c && c.error) {
    body.push(el('div', { class: 'banner bad' }, c.error));
  } else if (hasCert) {
    body.push(el('h3', {}, 'Certificate'));
    body.push(kv([
      ['Valid from', fmtDateTime(c.notBefore)],
      ['Valid until', el('span', {}, fmtDateTime(c.notAfter), el('span', { class: 'muted' }, ` (${fmtRelative(c.notAfter)})`))],
      ['Renew after', r.renewAfter ? el('span', {}, fmtDateTime(r.renewAfter), el('span', { class: 'muted' }, ` (${fmtRelative(r.renewAfter)})`)) : '—'],
      ['Issuer', el('span', { title: c.issuerFull }, c.issuer)],
      ['Thumbprint', el('span', { class: 'mono copy', title: 'Click to copy', onclick: () => copyText(c.thumbprint) }, c.thumbprint)],
      ['Serial', el('span', { class: 'mono copy', title: 'Click to copy', onclick: () => copyText(c.serial) }, c.serial)],
      ['Key', `${c.keyAlg || ''} ${r.keyLength ? '(' + r.keyLength + ')' : ''}`.trim()],
      ['Signature', c.sigAlg],
    ]));
    body.push(el('h3', {}, 'Download'));
    body.push(el('div', { class: 'chips' },
      ['cert', 'chain', 'fullchain'].filter((k) => c.files[k + '.cer'])
        .map((k) => el('a', { class: 'btn sm', href: fileUrl(r, k), download: '' }, `${k}.pem`))));
    body.push(el('p', { class: 'muted small' }, 'Private keys and PFX files are never served by the dashboard. They are in the order folder on the server.'));
  }

  body.push(el('h3', {}, 'Order'));
  body.push(kv([
    ['Order name', el('span', { class: 'mono' }, r.name)],
    ['ACME status', r.status],
    ['Validation', (r.plugin || []).join(', ') || 'none'],
    ['DNS alias', r.dnsAlias && r.dnsAlias.length ? r.dnsAlias.join(', ') : undefined],
    ['DNS sleep', r.dnsSleep != null ? `${r.dnsSleep}s` : undefined],
    ['Validation timeout', r.validationTimeout != null ? `${r.validationTimeout}s` : undefined],
    ['Key length', r.keyLength],
    ['New key on renew', r.alwaysNewKey ? 'Yes' : 'No'],
    ['Friendly name', r.friendlyName],
    ['Install to store', r.install ? 'Yes (LocalMachine\\My)' : 'No'],
    ['Lifetime', r.lifetimeDays ? `${r.lifetimeDays} days` : undefined],
    ['Preferred chain', r.preferredChain || undefined],
    ['Profile', r.profile || undefined],
    ['Created from CSR', r.fromCsr ? 'Yes' : undefined],
  ]));

  body.push(el('h3', {}, 'Location'));
  body.push(kv([
    ['Folder', el('span', { class: 'mono copy', title: 'Click to copy', onclick: () => copyText(r.folder) }, r.folder)],
    ['ACME server', r.serverUrl],
    ['Account', el('span', {}, r.account, r.accountObj.contact.length ? ` (${r.accountObj.contact.join(', ')})` : '')],
  ]));
  if (!r.serverIsCurrent) {
    body.push(el('p', { class: 'muted small' }, 'This order is not on the current ACME server, so a plain "Submit-Renewal -AllAccounts" task will not renew it. See the Auto-renewal tab.'));
  }

  clear($('#drawer-body'), body);
}

// ---------------------------------------------------------------------------
// Servers & accounts
// ---------------------------------------------------------------------------

function renderServers() {
  const host = $('#servers');
  if (!state.overview.servers.length) {
    clear(host, el('div', { class: 'card' }, el('p', {}, 'No ACME servers configured yet. Create a certificate or an account to get started.')));
    return;
  }
  clear(host, state.overview.servers.map((s) => el('section', { class: 'server-card' },
    el('header', {},
      el('h3', {}, serverLabel(s.location)),
      s.isCurrent ? el('span', { class: 'pill accent' }, 'current') : null,
      isStaging(s.location) ? el('span', { class: 'pill warn' }, 'staging / test') : null,
      el('span', { class: 'muted small mono' }, s.location),
      el('div', { class: 'spacer' }),
      s.tosUrl ? el('a', { href: s.tosUrl, target: '_blank', rel: 'noopener', class: 'small' }, 'Terms of service') : null),
    s.accounts.length ? s.accounts.map((a) => {
      const counts = {};
      a.orders.forEach((o) => { counts[o.health] = (counts[o.health] || 0) + 1; });
      return el('div', { class: 'account-row' },
        el('div', {},
          el('div', {}, el('span', { class: 'acct-id' }, a.id), ' ',
            a.isCurrent ? el('span', { class: 'pill accent' }, 'current') : null, ' ',
            el('span', { class: 'pill ' + (a.status === 'valid' ? 'ok' : 'bad') }, a.status || 'unknown')),
          el('div', { class: 'muted small' }, a.contact.length ? a.contact.join(', ') : 'No contact email', a.keyLength ? ` · key ${a.keyLength}` : '')),
        el('div', { class: 'spacer' }),
        el('div', { class: 'counts' },
          a.orders.length ? Object.entries(counts).map(([h, n]) => el('span', { class: 'pill ' + ((HEALTH[h] || {}).cls || '') }, `${n} ${(HEALTH[h] || { label: h }).label.toLowerCase()}`))
            : el('span', { class: 'muted small' }, 'No orders')),
        el('button', { class: 'btn sm', onclick: () => { state.filter.server = s.name; state.filter.search = a.id; $('#search').value = a.id; showTab('certs'); renderAll(); } }, 'View'),
        el('button', { class: 'btn sm write-only', disabled: !a.orders.length || a.status !== 'valid', onclick: () => renewAccount(s, a) }, 'Renew due'));
    }) : el('div', { class: 'account-row muted' }, 'No accounts on this server.'))));
}

// ---------------------------------------------------------------------------
// Auto-renewal
// ---------------------------------------------------------------------------

const TASK_RESULTS = { 0: 'Success', 267009: 'Running', 267011: 'Never run', 267010: 'Disabled', 2147750687: 'Already running' };

function renderRenewal() {
  const host = $('#renewal');
  const t = state.tasks;
  const runAs = state.info.runAs;
  const parts = [];

  if (!t) {
    parts.push(el('div', { class: 'card' }, 'Could not load scheduled tasks.'));
  } else if (!t.supported) {
    parts.push(el('div', { class: 'card' }, 'Scheduled task information is not available on this system.'));
  } else if (t.error) {
    parts.push(el('div', { class: 'card' }, 'Could not read scheduled tasks: ', t.error));
  } else if (t.tasks.length) {
    parts.push(el('div', { class: 'table-wrap', style: 'margin-bottom:16px' }, el('table', { class: 'grid' },
      el('thead', {}, el('tr', {}, ['Task', 'State', 'Runs as', 'Last run', 'Last result', 'Next run'].map((h) => el('th', {}, h)))),
      el('tbody', {}, t.tasks.map((task) => {
        const ok = task.lastTaskResult === 0;
        const label = TASK_RESULTS[task.lastTaskResult] || (task.lastTaskResult == null ? '—' : `0x${(task.lastTaskResult >>> 0).toString(16)}`);
        return el('tr', { style: 'cursor:default' },
          el('td', {}, el('strong', {}, task.name), el('div', { class: 'muted small mono' }, task.path), el('div', { class: 'muted small mono' }, task.command)),
          el('td', {}, el('span', { class: 'pill ' + (task.state === 'Ready' || task.state === 'Running' ? 'ok' : 'warn') }, task.state)),
          el('td', { class: 'mono' }, task.runAs || '—'),
          el('td', {}, fmtDateTime(task.lastRunTime), task.lastRunTime ? el('div', { class: 'muted small' }, fmtRelative(task.lastRunTime)) : null),
          el('td', {}, el('span', { class: 'pill ' + (ok ? 'ok' : task.lastTaskResult === 267011 ? '' : 'bad') }, label)),
          el('td', {}, fmtDateTime(task.nextRunTime)));
      })))));
  } else {
    parts.push(el('div', { class: 'banner warn', style: 'margin:0 0 16px' }, 'No scheduled task that runs Submit-Renewal was found on this machine.'));
  }

  const nonCurrent = state.overview.servers.filter((s) => !s.isCurrent && s.accounts.some((a) => a.orders.length));
  parts.push(el('div', { class: 'card' },
    el('h3', {}, 'How renewal works'),
    el('p', {}, 'Posh-ACME stores its configuration per Windows user (', el('code', {}, state.overview.configRoot),
      '), so the renewal task must run as the same user as this dashboard: ', el('code', {}, runAs), '.'),
    el('p', {}, el('code', {}, 'Submit-Renewal -AllAccounts'), ' renews every order that is past its renew-after date, for all accounts on the ',
      el('strong', {}, 'current'), ' ACME server. Run it daily.'),
    nonCurrent.length ? el('div', { class: 'banner warn' }, 'Orders also exist on ', nonCurrent.map((s) => serverLabel(s.location)).join(', '),
      ', which is not the current server. Use the multi-server command below so those renew too.') : null));

  const single = `$action = New-ScheduledTaskAction -Execute 'pwsh.exe' \`
    -Argument '-NoProfile -Command "Submit-Renewal -AllAccounts"'
$trigger = New-ScheduledTaskTrigger -Daily -At '03:00' -RandomDelay (New-TimeSpan -Hours 1)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName 'Posh-ACME Renewal' -Action $action -Trigger $trigger \`
    -Settings $settings -User '${runAs}' -Password (Read-Host 'Password for ${runAs}') -RunLevel Highest`;
  const multi = `$cur = (Get-PAServer).location
Get-PAServer -List | ForEach-Object { Set-PAServer $_.location; Submit-Renewal -AllAccounts }
Set-PAServer $cur`;
  parts.push(el('div', { class: 'card' },
    el('h3', {}, 'Create a renewal task'),
    el('p', { class: 'muted' }, 'Run in an elevated PowerShell prompt. ', el('code', {}, '-RunLevel Highest'), ' is only needed for orders that install into the Windows certificate store. Use powershell.exe instead of pwsh.exe if Posh-ACME is installed for Windows PowerShell 5.1.'),
    el('pre', { class: 'snippet' }, single),
    el('div', { style: 'margin-top:8px' }, el('button', { class: 'btn sm', onclick: () => copyText(single) }, 'Copy')),
    el('p', { class: 'muted', style: 'margin-top:16px' }, 'To renew orders on every ACME server, save this as a .ps1 script and point the task at it instead:'),
    el('pre', { class: 'snippet' }, multi),
    el('div', { style: 'margin-top:8px' }, el('button', { class: 'btn sm', onclick: () => copyText(multi) }, 'Copy'))));

  clear(host, parts);
}

// ---------------------------------------------------------------------------
// Activity (background jobs)
// ---------------------------------------------------------------------------

const JOB_STATE = { Running: ['Running', 'info running'], Completed: ['Completed', 'ok'], Failed: ['Failed', 'bad'], Stopped: ['Stopped', 'warn'], NotStarted: ['Queued', ''] };
let jobsTimer = null;
let logTimer = null;

async function loadJobs() {
  try {
    const before = new Map(state.jobs.map((j) => [j.id, j.state]));
    state.jobs = await api('jobs');
    let finished = false;
    for (const j of state.jobs) {
      if (before.get(j.id) === 'Running' && j.state !== 'Running') {
        finished = true;
        toast(`${j.label} ${j.target}: ${j.state === 'Completed' ? 'finished' : j.state.toLowerCase()}`, j.state === 'Failed');
      }
    }
    renderJobs();
    if (finished) loadAll();
  } catch { /* server unreachable; ignore until next tick */ }
  scheduleJobs();
}

function scheduleJobs() {
  clearTimeout(jobsTimer);
  const running = state.jobs.some((j) => j.state === 'Running');
  jobsTimer = setTimeout(loadJobs, running ? 2000 : 15000);
}

function renderJobs() {
  const running = state.jobs.filter((j) => j.state === 'Running').length;
  const badge = $('#running-badge');
  badge.textContent = running;
  badge.className = 'pill info running' + (running ? '' : ' hidden');

  const list = $('#job-list');
  if (!state.jobs.length) {
    clear(list, el('div', { class: 'card muted' }, 'No actions have been run since the dashboard started. Renewals, revocations and new certificates show up here with their full log.'));
    return;
  }
  clear(list, state.jobs.map((j) => {
    const [label, cls] = JOB_STATE[j.state] || [j.state, ''];
    return el('button', { class: 'job' + (state.selectedJob === j.id ? ' selected' : ''), onclick: () => selectJob(j.id) },
      el('div', { class: 'top' }, el('span', { class: 'title' }, j.label), el('span', { class: 'pill ' + cls }, el('span', { class: 'dot' }), label)),
      el('div', { class: 'meta' }, j.target),
      el('div', { class: 'meta' }, `${fmtDateTime(j.started)} · ${j.user}`));
  }));
}

function selectJob(id) {
  state.selectedJob = id;
  showTab('activity');
  renderJobs();
  loadJobLog();
}

async function loadJobLog() {
  clearTimeout(logTimer);
  const id = state.selectedJob;
  if (!id) return;
  let job;
  try { job = await api('jobs/' + id); } catch (e) { clear($('#job-log'), e.message); return; }
  if (state.selectedJob !== id) return;
  const [label, cls] = JOB_STATE[job.state] || [job.state, ''];
  clear($('#job-log-head'),
    el('strong', {}, `${job.label}`), el('span', { class: 'muted' }, job.target),
    el('span', { class: 'pill ' + cls }, el('span', { class: 'dot' }), label),
    job.state === 'Completed' && job.hasWarnings ? el('span', { class: 'pill warn' }, 'with warnings') : null,
    el('span', { class: 'spacer' }),
    el('span', { class: 'muted small' }, job.finished ? `Finished ${fmtDateTime(job.finished)}` : `Started ${fmtDateTime(job.started)}`));
  const pre = $('#job-log');
  const atBottom = pre.scrollHeight - pre.scrollTop - pre.clientHeight < 40;
  clear(pre, (job.log || []).map((line) => {
    const cls = /^\[[\d:]+\] (WARNING)/.test(line) ? 'l-warn' : /^\[[\d:]+\] (ERROR)|^ERROR/.test(line) ? 'l-err'
      : /^\[[\d:]+\] VERBOSE/.test(line) ? 'l-verbose' : /^\[[\d:]+\] RESULT/.test(line) ? 'l-result' : '';
    return el('div', { class: cls }, line);
  }));
  if (!job.log || !job.log.length) pre.textContent = job.state === 'Running' ? 'Starting…' : '(no output)';
  if (atBottom) pre.scrollTop = pre.scrollHeight;
  if (job.state === 'Running' || job.state === 'NotStarted') logTimer = setTimeout(loadJobLog, 1500);
}

async function startJob(body) {
  const job = await api('jobs', { method: 'POST', body });
  toast(`${job.label} started: ${job.target}`);
  state.jobs.unshift(job);
  selectJob(job.id);
  scheduleJobs();
  return job;
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------

/**
 * Open a modal form. onSubmit(form) may throw to show an error and keep the dialog open.
 */
function openDialog({ title, body, submitLabel = 'OK', cancelLabel = 'Cancel', danger = false, onSubmit, wide = false, keepOpen = false }) {
  const dlg = $('#dialog');
  const err = el('div', { class: 'banner bad hidden' });
  const submit = el('button', { type: 'submit', class: 'btn ' + (danger ? 'danger solid' : 'primary') }, submitLabel);
  const form = el('form', { method: 'dialog', novalidate: true },
    el('div', { class: 'dlg-head' }, el('h2', {}, title)),
    el('div', { class: 'dlg-body' }, body, err),
    el('div', { class: 'dlg-foot' },
      el('button', { type: 'button', class: 'btn', onclick: () => dlg.close() }, cancelLabel),
      submit));
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!form.checkValidity()) { form.reportValidity(); return; }
    submit.disabled = true;
    err.classList.add('hidden');
    try {
      await onSubmit(form);
      if (!keepOpen) dlg.close();
    } catch (ex) {
      clear(err, ex.message);
      err.classList.remove('hidden');
      err.scrollIntoView({ block: 'nearest' });
    } finally {
      submit.disabled = false;
    }
  });
  dlg.style.width = wide ? 'min(760px, calc(100vw - 32px))' : '';
  clear(dlg, form);
  dlg.showModal();
  const first = form.querySelector('input:not([type=hidden]):not([type=checkbox]), select, textarea');
  if (first) first.focus();
  return form;
}

function field(label, control, help, required = false) {
  const id = control.id || (control.id = 'f' + Math.random().toString(36).slice(2));
  return el('div', { class: 'field' }, el('label', { for: id }, label, required ? el('span', { class: 'req' }, ' *') : null), control, help ? el('div', { class: 'help' }, help) : null);
}
function checkbox(label, attrs = {}, help) {
  const cb = el('input', { type: 'checkbox', ...attrs });
  cb.id = cb.id || 'f' + Math.random().toString(36).slice(2);
  return el('div', {}, el('div', { class: 'field inline', style: help ? 'margin-bottom:2px' : '' }, cb, el('label', { for: cb.id }, label)),
    help ? el('div', { class: 'help muted small', style: 'margin:0 0 12px 24px' }, help) : null);
}
function confirmName(expected) {
  return field(`Type ${expected} to confirm`, el('input', { name: 'confirm', required: true, autocomplete: 'off', pattern: expected.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), title: 'Must match the order name' }));
}

function renewOrder(r) {
  const due = ['renewal-due', 'expiring', 'expired', 'pending', 'invalid'].includes(r.health);
  const manual = (r.plugin || []).includes('Manual');
  openDialog({
    title: `Renew ${r.mainDomain}`,
    submitLabel: 'Renew',
    body: [
      manual ? el('div', { class: 'banner warn', style: 'margin:0 0 12px' }, 'This order uses the Manual DNS plugin. Posh-ACME skips Manual orders when renewing non-interactively, so this will not do anything. Change the validation plugin first.') : null,
      el('p', {}, due ? 'This certificate is due for renewal. A new certificate will be requested using the saved validation settings.'
        : `This certificate is not due for renewal until ${fmtDateTime(r.renewAfter)}. Renewing early still counts against the CA's rate limits.`),
      checkbox('Force renewal even if not due', { name: 'force', checked: !due }),
      el('p', { class: 'muted small' }, 'Validation: ', (r.plugin || []).join(', '), r.dnsSleep ? ` · waits ${r.dnsSleep}s for DNS propagation` : ''),
    ],
    onSubmit: (f) => startJob({ action: 'Renew', serverUrl: r.serverUrl, account: r.account, order: r.name, force: f.force.checked }),
  });
}

function renewAccount(s, a) {
  openDialog({
    title: `Renew due orders for ${a.id}`,
    submitLabel: 'Renew',
    body: [
      el('p', {}, `Runs Submit-Renewal -AllOrders for this account on ${serverLabel(s.location)}. Only orders past their renew-after date are renewed unless you force it.`),
      checkbox('Force renewal of all orders', { name: 'force' }),
    ],
    onSubmit: (f) => startJob({ action: 'RenewAccount', serverUrl: s.location, account: a.id, force: f.force.checked }),
  });
}

function revokeDialog(r) {
  const reasons = ['', ...(state.info.revokeReasons || []).filter((x) => /^(keyCompromise|affiliationChanged|superseded|cessationOfOperation|privilegeWithdrawn)$/.test(x))];
  openDialog({
    title: `Revoke ${r.mainDomain}`,
    submitLabel: 'Revoke certificate',
    danger: true,
    body: [
      el('div', { class: 'banner bad', style: 'margin:0 0 14px' }, 'Revocation is permanent. Servers still using this certificate will start showing errors once clients see the revocation.'),
      field('Reason', el('select', { name: 'reason' }, reasons.map((x) => el('option', { value: x }, x || 'unspecified')))),
      confirmName(r.name),
    ],
    onSubmit: (f) => startJob({ action: 'Revoke', serverUrl: r.serverUrl, account: r.account, order: r.name, reason: f.reason.value || null }),
  });
}

function deleteDialog(r) {
  const hasCert = !!(r.cert && r.cert.notAfter);
  openDialog({
    title: `Delete order ${r.name}`,
    submitLabel: 'Delete order',
    danger: true,
    body: [
      el('p', {}, 'Removes the order and its folder (certificate, private key and PFX files) from the Posh-ACME config. It will no longer be renewed.'),
      el('p', { class: 'mono small muted' }, r.folder),
      hasCert ? checkbox('Also revoke the certificate', { name: 'revoke' }) : null,
      confirmName(r.name),
    ],
    onSubmit: async (f) => {
      await startJob({ action: 'Remove', serverUrl: r.serverUrl, account: r.account, order: r.name, revoke: !!(f.revoke && f.revoke.checked) });
      closeDrawer();
    },
  });
}

// --- server / account pickers ----------------------------------------------

function serverOptions() {
  const opts = [];
  const seen = new Set();
  for (const s of state.overview.servers) {
    seen.add(s.location);
    opts.push({ value: s.location, label: serverLabel(s.location) + (s.isCurrent ? ' (current)' : '') });
  }
  for (const [key, url] of Object.entries(state.info.wellKnownServers)) {
    if (!seen.has(url)) opts.push({ value: url, label: (SERVER_LABELS[key] || key) + ' (new)' });
  }
  opts.push({ value: '__custom', label: 'Other ACME server…' });
  return opts;
}

function defaultServer() {
  const cur = state.overview.servers.find((s) => s.isCurrent);
  return cur ? cur.location : state.info.wellKnownServers.LE_PROD;
}

/** Server + account pickers; returns { node, get(), setServer(url) } */
function serverAccountPicker({ allowNewAccount = true, accountRequired = false, onChange = null } = {}) {
  const serverSel = el('select', { name: 'server' }, serverOptions().map((o) => el('option', { value: o.value }, o.label)));
  serverSel.value = defaultServer();
  const customUrl = el('input', { name: 'customUrl', type: 'url', placeholder: 'https://acme.example.com/directory' });
  const customWrap = field('Directory URL', customUrl);
  const acctSel = el('select', { name: 'account' });
  const newAcct = el('div', {});
  const contact = el('input', { name: 'contact', type: 'email', placeholder: 'pki-team@example.com' });
  const tos = el('input', { type: 'checkbox', name: 'acceptTos', id: 'f-tos' });
  const tosLabel = el('label', { for: 'f-tos' }, 'I accept the CA\'s terms of service');

  function sync() {
    const isCustom = serverSel.value === '__custom';
    customWrap.classList.toggle('hidden', !isCustom);
    customUrl.required = isCustom;
    const server = state.overview.servers.find((s) => s.location === serverSel.value);
    const accounts = server ? server.accounts : [];
    const prev = acctSel.value;
    clear(acctSel,
      accounts.map((a) => el('option', { value: a.id }, `${a.id}${a.contact.length ? ' — ' + a.contact[0] : ''}${a.isCurrent ? ' (current)' : ''}${a.status !== 'valid' ? ' [' + a.status + ']' : ''}`)),
      allowNewAccount ? el('option', { value: '' }, 'Create a new account…') : null);
    const cur = accounts.find((a) => a.id === prev) || accounts.find((a) => a.isCurrent) || accounts[0];
    acctSel.value = cur ? cur.id : '';
    syncAcct();
    clear(tosLabel, 'I accept the CA\'s ', server && server.tosUrl ? el('a', { href: server.tosUrl, target: '_blank', rel: 'noopener' }, 'terms of service') : 'terms of service');
  }
  function syncAcct() {
    const creating = acctSel.value === '';
    newAcct.classList.toggle('hidden', !creating);
    tos.required = creating;
    acctSel.parentElement && acctSel.parentElement.classList.toggle('hidden', accountRequired === false && !acctSel.options.length);
    if (onChange) onChange();
  }
  serverSel.addEventListener('change', sync);
  acctSel.addEventListener('change', syncAcct);

  appendAll(newAcct,
    field('Contact email', contact, 'Optional. The CA may send expiry and policy notices here.'),
    el('div', { class: 'field inline' }, tos, tosLabel));

  const node = el('fieldset', {}, el('legend', {}, 'ACME server & account'),
    el('div', { class: 'row2' }, field('Server', serverSel), field('Account', acctSel)),
    customWrap, newAcct);
  sync();
  const get = () => ({
    serverUrl: serverSel.value === '__custom' ? customUrl.value.trim() : serverSel.value,
    account: acctSel.value || null,
    contact: contact.value.trim() ? [contact.value.trim()] : null,
    acceptTos: tos.checked,
  });
  return {
    node,
    get,
    setServer: (url) => {
      if (!url || ![...serverSel.options].some((o) => o.value === url)) return;
      serverSel.value = url;
      sync();
    },
  };
}

// --- plugin picker ---------------------------------------------------------

async function getPlugins() {
  if (!state.plugins) state.plugins = await api('plugins');
  return state.plugins;
}
async function getPluginDetail(name) {
  if (!state.pluginDetail.has(name)) state.pluginDetail.set(name, await api('plugins/' + encodeURIComponent(name)));
  return state.pluginDetail.get(name);
}

/**
 * Plugin select + credentials source + dynamic parameter form.
 * getTarget() returns { serverUrl } so saved credentials on that server can be offered for reuse.
 * selfKey is the order being edited (its own saved credentials are offered as "keep").
 * getDomains() returns the domains a credentials test should check.
 * Returns { node, get(), apply(template), refresh() }.
 */
function pluginPicker(plugins, initial, { getTarget = null, selfKey = null, getDomains = null } = {}) {
  const usable = plugins.filter((p) => p.name !== 'Manual');
  const sel = el('select', { name: 'plugin', required: true },
    el('option', { value: '' }, 'Choose a plugin…'),
    el('optgroup', { label: 'DNS (dns-01) — supports wildcards' }, usable.filter((p) => p.challengeType === 'dns-01').map((p) => el('option', { value: p.name }, p.name))),
    el('optgroup', { label: 'HTTP (http-01)' }, usable.filter((p) => p.challengeType !== 'dns-01').map((p) => el('option', { value: p.name }, p.name))));
  const credWrap = el('div', {});
  const setWrap = el('div', {});
  const paramsWrap = el('div', {});
  const docs = el('div', { class: 'help' });
  let detail = null;
  let setSel = null;
  let credSel = null;

  // Credentials test (only plugins with a server-side test, currently GoDaddy)
  const testResult = el('div', { class: 'test-result hidden', role: 'status' });
  const testBtn = el('button', { type: 'button', class: 'btn sm', onclick: () => runTest() }, 'Test credentials');
  const testWrap = el('div', { class: 'test-wrap write-only hidden' },
    el('div', { class: 'test-row' }, testBtn,
      el('span', { class: 'muted small' }, 'Checks the key against the GoDaddy API and that each domain\'s DNS zone is reachable. Read-only — no records are changed.')),
    testResult);

  const showTest = (kind, lines) => renderTestResult(testResult, kind, lines);

  async function runTest() {
    const domains = getDomains ? getDomains() : [];
    if (!domains.length) { showTest('fail', [{ level: 'FAIL', text: 'Enter the domains first, so the test can check their DNS zones.' }]); return; }
    let pl;
    try { pl = get(); } catch (e) { showTest('fail', [{ level: 'FAIL', text: e.message }]); return; }
    if (!pl.copyFrom && !(pl.pluginArgs.GDKey && (pl.pluginArgs.GDSecretSecure || pl.pluginArgs.GDSecret))) {
      showTest('fail', [{ level: 'FAIL', text: 'Enter GDKey and the secret, or choose saved credentials to reuse.' }]);
      return;
    }
    const target = getTarget ? getTarget() : {};
    testBtn.disabled = true;
    try {
      await runCredentialTest({ serverUrl: target.serverUrl, account: target.account || null, ...pl, domains }, showTest);
    } finally {
      testBtn.disabled = false;
    }
  }

  /** Orders on the target server that already have saved credentials for the selected plugin. */
  function candidates() {
    if (!sel.value) return [];
    const target = getTarget ? getTarget() : null;
    return state.rows
      .filter((r) => (r.plugin || []).includes(sel.value) && (!target || r.serverUrl === target.serverUrl))
      .sort((a, b) => (b.key === selfKey) - (a.key === selfKey) || a.mainDomain.localeCompare(b.mainDomain));
  }
  const reusing = () => !!(credSel && credSel.value);

  function renderCreds() {
    const prev = credSel ? credSel.value : null;
    const list = candidates();
    credSel = null;
    if (!list.length) { clear(credWrap); return; }
    credSel = el('select', {},
      list.map((r) => el('option', { value: r.key },
        r.key === selfKey ? 'Keep this order\'s saved credentials' : `Reuse saved credentials from ${r.mainDomain} (account ${r.account})`)),
      el('option', { value: '' }, 'Enter new credentials'));
    credSel.value = prev !== null && [...credSel.options].some((o) => o.value === prev) ? prev : list[0].key;
    credSel.addEventListener('change', updateRequired);
    clear(credWrap, field('Credentials', credSel,
      'Saved credentials stay encrypted on the server. Fill in a field below only to override that one value.'));
  }

  /** Mandatory fields are optional while reusing saved credentials. */
  function updateRequired() {
    const reuse = reusing();
    $$('input, textarea', paramsWrap).forEach((n) => {
      if (n.dataset.mandatory === 'true') n.required = !reuse;
    });
    $$('.req', paramsWrap).forEach((n) => n.classList.toggle('hidden', reuse));
  }

  function renderParams() {
    const set = detail.parameterSets.find((s) => s.name === (setSel ? setSel.value : '')) || detail.parameterSets[0];
    if (!set) { clear(paramsWrap, el('p', { class: 'muted small' }, 'This plugin has no parameters.')); return; }
    clear(paramsWrap, set.params.map((p) => {
      const name = 'pa_' + p.name;
      const data = { param: p.name, kind: p.kind, mandatory: String(p.mandatory) };
      switch (p.kind) {
        case 'switch':
        case 'bool':
          return checkbox(p.name, { name, dataset: data });
        case 'secure':
          return field(p.name, el('input', { name, type: 'password', autocomplete: 'new-password', required: p.mandatory, dataset: data }), 'Secret — stored encrypted by Posh-ACME', p.mandatory);
        case 'credential':
          return el('div', { class: 'row2', dataset: { param: p.name, kind: p.kind } },
            field(p.name + ' user', el('input', { name: name + '_user', required: p.mandatory, autocomplete: 'off', dataset: { mandatory: String(p.mandatory) } }), null, p.mandatory),
            field(p.name + ' password', el('input', { name: name + '_pass', type: 'password', required: p.mandatory, autocomplete: 'new-password', dataset: { mandatory: String(p.mandatory) } }), null, p.mandatory));
        case 'int':
          return field(p.name, el('input', { name, type: 'number', required: p.mandatory, dataset: data }), null, p.mandatory);
        case 'list':
          return field(p.name, el('input', { name, required: p.mandatory, dataset: data }), 'Comma-separated list', p.mandatory);
        case 'hashtable':
          return field(p.name, el('textarea', { name, required: p.mandatory, placeholder: '{ "key": "value" }', dataset: data }), 'JSON object', p.mandatory);
        default:
          return field(p.name, el('input', { name, required: p.mandatory, autocomplete: 'off', dataset: data }), null, p.mandatory);
      }
    }));
    updateRequired();
  }

  async function load() {
    clear(setWrap); clear(paramsWrap); clear(docs); clear(credWrap);
    detail = null; setSel = null; credSel = null;
    testWrap.classList.toggle('hidden', !TESTABLE_PLUGINS.includes(sel.value));
    testResult.className = 'test-result hidden';
    if (!sel.value) return;
    clear(paramsWrap, el('p', { class: 'muted small' }, 'Loading plugin parameters…'));
    const name = sel.value;
    let d;
    try { d = await getPluginDetail(name); }
    catch (e) { clear(paramsWrap, el('div', { class: 'banner bad' }, e.message)); return; }
    if (sel.value !== name) return; // plugin changed while loading
    detail = d;
    clear(docs, 'Setup guide: ', el('a', { href: detail.docsUrl, target: '_blank', rel: 'noopener' }, `${detail.name} plugin docs`));
    if (detail.parameterSets.length > 1) {
      setSel = el('select', {}, detail.parameterSets.map((s) => el('option', { value: s.name }, s.name + (s.isDefault ? ' (default)' : ''))));
      setSel.addEventListener('change', renderParams);
      clear(setWrap, field('Authentication method', setSel));
    }
    renderCreds();
    renderParams();
  }
  sel.addEventListener('change', load);
  const ready = initial ? (sel.value = initial, load()) : Promise.resolve();

  function get() {
    const args = {};
    $$('[data-param]', paramsWrap).forEach((n) => {
      const p = n.dataset.param;
      switch (n.dataset.kind) {
        case 'switch': case 'bool': if (n.checked) args[p] = true; break;
        case 'credential': {
          const [u, pw] = $$('input', n);
          if (u.value) args[p] = { username: u.value, password: pw.value };
          break;
        }
        case 'hashtable':
          if (n.value.trim()) { try { JSON.parse(n.value); } catch { throw new Error(`${p} must be valid JSON`); } args[p] = n.value; }
          break;
        default: if (n.value !== '') args[p] = n.value;
      }
    });
    let copyFrom = null;
    if (reusing()) {
      const src = rowByKey(credSel.value);
      if (src) copyFrom = { account: src.account, order: src.name };
    }
    return { plugin: sel.value, pluginArgs: args, copyFrom };
  }

  const node = el('fieldset', {}, el('legend', {}, 'Validation'), field('Plugin', sel, docs, true), credWrap, setWrap, paramsWrap, testWrap);
  return {
    node,
    ready,
    /** Re-evaluate which saved credentials can be reused (server/account changed). */
    refresh: () => { if (detail) { renderCreds(); updateRequired(); } },
    /** Select a plugin, parameter set and non-secret default values. */
    apply: async ({ plugin, parameterSet, pluginArgs } = {}) => {
      if (!plugin) return;
      if (!usable.some((p) => p.name === plugin)) throw new Error(`Plugin '${plugin}' is not available in this Posh-ACME version.`);
      sel.value = plugin;
      await load();
      if (setSel && parameterSet && [...setSel.options].some((o) => o.value === parameterSet)) {
        setSel.value = parameterSet;
        renderParams();
      }
      for (const [k, v] of Object.entries(pluginArgs || {})) {
        if (v === null || v === '' || v === undefined) continue;
        const n = $(`[data-param="${CSS.escape(k)}"]`, paramsWrap);
        if (!n || n.dataset.kind === 'secure' || n.dataset.kind === 'credential') continue; // never prefill secrets
        if (n.type === 'checkbox') n.checked = !!v; else n.value = Array.isArray(v) ? v.join(', ') : String(v);
      }
    },
    get,
  };
}

function renderTestResult(node, kind, lines) {
  node.className = 'test-result ' + kind;
  clear(node, lines.map((l) => el('div', { class: 'test-line ' + (l.level || '') },
    el('span', { class: 'test-icon' }, l.level === 'PASS' ? '\u2713' : l.level === 'FAIL' || l.level === 'ERROR' ? '\u2717' : '\u2022'),
    el('span', {}, l.text))));
}

/** Runs the read-only credentials test as a background job and reports through show(kind, lines). */
async function runCredentialTest(body, show) {
  show('running', [{ text: 'Testing GoDaddy credentials\u2026' }]);
  try {
    const job = await api('jobs', {
      method: 'POST',
      body: { action: 'TestPlugin', ...body, serverUrl: body.serverUrl || state.info.wellKnownServers.LE_PROD },
    });
    state.jobs.unshift(job); renderJobs(); scheduleJobs();
    let d = job;
    while (d.state === 'Running' || d.state === 'NotStarted') {
      await new Promise((r) => setTimeout(r, 1000));
      d = await api('jobs/' + job.id);
      const waiting = (d.log || []).some((l) => /Waiting for another dashboard action/.test(l));
      if (waiting && d.state === 'Running') show('running', [{ text: 'Waiting for another dashboard action to finish\u2026' }]);
    }
    const lines = (d.log || [])
      .map((l) => /^\[[\d:]+\] (PASS|FAIL|ERROR|WARNING)\s+(.*)$/.exec(l))
      .filter(Boolean)
      .map((m) => ({ level: m[1], text: m[2] }));
    // the final ERROR only repeats the FAIL count
    const shown = lines.some((l) => l.level === 'FAIL') ? lines.filter((l) => l.level !== 'ERROR') : lines;
    show(d.state === 'Completed' ? 'ok' : 'fail', shown.length ? shown : [{ level: 'FAIL', text: `Test ${d.state.toLowerCase()} without output. See the Activity tab.` }]);
  } catch (e) {
    show('fail', [{ level: 'FAIL', text: e.message }]);
  }
}

/** Read-only mode's credentials test: typed values only, nothing is saved. */
function godaddyTestDialog() {
  const domains = el('textarea', { name: 'domains', required: true, rows: 3, placeholder: 'example.com\nwww.example.com' });
  const key = el('input', { name: 'GDKey', required: true, autocomplete: 'off' });
  const secret = el('input', { name: 'GDSecret', type: 'password', required: true, autocomplete: 'new-password' });
  const customer = el('input', { name: 'GDCustomerId', autocomplete: 'off' });
  const ote = checkbox('GDUseOTE (a key for GoDaddy\'s test environment)', { name: 'GDUseOTE' });
  const result = el('div', { class: 'test-result hidden', role: 'status' });
  const form = openDialog({
    title: 'Test GoDaddy credentials',
    submitLabel: 'Run test',
    cancelLabel: 'Close',
    keepOpen: true,
    wide: true,
    body: [
      el('div', { class: 'banner info', style: 'margin:0 0 14px' },
        'Sends only read (GET) requests to the GoDaddy API: it finds each domain\'s DNS zone and reads its _acme-challenge TXT records. No DNS record is created or changed, and these values are not saved.'),
      field('Domains', domains, 'One per line. Wildcards are checked as their base domain.', true),
      el('div', { class: 'row2' }, field('API key (GDKey)', key, null, true), field('API secret', secret, null, true)),
      field('Customer ID (GDCustomerId)', customer, 'Only for reseller or delegated accounts'),
      ote,
      result,
    ],
    onSubmit: async (f) => {
      const pluginArgs = { GDKey: key.value.trim(), GDSecretSecure: secret.value };
      if (customer.value.trim()) pluginArgs.GDCustomerId = customer.value.trim();
      if (f.GDUseOTE.checked) pluginArgs.GDUseOTE = true;
      const names = domains.value.split(/[\s,]+/).map((d) => d.trim()).filter(Boolean);
      await runCredentialTest({ plugin: 'GoDaddy', pluginArgs, domains: names }, (kind, lines) => renderTestResult(result, kind, lines));
    },
  });
  $('#dialog').addEventListener('close', () => { secret.value = ''; key.value = ''; }, { once: true });
  return form;
}

async function getTemplates() {
  if (!state.templates) state.templates = await api('templates');
  return state.templates;
}

async function newCertificateDialog() {
  let plugins, templates;
  try { [plugins, templates] = await Promise.all([getPlugins(), getTemplates().catch(() => [])]); }
  catch (e) { toast(e.message, true); return; }

  let pp = null;
  const domainsInput = el('textarea', { name: 'domains', required: true, placeholder: 'example.com\nwww.example.com\n*.example.com', rows: 3 });
  const parseDomains = () => domainsInput.value.split(/[\s,]+/).map((d) => d.trim()).filter(Boolean);
  const sa = serverAccountPicker({ onChange: () => pp && pp.refresh() });
  pp = pluginPicker(plugins, null, { getTarget: sa.get, getDomains: parseDomains });

  const keySel = el('select', { name: 'certKeyLength' }, KEY_TYPES.map((k) => el('option', { value: k }, k.startsWith('ec') ? `ECC ${k.slice(3)}` : `RSA ${k}`)));
  keySel.value = '2048';
  const inputs = {
    dnsSleep: el('input', { name: 'dnsSleep', type: 'number', min: 0, placeholder: '120' }),
    validationTimeout: el('input', { name: 'validationTimeout', type: 'number', min: 1, placeholder: '60' }),
    lifetimeDays: el('input', { name: 'lifetimeDays', type: 'number', min: 1, placeholder: 'CA default' }),
    preferredChain: el('input', { name: 'preferredChain', placeholder: 'e.g. ISRG Root X1' }),
  };
  const checks = {
    install: checkbox('Install into the Windows certificate store (LocalMachine\\My)', { name: 'install' }, 'Requires the dashboard to run elevated.'),
    alwaysNewKey: checkbox('Generate a new private key on every renewal', { name: 'alwaysNewKey' }),
  };

  const notes = el('div', {});
  const tplSel = el('select', { name: 'template' },
    templates.map((t) => el('option', { value: t.id }, t.name)),
    el('option', { value: '' }, 'No template — choose everything manually'));
  const tplDefault = templates.find((t) => t.default) || templates[0];
  tplSel.value = tplDefault ? tplDefault.id : '';

  async function applyTemplate() {
    const t = templates.find((x) => x.id === tplSel.value);
    if (!t) { clear(notes); return; }
    if (t.serverUrl) sa.setServer(t.serverUrl);
    if (t.certKeyLength && KEY_TYPES.includes(String(t.certKeyLength))) keySel.value = String(t.certKeyLength);
    for (const k of Object.keys(inputs)) inputs[k].value = t[k] ?? '';
    for (const k of Object.keys(checks)) $('input', checks[k]).checked = !!t[k];
    clear(notes, el('div', { class: 'banner info', style: 'margin:0 0 14px; flex-direction:column; gap:4px' },
      t.description ? el('div', {}, el('strong', {}, t.name + ': '), t.description) : null,
      (t.notes || []).length ? el('ul', { style: 'margin:4px 0 0; padding-left:18px' }, t.notes.map((n) => el('li', {}, n))) : null,
      (t.links || []).length ? el('div', { class: 'chips', style: 'margin-top:4px' },
        t.links.map((l) => el('a', { href: l.url, target: '_blank', rel: 'noopener' }, l.label))) : null));
    try { await pp.apply(t); } catch (e) { toast(e.message, true); }
  }
  tplSel.addEventListener('change', applyTemplate);

  openDialog({
    title: 'New certificate',
    submitLabel: 'Request certificate',
    wide: true,
    body: [
      templates.length ? field('Template', tplSel) : null,
      notes,
      field('Domains', domainsInput, 'One per line. The first name is the main domain (certificate subject).', true),
      sa.node,
      pp.node,
      el('details', { class: 'advanced' }, el('summary', {}, 'Advanced options'),
        el('div', { class: 'row2' },
          field('Order name', el('input', { name: 'name', placeholder: 'defaults to the main domain' }), 'Use a different name to keep several orders for the same domain.'),
          field('Key type', keySel)),
        el('div', { class: 'row3' },
          field('DNS sleep (s)', inputs.dnsSleep, 'Wait for DNS propagation'),
          field('Validation timeout (s)', inputs.validationTimeout),
          field('Lifetime (days)', inputs.lifetimeDays)),
        el('div', { class: 'row2' },
          field('Friendly name', el('input', { name: 'friendlyName', placeholder: 'defaults to the main domain' })),
          field('PFX password', el('input', { name: 'pfxPass', type: 'password', autocomplete: 'new-password', placeholder: 'poshacme (default)' }))),
        el('div', { class: 'row2' },
          field('DNS alias', el('input', { name: 'dnsAlias', placeholder: 'acme.example.net' }), 'For CNAME challenge delegation; comma-separated per domain'),
          field('Preferred chain', inputs.preferredChain)),
        checks.install,
        checks.alwaysNewKey),
    ],
    onSubmit: (f) => {
      const domains = parseDomains();
      if (!domains.length) throw new Error('Enter at least one domain.');
      const target = sa.get();
      if (!target.serverUrl) throw new Error('Enter the ACME directory URL.');
      if (!target.account && !target.acceptTos) throw new Error('Accept the terms of service to create an account.');
      const pl = pp.get();
      if (!pl.plugin) throw new Error('Choose a validation plugin.');
      const num = (v) => (v === '' ? null : Number(v));
      return startJob({
        action: 'NewCertificate',
        ...target,
        domains,
        ...pl,
        name: f.name.value.trim() || null,
        certKeyLength: f.certKeyLength.value,
        dnsSleep: num(f.dnsSleep.value),
        validationTimeout: num(f.validationTimeout.value),
        lifetimeDays: num(f.lifetimeDays.value),
        friendlyName: f.friendlyName.value.trim() || null,
        pfxPass: f.pfxPass.value || null,
        dnsAlias: f.dnsAlias.value.trim() ? f.dnsAlias.value.split(',').map((x) => x.trim()).filter(Boolean) : null,
        preferredChain: f.preferredChain.value.trim() || null,
        install: f.install.checked,
        alwaysNewKey: f.alwaysNewKey.checked,
      });
    },
  });
  await applyTemplate();
  $('textarea[name=domains]', $('#dialog')).focus();
}

async function pluginDialog(r) {
  let plugins;
  try { plugins = await getPlugins(); } catch (e) { toast(e.message, true); return; }
  const pp = pluginPicker(plugins, (r.plugin || []).find((p) => p !== 'Manual') || '',
    { getTarget: () => ({ serverUrl: r.serverUrl, account: r.account }), selfKey: r.key, getDomains: () => [r.mainDomain, ...(r.sans || [])].filter(Boolean) });
  openDialog({
    title: `Validation settings for ${r.mainDomain}`,
    submitLabel: 'Save',
    wide: true,
    body: [
      el('p', {}, 'Current plugin: ', el('strong', {}, (r.plugin || []).join(', ') || 'none'),
        '. Saved credentials are encrypted and cannot be displayed. Keep them, copy them from another order, or enter new ones. Changes apply from the next renewal.'),
      pp.node,
    ],
    onSubmit: (f) => {
      const pl = pp.get();
      if (!pl.plugin) throw new Error('Choose a validation plugin.');
      return startJob({ action: 'UpdatePlugin', serverUrl: r.serverUrl, account: r.account, order: r.name, ...pl });
    },
  });
}

function newAccountDialog() {
  const sa = serverAccountPicker({ allowNewAccount: true });
  // This dialog is always for a new account: hide the account picker.
  const acctField = $('select[name=account]', sa.node).closest('.field');
  acctField.classList.add('hidden');
  const acctSel = $('select[name=account]', sa.node);
  const forceNew = () => { acctSel.value = ''; acctSel.dispatchEvent(new Event('change')); };
  $('select[name=server]', sa.node).addEventListener('change', forceNew);
  forceNew();
  openDialog({
    title: 'New ACME account',
    submitLabel: 'Create account',
    body: [
      sa.node,
      el('div', { class: 'row2' },
        field('Account name', el('input', { name: 'accountId', placeholder: 'auto-generated', pattern: '[\\w.-]+' }), 'Optional friendly ID'),
        field('Key type', el('select', { name: 'keyLength' }, ['ec-256', 'ec-384', '2048', '4096'].map((k) => el('option', { value: k }, k))))),
    ],
    onSubmit: (f) => {
      const t = sa.get();
      if (!t.serverUrl) throw new Error('Enter the ACME directory URL.');
      if (!t.acceptTos) throw new Error('Accept the terms of service.');
      return startJob({ action: 'NewAccount', serverUrl: t.serverUrl, contact: t.contact, acceptTos: true, keyLength: f.keyLength.value, accountId: f.accountId.value.trim() || null });
    },
  });
}

// ---------------------------------------------------------------------------
// Deployments: where certificates are installed, and what those servers serve
// ---------------------------------------------------------------------------

const DEPLOY_STATUS = {
  current:     { label: 'Up to date',          cls: 'ok',   rank: 4, help: 'The server presents the current certificate.' },
  outdated:    { label: 'Old certificate',     cls: 'bad',  rank: 0, help: 'The server still presents an older certificate for the same names. Install the renewed certificate.' },
  mismatch:    { label: 'Wrong certificate',   cls: 'bad',  rank: 1, help: 'The server presents a certificate that is not this one.' },
  unreachable: { label: 'Unreachable',         cls: 'warn', rank: 2, help: 'The check could not connect or complete a TLS handshake.' },
  never:       { label: 'Not checked yet',     cls: '',     rank: 3, help: 'Waiting for the first check.' },
  'no-cert':   { label: 'No certificate yet',  cls: '',     rank: 3, help: 'The order has not issued a certificate yet.' },
  unchecked:   { label: 'Manual',              cls: '',     rank: 5, help: 'Not checked automatically; kept as documentation.' },
};
const CHECK_MODES = [
  { value: 'tls', label: 'TLS (HTTPS, LDAPS, IMAPS, RDP gateway…)', port: 443 },
  { value: 'smtp', label: 'SMTP with STARTTLS (Exchange, mail relays)', port: 25 },
  { value: 'none', label: "Don't check — document only", port: 443 },
];
let deployTimer = null;

async function loadDeployments() {
  try {
    state.deploy = await api('deployments');
  } catch (e) {
    state.deploy = { targets: [], types: {}, checkRunning: false, error: e.message };
  }
  renderDeployments();
  if (state.drawerKey) { const r = rowByKey(state.drawerKey); if (r) renderDrawer(r); }
  clearTimeout(deployTimer);
  if (state.deploy.checkRunning) {
    deployTimer = setTimeout(async () => {
      const wasRunning = state.deploy.checkRunning;
      await loadDeployments();
      if (wasRunning && !state.deploy.checkRunning) loadAll(); // refresh "used on" counts
    }, 2000);
  }
}

function deployPill(status) {
  const s = DEPLOY_STATUS[status] || { label: status, cls: '' };
  return el('span', { class: 'pill ' + s.cls, title: s.help || '' }, el('span', { class: 'dot' }), s.label);
}

function endpointText(t) {
  return `${t.host}:${t.port}` + (t.sni && t.sni !== t.host ? ` (SNI ${t.sni})` : '');
}

function servedCell(t) {
  const lc = t.lastCheck;
  if (t.checkMode === 'none') return el('span', { class: 'muted small' }, t.notes || '—');
  if (!lc) return el('span', { class: 'muted' }, '—');
  if (lc.error) return el('span', { class: 'small', style: 'color:var(--warn)' }, lc.error);
  const s = lc.served;
  return el('div', {},
    el('span', {}, `Expires ${fmtDate(s.notAfter)}`),
    el('span', { class: 'muted small' }, t.servedDaysLeft != null ? ` · ${t.servedDaysLeft < 0 ? 'expired' : t.servedDaysLeft + ' days'}` : ''),
    el('div', { class: 'muted small mono', title: `${s.subject}\nIssuer: ${s.issuer}\nSerial: ${s.serial}` }, s.thumbprint.slice(0, 16) + '… · ' + s.protocol));
}

async function checkDeployments(ids) {
  try {
    await api('deployments/check', { method: 'POST', body: { ids: ids || [] } });
    toast(ids && ids.length === 1 ? 'Checking server…' : 'Checking servers…');
    state.deploy.checkRunning = true;
    renderDeployments();
    clearTimeout(deployTimer);
    deployTimer = setTimeout(loadDeployments, 1500);
  } catch (e) {
    toast(e.message, true);
  }
}

function deployActions(t) {
  return el('div', { class: 'row-actions' },
    t.checkMode !== 'none' ? el('button', { type: 'button', class: 'btn sm no-readonly-mode', disabled: state.deploy.checkRunning, onclick: (e) => { e.stopPropagation(); checkDeployments([t.id]); } }, 'Check') : null,
    el('button', { type: 'button', class: 'btn sm write-only', onclick: (e) => { e.stopPropagation(); deploymentDialog(t); } }, 'Edit'),
    el('button', { type: 'button', class: 'btn sm danger write-only', title: 'Remove', onclick: (e) => { e.stopPropagation(); removeDeployment(t); } }, '✕'));
}

function renderDeployments() {
  const host = $('#deploy-body');
  if (!host || !state.deploy) return;
  const d = state.deploy;
  const q = ($('#deploy-search').value || '').trim().toLowerCase();
  const filter = $('#deploy-filter').value;
  const all = d.targets || [];

  const counts = {};
  all.forEach((t) => { counts[t.status] = (counts[t.status] || 0) + 1; });
  clear($('#deploy-summary'), Object.keys(DEPLOY_STATUS).filter((k) => counts[k]).map((k) =>
    el('button', { type: 'button', class: 'pill ' + DEPLOY_STATUS[k].cls + (filter === k ? ' active-pill' : ''),
      onclick: () => { $('#deploy-filter').value = filter === k ? '' : k; renderDeployments(); } },
      `${counts[k]} ${DEPLOY_STATUS[k].label.toLowerCase()}`)));

  const checkBtn = $('#deploy-check-all');
  checkBtn.disabled = d.checkRunning || !all.some((t) => t.checkMode !== 'none');
  checkBtn.textContent = d.checkRunning ? 'Checking…' : 'Check all now';
  $('#deploy-last').textContent = d.lastFullCheck ? `Last full check ${fmtRelative(d.lastFullCheck)}` : 'Never fully checked';

  let rows = all.filter((t) => !filter || t.status === filter);
  if (q) rows = rows.filter((t) => [t.host, t.sni, t.mainDomain, t.typeLabel, t.owner, t.notes].some((v) => v && String(v).toLowerCase().includes(q)));
  rows.sort((a, b) => ((DEPLOY_STATUS[a.status] || {}).rank ?? 9) - ((DEPLOY_STATUS[b.status] || {}).rank ?? 9)
    || String(a.mainDomain).localeCompare(String(b.mainDomain)) || a.host.localeCompare(b.host));

  if (!all.length) {
    clear(host, el('div', { class: 'empty' },
      el('p', {}, el('strong', {}, 'No servers registered yet.')),
      el('p', {}, 'Add the servers, load balancers and appliances where each certificate is installed. The dashboard then checks which certificate each one actually presents, and warns when a server still has the old one after a renewal.'),
      state.info && state.info.canWrite ? el('button', { class: 'btn primary', onclick: () => deploymentDialog() }, '+ Add server') : null));
    return;
  }
  clear(host, el('div', { class: 'table-wrap' }, el('table', { class: 'grid' },
    el('thead', {}, el('tr', {}, ['Status', 'Server', 'Certificate', 'Type / owner', 'Serving', 'Last checked', ''].map((h) => el('th', { style: 'cursor:default' }, h)))),
    el('tbody', {}, rows.map((t) => el('tr', { style: 'cursor:default' },
      el('td', {}, deployPill(t.status)),
      el('td', {}, el('strong', { class: 'mono' }, `${t.host}:${t.port}`),
        t.sni && t.sni !== t.host ? el('div', { class: 'muted small' }, 'SNI ' + t.sni) : null,
        t.checkMode === 'smtp' ? el('div', { class: 'muted small' }, 'SMTP STARTTLS') : null),
      el('td', {}, t.certMissing ? el('span', { class: 'muted' }, '(deleted order)')
        : el('a', { href: '#', onclick: (e) => { e.preventDefault(); showTab('certs'); openDrawer(t.certKey); } }, t.mainDomain)),
      el('td', {}, t.typeLabel, t.owner ? el('div', { class: 'muted small' }, t.owner) : null),
      el('td', {}, servedCell(t)),
      el('td', { class: 'small' }, t.lastCheck ? fmtRelative(t.lastCheck.checkedAt) : '—'),
      el('td', { class: 'actions-col' }, deployActions(t))))))));
  if (!rows.length) host.append(el('div', { class: 'empty' }, 'No servers match the filter.'));
}

/** "Used on" section of the certificate drawer. */
function drawerDeployments(r) {
  const list = ((state.deploy && state.deploy.targets) || []).filter((t) => t.certKey === r.key);
  const head = el('div', { class: 'section-head' }, el('h3', {}, `Used on${list.length ? ` (${list.length})` : ''}`),
    el('div', { class: 'row-actions' },
      list.some((t) => t.checkMode !== 'none') ? el('button', { class: 'btn sm no-readonly-mode', disabled: state.deploy.checkRunning, onclick: () => checkDeployments(list.map((t) => t.id)) }, state.deploy.checkRunning ? 'Checking…' : 'Check') : null,
      el('button', { class: 'btn sm write-only', onclick: () => deploymentDialog(null, r.key) }, '+ Add server')));
  if (!list.length) {
    return [head, el('p', { class: 'muted small' }, 'Not registered on any server. Add the servers where this certificate is installed to check that they serve the current one after each renewal.')];
  }
  const outdated = list.filter((t) => t.status === 'outdated').length;
  return [head,
    outdated ? el('div', { class: 'banner bad', style: 'margin:0 0 10px' }, `${plural(outdated, 'server')} still ${outdated === 1 ? 'serves' : 'serve'} an older certificate. Install the current one (thumbprint ${(r.cert && r.cert.thumbprint || '').slice(0, 16)}…).`) : null,
    el('div', { class: 'deploy-list' }, list.map((t) => el('div', { class: 'deploy-item' },
      el('div', { class: 'deploy-main' },
        deployPill(t.status),
        el('div', {}, el('strong', { class: 'mono' }, endpointText(t)),
          el('div', { class: 'muted small' }, [t.typeLabel, t.owner, t.lastCheck ? 'checked ' + fmtRelative(t.lastCheck.checkedAt) : null].filter(Boolean).join(' · ')),
          t.lastCheck && t.lastCheck.error ? el('div', { class: 'small', style: 'color:var(--warn)' }, t.lastCheck.error) : null,
          t.notes ? el('div', { class: 'muted small' }, t.notes) : null)),
      deployActions(t))))];
}

function deploymentDialog(t, certKey) {
  const editing = !!t;
  const certOptions = state.rows.slice().sort((a, b) => a.mainDomain.localeCompare(b.mainDomain));
  const certSel = el('select', { name: 'certKey', required: true },
    el('option', { value: '' }, 'Choose a certificate…'),
    certOptions.map((r) => el('option', { value: r.key }, `${r.mainDomain}${r.sans && r.sans.length ? ` (+${r.sans.length})` : ''} — ${serverLabel(r.serverUrl)}`)));
  certSel.value = (t && t.certKey) || certKey || '';
  const port = el('input', { name: 'port', type: 'number', min: 1, max: 65535, required: true, value: t ? t.port : 443 });
  const mode = el('select', { name: 'checkMode' }, CHECK_MODES.map((m) => el('option', { value: m.value }, m.label)));
  mode.value = t ? t.checkMode : 'tls';
  let portTouched = editing;
  port.addEventListener('input', () => { portTouched = true; });
  mode.addEventListener('change', () => { if (!portTouched) port.value = CHECK_MODES.find((m) => m.value === mode.value).port; });
  const sni = el('input', { name: 'sni', value: t ? t.sni : '', placeholder: 'defaults to the host', autocomplete: 'off' });
  const sniHelp = el('div', { class: 'help' });
  const syncSni = () => {
    const r = rowByKey(certSel.value);
    const wildcard = r && [r.mainDomain, ...(r.sans || [])].find((n) => n.startsWith('*.'));
    clear(sniHelp, 'Name to ask for when the host is an IP address or serves several certificates.',
      wildcard ? ` For ${wildcard}, use a name it covers, e.g. www.${wildcard.slice(2)}.` : '');
  };
  certSel.addEventListener('change', syncSni); syncSni();
  const types = (state.deploy && state.deploy.types) || { other: 'Other' };

  openDialog({
    title: editing ? `Edit ${t.host}:${t.port}` : 'Add server',
    submitLabel: editing ? 'Save' : 'Add and check',
    wide: true,
    body: [
      field('Certificate', certSel, null, true),
      el('div', { class: 'row3 host-row' },
        field('Host', el('input', { name: 'host', required: true, value: t ? t.host : '', placeholder: 'web01.contoso.com or 10.0.0.12', autocomplete: 'off' }), null, true),
        field('Port', port, null, true),
        field('Server name (SNI)', sni, sniHelp)),
      field('Check method', mode, 'Read-only: the dashboard connects, reads the certificate the server presents and disconnects. Nothing is changed on the server.'),
      el('div', { class: 'row2' },
        field('Type', el('select', { name: 'type' }, Object.entries(types).map(([k, v]) => el('option', { value: k, selected: t ? t.type === k : k === 'iis' }, v)))),
        field('Owner', el('input', { name: 'owner', value: t ? t.owner : '', placeholder: 'Team or person who installs it' }))),
      field('Notes', el('textarea', { name: 'notes', rows: 2, placeholder: 'How to install the renewed certificate here, bindings, etc.' }, t ? t.notes : '')),
    ],
    onSubmit: async (f) => {
      const body = {
        certKey: f.certKey.value, host: f.host.value.trim(), port: Number(f.port.value), sni: f.sni.value.trim(),
        checkMode: f.checkMode.value, type: f.type.value, owner: f.owner.value.trim(), notes: f.notes.value.trim(),
      };
      if (!body.certKey) throw new Error('Choose a certificate.');
      await api(editing ? 'deployments/' + t.id : 'deployments', { method: editing ? 'PUT' : 'POST', body });
      toast(editing ? 'Server updated.' : body.checkMode === 'none' ? 'Server added.' : 'Server added; checking it now.');
      await loadDeployments();
      loadAll();
    },
  });
}

function removeDeployment(t) {
  openDialog({
    title: `Remove ${t.host}:${t.port}`,
    submitLabel: 'Remove',
    danger: true,
    body: el('p', {}, `Stop tracking ${endpointText(t)} for ${t.mainDomain || 'this certificate'}? Nothing is changed on the server itself.`),
    onSubmit: async () => {
      await api('deployments/' + t.id, { method: 'DELETE' });
      toast('Server removed.');
      await loadDeployments();
      loadAll();
    },
  });
}

// ---------------------------------------------------------------------------
// Settings (email notifications through Microsoft 365)
// ---------------------------------------------------------------------------

const DAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
let settingsDirty = false;

async function loadSettings() {
  const form = $('#settings-form');
  if (settingsDirty) return; // don't throw away unsaved edits when switching tabs
  clear(form, el('p', { class: 'muted' }, 'Loading settings…'));
  try {
    const [settings, status] = await Promise.all([api('settings'), api('notifications')]);
    renderSettings(settings, status);
  } catch (e) {
    clear(form, el('div', { class: 'banner bad' }, 'Could not load settings: ', e.message));
  }
}

function toggleRow(label, attrs, help) {
  const cb = el('input', { type: 'checkbox', class: 'switch', ...attrs });
  cb.id = cb.id || 'f' + Math.random().toString(36).slice(2);
  return el('div', { class: 'toggle-row' }, cb, el('div', {}, el('label', { for: cb.id }, label), help ? el('div', { class: 'help muted small' }, help) : null));
}

function renderSettings(settings, status) {
  const form = $('#settings-form');
  const e = settings.email, a = settings.alerts, d = settings.digest;
  settingsDirty = false;

  // --- email delivery ---
  const authSecret = el('input', { type: 'radio', name: 'authType', value: 'secret', id: 'auth-secret', checked: e.authType !== 'certificate' });
  const authCert = el('input', { type: 'radio', name: 'authType', value: 'certificate', id: 'auth-cert', checked: e.authType === 'certificate' });
  let clearSecret = false;
  const secretInput = el('input', { name: 'clientSecret', type: 'password', autocomplete: 'new-password',
    placeholder: e.clientSecretSet ? 'Saved — leave blank to keep the current secret' : 'Client secret value' });
  const secretStatus = el('div', { class: 'help' });
  function syncSecretStatus() {
    clear(secretStatus, e.clientSecretSet && !clearSecret
      ? ['A secret is saved (encrypted with Windows DPAPI for ', state.info ? state.info.runAs : 'this user', '). ',
        el('a', { href: '#', onclick: (ev) => { ev.preventDefault(); clearSecret = true; markDirty(); syncSecretStatus(); } }, 'Remove it')]
      : clearSecret ? 'The saved secret will be removed when you save.' : 'Stored encrypted with Windows DPAPI; never shown again.');
  }
  syncSecretStatus();
  const secretBlock = el('div', {}, field('Client secret', secretInput, secretStatus));
  const certBlock = el('div', { class: 'row2' },
    field('Certificate thumbprint', el('input', { name: 'certThumbprint', value: e.certThumbprint, placeholder: '40 hex characters', autocomplete: 'off' }),
      'Certificate with private key, uploaded to the app registration'),
    field('Certificate store', el('select', { name: 'certStore' },
      ['CurrentUser', 'LocalMachine'].map((x) => el('option', { value: x, selected: e.certStore === x }, `${x}\\My`)))));
  const syncAuth = () => { secretBlock.classList.toggle('hidden', authCert.checked); certBlock.classList.toggle('hidden', !authCert.checked); };
  authSecret.addEventListener('change', syncAuth); authCert.addEventListener('change', syncAuth);
  syncAuth();

  const testTo = el('input', { name: 'testTo', type: 'email', placeholder: 'defaults to the recipients' });
  const testBtn = el('button', { type: 'button', class: 'btn', onclick: () => sendTestEmail() }, 'Send test email');
  const testResult = el('div', {});

  const emailCard = el('section', { class: 'card settings-card' },
    el('div', { class: 'card-head' }, el('h3', {}, 'Email delivery'), el('span', { class: 'pill accent' }, 'Microsoft 365 · OAuth 2.0')),
    toggleRow('Send email notifications', { name: 'emailEnabled', checked: e.enabled },
      'Sends mail through Microsoft Graph as an Entra ID app (client credentials flow). No user sign-in or SMTP password is needed.'),
    el('div', { class: 'row2' },
      field('Directory (tenant) ID', el('input', { name: 'tenantId', value: e.tenantId, placeholder: 'contoso.onmicrosoft.com or GUID', autocomplete: 'off' })),
      field('Application (client) ID', el('input', { name: 'clientId', value: e.clientId, placeholder: '00000000-0000-0000-0000-000000000000', autocomplete: 'off' }))),
    el('div', { class: 'field' }, el('span', { class: 'label' }, 'Authentication'),
      el('div', { class: 'radio-row' },
        el('label', { for: 'auth-secret' }, authSecret, ' Client secret'),
        el('label', { for: 'auth-cert' }, authCert, ' Certificate (recommended)'))),
    secretBlock, certBlock,
    el('div', { class: 'row2' },
      field('Sender mailbox', el('input', { name: 'sender', type: 'email', value: e.sender, placeholder: 'pki-alerts@contoso.com' }),
        'A user or shared mailbox in this tenant'),
      field('Recipients', el('textarea', { name: 'recipients', rows: 2, placeholder: 'pki-team@contoso.com, oncall@contoso.com' }, (e.recipients || []).join(', ')),
        'Comma or newline separated')),
    field('Dashboard URL', el('input', { name: 'dashboardUrl', value: e.dashboardUrl || location.origin + '/', placeholder: 'https://acme-dashboard.contoso.com/' }),
      'Linked from every email'),
    el('div', { class: 'test-row' }, testTo, testBtn,
      el('span', { class: 'muted small' }, 'Uses the values above without saving them.')),
    testResult,
    setupHelp(e));

  // --- expiry warnings ---
  const pending = status.alertsPending || [];
  const issueLabel = { expired: 'expired', expiring: 'expiring', overdue: 'renewal overdue', invalid: 'failed', outdated: 'old certificate', mismatch: 'wrong certificate' };
  const alertsCard = el('section', { class: 'card settings-card' },
    el('div', { class: 'card-head' }, el('h3', {}, 'Expiry warnings')),
    toggleRow('Email when certificates need attention', { name: 'alertsEnabled', checked: a.enabled },
      `Checked every 15 minutes. Each problem is reported once, then again every reminder interval until it is fixed.`),
    el('div', { class: 'row3' },
      field('Expiring within (days)', el('input', { name: 'expiringDays', type: 'number', min: 0, max: 365, value: a.expiringDays })),
      field('Renewal overdue after (days)', el('input', { name: 'overdueDays', type: 'number', min: 0, max: 365, value: a.overdueDays }), 'Days past renew-after; means auto-renewal is failing'),
      field('Remind every (hours)', el('input', { name: 'reminderHours', type: 'number', min: 1, max: 8760, value: a.reminderHours }))),
    checkbox('Include orders that failed', { name: 'includeFailed', checked: a.includeFailed }),
    checkbox('Ignore staging / test ACME servers', { name: 'alertsSkipStaging', checked: a.skipStaging }),
    el('div', { class: 'inline-field' },
      checkbox('Include servers still serving an old or wrong certificate, after', { name: 'includeDeployments', checked: a.includeDeployments }),
      el('input', { name: 'deploymentGraceHours', type: 'number', min: 0, max: 720, value: a.deploymentGraceHours, 'aria-label': 'Grace hours after renewal' }),
      el('span', { class: 'small' }, 'hours')),
    el('h4', {}, 'Currently matching (saved settings)'),
    pending.length
      ? el('div', { class: 'chips' }, pending.map((p) => el('span', { class: 'pill ' + (p.issue === 'overdue' ? 'warn' : 'bad') }, `${p.mainDomain} — ${issueLabel[p.issue] || p.issue}`)))
      : el('p', { class: 'muted small' }, 'No certificates need attention.'),
    el('div', { class: 'test-row', style: 'margin-top:12px' },
      el('button', { type: 'button', class: 'btn', disabled: !e.enabled, onclick: (ev) => sendNow('alerts', ev.target) }, 'Send alert now'),
      el('span', { class: 'muted small' }, 'Sends every current issue, ignoring reminders.')));

  // --- digest ---
  const freq = el('select', { name: 'frequency' }, ['daily', 'weekly'].map((x) => el('option', { value: x, selected: d.frequency === x }, x === 'daily' ? 'Daily' : 'Weekly')));
  const dayField = field('Day', el('select', { name: 'dayOfWeek' }, DAYS.map((x) => el('option', { value: x, selected: d.dayOfWeek === x }, x))));
  const syncFreq = () => dayField.classList.toggle('hidden', freq.value !== 'weekly');
  freq.addEventListener('change', syncFreq); syncFreq();
  const digestCard = el('section', { class: 'card settings-card' },
    el('div', { class: 'card-head' }, el('h3', {}, 'Summary digest')),
    toggleRow('Email a summary of all certificates', { name: 'digestEnabled', checked: d.enabled }),
    el('div', { class: 'row3' }, field('Frequency', freq), dayField,
      field('Time', el('input', { name: 'time', type: 'time', value: d.time }), status.timeZone)),
    checkbox('Ignore staging / test ACME servers', { name: 'digestSkipStaging', checked: d.skipStaging }),
    el('p', { class: 'muted small' }, d.enabled && status.nextDigest ? `Next digest: ${fmtDateTime(status.nextDigest)}` : 'The digest is off.'),
    el('div', { class: 'test-row' },
      el('button', { type: 'button', class: 'btn', disabled: !e.enabled, onclick: (ev) => sendNow('digest', ev.target) }, 'Send digest now')));

  // --- server checks ---
  const dp = settings.deployments || { autoCheckHours: 6 };
  const deployCard = el('section', { class: 'card settings-card' },
    el('div', { class: 'card-head' }, el('h3', {}, 'Server checks')),
    el('div', { class: 'row2' },
      field('Check deployments every (hours)', el('input', { name: 'autoCheckHours', type: 'number', min: 0, max: 168, value: dp.autoCheckHours }),
        '0 = only when you click Check. Connects to each server on the Deployments tab and reads the certificate it presents.')));

  // --- status ---
  const statusCard = el('section', { class: 'card settings-card' },
    el('div', { class: 'card-head' }, el('h3', {}, 'Delivery status')),
    status.lastError ? el('div', { class: 'banner bad', style: 'margin:0 0 12px' }, el('div', {}, el('strong', {}, `Last error (${fmtDateTime(status.lastErrorAt)}): `), status.lastError)) : null,
    kv([
      ['Email', status.emailEnabled ? el('span', { class: 'pill ok' }, 'Enabled') : el('span', { class: 'pill' }, 'Disabled')],
      ['Last check', status.lastAlertCheck ? `${fmtDateTime(status.lastAlertCheck)} (${fmtRelative(status.lastAlertCheck)})` : 'Never'],
      ['Last alert sent', status.lastAlertSent ? fmtDateTime(status.lastAlertSent) : 'Never'],
      ['Last digest sent', status.lastDigestSent ? fmtDateTime(status.lastDigestSent) : 'Never'],
    ]),
    el('p', { class: 'muted small', style: 'margin:12px 0 0' },
      'Emails are sent by the dashboard while it runs. To send them even when it is stopped, schedule ',
      el('code', {}, 'Start-PoshAcmeDashboard.ps1 -NotifyOnce'), ' hourly as the same Windows user.'),
    settings.savedAt ? el('p', { class: 'muted small' }, `Settings last saved ${fmtDateTime(settings.savedAt)} by ${settings.savedBy}.`) : null);

  const saveBar = el('div', { class: 'save-bar' },
    el('span', { id: 'dirty-note', class: 'muted small' }, ''),
    el('button', { type: 'button', class: 'btn', onclick: () => { settingsDirty = false; loadSettings(); } }, 'Discard changes'),
    el('button', { type: 'submit', class: 'btn primary' }, 'Save settings'));

  clear(form, el('div', { class: 'settings-grid' }, emailCard, el('div', {}, alertsCard, digestCard, deployCard, statusCard)), saveBar);

  function markDirty() {
    settingsDirty = true;
    $('#dirty-note').textContent = 'Unsaved changes';
    $('.save-bar').classList.add('dirty');
  }
  form.oninput = (ev) => { if (ev.target.name !== 'testTo') markDirty(); };
  form.onchange = form.oninput;

  function collect() {
    const f = form.elements;
    return {
      email: {
        enabled: f.emailEnabled.checked,
        tenantId: f.tenantId.value.trim(),
        clientId: f.clientId.value.trim(),
        authType: authCert.checked ? 'certificate' : 'secret',
        clientSecret: secretInput.value || null,
        clearSecret,
        certThumbprint: f.certThumbprint.value.trim(),
        certStore: f.certStore.value,
        sender: f.sender.value.trim(),
        recipients: f.recipients.value.split(/[\s,;]+/).filter(Boolean),
        dashboardUrl: f.dashboardUrl.value.trim(),
      },
      alerts: {
        enabled: f.alertsEnabled.checked,
        expiringDays: f.expiringDays.value,
        overdueDays: f.overdueDays.value,
        reminderHours: f.reminderHours.value,
        includeFailed: f.includeFailed.checked,
        skipStaging: f.alertsSkipStaging.checked,
        includeDeployments: f.includeDeployments.checked,
        deploymentGraceHours: f.deploymentGraceHours.value,
      },
      deployments: { autoCheckHours: f.autoCheckHours.value },
      digest: {
        enabled: f.digestEnabled.checked,
        frequency: f.frequency.value,
        dayOfWeek: f.dayOfWeek.value,
        time: f.time.value,
        skipStaging: f.digestSkipStaging.checked,
      },
    };
  }

  async function sendTestEmail() {
    testBtn.disabled = true;
    clear(testResult, el('div', { class: 'test-result running' }, 'Signing in to Microsoft Entra ID and sending…'));
    try {
      const body = collect();
      const r = await api('settings/email/test', { method: 'POST', body: { email: body.email, to: testTo.value.trim() ? [testTo.value.trim()] : null } });
      clear(testResult, el('div', { class: 'test-result ok' }, el('div', { class: 'test-line PASS' }, el('span', { class: 'test-icon' }, '✓'),
        el('span', {}, `Test email sent to ${r.sentTo.join(', ')}. Check the inbox (and junk folder).`))));
    } catch (ex) {
      clear(testResult, el('div', { class: 'test-result fail' }, el('div', { class: 'test-line FAIL' }, el('span', { class: 'test-icon' }, '✗'), el('span', {}, ex.message))));
    } finally {
      testBtn.disabled = false;
    }
  }

  async function sendNow(kind, btn) {
    if (settingsDirty) { toast('Save your changes first.', true); return; }
    btn.disabled = true;
    try {
      const r = await api('notifications/' + kind, { method: 'POST', body: {} });
      toast(kind === 'digest' ? `Digest sent (${r.certificates} certificates).` : r.sent ? `Alert sent for ${plural(r.sent, 'certificate')}.` : 'Nothing to report: no certificates need attention.');
      loadSettings();
    } catch (ex) {
      toast(ex.message, true);
      loadSettings();
    } finally {
      btn.disabled = false;
    }
  }

  form.onsubmit = async (ev) => {
    ev.preventDefault();
    const btn = $('button[type=submit]', form);
    btn.disabled = true;
    try {
      const saved = await api('settings', { method: 'POST', body: collect() });
      settingsDirty = false;
      toast('Settings saved.');
      renderSettings(saved, await api('notifications'));
    } catch (ex) {
      toast(ex.message, true);
    } finally {
      btn.disabled = false;
    }
  };
}

function setupHelp(e) {
  const clientId = e.clientId || '<client-id>';
  const certSnippet = `$cert = New-SelfSignedCertificate -Subject 'CN=Posh-ACME Dashboard' -CertStoreLocation Cert:\\CurrentUser\\My \`
    -KeySpec Signature -KeyLength 2048 -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(2)
Export-Certificate -Cert $cert -FilePath .\\posh-acme-dashboard.cer   # upload this file to the app registration
$cert.Thumbprint                                                    # paste into "Certificate thumbprint"`;
  const policySnippet = `# Exchange Online PowerShell: only allow the app to send as members of this mail-enabled security group
New-ApplicationAccessPolicy -AppId ${clientId} -PolicyScopeGroupId pki-alerts-senders@contoso.com \`
    -AccessRight RestrictAccess -Description 'Posh-ACME dashboard mail'`;
  return el('details', { class: 'advanced setup-help' }, el('summary', {}, 'How to set up the Entra ID app registration'),
    el('ol', {},
      el('li', {}, 'In the Microsoft Entra admin center, go to ', el('strong', {}, 'App registrations → New registration'), '. Single tenant, no redirect URI.'),
      el('li', {}, 'Copy the ', el('strong', {}, 'Application (client) ID'), ' and ', el('strong', {}, 'Directory (tenant) ID'), ' into the fields above.'),
      el('li', {}, el('strong', {}, 'API permissions → Add a permission → Microsoft Graph → Application permissions → Mail.Send'), ', then ', el('strong', {}, 'Grant admin consent'), '.'),
      el('li', {}, el('strong', {}, 'Certificates & secrets'), ': upload a certificate (recommended, see below) or create a client secret and paste its ', el('em', {}, 'Value'), '. Secrets expire; note the date.'),
      el('li', {}, 'Use a shared mailbox (no license needed) as the sender, for example ', el('code', {}, 'pki-alerts@contoso.com'), '.'),
      el('li', {}, el('strong', {}, 'Recommended: '), 'Mail.Send lets the app send as ', el('em', {}, 'any'),
        ' mailbox. Restrict it to the sender mailbox with Exchange Online RBAC for Applications or an application access policy.')),
    el('p', { class: 'small' }, el('strong', {}, 'Create a certificate'), ' (run as ', state.info ? state.info.runAs : 'the dashboard user', ', the same user as the dashboard):'),
    el('pre', { class: 'snippet' }, certSnippet),
    el('p', { class: 'small' }, el('strong', {}, 'Restrict the app'), ' (application access policy example):'),
    el('pre', { class: 'snippet' }, policySnippet));
}

// ---------------------------------------------------------------------------
// Tabs, theme, wiring
// ---------------------------------------------------------------------------

function showTab(name) {
  $$('.tabs button').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.tab === name)));
  $$('.tab-panel').forEach((p) => p.classList.toggle('hidden', p.id !== 'tab-' + name));
  if (location.hash !== '#' + name) history.replaceState(null, '', '#' + name);
  if (name === 'settings') loadSettings();
  if (name === 'deploy') renderDeployments();
}

function applyTheme(theme) {
  if (theme) document.documentElement.dataset.theme = theme; else delete document.documentElement.dataset.theme;
}

function init() {
  let theme = null;
  try { theme = localStorage.getItem('pad-theme'); } catch { /* storage unavailable */ }
  applyTheme(theme);
  $('#theme').addEventListener('click', () => {
    const dark = document.documentElement.dataset.theme
      ? document.documentElement.dataset.theme === 'dark'
      : matchMedia('(prefers-color-scheme: dark)').matches;
    const next = dark ? 'light' : 'dark';
    applyTheme(next);
    try { localStorage.setItem('pad-theme', next); } catch { /* ignore */ }
  });

  $$('.tabs button').forEach((b) => b.addEventListener('click', () => showTab(b.dataset.tab)));
  $('#refresh').addEventListener('click', () => { state.tasks = null; loadAll(); loadJobs(); });
  $('#search').addEventListener('input', (e) => { state.filter.search = e.target.value; renderTable(); });
  $('#server-filter').addEventListener('change', (e) => { state.filter.server = e.target.value; renderKpis(); renderTable(); });
  $('#new-cert').addEventListener('click', newCertificateDialog);
  $('#new-account').addEventListener('click', newAccountDialog);
  $('#new-deploy').addEventListener('click', () => deploymentDialog());
  $('#deploy-check-all').addEventListener('click', () => checkDeployments());
  $('#deploy-search').addEventListener('input', renderDeployments);
  $('#deploy-filter').addEventListener('change', renderDeployments);
  $$('[data-close-drawer]').forEach((n) => n.addEventListener('click', closeDrawer));
  $$('#cert-table th[data-sort]').forEach((th) => th.addEventListener('click', () => {
    const key = th.dataset.sort;
    state.sort = { key, desc: state.sort.key === key ? !state.sort.desc : false };
    renderTable();
  }));

  document.addEventListener('keydown', (e) => {
    if (e.target.closest('input, textarea, select, dialog')) return;
    if (e.key === '/') { e.preventDefault(); showTab('certs'); $('#search').focus(); }
    else if (e.key === 'r' && !e.ctrlKey && !e.metaKey) loadAll();
    else if (e.key === 'Escape') closeDrawer();
  });

  const initialTab = location.hash.slice(1);
  showTab(['certs', 'deploy', 'accounts', 'activity', 'renewal', 'settings'].includes(initialTab) ? initialTab : 'certs');

  api('info').then((info) => {
    state.info = info;
    document.body.classList.toggle('read-only', !info.canWrite);
    document.body.classList.toggle('read-only-mode', !!info.readOnlyMode);
    $('#whoami').textContent = info.user;
    if (location.hash === '#settings') loadSettings(); // re-render with the Windows account name
    $('#whoami').title = `Server ${info.host} · runs as ${info.runAs} · Posh-ACME ${info.poshAcmeVersion} · PowerShell ${info.psVersion}`;
    return Promise.all([loadAll(), loadJobs()]);
  }).catch((e) => {
    clear($('#banners'), el('div', { class: 'banner bad' }, 'Cannot reach the dashboard server: ', e.message));
  });

  setInterval(() => { if (!document.hidden) loadAll(); }, 60000);
  setInterval(updateClock, 15000);
}

init();
