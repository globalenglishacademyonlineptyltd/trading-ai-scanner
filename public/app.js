let latestPlan=null;
let bestFavourablePrice=null;
const $=id=>document.getElementById(id);
const fmt=(n, max=6)=>Number(n).toLocaleString(undefined,{maximumFractionDigits:max});
const escapeHtml=value=>String(value).replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
let scanRefreshTimer=null;
let latestScan=null;
function renderLiveScan(data){
  latestScan=data;
  const rows=data.instruments||[];
  const live=rows.filter(x=>x.status==='ok'&&Number.isFinite(x.lastPrice));
  const list=$('opportunities');
  if(!live.length){
    list.innerHTML='<p class="form-error">No live instruments were returned. Check the provider connection or wait for the next scan. No sample data is being substituted.</p>';
    $('scanConnection').textContent='No successful live quotes';
    $('topScanStatus').textContent='Live scan unavailable';
    $('topScanUpdated').textContent='No valid live scan';
    $('scanTime').textContent='No live data';
    return;
  }
  list.innerHTML=rows.map(x=>{
    if(x.status!=='ok') return '<div class="opp"><div class="instrument">'+escapeHtml(x.symbol)+'<small>Provider data unavailable</small></div><div class="direction medium">UNAVAILABLE</div><div class="muted">—</div><div>—</div><div>—</div></div>';
    const signal=x.direction||'WAIT';
    return '<div class="opp"><div class="instrument">'+escapeHtml(x.symbol)+'<small>'+escapeHtml(x.name||x.market||'Provider instrument')+'</small></div><div class="direction '+(signal==='BUY'?'high':signal==='SELL'?'sell':'medium')+'">'+escapeHtml(signal)+'</div><div class="confidence-number medium">'+escapeHtml(x.score)+'<small>/100 technical</small></div><div>'+fmt(x.lastPrice)+'<small>'+escapeHtml(x.changePercent===null?'Change unavailable':fmt(x.changePercent,3)+'%')+'</small></div><div>'+(x.plan?'1:'+fmt(x.plan.riskReward,2):'—')+'<small>R:R</small></div></div>';
  }).join('');
  const top=[...live].sort((x,y)=>y.score-x.score)[0];
  $('bestSymbol').textContent=top.symbol;
  $('bestSignal').textContent=top.direction;
  $('bestSignal').className='signal '+(top.direction==='BUY'?'buy':top.direction==='SELL'?'sell':'medium');
  $('bestPrice').textContent=fmt(top.lastPrice);
  $('bestChange').textContent=top.changePercent===null?'Change unavailable':fmt(top.changePercent,3)+'%';
  $('bestConfidence').textContent=top.score+'/100';
  $('confidenceBar').style.width=top.score+'%';
  $('bestEntry').textContent=top.plan?fmt(top.plan.entry):'WAIT';
  $('bestStop').textContent=top.plan?fmt(top.plan.stopLoss):'—';
  $('bestTarget').textContent=top.plan?fmt(top.plan.takeProfit):'—';
  $('bestRR').textContent=top.plan?'1:'+fmt(top.plan.riskReward,2):'—';
  const stamp=data.lastUpdated?new Date(data.lastUpdated).toLocaleString():'Timestamp unavailable';
  $('scanTime').textContent='Last provider scan: '+stamp;
  $('scanConnection').textContent=live.length+' of '+rows.length+' instruments returned live data';
  $('topScanStatus').textContent='Live provider data · '+live.length+' instruments';
  $('topScanUpdated').textContent='Updated '+stamp;
}
async function refreshLiveScan(){
  try{
    const r=await fetch('/api/scan/status',{cache:'no-store'});
    const data=await r.json();
    if(!r.ok) throw new Error(data.error||'Live scan status unavailable');
    if(data.lastUpdated) renderLiveScan(data);
    else if(data.scanning) {
      $('scanConnection').textContent='Initial provider scan running…';
      $('topScanStatus').textContent='Fetching live provider candles…';
      $('topScanUpdated').textContent='Waiting for provider response';
    } else if(data.error) {
      $('scanConnection').textContent='Scanner error: '+data.error;
      $('topScanStatus').textContent='Live scanner error';
      $('topScanUpdated').textContent='No valid provider scan';
      $('opportunities').innerHTML='<p class="form-error">'+escapeHtml(data.error)+'</p>';
    } else {
      $('scanConnection').textContent='Waiting for provider scan…';
      $('topScanStatus').textContent='Waiting for first live scan';
    }
  }catch(e){
    $('scanConnection').textContent=e.message;
    $('topScanStatus').textContent='Live scan connection unavailable';
  }
}
function startLiveScanRefresh(){
  refreshLiveScan();
  if(scanRefreshTimer) clearInterval(scanRefreshTimer);
  scanRefreshTimer=setInterval(refreshLiveScan,30000);
}
function addMessage(text,type){
  const el=document.createElement('div');el.className=`message ${type}`;el.textContent=text;$('messages').appendChild(el);$('messages').scrollTop=$('messages').scrollHeight;
}

