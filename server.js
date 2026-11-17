import http from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const publicDir = path.join(__dirname, 'public');
const PORT = Number(process.env.PORT || 8080);

// MT5 integration: signal delivery and authenticated terminal heartbeat.
// Order execution happens inside the user's MT5 Expert Advisor; server-side auto mode stays OFF.
let automaticTradingEnabled = false;
let mt5LastHeartbeat = null;
const brokerExecutionReady = false;
const automationStatus = () => ({
  enabled: automaticTradingEnabled,
  brokerConnected: !!mt5LastHeartbeat && Date.now() - Date.parse(mt5LastHeartbeat.receivedAt) < 60000,
  executionAvailable: false,
  mode: 'MT5_EA_EXECUTION',
  note: 'Order execution is controlled by the MT5 EA and its explicit AutoExecution input.'
});
function requireMt5Token(req) {
  const expected = process.env.NEXORA_MT5_TOKEN || '';
  const supplied = (req.headers.authorization || '').replace(/^Bearer\s+/i, '').trim();
  if (expected.length < 32 || supplied.length !== expected.length) return false;
  let mismatch = 0;
  for (let i = 0; i < expected.length; i++) mismatch |= expected.charCodeAt(i) ^ supplied.charCodeAt(i);
  return mismatch === 0;
}
export function assertAutomaticExecutionAllowed() {
  throw new Error('Server-side order execution is not implemented. MT5 EA execution is separately controlled in the terminal.');
}

