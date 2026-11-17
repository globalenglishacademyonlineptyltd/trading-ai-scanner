//+------------------------------------------------------------------+
//| NEXORA MT5 ADVANCED                                        |
//| Unified tick feed plus chart-candle context in one Expert Advisor. |
//+------------------------------------------------------------------+
#property strict
#property version "2.00"
#property description "NEXORA MT5 Advanced - unified tick and candle analysis"
#include <Trade/Trade.mqh>
CTrade trade;
input string InpNexoraBaseUrl="https://trading-ai-scanner-production-ac73.up.railway.app";
input string InpConnectorToken=""; // Private; saved locally in MT5 Common Files
input bool InpEnableAutoExecution=false; // Keep OFF while validating on demo
input double InpRiskPercent=1.0;
input double InpMinimumAutoScore=70.0;
input int InpPollSeconds=120;
input int InpCooldownSeconds=300;
input int InpMaxPriceDeviationPoints=500;
input double InpMinimumExecutionRR=1.5;
input int InpTrailingStopPoints=300;
input int InpTrailingStepPoints=50;
input long InpMagicNumber=24111401;
string TOKEN_FILE="NEXORA_MT5_Connector.token", HISTORY_FILE="NEXORA_Signal_History.csv";
string candleContext="Not checked";
string token="",lastSignal="",statusText="Starting";
ulong nextScan=0,lastHeartbeat=0;
bool busy=false;
string TrimSlash(string s){while(StringLen(s)>0&&StringSubstr(s,StringLen(s)-1,1)=="/")s=StringSubstr(s,0,StringLen(s)-1);return s;}
bool LoadToken(){
 if(StringLen(InpConnectorToken)>=32){token=InpConnectorToken;int w=FileOpen(TOKEN_FILE,FILE_WRITE|FILE_TXT|FILE_COMMON);if(w==INVALID_HANDLE)return false;FileWriteString(w,token);FileClose(w);return true;}
 int r=FileOpen(TOKEN_FILE,FILE_READ|FILE_TXT|FILE_COMMON);if(r==INVALID_HANDLE)return false;token=FileReadString(r);FileClose(r);return StringLen(token)>=32;
}
string J(string body,string key){
 string n="\""+key+"\"";int p=StringFind(body,n);if(p<0)return "";p=StringFind(body,":",p+StringLen(n));if(p<0)return "";p++;while(p<StringLen(body)&&(StringGetCharacter(body,p)==' '||StringGetCharacter(body,p)=='\t'))p++;
 if(p<StringLen(body)&&StringGetCharacter(body,p)=='\"'){int e=StringFind(body,"\"",p+1);return e<0?"":StringSubstr(body,p+1,e-p-1);}
 int e=p;while(e<StringLen(body)&&StringGetCharacter(body,e)!=','&&StringGetCharacter(body,e)!='}')e++;string v=StringSubstr(body,p,e-p);StringTrimLeft(v);StringTrimRight(v);return v;
}
double JD(string b,string k){string v=J(b,k);return v==""||v=="null"?0:StringToDouble(v);}
bool Request(string method,string path,string payload,string &response){
 char data[],out[];string headersOut,headers="Accept: application/json\r\nAuthorization: Bearer "+token+"\r\n";
 if(method=="POST"){headers+="Content-Type: application/json\r\n";StringToCharArray(payload,data,0,WHOLE_ARRAY,CP_UTF8);if(ArraySize(data)>0)ArrayResize(data,ArraySize(data)-1);}
 ResetLastError();int code=WebRequest(method,TrimSlash(InpNexoraBaseUrl)+path,headers,15000,data,out,headersOut);
 if(code!=200){statusText="HTTP "+IntegerToString(code)+" / MT5 "+IntegerToString(GetLastError());Print("NEXORA request failed: ",statusText);return false;}
 response=CharArrayToString(out,0,WHOLE_ARRAY,CP_UTF8);return true;
}
bool SendHeartbeat(){
 string payload="{\"terminal_connected\":"+(TerminalInfoInteger(TERMINAL_CONNECTED)?"true":"false")+",\"trade_allowed\":"+(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)?"true":"false")+",\"account_trade_allowed\":"+(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)?"true":"false")+",\"account\":\""+IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN))+"\",\"server\":\""+AccountInfoString(ACCOUNT_SERVER)+"\",\"company\":\""+AccountInfoString(ACCOUNT_COMPANY)+"\",\"currency\":\""+AccountInfoString(ACCOUNT_CURRENCY)+"\"}";
 string response;if(!Request("POST","/api/mt5/heartbeat",payload,response))return false;lastHeartbeat=GetTickCount64();return true;
}
bool GetTickPayload(string &payload){
 MqlTick ticks[];ulong now=(ulong)TimeCurrent()*1000,from=now>600000?now-600000:0;
 int n=CopyTicks(_Symbol,ticks,COPY_TICKS_ALL,from,300);if(n<60){statusText="Waiting for 60 recent ticks ("+IntegerToString(n)+")";return false;}
 int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);payload="{\"chartSymbol\":\""+_Symbol+"\",\"digits\":"+IntegerToString(digits)+",\"ticks\":[";
 int count=0;for(int i=0;i<n;i++){if(ticks[i].bid<=0||ticks[i].ask<=0||ticks[i].ask<ticks[i].bid)continue;if(count++)payload+=",";payload+="{\"timeMsc\":"+IntegerToString((long)ticks[i].time_msc)+",\"bid\":"+DoubleToString(ticks[i].bid,digits)+",\"ask\":"+DoubleToString(ticks[i].ask,digits)+"}";}
 payload+="]}";return count>=60;
}
double LotsForRisk(ENUM_ORDER_TYPE type,double price,double sl){
 double equity=AccountInfoDouble(ACCOUNT_EQUITY),budget=equity*InpRiskPercent/100.0,one=0;if(equity<=0||budget<=0||!OrderCalcProfit(type,_Symbol,1.0,price,sl,one)||MathAbs(one)<=0)return 0;
 double raw=budget/MathAbs(one),min=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);if(step<=0||raw<min)return 0;
 double lots=MathFloor(raw/step)*step;int d=step<0.001?4:step<0.01?3:2;lots=NormalizeDouble(lots,d);double actual=0;
 if(lots<min||!OrderCalcProfit(type,_Symbol,lots,price,sl,actual)||MathAbs(actual)>budget*1.001)return 0;return lots;
}
void SaveHistory(string dir,double score,double entry,double sl,double tp,string stamp){
 int h=FileOpen(HISTORY_FILE,FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_SHARE_READ,',');if(h==INVALID_HANDLE)return;
 if(FileSize(h)==0)FileWrite(h,"Checked","Symbol","Direction","Score","Entry","SL","TP","Tick time");
 FileSeek(h,0,SEEK_END);FileWrite(h,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),_Symbol,dir,score,entry,sl,tp,stamp);FileClose(h);
}

