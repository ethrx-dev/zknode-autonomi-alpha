import { request as httpRequest } from 'http';
import { existsSync, writeFileSync } from 'fs';
import { execSync, spawn } from 'child_process';
import { hostname, networkInterfaces, totalmem, freemem, cpus, uptime, loadavg } from 'os';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import express from 'express';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 8080;
const WS_PORT = process.env.WS_PORT || 9200;
const DOCKER_SOCK = '/var/run/docker.sock';
let ZKCHAT_MESSAGES = [];

const app = express();
app.use(express.json());
app.use(express.static(join(__dirname, '..', 'public')));

function runShell(cmd, timeoutMs = 15000) {
  try {
    const out = execSync(cmd, { timeout: timeoutMs, encoding: 'utf8', maxBuffer: 1024 * 1024, shell: '/bin/sh' });
    return { ok: true, data: out.trim() };
  } catch (e) {
    const stderr = e.stderr ? e.stderr.toString().trim() : '';
    return { ok: false, error: e.message, stderr };
  }
}

function dockerApi(path) {
  return new Promise((resolve) => {
    if (!existsSync(DOCKER_SOCK)) return resolve({ error: 'docker socket not found' });
    const req = httpRequest({ socketPath: DOCKER_SOCK, path, method: 'GET' }, (res) => {
      let body = '';
      res.on('data', c => body += c);
      res.on('end', () => {
        try { resolve(JSON.parse(body)); }
        catch { resolve({ error: 'parse error', raw: body }); }
      });
    });
    req.on('error', () => resolve({ error: 'docker api error' }));
    req.end();
  });
}

function fetchUrl(url, timeout = 5000) {
  return new Promise((resolve) => {
    const controller = new AbortController();
    const t = setTimeout(() => controller.abort(), timeout);
    fetch(url, { signal: controller.signal })
      .then(r => r.text().then(txt => {
        try { return JSON.parse(txt); }
        catch { return { raw: txt }; }
      }))
      .then(d => { clearTimeout(t); resolve(d); })
      .catch(e => { clearTimeout(t); resolve({ error: e.message }); });
  });
}

// ─── MCP Client for llm-wiki ─────────────────────────────────

let mcpSessionId = null;
let mcpSseReq = null;
let mcpReady = false;
const mcpPending = [];

function mcpHttp(method, path, headers, body, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    const opts = {
      hostname: '127.0.0.1', port: 18765, path, method,
      headers: { ...headers }
    };
    const req = httpRequest(opts, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => resolve({
        status: res.statusCode,
        headers: res.headers,
        body: data
      }));
    });
    req.on('error', reject);
    req.setTimeout(timeoutMs, () => { req.destroy(); reject(new Error('timeout')); });
    if (body) req.write(body);
    req.end();
  });
}

function parseSseJson(sseBody) {
  const dataLines = [];
  for (const line of sseBody.split('\n')) {
    if (line.startsWith('data: ')) {
      const payload = line.slice(6).trim();
      if (payload) dataLines.push(payload);
    }
  }
  for (const jsonStr of dataLines) {
    try {
      const parsed = JSON.parse(jsonStr);
      if (parsed.jsonrpc === '2.0') return parsed;
    } catch {}
  }
  try { return JSON.parse(sseBody); }
  catch { return null; }
}

async function mcpInitialize() {
  const msg = JSON.stringify({
    jsonrpc: '2.0', id: 1, method: 'initialize',
    params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'zknode-dashboard', version: '1.0' } }
  });
  const resp = await mcpHttp('POST', '/mcp', {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream'
  }, msg);
  if (!resp.headers['mcp-session-id']) {
    throw new Error('No mcp-session-id in response');
  }
  mcpSessionId = resp.headers['mcp-session-id'];
}

function mcpOpenSse() {
  if (mcpSseReq) {
    mcpSseReq.destroy();
    mcpSseReq = null;
  }
  const opts = {
    hostname: '127.0.0.1', port: 18765, path: '/mcp', method: 'GET',
    headers: { 'Accept': 'text/event-stream', 'mcp-session-id': mcpSessionId }
  };
  const req = httpRequest(opts, (res) => {
    res.on('data', () => {});
    res.on('end', () => {
      mcpSseReq = null;
      mcpReady = false;
      setTimeout(connectMcp, 1000);
    });
    res.on('error', () => {
      mcpSseReq = null;
      mcpReady = false;
      setTimeout(connectMcp, 2000);
    });
  });
  req.on('error', () => {
    mcpSseReq = null;
    mcpReady = false;
    setTimeout(connectMcp, 2000);
  });
  req.end();
  mcpSseReq = req;
}