const TWELVEDATA = 'https://api.twelvedata.com';
const GDELT = 'https://api.gdeltproject.org/api/v2/doc/doc';
const GOOGLE_NEWS_RSS = 'https://news.google.com/rss/search';
let newsCache = { key: '', items: [], at: 0 };
let newsBackoffUntil = 0;
const symbolSearchCache = new Map();
const LIVE_WATCHLIST = [
  { symbol: 'EUR/USD', name: 'Euro / US Dollar', market: 'forex' },
  { symbol: 'USD/ZAR', name: 'US Dollar / South African Rand', market: 'forex' },
  { symbol: 'XAU/USD', name: 'Gold / US Dollar', market: 'metals' },
  { symbol: 'WTI', name: 'WTI Crude Oil', market: 'energy' },
  { symbol: 'BTC/USD', name: 'Bitcoin / US Dollar', market: 'crypto' },
  { symbol: 'SPY', name: 'S&P 500 ETF', market: 'indices' },
  { symbol: 'AAPL', name: 'Apple', market: 'shares' },
  { symbol: 'NVDA', name: 'NVIDIA', market: 'shares' }
];
// A 30-minute cadence limits provider consumption while keeping a regular website refresh.
const SCAN_INTERVAL_MS = 30 * 60 * 1000;
const NEWS_REFRESH_INTERVAL_MS = 2 * 60 * 60 * 1000;
const GLOBAL_NEWS_QUERY = 'global financial markets OR crude oil OR energy OR central banks OR inflation OR interest rates OR stocks OR bonds OR currencies OR commodities OR cryptocurrency';
let globalNewsIntel = { items: [], source: 'Not loaded', lastUpdated: null, nextRefreshAt: null, stale: true, error: null };
let newsRefreshPromise = null;
let liveScan = { instruments: [], lastUpdated: null, nextScanAt: null, scanning: false, error: null };
let scanPromise = null;
let lastScanStartedAt = 0;
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
    const raw = await response.text();
    let data;
    try { data = JSON.parse(raw); }
    catch {
      const error = new Error(`Market-data provider returned a non-JSON response (HTTP ${response.status}).`);
      error.providerStatus = response.status;
      error.status = 502;
      throw error;
    }
    if (!response.ok || data?.status === 'error' || data?.code) {
      const providerStatus = Number(data?.code || response.status) || response.status;
      const message = String(data?.message || `Provider returned HTTP ${response.status}`).slice(0, 240);
      const error = new Error(message);
      error.providerStatus = providerStatus;
      error.status = 502;
      throw error;
    }
    return data;
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
  // Twelve Data REST endpoints are path-based (for example /time_series and /quote),
  // not selected through a "function=" query parameter.
  const endpoint = String(params.function || '').trim();
  if (!endpoint) throw new Error('A Twelve Data endpoint is required.');
  const url = new URL('/' + endpoint.replaceAll('/', ''), TWELVEDATA);
  for (const [k,v] of Object.entries(params)) {
    if (k === 'function' || v === undefined || v === null || v === '') continue;
    url.searchParams.set(k, String(v));
  }
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
function analyseVolume(series) {
  const candles = series.candles || [];
  const volumes = candles.map(c => c.volume).filter(v => Number.isFinite(v) && v >= 0);
  const last = candles.at(-1);
  if (!last || !Number.isFinite(last.volume) || volumes.length < 5) {
    return { available: false, volume: null, volumeType: 'not supplied by provider', explanation: 'The provider did not supply enough usable volume observations for this instrument. No volume conclusion is made.' };
  }
  const prior = volumes.slice(-21, -1);
  if (prior.length < 5) return { available: false, volume: last.volume, volumeType: 'provider-reported; classification not supplied', explanation: 'Insufficient history for a reliable relative-volume comparison.' };
  const average = prior.reduce((a,b)=>a+b,0)/prior.length;
  const relative = average > 0 ? last.volume/average : null;
  const direction = last.close > last.open ? 'up' : last.close < last.open ? 'down' : 'flat';
  const intensity = relative === null ? 'unknown' : relative >= 2 ? 'exceptionally high' : relative >= 1.5 ? 'high' : relative <= 0.5 ? 'low' : 'near average';
  return {
    available: true, volume: last.volume, averageVolume20: average,
    relativeVolume20: relative === null ? null : Number(relative.toFixed(2)),
    volumeType: 'provider-reported; provider does not identify centralized traded volume versus tick volume here',
    candleDirection: direction, intensity,
    interpretation: relative === null ? 'Relative volume cannot be calculated.' :
      relative >= 1.5 && direction === 'up' ? 'Above-average activity accompanied an up candle; this is participation evidence, not proof of net buying or the cause.' :
      relative >= 1.5 && direction === 'down' ? 'Above-average activity accompanied a down candle; this is participation evidence, not proof of net selling or the cause.' :
      relative >= 1.5 ? 'Above-average activity accompanied a flat candle; participation increased without clear candle direction.' :
      relative <= 0.5 ? 'Activity was below its recent average; the move may have occurred in thinner conditions.' :
      'Activity was near its recent average.',
    warning: 'A candle volume value alone cannot identify who traded, whether all market venues are represented, or why price moved.'
  };
}
function matchNewsToInstrument(symbol, items) {
  const key = symbol.replace('/', ' ').toLowerCase();
  const aliases = {
    'xau usd':['gold','bullion','precious metal'], 'xag usd':['silver'],
    'wti':['crude oil','oil prices','opec','petroleum'], 'btc usd':['bitcoin','crypto'],
    'eth usd':['ethereum','crypto'], 'usd zar':['south african rand','rand'],
    'eur usd':['euro','ecb'], 'gbp usd':['sterling','bank of england','british pound'],
    'usd jpy':['yen','bank of japan'], 'aapl':['apple'], 'nvda':['nvidia'],
    'spy':['s&p 500','wall street','us stocks']
  };
  const terms=[key,...(aliases[key]||[])];
  return (items||[]).filter(item => terms.some(term => (item.title||'').toLowerCase().includes(term))).slice(0,5).map(item=>({
    title:item.title, url:item.url, source:item.source, publishedAt:item.publishedAt,
    relationship:'Topic match only; not proof this headline caused the price or volume move.'
  }));
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
async function getSymbolMatches(query) {
  requireTwelveKey();
  const key=query.trim().toLowerCase(), cached=symbolSearchCache.get(key);
  if(key.length<2)return [];
  if(cached && Date.now()-cached.at<600000)return cached.items;
  const data=await jsonFetch(twelveUrl({function:'symbol_search',symbol:query.trim(),outputsize:30,show_plan:true}).toString());
  if(data.status==='error'||!Array.isArray(data.data))throw new Error(data.message||'Instrument search unavailable.');
  const items=data.data.map(x=>({symbol:x.symbol,name:x.instrument_name||x.name||x.symbol,exchange:x.exchange||'',country:x.country||'',type:x.instrument_type||x.type||'Instrument',access:x.access?.global||x.access?.plan||'Provider-listed'})).filter(x=>x.symbol);
  symbolSearchCache.set(key,{items,at:Date.now()});return items;
}
async function getGoogleNewsFallback(query) {
  const url=new URL(GOOGLE_NEWS_RSS);url.searchParams.set('q',query||'global financial markets');url.searchParams.set('hl','en-US');url.searchParams.set('gl','US');url.searchParams.set('ceid','US:en');
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),12000);
  try {
    const response=await fetch(url,{signal:controller.signal,headers:{accept:'application/rss+xml, application/xml, text/xml'}});
    if(!response.ok)throw new Error('RSS fallback returned HTTP '+response.status);
    const xml=await response.text(),blocks=xml.match(/<item>[\s\S]*?<\/item>/gi)||[];
    const decode=v=>v.replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"').replace(/&#39;|&apos;/g,"'");
    return blocks.slice(0,20).map(block=>{
      const get=tag=>decode(((block.match(new RegExp('<'+tag+'>([\\s\\S]*?)<\\/'+tag+'>','i'))||[,''])[1]).replace(/<!\[CDATA\[|\]\]>/g,'').trim());
      return {title:get('title'),url:get('link'),source:get('source')||'Google News',publishedAt:get('pubDate')||null,language:'en',tone:null,sourceProvider:'Google News RSS'};
    }).filter(x=>x.title&&x.url);
  } finally {clearTimeout(timer);}
}
async function getNews(query) {
  const key=(query||'global markets').trim().toLowerCase();
  if(newsCache.key===key&&Date.now()-newsCache.at<300000)return {items:newsCache.items,source:'Cached news',stale:false};
  let primaryError=null;
  if(Date.now()>=newsBackoffUntil)try{
    const url=new URL(GDELT);url.searchParams.set('query',query||'markets OR finance OR central bank OR inflation');
    url.searchParams.set('mode','ArtList');url.searchParams.set('format','json');url.searchParams.set('sort','HybridRel');url.searchParams.set('maxrecords','20');
    const data=await jsonFetch(url.toString(),15000);
    const items=(data.articles||[]).map(a=>({title:a.title,url:a.url,source:a.domain||a.source||'Unknown source',publishedAt:a.seendate||null,language:a.language||null,tone:safeNumber(a.tone),sourceProvider:'GDELT'})).filter(a=>a.title&&a.url);
    newsCache={key,items,at:Date.now()};return {items,source:'GDELT',stale:false};
  }catch(error){primaryError=error;if(/HTTP 429/.test(error.message))newsBackoffUntil=Date.now()+180000;}
  try{
    const items=await getGoogleNewsFallback(query);newsCache={key,items,at:Date.now()};
    return {items,source:'Google News RSS fallback',stale:false,primaryWarning:primaryError?.message||'GDELT unavailable'};
  }catch(fallbackError){
    if(newsCache.items.length)return {items:newsCache.items,source:'Cached news (stale)',stale:true,primaryWarning:primaryError?.message||fallbackError.message};
    const error=new Error('News providers are temporarily unavailable. Please try again in a few minutes.');error.status=503;throw error;
  }
}
async function refreshGlobalNews(force = false) {
  if (newsRefreshPromise) return newsRefreshPromise;
  if (!force && globalNewsIntel.lastUpdated && Date.now() < Date.parse(globalNewsIntel.nextRefreshAt || 0)) return globalNewsIntel;
  newsRefreshPromise = (async () => {
    try {
      const result = await getNews(GLOBAL_NEWS_QUERY);
      globalNewsIntel = { items: result.items || [], source: result.source || 'Financial news providers',
        lastUpdated: new Date().toISOString(), nextRefreshAt: new Date(Date.now() + NEWS_REFRESH_INTERVAL_MS).toISOString(),
        stale: !!result.stale, error: null };
    } catch (error) {
      globalNewsIntel = { ...globalNewsIntel, stale: true, error: error.message,
        nextRefreshAt: new Date(Date.now() + 15 * 60 * 1000).toISOString() };
    }
    return globalNewsIntel;
  })().finally(() => { newsRefreshPromise = null; });
  return newsRefreshPromise;
}