function answer(q){
  const s=q.toLowerCase();
  if(s.includes('trailing')) return 'A trailing stop follows the market only when it moves in your favour. For a BUY/long position, the stop can ratchet upward as the best price rises. For a SELL/short position, it can ratchet downward as the best price falls. It must never move backwards and increase the original risk. This prototype calculates a trailing-stop illustration; it does not send broker orders.';
  if(s.includes('take profit')||s.includes('target')) return 'Take-profit is the planned exit level where the trade is intended to realise a gain. NEXORA should check that the target is on the profitable side of the entry, calculate reward relative to stop-loss risk, and support partial targets in a later full trade-management implementation.';
  if(s.includes('stop loss')||s.includes('stop-loss')) return 'A stop-loss is the protective exit level that defines where the trade idea is invalidated or the planned loss is limited. NEXORA must validate that it is on the correct side of the entry, calculate cash risk and position size using the instrument contract specifications, and account for gaps and slippage. A stop price does not guarantee an exact fill.';
  if(s.includes('gold')||s.includes('xau')) return 'Gold is analysed from Twelve Data only when the provider returns a valid current candle series. Check the Live Market Scanner timestamp and status before relying on a reading.';
  if(s.includes('risk')||s.includes('position')) return `The risk calculator shows a cash-risk budget based on your account balance and risk percentage. Safe quantity sizing also needs verified contract size, tick/pip value, account-currency conversion, fees and broker rules.`;
  if(s.includes('scan')) return 'The live scanner refreshes provider-backed instruments on its scheduled interval. It only displays instruments for which the provider returns valid data; it does not fill missing prices with samples.';
  if(s.includes('buy')||s.includes('sell')) return 'A production BUY or SELL decision should require multiple independent confirmations, a valid protective stop, a defined target and passing risk checks. It must return WAIT when the evidence is insufficient.';
  return 'Ask me about stop-loss, take-profit, trailing stops, risk calculations or how to interpret the live provider scan. News confirmation and broker execution remain separate systems.';
}

function showPlanError(message){
  $('planError').textContent=message||'';
}

