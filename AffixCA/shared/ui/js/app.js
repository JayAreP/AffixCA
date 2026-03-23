/* ============================================================================
   Affix/CA  ·  app.js  —  Single-page application
   Bootstraps from /api/status, renders context-aware PKI dashboard.
   Roles-based navigation, dynamic templates, trust chain export.
   ============================================================================ */

'use strict';

// ── Global State ──────────────────────────────────────────────────────────────
const State = {
  status:       null,
  certs:        [],
  templates:    [],       // cached from /api/templates
  chainData:    null,     // cached from /api/chain
  activity:     [],
  issuedResult: null,
  signedResult: null,
  activeView:   'dashboard',
  selectedProfile: null,
  pemFocus:     'cert',   // 'cert' | 'key' | 'chain'
  pollTimer:    null,
};

// ── API Layer ──────────────────────────────────────────────────────────────────
const API = {
  async get(path) {
    const r = await fetch(path);
    if (!r.ok) {
      const body = await r.json().catch(() => ({ error: r.statusText }));
      throw new Error(body.error || r.statusText);
    }
    return r.json();
  },

  async post(path, data) {
    const r = await fetch(path, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(data),
    });
    const body = await r.json().catch(() => ({ error: r.statusText }));
    if (!r.ok) throw new Error(body.error || r.statusText);
    return body;
  },
};

// ── Toast Notifications ────────────────────────────────────────────────────────
const Toast = {
  show(msg, type = 'info', duration = 4000) {
    const icons = { success: '✓', error: '✕', warn: '⚠', info: 'ℹ' };
    const el = document.createElement('div');
    el.className = `toast toast-${type}`;
    el.innerHTML = `<span class="toast-icon">${icons[type]}</span><span class="toast-msg">${msg}</span>`;
    document.getElementById('toast-container').appendChild(el);
    setTimeout(() => {
      el.classList.add('out');
      el.addEventListener('animationend', () => el.remove());
    }, duration);
  },
};

// ── Modal ──────────────────────────────────────────────────────────────────────
const Modal = {
  open(html, title = '') {
    const overlay = document.getElementById('modal-overlay');
    document.getElementById('modal-content').innerHTML =
      title ? `<h3 style="font-size:14px;font-weight:600;color:var(--text);margin-bottom:16px;">${title}</h3>${html}` : html;
    overlay.style.display = 'flex';
  },
  close() {
    document.getElementById('modal-overlay').style.display = 'none';
  },
};

// Make Modal.close available globally (called in HTML onclick)
window.Modal = Modal;

// ── Clock ─────────────────────────────────────────────────────────────────────
function startClock() {
  const el = document.getElementById('topbar-clock');
  const tick = () => {
    const now = new Date();
    el.textContent = now.toLocaleTimeString('en-GB', { hour12: false }) +
                     ' UTC' + (now.getTimezoneOffset() > 0 ? '-' : '+') +
                     String(Math.abs(now.getTimezoneOffset() / 60)).padStart(2,'0') + ':00';
  };
  tick();
  setInterval(tick, 1000);
}

// ── Background Canvas ─────────────────────────────────────────────────────────
function initCanvas() {
  const canvas = document.getElementById('bg-canvas');
  const ctx    = canvas.getContext('2d');
  let W, H, dots;

  function resize() {
    W = canvas.width  = window.innerWidth;
    H = canvas.height = window.innerHeight;
    dots = Array.from({ length: 60 }, () => ({
      x: Math.random() * W,
      y: Math.random() * H,
      r: Math.random() * 1.2 + 0.3,
      dx: (Math.random() - 0.5) * 0.25,
      dy: (Math.random() - 0.5) * 0.25,
    }));
  }

  function draw() {
    ctx.clearRect(0, 0, W, H);

    // Grid lines
    ctx.strokeStyle = 'rgba(249,115,22,0.04)';
    ctx.lineWidth = 1;
    const step = 60;
    for (let x = 0; x <= W; x += step) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, H); ctx.stroke(); }
    for (let y = 0; y <= H; y += step) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(W, y); ctx.stroke(); }

    // Moving dots + connections
    for (const d of dots) {
      d.x += d.dx; d.y += d.dy;
      if (d.x < 0) d.x = W; if (d.x > W) d.x = 0;
      if (d.y < 0) d.y = H; if (d.y > H) d.y = 0;

      ctx.beginPath();
      ctx.arc(d.x, d.y, d.r, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(249,115,22,0.5)';
      ctx.fill();
    }

    // Connect nearby dots
    for (let i = 0; i < dots.length; i++) {
      for (let j = i + 1; j < dots.length; j++) {
        const dx = dots[i].x - dots[j].x;
        const dy = dots[i].y - dots[j].y;
        const dist = Math.sqrt(dx*dx + dy*dy);
        if (dist < 120) {
          ctx.beginPath();
          ctx.moveTo(dots[i].x, dots[i].y);
          ctx.lineTo(dots[j].x, dots[j].y);
          ctx.strokeStyle = `rgba(249,115,22,${0.06 * (1 - dist / 120)})`;
          ctx.lineWidth = 1;
          ctx.stroke();
        }
      }
    }

    requestAnimationFrame(draw);
  }

  resize();
  window.addEventListener('resize', resize);
  draw();
}