async function runLiveScan(force = false) {
  if (scanPromise) return scanPromise;
  if (!force && lastScanStartedAt && Date.now() - lastScanStartedAt < SCAN_INTERVAL_MS && liveScan.lastUpdated) return liveScan;
  scanPromise = (async () => {
    liveScan = { ...liveScan, scanning: true, error: null };
    lastScanStartedAt = Date.now();
    const instruments = [];
    for (const item of LIVE_WATCHLIST) {
      try {
        const series = await getSeries(item.symbol, '1h', 100);
        const analysis = analyseSeries(series);
        const candles = series.candles;
        const previousClose = candles.length > 1 ? candles[candles.length - 2].close : null;
        const changePercent = previousClose && previousClose !== 0 ? ((analysis.lastPrice - previousClose) / previousClose) * 100 : null;
        instruments.push({
          symbol: item.symbol, name: item.name, market: item.market, status: 'ok',
          direction: analysis.direction, score: analysis.score,
          lastPrice: analysis.lastPrice,
          changePercent,
          timestamp: analysis.timestamp, source: 'Twelve Data',
          plan: analysis.plan, indicators: analysis.indicators,
          volume: analyseVolume(series), relatedHeadlines: matchNewsToInstrument(item.symbol, globalNewsIntel.items)
        });
      } catch (error) {
        instruments.push({ symbol: item.symbol, name: item.name, market: item.market, status: 'unavailable', error: error.message });
      }
    }
    const completedAt = new Date().toISOString();
    liveScan = {
      instruments, lastUpdated: completedAt,
      nextScanAt: new Date(Date.now() + SCAN_INTERVAL_MS).toISOString(),
      scanning: false,
      successfulCount: instruments.filter(x => x.status === 'ok').length,
      source: 'Twelve Data'
    };
    return liveScan;
  })().catch(error => {
    liveScan = { ...liveScan, scanning: false, error: error.message };
    return liveScan;
  }).finally(() => { scanPromise = null; });
  return scanPromise;
}

