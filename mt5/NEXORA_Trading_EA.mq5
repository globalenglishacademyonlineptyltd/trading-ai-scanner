//+------------------------------------------------------------------+
//| NEXORA MT5 Trading Expert Advisor                                |
//| Manual signals by default; optional demo execution switch.        |
//| Strategy source: NEXORA server /api/mt5/signal                   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.10"
#property description "NEXORA signals and optional MT5 order execution"

#include <Trade/Trade.mqh>
CTrade trade;

input string InpNexoraBaseUrl = "https://trading-ai-scanner-production-ac73.up.railway.app";
input string InpConnectorToken = "";       // Set privately; never commit/share
input string InpProviderSymbol = ""; // Leave blank to derive the provider symbol from this chart; optional explicit override
input string InpSignalInterval = "1h";
input bool   InpEnableAutoExecution = false; // OFF by default
input double InpRiskPerTradePercent = 1.0; // Equity risk budget per automatic trade
input double InpMaxAccountRiskPercent = 3.0; // Aggregate risk cap including manual positions
input int    InpMaxOpenPositions = 3; // Account-wide NEXORA magic-number position cap
input int    InpMaxPriceDeviationPoints = 500;
input int    InpTrailingStopPoints = 300;
input int    InpTrailingStepPoints = 50;
input int    InpPollSeconds = 120; // Scan all Market Watch instruments every two minutes
input long   InpMagicNumber = 24111401;
input ENUM_TIMEFRAMES InpAnalysisTimeframe = PERIOD_CURRENT; // PERIOD_CURRENT uses the chart timeframe
input bool   InpScanChartTimeframe = true; // Keep the chart/input timeframe as an independent signal stream
input bool   InpScanM1 = false;
input bool   InpScanM5 = false;
input bool   InpScanM10 = false;
input bool   InpScanM15 = false;
input bool   InpScanM30 = false;
input bool   InpScanH1 = false;
input bool   InpScanH4 = false;
input bool   InpScanD1 = false;
input bool   InpScanW1 = false;

string g_lastSignalKey = "";
string g_processedKeys[];
int g_processedNext = 0;
datetime g_lastHeartbeat = 0;
datetime g_lastScan = 0;
string g_lastStatus = "Starting";
bool g_requestBusy = false;
string g_lastChartSymbol = "";
ENUM_TIMEFRAMES g_lastChartPeriod = PERIOD_CURRENT;

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