// ── Counter Animation ─────────────────────────────────────────────────────────
function animateCounter(el, target) {
  const start = parseInt(el.textContent) || 0;
  const dur   = 600;
  const t0    = performance.now();
  const tick  = (t) => {
    const p = Math.min((t - t0) / dur, 1);
    el.textContent = Math.round(start + (target - start) * easeOut(p));
    if (p < 1) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}

function easeOut(t) { return 1 - Math.pow(1 - t, 3); }

// ── CA Hierarchy SVG — Dynamic from status.tiers ─────────────────────────────
function renderHierarchy(status) {
  const svg  = document.getElementById('hierarchy-svg');
  const W    = svg.clientWidth || 600;

  const typeColors = {
    root:         { fill: 'rgba(249,115,22,0.12)',   stroke: '#f97316' },
    intermediate: { fill: 'rgba(59,130,246,0.15)',  stroke: '#3b82f6' },
    policy:       { fill: 'rgba(59,130,246,0.15)',  stroke: '#3b82f6' },
    tls:          { fill: 'rgba(249,115,22,0.12)',   stroke: '#f97316' },
    codesign:     { fill: 'rgba(245,158,11,0.12)',  stroke: '#f59e0b' },
    smime:        { fill: 'rgba(34,197,94,0.12)',  stroke: '#22c55e' },
    issuing:      { fill: 'rgba(249,115,22,0.12)',   stroke: '#f97316' },
    ocsp:         { fill: 'rgba(244,63,94,0.1)',    stroke: '#f43f5e' },
    crl:          { fill: 'rgba(100,100,120,0.1)',   stroke: '#667788' },
    tsa:          { fill: 'rgba(59,130,246,0.1)',    stroke: '#3b82f6' },
  };

  const roles = status.roles || [];
  const tiers = status.tiers || {};

  // Build nodes dynamically from tiers data if available
  let nodes = [];
  let edges = [];

  if (tiers && Object.keys(tiers).length > 0) {
    // Dynamic layout from tiers
    const tierKeys = Object.keys(tiers).sort((a, b) => parseInt(a) - parseInt(b));
    let yPos = 30;
    const yStep = 80;

    for (const tierKey of tierKeys) {
      const tierNodes = Array.isArray(tiers[tierKey]) ? tiers[tierKey] : [tiers[tierKey]];
      const count = tierNodes.length;

      tierNodes.forEach((n, idx) => {
        const xPos = count === 1 ? W / 2 : W * ((idx + 1) / (count + 1));
        const nodeType = n.type || n.role || tierKey;
        nodes.push({
          id:    n.id || `${tierKey}-${idx}`,
          label: n.label || n.name || n.cn || nodeType,
          sub:   n.sub || n.algo || '',
          x:     xPos,
          y:     yPos,
          type:  nodeType,
          tier:  parseInt(tierKey),
        });
      });

      yPos += yStep;
    }

    // Connect parent-child based on tier order
    for (let i = 0; i < nodes.length; i++) {
      for (let j = i + 1; j < nodes.length; j++) {
        if (nodes[j].tier === nodes[i].tier + 1) {
          edges.push([nodes[i].id, nodes[j].id]);
        }
      }
    }

    const H = yPos - yStep + 60;
    svg.setAttribute('height', H);
  } else if (status.standalone || roles.length > 1) {
    // Standalone mode: show full PKI hierarchy with all active roles
    const hasRoot = roles.includes('root');
    const hasIntermediate = roles.includes('intermediate') || roles.includes('policy');
    const hasIssuing = roles.includes('issuing') || roles.includes('tls') || roles.includes('codesign') || roles.includes('smime');

    let yPos = 30;
    const yStep = 80;

    if (hasRoot) {
      nodes.push({ id: 'root', label: 'Root CA', sub: status.caName ? '' : '30yr · RSA 4096', x: W / 2, y: yPos, type: 'root' });
      yPos += yStep;
    }
    if (hasIntermediate) {
      nodes.push({ id: 'intermediate', label: 'Policy CA', sub: '15yr · RSA 4096', x: W / 2, y: yPos, type: 'intermediate' });
      yPos += yStep;
    }
    if (hasIssuing) {
      // Show issuing tier with distinct CAs
      const issuingTypes = [
        { id: 'tls',      label: 'TLS CA',        sub: '10yr · ECDSA P-384', type: 'tls' },
        { id: 'codesign', label: 'Code Sign CA',   sub: '10yr · RSA 4096',    type: 'codesign' },
        { id: 'smime',    label: 'S/MIME CA',      sub: '10yr · RSA 4096',    type: 'smime' },
      ];
      const count = issuingTypes.length;
      issuingTypes.forEach((iss, idx) => {
        nodes.push({ ...iss, x: W * ((idx + 1) / (count + 1)), y: yPos });
      });
      yPos += yStep;
    }

    // Build edges: root→intermediate, intermediate→issuing CAs
    if (hasRoot && hasIntermediate) edges.push(['root', 'intermediate']);
    if (hasRoot && !hasIntermediate && hasIssuing) {
      nodes.filter(n => ['tls','codesign','smime'].includes(n.type)).forEach(n => edges.push(['root', n.id]));
    }
    if (hasIntermediate && hasIssuing) {
      nodes.filter(n => ['tls','codesign','smime'].includes(n.type)).forEach(n => edges.push(['intermediate', n.id]));
    }

    svg.setAttribute('height', yPos - yStep + 60);
  } else {
    // Single-role fallback: show self only
    const selfType = roles[0] || 'issuing';
    nodes = [
      { id: 'self', label: status.caName || 'This CA', sub: '', x: W / 2, y: 50, type: selfType },
    ];
    svg.setAttribute('height', 120);
  }

  const NW = 130, NH = 48;
  const H = parseInt(svg.getAttribute('height'));

  let markup = `<svg viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg" style="width:100%;height:${H}px">`;

  // Edges
  markup += '<g class="hier-edges">';
  for (const [a, b] of edges) {
    const na = nodes.find(n => n.id === a);
    const nb = nodes.find(n => n.id === b);
    if (!na || !nb) continue;
    const color = typeColors[na.type]?.stroke || '#667788';
    markup += `<path d="M${na.x},${na.y + NH/2} C${na.x},${(na.y+nb.y)/2} ${nb.x},${(na.y+nb.y)/2} ${nb.x},${nb.y - NH/2}"
      fill="none" stroke="${color}" class="hier-edge" stroke-dasharray="5 4"/>`;
  }
  markup += '</g>';

  // Nodes
  markup += '<g class="hier-nodes">';
  for (const n of nodes) {
    const c    = typeColors[n.type] || typeColors.issuing;
    // Highlight self: match if this CA's roles include the node type, or if the node is named as this CA
    const isSelf = (status.caName && n.label === status.caName) || roles.includes(n.type);
    const glowFilter = isSelf ? ` filter="url(#glow-${n.id})"` : '';

    markup += `
      <defs>
        <filter id="glow-${n.id}" x="-30%" y="-30%" width="160%" height="160%">
          <feGaussianBlur in="SourceGraphic" stdDeviation="4" result="blur"/>
          <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
        </filter>
      </defs>
      <g class="hier-node" transform="translate(${n.x - NW/2},${n.y - NH/2})"${glowFilter}>
        <rect width="${NW}" height="${NH}" rx="8" ry="8"
              fill="${c.fill}" stroke="${c.stroke}" stroke-width="${isSelf ? 2 : 1.5}"
              ${isSelf ? `opacity="1"` : 'opacity="0.85"'}/>
        <circle cx="${NW - 12}" cy="12" r="4.5" class="hier-status-dot"
                fill="${isSelf ? c.stroke : 'rgba(100,120,140,0.4)'}"
                ${isSelf ? `style="filter: drop-shadow(0 0 4px ${c.stroke})"` : ''}/>
        <text x="${NW/2}" y="${NH/2 - 4}" text-anchor="middle" class="hier-label">${n.label}</text>
        <text x="${NW/2}" y="${NH/2 + 11}" text-anchor="middle" class="hier-sublabel">${n.sub}</text>
      </g>`;
  }
  markup += '</g></svg>';

  svg.innerHTML = markup;
}

// ── CA Node Strip (top bar) — Dynamic from /api/status peers ──────────────────
async function refreshNodeStrip() {
  const strip = document.getElementById('ca-node-strip');
  if (!strip) return;

  const s = State.status;
  if (!s) { strip.innerHTML = ''; return; }

  // If status provides peers array, probe them
  if (s.peers && Array.isArray(s.peers) && s.peers.length > 0) {
    const results = await Promise.allSettled(
      s.peers.map(n => {
        return fetch(`${n.url || `http://${location.hostname}:${n.port}`}/api/health`, { signal: AbortSignal.timeout(1500) })
          .then(r => r.ok ? r.json() : { initialized: false })
          .then(h => ({ ...n, online: h.initialized ? 'online' : 'warn' }))
          .catch(() => ({ ...n, online: 'offline' }));
      })
    );

    strip.innerHTML = results.map(r => {
      const n = r.value || {};
      const status = n.online || 'offline';
      return `<div class="ca-node-chip" data-status="${status}" title="${n.label || n.name || ''} — ${status}">
        <span class="ca-node-dot"></span>${n.label || n.name || ''}
      </div>`;
    }).join('');
  } else if (s.standalone) {
    // Standalone mode: show all roles as active chips
    const roleLabels = {
      root: 'Root CA', intermediate: 'Policy CA', policy: 'Policy CA',
      issuing: 'Issuing CA', tls: 'TLS CA', codesign: 'CodeSign CA',
      smime: 'S/MIME CA', ocsp: 'OCSP', crl: 'CRL', tsa: 'TSA'
    };
    const roles = s.roles || [];
    const initialized = s.initialized !== false;
    strip.innerHTML = roles.map(r => {
      const label = roleLabels[r] || r;
      const status = initialized ? 'online' : 'warn';
      return `<div class="ca-node-chip" data-status="${status}" title="${label} — ${status}">
        <span class="ca-node-dot"></span>${label}
      </div>`;
    }).join('');
  } else {
    strip.innerHTML = '';
  }
}

// ── Certificate Table ─────────────────────────────────────────────────────────
function renderCertTable(certs) {
  const tbody  = document.getElementById('cert-tbody');
  const search = (document.getElementById('cert-search')?.value || '').toLowerCase();
  const filter = document.getElementById('cert-filter')?.value || '';

  const filtered = certs.filter(c => {
    const matchSearch = !search ||
      c.serial?.toLowerCase().includes(search) ||
      c.cn?.toLowerCase().includes(search) ||
      c.subject?.toLowerCase().includes(search);
    const matchStatus = !filter || c.status === filter ||
      (filter === 'expiring' && c.status === 'expiring');
    return matchSearch && matchStatus;
  });

  if (!filtered.length) {
    tbody.innerHTML = `<tr class="table-empty"><td colspan="7">No certificates match the current filter.</td></tr>`;
    return;
  }

  tbody.innerHTML = filtered.map(c => `
    <tr data-serial="${escHtml(c.serial)}" onclick="showCertDetail('${escHtml(c.serial)}')">
      <td class="serial">${escHtml(c.serial)}</td>
      <td class="cn"    title="${escHtml(c.subject)}">${escHtml(c.cn || c.subject)}</td>
      <td>${escHtml(c.template || c.profile || '—')}</td>
      <td class="mono"  style="font-size:11px">${escHtml(c.issuedAt?.substring(0,10) || '—')}</td>
      <td class="mono"  style="font-size:11px">${escHtml(c.notAfter?.substring(0,10) || '—')}</td>
      <td><span class="badge badge-${c.status}">${c.status}</span></td>
      <td>
        <button class="btn btn-sm" onclick="event.stopPropagation(); downloadCert('${escHtml(c.serial)}')">↓ PEM</button>
        ${c.status !== 'revoked' ? `<button class="btn btn-sm btn-danger" onclick="event.stopPropagation(); revokeCert('${escHtml(c.serial)}')">Revoke</button>` : ''}
      </td>
    </tr>
  `).join('');
}

// ── Cert detail modal ─────────────────────────────────────────────────────────
async function showCertDetail(serial) {
  const cert = State.certs.find(c => c.serial === serial);
  if (!cert) return;

  let pemHtml = '';
  if (cert.hasPem) {
    try {
      const resp = await API.get(`/api/certificates/${serial}/pem`);
      pemHtml = `<div class="cert-pem-box" style="margin-top:12px">
        <pre class="pem-pre" style="max-height:180px">${escHtml(resp.pem)}</pre>
        <button class="copy-btn" onclick="navigator.clipboard.writeText(document.querySelector('.pem-pre').textContent); Toast.show('Copied!','success')" title="Copy" style="top:8px;right:8px">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/></svg>
        </button>
      </div>`;
    } catch {}
  }

  Modal.open(`
    <div style="font-size:12px;color:var(--text-mid);line-height:2;font-family:'JetBrains Mono',monospace">
      <div><span style="color:var(--text-muted)">Serial   </span> ${escHtml(cert.serial)}</div>
      <div><span style="color:var(--text-muted)">Subject  </span> ${escHtml(cert.subject)}</div>
      <div><span style="color:var(--text-muted)">Expires  </span> ${escHtml(cert.notAfter || '—')}</div>
      <div><span style="color:var(--text-muted)">Status   </span> <span class="badge badge-${cert.status}">${cert.status}</span></div>
    </div>
    ${pemHtml}
  `, `Certificate — ${cert.cn || cert.serial}`);
}

window.showCertDetail = showCertDetail;

// ── Download / Revoke helpers ──────────────────────────────────────────────────
async function downloadCert(serial) {
  const r = await fetch(`/api/certificates/${serial}/pem`);
  if (!r.ok) { Toast.show('Download failed', 'error'); return; }
  const { pem } = await r.json();
  triggerDownload(`${serial}.pem`, pem, 'application/x-pem-file');
}

async function revokeCert(serial) {
  if (!confirm(`Revoke certificate ${serial}? This cannot be undone.`)) return;
  try {
    await API.post(`/api/certificates/${serial}/revoke`, { reason: 'unspecified' });
    Toast.show(`Certificate ${serial} revoked.`, 'success');
    await loadCertificates();
  } catch (e) {
    Toast.show(e.message, 'error');
  }
}

window.downloadCert = downloadCert;
window.revokeCert   = revokeCert;

function triggerDownload(filename, content, mime) {
  const blob = new Blob([content], { type: mime });
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement('a');
  a.href = url; a.download = filename;
  document.body.appendChild(a); a.click();
  setTimeout(() => { URL.revokeObjectURL(url); a.remove(); }, 1000);
}

// ── Load Status ────────────────────────────────────────────────────────────────
async function loadStatus() {
  try {
    const s = await API.get('/api/status');
    State.status = s;
    applyStatus(s);
  } catch (e) {
    console.error('Status load failed:', e);
  }
}

function applyStatus(s) {
  // Sidebar CA identity
  const badge  = document.getElementById('ca-type-badge');
  const name   = document.getElementById('ca-name');
  const dot    = document.getElementById('ca-status-dot');
  const status = document.getElementById('ca-status-text');

  // Derive primary role label from roles array
  const roles = s.roles || [];
  const primaryRole = roles[0] || 'unknown';
  badge.textContent = primaryRole.toUpperCase();
  badge.setAttribute('data-type', primaryRole);
  badge.className   = 'ca-identity-badge';

  name.textContent  = s.caName || '—';

  const online = s.initialized !== false;
  dot.className     = `status-dot ${online ? 'online' : 'uninit'}`;
  status.textContent = online ? 'Online' : 'Not Initialized';

  // Dashboard title
  document.getElementById('dash-title').textContent = s.caName || 'Dashboard';
  document.getElementById('dash-subtitle').textContent = s.caSubject || '';
  document.title = `Affix/CA — ${s.caName || primaryRole || 'Dashboard'}`;

  // Stats
  const st = s.stats || {};
  animateCounter(document.getElementById('stat-total'),   st.total   || 0);
  animateCounter(document.getElementById('stat-valid'),   st.valid   || 0);
  animateCounter(document.getElementById('stat-revoked'), st.revoked || 0);
  animateCounter(document.getElementById('stat-expiring'),st.expiring|| 0);

  // Sidebar expiry bar
  if (s.daysUntilExpiry != null) {
    const total = s.totalDays || 3652;
    const pct   = Math.max(0, Math.min(100, (s.daysUntilExpiry / total) * 100));
    document.getElementById('expiry-value').textContent =
      s.daysUntilExpiry > 0 ? `${s.daysUntilExpiry}d remaining` : 'EXPIRED';
    const bar = document.getElementById('expiry-bar');
    bar.style.width = `${pct}%`;
    if (pct < 10) bar.classList.add('warn');
    else if (pct <= 0) bar.classList.add('expired');
  }

  // Show/hide navigation items based on roles array
  const hasIssuing    = roles.includes('issuing') || roles.includes('tls') || roles.includes('codesign') || roles.includes('smime');
  const hasSignCSR    = roles.includes('root') || roles.includes('intermediate') || roles.includes('policy');
  const hasTemplates  = hasIssuing;

  document.getElementById('nav-issue').classList.toggle    ('nav-hidden', !hasIssuing);
  document.getElementById('nav-templates').classList.toggle('nav-hidden', !hasTemplates);
  document.getElementById('nav-sign-csr').classList.toggle ('nav-hidden', !hasSignCSR);
  document.getElementById('nav-ceremony').classList.toggle ('nav-hidden', online);

  // Show Users nav for admin users
  const authUser = window.AffixAuth && AffixAuth.getUser();
  const usersNav = document.getElementById('nav-users');
  if (usersNav) usersNav.classList.toggle('nav-hidden', !authUser || authUser.role !== 'admin');

  // Ceremony banner on dashboard when not initialized
  const banner = document.getElementById('ceremony-banner');
  if (banner) banner.style.display = !online ? 'flex' : 'none';

  // Render hierarchy from tiers data
  renderHierarchy(s);

  // Populate issue profiles from templates
  if (hasIssuing) {
    populateProfiles();
  }
}

// ── Load Templates ─────────────────────────────────────────────────────────────
async function loadTemplates() {
  try {
    const data = await API.get('/api/templates');
    State.templates = data.templates || [];
    renderTemplateGrid(State.templates);
    return State.templates;
  } catch (e) {
    console.error('Template load failed:', e);
    return [];
  }
}

function renderTemplateGrid(templates) {
  const grid = document.getElementById('template-grid');
  if (!grid) return;

  if (!templates.length) {
    grid.innerHTML = '<div class="template-empty">No templates available</div>';
    return;
  }

  grid.innerHTML = templates.map(t => `
    <div class="panel template-card">
      <div class="panel-header">
        <span class="panel-title" style="color:${t.color || 'var(--cyan)'}">
          ${templateIcon(t)}
          ${escHtml(t.name || t.id)}
        </span>
        <span class="panel-badge">${escHtml(t.id)}</span>
      </div>
      <div class="panel-body">
        <div class="template-card-desc">${escHtml(t.desc || t.description || '')}</div>
        <div class="template-card-meta">
          ${t.keyUsage   ? `<span>Key Usage: ${escHtml(t.keyUsage)}</span>`     : ''}
          ${t.extKeyUsage? `<span>EKU: ${escHtml(t.extKeyUsage)}</span>`        : ''}
          ${t.maxDays    ? `<span>Max validity: ${t.maxDays}d</span>`           : ''}
        </div>
      </div>
    </div>
  `).join('');
}

function templateIcon(t) {
  const type = (t.id || t.type || '').toLowerCase();
  if (type.includes('tls') || type.includes('server')) return serverIcon();
  if (type.includes('client'))     return clientIcon();
  if (type.includes('code'))       return codeIcon();
  if (type.includes('mail') || type.includes('smime') || type.includes('email')) return emailIcon();
  // Default
  return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>';
}

// ── Load Certificates ──────────────────────────────────────────────────────────
async function loadCertificates() {
  try {
    const data = await API.get('/api/certificates');
    State.certs = data.certificates || [];
    renderCertTable(State.certs);
    renderRevokedTable(State.certs.filter(c => c.status === 'revoked'));
    updateActivityList(State.certs);
  } catch (e) {
    console.error('Cert load failed:', e);
  }
}

function updateActivityList(certs) {
  const el   = document.getElementById('activity-list');
  const cnt  = document.getElementById('activity-count');
  const recent = [...certs]
    .sort((a, b) => new Date(b.issuedAt || 0) - new Date(a.issuedAt || 0))
    .slice(0, 20);

  cnt.textContent = recent.length;

  if (!recent.length) {
    el.innerHTML = '<li class="activity-empty">No recent activity</li>';
    return;
  }

  el.innerHTML = recent.map(c => {
    const actionClass = c.status === 'revoked' ? 'revoke' : 'issue';
    const actionLabel = c.status === 'revoked' ? 'Revoked' : 'Issued';
    return `
      <li class="activity-item">
        <div class="activity-icon ${actionClass}">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
            ${c.status === 'revoked'
              ? '<circle cx="12" cy="12" r="10"/><line x1="4.93" y1="4.93" x2="19.07" y2="19.07"/>'
              : '<path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/><polyline points="14 2 14 8 20 8"/>'}
          </svg>
        </div>
        <div class="activity-body">
          <div class="activity-msg">${actionLabel}: ${escHtml(c.cn || c.serial)}</div>
          <div class="activity-time">${escHtml(c.serial)}</div>
        </div>
      </li>
    `;
  }).join('');
}

// ── Revoked Table ──────────────────────────────────────────────────────────────
function renderRevokedTable(revoked) {
  const tbody = document.getElementById('revoked-tbody');
  if (!revoked.length) {
    tbody.innerHTML = '<tr class="table-empty"><td colspan="4">No revoked certificates</td></tr>';
    return;
  }
  tbody.innerHTML = revoked.map(c => `
    <tr>
      <td class="serial">${escHtml(c.serial)}</td>
      <td>${escHtml(c.cn || '—')}</td>
      <td class="mono" style="font-size:11px">${escHtml(c.revokedAt || '—')}</td>
      <td>${escHtml(c.reason || 'unspecified')}</td>
    </tr>
  `).join('');
}

// ── Load CRL Info ──────────────────────────────────────────────────────────────
async function loadCRLInfo() {
  try {
    const d = await API.get('/api/crl/info');
    document.getElementById('crl-last').textContent    = d.lastGenerated || '—';
    document.getElementById('crl-next').textContent    = d.nextUpdate    || '—';
    document.getElementById('crl-entries').textContent = d.entries ?? '—';
    document.getElementById('crl-number').textContent  = d.crlNumber     || '—';
  } catch {}
}

// ── Load Trust Chain ──────────────────────────────────────────────────────────
async function loadChain() {
  try {
    const data = await API.get('/api/chain');
    State.chainData = data;
    renderChainCards(data);
  } catch (e) {
    console.error('Chain load failed:', e);
    const container = document.getElementById('chain-cards');
    if (container) container.innerHTML = '<div class="template-empty">Failed to load trust chain</div>';
  }
}

function renderChainCards(data) {
  const container = document.getElementById('chain-cards');
  if (!container) return;

  const certs = data.certs || [];

  if (!certs.length) {
    container.innerHTML = '<div class="template-empty">No chain certificates available</div>';
    return;
  }

  container.innerHTML = certs.map((cert, idx) => `
    <div class="chain-card">
      <div class="chain-card-position">
        <span class="chain-card-idx">${idx + 1}</span>
        ${idx < certs.length - 1 ? '<div class="chain-card-connector"></div>' : ''}
      </div>
      <div class="chain-card-body">
        <div class="chain-card-header">
          <div class="chain-card-cn">${escHtml(cert.cn || cert.subject || 'Unknown')}</div>
          <span class="badge badge-valid">${idx === 0 ? 'Leaf / This CA' : idx === certs.length - 1 ? 'Root' : 'Intermediate'}</span>
        </div>
        <div class="chain-card-details">
          <div class="chain-card-row">
            <span class="chain-card-label">Serial</span>
            <span class="chain-card-value mono">${escHtml(cert.serial || '—')}</span>
          </div>
          <div class="chain-card-row">
            <span class="chain-card-label">Expires</span>
            <span class="chain-card-value mono">${escHtml(cert.notAfter?.substring(0, 10) || '—')}</span>
          </div>
          ${cert.thumbprint ? `
          <div class="chain-card-row">
            <span class="chain-card-label">Thumbprint (SHA-256)</span>
            <span class="chain-card-value mono" style="font-size:10px;word-break:break-all">${escHtml(cert.thumbprint)}</span>
          </div>` : ''}
        </div>
      </div>
    </div>
  `).join('');
}

// ── Import Instructions ───────────────────────────────────────────────────────
const IMPORT_INSTRUCTIONS = {
  macos: `<ol>
    <li>Download the <strong>Full Chain (PEM)</strong> file</li>
    <li>Open <strong>Keychain Access</strong></li>
    <li>Select the <strong>System</strong> keychain</li>
    <li>Drag the PEM file into the keychain, or use <code>File → Import Items…</code></li>
    <li>Double-click the imported certificate, expand <strong>Trust</strong>, and set to <strong>Always Trust</strong></li>
  </ol>
  <pre class="pem-pre" style="margin-top:10px;max-height:60px">sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain chain.pem</pre>`,

  windows: `<ol>
    <li>Download the <strong>Full Chain (PEM)</strong> or <strong>PKCS#7 (.p7b)</strong> file</li>
    <li>Double-click the file, then click <strong>Install Certificate…</strong></li>
    <li>Select <strong>Local Machine</strong> → Next</li>
    <li>Choose <strong>Place all certificates in the following store</strong></li>
    <li>Browse → <strong>Trusted Root Certification Authorities</strong> → OK → Next → Finish</li>
  </ol>
  <pre class="pem-pre" style="margin-top:10px;max-height:60px">certutil -addstore "Root" chain.pem</pre>`,

  linux: `<ol>
    <li>Download the <strong>Full Chain (PEM)</strong> file</li>
    <li>Copy to the system trust store directory:</li>
  </ol>
  <pre class="pem-pre" style="margin-top:10px;max-height:100px"># Debian/Ubuntu
sudo cp chain.pem /usr/local/share/ca-certificates/affix-ca.crt
sudo update-ca-certificates

# RHEL/CentOS/Fedora
sudo cp chain.pem /etc/pki/ca-trust/source/anchors/affix-ca.pem
sudo update-ca-trust</pre>`,

  firefox: `<ol>
    <li>Download the <strong>Full Chain (PEM)</strong> file</li>
    <li>Open Firefox → <strong>Settings</strong> → <strong>Privacy & Security</strong></li>
    <li>Scroll to <strong>Certificates</strong> → <strong>View Certificates…</strong></li>
    <li>Click the <strong>Authorities</strong> tab → <strong>Import…</strong></li>
    <li>Select the PEM file and check <strong>Trust this CA to identify websites</strong></li>
  </ol>
  <p style="margin-top:8px;font-size:11px;color:var(--text-muted)">Note: Firefox uses its own certificate store, separate from the OS trust store.</p>`,
};

function showImportInstructions(platform) {
  const content = document.getElementById('import-content');
  if (content) {
    content.innerHTML = IMPORT_INSTRUCTIONS[platform] || '';
  }
  document.querySelectorAll('.import-tab').forEach(t => {
    t.classList.toggle('active', t.dataset.platform === platform);
  });
}

// ── Profile Selector — Builds from API templates ─────────────────────────────
function populateProfiles() {
  const grid = document.getElementById('profile-grid');
  if (!grid) return;

  const templates = State.templates;
  if (!templates.length) {
    // Try to load templates first, then populate
    loadTemplates().then(() => {
      buildProfileGrid(grid, State.templates);
    });
    return;
  }

  buildProfileGrid(grid, templates);
}

function buildProfileGrid(grid, templates) {
  if (!templates.length) {
    grid.innerHTML = '<div style="color:var(--text-muted);font-size:12px;padding:8px">No templates available</div>';
    return;
  }

  State.selectedProfile = templates[0]?.id || null;

  // Map templates to profile cards
  const profiles = templates.map(t => ({
    id:    t.id,
    name:  t.name || t.id,
    desc:  t.desc || t.description || '',
    color: t.color || profileColor(t.id),
    icon:  templateIcon(t),
  }));

  grid.innerHTML = profiles.map(p => `
    <div class="profile-card ${p.id === State.selectedProfile ? 'active' : ''}"
         data-profile="${escHtml(p.id)}"
         onclick="selectProfile('${escHtml(p.id)}')">
      <div class="profile-card-icon" style="background: ${p.color}20; color: ${p.color}">
        ${p.icon}
      </div>
      <div class="profile-card-info">
        <div class="profile-card-name">${escHtml(p.name)}</div>
        <div class="profile-card-desc">${escHtml(p.desc)}</div>
      </div>
    </div>
  `).join('');

  updateProfileUI(State.selectedProfile);
}

function profileColor(id) {
  const lower = (id || '').toLowerCase();
  if (lower.includes('tls') || lower.includes('server')) return '#f97316';
  if (lower.includes('client'))   return '#3b82f6';
  if (lower.includes('code'))     return '#f59e0b';
  if (lower.includes('smime') || lower.includes('mail') || lower.includes('email')) return '#22c55e';
  return '#f97316';
}

function selectProfile(id) {
  State.selectedProfile = id;
  document.querySelectorAll('.profile-card').forEach(el => {
    el.classList.toggle('active', el.dataset.profile === id);
  });
  updateProfileUI(id);
}

window.selectProfile = selectProfile;

function updateProfileUI(profileId) {
  // Show/hide SAN field based on profile
  const sanGroup = document.getElementById('san-group');
  if (sanGroup) {
    const lower = (profileId || '').toLowerCase();
    const showSan = lower.includes('tls') || lower.includes('server') || lower.includes('client') || lower.includes('smime') || lower.includes('mail');
    sanGroup.style.display = showSan ? '' : 'none';
  }
}

// ── Issue Certificate ─────────────────────────────────────────────────────────
async function issueCertificate() {
  const btn = document.getElementById('btn-issue');
  if (!btn) return;

  const cn      = document.getElementById('issue-cn')?.value?.trim();
  const san     = document.getElementById('issue-san')?.value?.trim();
  const org     = document.getElementById('issue-org')?.value?.trim();
  const ou      = document.getElementById('issue-ou')?.value?.trim();
  const country = document.getElementById('issue-country')?.value?.trim();
  const algo    = document.getElementById('issue-algo')?.value;
  const days    = parseInt(document.getElementById('issue-days')?.value) || 365;

  if (!cn) { Toast.show('Common Name is required.', 'warn'); return; }
  if (!State.selectedProfile) { Toast.show('Select a certificate template.', 'warn'); return; }

  const [algoType, algoParam] = algo.split('-');
  const payload = {
    template: State.selectedProfile,
    subject:  { cn, o: org || undefined, ou: ou || undefined, c: country || undefined },
    san:      san ? san.split(',').map(s => s.trim()).filter(Boolean) : [],
    days,
    keyAlgo:  algoType,
    keyParam: algoParam,
  };

  btn.disabled = true;
  btn.textContent = 'Issuing…';

  try {
    const result = await API.post('/api/issue', payload);
    State.issuedResult = result;
    showIssueResult(result);
    Toast.show(`Certificate issued: ${result.serial}`, 'success');
    await loadCertificates();
  } catch (e) {
    Toast.show(`Issue failed: ${e.message}`, 'error');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Issue Certificate';
  }
}

function showIssueResult(result) {
  const panel = document.getElementById('issue-result');
  if (!panel) return;
  panel.style.display = '';

  document.getElementById('result-meta').innerHTML =
    `Serial: ${escHtml(result.serial)} &nbsp;|&nbsp; Expires: ${escHtml(result.notAfter || '—')}`;

  // Default to cert view
  State.pemFocus = 'cert';
  updatePEMDisplay();

  // Wire download buttons
  document.getElementById('dl-cert')?.addEventListener('click', () =>
    triggerDownload(`${result.serial}.pem`, result.certificate, 'application/x-pem-file'));
  document.getElementById('dl-key')?.addEventListener('click', () =>
    triggerDownload(`${result.serial}-key.pem`, result.privateKey, 'application/x-pem-file'));
  document.getElementById('dl-chain')?.addEventListener('click', () =>
    triggerDownload(`${result.serial}-chain.pem`, result.chain, 'application/x-pem-file'));
  document.getElementById('dl-p12')?.addEventListener('click', () => {
    const pw = prompt('Enter PKCS#12 password:');
    if (pw === null) return;
    API.post(`/api/certificates/${result.serial}/pkcs12`, { password: pw })
      .then(r => { triggerDownload(`${result.serial}.p12`, atob(r.p12Base64), 'application/x-pkcs12'); })
      .catch(e => Toast.show(e.message, 'error'));
  });

  panel.scrollIntoView({ behavior: 'smooth' });
}

function updatePEMDisplay() {
  const r   = State.issuedResult;
  const pre = document.getElementById('pem-display');
  if (!r || !pre) return;

  const map = { cert: r.certificate, key: r.privateKey, chain: r.chain };
  pre.textContent = map[State.pemFocus] || '—';
}

// ── Sign Subordinate CSR ───────────────────────────────────────────────────────
async function signSubordinateCSR() {
  const csr     = document.getElementById('csr-paste')?.value?.trim();
  const profile = document.getElementById('csr-profile')?.value;
  const days    = parseInt(document.getElementById('csr-days')?.value) || 5475;

  if (!csr?.includes('CERTIFICATE REQUEST')) {
    Toast.show('Paste a valid PEM CSR.', 'warn');
    return;
  }

  const btn = document.getElementById('btn-sign-subordinate');
  btn.disabled = true; btn.textContent = 'Signing…';

  try {
    const result = await API.post('/api/sign-csr', { csr, profile, days });
    State.signedResult = result;

    const panel  = document.getElementById('sign-result');
    const preEl  = document.getElementById('signed-pem-display');
    panel.style.display = '';
    preEl.textContent   = result.certificate;

    document.getElementById('dl-signed-cert').onclick = () =>
      triggerDownload(`${result.serial}.pem`, result.certificate, 'application/x-pem-file');

    Toast.show('Certificate signed successfully.', 'success');
    panel.scrollIntoView({ behavior: 'smooth' });
  } catch (e) {
    Toast.show(`Signing failed: ${e.message}`, 'error');
  } finally {
    btn.disabled = false; btn.textContent = 'Sign Certificate';
  }
}

// ── CA Ceremony Wizard ─────────────────────────────────────────────────────────
const wizard = {
  current: 1,
  max: 4,

  next() {
    if (this.current < this.max) {
      document.querySelector(`.wizard-step[data-step="${this.current}"]`)?.classList.add('done');
      this.current++;
      this.render();
    }
  },

  prev() {
    if (this.current > 1) {
      document.querySelector(`.wizard-step[data-step="${this.current}"]`)?.classList.remove('done');
      this.current--;
      this.render();
    }
  },

  render() {
    document.querySelectorAll('.wizard-pane').forEach(p => p.classList.remove('active'));
    document.querySelectorAll('.wizard-step').forEach(s => s.classList.remove('active'));
    document.querySelector(`.wizard-pane[data-pane="${this.current}"]`)?.classList.add('active');
    document.querySelector(`.wizard-step[data-step="${this.current}"]`)?.classList.add('active');
  },
};

window.wizard = wizard;

async function runCeremony() {
  const cn       = document.getElementById('cer-cn')?.value?.trim();
  const org      = document.getElementById('cer-org')?.value?.trim();
  const country  = document.getElementById('cer-country')?.value?.trim() || 'US';
  const state    = document.getElementById('cer-state')?.value?.trim();
  const locality = document.getElementById('cer-locality')?.value?.trim();
  const algo     = document.getElementById('cer-algo')?.value;
  const days     = parseInt(document.getElementById('cer-days')?.value) || 10957;

  if (!cn || !org) { Toast.show('CN and Organization are required.', 'warn'); return; }

  const btn = document.getElementById('btn-run-ceremony');
  btn.disabled = true; btn.textContent = 'Generating…';

  const log = document.getElementById('ceremony-log');
  log.style.display = '';
  log.textContent   = '';

  const appendLog = (msg) => { log.textContent += `[${new Date().toLocaleTimeString()}] ${msg}\n`; log.scrollTop = log.scrollHeight; };

  appendLog('Starting CA initialization…');

  try {
    const [algoType, algoParam] = algo.split('-');
    const result = await API.post('/api/ceremony/init', {
      subject: { cn, o: org, c: country, st: state || undefined, l: locality || undefined },
      days,
      keyAlgo: algoType, keyParam: algoParam,
    });

    appendLog(`Key generated (${algo})`);
    appendLog(`Self-signed certificate created`);
    appendLog(`Serial: ${result.serial}`);
    appendLog('Initial CRL generated');
    appendLog('Published to /published volume');
    appendLog('Ceremony complete!');

    // Advance to completion step
    wizard.next();

    // Show cert
    document.getElementById('ceremony-cert-display').innerHTML =
      `<div class="cert-pem-box"><pre class="pem-pre" style="max-height:160px">${escHtml(result.certificate)}</pre></div>`;

    Toast.show('CA initialized successfully!', 'success');
    await loadStatus();
  } catch (e) {
    appendLog(`ERROR: ${e.message}`);
    Toast.show(e.message, 'error');
  } finally {
    btn.disabled = false; btn.textContent = 'Generate CA';
  }
}

// ── Navigation ────────────────────────────────────────────────────────────────
const App = {
  navigate(viewId) {
    State.activeView = viewId;

    document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
    document.querySelectorAll('.nav-link').forEach(l => l.classList.remove('active'));

    document.getElementById(`view-${viewId}`)?.classList.add('active');
    document.querySelector(`.nav-link[data-view="${viewId}"]`)?.classList.add('active');

    // Lazy-load view data
    if (viewId === 'certificates') loadCertificates();
    if (viewId === 'revocation')   { loadCertificates(); loadCRLInfo(); }
    if (viewId === 'chain')        loadChain();
    if (viewId === 'templates')    loadTemplates();
    if (viewId === 'users')        loadUsers();
    if (viewId === 'webserver')    loadWebServerCert();
  },
};

window.App = App;

// ── Utility ───────────────────────────────────────────────────────────────────
function escHtml(str) {
  if (str == null) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// SVG icon helpers
function serverIcon() { return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="2" width="20" height="8" rx="2"/><rect x="2" y="14" width="20" height="8" rx="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/></svg>'; }
function clientIcon() { return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="5" y="2" width="14" height="20" rx="2"/><line x1="12" y1="18" x2="12.01" y2="18"/></svg>'; }
function codeIcon()   { return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>'; }
function emailIcon()  { return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"/><polyline points="22,6 12,13 2,6"/></svg>'; }

// ── Event Wiring ──────────────────────────────────────────────────────────────
function wireEvents() {
  // Navigation links
  document.querySelectorAll('.nav-link[data-view]').forEach(link => {
    link.addEventListener('click', (e) => {
      e.preventDefault();
      App.navigate(link.dataset.view);
    });
  });

  // Ceremony banner button
  document.querySelector('.ceremony-banner .btn')?.addEventListener('click', () => App.navigate('ceremony'));

  // Search + filter
  document.getElementById('cert-search')?.addEventListener('input', () => renderCertTable(State.certs));
  document.getElementById('cert-filter')?.addEventListener('change', () => renderCertTable(State.certs));

  // Issue certificate button
  document.getElementById('btn-issue')?.addEventListener('click', issueCertificate);

  // Sign uploaded CSR
  document.getElementById('btn-sign-csr-upload')?.addEventListener('click', async () => {
    const csr  = document.getElementById('issue-csr-paste')?.value?.trim();
    const days = parseInt(document.getElementById('issue-csr-days')?.value) || 365;
    if (!csr?.includes('CERTIFICATE REQUEST')) { Toast.show('Paste a valid PEM CSR.', 'warn'); return; }
    try {
      const result = await API.post('/api/issue', { csr, template: State.selectedProfile, days });
      State.issuedResult = result;
      showIssueResult(result);
    } catch (e) { Toast.show(e.message, 'error'); }
  });

  // Sign subordinate CSR
  document.getElementById('btn-sign-subordinate')?.addEventListener('click', signSubordinateCSR);

  // Ceremony run
  document.getElementById('btn-run-ceremony')?.addEventListener('click', runCeremony);

  // Refresh button
  document.getElementById('btn-refresh')?.addEventListener('click', async () => {
    const btn = document.getElementById('btn-refresh');
    btn.classList.add('spinning');
    await Promise.all([loadStatus(), loadCertificates(), refreshNodeStrip()]);
    btn.classList.remove('spinning');
    Toast.show('Refreshed.', 'info', 1500);
  });

  // CRL buttons
  document.getElementById('btn-regenerate-crl')?.addEventListener('click', async () => {
    try { await API.post('/api/crl/regenerate', {}); Toast.show('CRL regenerated.', 'success'); await loadCRLInfo(); }
    catch (e) { Toast.show(e.message, 'error'); }
  });
  document.getElementById('btn-dl-crl-pem')?.addEventListener('click', () => window.open('/api/crl/pem'));
  document.getElementById('btn-dl-crl-der')?.addEventListener('click', () => window.open('/api/crl/der'));

  // Chain download buttons
  document.getElementById('btn-dl-chain-pem')?.addEventListener('click', () => {
    window.open('/api/chain/download?format=pem');
  });
  document.getElementById('btn-dl-chain-p7b')?.addEventListener('click', () => {
    window.open('/api/chain/download?format=p7b');
  });
  document.getElementById('btn-copy-chain-pem')?.addEventListener('click', async () => {
    try {
      if (State.chainData?.chain) {
        await navigator.clipboard.writeText(State.chainData.chain);
        Toast.show('Chain PEM copied to clipboard', 'success', 2000);
      } else {
        const data = await API.get('/api/chain');
        if (data.chain) {
          await navigator.clipboard.writeText(data.chain);
          Toast.show('Chain PEM copied to clipboard', 'success', 2000);
        }
      }
    } catch (e) {
      Toast.show('Copy failed', 'error');
    }
  });

  // Import instruction tabs
  document.querySelectorAll('.import-tab').forEach(tab => {
    tab.addEventListener('click', () => {
      showImportInstructions(tab.dataset.platform);
    });
  });

  // PEM tab switching
  document.querySelectorAll('.pem-tab').forEach(tab => {
    tab.addEventListener('click', () => {
      State.pemFocus = tab.dataset.pem;
      document.querySelectorAll('.pem-tab').forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
      updatePEMDisplay();
    });
  });

  // Copy button
  document.getElementById('pem-copy')?.addEventListener('click', () => {
    const text = document.getElementById('pem-display')?.textContent;
    if (text) {
      navigator.clipboard.writeText(text).then(() => Toast.show('Copied to clipboard', 'success', 2000));
    }
  });

  // Tab switcher (form vs CSR)
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      const tabId = btn.dataset.tab;
      document.querySelectorAll('.tab-btn').forEach(t => t.classList.remove('active'));
      document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
      btn.classList.add('active');
      document.getElementById(`tab-${tabId}`)?.classList.add('active');
    });
  });

  // Close modal on overlay click
  document.getElementById('modal-overlay')?.addEventListener('click', (e) => {
    if (e.target === document.getElementById('modal-overlay')) Modal.close();
  });

  // Escape key
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') Modal.close();
  });
}

// ── Polling ───────────────────────────────────────────────────────────────────
function startPolling() {
  State.pollTimer = setInterval(async () => {
    await loadStatus();
    if (State.activeView === 'certificates') await loadCertificates();
    if (State.activeView === 'revocation')   await Promise.all([loadCertificates(), loadCRLInfo()]);
  }, 30_000);
}

// ── User Management ──────────────────────────────────────────────────────────
async function loadUsers() {
  try {
    const data = await API.get('/api/auth/users');
    if (data.success) renderUsersTable(data.users);
  } catch (e) {
    Toast.show('Failed to load users: ' + e.message, 'error');
  }
}

function renderUsersTable(users) {
  const tbody = document.getElementById('users-tbody');
  if (!tbody) return;
  if (!users || users.length === 0) {
    tbody.innerHTML = '<tr class="table-empty"><td colspan="4">No users found</td></tr>';
    return;
  }
  tbody.innerHTML = users.map(u => {
    const created = u.createdAt ? new Date(u.createdAt).toLocaleDateString() : '—';
    const roleBadge = u.role === 'admin'
      ? '<span class="status-badge badge-valid">admin</span>'
      : '<span class="status-badge badge-expiring">user</span>';
    const currentUser = window.AffixAuth?.getUser();
    const isSelf = currentUser && currentUser.username === u.username;
    const actions = isSelf
      ? '<span style="color:var(--text-muted);font-size:12px">current</span>'
      : `<button class="btn btn-sm btn-table" onclick="resetUserPassword('${u.username}')">Reset PW</button>
         <button class="btn btn-sm btn-table btn-danger-sm" onclick="deleteUser('${u.username}')">Delete</button>`;
    return `<tr>
      <td><span class="mono">${u.username}</span></td>
      <td>${roleBadge}</td>
      <td>${created}</td>
      <td>${actions}</td>
    </tr>`;
  }).join('');
}

async function addUser() {
  Modal.open(`
    <div style="display:flex;flex-direction:column;gap:14px;min-width:300px">
      <div class="form-group"><label>Username</label>
        <input type="text" id="new-username" class="input" placeholder="username" /></div>
      <div class="form-group"><label>Password</label>
        <input type="password" id="new-password" class="input" placeholder="password" /></div>
      <div class="form-group"><label>Role</label>
        <select id="new-role" class="select">
          <option value="user">User</option>
          <option value="admin">Admin</option>
        </select></div>
      <button class="btn btn-primary" id="btn-create-user-confirm">Create User</button>
    </div>
  `, 'Add User');
  document.getElementById('btn-create-user-confirm')?.addEventListener('click', async () => {
    const username = document.getElementById('new-username').value.trim();
    const password = document.getElementById('new-password').value;
    const role     = document.getElementById('new-role').value;
    if (!username || !password) { Toast.show('Username and password required', 'warn'); return; }
    try {
      await API.post('/api/auth/users', { username, password, role });
      Toast.show(`User '${username}' created`, 'success');
      Modal.close();
      await loadUsers();
    } catch (e) { Toast.show(e.message || e.error, 'error'); }
  });
}

async function deleteUser(username) {
  if (!confirm(`Delete user "${username}"? This cannot be undone.`)) return;
  try {
    await API.post('/api/auth/users/' + encodeURIComponent(username), {}); // Will fail — need DELETE
  } catch {}
  // Use raw fetch for DELETE
  try {
    const r = await fetch('/api/auth/users/' + encodeURIComponent(username), { method: 'DELETE' });
    const data = await r.json();
    if (data.success) {
      Toast.show(`User '${username}' deleted`, 'success');
      await loadUsers();
    } else { Toast.show(data.message, 'error'); }
  } catch (e) { Toast.show(e.message, 'error'); }
}

async function resetUserPassword(username) {
  Modal.open(`
    <div style="display:flex;flex-direction:column;gap:14px;min-width:300px">
      <div class="form-group"><label>New Password for ${username}</label>
        <input type="password" id="reset-pw-input" class="input" placeholder="new password" /></div>
      <button class="btn btn-primary" id="btn-reset-pw-confirm">Reset Password</button>
    </div>
  `, 'Reset Password');
  document.getElementById('btn-reset-pw-confirm')?.addEventListener('click', async () => {
    const password = document.getElementById('reset-pw-input').value;
    if (!password) { Toast.show('Password required', 'warn'); return; }
    try {
      const r = await fetch('/api/auth/users/' + encodeURIComponent(username), {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password })
      });
      const data = await r.json();
      if (data.success) {
        Toast.show(`Password reset for '${username}'`, 'success');
        Modal.close();
      } else { Toast.show(data.message, 'error'); }
    } catch (e) { Toast.show(e.message, 'error'); }
  });
}

