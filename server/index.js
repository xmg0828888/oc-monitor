const http = require('http');
const fs = require('fs');
const path = require('path');
const Database = require('better-sqlite3');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 3800;
const DB_PATH = path.join(__dirname, '..', 'data', 'monitor.db');
const PUBLIC = path.join(__dirname, '..', 'public');

// Ensure data dir
fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });

const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');

// Schema
db.exec(`
CREATE TABLE IF NOT EXISTS nodes (
  id TEXT PRIMARY KEY,
  name TEXT,
  host TEXT,
  os TEXT,
  oc_version TEXT,
  role TEXT DEFAULT 'worker',
  providers TEXT DEFAULT '[]',
  cpu REAL DEFAULT 0, mem REAL DEFAULT 0, disk REAL DEFAULT 0, swap REAL DEFAULT 0,
  sessions INTEGER DEFAULT 0, gw_ok INTEGER DEFAULT 1, daemon_ok INTEGER DEFAULT 1,
  uptime INTEGER DEFAULT 0,
  tok_today INTEGER DEFAULT 0, tok_week INTEGER DEFAULT 0, tok_month INTEGER DEFAULT 0,
  last_seen INTEGER DEFAULT 0,
  created_at INTEGER DEFAULT (unixepoch())
);
CREATE TABLE IF NOT EXISTS requests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id TEXT, upstream TEXT, model TEXT, status INTEGER,
  input_tokens INTEGER, output_tokens INTEGER,
  ttft_ms INTEGER, total_ms INTEGER, success INTEGER,
  ts INTEGER DEFAULT (unixepoch()),
  FOREIGN KEY(node_id) REFERENCES nodes(id)
);
CREATE INDEX IF NOT EXISTS idx_req_ts ON requests(ts);
CREATE INDEX IF NOT EXISTS idx_req_node ON requests(node_id);
CREATE TABLE IF NOT EXISTS tokens (
  id TEXT PRIMARY KEY DEFAULT 'global',
  token TEXT UNIQUE
);
INSERT OR IGNORE INTO tokens(id, token) VALUES('global', hex(randomblob(16)));
`);

const AUTH_TOKEN = db.prepare("SELECT token FROM tokens WHERE id='global'").get().token;
console.log(`Auth token: ${AUTH_TOKEN}`);

// Prepared statements
const upsertNode = db.prepare(`INSERT INTO nodes(id,name,host,os,oc_version,role,providers,cpu,mem,disk,swap,sessions,gw_ok,daemon_ok,uptime,tok_today,tok_week,tok_month,last_seen)
  VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
  name=coalesce(excluded.name,name),host=excluded.host,os=excluded.os,oc_version=excluded.oc_version,
  role=excluded.role,providers=excluded.providers,cpu=excluded.cpu,mem=excluded.mem,disk=excluded.disk,
  swap=excluded.swap,sessions=excluded.sessions,gw_ok=excluded.gw_ok,daemon_ok=excluded.daemon_ok,
  uptime=excluded.uptime,tok_today=excluded.tok_today,tok_week=excluded.tok_week,tok_month=excluded.tok_month,
  last_seen=excluded.last_seen`);
const insertReq = db.prepare(`INSERT INTO requests(node_id,upstream,model,status,input_tokens,output_tokens,ttft_ms,total_ms,success,ts) VALUES(?,?,?,?,?,?,?,?,?,?)`);
const getNodes = db.prepare("SELECT * FROM nodes ORDER BY role='master' DESC, name");
const getReqs = db.prepare("SELECT r.*,n.name as node_name FROM requests r LEFT JOIN nodes n ON r.node_id=n.id ORDER BY r.ts DESC LIMIT ?");
const getStats = db.prepare(`SELECT count(*) as total, sum(input_tokens) as input_tok, sum(output_tokens) as output_tok,
  sum(success) as ok, avg(ttft_ms) as avg_ttft, avg(total_ms) as avg_total
  FROM requests WHERE ts > ?`);
const renameNode = db.prepare("UPDATE nodes SET name=? WHERE id=?");
const deleteNode = db.prepare("DELETE FROM nodes WHERE id=?");

// WebSocket clients
const wsClients = new Set();
function broadcast(data) {
  const msg = JSON.stringify(data);
  for (const c of wsClients) { try { c.send(msg); } catch {} }
}

// MIME types
const MIME = { '.html':'text/html','.js':'application/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.svg':'image/svg+xml' };