// Deriv synthetic indices use closed candles from the active MT5 chart.
// Other supported instruments use their mapped Twelve Data provider symbol.
bool IsDerivSyntheticSymbol(string symbol)
{
   string upper=symbol;
   StringToUpper(upper);
   string markers[9]={"VOLATILITY","STEP INDEX","BOOM","CRASH","JUMP","RANGE BREAK","DEX","DERIVED","SYNTHETIC"};
   for(int i=0;i<ArraySize(markers);i++) if(StringFind(upper,markers[i])>=0) return true;
   return false;
}
ENUM_TIMEFRAMES AnalysisTimeframe()
{
   return (InpAnalysisTimeframe==PERIOD_CURRENT?_Period:InpAnalysisTimeframe);
}
string CurrentChartInterval()
{
   return EnumToString(AnalysisTimeframe());
}
bool SignalAlreadyProcessed(string key)
{
   int count=ArraySize(g_processedKeys);
   for(int i=0;i<count;i++)
      if(g_processedKeys[i]==key) return true;
   if(count<2048)
   {
      ArrayResize(g_processedKeys,count+1);
      g_processedKeys[count]=key;
   }
   else
   {
      g_processedKeys[g_processedNext]=key;
      g_processedNext=(g_processedNext+1)%2048;
   }
   return false;
}
// Detect symbol/timeframe changes on this chart and discard the previous chart's signal state.
bool RefreshChartContext()
{
   if(g_lastChartSymbol==_Symbol && g_lastChartPeriod==_Period) return false;
   string previousSymbol=g_lastChartSymbol;
   g_lastChartSymbol=_Symbol;
   g_lastChartPeriod=_Period;
   g_lastSignalKey="";
   g_lastStatus="Loading fresh MT5 data for "+_Symbol+" ("+CurrentChartInterval()+")";
   Print("NEXORA chart context changed: ",previousSymbol," -> ",_Symbol,
         ", timeframe=",CurrentChartInterval(),". Previous signal state cleared.");
   Comment("NEXORA MT5\\n",g_lastStatus,"\\nData source: MT5 terminal chart\\nNo previous-chart signal is being carried over.");
   return true;
}
bool HttpPostJson(string url,string payload,string &body)
{
   char data[],result[];
   string responseHeaders;
   StringToCharArray(payload,data,0,WHOLE_ARRAY,CP_UTF8);
   if(ArraySize(data)>0) ArrayResize(data,ArraySize(data)-1);
   string headers="Content-Type: application/json\r\nAccept: application/json\r\nAuthorization: Bearer "+InpConnectorToken+"\r\n";
   ResetLastError();
   int code=WebRequest("POST",url,headers,15000,data,result,responseHeaders);
   if(code!=200)
   {
      g_lastStatus="Local MT5 analysis HTTP "+IntegerToString(code)+" / MT5 error "+IntegerToString(GetLastError());
      Print(g_lastStatus);
      return false;
   }
   body=CharArrayToString(result,0,WHOLE_ARRAY,CP_UTF8);
   return true;
}
bool BuildLocalCandlePayload(string symbol,ENUM_TIMEFRAMES timeframe,string &payload)
{
   MqlRates rates[];
   ArraySetAsSeries(rates,false);
   int copied=CopyRates(symbol,timeframe,1,100,rates); // closed candles only; excludes the forming bar
   if(copied<60)
   {
      g_lastStatus="Waiting for at least 60 closed candles for "+symbol;
      Print("NEXORA: ",g_lastStatus,". CopyRates=",copied);
      return false;
   }
   payload="{\"chartSymbol\":\""+symbol+"\",";
   payload+="\"interval\":\""+EnumToString(timeframe)+"\",";
   payload+="\"candles\":[";
   for(int i=0;i<copied;i++)
   {
      if(i>0) payload+=",";
      payload+="{\"time\":\""+TimeToString(rates[i].time,TIME_DATE|TIME_MINUTES)+"\",";
      payload+="\"open\":"+DoubleToString(rates[i].open,(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS))+",";
      payload+="\"high\":"+DoubleToString(rates[i].high,(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS))+",";
      payload+="\"low\":"+DoubleToString(rates[i].low,(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS))+",";
      payload+="\"close\":"+DoubleToString(rates[i].close,(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS))+",";
      payload+="\"volume\":"+IntegerToString((long)rates[i].tick_volume)+"}";
   }
   payload+="]}";
   return true;
}
bool BuildTickPayload(string symbol,string &payload)
{
   MqlTick ticks[];
   ArraySetAsSeries(ticks,false);
   ulong fromMsc=(ulong)(TimeCurrent()-900)*1000;
   int copied=CopyTicks(symbol,ticks,COPY_TICKS_INFO,fromMsc,300);
   if(copied<60) { g_lastStatus="Waiting for at least 60 recent bid/ask ticks for "+symbol; return false; }
   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   payload="{\"chartSymbol\":\""+symbol+"\",\"digits\":"+IntegerToString(digits)+",\"ticks\":[";
   int included=0;
   for(int i=0;i<copied;i++) {
      if(ticks[i].time_msc==0 || ticks[i].bid<=0 || ticks[i].ask<ticks[i].bid) continue;
      if(included>0) payload+=",";
      payload+="{\"timeMsc\":"+IntegerToString((long)ticks[i].time_msc)+",\"bid\":"+DoubleToString(ticks[i].bid,digits)+",\"ask\":"+DoubleToString(ticks[i].ask,digits)+"}";
      included++;
   }
   payload+="]}";
   if(included<60) { g_lastStatus="Fewer than 60 valid bid/ask ticks for "+symbol; return false; }
   return true;
}
string ResolveProviderSymbol()
{
   string s=_Symbol;
   string upper=s;
   StringToUpper(upper);
   if(StringFind(upper,"VOLATILITY")>=0 || StringFind(upper,"STEP INDEX")>=0 ||
      StringFind(upper,"BOOM")>=0 || StringFind(upper,"CRASH")>=0 ||
      StringFind(upper,"JUMP")>=0 || StringFind(upper,"RANGE BREAK")>=0 ||
      StringFind(upper,"DEX")>=0 || StringFind(upper,"DERIVED")>=0)
      return "";
   // Common broker suffixes are removed only for known FX/metal/crypto pairs.
   string compact=upper;
   StringReplace(compact,".","");
   StringReplace(compact,"_","");
   StringReplace(compact,"-","");
   string known[16]={"EURUSD","GBPUSD","USDJPY","USDCHF","USDCAD","AUDUSD","NZDUSD","USDZAR",
                     "EURGBP","EURJPY","GBPJPY","XAUUSD","XAGUSD","BTCUSD","ETHUSD","LTCUSD"};
   for(int i=0;i<ArraySize(known);i++)
   {
      if(StringFind(compact,known[i])==0)
         return StringSubstr(known[i],0,3)+"/"+StringSubstr(known[i],3);
   }
   // Keep plain US ticker symbols as-is; unsupported broker-specific names will be rejected by provider.
   if(StringLen(compact)>=1 && StringLen(compact)<=6 && StringFind(upper," ")<0)
      return compact;
   return "";
}
string CanonicalSymbol(string value)
{
   StringToUpper(value);
   StringReplace(value,"/","");
   StringReplace(value," ","");
   StringReplace(value,".","");
   StringReplace(value,"_","");
   StringReplace(value,"-","");
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
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) return true;
   }
   return false;
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
int VolumeDigits(double step)
{
   for(int digits=0;digits<=8;digits++)
      if(MathAbs(step-NormalizeDouble(step,digits))<1e-10) return digits;
   return 8;
}

