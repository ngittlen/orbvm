#!/usr/bin/env node
'use strict';
//
// OrbStack VM dashboard — a tiny zero-dependency control plane.
//
// Serves a web UI and a small JSON API that shells out to `orb`, `tailscale`,
// and the create-vm.sh / delete-vm.sh scripts one directory up. Bind is
// localhost only; expose it on your tailnet with `tailscale serve` (see
// start-dashboard.sh).
//
const http = require('http');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const ROOT = path.join(__dirname, '..');            // orbvm/ (where the scripts live)
const PUBLIC = path.join(__dirname, 'public');
const PORT = parseInt(process.env.PORT || '8099', 10);
const CREATE = path.join(ROOT, 'create-vm.sh');
const DELETE = path.join(ROOT, 'delete-vm.sh');
const NAME_RE = /^[a-z0-9][a-z0-9-]*$/;

// In-progress creates: name -> { status, log:[], child, startedAt, error, distro }
const creating = new Map();

// Per-VM resource sampler. OrbStack VMs share the host kernel, so /proc/meminfo
// and /proc/stat report HOST-wide totals (identical for every VM). But each VM
// has its own PID namespace, so we measure this VM's real footprint by summing
// its own processes: RSS for memory, and a short delta of per-process CPU jiffies
// for CPU%. `cpu` is normalized so 100 = one full core (may exceed 100).
const STATS_SCRIPT = `
rss=$(ps -e -o rss= 2>/dev/null | awk '{s+=$1} END{print int(s/1024)+0}')
procs=$(ps -e --no-headers 2>/dev/null | wc -l | tr -d ' ')
ncpu=$(nproc 2>/dev/null || echo 1)
mt=$(awk '/^MemTotal/{print int($2/1024)}' /proc/meminfo)
hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
rt(){ awk '{n=split($0,a,") "); split(a[2],b," "); T+=b[12]+b[13]} END{print T+0}' /proc/[0-9]*/stat 2>/dev/null; }
p1=$(rt); sleep 0.3; p2=$(rt)
cpu=$(awk -v d=$((p2-p1)) -v hz="$hz" 'BEGIN{v=(d/(0.3*hz))*100; if(v<0)v=0; printf "%d", v}')
printf '{"cpu":%s,"memUsedMb":%s,"memTotalMb":%s,"nproc":%s,"procs":%s}' "\${cpu:-0}" "\${rss:-0}" "\${mt:-0}" "\${ncpu:-1}" "\${procs:-0}"
`;

function run(cmd, args, { timeout = 8000 } = {}) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(cmd, args, { cwd: ROOT });
    } catch (e) {
      return resolve({ code: -1, out: '', err: String(e) });
    }
    let out = '', err = '';
    const timer = timeout ? setTimeout(() => child.kill('SIGKILL'), timeout) : null;
    child.stdout.on('data', d => (out += d));
    child.stderr.on('data', d => (err += d));
    child.on('error', e => { if (timer) clearTimeout(timer); resolve({ code: -1, out, err: String(e) }); });
    child.on('close', code => { if (timer) clearTimeout(timer); resolve({ code, out, err }); });
  });
}

async function getTailscale() {
  const r = await run('tailscale', ['status', '--json'], { timeout: 5000 });
  const map = {};
  if (r.code === 0) {
    try {
      const d = JSON.parse(r.out);
      for (const p of Object.values(d.Peer || {})) {
        const h = String(p.HostName || '').toLowerCase();
        if (h) map[h] = { ip: (p.TailscaleIPs || [])[0] || null, online: !!p.Online };
      }
    } catch { /* ignore */ }
  }
  return map;
}

async function getStats(name) {
  const r = await run('orb', ['run', '-m', name, 'sh', '-c', STATS_SCRIPT], { timeout: 4000 });
  if (r.code !== 0) return null;
  try { return JSON.parse(r.out.trim()); } catch { return null; }
}

async function getMachines() {
  const r = await run('orb', ['list', '--format', 'json'], { timeout: 6000 });
  let list = [];
  if (r.code === 0) { try { list = JSON.parse(r.out) || []; } catch { /* ignore */ } }
  const ts = await getTailscale();

  const machines = await Promise.all(list.map(async (m) => {
    const key = String(m.name).toLowerCase();
    const running = m.state === 'running';
    const prov = creating.get(m.name);
    const entry = {
      id: m.id,
      name: m.name,
      state: m.state,
      status: running ? 'running' : m.state,
      distro: m.image && m.image.distro,
      version: m.image && m.image.version,
      arch: m.image && m.image.arch,
      os: m.os_release && m.os_release.pretty_name,
      username: m.config && m.config.default_username,
      tailscaleIP: (ts[key] || {}).ip || null,
      tailscaleOnline: (ts[key] || {}).online || false,
      cpu: null, memUsedMb: null, memTotalMb: null, nproc: null, procs: null,
      error: null,
    };
    if (prov && prov.status === 'provisioning') entry.status = 'provisioning';
    if (prov && prov.status === 'error') { entry.status = 'error'; entry.error = prov.error; }
    if (running) {
      const s = await getStats(m.name);
      if (s) {
        entry.cpu = Math.max(0, s.cpu);
        entry.memUsedMb = s.memUsedMb;
        entry.memTotalMb = s.memTotalMb;
        entry.nproc = s.nproc;
        entry.procs = s.procs;
      }
    }
    return entry;
  }));

  // Surface creates that haven't appeared in `orb list` yet (very early, or failed).
  const known = new Set(list.map(m => m.name));
  for (const [name, prov] of creating) {
    if (!known.has(name)) {
      machines.push({
        id: 'pending-' + name, name, state: prov.status, status: prov.status,
        distro: prov.distro || null, tailscaleIP: null, tailscaleOnline: false,
        cpu: null, memUsedMb: null, memTotalMb: null, nproc: null, error: prov.error || null,
      });
    }
  }
  machines.sort((a, b) => a.name.localeCompare(b.name));
  return machines;
}