// Make user mgmt functions globally accessible (called from onclick in rendered HTML)
window.resetUserPassword = resetUserPassword;
window.deleteUser = deleteUser;

function wireUserEvents() {
  document.getElementById('btn-add-user')?.addEventListener('click', addUser);

  document.getElementById('btn-change-pw')?.addEventListener('click', async () => {
    const currentPassword = document.getElementById('chg-current-pw')?.value;
    const newPassword     = document.getElementById('chg-new-pw')?.value;
    if (!currentPassword || !newPassword) { Toast.show('Both fields required', 'warn'); return; }
    try {
      const data = await API.post('/api/auth/change-password', { currentPassword, newPassword });
      if (data.success) {
        Toast.show('Password changed', 'success');
        document.getElementById('chg-current-pw').value = '';
        document.getElementById('chg-new-pw').value = '';
      } else { Toast.show(data.message, 'error'); }
    } catch (e) { Toast.show(e.message, 'error'); }
  });
}

// ── Web Server Certificate ────────────────────────────────────────────────────
async function loadWebServerCert() {
  const el = document.getElementById('ws-cert-info');
  if (!el) return;
  try {
    const data = await fetch('/api/webserver/cert').then(r => r.json());
    if (!data.hasCert) {
      el.innerHTML = '<p class="text-muted">No certificate installed.</p>';
      return;
    }

    const statusClass = data.selfSigned ? 'badge-warning' : 'badge-success';
    const statusLabel = data.selfSigned ? 'Self-Signed' : 'CA-Signed';
    const daysClass = data.daysLeft < 30 ? 'text-danger' : data.daysLeft < 90 ? 'text-warning' : '';

    el.innerHTML = `
      <div style="display:grid; grid-template-columns:140px 1fr; gap:8px 16px; font-size:13px;">
        <span class="text-muted">Status</span>
        <span><span class="badge ${statusClass}">${statusLabel}</span></span>
        <span class="text-muted">Subject</span>
        <span style="font-family:'JetBrains Mono',monospace; font-size:12px">${escHtml(data.subject)}</span>
        <span class="text-muted">Issuer</span>
        <span style="font-family:'JetBrains Mono',monospace; font-size:12px">${escHtml(data.issuer)}</span>
        <span class="text-muted">Serial</span>
        <span style="font-family:'JetBrains Mono',monospace; font-size:12px">${escHtml(data.serial)}</span>
        <span class="text-muted">Not Before</span>
        <span>${escHtml(data.notBefore)}</span>
        <span class="text-muted">Not After</span>
        <span class="${daysClass}">${escHtml(data.notAfter)} (${data.daysLeft} days remaining)</span>
        <span class="text-muted">Fingerprint</span>
        <span style="font-family:'JetBrains Mono',monospace; font-size:11px; word-break:break-all">${escHtml(data.fingerprint)}</span>
      </div>
    `;

    if (data.pendingCsr) {
      const csrPanel = document.getElementById('ws-csr-panel');
      const csrOutput = document.getElementById('ws-csr-output');
      if (csrPanel && csrOutput) {
        csrPanel.style.display = 'block';
        csrOutput.value = data.pendingCsr;
      }
    }
  } catch (err) {
    el.innerHTML = `<p class="text-danger">Failed to load certificate info: ${escHtml(err.message)}</p>`;
  }
}