// Broker-calculated cash risk in the account deposit currency; never guess contract values.
bool CalculateRiskLots(string symbol,string direction,double entry,double stop,
                       double &lots,double &cashRisk)
{
   lots=0.0; cashRisk=0.0;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   double minLot=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   if(equity<=0 || step<=0 || minLot<=0 || maxLot<minLot) return false;
   ENUM_ORDER_TYPE action=(direction=="BUY"?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
   double oneLotProfit=0.0;
   ResetLastError();
   if(!OrderCalcProfit(action,symbol,1.0,entry,stop,oneLotProfit))
   {
      Print("NEXORA RISK BLOCK: broker cannot calculate risk for ",symbol,
            ". Error=",GetLastError());
      return false;
   }
   double riskPerLot=MathAbs(oneLotProfit);
   if(riskPerLot<=0) return false;
   double budget=equity*InpRiskPerTradePercent/100.0;
   double rawLots=budget/riskPerLot;
   double rounded=MathFloor((MathMin(rawLots,maxLot)+1e-12)/step)*step;
   rounded=NormalizeDouble(rounded,VolumeDigits(step));
   if(rounded<minLot)
   {
      Print("NEXORA RISK BLOCK: minimum lot exceeds the configured risk budget on ",symbol,
            ". No order sent.");
      return false;
   }
   double finalProfit=0.0;
   if(!OrderCalcProfit(action,symbol,rounded,entry,stop,finalProfit)) return false;
   cashRisk=MathAbs(finalProfit);
   if(cashRisk>budget+0.01) return false;
   lots=rounded;
   return true;
}

// Includes manual and NEXORA positions. Unknown or unprotected risk blocks new entries.
bool CalculateExistingAccountRisk(double &totalRisk)
{
   totalRisk=0.0;
   // Pending orders can become exposure between checks; block until their risk is modelled.
   for(int j=OrdersTotal()-1;j>=0;j--)
   {
      ulong orderTicket=OrderGetTicket(j);
      if(orderTicket>0)
      {
         Print("NEXORA RISK BLOCK: pending order ",orderTicket,
               " exists. Manage pending orders before new automatic entries.");
         return false;
      }
   }
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      string symbol=PositionGetString(POSITION_SYMBOL);
      double volume=PositionGetDouble(POSITION_VOLUME);
      double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
      double stop=PositionGetDouble(POSITION_SL);
      long positionType=PositionGetInteger(POSITION_TYPE);
      if(stop<=0.0)
      {
         Print("NEXORA RISK BLOCK: position ",ticket," on ",symbol,
               " has no stop-loss. No new automatic entry.");
         return false;
      }
      ENUM_ORDER_TYPE action=(positionType==POSITION_TYPE_BUY?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
      double profit=0.0;
      if(!OrderCalcProfit(action,symbol,volume,openPrice,stop,profit))
      {
         Print("NEXORA RISK BLOCK: cannot calculate risk for existing position ",ticket,
               ". Error=",GetLastError());
         return false;
      }
      totalRisk+=MathMax(0.0,-profit);
   }
   return true;
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
      g_lastHeartbeat=TimeLocal();
}
void ManageTrailingStop()
{
   if(InpTrailingStopPoints<=0) return;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      string symbol=PositionGetString(POSITION_SYMBOL);
      long type=PositionGetInteger(POSITION_TYPE);
      double oldSL=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
      int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      double bid=SymbolInfoDouble(symbol,SYMBOL_BID);
      double ask=SymbolInfoDouble(symbol,SYMBOL_ASK);
      if(point<=0 || bid<=0 || ask<=0) continue;
      double distance=InpTrailingStopPoints*point;
      double step=MathMax(1,InpTrailingStepPoints)*point;
      if(type==POSITION_TYPE_BUY)
      {
         double candidate=NormalizeDouble(bid-distance,digits);
         if(candidate>0 && (oldSL==0 || candidate>oldSL+step) && candidate<bid)
            trade.PositionModify(ticket,candidate,tp);
      }
      else if(type==POSITION_TYPE_SELL)
      {
         double candidate=NormalizeDouble(ask+distance,digits);
         if(candidate>ask && (oldSL==0 || candidate<oldSL-step))
            trade.PositionModify(ticket,candidate,tp);
      }
   }
}
void ProcessSignal(string symbol,ENUM_TIMEFRAMES timeframe)
{
   if(g_requestBusy) return;
   g_requestBusy=true;
   // ALL instruments use the connected MT5 terminal as the only price-data source.
   // No Twelve Data/provider-symbol lookup is used by this Expert Advisor.
   string providerSymbol=symbol;
   string payload;
   if(!BuildLocalCandlePayload(symbol,timeframe,payload)) { g_requestBusy=false; return; }
   string json;
   string localUrl=TrimSlash(InpNexoraBaseUrl)+"/api/mt5/signal-local";
   if(!HttpPostJson(localUrl,payload,json)) { g_requestBusy=false; return; }
   string responseSymbol=JsonValue(json,"symbol");
   if(responseSymbol=="" || CanonicalSymbol(responseSymbol)!=CanonicalSymbol(providerSymbol))
   {
      g_lastStatus="Symbol mismatch blocked: chart "+symbol+", requested "+providerSymbol+", received "+responseSymbol;
      Print("NEXORA SAFETY BLOCK: ",g_lastStatus);
      Comment("NEXORA MT5\n",g_lastStatus,"\nNo alert or order generated.");
      g_requestBusy=false;
      return;
   }
   string direction=JsonValue(json,"direction");
   string signalTime=JsonValue(json,"timestamp");
   double score=JsonDouble(json,"score");
   double entry=JsonDouble(json,"entry");
   double sl=JsonDouble(json,"stopLoss");
   double tp=JsonDouble(json,"takeProfit");
   // Independent live-tick confirmation: unavailable or conflicting ticks suppress the signal.
   string tickPayload,tickJson;
   if(!BuildTickPayload(symbol,tickPayload)) { g_requestBusy=false; return; }
   string tickUrl=TrimSlash(InpNexoraBaseUrl)+"/api/mt5/signal-ticks";
   if(!HttpPostJson(tickUrl,tickPayload,tickJson)) { g_requestBusy=false; return; }
   string tickDirection=JsonValue(tickJson,"direction");
   double tickScore=JsonDouble(tickJson,"score");
   if((direction=="BUY" || direction=="SELL") && tickDirection!=direction)
   {
      g_lastStatus="WAIT: candle signal "+direction+" conflicts with tick analysis "+tickDirection+" for "+symbol;
      Print("NEXORA CONFIRMATION BLOCK: ",g_lastStatus,". Candle score=",score," tick score=",tickScore);
      g_requestBusy=false; return;
   }
   if(direction!="BUY" && direction!="SELL") { g_lastStatus="WAIT: candle engine has no trade for "+symbol; g_requestBusy=false; return; }
   Print("NEXORA dual-engine confirmation: ",symbol," ",direction," candle score=",score," tick score=",tickScore);
   // Publish only after the closed-candle and independent live-tick engines agree.
   int publishDigits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   string publishPayload="{\"symbol\":\""+symbol+"\",";
   publishPayload+="\"interval\":\""+EnumToString(timeframe)+"\",";
   publishPayload+="\"direction\":\""+direction+"\",";
   publishPayload+="\"score\":"+DoubleToString(score,0)+",";
   publishPayload+="\"tickScore\":"+DoubleToString(tickScore,0)+",";
   publishPayload+="\"timestamp\":\""+signalTime+"\",";
   publishPayload+="\"entry\":"+DoubleToString(entry,publishDigits)+",";
   publishPayload+="\"stopLoss\":"+DoubleToString(sl,publishDigits)+",";
   publishPayload+="\"takeProfit\":"+DoubleToString(tp,publishDigits)+"}";
   string publishResponse;
   if(!HttpPostJson(TrimSlash(InpNexoraBaseUrl)+"/api/mt5/signal-publish",publishPayload,publishResponse))
      Print("NEXORA: signal is confirmed locally, but website publishing failed. ",g_lastStatus);
   else
      Print("NEXORA: confirmed ",symbol," ",EnumToString(timeframe)," signal published to website.");
   string signalKey=providerSymbol+"|"+EnumToString(timeframe)+"|"+direction+"|"+signalTime;
   g_lastStatus="Scanned "+providerSymbol+" "+direction+" score "+DoubleToString(score,0);
   if(direction!="BUY" && direction!="SELL") { g_requestBusy=false; return; }
   if(SignalAlreadyProcessed(signalKey)) { g_requestBusy=false; return; }
   g_lastSignalKey=signalKey;
   Print("NEXORA signal: ",direction," ",providerSymbol," score=",score," entry=",entry," SL=",sl," TP=",tp);
   if(!InpEnableAutoExecution)
   {
      Alert("NEXORA ",direction," signal for ",providerSymbol,". Review and place manually if appropriate.");
      g_requestBusy=false;
      return;
   }
   // Automatic execution is restricted to demo accounts, even if the input is enabled.
   if((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("NEXORA SAFETY BLOCK: automatic execution is demo-account only. No live-account order sent.");
      g_requestBusy=false; return;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      Print("NEXORA: trading permissions are disabled. No order sent.");
      g_requestBusy=false; return;
   }
   if(CountOurPositions()>=InpMaxOpenPositions)
   {
      Print("NEXORA: account-wide maximum of ",InpMaxOpenPositions," NEXORA positions reached.");
      g_requestBusy=false; return;
   }
   if(IsOurPosition(symbol))
   {
      Print("NEXORA: an automatic position already exists on ",symbol,". Duplicate entry blocked.");
      g_requestBusy=false; return;
   }
   double ask=SymbolInfoDouble(symbol,SYMBOL_ASK), bid=SymbolInfoDouble(symbol,SYMBOL_BID);
   double current=(direction=="BUY"?ask:bid);
   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
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
   long stopLevel=SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
   if(MathAbs(current-sl)<stopLevel*point || MathAbs(tp-current)<stopLevel*point)
   {
      Print("NEXORA: broker minimum stop distance not satisfied.");
      g_requestBusy=false; return;
   }
   if(InpRiskPerTradePercent<=0 || InpRiskPerTradePercent>5 ||
      InpMaxAccountRiskPercent<=0 || InpMaxAccountRiskPercent>10 ||
      InpRiskPerTradePercent>InpMaxAccountRiskPercent ||
      InpMaxOpenPositions<1 || InpMaxOpenPositions>3)
   {
      Print("NEXORA RISK BLOCK: invalid risk settings.");
      g_requestBusy=false; return;
   }
   double lots=0.0, proposedRisk=0.0;
   if(!CalculateRiskLots(symbol,direction,current,sl,lots,proposedRisk))
   {
      Print("NEXORA RISK BLOCK: safe lot size unavailable. No order sent.");
      g_requestBusy=false; return;
   }
   double existingRisk=0.0;
   if(!CalculateExistingAccountRisk(existingRisk))
   {
      Print("NEXORA RISK BLOCK: existing account risk is unknown. No order sent.");
      g_requestBusy=false; return;
   }
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double accountRiskCap=equity*InpMaxAccountRiskPercent/100.0;
   if(existingRisk+proposedRisk>accountRiskCap+0.01)
   {
      Print("NEXORA RISK BLOCK: total open risk would exceed ",
            DoubleToString(InpMaxAccountRiskPercent,2),"% equity. Existing=",
            DoubleToString(existingRisk,2)," proposed=",DoubleToString(proposedRisk,2),
            " cap=",DoubleToString(accountRiskCap,2)," ",AccountInfoString(ACCOUNT_CURRENCY));
      g_requestBusy=false; return;
   }
   double marginRequired=0.0;
   ENUM_ORDER_TYPE action=(direction=="BUY"?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
   if(!OrderCalcMargin(action,symbol,lots,current,marginRequired) ||
      marginRequired>AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      Print("NEXORA RISK BLOCK: margin calculation failed or free margin is insufficient.");
      g_requestBusy=false; return;
   }
   Print("NEXORA risk sizing approved: ",symbol," ",direction,
         " lots=",DoubleToString(lots,VolumeDigits(SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP))),
         " risk=",DoubleToString(proposedRisk,2)," ",AccountInfoString(ACCOUNT_CURRENCY),
         " existing account risk=",DoubleToString(existingRisk,2));
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxPriceDeviationPoints);
   bool sent=false;
   if(direction=="BUY") sent=trade.Buy(lots,symbol,0,NormalizeDouble(sl,digits),NormalizeDouble(tp,digits),"NEXORA "+signalTime);
   else sent=trade.Sell(lots,symbol,0,NormalizeDouble(sl,digits),NormalizeDouble(tp,digits),"NEXORA "+signalTime);
   if(!sent) Print("NEXORA order rejected: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   else Print("NEXORA demo order submitted. Ticket/deal: ",trade.ResultDeal());
   g_requestBusy=false;
}
int OnInit()
{
   if(StringFind(InpNexoraBaseUrl,"https://")!=0 || StringLen(InpConnectorToken)<32)
   {
      Print("NEXORA: Set HTTPS base URL and private connector token in EA Inputs.");
      return INIT_PARAMETERS_INCORRECT;
   }
   trade.SetExpertMagicNumber(InpMagicNumber);
   g_lastChartSymbol=_Symbol;
   g_lastChartPeriod=_Period;
   EventSetTimer(15); // Frequent timer keeps the server heartbeat fresh and trailing stops responsive.
   SendHeartbeat();
   ScanMarketWatch();
   g_lastScan=TimeLocal();
   return INIT_SUCCEEDED;
}
void ScanMarketWatch()
{
   if(g_requestBusy) return;
   ENUM_TIMEFRAMES tf=AnalysisTimeframe();
   int total=SymbolsTotal(true);
   if(total<=0)
   {
      Print("NEXORA: Market Watch is empty. Add instruments in MT5 Market Watch.");
      return;
   }
   Print("NEXORA: scanning ",total," Market Watch instruments across selected independent timeframes.");
   for(int i=0;i<total;i++)
   {
      string symbol=SymbolName(i,true);
      if(symbol=="") continue;
      if(!SymbolSelect(symbol,true)) continue;
      if(InpScanChartTimeframe) ProcessSignal(symbol,tf);
      if(InpScanM1 && tf!=PERIOD_M1) ProcessSignal(symbol,PERIOD_M1);
      if(InpScanM5 && tf!=PERIOD_M5) ProcessSignal(symbol,PERIOD_M5);
      if(InpScanM10 && tf!=PERIOD_M10) ProcessSignal(symbol,PERIOD_M10);
      if(InpScanM15 && tf!=PERIOD_M15) ProcessSignal(symbol,PERIOD_M15);
      if(InpScanM30 && tf!=PERIOD_M30) ProcessSignal(symbol,PERIOD_M30);
      if(InpScanH1 && tf!=PERIOD_H1) ProcessSignal(symbol,PERIOD_H1);
      if(InpScanH4 && tf!=PERIOD_H4) ProcessSignal(symbol,PERIOD_H4);
      if(InpScanD1 && tf!=PERIOD_D1) ProcessSignal(symbol,PERIOD_D1);
      if(InpScanW1 && tf!=PERIOD_W1) ProcessSignal(symbol,PERIOD_W1);
   }
}
void OnTimer()
{
   if(RefreshChartContext()) Print("NEXORA chart changed; Market Watch scan will use selected timeframe.");
   if(TimeLocal()-g_lastHeartbeat>=30) SendHeartbeat();
   if(TimeLocal()-g_lastScan>=MathMax(120,InpPollSeconds))
   {
      ScanMarketWatch();
      g_lastScan=TimeCurrent();
   }
   ManageTrailingStop();
}
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_CHART_CHANGE && RefreshChartContext())
      ScanMarketWatch();
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}
// IMPORTANT: Auto execution is OFF by default. Test on demo only.
// This EA uses NEXORA's current rules-based technical signal API.
// Verify symbol mapping and strategy results before enabling any real account.
