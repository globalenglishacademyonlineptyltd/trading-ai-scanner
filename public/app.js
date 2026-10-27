const opportunities = [
  {symbol:'XAU/USD',name:'Gold',market:'gold',signal:'BUY',confidence:87,price:'4,081.20',change:'+1.18%',entry:'4,075–4,083',stop:'4,058',target:'4,118',rr:'1:2.3'},
  {symbol:'EUR/USD',name:'Euro / US Dollar',market:'forex',signal:'SELL',confidence:81,price:'1.1642',change:'-0.42%',entry:'1.1640–1.1650',stop:'1.1674',target:'1.1570',rr:'1:2.1'},
  {symbol:'USD/ZAR',name:'US Dollar / Rand',market:'forex',signal:'BUY',confidence:76,price:'17.31',change:'+0.36%',entry:'17.28–17.33',stop:'17.18',target:'17.58',rr:'1:2.4'},
  {symbol:'BTC/USD',name:'Bitcoin',market:'crypto',signal:'WAIT',confidence:64,price:'68,420',change:'+0.11%',entry:'Confirmation needed',stop:'—',target:'—',rr:'—'},
  {symbol:'NAS100',name:'Nasdaq 100',market:'indices',signal:'BUY',confidence:73,price:'24,210',change:'+0.58%',entry:'24,170–24,220',stop:'24,040',target:'24,520',rr:'1:2.2'}
];

let activeFilter='all';
const $=id=>document.getElementById(id);

function render(list=opportunities){
  $('opportunities').innerHTML=list.filter(x=>activeFilter==='all'||x.market===activeFilter).map(x=>`<div class="opp"><div class="instrument">${x.symbol}<small>${x.name}</small></div><div class="direction ${x.signal==='BUY'?'high':x.signal==='SELL'?'sell':'medium'}">${x.signal}</div><div class="confidence-number ${x.confidence>=75?'high':'medium'}">${x.confidence}%</div><div>${x.price}<small>${x.change}</small></div><div>${x.rr}<small>R:R</small></div></div>`).join('')||'<p class="muted">No opportunities in this filter.</p>';
}

function setBest(x){
  $('bestSymbol').textContent=x.symbol; $('bestSignal').textContent=x.signal; $('bestSignal').className=`signal ${x.signal==='BUY'?'buy':x.signal==='SELL'?'sell':'medium'}`;
  $('bestPrice').textContent=x.price; $('bestChange').textContent=x.change; $('bestConfidence').textContent=`${x.confidence}%`; $('confidenceBar').style.width=`${x.confidence}%`;
  $('bestEntry').textContent=x.entry; $('bestStop').textContent=x.stop; $('bestTarget').textContent=x.target; $('bestRR').textContent=x.rr;
}

function scan(){
  const ranked=[...opportunities].sort((a,b)=>b.confidence-a.confidence);
  setBest(ranked[0]);
  $('scanTime').textContent=`Last scan: ${new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'})}`;
  render();
}

function addMessage(text,type){const el=document.createElement('div');el.className=`message ${type}`;el.textContent=text;$('messages').appendChild(el);$('messages').scrollTop=$('messages').scrollHeight;}

function answer(q){
  const s=q.toLowerCase();
  if(s.includes('gold')||s.includes('xau')) return 'Gold is currently the highest-ranked setup in this prototype. The simulated model score is 87%, but this is not live market data yet. Once a live feed is connected, the robot will recalculate the setup continuously and explain the exact confirmations and invalidation level.';
  if(s.includes('compare')) return 'The current prototype ranks XAU/USD first at 87%, EUR/USD second at 81%, and USD/ZAR third at 76%. These are demonstration scores only; they are not live predictions until we connect a verified market-data feed.';
  if(s.includes('risk')||s.includes('position')) return `Your current calculator is set to R${Number($('balance').value||0).toLocaleString()} with ${$('risk').value}% risk per trade. The maximum planned risk is R${Number($('riskAmount').textContent.replace(/[^0-9.]/g,'' )||0).toLocaleString()}. Final position sizing will use the instrument's live price, contract specifications and stop distance.`;
  if(s.includes('scan')) return 'I can scan the supported market universe and rank the strongest setups. The first build is using demonstration data; live market feeds and the real analysis engine are the next integration layer.';
  if(s.includes('buy')||s.includes('sell')) return 'A BUY or SELL signal should only be produced after multiple independent confirmations agree. The production robot will also be able to return WAIT when the evidence is insufficient.';
  return 'Ask me about Gold, a specific market, the strongest setup, risk/position sizing, or say “scan everything”.';
}

$('scanButton').addEventListener('click',scan);
$('sendButton').addEventListener('click',()=>{const input=$('chatInput');const q=input.value.trim();if(!q)return;addMessage(q,'user');input.value='';setTimeout(()=>addMessage(answer(q),'bot'),250)});
$('chatInput').addEventListener('keydown',e=>{if(e.key==='Enter')$('sendButton').click()});
$('balance').addEventListener('input',updateRisk);$('risk').addEventListener('input',updateRisk);
function updateRisk(){const amount=Number($('balance').value||0)*Number($('risk').value||0)/100;$('riskAmount').textContent=`R${amount.toLocaleString(undefined,{maximumFractionDigits:2})}`}
document.querySelectorAll('.filter').forEach(btn=>btn.addEventListener('click',()=>{document.querySelectorAll('.filter').forEach(b=>b.classList.remove('active'));btn.classList.add('active');activeFilter=btn.dataset.filter;render()}));

setBest(opportunities[0]); render(); updateRisk();
