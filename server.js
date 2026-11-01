import http from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const publicDir = path.join(__dirname, 'public');

// Fail-safe: automatic trading permission is OFF on every server start.
let automaticTradingEnabled = false;
const brokerExecutionReady = false; // Set true only after a broker adapter and safeguards are implemented and tested.

function automationStatus() {
  return { enabled: automaticTradingEnabled, brokerConnected: false, executionAvailable: brokerExecutionReady };
}

// Every future automatic order route/worker MUST call this guard immediately before submission.
export function assertAutomaticExecutionAllowed() {
  if (!automaticTradingEnabled) throw new Error('Automatic trading is OFF. Automatic order submission is blocked.');
  if (!brokerExecutionReady) throw new Error('Automatic execution is unavailable: no verified broker adapter is connected.');
}

const mime = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml'
};

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    let pathname = decodeURIComponent(url.pathname);

    if (pathname === '/api/automation/status' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(automationStatus()));
      return;
    }

    if (pathname === '/api/automation/mode' && req.method === 'POST') {
      let raw = '';
      for await (const chunk of req) raw += chunk;
      let body;
      try { body = JSON.parse(raw || '{}'); } catch {
        res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ error: 'Invalid JSON request.' }));
        return;
      }
      if (typeof body.enabled !== 'boolean') {
        res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ error: 'enabled must be true or false.' }));
        return;
      }
      // OFF takes effect synchronously on the server before the response is sent.
      automaticTradingEnabled = body.enabled;
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(automationStatus()));
      return;
    }

    if (pathname.startsWith('/api/')) {
      res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ error: 'API route not found.' }));
      return;
    }
    if (pathname === '/') pathname = '/index.html';

    const file = path.join(publicDir, pathname);
    if (!file.startsWith(publicDir)) throw new Error('Forbidden');

    const data = await readFile(file);
    res.writeHead(200, {
      'Content-Type': mime[path.extname(file)] || 'application/octet-stream',
      'Cache-Control': pathname === '/index.html' ? 'no-cache' : 'public, max-age=3600'
    });
    res.end(data);
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Not found');
  }
});

const port = Number(process.env.PORT || 3000);
server.listen(port, '0.0.0.0', () => {
  console.log(`Trading AI Scanner listening on ${port}`);
});