async function route(req, res, url) {
  const p = url.pathname;
  if (p === '/api/health') return send(res, 200, { ok: true, service: 'NEXORA AI', time: new Date().toISOString() });
  if (p === '/api/mt5/heartbeat' && req.method === 'POST') {
    if (!requireMt5Token(req)) return send(res, 401, { error: 'MT5 connector authentication failed or server token is not configured.' });
    let raw = ''; for await (const chunk of req) { raw += chunk; if (raw.length > 8192) return send(res, 413, { error: 'Heartbeat payload too large.' }); }
    let body; try { body = JSON.parse(raw || '{}'); } catch { return send(res, 400, { error: 'Invalid JSON heartbeat.' }); }
    if (typeof body.terminal_connected !== 'boolean' || typeof body.trade_allowed !== 'boolean') return send(res, 400, { error: 'Invalid MT5 heartbeat fields.' });
    mt5LastHeartbeat = {
      connected: body.terminal_connected,
      tradeAllowed: body.trade_allowed && body.account_trade_allowed === true,
      account: String(body.account || '').slice(0, 32),
      server: String(body.server || '').slice(0, 100),
      company: String(body.company || '').slice(0, 100),
      currency: String(body.currency || '').slice(0, 12),
      receivedAt: new Date().toISOString()
    };
    return send(res, 200, { ok: true, mode: 'MT5-EA', heartbeatReceivedAt: mt5LastHeartbeat.receivedAt });
  }
  if (p === '/api/mt5/status' && req.method === 'GET') {
    if (!requireMt5Token(req)) return send(res, 401, { error: 'MT5 connector authentication failed or server token is not configured.' });
    const fresh = !!mt5LastHeartbeat && Date.now() - Date.parse(mt5LastHeartbeat.receivedAt) < 60000;
    return send(res, 200, { connected: fresh && mt5LastHeartbeat.connected, heartbeat: fresh ? mt5LastHeartbeat : null, mode: 'MT5-EA', automaticTrading: 'controlled-in-terminal' });
  }
  if (p === '/api/mt5/signal-local' && req.method === 'POST') {
    if (!requireMt5Token(req)) return send(res, 401, { error: 'MT5 connector authentication failed or server token is not configured.' });
    let raw = '';
    for await (const chunk of req) { raw += chunk; if (raw.length > 65536) return send(res, 413, { error: 'Local candle payload too large.' }); }
    let body;
    try { body = JSON.parse(raw || '{}'); } catch { return send(res, 400, { error: 'Invalid JSON candle payload.' }); }
    const symbol = String(body.chartSymbol || '').trim();
    const interval = String(body.interval || 'chart').trim();
    if (!symbol || symbol.length > 100 || !Array.isArray(body.candles) || body.candles.length < 60 || body.candles.length > 500)
      return send(res, 400, { error: 'Expected chartSymbol and between 60 and 500 closed MT5 candles.' });
    const candles = body.candles.map(c => ({
      time: String(c.time || ''),
      open: safeNumber(c.open), high: safeNumber(c.high),
      low: safeNumber(c.low), close: safeNumber(c.close),
      volume: safeNumber(c.volume ?? 0)
    })).filter(c => c.time && c.open !== null && c.high !== null && c.low !== null && c.close !== null &&
      c.high >= Math.max(c.open, c.close, c.low) && c.low <= Math.min(c.open, c.close, c.high));
    if (candles.length < 60) return send(res, 400, { error: 'Insufficient valid closed MT5 candles after validation.' });
    const series = { symbol, interval, candles, source: 'Deriv MT5 chart data' };
    const analysis = analyseSeries(series);
    console.info('NEXORA local MT5 analysis', { chartSymbol: symbol, candleCount: candles.length, interval });
    return send(res, 200, {
      symbol: analysis.symbol, direction: analysis.direction, score: analysis.score,
      timestamp: analysis.timestamp, entry: analysis.plan?.entry ?? null,
      stopLoss: analysis.plan?.stopLoss ?? null, takeProfit: analysis.plan?.takeProfit ?? null,
      interval: analysis.interval, indicators: analysis.indicators,
      source: analysis.source,
      warnings: [...(analysis.warnings || []), 'Analysis uses closed candles supplied by the connected MT5 terminal; verify data freshness and broker contract rules.']
    });
  }
  if (p === '/api/mt5/signal' && req.method === 'GET') {
    if (!requireMt5Token(req)) return send(res, 401, { error: 'MT5 connector authentication failed or server token is not configured.' });
    const symbol = url.searchParams.get('symbol');
    if (!symbol) return send(res, 400, { error: 'symbol is required' });
    const series = await getSeries(symbol, url.searchParams.get('interval') || '1h', 100);
    console.info('NEXORA MT5 signal instrument', { requestedSymbol: symbol, returnedSymbol: series.symbol, interval: series.interval });
    const analysis = analyseSeries(series);
    return send(res, 200, {
      symbol: analysis.symbol, direction: analysis.direction, score: analysis.score,
      timestamp: analysis.timestamp, entry: analysis.plan?.entry ?? null,
      stopLoss: analysis.plan?.stopLoss ?? null, takeProfit: analysis.plan?.takeProfit ?? null,
      interval: analysis.interval, indicators: analysis.indicators,
      warnings: analysis.warnings || ['Technical-only signal; not a profit guarantee.']
    });
  }
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
    news: 'GDELT with Google News RSS fallback', technicalEngine: 'active',
    broker: 'not_connected', automaticExecution: 'disabled',
    coverage: 'Only instruments returned by connected providers can be scanned; this is not an exhaustive all-world exchange feed.'
  });
  if (p === '/api/scan/status') {
    if (!liveScan.lastUpdated) await runLiveScan(false);
    return send(res,200,{...liveScan,watchlist:LIVE_WATCHLIST.map(x=>({symbol:x.symbol,name:x.name,market:x.market})),refreshIntervalMinutes:15});
  }
  if (p === '/api/market/search') {
    const q=url.searchParams.get('q')||'';
    if(q.trim().length<2)return send(res,200,{items:[],source:'Twelve Data'});
    return send(res,200,{items:await getSymbolMatches(q),source:'Twelve Data'});
  }
  if (p === '/api/market/quote') {
    const symbol=url.searchParams.get('symbol'); if(!symbol) return send(res,400,{error:'symbol is required'});
    return send(res,200,await getQuote(symbol));
  }
  if (p === '/api/market/series') {
    const symbol=url.searchParams.get('symbol'); if(!symbol) return send(res,400,{error:'symbol is required'});
    return send(res,200,await getSeries(symbol,url.searchParams.get('interval')||'1h',Math.min(500,Math.max(30,Number(url.searchParams.get('outputsize')||100)))));
  }
  if (p === '/api/market/volume') {
    const symbol=url.searchParams.get('symbol'); if(!symbol) return send(res,400,{error:'symbol is required'});
    const series=await getSeries(symbol,url.searchParams.get('interval')||'1h',Math.min(500,Math.max(30,Number(url.searchParams.get('outputsize')||100))));
    return send(res,200,{symbol:series.symbol,interval:series.interval,timestamp:series.candles.at(-1)?.time||null,source:series.source,...analyseVolume(series)});
  }
  if (p === '/api/news/status') {
    if (!globalNewsIntel.lastUpdated) await refreshGlobalNews(true);
    return send(res,200,globalNewsIntel);
  }
  if (p === '/api/news') {
    const query=url.searchParams.get('q');
    if (!query) {
      if (!globalNewsIntel.lastUpdated || Date.now() >= Date.parse(globalNewsIntel.nextRefreshAt || 0)) await refreshGlobalNews(true);
      return send(res,200,{items:globalNewsIntel.items,source:globalNewsIntel.source,retrievedAt:globalNewsIntel.lastUpdated,nextRefreshAt:globalNewsIntel.nextRefreshAt,stale:globalNewsIntel.stale,error:globalNewsIntel.error});
    }
    return send(res,200,{...await getNews(query),retrievedAt:new Date().toISOString()});
  }
  if (p === '/api/signals') {
    const symbol=url.searchParams.get('symbol'); if(!symbol) return send(res,400,{error:'symbol is required'});
    const series=await getSeries(symbol,url.searchParams.get('interval')||'1h',100);
    const analysis=analyseSeries(series);
    return send(res,200,{...analysis,volume:analyseVolume(series),relatedHeadlines:matchNewsToInstrument(symbol,globalNewsIntel.items)});
  }
  return send(res,404,{error:'API route not found.'});
}