async function connectMcp() {
  try {
    await mcpInitialize();
    mcpOpenSse();
    mcpReady = true;
    console.log('MCP session established:', mcpSessionId?.slice(0, 8) + '...');
  } catch (e) {
    console.log('MCP init failed:', e.message, '- retrying in 5s');
    mcpReady = false;
    setTimeout(connectMcp, 5000);
  }
}

async function mcpCall(method, params = {}) {
  if (!mcpReady) {
    return { error: 'MCP not ready' };
  }
  const id = Date.now() + Math.floor(Math.random() * 1000);
  const msg = JSON.stringify({ jsonrpc: '2.0', id, method, params });
  try {
    const resp = await mcpHttp('POST', '/mcp', {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      'mcp-session-id': mcpSessionId
    }, msg);
    if (resp.status === 400) {
      mcpReady = false;
      connectMcp();
      return { error: 'Session expired, reconnecting' };
    }
    if (resp.status !== 200) {
      return { error: `HTTP ${resp.status}`, raw: resp.body };
    }
    const parsed = parseSseJson(resp.body);
    if (!parsed) return { error: 'failed to parse response', raw: resp.body };
    if (parsed.error) return { error: parsed.error.message || JSON.stringify(parsed.error) };
    if (parsed.result && parsed.result.content) {
      const textContent = parsed.result.content.find(c => c.type === 'text');
      if (textContent) {
        try { return JSON.parse(textContent.text); }
        catch { return textContent.text; }
      }
      return parsed.result.content;
    }
    return parsed.result;
  } catch (e) {
    return { error: e.message };
  }
}

// ─── SYSTEM DATA FUNCTIONS ────────────────────────────────────

