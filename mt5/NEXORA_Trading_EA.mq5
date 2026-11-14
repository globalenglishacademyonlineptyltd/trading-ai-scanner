//+------------------------------------------------------------------+
//| NEXORA MT5 Trading Expert Advisor                                |
//| Manual signals by default; optional demo execution switch.        |
//| Strategy source: NEXORA server /api/mt5/signal                   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "NEXORA signals and optional MT5 order execution"

#include <Trade/Trade.mqh>
CTrade trade;

input string InpNexoraBaseUrl = "https://trading-ai-scanner-production-ac73.up.railway.app";
input string InpConnectorToken = "";       // Set privately; never commit/share
input string InpProviderSymbol = "EUR/USD"; // Must match NEXORA/Twelve Data symbol
input string InpSignalInterval = "1h";
input bool   InpEnableAutoExecution = false; // OFF by default
input double InpFixedLots = 0.01;
input int    InpMaxOpenPositions = 1;
input int    InpMaxPriceDeviationPoints = 500;
input int    InpTrailingStopPoints = 300;
input int    InpTrailingStepPoints = 50;
input int    InpPollSeconds = 60;
input long   InpMagicNumber = 24111401;

string g_lastSignalKey = "";
datetime g_lastHeartbeat = 0;
string g_lastStatus = "Starting";
bool g_requestBusy = false;

