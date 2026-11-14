//+------------------------------------------------------------------+
//| NEXORA MT5 Demo Connector - heartbeat only                       |
//| This first milestone DOES NOT place, modify or close trades.     |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "NEXORA demo connection heartbeat; no trade execution"

input string InpNexoraBaseUrl = "https://YOUR-NEXORA-DOMAIN";
input string InpConnectorToken = ""; // Set privately; never share this token
input int    InpHeartbeatSeconds = 15;

string JsonEscape(string value)
{
   StringReplace(value, "\\", "\\\\");
   StringReplace(value, "\"", "\\\"");
   StringReplace(value, "\r", "");
   StringReplace(value, "\n", " ");
   return value;
}

string MaskLogin(long login)
{
   string s = IntegerToString(login);
   int n = StringLen(s);
   if(n <= 4) return "****";
   return StringSubstr(s, 0, 2) + "****" + StringSubstr(s, n-2, 2);
}

void SendHeartbeat()
{
   if(StringLen(InpConnectorToken) < 24)
   {
      Print("NEXORA: Add the connector token in EA Inputs. No account data sent.");
      return;
   }

   string base = InpNexoraBaseUrl;
   while(StringLen(base) > 0 && StringSubstr(base, StringLen(base)-1, 1) == "/")
      base = StringSubstr(base, 0, StringLen(base)-1);
   if(StringFind(base, "https://") != 0)
   {
      Print("NEXORA: HTTPS URL required.");
      return;
   }

   string payload = "{";
   payload += "\"account\":\"" + MaskLogin((long)AccountInfoInteger(ACCOUNT_LOGIN)) + "\",";
   payload += "\"server\":\"" + JsonEscape(AccountInfoString(ACCOUNT_SERVER)) + "\",";
   payload += "\"company\":\"" + JsonEscape(AccountInfoString(ACCOUNT_COMPANY)) + "\",";
   payload += "\"currency\":\"" + JsonEscape(AccountInfoString(ACCOUNT_CURRENCY)) + "\",";
   payload += "\"terminal_connected\":" + (TerminalInfoInteger(TERMINAL_CONNECTED) ? "true" : "false") + ",";
   payload += "\"trade_allowed\":" + (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ? "true" : "false") + ",";
   payload += "\"account_trade_allowed\":" + (AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ? "true" : "false");
   payload += "}";

   char data[];
   StringToCharArray(payload, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(ArraySize(data) > 0) ArrayResize(data, ArraySize(data)-1);

   char result[];
   string responseHeaders;
   string headers = "Content-Type: application/json\r\n";
   headers += "Authorization: Bearer " + InpConnectorToken + "\r\n";
   ResetLastError();
   int code = WebRequest("POST", base + "/api/mt5/heartbeat", headers, 8000, data, result, responseHeaders);
   if(code == -1)
   {
      Print("NEXORA heartbeat failed. MT5 error=", GetLastError(),
            ". Add the exact HTTPS host under Tools > Options > Expert Advisors > WebRequest.");
      return;
   }
   string response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(code == 200)
      Print("NEXORA demo connector connected: ", response);
   else
      Print("NEXORA server returned HTTP ", code, ": ", response);
}

int OnInit()
{
   if(StringLen(InpNexoraBaseUrl) < 12 || StringFind(InpNexoraBaseUrl, "https://") != 0)
   {
      Print("NEXORA: Configure the HTTPS base URL in EA Inputs.");
      return INIT_PARAMETERS_INCORRECT;
   }
   EventSetTimer(MathMax(5, InpHeartbeatSeconds));
   SendHeartbeat();
   return INIT_SUCCEEDED;
}

void OnTimer() { SendHeartbeat(); }
void OnDeinit(const int reason) { EventKillTimer(); }
// Deliberately no OnTick trade logic: this build cannot place trades.