function getSystemStats() {
  const mem = { total: totalmem(), free: freemem(), used: totalmem() - freemem() };
  const disk = (() => {
    try {
      const out = execSync('df -B1 / /mnt/autonomi 2>/dev/null || df -B1 /', { timeout: 3000, encoding: 'utf8' });
      return out.trim().split('\n').slice(1).map(l => {
        const [, fs, sz, u, av, use, mp] = l.match(/(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+(\S+)/) || [];
        return fs ? { filesystem: fs, size: +sz, used: +u, available: +av, usePercent: +use, mount: mp } : null;
      }).filter(Boolean);
    } catch { return []; }
  })();
  return {
    hostname: hostname(), platform: process.platform, arch: process.arch,
    uptime: uptime(), loadavg: loadavg(), cpuCount: cpus().length, memory: mem,
    disks: disk,
    network: Object.entries(networkInterfaces()).flatMap(([name, addrs]) =>
      addrs.filter(a => a.family === 'IPv4').map(a => ({ name, address: a.address }))
    )
  };
}

async function getContainers() {
  const data = await dockerApi('/containers/json?all=true');
  if (data.error) return data;
  if (!Array.isArray(data)) return { error: 'unexpected response' };
  return data.map(c => ({
    id: c.Id?.slice(0, 12), name: c.Names?.[0]?.replace(/^\//, ''),
    image: c.Image, state: c.State, status: c.Status,
    ports: c.Ports?.map(p => `${p.PublicPort || ''}:${p.PrivatePort}/${p.Type}`) || [],
    created: c.Created, networkMode: c.HostConfig?.NetworkMode
  }));
}

async function getMixnetStatus() {
  const auths = await Promise.all(
    ['127.0.0.1:30001', '127.0.0.1:30002', '127.0.0.1:30003'].map(h =>
      fetchUrl(`http://${h}/status`).then(d => ({ host: h, data: d }))
    )
  );
  return { authorities: auths };
}

async function getWalletshieldStatus() {
  const ws = await fetchUrl(`http://127.0.0.1:${WS_PORT}/health`);
  return ws && !ws.error ? { connected: true } : { connected: false };
}

// ─── WIKI ENDPOINTS (via MCP) ────────────────────────────────

app.post('/api/wiki/search', async (req, res) => {
  const { query, topK } = req.body || {};
  if (!query) return res.json({ error: 'query required', results: [] });
  const result = await mcpCall('tools/call', {
    name: 'wiki_search',
    arguments: { query, top_k: topK || 10 }
  });
  res.json(result);
});

app.get('/api/wiki/list', async (req, res) => {
  const page = parseInt(req.query.page) || 1;
  const pageSize = parseInt(req.query.pageSize) || 20;
  const type = req.query.type || '';
  const status = req.query.status || '';
  const args = { page, page_size: pageSize };
  if (type) args.type = type;
  if (status) args.status = status;
  const result = await mcpCall('tools/call', {
    name: 'wiki_list',
    arguments: args
  });
  res.json(result);
});

app.get('/api/wiki/page/:slug', async (req, res) => {
  const { wiki } = req.query;
  const args = { uri: req.params.slug };
  if (wiki) args.wiki = wiki;
  const result = await mcpCall('tools/call', {
    name: 'wiki_content_read',
    arguments: args
  });
  res.json(result);
});

app.get('/api/wiki/stats', async (req, res) => {
  const result = await mcpCall('tools/call', { name: 'wiki_stats', arguments: {} });
  res.json(result || {});
});

app.get('/api/wiki/suggest/:slug', async (req, res) => {
  const result = await mcpCall('tools/call', {
    name: 'wiki_suggest',
    arguments: { slug: req.params.slug, limit: 10 }
  });
  res.json(result);
});

// ─── ZKCHAT ENDPOINTS ─────────────────────────────────────────

const ZKCHAT_BIN = 'docker exec zkchat zkchat';
const ZKCONF = '/etc/zkchat/thinclient.toml';
const POLL_TIMEOUT = 15000;

function zkchatCmd(args, timeout = 10000) {
  return runShell(`${ZKCHAT_BIN} ${args} 2>&1`, timeout);
}

// Direct messaging
app.post('/api/chat/send', (req, res) => {
  const { recipient, message } = req.body || {};
  if (!recipient || !message) return res.status(400).json({ error: 'recipient and message required' });
  const r = zkchatCmd(`send ${ZKCONF} ${recipient} "${message}"`);
  res.json(r.ok ? { sent: true, output: r.data } : { sent: false, error: r.error });
});

app.get('/api/chat/poll', (req, res) => {
  const r = zkchatCmd(`poll ${ZKCONF}`, POLL_TIMEOUT);
  if (!r.ok) return res.json({ messages: [], error: r.error });
  const raw = r.data.split('\n').filter(l => l.trim());
  const messages = raw.map(l => {
    const m = l.match(/^\[(.+?)\]\s+(.+?):\s(.+)/);
    return m ? { timestamp: m[1], sender: m[2], text: m[3] } : { raw: l };
  });
  if (messages.length) ZKCHAT_MESSAGES.push(...messages);
  res.json({ messages, history: ZKCHAT_MESSAGES.slice(-100) });
});

app.get('/api/chat/messages', (req, res) => {
  res.json({ messages: ZKCHAT_MESSAGES.slice(-100) });
});

// Group management
app.get('/api/chat/groups', (req, res) => {
  const r = zkchatCmd(`group list ${ZKCONF}`);
  if (!r.ok) return res.json({ groups: [], error: r.error });
  const lines = r.data.split('\n').filter(l => l.trim());
  const groups = [];
  for (const line of lines) {
    const parts = line.split(/\s+/);
    if (parts.length >= 3) {
      groups.push({ id: parts[0], name: parts[1], members: parseInt(parts[2]) || 0 });
    }
  }
  res.json({ groups });
});

app.post('/api/chat/groups/create', (req, res) => {
  const { name, members } = req.body || {};
  if (!name) return res.status(400).json({ error: 'group name required' });
  const membersStr = members && members.length ? members.join(' ') : '';
  const r = zkchatCmd(`group create ${ZKCONF} "${name}" ${membersStr}`);
  res.json(r.ok ? { created: true, output: r.data } : { error: r.error, stderr: r.stderr });
});

app.post('/api/chat/groups/send', (req, res) => {
  const { group_id, message } = req.body || {};
  if (!group_id || !message) return res.status(400).json({ error: 'group_id and message required' });
  const r = zkchatCmd(`group send ${ZKCONF} ${group_id} "${message}"`);
  res.json(r.ok ? { sent: true, output: r.data } : { sent: false, error: r.error });
});

app.get('/api/chat/groups/poll', (req, res) => {
  const groupId = req.query.group_id || '';
  const cmd = `group poll ${ZKCONF}${groupId ? ' ' + groupId : ''}`;
  const r = zkchatCmd(cmd, POLL_TIMEOUT);
  if (!r.ok) return res.json({ messages: [], error: r.error });
  const lines = r.data.split('\n').filter(l => l.trim());
  const messages = lines.map(l => {
    const m = l.match(/^\[(.+?)\]\s+(.+?):\s(.+)/);
    return m ? { timestamp: m[1], sender: m[2], text: m[3], group: groupId || 'all' } : { raw: l };
  });
  res.json({ messages });
});

app.post('/api/chat/groups/invite', (req, res) => {
  const { group_id, members } = req.body || {};
  if (!group_id || !members || !members.length) return res.status(400).json({ error: 'group_id and members required' });
  const r = zkchatCmd(`group invite ${ZKCONF} ${group_id} ${members.join(' ')}`);
  res.json(r.ok ? { invited: true, output: r.data } : { error: r.error });
});

app.post('/api/chat/groups/leave', (req, res) => {
  const { group_id } = req.body || {};
  if (!group_id) return res.status(400).json({ error: 'group_id required' });
  const r = zkchatCmd(`group leave ${ZKCONF} ${group_id}`);
  res.json(r.ok ? { left: true, output: r.data } : { error: r.error });
});

// ─── MESH ENDPOINTS ───────────────────────────────────────────

app.get('/api/mesh/status', (req, res) => {
  const rnsd = runShell('docker exec reticulum bash -c "rnpath . 2>&1 || rnstatus 2>&1 || echo daemon running"', 10000);
  const ident = runShell('docker exec reticulum cat /root/.reticulum/identity 2>&1', 5000);
  const nomad = runShell('systemctl --user is-active nomadnet 2>/dev/null || echo inactive');
  res.json({
    rnsd: rnsd.ok ? rnsd.data.split('\n').slice(0, 15) : rnsd.stderr || rnsd.error,
    identity: ident.ok ? ident.data.slice(0, 64) + '...' : null,
    nomadnet: nomad.data,
    container: runShell('docker inspect reticulum --format "{{.State.Status}}" 2>&1').data
  });
});

app.get('/api/mesh/nomadnet', (req, res) => {
  const pages = runShell('ls /home/zero-tech/nomadnet-new/pages/ 2>/dev/null');
  const config = runShell('cat /home/zero-tech/nomadnet-new/config 2>/dev/null');
  const log = runShell('tail -10 /home/zero-tech/nomadnet-new/logfile 2>/dev/null');
  res.json({
    pages: pages.ok ? pages.data.split('\n').filter(Boolean) : [],
    config: config.ok ? config.data : null,
    recentLog: log.ok ? log.data.split('\n') : []
  });
});

// ─── SYSTEM ENDPOINTS ─────────────────────────────────────────

app.get('/api/system', (req, res) => res.json(getSystemStats()));
app.get('/api/containers', async (req, res) => res.json(await getContainers()));
app.get('/api/mixnet', async (req, res) => res.json(await getMixnetStatus()));
app.get('/api/walletshield', async (req, res) => res.json(await getWalletshieldStatus()));
app.get('/api/zkchat', (req, res) => {
  const s = runShell('docker logs zkchat --tail 2 2>&1');
  res.json({ running: s.ok && s.data.length > 0, log: s.data });
});
app.get('/api/reticulum', (req, res) => {
  const r = runShell('docker exec reticulum rnstatus 2>&1');
  res.json({ rnsd: r.ok ? r.data : r.stderr || r.error });
});
app.get('/api/zymbit', (req, res) => {
  const z = runShell('systemctl is-active zkifc 2>/dev/null || echo inactive');
  res.json({ zkifc: z.data, devZymkey: existsSync('/dev/zymkey') });
});
app.get('/api/llm-wiki', async (req, res) => {
  const s = runShell('docker ps --filter name=llm --format {{.Names}} 2>/dev/null');
  res.json({
    container: s.data || null,
    mcpOk: mcpReady,
    sessionId: mcpSessionId ? mcpSessionId.slice(0, 8) + '...' : null
  });
});
app.get('/api/prover', async (req, res) => {
  const p = await fetchUrl('http://127.0.0.1:8700/health');
  res.json(p && !p.error ? { running: true } : { running: false });
});
app.get('/api/ant', async (req, res) => {
  const a = await fetchUrl('http://127.0.0.1:8600/status');
  res.json(a && !a.error ? { running: true } : { running: false });
});
app.get('/api/services', async (req, res) => {
  const antP = fetchUrl('http://127.0.0.1:8600/status');
  const provP = fetchUrl('http://127.0.0.1:8700/health');
  const [containers, mixnet, walletshield, reticulum, ant, prover, system] =
    await Promise.all([
      getContainers(), getMixnetStatus(), getWalletshieldStatus(),
      (async () => { const r = runShell('docker exec reticulum rnstatus 2>&1'); return { rnsd: r.ok ? r.data : r.error }; })(),
      antP, provP, Promise.resolve(getSystemStats())
    ]);
  res.json({ system, containers, mixnet, walletshield, reticulum,
    ant: ant && !ant.error ? { running: true } : { running: false },
    prover: prover && !prover.error ? { running: true } : { running: false }
  });
});

app.get('*', (req, res) => {
  res.sendFile(join(__dirname, '..', 'public', 'index.html'));
});

// Start MCP connection
connectMcp();

setInterval(() => {
  if (!mcpReady && !mcpSessionId) {
    connectMcp();
  }
}, 30000);

app.listen(PORT, '0.0.0.0', () => {
  console.log(`ZKNode Dashboard running on http://0.0.0.0:${PORT}`);
});
