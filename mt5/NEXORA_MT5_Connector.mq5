//+------------------------------------------------------------------+
//| NEXORA MT5 Trading Expert Advisor                                |
//| Manual signals by default; optional demo execution switch.        |
//| Strategy source: NEXORA server /api/mt5/signal                   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.10"
#define NEXORA_BUILD_ID "2026.11.17-5TF-INDIE-COOLDOWN-FIX"
#property description "NEXORA signals and optional MT5 order execution"

#include <Trade/Trade.mqh>
CTrade trade;

input string InpNexoraBaseUrl = "https://trading-ai-scanner-production-ac73.up.railway.app";
input string InpConnectorToken = "";       // Set privately; never commit/share
input string InpProviderSymbol = ""; // Leave blank to derive the provider symbol from this chart; optional explicit override
input string InpSignalInterval = "1h";
input bool   InpEnableAutoExecution = false; // OFF by default
input double InpRiskPercent = 1.0; // Risk budget as % of account equity, calculated from entry-to-stop loss
input int    InpMaxOpenPositions = 5; // Up to one independently managed position per timeframe
input int    InpMaxPriceDeviationPoints = 500;
input int    InpTrailingStopPoints = 300;
input int    InpTrailingStepPoints = 50;
input int    InpPollSeconds = 120; // Refresh signals every 2 minutes
input double InpMinimumAutoScore = 70.0; // Minimum technical score for automatic entries
input int    InpTradeCooldownSeconds = 300; // Per-timeframe cooldown after a position closes
input long   InpMagicNumber = 24111401;

string g_lastSignalKey = "";
string g_lastSignalKeys[5];
ENUM_TIMEFRAMES g_activeTimeframe=PERIOD_M5;
ENUM_TIMEFRAMES g_scanFrames[5]={PERIOD_M5,PERIOD_M15,PERIOD_M30,PERIOD_H1,PERIOD_H4};
string g_scanLabels[5]={"M5","M15","M30","H1","H4"};
string g_connectorToken = "";
ulong g_nextSignalCheckMs = 0;
const string NEXORA_TOKEN_FILE = "NEXORA_MT5_Connector.token";
const string NEXORA_HISTORY_FILE = "NEXORA_Signal_History.csv";
ulong g_lastHeartbeatMs = 0;
string g_lastStatus = "Starting";
string g_lastRefreshText = "Not refreshed yet";
bool g_requestBusy = false;
string g_lastChartSymbol = "";
ENUM_TIMEFRAMES g_lastChartPeriod = PERIOD_CURRENT;


bool LoadConnectorToken()
{
   // A token entered in Inputs is remembered locally for other charts on this PC.
   if(StringLen(InpConnectorToken)>=32)
   {
      g_connectorToken=InpConnectorToken;
      int writeHandle=FileOpen(NEXORA_TOKEN_FILE,FILE_WRITE|FILE_TXT|FILE_COMMON);
      if(writeHandle==INVALID_HANDLE)
      {
         Print("NEXORA ERROR: Could not save connector token in MT5 Common Files. Error ",GetLastError());
         return false;
      }
      FileWriteString(writeHandle,g_connectorToken);
      FileClose(writeHandle);
      return true;
   }
   int readHandle=FileOpen(NEXORA_TOKEN_FILE,FILE_READ|FILE_TXT|FILE_COMMON);
   if(readHandle==INVALID_HANDLE)
   {
      Print("NEXORA: No saved connector token found. Enter it once in EA Inputs.");
      return false;
   }
   g_connectorToken=FileReadString(readHandle);
   FileClose(readHandle);
   if(StringLen(g_connectorToken)<32)
   {
      g_connectorToken="";
      Print("NEXORA: Saved connector token is invalid. Re-enter it in EA Inputs.");
      return false;
   }
   return true;
}
string AlertCooldownVariable()
{
   string key="NEXORA_ALERT_"+_Symbol+"_"+EnumToString(g_activeTimeframe);
   if(StringLen(key)>63) key=StringSubstr(key,0,63);
   return key;
}
void AppendSignalHistory(string direction,double score,double entry,double sl,double tp,string signalTime,bool notificationSent)
{
   int handle=FileOpen(NEXORA_HISTORY_FILE,FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_SHARE_READ,',');
   if(handle==INVALID_HANDLE)
   {
      Print("NEXORA: Could not open signal history file. Error ",GetLastError());
      return;
   }
   if(FileSize(handle)==0)
      FileWrite(handle,"Check time","Chart symbol","Timeframe","Direction","Score","Entry","Stop loss","Take profit","Signal candle time","Alert cooldown eligible");
   FileSeek(handle,0,SEEK_END);
   FileWrite(handle,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),_Symbol,EnumToString(g_activeTimeframe),
             direction,DoubleToString(score,1),DoubleToString(entry,_Digits),
             DoubleToString(sl,_Digits),DoubleToString(tp,_Digits),signalTime,
              notificationSent?"YES - alert permitted":"NO - alert cooldown active");
   FileClose(handle);
}