string TrimSlash(string value)
{
   while(StringLen(value)>0 && StringSubstr(value,StringLen(value)-1,1)=="/")
      value=StringSubstr(value,0,StringLen(value)-1);
   return value;
}
string EncodeSymbol(string value)
{
   StringReplace(value,"/","%2F");
   StringReplace(value," ","%20");
   return value;
}
string JsonValue(string json,string key)
{
   string needle="\""+key+"\"";
   int p=StringFind(json,needle);
   if(p<0) return "";
   p=StringFind(json,":",p+StringLen(needle));
   if(p<0) return "";
   p++;
   while(p<StringLen(json) && (StringGetCharacter(json,p)==' ' || StringGetCharacter(json,p)=='\t')) p++;
   if(p>=StringLen(json)) return "";
   if(StringGetCharacter(json,p)=='\"')
   {
      int e=StringFind(json,"\"",p+1);
      if(e<0) return "";
      return StringSubstr(json,p+1,e-p-1);
   }
   int e=p;
   while(e<StringLen(json) && StringGetCharacter(json,e)!=',' && StringGetCharacter(json,e)!='}' && StringGetCharacter(json,e)!=']') e++;
   string out=StringSubstr(json,p,e-p);
   StringTrimLeft(out); StringTrimRight(out);
   return out;
}
double JsonDouble(string json,string key)
{
   string v=JsonValue(json,key);
   if(v=="" || v=="null") return 0.0;
   return StringToDouble(v);
}
bool IsOurPosition(string symbol)
{
   if(!PositionSelect(symbol)) return false;
   return PositionGetInteger(POSITION_MAGIC)==InpMagicNumber;
}
int CountOurPositions()
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) count++;
   }
   return count;
}
double NormalizedLots(double requested)
{
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) return 0;
   double lots=MathMax(minLot,MathMin(maxLot,requested));
   lots=MathFloor(lots/step)*step;
   int digits=2;
   if(step<0.01) digits=3;
   if(step<0.001) digits=4;
   return NormalizeDouble(lots,digits);
}
bool HttpGet(string url,string &body)
{
   char data[],result[];
   string responseHeaders;
   string headers="Accept: application/json\r\nAuthorization: Bearer "+InpConnectorToken+"\r\n";
   ResetLastError();
   int code=WebRequest("GET",url,headers,10000,data,result,responseHeaders);
   if(code!=200)
   {
      g_lastStatus="NEXORA HTTP "+IntegerToString(code)+" / MT5 error "+IntegerToString(GetLastError());
      Print(g_lastStatus);
      return false;
   }
   body=CharArrayToString(result,0,WHOLE_ARRAY,CP_UTF8);
   return true;
}
bool HttpPost(string url,string payload)
{
   char data[],result[];
   string responseHeaders;
   StringToCharArray(payload,data,0,WHOLE_ARRAY,CP_UTF8);
   if(ArraySize(data)>0) ArrayResize(data,ArraySize(data)-1);
   string headers="Content-Type: application/json\r\nAuthorization: Bearer "+InpConnectorToken+"\r\n";
   ResetLastError();
   int code=WebRequest("POST",url,headers,10000,data,result,responseHeaders);
   if(code!=200)
   {
      Print("NEXORA heartbeat HTTP ",code," MT5 error ",GetLastError());
      return false;
   }
   return true;
}
string MaskLogin(long login)
{
   string value=IntegerToString(login);
   int n=StringLen(value);
   if(n<=4) return "****";
   return StringSubstr(value,0,2)+"****"+StringSubstr(value,n-2,2);
}
void SendHeartbeat()
{
   string account=MaskLogin((long)AccountInfoInteger(ACCOUNT_LOGIN));
   string payload="{\"account\":\""+account+"\",";
   payload+="\"server\":\""+AccountInfoString(ACCOUNT_SERVER)+"\",";
   payload+="\"company\":\""+AccountInfoString(ACCOUNT_COMPANY)+"\",";
   payload+="\"currency\":\""+AccountInfoString(ACCOUNT_CURRENCY)+"\",";
   payload+="\"terminal_connected\":"+(TerminalInfoInteger(TERMINAL_CONNECTED)?"true":"false")+",";
   payload+="\"trade_allowed\":"+(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)?"true":"false")+",";
   payload+="\"account_trade_allowed\":"+(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)?"true":"false")+"}";
   if(HttpPost(TrimSlash(InpNexoraBaseUrl)+"/api/mt5/heartbeat",payload))
      g_lastHeartbeat=TimeCurrent();
}
void ManageTrailingStop()
{
   if(InpTrailingStopPoints<=0 || !IsOurPosition(_Symbol)) return;
   long type=PositionGetInteger(POSITION_TYPE);
   double oldSL=PositionGetDouble(POSITION_SL);
   double tp=PositionGetDouble(POSITION_TP);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double distance=InpTrailingStopPoints*point;
   double step= MathMax(1,InpTrailingStepPoints)*point;
   if(type==POSITION_TYPE_BUY)
   {
      double candidate=NormalizeDouble(bid-distance,digits);
      if(candidate>0 && (oldSL==0 || candidate>oldSL+step) && candidate<bid)
         trade.PositionModify(_Symbol,candidate,tp);
   }
   else if(type==POSITION_TYPE_SELL)
   {
      double candidate=NormalizeDouble(ask+distance,digits);
      if(candidate>ask && (oldSL==0 || candidate<oldSL-step))
         trade.PositionModify(_Symbol,candidate,tp);
   }
}
void ProcessSignal()
{
   if(g_requestBusy) return;
   g_requestBusy=true;
   string url=TrimSlash(InpNexoraBaseUrl)+"/api/mt5/signal?symbol="+EncodeSymbol(InpProviderSymbol)+"&interval="+InpSignalInterval;
   string json;
   if(!HttpGet(url,json)) { g_requestBusy=false; return; }
   string direction=JsonValue(json,"direction");
   string signalTime=JsonValue(json,"timestamp");
   double score=JsonDouble(json,"score");
   double entry=JsonDouble(json,"entry");
   double sl=JsonDouble(json,"stopLoss");
   double tp=JsonDouble(json,"takeProfit");
   string signalKey=InpProviderSymbol+"|"+direction+"|"+signalTime;
   g_lastStatus="Signal "+direction+" score "+DoubleToString(score,0);
   Comment("NEXORA MT5\n",g_lastStatus,"\nMode: ",InpEnableAutoExecution?"AUTOMATIC":"MANUAL (signals only)","\nProvider symbol: ",InpProviderSymbol,"\nLast signal: ",signalTime);
   if(direction!="BUY" && direction!="SELL") { g_requestBusy=false; return; }
   if(signalKey==g_lastSignalKey) { g_requestBusy=false; return; }
   g_lastSignalKey=signalKey;
   Print("NEXORA signal: ",direction," ",InpProviderSymbol," score=",score," entry=",entry," SL=",sl," TP=",tp);
   if(!InpEnableAutoExecution)
   {
      Alert("NEXORA ",direction," signal for ",InpProviderSymbol,". Review and place manually if appropriate.");
      g_requestBusy=false;
      return;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      Print("NEXORA: trading permissions are disabled. No order sent.");
      g_requestBusy=false; return;
   }
   if(CountOurPositions()>=InpMaxOpenPositions)
   {
      Print("NEXORA: maximum open position limit reached.");
      g_requestBusy=false; return;
   }
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double current=(direction=="BUY"?ask:bid);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   if(entry<=0 || sl<=0 || tp<=0 || point<=0)
   {
      Print("NEXORA: signal has no valid entry/SL/TP. No order sent.");
      g_requestBusy=false; return;
   }
   if(MathAbs(current-entry)/point>InpMaxPriceDeviationPoints)
   {
      Print("NEXORA: price moved beyond configured deviation. No order sent.");
      g_requestBusy=false; return;
   }
   if(direction=="BUY" && !(sl<current && tp>current))
   {
      Print("NEXORA: BUY stop/target invalid for current price.");
      g_requestBusy=false; return;
   }
   if(direction=="SELL" && !(sl>current && tp<current))
   {
      Print("NEXORA: SELL stop/target invalid for current price.");
      g_requestBusy=false; return;
   }
   long stopLevel=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   if(MathAbs(current-sl)<stopLevel*point || MathAbs(tp-current)<stopLevel*point)
   {
      Print("NEXORA: broker minimum stop distance not satisfied.");
      g_requestBusy=false; return;
   }
   double lots=NormalizedLots(InpFixedLots);
   if(lots<=0) { Print("NEXORA: invalid volume step."); g_requestBusy=false; return; }
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   bool sent=false;
   if(direction=="BUY") sent=trade.Buy(lots,_Symbol,0,NormalizeDouble(sl,digits),NormalizeDouble(tp,digits),"NEXORA "+signalTime);
   else sent=trade.Sell(lots,_Symbol,0,NormalizeDouble(sl,digits),NormalizeDouble(tp,digits),"NEXORA "+signalTime);
   if(!sent) Print("NEXORA order rejected: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   else Print("NEXORA demo order submitted. Ticket/deal: ",trade.ResultDeal());
   g_requestBusy=false;
}
int OnInit()
{
   if(StringFind(InpNexoraBaseUrl,"https://")!=0 || StringLen(InpConnectorToken)<24)
   {
      Print("NEXORA: Set HTTPS base URL and private connector token in EA Inputs.");
      return INIT_PARAMETERS_INCORRECT;
   }
   trade.SetExpertMagicNumber(InpMagicNumber);
   EventSetTimer(MathMax(15,InpPollSeconds));
   SendHeartbeat();
   ProcessSignal();
   return INIT_SUCCEEDED;
}
void OnTimer()
{
   if(TimeCurrent()-g_lastHeartbeat>=30) SendHeartbeat();
   ProcessSignal();
   ManageTrailingStop();
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}
// IMPORTANT: Auto execution is OFF by default. Test on demo only.
// This EA uses NEXORA's current rules-based technical signal API.
// Verify symbol mapping and strategy results before enabling any real account.
