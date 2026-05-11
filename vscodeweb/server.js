// ─── VibeCoding Auth Proxy ───────────────────────────────────────────────────
// HTTPS reverse proxy to VS Code serve-web with a password login gate.
// Run: node server.js
// Env: CODESERVER_PORT (default 8080), VIBE_PORT (default 9443), VIBE_PASSWORD

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execSync } = require('child_process');
const WebSocket = require('ws');

const CODESERVER_PORT = parseInt(process.env.CODESERVER_PORT || '8080', 10);
const VIBE_PORT = parseInt(process.env.VIBE_PORT || '9443', 10);
const VIBE_PASSWORD = process.env.VIBE_PASSWORD || '';
const VIBE_CERT = process.env.VIBE_CERT || '';
const VIBE_KEY = process.env.VIBE_KEY || '';
const VIBE_HOST = process.env.VIBE_HOST || 'localhost';
const CERT_DIR = path.join(__dirname, 'certs');

// ─── Backend connection ──────────────────────────────────────────────────────
// server-main.js listens on TCP directly (no code-tunnel.exe wrapper).
function backendOpts(extraHeaders) {
  return { hostname: '127.0.0.1', port: CODESERVER_PORT, headers: { host: 'localhost', ...extraHeaders } };
}

// Normalize a folder path to a URI-path suitable for ?folder=
// VS Code Web requires a leading '/' before the drive letter (e.g. /C:/Users/...)
// to register the remote file-system provider.  Without it → ENOPRO.
function toFolderUri(p) {
  let f = p.replace(/\\/g, '/');
  // Ensure leading slash before drive letter (C:/... → /C:/...)
  if (/^[A-Za-z]:/.test(f)) f = '/' + f;
  return f;
}

// ─── Active connection tracking ──────────────────────────────────────────────
// Track which folders have active WebSocket connections through the proxy.
// When a page loads with ?folder=X, we record it. When WebSocket opens shortly
// after, we associate the connection with that folder.
let _lastLoadedFolder = null;
let _lastLoadedAt = 0;
const _wsConns = new Map(); // connId -> { folder, openedAt }

function getActiveSessionFolders() {
  const folderMap = new Map(); // lowerFolder -> { folder, connections, since }
  let unassociated = 0;
  for (const [, c] of _wsConns) {
    if (c.folder) {
      const key = c.folder.toLowerCase();
      const existing = folderMap.get(key);
      if (existing) { existing.connections++; }
      else { folderMap.set(key, { folder: c.folder, connections: 1, since: c.openedAt }); }
    } else {
      unassociated++;
    }
  }
  const sessions = [];
  for (const [, info] of folderMap) {
    sessions.push({
      folder: info.folder,
      label: path.basename(info.folder) || info.folder,
      since: info.since,
      connections: info.connections,
    });
  }
  sessions.sort((a, b) => b.since - a.since);
  return { sessions, totalWs: _wsConns.size, unassociated };
}

// Process-based fallback: count Extension Host processes (works even after proxy restart)
let _cachedProcessCount = null;
let _processCountAt = 0;
function getExtHostProcessCount() {
  if (_cachedProcessCount !== null && (Date.now() - _processCountAt) < 15000) return _cachedProcessCount;
  try {
    const out = execSync(
      'powershell -NoProfile -Command "' +
      '$sm = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like \'*server-main*--host*\' } | Select-Object -First 1; ' +
      'if ($sm) { (Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $sm.ProcessId -and $_.CommandLine -like \'*extensionHost*\' }).Count }"',
      { encoding: 'utf8', timeout: 8000 }
    ).trim();
    _cachedProcessCount = parseInt(out, 10) || 0;
    _processCountAt = Date.now();
  } catch {
    _cachedProcessCount = 0;
    _processCountAt = Date.now();
  }
  return _cachedProcessCount;
}

