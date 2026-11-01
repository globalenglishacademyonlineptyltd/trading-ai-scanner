const opportunities = [
  {symbol:'XAU/USD',name:'Gold',market:'gold',signal:'BUY',confidence:87,price:'4,081.20',change:'+1.18%',entry:'4,075–4,083',stop:'4,058',target:'4,118',rr:'1:2.3'},
  {symbol:'EUR/USD',name:'Euro / US Dollar',market:'forex',signal:'SELL',confidence:81,price:'1.1642',change:'-0.42%',entry:'1.1640–1.1650',stop:'1.1674',target:'1.1570',rr:'1:2.1'},
  {symbol:'USD/ZAR',name:'US Dollar / Rand',market:'forex',signal:'BUY',confidence:76,price:'17.31',change:'+0.36%',entry:'17.28–17.33',stop:'17.18',target:'17.58',rr:'1:2.4'},
  {symbol:'BTC/USD',name:'Bitcoin',market:'crypto',signal:'WAIT',confidence:64,price:'68,420',change:'+0.11%',entry:'Confirmation needed',stop:'—',target:'—',rr:'—'},
  {symbol:'NAS100',name:'Nasdaq 100',market:'indices',signal:'BUY',confidence:73,price:'24,210',change:'+0.58%',entry:'24,170–24,220',stop:'24,040',target:'24,520',rr:'1:2.2'}
];

let activeFilter='all';
let latestPlan=null;
let bestFavourablePrice=null;
const $=id=>document.getElementById(id);
const fmt=(n, max=6)=>Number(n).toLocaleString(undefined,{maximumFractionDigits:max});
const escapeHtml=value=>String(value).replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));

function render(list=opportunities){
  $('opportunities').innerHTML=list.filter(x=>activeFilter==='all'||x.market===activeFilter).map(x=>`<div class="opp"><div class="instrument">${escapeHtml(x.symbol)}<small>${escapeHtml(x.name)}</small></div><div class="direction ${x.signal==='BUY'?'high':x.signal==='SELL'?'sell':'medium'}">${x.signal}</div><div class="confidence-number ${x.confidence>=75?'high':'medium'}">${x.confidence}%</div><div>${x.price}<small>${x.change}</small></div><div>${x.rr}<small>R:R</small></div></div>`).join('')||'<p class="muted">No opportunities in this filter.</p>';
}

function setBest(x){
  $('bestSymbol').textContent=x.symbol; $('bestSignal').textContent=x.signal; $('bestSignal').className=`signal ${x.signal==='BUY'?'buy':x.signal==='SELL'?'sell':'medium'}`;
  $('bestPrice').textContent=x.price; $('bestChange').textContent=x.change; $('bestConfidence').textContent=`${x.confidence}%`; $('confidenceBar').style.width=`${x.confidence}%`;
  $('bestEntry').textContent=x.entry; $('bestStop').textContent=x.stop; $('bestTarget').textContent=x.target; $('bestRR').textContent=x.rr;
}

function scan(){
  const ranked=[...opportunities].sort((a,b)=>b.confidence-a.confidence);
  setBest(ranked[0]);
  $('scanTime').textContent=`Sample scan: ${new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'})}`;
  render();
}

function addMessage(text,type){
  const el=document.createElement('div');el.className=`message ${type}`;el.textContent=text;$('messages').appendChild(el);$('messages').scrollTop=$('messages').scrollHeight;
}

function answer(q){
  const s=q.toLowerCase();
  if(s.includes('trailing')) return 'A trailing stop follows the market only when it moves in your favour. For a BUY/long position, the stop can ratchet upward as the best price rises. For a SELL/short position, it can ratchet downward as the best price falls. It must never move backwards and increase the original risk. This prototype calculates a trailing-stop illustration; it does not send broker orders.';
  if(s.includes('take profit')||s.includes('target')) return 'Take-profit is the planned exit level where the trade is intended to realise a gain. NEXORA should check that the target is on the profitable side of the entry, calculate reward relative to stop-loss risk, and support partial targets in a later full trade-management implementation.';
  if(s.includes('stop loss')||s.includes('stop-loss')) return 'A stop-loss is the protective exit level that defines where the trade idea is invalidated or the planned loss is limited. NEXORA must validate that it is on the correct side of the entry, calculate cash risk and position size using the instrument contract specifications, and account for gaps and slippage. A stop price does not guarantee an exact fill.';
  if(s.includes('gold')||s.includes('xau')) return 'Gold appears in this prototype sample list only. The displayed quote and score are demonstration data, not a live market reading or recommendation.';
  if(s.includes('risk')||s.includes('position')) return `The risk calculator shows a cash-risk budget based on your account balance and risk percentage. Safe quantity sizing also needs verified contract size, tick/pip value, account-currency conversion, fees and broker rules.`;
  if(s.includes('scan')) return 'The current scan button ranks a small hard-coded demonstration list. Global instrument discovery, live market feeds, news intelligence and production signal analysis have not yet been connected.';
  if(s.includes('buy')||s.includes('sell')) return 'A production BUY or SELL decision should require multiple independent confirmations, a valid protective stop, a defined target and passing risk checks. It must return WAIT when the evidence is insufficient.';
  return 'Ask me about stop-loss, take-profit, trailing stops, risk calculations or the sample market list. Live news, global market data and broker execution still need to be integrated.';
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

$('scanButton').addEventListener('click',scan);
$('sendButton').addEventListener('click',()=>{const input=$('chatInput');const q=input.value.trim();if(!q)return;addMessage(q,'user');input.value='';addMessage(answer(q),'bot')});
$('chatInput').addEventListener('keydown',e=>{if(e.key==='Enter')$('sendButton').click()});
$('calculatePlan').addEventListener('click',calculatePlan);
$('copyPlan').addEventListener('click',copyPlan);
$('balance').addEventListener('input',updateRisk);$('risk').addEventListener('input',updateRisk);
function updateRisk(){const amount=Number($('balance').value||0)*Number($('risk').value||0)/100;$('riskAmount').textContent=`R${amount.toLocaleString(undefined,{maximumFractionDigits:2})}`}
document.querySelectorAll('.filter').forEach(btn=>btn.addEventListener('click',()=>{document.querySelectorAll('.filter').forEach(b=>b.classList.remove('active'));btn.classList.add('active');activeFilter=btn.dataset.filter;render()}));

setBest(opportunities[0]); render(); updateRisk();
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