bool BuildCandlePayload(string &payload){
 MqlRates rates[];ArraySetAsSeries(rates,false);
 int copied=CopyRates(_Symbol,_Period,1,100,rates);
 if(copied<60)return false;
 payload="{\"chartSymbol\":\""+_Symbol+"\",\"interval\":\""+EnumToString(_Period)+"\",\"candles\":[";
 for(int i=0;i<copied;i++){
  if(i>0)payload+=",";
  payload+="{\"time\":\""+TimeToString(rates[i].time,TIME_DATE|TIME_MINUTES)+"\",";
  payload+="\"open\":"+DoubleToString(rates[i].open,_Digits)+",";
  payload+="\"high\":"+DoubleToString(rates[i].high,_Digits)+",";
  payload+="\"low\":"+DoubleToString(rates[i].low,_Digits)+",";
  payload+="\"close\":"+DoubleToString(rates[i].close,_Digits)+",";
  payload+="\"volume\":"+IntegerToString((long)rates[i].tick_volume)+"}";
 }
 payload+="]}";return true;
}
void SendCandleContext(){
 string payload,json;
 if(!BuildCandlePayload(payload)){candleContext="Waiting for 60 closed candles";return;}
 if(!Request("POST","/api/mt5/signal-local",payload,json)){candleContext="Candle API unavailable";return;}
 string d=J(json,"direction");double s=JD(json,"score");
 candleContext=(d==""?"WAIT":d)+" / "+DoubleToString(s,0);
 Print("NEXORA candle context ",_Symbol," ",candleContext," (tick engine remains primary)");
}