// ─── Self-signed cert generation ─────────────────────────────────────────────
function ensureCerts() {
  // Use environment variables if provided (for ACME certificates)
  if (VIBE_CERT && VIBE_KEY) {
    if (fs.existsSync(VIBE_CERT) && fs.existsSync(VIBE_KEY)) {
      console.log(`[VibeCoding] Using ACME certificate: ${VIBE_CERT}`);
      return { key: fs.readFileSync(VIBE_KEY), cert: fs.readFileSync(VIBE_CERT) };
    }
  }

  if (!fs.existsSync(CERT_DIR)) fs.mkdirSync(CERT_DIR, { recursive: true });
  const keyPath = path.join(CERT_DIR, 'key.pem');
  const certPath = path.join(CERT_DIR, 'cert.pem');
  if (fs.existsSync(keyPath) && fs.existsSync(certPath)) {
    console.log(`[VibeCoding] Using existing self-signed certificate`);
    return { key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath) };
  }
  const { execSync } = require('child_process');
  console.log(`[VibeCoding] Generating self-signed certificate for ${VIBE_HOST}`);
  execSync(
    `openssl req -x509 -newkey rsa:2048 -keyout "${keyPath}" -out "${certPath}" -days 365 -nodes -subj "/CN=${VIBE_HOST}"`,
    { stdio: 'pipe' }
  );
  return { key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath) };
}

// ─── Session auth (persistent) ───────────────────────────────────────────────
const SESSION_FILE = path.join(__dirname, '.sessions.json');
const SESSION_MAX_AGE = 30 * 24 * 60 * 60; // 30 days in seconds

let sessions = new Set();
function loadSessions() {
  try {
    if (fs.existsSync(SESSION_FILE)) {
      const data = JSON.parse(fs.readFileSync(SESSION_FILE, 'utf8'));
      const now = Date.now();
      sessions = new Set(
        data.filter(s => s.expires > now).map(s => s.token)
      );
      console.log(`[VibeCoding] Loaded ${sessions.size} persistent session(s)`);
    }
  } catch (e) {
    console.warn('[VibeCoding] Failed to load sessions:', e.message);
  }
}
function saveSessions() {
  try {
    const now = Date.now();
    const data = [...sessions].map(token => ({
      token,
      expires: now + SESSION_MAX_AGE * 1000,
    }));
    fs.writeFileSync(SESSION_FILE, JSON.stringify(data), 'utf8');
  } catch (e) {
    console.warn('[VibeCoding] Failed to save sessions:', e.message);
  }
}
loadSessions();

// ─── Workspace tracking (persistent) ─────────────────────────────────────────
const WORKSPACES_FILE = path.join(__dirname, '.workspaces.json');