function startCreate(name, distro) {
  const args = [CREATE, name];
  if (distro) args.push(distro);
  const rec = { status: 'provisioning', log: [], child: null, startedAt: Date.now(), error: null, distro };
  creating.set(name, rec);
  const child = spawn('bash', args, { cwd: ROOT });
  rec.child = child;
  const push = d => { rec.log.push(d.toString()); if (rec.log.length > 800) rec.log.shift(); };
  child.stdout.on('data', push);
  child.stderr.on('data', push);
  child.on('error', e => { rec.status = 'error'; rec.error = String(e); });
  child.on('close', code => {
    rec.child = null;
    if (code === 0) creating.delete(name);           // success: let `orb list` own it
    else { rec.status = 'error'; rec.error = 'create-vm.sh exited with code ' + code; }
  });
}

// ---------------------------------------------------------------- HTTP layer

function send(res, code, body, type = 'application/json') {
  const data = type === 'application/json' ? JSON.stringify(body) : body;
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve) => {
    let b = '';
    req.on('data', d => (b += d));
    req.on('end', () => { try { resolve(b ? JSON.parse(b) : {}); } catch { resolve({}); } });
  });
}

const STATIC = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/index.html': ['index.html', 'text/html; charset=utf-8'],
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname;

  try {
    if (req.method === 'GET' && STATIC[p]) {
      const [file, type] = STATIC[p];
      return fs.readFile(path.join(PUBLIC, file), (e, buf) =>
        e ? send(res, 404, 'not found', 'text/plain') : send(res, 200, buf, type));
    }

    if (req.method === 'GET' && p === '/api/machines') {
      return send(res, 200, await getMachines());
    }

    if (req.method === 'POST' && p === '/api/machines') {
      const { name, distro } = await readBody(req);
      if (!name || !NAME_RE.test(name)) return send(res, 400, { error: 'invalid name (use lowercase letters, digits, dashes)' });
      if (distro && !/^[a-z0-9:.\-]+$/.test(distro)) return send(res, 400, { error: 'invalid distro' });
      if (creating.has(name)) return send(res, 409, { error: 'already provisioning' });
      const existing = await run('orb', ['list', '--format', 'json']);
      try { if ((JSON.parse(existing.out) || []).some(m => m.name === name)) return send(res, 409, { error: 'machine already exists' }); } catch { /* ignore */ }
      startCreate(name, distro);
      return send(res, 202, { ok: true, name });
    }

    const mLog = p.match(/^\/api\/machines\/([a-z0-9-]+)\/log$/);
    if (req.method === 'GET' && mLog) {
      const rec = creating.get(mLog[1]);
      return send(res, 200, rec ? { status: rec.status, log: rec.log.join(''), error: rec.error } : { status: 'none', log: '' });
    }

    // Power: stop (shut down) or start a machine. A name is always required —
    // `orb stop` with no argument would stop the entire OrbStack service.
    const mPower = p.match(/^\/api\/machines\/([a-z0-9-]+)\/(stop|start)$/);
    if (req.method === 'POST' && mPower) {
      const [, name, action] = mPower;
      const r = await run('orb', [action, name], { timeout: 60000 });
      if (r.code !== 0) return send(res, 500, { error: r.err || r.out || (action + ' failed') });
      return send(res, 200, { ok: true });
    }

    const mDel = p.match(/^\/api\/machines\/([a-z0-9-]+)$/);
    if (req.method === 'DELETE' && mDel) {
      const name = mDel[1];
      const rec = creating.get(name);
      if (rec && rec.child) rec.child.kill('SIGKILL');
      creating.delete(name);
      const r = await run('bash', [DELETE, name], { timeout: 90000 });
      if (r.code !== 0) return send(res, 500, { error: r.err || r.out || 'delete failed' });
      return send(res, 200, { ok: true });
    }

    send(res, 404, { error: 'not found' });
  } catch (e) {
    send(res, 500, { error: String(e) });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`OrbStack dashboard listening on http://127.0.0.1:${PORT}`);
});