function calculatePlan(){
  showPlanError('');
  $('planResults').innerHTML='';
  $('copyPlan').disabled=true;
  latestPlan=null;
  bestFavourablePrice=null;

  const symbol=$('planSymbol').value.trim()||'Unspecified instrument';
  const direction=$('planDirection').value;
  const entry=Number($('planEntry').value);
  const current=Number($('planCurrent').value);
  const stop=Number($('planStop').value);
  const target=Number($('planTarget').value);
  const balance=Number($('planBalance').value);
  const riskPct=Number($('planRisk').value);
  const trailingEnabled=$('trailingEnabled').checked;
  const trailingDistance=Number($('trailingDistance').value);

  if(![entry,stop,target,balance,riskPct].every(Number.isFinite)||entry<=0||stop<=0||target<=0||balance<=0||riskPct<=0||riskPct>5){
    showPlanError('Enter a valid positive entry, stop-loss, take-profit, account balance and risk percentage (maximum 5%).');
    return;
  }
  if(direction==='long' && !(stop<entry && target>entry)){
    showPlanError('For a BUY / LONG plan, the stop-loss must be below entry and take-profit must be above entry.');
    return;
  }
  if(direction==='short' && !(stop>entry && target<entry)){
    showPlanError('For a SELL / SHORT plan, the stop-loss must be above entry and take-profit must be below entry.');
    return;
  }
  if(trailingEnabled && (!Number.isFinite(trailingDistance)||trailingDistance<=0)){
    showPlanError('Enter a trailing distance greater than zero, or switch off trailing-stop calculation.');
    return;
  }
  if($('planCurrent').value.trim()!=='' && (!Number.isFinite(current)||current<=0)){
    showPlanError('Current / latest price must be a positive number.');
    return;
  }

  const riskDistance=Math.abs(entry-stop);
  const rewardDistance=Math.abs(target-entry);
  const rr=rewardDistance/riskDistance;
  const cashRisk=balance*riskPct/100;
  const rewardAtTarget=cashRisk*rr;
  const currentProvided=$('planCurrent').value.trim()!=='';
  if(currentProvided && direction==='long' && current<=stop){
    showPlanError('The entered current price is at or below the stop-loss. Review the trade; the protective level may already have been breached.');
    return;
  }
  if(currentProvided && direction==='short' && current>=stop){
    showPlanError('The entered current price is at or above the stop-loss. Review the trade; the protective level may already have been breached.');
    return;
  }

  let trailStop=null;
  let trailStatus='Enter a current price to calculate a trailing-stop illustration.';
  if(trailingEnabled && currentProvided){
    bestFavourablePrice=current;
    const favourable=direction==='long'?current>entry:current<entry;
    const candidate=direction==='long'?current-trailingDistance:current+trailingDistance;
    trailStop=direction==='long'?Math.max(stop,candidate):Math.min(stop,candidate);
    trailStatus=favourable
      ? 'Trailing reference set from the entered latest price. It can tighten as the market moves further in your favour.'
      : 'Price has not moved favourably beyond entry. The initial stop remains the active reference.';
  }

  latestPlan={symbol,direction,entry,stop,target,riskDistance,rewardDistance,rr,balance,riskPct,cashRisk,rewardAtTarget,trailingEnabled,trailingDistance,current:currentProvided?current:null,trailStop,trailStatus};
  const dirLabel=direction==='long'?'BUY / LONG':'SELL / SHORT';
  const trailText=trailingEnabled
    ? (trailStop===null?'Not calculated yet':fmt(trailStop))
    : 'Disabled';
  $('planResults').innerHTML=`
    <div class="result-grid">
      <div class="result-tile"><span>Trade plan</span><strong>${escapeHtml(symbol)} · ${dirLabel}</strong></div>
      <div class="result-tile"><span>Stop-loss distance</span><strong>${fmt(riskDistance)}</strong></div>
      <div class="result-tile"><span>Take-profit distance</span><strong>${fmt(rewardDistance)}</strong></div>
      <div class="result-tile"><span>Risk / reward</span><strong>1 : ${fmt(rr,2)}</strong></div>
      <div class="result-tile"><span>Cash risk budget</span><strong>R${fmt(cashRisk,2)}</strong></div>
      <div class="result-tile"><span>Illustrative reward at target</span><strong>R${fmt(rewardAtTarget,2)}</strong></div>
      <div class="result-tile"><span>Initial stop-loss</span><strong>${fmt(stop)}</strong></div>
      <div class="result-tile"><span>Take-profit</span><strong>${fmt(target)}</strong></div>
      <div class="result-tile"><span>Trailing stop</span><strong id="trailingStopValue">${trailText}</strong></div>
      <div class="result-tile"><span>Best favourable price seen</span><strong id="bestFavourableValue">${currentProvided?fmt(current):'—'}</strong></div>
    </div>
    <p class="trail-status" id="trailStatus">${escapeHtml(trailStatus)}</p>
    <div class="trail-update">
      <label>New latest price<input id="trailLatestPrice" type="number" min="0" step="any" value="${currentProvided?current:''}" placeholder="Update latest price" /></label>
      <button class="secondary" id="updateTrailing" ${trailingEnabled?'':'disabled'}>Update trailing stop</button>
    </div>
    <p class="notice">Illustrative calculations only. Cash risk is not position size or a guaranteed maximum loss. Live order sizing and stop handling require broker-specific contract, tick-value, margin and execution rules.</p>`;
  $('copyPlan').disabled=false;
  $('updateTrailing').addEventListener('click',updateTrailingStop);
}