let workspaces = []; // [{ folder, label, lastAccess }]
function loadWorkspaces() {
  try {
    if (fs.existsSync(WORKSPACES_FILE)) {
      workspaces = JSON.parse(fs.readFileSync(WORKSPACES_FILE, 'utf8'));
      console.log(`[VibeCoding] Loaded ${workspaces.length} workspace(s)`);
    }
  } catch (e) {
    console.warn('[VibeCoding] Failed to load workspaces:', e.message);
  }
}
function saveWorkspaces() {
  try {
    fs.writeFileSync(WORKSPACES_FILE, JSON.stringify(workspaces, null, 2), 'utf8');
  } catch (e) {
    console.warn('[VibeCoding] Failed to save workspaces:', e.message);
  }
}
function trackWorkspace(folder) {
  if (!folder) return;
  const normalized = folder.replace(/\//g, '\\');
  const idx = workspaces.findIndex(w => w.folder.toLowerCase() === normalized.toLowerCase());
  const entry = {
    folder: normalized,
    label: path.basename(normalized) || normalized,
    lastAccess: Date.now(),
  };
  if (idx >= 0) {
    workspaces[idx] = entry;
  } else {
    workspaces.push(entry);
  }
  saveWorkspaces();
}
function removeWorkspace(folder) {
  const normalized = folder.replace(/\//g, '\\');
  workspaces = workspaces.filter(w => w.folder.toLowerCase() !== normalized.toLowerCase());
  saveWorkspaces();
}
loadWorkspaces();

function getSession(req) {
  const match = (req.headers.cookie || '').match(/vibe_session=([^;]+)/);
  return match && sessions.has(match[1]);
}

function showLogin(res) {
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end(`<!DOCTYPE html>
<html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>VibeCoding Login</title>
<style>
  body{background:#1e1e1e;color:#ccc;font-family:-apple-system,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}
  .box{background:#252526;padding:32px;border-radius:12px;width:min(320px,90vw);text-align:center}
  h1{color:#3794ff;margin:0 0 24px;font-size:22px}
  input{width:100%;padding:14px;border:1px solid #444;border-radius:8px;background:#1e1e1e;color:#fff;font-size:16px;box-sizing:border-box;margin-bottom:16px}
  button{width:100%;padding:14px;border:none;border-radius:8px;background:#0e639c;color:#fff;font-size:16px;cursor:pointer}
  button:active{background:#1177bb}
</style></head><body>
<div class="box"><h1>VibeCoding</h1>
<form method="POST" action="/vibe-login">
<input type="password" name="password" placeholder="Password" autofocus>
<button type="submit">Enter</button>
</form></div></body></html>`);
}

// ─── Session picker ──────────────────────────────────────────────────────────
function scanForProjects(rootDirs, depth) {
  const projects = [];
  function scan(dir, d) {
    if (d < 0) return;
    try {
      const entries = fs.readdirSync(dir, { withFileTypes: true });
      const markers = ['.git', '.vscode', 'package.json', '*.sln', 'Cargo.toml', 'go.mod', 'requirements.txt', 'pom.xml'];
      const hasMarker = entries.some(e => {
        if (e.name === '.git' || e.name === '.vscode') return e.isDirectory();
        return ['package.json', 'Cargo.toml', 'go.mod', 'requirements.txt', 'pom.xml'].includes(e.name)
          || e.name.endsWith('.sln');
      });
      if (hasMarker) {
        projects.push(dir);
      }
      if (d > 0) {
        for (const e of entries) {
          if (!e.isDirectory()) continue;
          if (e.name.startsWith('.') || e.name === 'node_modules' || e.name === '__pycache__') continue;
          scan(path.join(dir, e.name), d - 1);
        }
      }
    } catch {}
  }
  for (const r of rootDirs) { if (fs.existsSync(r)) scan(r, depth); }
  return projects;
}

const SCAN_ROOTS = [
  path.join(process.env.USERPROFILE || 'C:\\Users\\ghcpdev', 'Documents'),
  path.join(process.env.USERPROFILE || 'C:\\Users\\ghcpdev', 'source'),
  path.join(process.env.USERPROFILE || 'C:\\Users\\ghcpdev', 'repos'),
  path.join(process.env.USERPROFILE || 'C:\\Users\\ghcpdev', 'projects'),
  path.join(process.env.USERPROFILE || 'C:\\Users\\ghcpdev', 'Desktop'),
];

function showSessionPicker(res) {
  // Merge tracked workspaces with scanned projects
  const tracked = workspaces.slice().sort((a, b) => b.lastAccess - a.lastAccess);
  const trackedPaths = new Set(tracked.map(w => w.folder.toLowerCase()));

  const scanned = scanForProjects(SCAN_ROOTS, 2)
    .filter(p => !trackedPaths.has(p.toLowerCase()))
    .map(p => ({ folder: p, label: path.basename(p), lastAccess: 0 }));

  const { sessions: activeSessions, totalWs, unassociated } = getActiveSessionFolders();
  const processCount = getExtHostProcessCount();
  const activeFolderSet = new Set(activeSessions.map(s => s.folder.toLowerCase()));

  const escHtml = s => s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  const ago = ts => {
    if (!ts) return 'discovered';
    const d = Date.now() - ts;
    const mins = Math.floor(d / 60000);
    if (mins < 1) return 'just now';
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return `${hrs}h ago`;
    const days = Math.floor(hrs / 24);
    return `${days}d ago`;
  };

  let recentHtml = '';
  const recentNonActive = tracked.filter(w => !activeFolderSet.has(w.folder.toLowerCase()));
  if (recentNonActive.length > 0) {
    recentHtml = '<h2>Recent Sessions</h2><div class="list">';
    for (const w of recentNonActive) {
      const urlFolder = toFolderUri(w.folder);
      recentHtml += `<a class="item" href="/?folder=${encodeURIComponent(urlFolder)}">
        <span class="icon">&#128193;</span>
        <span class="info"><span class="label">${escHtml(w.label)}</span><span class="path">${escHtml(w.folder)}</span></span>
        <span class="time">${ago(w.lastAccess)}</span>
        <span class="remove" title="Remove" onclick="event.preventDefault();event.stopPropagation();remove('${escHtml(w.folder.replace(/\\/g,'\\\\'))}')">&times;</span>
      </a>`;
    }
    recentHtml += '</div>';
  }

  let discoveredHtml = '';
  if (scanned.length > 0) {
    discoveredHtml = '<h2>Discovered Projects</h2><div class="list">';
    for (const w of scanned) {
      const urlFolder = toFolderUri(w.folder);
      discoveredHtml += `<a class="item" href="/?folder=${encodeURIComponent(urlFolder)}">
        <span class="icon">&#128269;</span>
        <span class="info"><span class="label">${escHtml(w.label)}</span><span class="path">${escHtml(w.folder)}</span></span>
      </a>`;
    }
    discoveredHtml += '</div>';
  }

  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end(`<!DOCTYPE html>
<html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>VibeCoding - Sessions</title>
<style>
  *{box-sizing:border-box}
  body{background:#1e1e1e;color:#ccc;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:0;padding:20px;min-height:100vh}
  .container{max-width:680px;margin:0 auto}
  .header{display:flex;align-items:center;justify-content:space-between;margin-bottom:24px}
  h1{color:#3794ff;margin:0;font-size:24px}
  h2{color:#888;font-size:13px;text-transform:uppercase;letter-spacing:1px;margin:24px 0 8px;padding:0}
  .list{display:flex;flex-direction:column;gap:2px}
  .item{display:flex;align-items:center;gap:12px;padding:12px 16px;background:#252526;border-radius:8px;text-decoration:none;color:#ccc;transition:background .15s}
  .item:hover{background:#2a2d2e}
  .icon{font-size:24px;flex-shrink:0;width:32px;text-align:center}
  .info{flex:1;min-width:0}
  .label{display:block;color:#fff;font-size:15px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .path{display:block;color:#888;font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .time{color:#666;font-size:12px;flex-shrink:0}
  .remove{color:#666;font-size:20px;padding:4px 8px;cursor:pointer;flex-shrink:0;border-radius:4px}
  .remove:hover{color:#f44;background:#333}
  .actions{display:flex;gap:8px;margin-top:24px}
  .btn{padding:12px 20px;border:1px solid #444;border-radius:8px;background:#252526;color:#ccc;font-size:14px;cursor:pointer;text-decoration:none;text-align:center;flex:1;transition:background .15s}
  .btn:hover{background:#333}
  .btn-primary{background:#0e639c;border-color:#0e639c;color:#fff}
  .btn-primary:hover{background:#1177bb}
  .manual{margin-top:16px;display:flex;gap:8px}
  .manual input{flex:1;padding:12px;border:1px solid #444;border-radius:8px;background:#1e1e1e;color:#fff;font-size:14px}
  .empty{color:#666;text-align:center;padding:32px;font-size:14px}
  .status{display:flex;align-items:center;gap:8px;padding:8px 16px;background:#252526;border-radius:8px;margin-bottom:16px;font-size:13px}
  .dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
  .dot-active{background:#4caf50}
  .dot-idle{background:#666}
  .badge{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600;margin-left:8px}
  .badge-active{background:#1b5e20;color:#4caf50}
  .item-active{border-left:3px solid #4caf50}
</style></head><body>
<div class="container">
  <div class="header">
    <h1>&#9889; VibeCoding</h1>
    <a class="btn" href="/" style="flex:0">Empty Editor</a>
  </div>
  <div class="status">
    <span class="dot ${activeSessions.length > 0 || processCount > 0 || totalWs > 0 ? 'dot-active' : 'dot-idle'}"></span>
    ${activeSessions.length > 0 ? `<span>${activeSessions.length} active session${activeSessions.length !== 1 ? 's' : ''}</span>` : processCount > 0 ? `<span>${processCount} active session${processCount !== 1 ? 's' : ''}</span>` : totalWs > 0 ? `<span>${totalWs} connection${totalWs !== 1 ? 's' : ''} (reload tabs to track)</span>` : '<span style="color:#666">No active sessions</span>'}
  </div>
  ${activeSessions.length > 0 ? '<h2>Active Sessions</h2><div class="list">' + activeSessions.map(s => {
    const urlFolder = toFolderUri(s.folder);
    return `<a class="item item-active" href="/?folder=${encodeURIComponent(urlFolder)}"><span class="icon" style="color:#4caf50">&#9679;</span><span class="info"><span class="label">${escHtml(s.label)}<span class="badge badge-active">${s.connections} conn</span></span><span class="path">${escHtml(s.folder)}</span></span><span class="time">${ago(s.since)}</span></a>`;
  }).join('') + '</div>' : ''}
  ${recentHtml}
  ${discoveredHtml}
  ${tracked.length === 0 && scanned.length === 0 ? '<div class="empty">No sessions yet. Open a folder to get started.</div>' : ''}
  <form class="manual" onsubmit="if(this.f.value){var p=this.f.value.replace(/\\\\/g,'/');if(/^[A-Za-z]:/.test(p))p='/'+p;location.href='/?folder='+encodeURIComponent(p);}return false">
    <input name="f" placeholder="Enter folder path (e.g. C:\\Users\\ghcpdev\\myproject)">
    <button type="submit" class="btn btn-primary" style="flex:0;white-space:nowrap">Open Folder</button>
  </form>
</div>
<script>
function remove(folder) {
  fetch('/vibe-workspaces/remove', {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({folder})
  }).then(() => location.reload());
}
</script>
</body></html>`);
}

function handleLogin(req, res) {
  let body = '';
  req.on('data', c => { body += c; if (body.length > 1e4) req.destroy(); });
  req.on('end', () => {
    const pw = new URLSearchParams(body).get('password') || '';
    if (pw === VIBE_PASSWORD) {
      const token = crypto.randomBytes(32).toString('hex');
      sessions.add(token);
      saveSessions();
      res.writeHead(302, {
        'Set-Cookie': `vibe_session=${token}; Path=/; HttpOnly; SameSite=Strict; Secure; Max-Age=${SESSION_MAX_AGE}`,
        'Location': '/vibe-sessions'
      });
    } else {
      res.writeHead(302, { 'Location': '/' });
    }
    res.end();
  });
}

function handleWorkspaceRemove(req, res) {
  let body = '';
  req.on('data', c => { body += c; if (body.length > 1e4) req.destroy(); });
  req.on('end', () => {
    try {
      const { folder } = JSON.parse(body);
      if (folder) removeWorkspace(folder);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end('{"ok":true}');
    } catch {
      res.writeHead(400);
      res.end('Bad request');
    }
  });
}

// ─── Proxy ───────────────────────────────────────────────────────────────────
function proxyRequest(req, res) {
  const opts = {
    ...backendOpts(req.headers),
    path: req.url,
    method: req.method,
  };

  // Intercept vsda.js to inject AMD wrapper (the IIFE build lacks define())
  const urlPath = req.url.split('?')[0];
  const isVsda = urlPath.endsWith('/node_modules/vsda/rust/web/vsda.js');

  // Detect HTML responses that need remoteAuthority rewriting
  const isHtml = urlPath === '/' || urlPath === '';

  const proxyReq = http.request(opts, (proxyRes) => {
    const ct = (proxyRes.headers['content-type'] || '');

    if (isVsda && proxyRes.statusCode === 200) {
      const chunks = [];
      proxyRes.on('data', (c) => chunks.push(c));
      proxyRes.on('end', () => {
        let body = Buffer.concat(chunks).toString('utf8');
        // Append AMD define wrapper if missing
        if (!body.includes('define(')) {
          body += '\nif(typeof define==="function"&&define.amd){define([],function(){return vsda_web;});}\n';
        }
        const hdrs = { ...proxyRes.headers };
        hdrs['content-length'] = Buffer.byteLength(body);
        hdrs['cache-control'] = 'no-cache';
        res.writeHead(200, hdrs);
        res.end(body);
      });
    } else if (isHtml && ct.includes('text/html') && proxyRes.statusCode === 200) {
      // Rewrite remoteAuthority and resource URLs so the workbench connects
      // through the proxy host instead of the internal backend address.
      const chunks = [];
      proxyRes.on('data', (c) => chunks.push(c));
      proxyRes.on('end', () => {
        let body = Buffer.concat(chunks).toString('utf8');
        const backendAddr = `127.0.0.1:${CODESERVER_PORT}`;
        const proxyHost = req.headers.host || `${VIBE_HOST}:${VIBE_PORT}`;
        body = body.split(`http://${backendAddr}`).join(`https://${proxyHost}`);
        body = body.split(backendAddr).join(proxyHost);
        const hdrs = { ...proxyRes.headers };
        hdrs['content-length'] = Buffer.byteLength(body);
        res.writeHead(200, hdrs);
        res.end(body);
      });
    } else {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    }
  });

  proxyReq.on('error', (err) => {
    console.error('[proxy]', err.message);
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'text/plain' });
      res.end('VS Code backend unavailable');
    }
  });

  req.pipe(proxyReq);
}

