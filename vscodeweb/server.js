// ─── VibeCoding Auth Proxy ───────────────────────────────────────────────────
// HTTPS reverse proxy to VS Code serve-web with a password login gate.
// Run: node server.js
// Env: CODESERVER_PORT (default 8080), VIBE_PORT (default 9443), VIBE_PASSWORD

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const CODESERVER_PORT = parseInt(process.env.CODESERVER_PORT || '8080', 10);
const VIBE_PORT = parseInt(process.env.VIBE_PORT || '9443', 10);
const VIBE_PASSWORD = process.env.VIBE_PASSWORD || '';
const CERT_DIR = path.join(__dirname, 'certs');

// ─── Self-signed cert generation ─────────────────────────────────────────────
function ensureCerts() {
  if (!fs.existsSync(CERT_DIR)) fs.mkdirSync(CERT_DIR, { recursive: true });
  const keyPath = path.join(CERT_DIR, 'key.pem');
  const certPath = path.join(CERT_DIR, 'cert.pem');
  if (fs.existsSync(keyPath) && fs.existsSync(certPath)) {
    return { key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath) };
  }
  const { execSync } = require('child_process');
  execSync(
    `openssl req -x509 -newkey rsa:2048 -keyout "${keyPath}" -out "${certPath}" -days 365 -nodes -subj "/CN=vibecoding"`,
    { stdio: 'pipe' }
  );
  return { key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath) };
}

// ─── Session auth ────────────────────────────────────────────────────────────
const sessions = new Set();

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

function handleLogin(req, res) {
  let body = '';
  req.on('data', c => { body += c; if (body.length > 1e4) req.destroy(); });
  req.on('end', () => {
    const pw = new URLSearchParams(body).get('password') || '';
    if (pw === VIBE_PASSWORD) {
      const token = crypto.randomBytes(32).toString('hex');
      sessions.add(token);
      res.writeHead(302, {
        'Set-Cookie': `vibe_session=${token}; Path=/; HttpOnly; SameSite=Strict; Secure`,
        'Location': '/'
      });
    } else {
      res.writeHead(302, { 'Location': '/' });
    }
    res.end();
  });
}

// ─── Proxy ───────────────────────────────────────────────────────────────────
function proxyRequest(req, res) {
  const options = {
    hostname: '127.0.0.1',
    port: CODESERVER_PORT,
    path: req.url,
    method: req.method,
    headers: { ...req.headers },
  };

  const proxyReq = http.request(options, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res);
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
function handleUpgrade(req, socket, head) {
  if (VIBE_PASSWORD && !getSession(req)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }

  socket.setKeepAlive(true, 30000);
  socket.setNoDelay(true);
  socket.setTimeout(0);

  const options = {
    hostname: '127.0.0.1',
    port: CODESERVER_PORT,
    path: req.url,
    method: 'GET',
    headers: { ...req.headers },
  };

  const proxyReq = http.request(options);
  proxyReq.on('upgrade', (proxyRes, proxySocket, proxyHead) => {
    proxySocket.setKeepAlive(true, 30000);
    proxySocket.setNoDelay(true);
    proxySocket.setTimeout(0);

    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
      Object.entries(proxyRes.headers).map(([k, v]) => `${k}: ${v}`).join('\r\n') +
      '\r\n\r\n'
    );
    if (proxyHead.length) proxySocket.unshift(proxyHead);
    if (head.length) socket.unshift(head);
    proxySocket.pipe(socket);
    socket.pipe(proxySocket);

    socket.on('error', () => proxySocket.destroy());
    proxySocket.on('error', () => socket.destroy());
    socket.on('close', () => proxySocket.destroy());
    proxySocket.on('close', () => socket.destroy());
  });

  proxyReq.on('error', () => socket.destroy());
  proxyReq.end();
}

// ─── Request handler ─────────────────────────────────────────────────────────
function handler(req, res) {
  if (VIBE_PASSWORD) {
    if (req.method === 'POST' && req.url === '/vibe-login') {
      handleLogin(req, res);
      return;
    }
    if (!getSession(req)) {
      showLogin(res);
      return;
    }
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
    console.log(`[VibeCoding] Listening on https://0.0.0.0:${VIBE_PORT}`);
    console.log(`[VibeCoding] Backend: localhost:${CODESERVER_PORT}`);
    if (VIBE_PASSWORD) console.log('[VibeCoding] Password auth enabled');
  });
})();