// HTTP server
const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const method = req.method;

  // CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type,Authorization');
  if (method === 'OPTIONS') { res.writeHead(204); return res.end(); }

  const json = (code, data) => { res.writeHead(code, {'Content-Type':'application/json'}); res.end(JSON.stringify(data)); };
  const auth = () => {
    const t = (req.headers.authorization||'').replace('Bearer ','');
    if (t !== AUTH_TOKEN) { json(401, {error:'unauthorized'}); return false; }
    return true;
  };

  // Static files + agent.sh download
  if (method === 'GET' && !url.pathname.startsWith('/api/')) {
    if (url.pathname === '/agent.sh') {
      const agentPath = path.join(__dirname, '..', 'agent', 'agent.sh');
      if (fs.existsSync(agentPath)) {
        res.writeHead(200, {'Content-Type':'text/plain'});
        return fs.createReadStream(agentPath).pipe(res);
      }
    }
    let fp = path.join(PUBLIC, url.pathname === '/' ? 'index.html' : url.pathname);
    if (!fs.existsSync(fp)) fp = path.join(PUBLIC, 'index.html');
    const ext = path.extname(fp);
    res.writeHead(200, {'Content-Type': MIME[ext]||'text/plain'});
    return fs.createReadStream(fp).pipe(res);
  }

  // Body parser helper
  const readBody = () => new Promise(r => { let d=''; req.on('data',c=>d+=c); req.on('end',()=>r(JSON.parse(d||'{}'))); });

  // API routes
  (async () => {
    try {
      // GET /api/dashboard - public overview
      if (url.pathname === '/api/dashboard' && method === 'GET') {
        const now = Math.floor(Date.now()/1000);
        const today = now - (now % 86400);
        const nodes = getNodes.all();
        const stats = getStats.get(today);
        const reqs = getReqs.all(50);
        return json(200, { nodes, stats, requests: reqs, token: undefined });
      }

      // POST /api/heartbeat - agent reports
      if (url.pathname === '/api/heartbeat' && method === 'POST') {
        if (!auth()) return;
        const b = await readBody();
        const now = Math.floor(Date.now()/1000);
        upsertNode.run(b.id,b.name,b.host,b.os,b.oc_version,b.role||'worker',
          JSON.stringify(b.providers||[]),b.cpu||0,b.mem||0,b.disk||0,b.swap||0,
          b.sessions||0,b.gw_ok?1:0,b.daemon_ok?1:0,b.uptime||0,
          b.tok_today||0,b.tok_week||0,b.tok_month||0,now);
        broadcast({ type:'heartbeat', node: { ...b, last_seen: now } });
        return json(200, { ok: true });
      }

      // POST /api/request - agent reports API call (single or batch)
      if (url.pathname === '/api/request' && method === 'POST') {
        if (!auth()) return;
        const b = await readBody();
        const now = Math.floor(Date.now()/1000);
        const items = Array.isArray(b) ? b : [b];
        for (const r of items) {
          insertReq.run(r.node_id,r.upstream,r.model,r.status||200,
            r.input_tokens||0,r.output_tokens||0,r.ttft_ms||0,r.total_ms||0,
            r.success!==false?1:0, r.ts||now);
        }
        if (items.length <= 5) items.forEach(r => broadcast({ type:'request', request: r }));
        return json(200, { ok: true, count: items.length });
      }

      // POST /api/node/rename
      if (url.pathname === '/api/node/rename' && method === 'POST') {
        if (!auth()) return;
        const b = await readBody();
        renameNode.run(b.name, b.id);
        broadcast({ type:'rename', id: b.id, name: b.name });
        return json(200, { ok: true });
      }

      // GET /api/admin/info
      if (url.pathname === '/api/admin/info' && method === 'GET') {
        if (!auth()) return;
        const nodes = getNodes.all();
        return json(200, { token: AUTH_TOKEN, nodes });
      }

      // DELETE /api/node/:id
      if (url.pathname.startsWith('/api/node/') && method === 'DELETE') {
        if (!auth()) return;
        const id = url.pathname.split('/').pop();
        deleteNode.run(id);
        broadcast({ type:'delete', id });
        return json(200, { ok: true });
      }

      json(404, { error: 'not found' });
    } catch (e) { json(500, { error: e.message }); }
  })();
});

// WebSocket
const wss = new WebSocketServer({ server });
wss.on('connection', ws => {
  wsClients.add(ws);
  ws.on('close', () => wsClients.delete(ws));
});

server.listen(PORT, '0.0.0.0', () => console.log(`OC Monitor running on :${PORT}`));