// ─── WebSocket upgrade ───────────────────────────────────────────────────────
const _wss = new WebSocket.Server({ noServer: true });

function handleUpgrade(req, socket, head) {
  if (VIBE_PASSWORD && !getSession(req)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }

  // Accept the browser-side WebSocket via the ws library
  _wss.handleUpgrade(req, socket, head, (clientWs) => {
    // Open a WebSocket connection to the backend
    const backendUrl = `ws://127.0.0.1:${CODESERVER_PORT}${req.url}`;
    const backendWs = new WebSocket(backendUrl, {
      perMessageDeflate: false,
      headers: { host: 'localhost' },
    });

    let clientDead = false;
    let backendDead = false;

    // Once backend is open, relay messages in both directions
    backendWs.on('open', () => {
      console.log(`[ws] backend connected`);
    });

    backendWs.on('message', (data, isBinary) => {
      if (!clientDead && clientWs.readyState === WebSocket.OPEN) {
        clientWs.send(data, { binary: isBinary });
      }
    });

    clientWs.on('message', (data, isBinary) => {
      if (!backendDead && backendWs.readyState === WebSocket.OPEN) {
        backendWs.send(data, { binary: isBinary });
      }
    });

    const cleanup = (tag) => {
      console.log(`[ws] ${tag} closed`);
      if (!clientDead) { clientDead = true; clientWs.close(); }
      if (!backendDead) { backendDead = true; backendWs.close(); }
      _wsConns.delete(connId);
    };

    clientWs.on('close', () => cleanup('client'));
    backendWs.on('close', () => cleanup('backend'));
    clientWs.on('error', (e) => { console.error('[ws] client error', e.message); cleanup('client-err'); });
    backendWs.on('error', (e) => { console.error('[ws] backend error', e.message); cleanup('backend-err'); });

    // Track this connection
    const connId = crypto.randomBytes(4).toString('hex');
    const connFolder = (_lastLoadedFolder && (Date.now() - _lastLoadedAt) < 120000) ? _lastLoadedFolder : null;
    _wsConns.set(connId, { folder: connFolder, openedAt: Date.now() });
    if (connFolder) console.log(`[ws] tracking connection ${connId} for ${connFolder}`);
  });
}