string TrimSlash(string value)
{
   while(StringLen(value)>0 && StringSubstr(value,StringLen(value)-1,1)=="/")
      value=StringSubstr(value,0,StringLen(value)-1);
   return value;
}
string CurrentChartInterval()
{
   return EnumToString(g_activeTimeframe);
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
   Comment("NEXORA MT5\n",g_lastStatus,"\nData source: MT5 terminal chart\nNo previous-chart signal is being carried over.");
   return true;
}
bool HttpPostJson(string url,string payload,string &body)
{
   char data[],result[];
   string responseHeaders;
   StringToCharArray(payload,data,0,WHOLE_ARRAY,CP_UTF8);
   if(ArraySize(data)>0) ArrayResize(data,ArraySize(data)-1);
   string headers="Content-Type: application/json\r\nAccept: application/json\r\nAuthorization: Bearer "+g_connectorToken+"\r\n";
   ResetLastError();
   int code=WebRequest("POST",url,headers,15000,data,result,responseHeaders);
   if(code!=200)
   {
      g_lastStatus="Refresh failed: HTTP "+IntegerToString(code)+" / MT5 error "+IntegerToString(GetLastError());
      Print("NEXORA ",g_lastStatus);
      Comment("NEXORA UPDATE | ",TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
              "\n",g_lastStatus,"\nPrevious signal is not being presented as a fresh update.");
      return false;
   }
   body=CharArrayToString(result,0,WHOLE_ARRAY,CP_UTF8);
   return true;
}
bool BuildLocalCandlePayload(string &payload)
{
   MqlRates rates[];
   ArraySetAsSeries(rates,false);
   int copied=CopyRates(_Symbol,g_activeTimeframe,1,100,rates); // closed candles only; excludes the forming bar
   if(copied<60)
   {
      g_lastStatus="Waiting for at least 60 closed chart candles for "+_Symbol;
      Print("NEXORA: ",g_lastStatus,". CopyRates=",copied);
      return false;
   }
   payload="{\"chartSymbol\":\""+_Symbol+"\",";
   payload+="\"interval\":\""+CurrentChartInterval()+"\",";
   payload+="\"candles\":[";
   for(int i=0;i<copied;i++)
   {
      if(i>0) payload+=",";
      payload+="{\"time\":\""+TimeToString(rates[i].time,TIME_DATE|TIME_MINUTES)+"\",";
      payload+="\"open\":"+DoubleToString(rates[i].open,_Digits)+",";
      payload+="\"high\":"+DoubleToString(rates[i].high,_Digits)+",";
      payload+="\"low\":"+DoubleToString(rates[i].low,_Digits)+",";
      payload+="\"close\":"+DoubleToString(rates[i].close,_Digits)+",";
      payload+="\"volume\":"+IntegerToString((long)rates[i].tick_volume)+"}";
   }
   payload+="]}";
   return true;
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
bool IsOurMagic(long magic)
{
   if(magic==InpMagicNumber) return true;
   for(int i=0;i<5;i++)
      if(magic==InpMagicNumber+(long)g_scanFrames[i]) return true;
   return false;
}
bool IsOurPosition(string symbol)
{
   if(!PositionSelect(symbol)) return false;
   return IsOurMagic(PositionGetInteger(POSITION_MAGIC));
}
int CountOurPositions(string symbol)
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionGetString(POSITION_SYMBOL)==symbol &&
         IsOurMagic(PositionGetInteger(POSITION_MAGIC))) count++;
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
   string headers="Accept: application/json\r\nAuthorization: Bearer "+g_connectorToken+"\r\n";
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
   string headers="Content-Type: application/json\r\nAuthorization: Bearer "+g_connectorToken+"\r\n";
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
      g_lastHeartbeatMs=GetTickCount64();
}
void ManageTrailingStop()
{
   if(InpTrailingStopPoints<=0) return;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      string symbol=PositionGetString(POSITION_SYMBOL);
      long magic=PositionGetInteger(POSITION_MAGIC);
      if(!IsOurMagic(magic)) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      double oldSL=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
      double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
      int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      double bid=SymbolInfoDouble(symbol,SYMBOL_BID);
      double ask=SymbolInfoDouble(symbol,SYMBOL_ASK);
      if(point<=0 || openPrice<=0) continue;
      string riskKey="NEXORA_RISK_"+IntegerToString((long)ticket);
      double initialRisk=0.0;
      if(GlobalVariableCheck(riskKey)) initialRisk=GlobalVariableGet(riskKey);
      else if(oldSL>0)
      {
         initialRisk=MathAbs(openPrice-oldSL);
         if(initialRisk>0) GlobalVariableSet(riskKey,initialRisk);
      }
      if(initialRisk<=0) continue;
      double favourableMove=(type==POSITION_TYPE_BUY)?bid-openPrice:openPrice-ask;
      if(favourableMove<initialRisk) continue; // Activate only after +1R.
      double distance=InpTrailingStopPoints*point;
      double step=MathMax(1,InpTrailingStepPoints)*point;
      if(type==POSITION_TYPE_BUY)
      {
         double candidate=NormalizeDouble(bid-distance,digits);
         if(candidate>openPrice && (oldSL==0 || candidate>oldSL+step) && candidate<bid)
         {
            if(!trade.PositionModify(ticket,candidate,tp))
               Print("NEXORA trailing-stop update failed for ",symbol," ticket ",ticket,": ",
                     trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
         }
      }
      else if(type==POSITION_TYPE_SELL)
      {
         double candidate=NormalizeDouble(ask+distance,digits);
         if(candidate<openPrice && (oldSL==0 || candidate<oldSL-step) && candidate>ask)
         {
            if(!trade.PositionModify(ticket,candidate,tp))
               Print("NEXORA trailing-stop update failed for ",symbol," ticket ",ticket,": ",
                     trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
         }
      }
   }
}
// Return BUY/SELL only when EMA trend, closed-candle price, RSI and momentum agree.
string LocalTimeframeDirection(ENUM_TIMEFRAMES timeframe)
{
   MqlRates rates[];
   ArraySetAsSeries(rates,false);
   if(CopyRates(_Symbol,timeframe,1,60,rates)<60) return "WAIT";
   int fastHandle=iMA(_Symbol,timeframe,20,0,MODE_EMA,PRICE_CLOSE);
   int slowHandle=iMA(_Symbol,timeframe,50,0,MODE_EMA,PRICE_CLOSE);
   int rsiHandle=iRSI(_Symbol,timeframe,14,PRICE_CLOSE);
   if(fastHandle==INVALID_HANDLE || slowHandle==INVALID_HANDLE || rsiHandle==INVALID_HANDLE)
   {
      if(fastHandle!=INVALID_HANDLE) IndicatorRelease(fastHandle);
      if(slowHandle!=INVALID_HANDLE) IndicatorRelease(slowHandle);
      if(rsiHandle!=INVALID_HANDLE) IndicatorRelease(rsiHandle);
      return "WAIT";
   }
   double fast[1],slow[1],rsiValue[1];
   bool copied=(CopyBuffer(fastHandle,0,1,1,fast)==1 &&
                CopyBuffer(slowHandle,0,1,1,slow)==1 &&
                CopyBuffer(rsiHandle,0,1,1,rsiValue)==1);
   IndicatorRelease(fastHandle);
   IndicatorRelease(slowHandle);
   IndicatorRelease(rsiHandle);
   if(!copied) return "WAIT";
   int last=ArraySize(rates)-1;
   if(last<1) return "WAIT";
   double closeNow=rates[last].close;
   double closePrior=rates[last-1].close;
   if(fast[0]>slow[0] && closeNow>fast[0] && closeNow>closePrior &&
      rsiValue[0]>50.0 && rsiValue[0]<70.0) return "BUY";
   if(fast[0]<slow[0] && closeNow<fast[0] && closeNow<closePrior &&
      rsiValue[0]<50.0 && rsiValue[0]>30.0) return "SELL";
   return "WAIT";
}
bool ConfirmAllTimeframes(string direction,string &details)
{
   // Six-timeframe confirmation: every timeframe must agree with the chart's primary signal.
   ENUM_TIMEFRAMES frames[5]={PERIOD_M5,PERIOD_M15,PERIOD_M30,PERIOD_H1,PERIOD_H4};
   string labels[5]={"M5","M15","M30","H1","H4"};
   details="";
   for(int i=0;i<5;i++)
   {
      string found=LocalTimeframeDirection(frames[i]);
      if(details!="") details+=" | ";
      details+=labels[i]+":"+found;
      if(found!=direction) return false;
   }
   return true;
}
void ProcessSignal()
{
   if(g_requestBusy) return;
   g_requestBusy=true;
   // ALL instruments use the connected MT5 terminal as the only price-data source.
   // No Twelve Data/provider-symbol lookup is used by this Expert Advisor.
   string providerSymbol=_Symbol;
   string payload;
   if(!BuildLocalCandlePayload(payload))
   {
      Comment("NEXORA UPDATE | ",TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
              "\nRefresh unavailable: ",g_lastStatus);
      g_requestBusy=false; return;
   }
   string json;
   string localUrl=TrimSlash(InpNexoraBaseUrl)+"/api/mt5/signal-local";
   if(!HttpPostJson(localUrl,payload,json)) { g_requestBusy=false; return; }
   g_lastRefreshText=TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS);
   string responseSymbol=JsonValue(json,"symbol");
   if(responseSymbol=="" || CanonicalSymbol(responseSymbol)!=CanonicalSymbol(providerSymbol))
   {
      g_lastStatus="Symbol mismatch blocked: chart "+_Symbol+", requested "+providerSymbol+", received "+responseSymbol;
      Print("NEXORA SAFETY BLOCK: ",g_lastStatus);
      Comment("NEXORA MT5\n",g_lastStatus,"\nNo alert or order generated.");
      g_requestBusy=false;
      return;
   }
   // Parse all response fields before branching. WAIT legitimately has null trade levels.
   string direction=JsonValue(json,"direction");
   StringTrimLeft(direction); StringTrimRight(direction); StringToUpper(direction);
   string signalTime=JsonValue(json,"timestamp");
   double score=JsonDouble(json,"score");
   double entry=JsonDouble(json,"entry");
   double sl=JsonDouble(json,"stopLoss");
   double tp=JsonDouble(json,"takeProfit");
   string interval=CurrentChartInterval();
   int timeframeIndex=-1;
   for(int ti=0;ti<5;ti++) if(g_scanFrames[ti]==g_activeTimeframe) timeframeIndex=ti;
   if(timeframeIndex<0) { g_requestBusy=false; return; }
   if(direction!="BUY" && direction!="SELL")
   {
      Comment("NEXORA UPDATE | ",g_lastRefreshText,"\\nNEXORA TIMEFRAME SIGNAL\\nInstrument: ",_Symbol," | Timeframe: ",interval,
              "\\nSignal: WAIT | Technical score: ",DoubleToString(score,0),"/100",
              "\\nAnalysed closed candle: ",signalTime,
              "\\nNo trade proposed. Entry, stop loss and take profit are not applicable to WAIT.");
      Print("NEXORA | ",_Symbol," ",interval," | WAIT ",DoubleToString(score,0),"/100",
            " | E -- SL -- TP -- | NO TRADE");
      g_requestBusy=false; return;
   }
   string signalKey=providerSymbol+"|"+interval+"|"+direction+"|"+signalTime;
   double riskDistance=(entry>0 && sl>0)?MathAbs(entry-sl):0;
   // Current server plan sets SL at 1.5 x average candle range; derive the range from returned SL.
   double avgRange=(riskDistance>0)?riskDistance/1.5:0;
   double rewardDistance=(entry>0 && tp>0)?MathAbs(tp-entry):0;
   double rr=(riskDistance>0)?rewardDistance/riskDistance:0;
   string planRejectReason="";
   if(direction!="BUY" && direction!="SELL") planRejectReason="direction is not BUY or SELL";
   else if(!MathIsValidNumber(entry) || entry<=0) planRejectReason="entry missing or not numeric";
   else if(!MathIsValidNumber(sl) || sl<=0) planRejectReason="stop loss missing or not numeric";
   else if(!MathIsValidNumber(tp) || tp<=0) planRejectReason="take profit missing or not numeric";
   else if(direction=="BUY" && sl>=entry) planRejectReason="BUY stop loss must be below entry";
   else if(direction=="BUY" && tp<=entry) planRejectReason="BUY take profit must be above entry";
   else if(direction=="SELL" && sl<=entry) planRejectReason="SELL stop loss must be above entry";
   else if(direction=="SELL" && tp>=entry) planRejectReason="SELL take profit must be below entry";
   bool validPlan=(planRejectReason=="");
   if(validPlan)
      Print("NEXORA PLAN ACCEPTED: ",_Symbol," ",interval," ",direction,
            " | E ",DoubleToString(entry,_Digits)," SL ",DoubleToString(sl,_Digits),
            " TP ",DoubleToString(tp,_Digits));
   if(!validPlan)
      Print("NEXORA PLAN REJECT REASON: ",planRejectReason,
            " | raw direction=",JsonValue(json,"direction"),
            " | raw entry=",JsonValue(json,"entry"),
            " | raw SL=",JsonValue(json,"stopLoss"),
            " | raw TP=",JsonValue(json,"takeProfit"),
            " | parsed E=",DoubleToString(entry,_Digits),
            " SL=",DoubleToString(sl,_Digits)," TP=",DoubleToString(tp,_Digits),
            " | JSON=",json);
   double trailActivation=0;
   if(validPlan) trailActivation=(direction=="BUY")?entry+riskDistance:entry-riskDistance;
   string panel="NEXORA UPDATE | "+g_lastRefreshText+"\n";
   panel+="NEXORA TRADE PLAN\n";
   panel+="Instrument: "+_Symbol+" | Timeframe: "+interval+"\n";
   panel+="Signal: "+direction+" | Technical score: "+DoubleToString(score,0)+"/100\n";
   panel+="Analysed closed candle: "+signalTime+"\n";
   panel+="Entry: "+(validPlan?DoubleToString(entry,_Digits):"NOT AVAILABLE")+"\n";
   panel+="Stop loss: "+(validPlan?DoubleToString(sl,_Digits):"NOT AVAILABLE")+"\n";
   panel+="Take profit: "+(validPlan?DoubleToString(tp,_Digits):"NOT AVAILABLE")+"\n";
   panel+="Risk distance: "+(validPlan?DoubleToString(riskDistance,_Digits):"N/A")+" | Reward/Risk: "+(validPlan?DoubleToString(rr,2):"N/A")+"\n";
   panel+="Trailing stop: start after +1R at "+(validPlan?DoubleToString(trailActivation,_Digits):"N/A")+"\n";
   panel+="Trailing distance: "+IntegerToString(InpTrailingStopPoints)+" points; activation after +1R\n";
   panel+="Method: EMA20/EMA50 + RSI14 + momentum | closed candles only\n";
   panel+="Auto position sizing: "+DoubleToString(InpRiskPercent,2)+"% equity risk; calculated against stop loss when auto mode is enabled\n";
   panel+=InpEnableAutoExecution?"AUTOMATIC MODE - currently configured; demo testing only":"MANUAL MODE - no order will be placed";
   panel+="\\nIndependent timeframe scan: "+interval+" | AUTO threshold: "+DoubleToString(InpMinimumAutoScore,0)+"/100";
   panel+="\nBUILD: "+NEXORA_BUILD_ID;
   Comment(panel);
   Print("NEXORA BUILD: ",NEXORA_BUILD_ID);
   Print("NEXORA | ",_Symbol," ",interval," | ",direction," ",DoubleToString(score,0),"/100",
         " | E ",DoubleToString(entry,_Digits),
         " SL ",DoubleToString(sl,_Digits),
         " TP ",DoubleToString(tp,_Digits),
         " | AUTO ",InpEnableAutoExecution?"ON":"OFF");

   // Independent timeframe mode: no cross-timeframe agreement gate.\n   if(!validPlan)
   {
      g_lastStatus="INVALID TRADE PLAN - levels failed validation";
      Comment("NEXORA UPDATE | ",g_lastRefreshText,"\nNEXORA SAFETY WARNING\n",_Symbol," | ",interval,"\nSignal: ",direction,
              " | Score: ",DoubleToString(score,0),"/100",
              "\nEntry/SL/TP levels are invalid or incomplete. Do not trade.",
              "\nAnalysed candle: ",signalTime);
      Print("NEXORA | ",_Symbol," ",interval," | REJECTED INVALID PLAN: ",planRejectReason,
            " | E ",DoubleToString(entry,_Digits),
            " SL ",DoubleToString(sl,_Digits),
            " TP ",DoubleToString(tp,_Digits),
            " | NO ORDER");
      g_requestBusy=false; return;
   }
   bool newSignal=(signalKey!=g_lastSignalKeys[timeframeIndex]);
   if(newSignal)
   {
      g_lastSignalKeys[timeframeIndex]=signalKey;
      g_lastSignalKey=signalKey;
      Print("NEXORA signal: ",direction," ",providerSymbol," score=",score," entry=",entry," SL=",sl," TP=",tp);
   }
   string cooldownName=AlertCooldownVariable();
   datetime lastAlert=0;
   if(GlobalVariableCheck(cooldownName)) lastAlert=(datetime)GlobalVariableGet(cooldownName);
   bool notifyUser=(lastAlert==0 || TimeCurrent()-lastAlert>=600);
   if(notifyUser)
   {
      GlobalVariableSet(cooldownName,(double)TimeCurrent());
      // Desktop pop-ups are disabled; the full trade plan is displayed on the chart.
   }
   else
      Print("NEXORA: signal for ",providerSymbol," logged; repeat alert suppressed by the 10-minute alert limit.");
   AppendSignalHistory(direction,score,entry,sl,tp,signalTime,notifyUser);
   if(!InpEnableAutoExecution)
   {
      g_requestBusy=false;
      return;
   }
   // Do not suppress an unchanged but still-valid setup forever. The per-timeframe cooldown
   // and existing-position check below prevent premature duplicate entries; after cooldown,
   // the same setup may be traded again if it still passes all checks.
   double directionalStrength=(direction=="SELL")?100.0-score:score;
   if(directionalStrength<InpMinimumAutoScore)
   {
      Print("NEXORA AUTO BLOCK: ",_Symbol," ",interval," directional strength ",DoubleToString(directionalStrength,1),
            "/100 (raw technical score ",DoubleToString(score,1),") is below minimum ",DoubleToString(InpMinimumAutoScore,1),".");
      g_requestBusy=false; return;
   }
   string cooldownKey="NEXORA_COOLDOWN_"+_Symbol+"_"+EnumToString(g_activeTimeframe);
   if(GlobalVariableCheck(cooldownKey) && TimeCurrent()<(datetime)GlobalVariableGet(cooldownKey))
   {
      Print("NEXORA AUTO WAIT: ",_Symbol," ",interval," is in its post-close cooldown until ",
            TimeToString((datetime)GlobalVariableGet(cooldownKey),TIME_DATE|TIME_SECONDS));
      g_requestBusy=false; return;
   }
   long timeframeMagic=InpMagicNumber+(long)g_activeTimeframe;
   for(int pi=PositionsTotal()-1;pi>=0;pi--)
   {
      ulong pt=PositionGetTicket(pi);
      if(pt>0 && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==timeframeMagic)
      {
         Print("NEXORA AUTO WAIT: existing ",interval," position already open on ",_Symbol,".");
         g_requestBusy=false; return;
      }
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      Print("NEXORA: trading permissions are disabled. No order sent.");
      g_requestBusy=false; return;
   }
   if(CountOurPositions(_Symbol)>=InpMaxOpenPositions)
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
   // Size the order so estimated loss at the stop is no more than the
   // configured percentage of current account equity. Never round UP to min lot.
   ENUM_ORDER_TYPE orderType=(direction=="BUY")?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double riskBudget=equity*(InpRiskPercent/100.0);
   double oneLotProfit=0.0;
   if(equity<=0.0 || riskBudget<=0.0 ||
      !OrderCalcProfit(orderType,_Symbol,1.0,current,sl,oneLotProfit) ||
      MathAbs(oneLotProfit)<=0.0)
   {
      Print("NEXORA SAFETY BLOCK: could not calculate stop-loss risk from this symbol's contract specifications. No order sent.");
      g_requestBusy=false; return;
   }
   double rawLots=riskBudget/MathAbs(oneLotProfit);
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0.0 || rawLots<minLot)
   {
      Print("NEXORA SAFETY BLOCK: minimum broker volume would exceed the ",DoubleToString(InpRiskPercent,2),
            "% risk budget. No order sent.");
      g_requestBusy=false; return;
   }
   double lots=NormalizedLots(rawLots);
   if(lots<minLot || lots<=0.0)
   {
      Print("NEXORA SAFETY BLOCK: calculated volume is below broker minimum. No order sent.");
      g_requestBusy=false; return;
   }
   double estimatedProfit=0.0;
   if(!OrderCalcProfit(orderType,_Symbol,lots,current,sl,estimatedProfit) ||
      MathAbs(estimatedProfit)>riskBudget*1.001)
   {
      Print("NEXORA SAFETY BLOCK: final volume failed the risk-budget check. No order sent.");
      g_requestBusy=false; return;
   }
   trade.SetExpertMagicNumber(timeframeMagic);
   trade.SetDeviationInPoints(InpMaxPriceDeviationPoints);
   bool sent=false;
   if(direction=="BUY") sent=trade.Buy(lots,_Symbol,0,NormalizeDouble(sl,digits),NormalizeDouble(tp,digits),"NEXORA "+signalTime);
   else sent=trade.Sell(lots,_Symbol,0,NormalizeDouble(sl,digits),NormalizeDouble(tp,digits),"NEXORA "+signalTime);
   if(!sent) Print("NEXORA order rejected: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   else Print("NEXORA demo order submitted. Ticket/deal: ",trade.ResultDeal(),
              " | timeframe=",interval," | magic=",timeframeMagic,
              " | riskBudget=",DoubleToString(riskBudget,2)," ",AccountInfoString(ACCOUNT_CURRENCY));
   g_requestBusy=false;
}
int OnInit()
{
   if(InpRiskPercent<=0.0 || InpRiskPercent>5.0 || InpMinimumAutoScore<0.0 || InpMinimumAutoScore>100.0 || InpTradeCooldownSeconds<0)
   {
      Print("NEXORA SAFETY BLOCK: risk percentage must be greater than 0 and no more than 5%.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(StringFind(InpNexoraBaseUrl,"https://")!=0 || !LoadConnectorToken())
   {
      Print("NEXORA: Set HTTPS base URL and enter the private token once in EA Inputs. It will be saved locally for other charts on this computer.");
      return INIT_PARAMETERS_INCORRECT;
   }
   trade.SetExpertMagicNumber(InpMagicNumber);
   g_lastChartSymbol=_Symbol;
   g_lastChartPeriod=_Period;
   EventSetTimer(10); // Keep the backend heartbeat alive independently of signal checks.
   Print("NEXORA BUILD ACTIVE: ",NEXORA_BUILD_ID," | auto=",InpEnableAutoExecution?"ON":"OFF",
         " | scoreThreshold=",DoubleToString(InpMinimumAutoScore,0),
         " | cooldownSeconds=",InpTradeCooldownSeconds);
   SendHeartbeat();
   for(int i=0;i<5;i++) { g_activeTimeframe=g_scanFrames[i]; ProcessSignal(); }
   g_activeTimeframe=_Period;
   g_nextSignalCheckMs=GetTickCount64()+(ulong)MathMax(60,InpPollSeconds)*1000;
   return INIT_SUCCEEDED;
}
void OnTimer()
{
   if(RefreshChartContext())
   {
      for(int i=0;i<5;i++) { g_activeTimeframe=g_scanFrames[i]; ProcessSignal(); }
      g_activeTimeframe=_Period;
      g_nextSignalCheckMs=GetTickCount64()+(ulong)MathMax(60,InpPollSeconds)*1000;
      return;
   }
   ulong nowMs=GetTickCount64();
   if(nowMs-g_lastHeartbeatMs>=20000) SendHeartbeat();
   if(nowMs>=g_nextSignalCheckMs)
   {
      // Refresh all five independent timeframe signals on every scheduled scan.
      for(int i=0;i<5;i++) { g_activeTimeframe=g_scanFrames[i]; ProcessSignal(); }
      g_activeTimeframe=_Period;
      g_nextSignalCheckMs=GetTickCount64()+(ulong)MathMax(60,InpPollSeconds)*1000;
   }
   ManageTrailingStop();
}
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_CHART_CHANGE && RefreshChartContext())
   {
      for(int i=0;i<5;i++) { g_activeTimeframe=g_scanFrames[i]; ProcessSignal(); }
      g_activeTimeframe=_Period;
   }
}
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   long magic=(long)HistoryDealGetInteger(trans.deal,DEAL_MAGIC);
   long entry=(long)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) return;
   string symbol=HistoryDealGetString(trans.deal,DEAL_SYMBOL);
   // A partial close is not the end of the trade. Start the cooldown only after
   // the last position for this symbol/timeframe magic has fully disappeared.
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionGetString(POSITION_SYMBOL)==symbol &&
         PositionGetInteger(POSITION_MAGIC)==magic)
         return;
   }
   for(int i=0;i<5;i++)
   {
      long expectedMagic=InpMagicNumber+(long)g_scanFrames[i];
      if(magic!=expectedMagic) continue;
      string key="NEXORA_COOLDOWN_"+symbol+"_"+EnumToString(g_scanFrames[i]);
      datetime until=TimeCurrent()+MathMax(0,InpTradeCooldownSeconds);
      GlobalVariableSet(key,(double)until);
      Print("NEXORA cooldown started: ",symbol," ",g_scanLabels[i]," until ",TimeToString(until,TIME_DATE|TIME_SECONDS));
      break;
   }
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}
// IMPORTANT: Auto execution is OFF by default. Test on demo only.
// This EA uses NEXORA's current rules-based technical signal API.
// Verify symbol mapping and strategy results before enabling any real account.
