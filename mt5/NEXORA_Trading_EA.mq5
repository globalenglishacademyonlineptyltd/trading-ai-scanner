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
input string InpProviderSymbol = ""; // Leave blank to derive the provider symbol from this chart; optional explicit override
input string InpSignalInterval = "1h";
input bool   InpEnableAutoExecution = false; // OFF by default
input double InpRiskPercent = 1.0; // Risk budget as % of account equity, calculated from entry-to-stop loss
input int    InpMaxOpenPositions = 1;
input int    InpMaxPriceDeviationPoints = 500;
input int    InpTrailingStopPoints = 300;
input int    InpTrailingStepPoints = 50;
input int    InpPollSeconds = 300; // Signal analysis/notification interval: 5 minutes
input long   InpMagicNumber = 24111401;

string g_lastSignalKey = "";
string g_connectorToken = "";
datetime g_nextSignalCheck = 0;
const string NEXORA_TOKEN_FILE = "NEXORA_MT5_Connector.token";
const string NEXORA_HISTORY_FILE = "NEXORA_Signal_History.csv";
datetime g_lastHeartbeat = 0;
string g_lastStatus = "Starting";
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
   string key="NEXORA_ALERT_"+_Symbol;
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
   FileWrite(handle,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),_Symbol,EnumToString(_Period),
             direction,DoubleToString(score,1),DoubleToString(entry,_Digits),
             DoubleToString(sl,_Digits),DoubleToString(tp,_Digits),signalTime,
              notificationSent?"YES - cooldown elapsed":"NO - 5 minute cooldown");
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
   return EnumToString(_Period);
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
      g_lastStatus="Local MT5 analysis HTTP "+IntegerToString(code)+" / MT5 error "+IntegerToString(GetLastError());
      Print(g_lastStatus);
      return false;
   }
   body=CharArrayToString(result,0,WHOLE_ARRAY,CP_UTF8);
   return true;
}
bool BuildLocalCandlePayload(string &payload)
{
   MqlRates rates[];
   ArraySetAsSeries(rates,false);
   int copied=CopyRates(_Symbol,_Period,1,100,rates); // closed candles only; excludes the forming bar
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
   // ALL instruments use the connected MT5 terminal as the only price-data source.
   // No Twelve Data/provider-symbol lookup is used by this Expert Advisor.
   string providerSymbol=_Symbol;
   string payload;
   if(!BuildLocalCandlePayload(payload)) { g_requestBusy=false; return; }
   string json;
   string localUrl=TrimSlash(InpNexoraBaseUrl)+"/api/mt5/signal-local";
   if(!HttpPostJson(localUrl,payload,json)) { g_requestBusy=false; return; }
   string responseSymbol=JsonValue(json,"symbol");
   if(responseSymbol=="" || CanonicalSymbol(responseSymbol)!=CanonicalSymbol(providerSymbol))
   {
      g_lastStatus="Symbol mismatch blocked: chart "+_Symbol+", requested "+providerSymbol+", received "+responseSymbol;
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
   string signalKey=providerSymbol+"|"+CurrentChartInterval()+"|"+direction+"|"+signalTime;
   string interval=CurrentChartInterval();
   double riskDistance=(entry>0 && sl>0)?MathAbs(entry-sl):0;
   // Current server plan sets SL at 1.5 x average candle range; derive the range from returned SL.
   double avgRange=(riskDistance>0)?riskDistance/1.5:0;
   double rewardDistance=(entry>0 && tp>0)?MathAbs(tp-entry):0;
   double rr=(riskDistance>0)?rewardDistance/riskDistance:0;
   bool validPlan=(entry>0 && sl>0 && tp>0 && avgRange>0 &&
                   ((direction=="BUY" && sl<entry && tp>entry) ||
                    (direction=="SELL" && sl>entry && tp<entry)));
   double trailActivation=0;
   if(validPlan) trailActivation=(direction=="BUY")?entry+riskDistance:entry-riskDistance;
   string panel="NEXORA TRADE PLAN\n";
   panel+="Instrument: "+_Symbol+" | Timeframe: "+interval+"\n";
   panel+="Signal: "+direction+" | Technical score: "+DoubleToString(score,0)+"/100\n";
   panel+="Analysed closed candle: "+signalTime+"\n";
   panel+="Entry: "+(validPlan?DoubleToString(entry,_Digits):"NOT AVAILABLE")+"\n";
   panel+="Stop loss: "+(validPlan?DoubleToString(sl,_Digits):"NOT AVAILABLE")+"\n";
   panel+="Take profit: "+(validPlan?DoubleToString(tp,_Digits):"NOT AVAILABLE")+"\n";
   panel+="Risk distance: "+(validPlan?DoubleToString(riskDistance,_Digits):"N/A")+" | Reward/Risk: "+(validPlan?DoubleToString(rr,2):"N/A")+"\n";
   panel+="Trailing stop: start after +1R at "+(validPlan?DoubleToString(trailActivation,_Digits):"N/A")+"\n";
   panel+="Trailing distance: "+(validPlan?DoubleToString(avgRange,_Digits)+" (average candle range)":"N/A")+"\n";
   panel+="Method: EMA20/EMA50 + RSI14 + momentum | closed candles only\n";
   panel+="Auto position sizing: "+DoubleToString(InpRiskPercent,2)+"% equity risk; calculated against stop loss when auto mode is enabled\n";
   panel+=InpEnableAutoExecution?"AUTOMATIC MODE - currently configured; demo testing only":"MANUAL MODE - no order will be placed";
   Comment(panel);
   Print("NEXORA 5-MINUTE UPDATE | ",_Symbol," | ",interval,
         " | ",direction," | score=",DoubleToString(score,0),"/100",
         " | Entry=",DoubleToString(entry,_Digits),
         " | SL=",DoubleToString(sl,_Digits),
         " | TP=",DoubleToString(tp,_Digits),
         " | candle=",signalTime,
         " | auto=",InpEnableAutoExecution?"ON":"OFF");
   if(direction!="BUY" && direction!="SELL")
   {
      Comment("NEXORA TRADE PLAN\nInstrument: ",_Symbol," | Timeframe: ",interval,
              "\nSignal: WAIT | Score: ",DoubleToString(score,0),"/100",
              "\nAnalysed closed candle: ",signalTime,
              "\nNo entry, stop loss or take profit: mixed/insufficient technical evidence.",
              "\nMethod: EMA20/EMA50 + RSI14 + momentum. Manual mode; no order placed.");
      Print("NEXORA 5-MINUTE UPDATE | ",_Symbol," | ",interval,
            " | WAIT | score=",DoubleToString(score,0),"/100",
            " | Entry=N/A | SL=N/A | TP=N/A | candle=",signalTime,
            " | No trade: technical conditions are not aligned.");
      g_requestBusy=false; return;
   }
   if(!validPlan)
   {
      g_lastStatus="INVALID TRADE PLAN - levels failed validation";
      Comment("NEXORA SAFETY WARNING\n",_Symbol," | ",interval,"\nSignal: ",direction,
              " | Score: ",DoubleToString(score,0),"/100",
              "\nEntry/SL/TP levels are invalid or incomplete. Do not trade.",
              "\nAnalysed candle: ",signalTime);
      Print("NEXORA 5-MINUTE UPDATE | ",_Symbol," | ",interval,
            " | REJECTED INVALID PLAN | score=",DoubleToString(score,0),
            " | Entry=",DoubleToString(entry,_Digits),
            " | SL=",DoubleToString(sl,_Digits),
            " | TP=",DoubleToString(tp,_Digits),
            " | No order sent.");
      g_requestBusy=false; return;
   }
   bool newSignal=(signalKey!=g_lastSignalKey);
   if(newSignal)
   {
      g_lastSignalKey=signalKey;
      Print("NEXORA signal: ",direction," ",providerSymbol," score=",score," entry=",entry," SL=",sl," TP=",tp);
   }
   string cooldownName=AlertCooldownVariable();
   datetime lastAlert=0;
   if(GlobalVariableCheck(cooldownName)) lastAlert=(datetime)GlobalVariableGet(cooldownName);
   bool notifyUser=(lastAlert==0 || TimeCurrent()-lastAlert>=300);
   if(notifyUser)
   {
      GlobalVariableSet(cooldownName,(double)TimeCurrent());
      // Desktop pop-ups are disabled; the full trade plan is displayed on the chart.
   }
   else
      Print("NEXORA: signal for ",providerSymbol," logged; repeat alert suppressed by the 5-minute alert limit.");
   AppendSignalHistory(direction,score,entry,sl,tp,signalTime,notifyUser);
   if(!InpEnableAutoExecution)
   {
      g_requestBusy=false;
      return;
   }
   if(!newSignal) { g_requestBusy=false; return; }
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
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxPriceDeviationPoints);
   bool sent=false;
   if(direction=="BUY") sent=trade.Buy(lots,_Symbol,0,NormalizeDouble(sl,digits),NormalizeDouble(tp,digits),"NEXORA "+signalTime);
   else sent=trade.Sell(lots,_Symbol,0,NormalizeDouble(sl,digits),NormalizeDouble(tp,digits),"NEXORA "+signalTime);
   if(!sent) Print("NEXORA order rejected: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   else Print("NEXORA demo order submitted. Ticket/deal: ",trade.ResultDeal());
   g_requestBusy=false;
}
int OnInit()
{
   if(InpRiskPercent<=0.0 || InpRiskPercent>5.0)
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
   SendHeartbeat();
   ProcessSignal();
   g_nextSignalCheck=TimeCurrent()+MathMax(60,InpPollSeconds);
   return INIT_SUCCEEDED;
}
void OnTimer()
{
   if(RefreshChartContext())
   {
      ProcessSignal();
      g_nextSignalCheck=TimeCurrent()+MathMax(60,InpPollSeconds);
      return;
   }
   if(TimeCurrent()-g_lastHeartbeat>=20) SendHeartbeat();
   if(TimeCurrent()>=g_nextSignalCheck)
   {
      ProcessSignal();
      g_nextSignalCheck=TimeCurrent()+MathMax(60,InpPollSeconds);
   }
   ManageTrailingStop();
}
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_CHART_CHANGE && RefreshChartContext())
      ProcessSignal();
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}
// IMPORTANT: Auto execution is OFF by default. Test on demo only.
// This EA uses NEXORA's current rules-based technical signal API.
// Verify symbol mapping and strategy results before enabling any real account.