void Scan(){
 if(busy)return;busy=true;SendCandleContext();string payload,json;if(!GetTickPayload(payload)){Comment("NEXORA MT5 ADVANCED\n",statusText,"\nCandle context: ",candleContext);busy=false;return;}
 if(!Request("POST","/api/mt5/signal-ticks",payload,json)){Comment("NEXORA MT5 ADVANCED | UPDATE FAILED\n",statusText);busy=false;return;}
 string symbol=J(json,"symbol"),dir=J(json,"direction"),stamp=J(json,"timestamp");StringToUpper(dir);
 if(symbol!=_Symbol){Print("NEXORA SAFETY BLOCK: returned symbol mismatch ",symbol);busy=false;return;}
 double score=JD(json,"score"),entry=JD(json,"entry"),sl=JD(json,"stopLoss"),tp=JD(json,"takeProfit");
 if(dir!="BUY"&&dir!="SELL"){Comment("NEXORA MT5 ADVANCED\n",_Symbol," | WAIT | Tick score ",score,"\nCandle context: ",candleContext,"\nUpdated ",TimeToString(TimeCurrent(),TIME_SECONDS),"\nAuto ",InpEnableAutoExecution?"ON":"OFF");busy=false;return;}
 if(entry<=0||sl<=0||tp<=0||(dir=="BUY"&&(sl>=entry||tp<=entry))||(dir=="SELL"&&(sl<=entry||tp>=entry))){Print("NEXORA rejected invalid tick trade plan: ",json);busy=false;return;}
 Comment("NEXORA MT5 ADVANCED\n",_Symbol," | ",dir," | Tick score ",score,"/100\nEntry ",entry," | SL ",sl," | TP ",tp,"\nAuto ",InpEnableAutoExecution?"ON":"OFF"," | Risk ",InpRiskPercent,"% | Cooldown ",InpCooldownSeconds," sec\nCandle context: ",candleContext,"\nUpdated ",TimeToString(TimeCurrent(),TIME_SECONDS));
 if(stamp!=lastSignal){lastSignal=stamp;Print("NEXORA tick signal ",_Symbol," ",dir," score ",score," entry ",entry," SL ",sl," TP ",tp);}
 SaveHistory(dir,score,entry,sl,tp,stamp);
 if(!InpEnableAutoExecution){busy=false;return;}
 double strength=dir=="SELL"?100-score:score;if(strength<InpMinimumAutoScore){Print("NEXORA auto blocked: strength below threshold");busy=false;return;}
 string cd="NEXORA_COOLDOWN_"+_Symbol;if(GlobalVariableCheck(cd)&&TimeCurrent()<(datetime)GlobalVariableGet(cd)){busy=false;return;}
 for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t>0&&PositionGetString(POSITION_SYMBOL)==_Symbol&&PositionGetInteger(POSITION_MAGIC)==InpMagicNumber){busy=false;return;}}
 double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),point=SymbolInfoDouble(_Symbol,SYMBOL_POINT),price=dir=="BUY"?ask:bid;int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
 double riskDist=MathAbs(entry-sl),allowed=MathMax(InpMaxPriceDeviationPoints*point,riskDist*.25);if(point<=0||MathAbs(price-entry)>allowed||(dir=="BUY"&&!(sl<price&&tp>price))||(dir=="SELL"&&!(sl>price&&tp<price))){Print("NEXORA auto blocked: live price invalidated plan");busy=false;return;}
 double risk=dir=="BUY"?price-sl:sl-price,reward=dir=="BUY"?tp-price:price-tp;if(risk<=0||reward/risk<InpMinimumExecutionRR){Print("NEXORA auto blocked: reward/risk too low");busy=false;return;}
 long stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);if(MathAbs(price-sl)<stops*point||MathAbs(tp-price)<stops*point){busy=false;return;}
 ENUM_ORDER_TYPE type=dir=="BUY"?ORDER_TYPE_BUY:ORDER_TYPE_SELL;double lots=LotsForRisk(type,price,sl);if(lots<=0){Print("NEXORA safety block: volume cannot meet 1% risk budget");busy=false;return;}
 trade.SetExpertMagicNumber(InpMagicNumber);trade.SetDeviationInPoints((int)MathMax(InpMaxPriceDeviationPoints,MathCeil(allowed/point)));
 bool sent=dir=="BUY"?trade.Buy(lots,_Symbol,0,NormalizeDouble(sl,digits),NormalizeDouble(tp,digits),"NEXORA tick"):trade.Sell(lots,_Symbol,0,NormalizeDouble(sl,digits),NormalizeDouble(tp,digits),"NEXORA tick");
 if(!sent)Print("NEXORA order rejected ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());else Print("NEXORA order sent ",_Symbol," ",dir," volume ",lots);
 busy=false;
}
void Trail(){
 for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)continue;string sym=PositionGetString(POSITION_SYMBOL);long type=PositionGetInteger(POSITION_TYPE);double open=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP),point=SymbolInfoDouble(sym,SYMBOL_POINT),bid=SymbolInfoDouble(sym,SYMBOL_BID),ask=SymbolInfoDouble(sym,SYMBOL_ASK);if(point<=0||sl<=0)continue;double r=MathAbs(open-sl),move=type==POSITION_TYPE_BUY?bid-open:open-ask;if(move<r)continue;double next=type==POSITION_TYPE_BUY?bid-InpTrailingStopPoints*point:ask+InpTrailingStopPoints*point;next=NormalizeDouble(next,(int)SymbolInfoInteger(sym,SYMBOL_DIGITS));if(type==POSITION_TYPE_BUY&&next>open&&next>sl+InpTrailingStepPoints*point)trade.PositionModify(t,next,tp);if(type==POSITION_TYPE_SELL&&next<open&&next<sl-InpTrailingStepPoints*point)trade.PositionModify(t,next,tp);}
}
int OnInit(){
 if(InpRiskPercent<=0||InpRiskPercent>5||InpPollSeconds<10||InpCooldownSeconds<0||InpMinimumExecutionRR<1){Print("NEXORA invalid safety inputs");return INIT_PARAMETERS_INCORRECT;}
 if(StringFind(InpNexoraBaseUrl,"https://")!=0||!LoadToken()){Print("NEXORA set HTTPS URL and private token in EA Inputs");return INIT_PARAMETERS_INCORRECT;}
 trade.SetExpertMagicNumber(InpMagicNumber);EventSetTimer(1);SendHeartbeat();Scan();nextScan=GetTickCount64()+(ulong)InpPollSeconds*1000;
 Print("NEXORA MT5 ADVANCED BUILD 2.00 | unified tick+candle | auto=",InpEnableAutoExecution?"ON":"OFF");return INIT_SUCCEEDED;
}
void OnTimer(){ulong now=GetTickCount64();if(now-lastHeartbeat>=20000)SendHeartbeat();if(now>=nextScan){Scan();nextScan=now+(ulong)InpPollSeconds*1000;}Trail();}
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result){
 if(trans.type!=TRADE_TRANSACTION_DEAL_ADD||trans.deal==0||!HistoryDealSelect(trans.deal))return;
 if((long)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagicNumber)return;long e=(long)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);if(e!=DEAL_ENTRY_OUT&&e!=DEAL_ENTRY_OUT_BY)return;
 string sym=HistoryDealGetString(trans.deal,DEAL_SYMBOL);for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t>0&&PositionGetString(POSITION_SYMBOL)==sym&&PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)return;}
 datetime until=TimeCurrent()+InpCooldownSeconds;GlobalVariableSet("NEXORA_COOLDOWN_"+sym,(double)until);Print("NEXORA re-entry cooldown until ",TimeToString(until,TIME_SECONDS));
}
void OnDeinit(const int reason){EventKillTimer();Comment("");}