function wireWebServerEvents() {
  // Auto-populate SANs with CN when the field is focused and empty
  document.getElementById('ws-csr-sans')?.addEventListener('focus', function() {
    if (!this.value.trim()) {
      const cn = document.getElementById('ws-csr-cn')?.value.trim();
      if (cn) this.value = cn;
    }
  });

  document.getElementById('btn-ws-gen-csr')?.addEventListener('click', async () => {
    const cn      = document.getElementById('ws-csr-cn')?.value.trim() || 'Affix/CA Web Server';
    const rawSans = document.getElementById('ws-csr-sans')?.value.trim() || '';

    // Convert bare hostnames to DNS: prefixed format
    const sans = rawSans ? rawSans.split(',')
      .map(s => s.trim())
      .filter(Boolean)
      .map(s => s.includes(':') ? s : 'DNS:' + s)
      .join(',') : '';

    const btn  = document.getElementById('btn-ws-gen-csr');

    btn.disabled = true;
    btn.textContent = 'Generating...';

    try {
      const res = await fetch('/api/webserver/csr', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ commonName: cn, sans })
      });
      const data = await res.json();
      if (!data.success) throw new Error(data.error);

      const panel  = document.getElementById('ws-csr-panel');
      const output = document.getElementById('ws-csr-output');
      panel.style.display = 'block';
      output.value = data.csr;

      loadWebServerCert();
    } catch (err) {
      alert('CSR generation failed: ' + err.message);
    } finally {
      btn.disabled = false;
      btn.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="14" height="14"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg> Generate CSR';
    }
  });

  document.getElementById('btn-ws-copy-csr')?.addEventListener('click', () => {
    const csr = document.getElementById('ws-csr-output')?.value;
    if (csr) {
      navigator.clipboard.writeText(csr).then(() => {
        const btn = document.getElementById('btn-ws-copy-csr');
        btn.textContent = 'Copied!';
        setTimeout(() => { btn.textContent = 'Copy to Clipboard'; }, 2000);
      });
    }
  });

  document.getElementById('btn-ws-download-csr')?.addEventListener('click', () => {
    const csr = document.getElementById('ws-csr-output')?.value;
    if (csr) {
      const blob = new Blob([csr], { type: 'application/pkcs10' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'affix-ca-webserver.csr';
      a.click();
      URL.revokeObjectURL(a.href);
    }
  });

  document.getElementById('btn-ws-self-sign')?.addEventListener('click', async () => {
    const csrPem = document.getElementById('ws-csr-output')?.value;
    if (!csrPem) { alert('No CSR to sign. Generate a CSR first.'); return; }

    const btn = document.getElementById('btn-ws-self-sign');
    btn.disabled = true;
    btn.textContent = 'Signing...';

    try {
      // Submit the CSR to the CA's own signing endpoint
      const res = await fetch('/api/sign-csr', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ csr: csrPem, profile: 'tls_server_ext', days: 365 })
      });
      const data = await res.json();
      if (!data.certificate) throw new Error(data.error || 'Signing failed');

      // Install the signed cert
      const installRes = await fetch('/api/webserver/install', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ certificate: data.certificate })
      });
      const installData = await installRes.json();
      if (!installData.success) throw new Error(installData.error);

      alert('Certificate signed and installed. The server will restart momentarily.');
      // Server restarts — page will reconnect
      setTimeout(() => { window.location.reload(); }, 3000);
    } catch (err) {
      alert('Self-sign failed: ' + err.message);
      btn.disabled = false;
      btn.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="14" height="14"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/></svg> Sign with this CA';
    }
  });

  document.getElementById('btn-ws-install')?.addEventListener('click', async () => {
    const certPem = document.getElementById('ws-cert-pem')?.value.trim();
    if (!certPem) { alert('Paste a PEM certificate first.'); return; }

    const btn = document.getElementById('btn-ws-install');
    btn.disabled = true;
    btn.textContent = 'Installing...';

    try {
      const res = await fetch('/api/webserver/install', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ certificate: certPem })
      });
      const data = await res.json();
      if (!data.success) throw new Error(data.error);

      alert('Certificate installed. The server will restart momentarily.');
      setTimeout(() => { window.location.reload(); }, 3000);
    } catch (err) {
      alert('Install failed: ' + err.message);
      btn.disabled = false;
      btn.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="14" height="14"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg> Install Certificate';
    }
  });
}

// ── Boot ──────────────────────────────────────────────────────────────────────
async function boot() {
  initCanvas();
  startClock();
  wireEvents();
  wireUserEvents();
  wireWebServerEvents();

  // Display authenticated user in topbar
  const authUser = window.AffixAuth && AffixAuth.getUser();
  const usernameEl = document.getElementById('topbar-username');
  if (usernameEl && authUser) usernameEl.textContent = authUser.username;

  // Show default import instructions
  showImportInstructions('macos');

  // Redirect to setup wizard if the CA hasn't been initialized yet
  try {
    const health = await fetch('/api/health').then(r => r.ok ? r.json() : null);
    if (health && !health.initialized) {
      window.location.href = '/ui/setup.html';
      return;
    }
  } catch {}

  try {
    await loadStatus();
    await Promise.all([loadCertificates(), loadTemplates()]);
  } catch {}

  // Probe sibling CA nodes in background (non-blocking)
  refreshNodeStrip().catch(() => {});

  startPolling();

  // Default to dashboard
  App.navigate('dashboard');
}

document.addEventListener('DOMContentLoaded', boot);