// ─── Request handler ─────────────────────────────────────────────────────────
function handler(req, res) {
  const parsedUrl = new URL(req.url, `https://${req.headers.host || 'localhost'}`);

  if (VIBE_PASSWORD) {
    if (req.method === 'POST' && parsedUrl.pathname === '/vibe-login') {
      handleLogin(req, res);
      return;
    }
    if (req.method === 'POST' && parsedUrl.pathname === '/vibe-workspaces/remove') {
      if (!getSession(req)) { res.writeHead(401); res.end(); return; }
      handleWorkspaceRemove(req, res);
      return;
    }
    if (!getSession(req)) {
      showLogin(res);
      return;
    }
    if (parsedUrl.pathname === '/vibe-sessions') {
      showSessionPicker(res);
      return;
    }
  }

  // Normalize folder URI: redirect ?folder=C:/... to ?folder=/C:/... so the
  // remote file-system provider registers correctly (prevents ENOPRO).
  const folder = parsedUrl.searchParams.get('folder');
  if (folder && parsedUrl.pathname === '/') {
    const canonical = toFolderUri(folder);
    if (canonical !== folder) {
      parsedUrl.searchParams.set('folder', canonical);
      res.writeHead(302, { 'Location': `${parsedUrl.pathname}?${parsedUrl.searchParams}` });
      res.end();
      return;
    }
    trackWorkspace(folder);
    _lastLoadedFolder = folder.replace(/\//g, '\\');
    _lastLoadedAt = Date.now();
  }

  proxyRequest(req, res);
}

// ─── Start ───────────────────────────────────────────────────────────────────
(function start() {
  let server;
  try {
    const certs = ensureCerts();
    server = https.createServer(certs, handler);
    console.log(`[VibeCoding] HTTPS on port ${VIBE_PORT}`);
  } catch (e) {
    console.warn('[VibeCoding] TLS failed, using HTTP:', e.message);
    server = http.createServer(handler);
  }

  server.on('upgrade', handleUpgrade);
  server.keepAliveTimeout = 120000;
  server.headersTimeout = 125000;
  server.timeout = 0;
  server.listen(VIBE_PORT, '0.0.0.0', () => {
    console.log(`[VibeCoding] Listening on https://${VIBE_HOST}:${VIBE_PORT}`);
    console.log(`[VibeCoding] Backend: localhost:${CODESERVER_PORT}`);
    if (VIBE_PASSWORD) console.log('[VibeCoding] Password auth enabled');
    if (VIBE_CERT && VIBE_KEY) console.log('[VibeCoding] ACME certificate renewal available');
  });
})();
