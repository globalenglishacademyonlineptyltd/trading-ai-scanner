import http from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const publicDir = path.join(__dirname, 'public');
const PORT = Number(process.env.PORT || 8080);

// Safety: live order execution is deliberately unavailable in this release.
let automaticTradingEnabled = false;
const brokerExecutionReady = false;
const automationStatus = () => ({
  enabled: automaticTradingEnabled,
  brokerConnected: false,
  executionAvailable: brokerExecutionReady
});
export function assertAutomaticExecutionAllowed() {
  if (!automaticTradingEnabled) throw new Error('Automatic trading is OFF.');
  if (!brokerExecutionReady) throw new Error('No verified broker adapter is connected.');
}

const TWELVEDATA = 'https://api.twelvedata.com';
const GDELT = 'https://api.gdeltproject.org/api/v2/doc/doc';
const mime = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml'
};

async function jsonFetch(url, timeoutMs = 12000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: controller.signal, headers: { accept: 'application/json' } });
    if (!response.ok) throw new Error(`Provider returned HTTP ${response.status}`);
    return await response.json();
  } finally { clearTimeout(timer); }
}
function send(res, status, data) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(data));
}
function safeNumber(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}
function requireTwelveKey() {
  if (!process.env.TWELVEDATA_API_KEY) {
    const error = new Error('Market data is not connected. Add TWELVEDATA_API_KEY to Railway service variables.');
    error.status = 503; throw error;
  }
}
function twelveUrl(params) {
  const url = new URL(TWELVEDATA);
  for (const [k,v] of Object.entries(params)) if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, String(v));
  url.searchParams.set('apikey', process.env.TWELVEDATA_API_KEY);
  return url;
}
async function getQuote(symbol) {
  requireTwelveKey();
  const data = await jsonFetch(twelveUrl({ function: 'quote', symbol }).toString());
  if (data.status === 'error' || data.code) throw new Error(data.message || 'Market-data provider rejected the symbol.');
  return {
    symbol: data.symbol || symbol, name: data.name || data.instrument_name || symbol,
    exchange: data.exchange || null, currency: data.currency || null,
    price: safeNumber(data.close ?? data.price), change: safeNumber(data.change),
    percentChange: safeNumber(data.percent_change), high: safeNumber(data.high),
    low: safeNumber(data.low), volume: safeNumber(data.volume),
    timestamp: data.timestamp || null, source: 'Twelve Data', status: 'provider quote'
  };
}
async function getSeries(symbol, interval = '1h', outputsize = 100) {
  requireTwelveKey();
  const data = await jsonFetch(twelveUrl({ function: 'time_series', symbol, interval, outputsize, order: 'ASC' }).toString());
  if (data.status === 'error' || !Array.isArray(data.values)) throw new Error(data.message || 'No candle data returned for this symbol.');
  const candles = data.values.map(v => ({
    time: v.datetime, open: safeNumber(v.open), high: safeNumber(v.high),
    low: safeNumber(v.low), close: safeNumber(v.close), volume: safeNumber(v.volume)
  })).filter(c => c.close !== null && c.high !== null && c.low !== null);
  if (candles.length < 30) throw new Error('At least 30 valid candles are required for analysis.');
  return { symbol: data.meta?.symbol || symbol, interval, exchange: data.meta?.exchange || null, candles, source: 'Twelve Data' };
}
function ema(values, period) {
  const k = 2 / (period + 1);
  return values.reduce((out, value, i) => {
    out.push(i === 0 ? value : value * k + out[i - 1] * (1 - k));
    return out;
  }, []);
}
function rsi(values, period = 14) {
  if (values.length <= period) return null;
  let gains = 0, losses = 0;
  for (let i = values.length - period; i < values.length; i++) {
    const d = values[i] - values[i - 1];
    if (d > 0) gains += d; else losses -= d;
  }
  if (losses === 0) return 100;
  const rs = (gains / period) / (losses / period);
  return 100 - (100 / (1 + rs));
}
function analyseSeries(series) {
  const c = series.candles;
  const closes = c.map(x => x.close);
  const last = c[c.length - 1], prior = c[c.length - 2];
  const e20 = ema(closes, 20), e50 = ema(closes, 50);
  const avgRange = c.slice(-14).reduce((s,x)=>s+(x.high-x.low),0)/Math.min(14,c.length);
  const momentum = ((last.close - prior.close) / prior.close) * 100;
  const strength = rsi(closes);
  const trend = e20.at(-1) > e50.at(-1) ? 'bullish' : e20.at(-1) < e50.at(-1) ? 'bearish' : 'neutral';
  let score = 50;
  score += trend === 'bullish' ? 18 : trend === 'bearish' ? -18 : 0;
  score += last.close > e20.at(-1) ? 10 : -10;
  score += momentum > 0 ? Math.min(8, momentum * 3) : Math.max(-8, momentum * 3);
  if (strength !== null) score += strength > 55 && strength < 70 ? 8 : strength < 45 && strength > 30 ? -8 : strength >= 70 || strength <= 30 ? 0 : 0;
  score = Math.max(0, Math.min(100, Math.round(score)));
  const direction = score >= 68 ? 'BUY' : score <= 32 ? 'SELL' : 'WAIT';
  const entry = last.close;
  const stop = direction === 'BUY' ? entry - avgRange * 1.5 : direction === 'SELL' ? entry + avgRange * 1.5 : null;
  const target = direction === 'BUY' ? entry + avgRange * 3 : direction === 'SELL' ? entry - avgRange * 3 : null;
  const risk = stop === null ? null : Math.abs(entry-stop);
  const reward = target === null ? null : Math.abs(target-entry);
  return {
    symbol: series.symbol, direction, score, confidenceLabel: 'technical score (not win probability)',
    lastPrice: entry, timestamp: last.time, source: series.source, interval: series.interval,
    indicators: { ema20: e20.at(-1), ema50: e50.at(-1), rsi14: strength, averageRange14: avgRange, momentumPercent: momentum, trend },
    plan: direction === 'WAIT' ? null : { entry, stopLoss: stop, takeProfit: target, riskReward: Number((reward/risk).toFixed(2)) },
    decision: direction === 'WAIT' ? 'WAIT: technical evidence is mixed or insufficient. No trade proposed.' : 'Preliminary technical setup only. Check news, liquidity, spread, event risk and account exposure before acting.',
    warnings: ['Technical-only analysis; no news confirmation in this score.', 'Not a probability of profit or a guarantee.', 'No position size is calculated without verified contract and account-currency specifications.']
  };
}
async function getNews(query) {
  const url = new URL(GDELT);
  url.searchParams.set('query', query || 'markets OR finance OR central bank OR inflation');
  url.searchParams.set('mode', 'ArtList'); url.searchParams.set('format', 'json');
  url.searchParams.set('sort', 'HybridRel'); url.searchParams.set('maxrecords', '25');
  const data = await jsonFetch(url.toString(), 15000);
  return (data.articles || []).map(a => ({
    title: a.title, url: a.url, source: a.domain || a.source || 'Unknown source',
    publishedAt: a.seendate || null, language: a.language || null,
    tone: safeNumber(a.tone), sourceProvider: 'GDELT'
  })).filter(a => a.title && a.url);
}
async function route(req, res, url) {
  const p = url.pathname;
  if (p === '/api/health') return send(res, 200, { ok: true, service: 'NEXORA AI', time: new Date().toISOString() });
  if (p === '/api/automation/status' && req.method === 'GET') return send(res, 200, automationStatus());
  if (p === '/api/automation/mode' && req.method === 'POST') {
    let raw=''; for await (const chunk of req) raw += chunk;
    let body; try { body=JSON.parse(raw || '{}'); } catch { return send(res,400,{error:'Invalid JSON request.'}); }
    if (typeof body.enabled !== 'boolean') return send(res,400,{error:'enabled must be true or false.'});
    automaticTradingEnabled = body.enabled;
    return send(res,200,automationStatus());
  }
  if (p === '/api/intelligence/status') return send(res,200,{
    service:'NEXORA Global Intelligence', marketData: process.env.TWELVEDATA_API_KEY ? 'configured' : 'not_configured',
    news: 'GDELT public news search available', technicalEngine: 'active',
    broker: 'not_connected', automaticExecution: 'disabled',
    coverage: 'Only instruments returned by connected providers can be scanned; this is not an exhaustive all-world exchange feed.'
  });
  if (p === '/api/market/quote') {
    const symbol=url.searchParams.get('symbol'); if(!symbol) return send(res,400,{error:'symbol is required'});
    return send(res,200,await getQuote(symbol));
  }
  if (p === '/api/market/series') {
    const symbol=url.searchParams.get('symbol'); if(!symbol) return send(res,400,{error:'symbol is required'});
    return send(res,200,await getSeries(symbol,url.searchParams.get('interval')||'1h',Math.min(500,Math.max(30,Number(url.searchParams.get('outputsize')||100)))));
  }
  if (p === '/api/news') {
    const query=url.searchParams.get('q')||'markets OR finance OR central bank OR inflation';
    return send(res,200,{items:await getNews(query),source:'GDELT',retrievedAt:new Date().toISOString()});
  }
  if (p === '/api/signals') {
    const symbol=url.searchParams.get('symbol'); if(!symbol) return send(res,400,{error:'symbol is required'});
    const series=await getSeries(symbol,url.searchParams.get('interval')||'1h',100);
    return send(res,200,analyseSeries(series));
  }
  return send(res,404,{error:'API route not found.'});
}

const server = http.createServer(async (req,res)=>{
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    if(url.pathname.startsWith('/api/')) {
      try { await route(req,res,url); }
      catch(error) { send(res,error.status||502,{error:error.message||'Provider request failed', providerStatus:error.status||502}); }
      return;
    }
    let pathname=decodeURIComponent(url.pathname);
    if(pathname==='/') pathname='/index.html';
    const file=path.join(publicDir,pathname);
    if(!file.startsWith(publicDir)) return send(res,403,{error:'Forbidden'});
    const data=await readFile(file);
    res.writeHead(200,{'Content-Type':mime[path.extname(file)]||'application/octet-stream','Cache-Control':pathname==='/index.html'?'no-cache':'public, max-age=3600'});
    res.end(data);
  } catch { res.writeHead(404,{'Content-Type':'text/plain; charset=utf-8'});res.end('Not found'); }
});
server.listen(PORT,'0.0.0.0',()=>console.log(`NEXORA AI listening on ${PORT}`));