function updateTrailingStop(){
  if(!latestPlan||!latestPlan.trailingEnabled)return;
  const latest=Number($('trailLatestPrice').value);
  if(!Number.isFinite(latest)||latest<=0){$('trailStatus').textContent='Enter a valid latest price.';return;}
  const p=latestPlan;
  if(p.direction==='long'&&latest<=p.stop){$('trailStatus').textContent='Latest price is at or below the initial stop-loss. Review the trade; no trailing update was made.';return;}
  if(p.direction==='short'&&latest>=p.stop){$('trailStatus').textContent='Latest price is at or above the initial stop-loss. Review the trade; no trailing update was made.';return;}

  if(bestFavourablePrice===null) bestFavourablePrice=latest;
  else bestFavourablePrice=p.direction==='long'?Math.max(bestFavourablePrice,latest):Math.min(bestFavourablePrice,latest);

  const movedFavourably=p.direction==='long'?bestFavourablePrice>p.entry:bestFavourablePrice<p.entry;
  const candidate=p.direction==='long'?bestFavourablePrice-p.trailingDistance:bestFavourablePrice+p.trailingDistance;
  const prior=p.trailStop===null?p.stop:p.trailStop;
  const next=p.direction==='long'?Math.max(prior,candidate):Math.min(prior,candidate);
  p.trailStop=next;
  p.current=latest;
  $('trailingStopValue').textContent=fmt(next);
  $('bestFavourableValue').textContent=fmt(bestFavourablePrice);
  $('trailStatus').textContent=movedFavourably
    ? 'Trailing stop updated from the best favourable price. The stop only tightens; it never moves backwards to increase risk.'
    : 'The market has not moved favourably beyond entry. The initial protective stop remains in place.';
}

async function copyPlan(){
  if(!latestPlan)return;
  const p=latestPlan;
  const textPlan=[
    'NEXORA MANUAL TRADE PLAN (calculation only; no order placed)',
    `Instrument: ${p.symbol}`,
    `Direction: ${p.direction==='long'?'BUY / LONG':'SELL / SHORT'}`,
    `Entry: ${p.entry}`,
    `Stop-loss: ${p.stop}`,
    `Take-profit: ${p.target}`,
    `Risk/reward: 1:${fmt(p.rr,2)}`,
    `Cash risk budget: R${fmt(p.cashRisk,2)}`,
    `Trailing stop: ${p.trailingEnabled?(p.trailStop===null?'Not yet calculated':fmt(p.trailStop)):'Disabled'}`,
    'Position quantity not calculated: broker/instrument contract specifications are required.',
    'No broker connected; no live order submitted.'
  ].join('\n');
  try{
    await navigator.clipboard.writeText(textPlan);
    $('copyPlan').textContent='Copied';
  }catch{
    showPlanError('Clipboard access is unavailable in this browser. You can select and copy the plan details manually.');
  }
}

$('sendButton').addEventListener('click',()=>{const input=$('chatInput');const q=input.value.trim();if(!q)return;addMessage(q,'user');input.value='';addMessage(answer(q),'bot')});
$('chatInput').addEventListener('keydown',e=>{if(e.key==='Enter')$('sendButton').click()});
$('calculatePlan').addEventListener('click',calculatePlan);
$('copyPlan').addEventListener('click',copyPlan);
$('balance').addEventListener('input',updateRisk);$('risk').addEventListener('input',updateRisk);
function updateRisk(){const amount=Number($('balance').value||0)*Number($('risk').value||0)/100;$('riskAmount').textContent=`R${amount.toLocaleString(undefined,{maximumFractionDigits:2})}`}

updateRisk();
refreshAutomationState();

// Automatic trading permission is server-authoritative and defaults OFF.
// Enabling this preference does not place trades: no broker or execution engine is connected.
let automationState={enabled:false,brokerConnected:false,executionAvailable:false};
async function refreshAutomationState(){
  try{
    const response=await fetch('/api/automation/status',{cache:'no-store'});
    if(!response.ok) throw new Error('Unable to read automation status');
    automationState=await response.json();
  }catch{
    automationState={enabled:false,brokerConnected:false,executionAvailable:false};
    $('automationNotice').textContent='Could not verify the server safety state. Treat automation as OFF; automatic execution remains unavailable.';
  }
  renderAutomationState();
}
function renderAutomationState(){
  const enabled=automationState.enabled===true;
  $('autoTradingToggle').checked=enabled;
  $('automationStatus').textContent=enabled?'ON · ARMED':'OFF · SAFE';
  $('automationStatus').className=enabled?'armed-pill':'safe-pill';
  $('automationModeLabel').textContent=enabled?'Automatic trading permission ON':'Manual trading only';
  $('automationModeHelp').textContent=enabled?'Permission is armed, but broker execution is not connected.':'Automatic trading is disabled.';
  $('permissionValue').textContent=enabled?'ON':'OFF';
  $('brokerValue').textContent=automationState.brokerConnected?'Connected':'Not connected';
  $('executionValue').textContent=automationState.executionAvailable?'Available':'Unavailable';
  $('headerMode').querySelector('b').textContent=enabled?'AUTOMATION ARMED':'MANUAL MODE';
  $('headerModeDetail').textContent=enabled?'Broker execution unavailable':'Automatic execution is OFF';
  $('emergencyStop').textContent=enabled?'EMERGENCY STOP · DISABLE':'EMERGENCY STOP · OFF';
  $('automationNotice').textContent=enabled
    ? 'Your permission is ON, but no broker is connected and no execution engine is available. NEXORA cannot place trades yet.'
    : 'Safety default: OFF. Automatic order requests are blocked by the server-side permission gate. Existing broker positions/orders are not affected by this prototype.';
}
async function setAutomationPermission(enabled){
  $('autoTradingToggle').disabled=true;
  $('emergencyStop').disabled=true;
  try{
    const response=await fetch('/api/automation/mode',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({enabled})});
    const result=await response.json();
    if(!response.ok) throw new Error(result.error||'Could not update automation permission');
    automationState=result;
    renderAutomationState();
  }catch(error){
    $('automationNotice').textContent=error.message+' Treat automation as OFF until the server confirms the setting.';
    await refreshAutomationState();
  }finally{
    $('autoTradingToggle').disabled=false;
    $('emergencyStop').disabled=false;
  }
}
$('autoTradingToggle').addEventListener('change',event=>setAutomationPermission(event.target.checked));
$('emergencyStop').addEventListener('click',()=>setAutomationPermission(false));