const server = http.createServer(async (req,res)=>{
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    if(url.pathname.startsWith('/api/')) {
      try { await route(req,res,url); }
      catch(error) {
        // Log provider diagnostics without ever logging request URLs (which contain the API key).
        console.error('NEXORA API request failed', {
          path: url.pathname,
          message: String(error.message || 'Provider request failed').slice(0, 240),
          providerStatus: error.providerStatus || error.status || 502
        });
        send(res,error.status||502,{
          error:error.message||'Provider request failed',
          providerStatus:error.providerStatus||error.status||502
        });
      }
      return;
    }
    let pathname=decodeURIComponent(url.pathname);
    if(pathname==='/') pathname='/index.html';
    const file=path.join(publicDir,pathname);
    if(!file.startsWith(publicDir)) return send(res,403,{error:'Forbidden'});
    const data=await readFile(file);
    res.writeHead(200,{'Content-Type':mime[path.extname(file)]||'application/octet-stream','Cache-Control':'no-store, no-cache, must-revalidate'});
    res.end(data);
  } catch { res.writeHead(404,{'Content-Type':'text/plain; charset=utf-8'});res.end('Not found'); }
});
server.listen(PORT,'0.0.0.0',()=>{ console.log(`NEXORA AI listening on ${PORT}`); runLiveScan(true); refreshGlobalNews(true); setInterval(()=>runLiveScan(true),SCAN_INTERVAL_MS).unref(); setInterval(()=>refreshGlobalNews(true),NEWS_REFRESH_INTERVAL_MS).unref(); });