// Live Intelligence API integration. Provider-backed responses are rendered separately
// from the legacy demonstration opportunities above.
async function loadIntelligenceStatus(){
  const badge=$('intelligenceStatus');
  try{
    const r=await fetch('/api/intelligence/status',{cache:'no-store'});
    const data=await r.json();
    if(!r.ok) throw new Error(data.error||'Status unavailable');
    badge.textContent=data.marketData==='configured'?'MARKET DATA CONFIGURED':'MARKET DATA NOT CONFIGURED';
    badge.className=data.marketData==='configured'?'armed-pill':'safe-pill';
    $('liveAnalysis').innerHTML='<div class="result-grid">'+
      '<div class="result-tile"><span>Market data</span><strong>'+escapeHtml(data.marketData)+'</strong></div>'+
      '<div class="result-tile"><span>News feed</span><strong>'+escapeHtml(data.news)+'</strong></div>'+
      '<div class="result-tile"><span>Technical engine</span><strong>'+escapeHtml(data.technicalEngine)+'</strong></div>'+
      '<div class="result-tile"><span>Broker</span><strong>'+escapeHtml(data.broker)+'</strong></div></div>'+
      '<p class="notice">'+escapeHtml(data.coverage)+'</p>';
  }catch(e){badge.textContent='STATUS UNAVAILABLE';badge.className='safe-pill';}
}
let symbolSearchTimer=null;
async function searchMarketSymbols(){
 const input=$('symbolSearch'),status=$('symbolSearchStatus'),results=$('symbolMatches'),query=input.value.trim();
 if(query.length<2){results.hidden=true;status.textContent='Type at least 2 characters to search.';return;}
 status.textContent='Searching provider instruments…';
 try{
  const r=await fetch('/api/market/search?q='+encodeURIComponent(query),{cache:'no-store'}),data=await r.json();
  if(!r.ok)throw new Error(data.error||'Instrument search failed');
  results.innerHTML='';
  (data.items||[]).forEach(item=>{const option=document.createElement('option');option.value=item.symbol;option.textContent=item.symbol+' — '+item.name+' · '+[item.exchange,item.country,item.type].filter(Boolean).join(' · ');results.appendChild(option);});
  results.hidden=!(data.items||[]).length;
  status.textContent=(data.items||[]).length?data.items.length+' matches — select one below.':'No matching instruments found.';
 }catch(e){results.hidden=true;status.textContent=e.message;}
}
async function analyzeLiveMarket(){
  const button=$('analyzeLive'),out=$('liveAnalysis');
  const symbol=$('liveSymbol').value.trim(),interval=$('liveInterval').value;
  if(!symbol){out.textContent='Enter a market symbol.';return;}
  button.disabled=true;button.textContent='Analysing…';
  out.innerHTML='<div class="result-placeholder">Requesting current provider candles and calculating indicators…</div>';
  try{
    const r=await fetch('/api/signals?symbol='+encodeURIComponent(symbol)+'&interval='+encodeURIComponent(interval),{cache:'no-store'});
    const data=await r.json();if(!r.ok)throw new Error(data.error||'Analysis failed');
    const i=data.indicators||{},p=data.plan;
    out.innerHTML='<div class="result-grid">'+
      '<div class="result-tile"><span>Instrument</span><strong>'+escapeHtml(data.symbol)+'</strong></div>'+
      '<div class="result-tile"><span>Decision</span><strong>'+escapeHtml(data.direction)+'</strong></div>'+
      '<div class="result-tile"><span>Technical score</span><strong>'+escapeHtml(data.score)+' / 100</strong></div>'+
      '<div class="result-tile"><span>Latest close</span><strong>'+fmt(data.lastPrice)+'</strong></div>'+
      '<div class="result-tile"><span>Trend</span><strong>'+escapeHtml(i.trend||'—')+'</strong></div>'+
      '<div class="result-tile"><span>RSI (14)</span><strong>'+fmt(i.rsi14,2)+'</strong></div>'+
      '<div class="result-tile"><span>EMA 20 / EMA 50</span><strong>'+fmt(i.ema20)+' / '+fmt(i.ema50)+'</strong></div>'+
      '<div class="result-tile"><span>Momentum</span><strong>'+fmt(i.momentumPercent,3)+'%</strong></div>'+
      (p?'<div class="result-tile"><span>Indicative entry</span><strong>'+fmt(p.entry)+'</strong></div><div class="result-tile"><span>Indicative stop-loss</span><strong>'+fmt(p.stopLoss)+'</strong></div><div class="result-tile"><span>Indicative take-profit</span><strong>'+fmt(p.takeProfit)+'</strong></div><div class="result-tile"><span>Risk / reward</span><strong>1 : '+fmt(p.riskReward,2)+'</strong></div>':'')+
      '</div><p class="notice">'+escapeHtml(data.decision)+'</p><p class="muted">Source: '+escapeHtml(data.source)+' · '+escapeHtml(data.interval)+' · Candle: '+escapeHtml(data.timestamp||'unknown')+'</p>'+
      '<ul class="checks">'+(data.warnings||[]).map(w=>'<li>'+escapeHtml(w)+'</li>').join('')+'</ul>';
  }catch(e){out.innerHTML='<p class="form-error">'+escapeHtml(e.message)+'</p>';}
  finally{button.disabled=false;button.textContent='Analyse live market';}
}
async function loadNews(){
  const button=$('loadNews'),out=$('newsFeed');
  button.disabled=true;button.textContent='Loading…';
  try{
    const q=$('newsQuery').value.trim()||'markets OR finance';
    const r=await fetch('/api/news?q='+encodeURIComponent(q),{cache:'no-store'});
    const data=await r.json();if(!r.ok)throw new Error(data.error||'News request failed');
    const items=data.items||[];
    out.innerHTML=items.length?items.map(a=>'<div class="opp"><div class="instrument"><a href="'+escapeHtml(a.url)+'" target="_blank" rel="noopener noreferrer">'+escapeHtml(a.title)+'</a><small>'+escapeHtml(a.source)+' · '+escapeHtml(a.publishedAt||'Publication time unavailable')+'</small></div><div class="muted">News</div></div>').join(''):'<p class="muted">No matching articles were returned.</p>';
    $('newsUpdated').textContent=(data.source||'News feed')+' · '+new Date(data.retrievedAt).toLocaleTimeString()+(data.stale?' · cached':'');
  }catch(e){out.innerHTML='<p class="form-error">'+escapeHtml(e.message)+'</p>';}
  finally{button.disabled=false;button.textContent='Load news';}
}
$('analyzeLive').addEventListener('click',analyzeLiveMarket);
$('refreshIntelligence').addEventListener('click',loadIntelligenceStatus);
$('refreshLiveScan').addEventListener('click',refreshLiveScan);
$('loadNews').addEventListener('click',loadNews);
$('symbolSearch').addEventListener('input',()=>{clearTimeout(symbolSearchTimer);symbolSearchTimer=setTimeout(searchMarketSymbols,600);});
$('symbolMatches').addEventListener('change',()=>{const symbol=$('symbolMatches').value;if(symbol){$('liveSymbol').value=symbol;$('symbolSearchStatus').textContent='Selected '+symbol;$('symbolMatches').hidden=true;}});
$('liveSymbol').addEventListener('change',()=>{$('planSymbol').value=$('liveSymbol').value;});
loadIntelligenceStatus();
loadNews();
startLiveScanRefresh();
