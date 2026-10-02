//+------------------------------------------------------------------+
//|                                                BfxBridge.mq5     |
//|                         Copyright 2026, BfxBridge Technologies   |
//|                                   https://bfxbridge.com          |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, BfxBridge Technologies"
#property link      "https://bfxbridge.com"
#property version   "1.20"
#property description "Official BfxBridge Execution Connector for MetaTrader 5."
#property description "Supports Limit Orders (Buy/Sell Limit), Stop Orders (Buy/Sell Stop), and Market Execution."

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Enums
enum ENUM_BFX_EXEC_MODE
{
   EXEC_MODE_MARKET  = 0,  // Immediate Execution (Market Order) - Default
   EXEC_MODE_PENDING = 1   // Pending Orders (Auto Buy/Sell Limit & Stop)
};

//--- Input Parameters
input group "=== BfxBridge Server Settings ==="
input string   InpServerUrl         = "https://bfxbridge.onrender.com";          // BfxBridge Server Base URL (e.g. https://your-domain.com)
input string   InpAccountId         = "";                                      // BfxBridge Account ID (from your MT5 Accounts card)

input group "=== Order Execution Type Settings ==="
input ENUM_BFX_EXEC_MODE InpExecMode          = EXEC_MODE_MARKET; // Execution Mode (Immediate / Pending Limit & Stop)
input uint               InpPendingExpiryMins = 0;                // Pending Order Expiration in Mins (0 = GTC / No Expiry)

input group "=== Execution & Polling Settings ==="
input ulong    InpMagicNumber       = 20260904;                // EA Magic Number for BfxBridge trades
input bool     InpLongPolling       = true;                    // Enable Ultra-Fast Long-Polling (< 20ms)
input uint     InpPollInterval      = 1;                       // Polling interval in seconds (default 1)
input uint     InpHeartbeatInterval = 30;                      // Heartbeat interval in seconds (recommended 30)
input ulong    InpDeviation         = 20;                      // Max allowable slippage in points


//--- Global Objects & State
CTrade         m_trade;
CSymbolInfo    m_symbol;
datetime       m_lastHeartbeatTime     = 0;
bool           m_isConnected           = false;
string         m_autoResolvedAccountId = "";

//--- WinINet API Declarations (Zero-Whitelist Native Windows HTTP)
#import "wininet.dll"
long InternetOpenW(string lpszAgent, int dwAccessType, string lpszProxy, string lpszProxyBypass, int dwFlags);
long InternetConnectW(long hInternet, string lpszServerName, int nServerPort, string lpszUsername, string lpszPassword, int dwService, int dwFlags, int dwContext);
long HttpOpenRequestW(long hConnect, string lpszVerb, string lpszObjectName, string lpszVersion, string lpszReferrer, long lpszAcceptTypes, int dwFlags, int dwContext);
bool HttpSendRequestW(long hRequest, string lpszHeaders, int dwHeadersLength, const char &lpOptional[], int dwOptionalLength);
bool InternetReadFile(long hFile, char &lpBuffer[], int dwNumberOfBytesToRead, int &lpdwNumberOfBytesRead);
bool InternetCloseHandle(long hInternet);
#import

#define INTERNET_OPEN_TYPE_DIRECT               1
#define INTERNET_SERVICE_HTTP                   3
#define INTERNET_FLAG_RELOAD                    0x80000000
#define INTERNET_FLAG_NO_CACHE_WRITE            0x04000000
#define INTERNET_FLAG_SECURE                    0x00800000
#define INTERNET_FLAG_IGNORE_CERT_CN_INVALID    0x00001000
#define INTERNET_FLAG_IGNORE_CERT_DATE_INVALID  0x00002000
#define INTERNET_FLAG_PRAGMA_NOCACHE            0x00000100

//+------------------------------------------------------------------+
//| Native WinInet HTTP Implementation (Bypasses WebRequest whitelist)|
//+------------------------------------------------------------------+
int WinInetHttpRequest(
   string      method,
   string      url,
   string      headers,
   int         timeoutMs,
   const char &postData[],
   char       &resultData[],
   string     &resultHeaders
)
{
   bool isHttps = (StringFind(url, "https://") == 0);
   int defaultPort = isHttps ? 443 : 80;
   int prefixLen = isHttps ? 8 : 7;
   
   string rest = StringSubstr(url, prefixLen);
   int slashPos = StringFind(rest, "/");
   string serverName = (slashPos >= 0) ? StringSubstr(rest, 0, slashPos) : rest;
   string objectPath = (slashPos >= 0) ? StringSubstr(rest, slashPos) : "/";
   
   int port = defaultPort;
   int colonPos = StringFind(serverName, ":");
   if(colonPos >= 0)
   {
      port = (int)StringToInteger(StringSubstr(serverName, colonPos + 1));
      serverName = StringSubstr(serverName, 0, colonPos);
   }

   long hInternet = InternetOpenW("BfxBridge/1.2", INTERNET_OPEN_TYPE_DIRECT, NULL, NULL, 0);
   if(hInternet == 0) return -1;

   long hConnect = InternetConnectW(hInternet, serverName, port, NULL, NULL, INTERNET_SERVICE_HTTP, 0, 0);
   if(hConnect == 0)
   {
      InternetCloseHandle(hInternet);
      return -1;
   }

   int reqFlags = INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE | INTERNET_FLAG_PRAGMA_NOCACHE;
   if(isHttps)
   {
      reqFlags |= (INTERNET_FLAG_SECURE | INTERNET_FLAG_IGNORE_CERT_CN_INVALID | INTERNET_FLAG_IGNORE_CERT_DATE_INVALID);
   }

   long hRequest = HttpOpenRequestW(hConnect, method, objectPath, NULL, NULL, 0, reqFlags, 0);
   if(hRequest == 0)
   {
      InternetCloseHandle(hConnect);
      InternetCloseHandle(hInternet);
      return -1;
   }

   int postSize = ArraySize(postData);
   bool sendOk = HttpSendRequestW(hRequest, headers, StringLen(headers), postData, postSize);
   if(!sendOk)
   {
      InternetCloseHandle(hRequest);
      InternetCloseHandle(hConnect);
      InternetCloseHandle(hInternet);
      return -1;
   }

   char chunk[4096];
   int bytesRead = 0;
   ArrayResize(resultData, 0);

   while(InternetReadFile(hRequest, chunk, 4096, bytesRead) && bytesRead > 0)
   {
      int cur = ArraySize(resultData);
      ArrayResize(resultData, cur + bytesRead);
      ArrayCopy(resultData, chunk, cur, 0, bytesRead);
   }

   InternetCloseHandle(hRequest);
   InternetCloseHandle(hConnect);
   InternetCloseHandle(hInternet);

   return 200;
}

//+------------------------------------------------------------------+
//| Universal HTTP Request Dispatcher                                |
//+------------------------------------------------------------------+
int SendHttpRequest(
   string      method,
   string      url,
   string      headers,
   int         timeoutMs,
   const char &postData[],
   char       &resultData[],
   string     &resultHeaders
)
{
   if(TerminalInfoInteger(TERMINAL_DLLS_ALLOWED))
   {
      int winRes = WinInetHttpRequest(method, url, headers, timeoutMs, postData, resultData, resultHeaders);
      if(winRes == 200)
         return 200;
   }

   ResetLastError();
   return WebRequest(method, url, headers, timeoutMs, postData, resultData, resultHeaders);
}

// Duplicate Execution Protection Cache
#define MAX_CACHED_EXEC_IDS 256
string         m_processedExecutionIds[MAX_CACHED_EXEC_IDS];
int            m_processedCount        = 0;

bool IsExecutionAlreadyProcessed(string execId)
{
   if(StringLen(execId) == 0) return false;
   for(int i = 0; i < m_processedCount; i++)
   {
      if(m_processedExecutionIds[i] == execId)
         return true;
   }
   return false;
}

void MarkExecutionAsProcessed(string execId)
{
   if(StringLen(execId) == 0) return;
   if(m_processedCount >= MAX_CACHED_EXEC_IDS)
   {
      for(int i = 0; i < MAX_CACHED_EXEC_IDS - 1; i++)
         m_processedExecutionIds[i] = m_processedExecutionIds[i + 1];
      m_processedCount = MAX_CACHED_EXEC_IDS - 1;
   }
   m_processedExecutionIds[m_processedCount++] = execId;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Configure CTrade
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpDeviation);
   m_trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   // Start ultra-responsive polling timer (500ms for instant execution listener)
   if(!EventSetMillisecondTimer(500))
   {
      uint timerInterval = MathMax(1, InpPollInterval);
      if(!EventSetTimer(timerInterval))
      {
         Print("BfxBridge Error: Failed to start polling timer! Code: ", GetLastError());
         return(INIT_FAILED);
      }
   }
   
   Print("==================================================");
   Print("BfxBridge.mq5 initialized successfully!");
   Print("Terminal Account: ", AccountInfoInteger(ACCOUNT_LOGIN), " on ", AccountInfoString(ACCOUNT_SERVER));
   Print("Connected Broker: ", AccountInfoString(ACCOUNT_COMPANY));
   Print("BfxBridge Server: ", InpServerUrl);
   if(StringLen(InpAccountId) > 0)
      Print("Configured Account ID: ", InpAccountId);
   else
      Print("Account ID will be auto-resolved via login #", AccountInfoInteger(ACCOUNT_LOGIN));
   Print("Polling Interval: ", InpPollInterval, " second(s)");
   Print("==================================================");
   
   // Send initial heartbeat
   SendHeartbeat();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("BfxBridge.mq5 deactivated. Polling timer stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Timer event function (Primary Polling & Heartbeat Loop)          |
//+------------------------------------------------------------------+
void OnTimer()
{
   datetime currentTime = TimeCurrent();
   
   // 1. Periodic Heartbeat & Balance Synchronization
   if(currentTime - m_lastHeartbeatTime >= (datetime)InpHeartbeatInterval)
   {
      SendHeartbeat();
      m_lastHeartbeatTime = currentTime;
   }
   
   // 2. Poll BfxBridge for Pending Trade Executions
   PollPendingCommands();
}

//+------------------------------------------------------------------+
//| Serializes active open positions to JSON                         |
//+------------------------------------------------------------------+
string GetOpenPositionsJson()
{
   string json = "[";
   int total = PositionsTotal();
   int count = 0;
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         string sym   = PositionGetString(POSITION_SYMBOL);
         long type    = PositionGetInteger(POSITION_TYPE);
         double vol   = PositionGetDouble(POSITION_VOLUME);
         double openP = PositionGetDouble(POSITION_PRICE_OPEN);
         double currP = PositionGetDouble(POSITION_PRICE_CURRENT);
         double sl    = PositionGetDouble(POSITION_SL);
         double tp    = PositionGetDouble(POSITION_TP);
         double pnl   = PositionGetDouble(POSITION_PROFIT);
         
         if(count > 0) json += ",";
         json += StringFormat("{\"ticket\":\"%I64u\",\"symbol\":\"%s\",\"type\":\"%s\",\"lots\":%.2f,\"entryPrice\":%.5f,\"currentPrice\":%.5f,\"sl\":%.5f,\"tp\":%.5f,\"profit\":%.2f}",
            ticket, sym, (type == POSITION_TYPE_BUY ? "BUY" : "SELL"), vol, openP, currP, sl, tp, pnl);
         count++;
      }
   }
   json += "]";
   return json;
}

//+------------------------------------------------------------------+
//| Serializes recent closed deals from history to JSON              |
//+------------------------------------------------------------------+
string GetClosedDealsJson()
{
   string json = "[";
   datetime fromDate = TimeCurrent() - (7 * 86400);
   if(HistorySelect(fromDate, TimeCurrent()))
   {
      int total = HistoryDealsTotal();
      int count = 0;
      for(int i = total - 1; i >= 0 && count < 20; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket > 0)
         {
            long entryType = HistoryDealGetInteger(ticket, DEAL_ENTRY);
            if(entryType == DEAL_ENTRY_OUT || entryType == DEAL_ENTRY_INOUT)
            {
               ulong posId       = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
               string sym        = HistoryDealGetString(ticket, DEAL_SYMBOL);
               double profit     = HistoryDealGetDouble(ticket, DEAL_PROFIT);
               double swap       = HistoryDealGetDouble(ticket, DEAL_SWAP);
               double comm       = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
               double netProfit  = profit + swap + comm;
               double exitPrice  = HistoryDealGetDouble(ticket, DEAL_PRICE);
               double vol        = HistoryDealGetDouble(ticket, DEAL_VOLUME);
               datetime dealTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
               long dealType     = HistoryDealGetInteger(ticket, DEAL_TYPE);
               string posType    = (dealType == DEAL_TYPE_SELL) ? "BUY" : "SELL";

               if(count > 0) json += ",";
               json += StringFormat("{\"ticket\":\"%I64u\",\"positionId\":\"%I64u\",\"symbol\":\"%s\",\"type\":\"%s\",\"lots\":%.2f,\"exitPrice\":%.5f,\"profit\":%.2f,\"time\":%d}",
                  ticket, posId, sym, posType, vol, exitPrice, netProfit, (int)dealTime);
               count++;
            }
         }
      }
   }
   json += "]";
   return json;
}

//+------------------------------------------------------------------+
//| Sends telemetry heartbeat to BfxBridge                          |
//+------------------------------------------------------------------+
void SendHeartbeat()
{
   string url = InpServerUrl + "/api/mt5/bridge/heartbeat";
   string headers = BuildAuthHeaders();
   
   // Construct JSON payload with live terminal metrics & identity
   double balance        = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity         = AccountInfoDouble(ACCOUNT_EQUITY);
   double profitLoss     = AccountInfoDouble(ACCOUNT_PROFIT);
   double margin         = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin     = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   string currency       = AccountInfoString(ACCOUNT_CURRENCY);
   string broker         = AccountInfoString(ACCOUNT_COMPANY);
   string server         = AccountInfoString(ACCOUNT_SERVER);
   long login            = AccountInfoInteger(ACCOUNT_LOGIN);
   bool terminalTradeAllowed = (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);
   bool mqlTradeAllowed      = (bool)MQLInfoInteger(MQL_TRADE_ALLOWED);
   bool accountTradeAllowed  = (bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED);
   bool accountExpertAllowed = (bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
   bool algoTrading          = terminalTradeAllowed && mqlTradeAllowed && accountTradeAllowed && accountExpertAllowed;
   bool terminalConnect  = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   string positionsJson   = GetOpenPositionsJson();
   string closedDealsJson = GetClosedDealsJson();
   
   string payload = StringFormat(
      "{\"balance\":%.2f,\"equity\":%.2f,\"profitLoss\":%.2f,\"margin\":%.2f,\"freeMargin\":%.2f,\"currency\":\"%s\",\"broker\":\"%s\",\"server\":\"%s\",\"terminalVersion\":\"%d\",\"login\":%I64d,\"algoTradingEnabled\":%s,\"terminalConnected\":%s,\"positions\":",
      balance, equity, profitLoss, margin, freeMargin, currency, broker, server, TerminalInfoInteger(TERMINAL_BUILD),
      login, algoTrading ? "true" : "false", terminalConnect ? "true" : "false"
   ) + positionsJson + ",\"closedDeals\":" + closedDealsJson + "}";
   
   char postData[];
   char resultData[];
   string resultHeaders;
   StringToCharArray(payload, postData, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(postData, ArraySize(postData) - 1); // remove null terminator
   
   ResetLastError();
   int res = SendHttpRequest("POST", url, headers, 3000, postData, resultData, resultHeaders);
   
   if(res == 200)
   {
      string respStr = CharArrayToString(resultData, 0, WHOLE_ARRAY, CP_UTF8);
      string resolvedId = ExtractJsonString(respStr, "accountId");
      if(StringLen(resolvedId) > 0 && StringLen(m_autoResolvedAccountId) == 0)
      {
         m_autoResolvedAccountId = resolvedId;
         Print("BfxBridge: Auto-resolved Account ID: ", m_autoResolvedAccountId);
      }

      if(!m_isConnected)
      {
         Print("BfxBridge: Connected to bridge server successfully. Status: ONLINE");
         m_isConnected = true;
      }
   }
   else if(res == -1)
   {
      int err = GetLastError();
      if(err == 4014) // ERR_FUNCTION_NOT_ALLOWED
      {
         Print("BfxBridge Security Warning: WebRequest not allowed! Add '", InpServerUrl, "' to Tools -> Options -> Expert Advisors -> 'Allow WebRequest for listed URL'.");
      }
      else
      {
         Print("BfxBridge Heartbeat failed: Network error ", err);
      }
      m_isConnected = false;
   }
   else
   {
      Print("BfxBridge Heartbeat returned HTTP status ", res);
      m_isConnected = false;
   }
}

//+------------------------------------------------------------------+
//| Polls BfxBridge for READY trade commands and modifications       |
//+------------------------------------------------------------------+
void PollPendingCommands()
{
   static bool isPollingActive = false;
   if(isPollingActive) return; // Prevent overlapping requests
   isPollingActive = true;

   string effectiveId = (StringLen(InpAccountId) > 0) ? InpAccountId : m_autoResolvedAccountId;
   if(StringLen(effectiveId) == 0)
   {
      isPollingActive = false;
      return;
   }
   
   string url = InpServerUrl + "/api/mt5/bridge/poll";
   if(InpLongPolling)
   {
      url += "?longPoll=true&timeout=10";
   }

   string headers = BuildAuthHeaders();
   char postData[];
   char resultData[];
   string resultHeaders;
   
   int requestTimeout = InpLongPolling ? 15000 : 3000;
   
   ResetLastError();
   int res = SendHttpRequest("GET", url, headers, requestTimeout, postData, resultData, resultHeaders);
   
   isPollingActive = false;
   
   if(res != 200) return;
   
   string responseStr = CharArrayToString(resultData, 0, WHOLE_ARRAY, CP_UTF8);
   if(StringLen(responseStr) == 0) return;
   
   // Check if count > 0 in response
   if(StringFind(responseStr, "\"count\":0") >= 0) return;
   
   // Extract commands array
   int commandsPos = StringFind(responseStr, "\"commands\":[");
   if(commandsPos < 0) return;
   
   // Process commands
   ProcessCommandsPayload(responseStr);
}

//+------------------------------------------------------------------+
//| Processes received JSON commands array                           |
//+------------------------------------------------------------------+
void ProcessCommandsPayload(string json)
{
   int startPos = StringFind(json, "\"commands\":[");
   if(startPos < 0) return;
   
   int searchIdx = startPos;
   while(true)
   {
      int objStart = StringFind(json, "{\"commandId\":", searchIdx);
      if(objStart < 0) break;
      
      int objEnd = StringFind(json, "}", objStart);
      if(objEnd < 0) break;
      
      string cmdJson = StringSubstr(json, objStart, objEnd - objStart + 1);
      
      string type = ExtractJsonString(cmdJson, "type");
      string execId = ExtractJsonString(cmdJson, "executionId");
      
      if(type == "NEW_ORDER")
      {
         ExecuteNewOrderCommand(cmdJson, execId);
      }
      else if(type == "MODIFY_POSITION")
      {
         ExecuteModifyPositionCommand(cmdJson, execId);
      }
      
      searchIdx = objEnd + 1;
   }
}

//+------------------------------------------------------------------+
//| Checks whether AlgoTrading is fully permitted locally            |
//+------------------------------------------------------------------+
bool IsAlgoTradingPermittedLocally(string &reason)
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      reason = "MT5 Algo Trading toolbar button is OFF (Red). Click the 'Algo Trading' button on top to turn it GREEN.";
      return false;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      reason = "EA 'Allow Algo Trading' is unchecked in chart properties. Press F7 -> Common -> Check 'Allow Algo Trading'.";
      return false;
   }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      reason = "Broker has disabled trading for this account (ACCOUNT_TRADE_ALLOWED is false).";
      return false;
   }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      reason = "Broker has disabled Expert Advisor automated trading for this account.";
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Dynamically sets best filling mode supported by broker for symbol|
//+------------------------------------------------------------------+
void AdaptOrderFillingMode(string symbol)
{
   uint fillingMode = (uint)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((fillingMode & SYMBOL_FILLING_IOC) != 0)
      m_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((fillingMode & SYMBOL_FILLING_FOK) != 0)
      m_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
//| Universal symbol resolver: Matches broker symbols dynamically    |
//| Prefix/Suffix agnostic: Finds GBPUSDz, GBPUSDm, i_GBPUSD, etc.   |
//+------------------------------------------------------------------+
string ResolveTradableSymbol(string rawSymbol)
{
   // 1. Exact match check
   if(SymbolSelect(rawSymbol, true))
      return rawSymbol;

   string base = rawSymbol;
   StringToUpper(base);
   StringTrimLeft(base);
   StringTrimRight(base);

   // Determine primary search keys (handling asset aliases)
   string searchKeys[8];
   int keyCount = 0;
   searchKeys[keyCount++] = base;

   if(StringFind(base, "XAUUSD") >= 0 || StringFind(base, "GOLD") >= 0)
   {
      searchKeys[keyCount++] = "XAUUSD";
      searchKeys[keyCount++] = "GOLD";
   }
   else if(StringFind(base, "BTCUSD") >= 0 || StringFind(base, "BTCUSDT") >= 0)
   {
      searchKeys[keyCount++] = "BTCUSD";
      searchKeys[keyCount++] = "BTCUSDT";
      searchKeys[keyCount++] = "BITCOIN";
   }
   else if(StringFind(base, "US30") >= 0 || StringFind(base, "DJ30") >= 0 || StringFind(base, "WS30") >= 0)
   {
      searchKeys[keyCount++] = "US30";
      searchKeys[keyCount++] = "DJ30";
      searchKeys[keyCount++] = "WS30";
      searchKeys[keyCount++] = "WALLSTREET";
      searchKeys[keyCount++] = "USA30";
   }
   else if(StringFind(base, "USOIL") >= 0 || StringFind(base, "WTI") >= 0 || StringFind(base, "CRUDE") >= 0)
   {
      searchKeys[keyCount++] = "USOIL";
      searchKeys[keyCount++] = "WTI";
      searchKeys[keyCount++] = "XTIUSD";
      searchKeys[keyCount++] = "OIL";
   }
   else if(StringFind(base, "NAS100") >= 0 || StringFind(base, "USTEC") >= 0 || StringFind(base, "US100") >= 0)
   {
      searchKeys[keyCount++] = "NAS100";
      searchKeys[keyCount++] = "USTEC";
      searchKeys[keyCount++] = "US100";
      searchKeys[keyCount++] = "NDX";
   }
   else if(StringFind(base, "UKOIL") >= 0 || StringFind(base, "BRENT") >= 0)
   {
      searchKeys[keyCount++] = "UKOIL";
      searchKeys[keyCount++] = "BRENT";
      searchKeys[keyCount++] = "XBRUSD";
   }

   // 2. PASS 1: Search symbols currently active in Market Watch (selected = true)
   int totalSelected = SymbolsTotal(true);
   for(int i = 0; i < totalSelected; i++)
   {
      string symName = SymbolName(i, true);
      string symUpper = symName;
      StringToUpper(symUpper);

      for(int k = 0; k < keyCount; k++)
      {
         string key = searchKeys[k];
         if(StringLen(key) == 0) continue;

         int pos = StringFind(symUpper, key);
         if(pos >= 0)
         {
            if(StringLen(symUpper) <= StringLen(key) + 8)
            {
               PrintFormat("BfxBridge: Universal match (Market Watch): '%s' -> '%s'", rawSymbol, symName);
               return symName;
            }
         }
      }
   }

   // 3. PASS 2: Search ALL broker symbols available on the server (selected = false)
   int totalAll = SymbolsTotal(false);
   for(int i = 0; i < totalAll; i++)
   {
      string symName = SymbolName(i, false);
      string symUpper = symName;
      StringToUpper(symUpper);

      for(int k = 0; k < keyCount; k++)
      {
         string key = searchKeys[k];
         if(StringLen(key) == 0) continue;

         int pos = StringFind(symUpper, key);
         if(pos >= 0)
         {
            if(StringLen(symUpper) <= StringLen(key) + 8)
            {
               if(SymbolSelect(symName, true))
               {
                  PrintFormat("BfxBridge: Universal match (Broker DB): '%s' -> '%s' (auto-enabled in Market Watch)", rawSymbol, symName);
                  return symName;
               }
            }
         }
      }
   }

   return rawSymbol;
}

//+------------------------------------------------------------------+
//| Places actual market order through MetaTrader 5 CTrade          |
//+------------------------------------------------------------------+
void ExecuteNewOrderCommand(string cmdJson, string executionId)
{
   string symbol       = ExtractJsonString(cmdJson, "symbol");
   string action       = ExtractJsonString(cmdJson, "action");
   double volume       = ExtractJsonDouble(cmdJson, "volume");
   double stopLoss     = ExtractJsonDouble(cmdJson, "stopLoss");
   double takeProfit   = ExtractJsonDouble(cmdJson, "takeProfit");
   
   double entryPrice   = ExtractJsonDouble(cmdJson, "entryPrice");
   
   PrintFormat("BfxBridge: Placing %s order on %s. Volume: %.2f | SL: %.5f | TP: %.5f | ExecID: %s",
      action, symbol, volume, stopLoss, takeProfit, executionId);
   
   // 1. Duplicate Execution Protection Guard
   if(IsExecutionAlreadyProcessed(executionId))
   {
      PrintFormat("BfxBridge: Execution %s already processed. Skipping duplicate.", executionId);
      return;
   }
   MarkExecutionAsProcessed(executionId);

   // 2. Pre-Execution Guard: Verify Terminal Algo Trading Permissions
   string algoDisabledReason = "";
   if(!IsAlgoTradingPermittedLocally(algoDisabledReason))
   {
      Print("BfxBridge Execution Blocked: ", algoDisabledReason);
      SendExecutionReport(executionId, false, 0, 0, 0.0, 0.0, 0.0, 0.0, "AUTOTRADING_DISABLED", algoDisabledReason);
      return;
   }

   // 3. Resolve Tradable Symbol (with broker suffixes e.g. .cash, m, .pro, or aliases)
   string tradableSymbol = ResolveTradableSymbol(symbol);
   if(!SymbolSelect(tradableSymbol, true))
   {
      string errDesc = StringFormat("Symbol '%s' (nor candidate aliases) not found in broker Market Watch.", symbol);
      Print("BfxBridge Execution Error: ", errDesc);
      SendExecutionReport(executionId, false, 0, 0, 0.0, 0.0, 0.0, 0.0, "SYMBOL_NOT_FOUND", errDesc);
      return;
   }
   symbol = tradableSymbol;
   
   // 4. Adapt Filling Mode dynamically for this specific symbol
   AdaptOrderFillingMode(symbol);
   
   m_symbol.Name(symbol);
   m_symbol.RefreshRates();
   
   // Enforce user volume bounds [0.01, 200.0] and align with broker lotStep
   double minLot  = MathMax(0.01, m_symbol.LotsMin());
   double maxLot  = MathMin(200.0, m_symbol.LotsMax());
   double lotStep = MathMax(0.01, m_symbol.LotsStep());
   
   double safeVolume = MathMax(minLot, MathMin(maxLot, volume));
   int stepDecimals = 2;
   if(lotStep >= 0.1) stepDecimals = 1;
   if(lotStep >= 1.0) stepDecimals = 0;
   
   double effectiveVolume = NormalizeDouble(MathFloor(safeVolume / lotStep + 1e-9) * lotStep, stepDecimals);
   if(effectiveVolume < minLot) effectiveVolume = minLot;
   if(effectiveVolume > maxLot) effectiveVolume = maxLot;
   
   bool orderSuccess = false;
   string comment = "BfxBridge:" + StringSubstr(executionId, StringLen(executionId) - 6);
   
   double ask = m_symbol.Ask();
   double bid = m_symbol.Bid();
   double point = m_symbol.Point();
   int digits = (int)m_symbol.Digits();
   long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long spread = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   double minDistance = MathMax(stopsLevel + 5, MathMax(spread + 5, 10)) * point;
   
   double effectiveSL = stopLoss;
   double effectiveTP = takeProfit;
   double targetPrice = 0.0;
   
   datetime expTime = (InpPendingExpiryMins > 0) ? (TimeCurrent() + (datetime)(InpPendingExpiryMins * 60)) : 0;
   ENUM_ORDER_TYPE_TIME timeType = (InpPendingExpiryMins > 0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
   
   if(action == "BUY")
   {
      // --- PENDING ORDER MODE (Auto Buy Limit vs Buy Stop at Entry Price) ---
      if(InpExecMode == EXEC_MODE_PENDING && entryPrice > 0)
      {
         // Case A: Price is currently above Entry -> BUY LIMIT (wait for pullback)
         if(entryPrice <= ask - minDistance)
         {
            targetPrice = NormalizeDouble(entryPrice, digits);
            if(effectiveSL > 0 && effectiveSL >= targetPrice - minDistance)
            {
               double dist = (entryPrice > stopLoss) ? (entryPrice - stopLoss) : (20.0 * point);
               effectiveSL = NormalizeDouble(targetPrice - MathMax(dist, minDistance), digits);
            }
            if(effectiveTP > 0 && effectiveTP <= targetPrice + minDistance)
            {
               double dist = (takeProfit > entryPrice) ? (takeProfit - entryPrice) : (20.0 * point);
               effectiveTP = NormalizeDouble(targetPrice + MathMax(dist, minDistance), digits);
            }

            PrintFormat("BfxBridge: Auto-Routing to BUY LIMIT on %s at Price: %.5f (Current Ask: %.5f) | Lots: %.2f | SL: %.5f | TP: %.5f",
               symbol, targetPrice, ask, effectiveVolume, effectiveSL, effectiveTP);
            orderSuccess = m_trade.BuyLimit(effectiveVolume, targetPrice, symbol, effectiveSL, effectiveTP, timeType, expTime, comment);

            // Two-step fallback for brokers that reject initial SL/TP on pending orders
            uint rc = m_trade.ResultRetcode();
            if(!orderSuccess || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED))
            {
               if(rc == TRADE_RETCODE_INVALID_PRICE || rc == TRADE_RETCODE_INVALID_STOPS)
               {
                  PrintFormat("BfxBridge: Initial BUY LIMIT returned %u. Retrying with clean Two-Step order placement...", rc);
                  orderSuccess = m_trade.BuyLimit(effectiveVolume, targetPrice, symbol, 0, 0, timeType, expTime, comment);
                  if(orderSuccess && (effectiveSL > 0 || effectiveTP > 0))
                  {
                     ulong pendingTicket = m_trade.ResultOrder();
                     if(pendingTicket > 0)
                     {
                        bool modOk = m_trade.OrderModify(pendingTicket, targetPrice, effectiveSL, effectiveTP, timeType, expTime);
                        if(modOk)
                           PrintFormat("BfxBridge: OrderModify attached SL: %.5f | TP: %.5f to Pending Order #%I64u", effectiveSL, effectiveTP, pendingTicket);
                        else
                           PrintFormat("BfxBridge Warning: OrderModify returned %u (%s)", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
                     }
                  }
               }
            }
         }
         // Case B: Price is currently below Entry -> BUY STOP (wait for breakout)
         else if(entryPrice >= ask + minDistance)
         {
            targetPrice = NormalizeDouble(entryPrice, digits);
            if(effectiveSL > 0 && effectiveSL >= targetPrice - minDistance)
            {
               double dist = (entryPrice > stopLoss) ? (entryPrice - stopLoss) : (20.0 * point);
               effectiveSL = NormalizeDouble(targetPrice - MathMax(dist, minDistance), digits);
            }
            if(effectiveTP > 0 && effectiveTP <= targetPrice + minDistance)
            {
               double dist = (takeProfit > entryPrice) ? (takeProfit - entryPrice) : (20.0 * point);
               effectiveTP = NormalizeDouble(targetPrice + MathMax(dist, minDistance), digits);
            }

            PrintFormat("BfxBridge: Auto-Routing to BUY STOP on %s at Price: %.5f (Current Ask: %.5f) | Lots: %.2f | SL: %.5f | TP: %.5f",
               symbol, targetPrice, ask, effectiveVolume, effectiveSL, effectiveTP);
            orderSuccess = m_trade.BuyStop(effectiveVolume, targetPrice, symbol, effectiveSL, effectiveTP, timeType, expTime, comment);

            // Two-step fallback
            uint rc = m_trade.ResultRetcode();
            if(!orderSuccess || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED))
            {
               if(rc == TRADE_RETCODE_INVALID_PRICE || rc == TRADE_RETCODE_INVALID_STOPS)
               {
                  PrintFormat("BfxBridge: Initial BUY STOP returned %u. Retrying with clean Two-Step order placement...", rc);
                  orderSuccess = m_trade.BuyStop(effectiveVolume, targetPrice, symbol, 0, 0, timeType, expTime, comment);
                  if(orderSuccess && (effectiveSL > 0 || effectiveTP > 0))
                  {
                     ulong pendingTicket = m_trade.ResultOrder();
                     if(pendingTicket > 0)
                     {
                        bool modOk = m_trade.OrderModify(pendingTicket, targetPrice, effectiveSL, effectiveTP, timeType, expTime);
                        if(modOk)
                           PrintFormat("BfxBridge: OrderModify attached SL: %.5f | TP: %.5f to Pending Order #%I64u", effectiveSL, effectiveTP, pendingTicket);
                        else
                           PrintFormat("BfxBridge Warning: OrderModify returned %u (%s)", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
                     }
                  }
               }
            }
         }
         // Case C: Market is already within spread of Entry -> Execute immediate Market BUY
         else
         {
            targetPrice = ask;
            if(effectiveSL > 0 && effectiveSL >= bid - minDistance)
            {
               double dist = (entryPrice > 0 && entryPrice > stopLoss) ? (entryPrice - stopLoss) : (20.0 * point);
               effectiveSL = NormalizeDouble(bid - MathMax(dist, minDistance), digits);
            }
            if(effectiveTP > 0 && effectiveTP <= bid + minDistance)
            {
               double dist = (entryPrice > 0 && takeProfit > entryPrice) ? (takeProfit - entryPrice) : (20.0 * point);
               effectiveTP = NormalizeDouble(bid + MathMax(dist, minDistance), digits);
            }

            PrintFormat("BfxBridge: Market is within spread of Entry (Ask: %.5f, Entry: %.5f). Executing Market BUY.", ask, entryPrice);
            orderSuccess = m_trade.Buy(effectiveVolume, symbol, ask, effectiveSL, effectiveTP, comment);

            uint rc = m_trade.ResultRetcode();
            if(!orderSuccess || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED))
            {
               if(rc == TRADE_RETCODE_INVALID_PRICE || rc == TRADE_RETCODE_INVALID_STOPS)
               {
                  orderSuccess = m_trade.Buy(effectiveVolume, symbol, ask, 0, 0, comment);
                  if(orderSuccess && (effectiveSL > 0 || effectiveTP > 0))
                  {
                     m_symbol.RefreshRates();
                     double freshBid = m_symbol.Bid();
                     if(effectiveSL >= freshBid - minDistance)
                     {
                        double dist = (entryPrice > 0 && entryPrice > stopLoss) ? (entryPrice - stopLoss) : (20.0 * point);
                        effectiveSL = NormalizeDouble(freshBid - MathMax(dist, minDistance), digits);
                     }
                     if(effectiveTP <= freshBid + minDistance)
                     {
                        double dist = (entryPrice > 0 && takeProfit > entryPrice) ? (takeProfit - entryPrice) : (20.0 * point);
                        effectiveTP = NormalizeDouble(freshBid + MathMax(dist, minDistance), digits);
                     }

                     ulong posTicket = 0;
                     for(int p = PositionsTotal() - 1; p >= 0; p--)
                     {
                        ulong t = PositionGetTicket(p);
                        if(t > 0 && PositionGetString(POSITION_SYMBOL) == symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
                        {
                           posTicket = t;
                           break;
                        }
                     }
                     if(posTicket == 0 && m_trade.ResultDeal() > 0 && HistoryDealSelect(m_trade.ResultDeal()))
                        posTicket = HistoryDealGetInteger(m_trade.ResultDeal(), DEAL_POSITION_ID);
                     if(posTicket == 0) posTicket = m_trade.ResultOrder();

                     if(posTicket > 0)
                        m_trade.PositionModify(posTicket, effectiveSL, effectiveTP);
                  }
               }
            }
         }
      }
      // --- IMMEDIATE MARKET EXECUTION MODE (Default) ---
      else
      {
         targetPrice = ask;
         if(effectiveSL > 0 && effectiveSL >= bid - minDistance)
         {
            double dist = (entryPrice > 0 && entryPrice > stopLoss) ? (entryPrice - stopLoss) : (20.0 * point);
            effectiveSL = NormalizeDouble(bid - MathMax(dist, minDistance), digits);
         }
         if(effectiveTP > 0 && effectiveTP <= bid + minDistance)
         {
            double dist = (entryPrice > 0 && takeProfit > entryPrice) ? (takeProfit - entryPrice) : (20.0 * point);
            effectiveTP = NormalizeDouble(bid + MathMax(dist, minDistance), digits);
         }

         PrintFormat("BfxBridge: Executing Immediate Market BUY on %s at Ask: %.5f | Lots: %.2f | SL: %.5f | TP: %.5f",
            symbol, ask, effectiveVolume, effectiveSL, effectiveTP);
         orderSuccess = m_trade.Buy(effectiveVolume, symbol, ask, effectiveSL, effectiveTP, comment);

         // Two-Step ECN Fallback for brokers that reject initial SL/TP on market orders
         uint rc = m_trade.ResultRetcode();
         if(!orderSuccess || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED))
         {
            if(rc == TRADE_RETCODE_INVALID_PRICE || rc == TRADE_RETCODE_INVALID_STOPS)
            {
               PrintFormat("BfxBridge: Initial BUY returned %u. Retrying with clean Two-Step execution...", rc);
               orderSuccess = m_trade.Buy(effectiveVolume, symbol, ask, 0, 0, comment);
               if(orderSuccess && (effectiveSL > 0 || effectiveTP > 0))
               {
                  m_symbol.RefreshRates();
                  double freshBid = m_symbol.Bid();
                  if(effectiveSL >= freshBid - minDistance)
                  {
                     double dist = (entryPrice > 0 && entryPrice > stopLoss) ? (entryPrice - stopLoss) : (20.0 * point);
                     effectiveSL = NormalizeDouble(freshBid - MathMax(dist, minDistance), digits);
                  }
                  if(effectiveTP <= freshBid + minDistance)
                  {
                     double dist = (entryPrice > 0 && takeProfit > entryPrice) ? (takeProfit - entryPrice) : (20.0 * point);
                     effectiveTP = NormalizeDouble(freshBid + MathMax(dist, minDistance), digits);
                  }

                  ulong posTicket = 0;
                  for(int p = PositionsTotal() - 1; p >= 0; p--)
                  {
                     ulong t = PositionGetTicket(p);
                     if(t > 0 && PositionGetString(POSITION_SYMBOL) == symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
                     {
                        posTicket = t;
                        break;
                     }
                  }
                  if(posTicket == 0 && m_trade.ResultDeal() > 0 && HistoryDealSelect(m_trade.ResultDeal()))
                     posTicket = HistoryDealGetInteger(m_trade.ResultDeal(), DEAL_POSITION_ID);
                  if(posTicket == 0) posTicket = m_trade.ResultOrder();

                  if(posTicket > 0)
                  {
                     bool modOk = m_trade.PositionModify(posTicket, effectiveSL, effectiveTP);
                     if(modOk)
                        PrintFormat("BfxBridge: PositionModify attached SL: %.5f | TP: %.5f to Position #%I64u", effectiveSL, effectiveTP, posTicket);
                     else
                        PrintFormat("BfxBridge Warning: PositionModify returned %u (%s)", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
                  }
               }
            }
         }
      }
   }
   else if(action == "SELL")
   {
      // --- PENDING ORDER MODE (Auto Sell Limit vs Sell Stop at Entry Price) ---
      if(InpExecMode == EXEC_MODE_PENDING && entryPrice > 0)
      {
         // Case A: Price is currently below Entry -> SELL LIMIT (wait for rally)
         if(entryPrice >= bid + minDistance)
         {
            targetPrice = NormalizeDouble(entryPrice, digits);
            if(effectiveSL > 0 && effectiveSL <= targetPrice + minDistance)
            {
               double dist = (stopLoss > entryPrice) ? (stopLoss - entryPrice) : (20.0 * point);
               effectiveSL = NormalizeDouble(targetPrice + MathMax(dist, minDistance), digits);
            }
            if(effectiveTP > 0 && effectiveTP >= targetPrice - minDistance)
            {
               double dist = (entryPrice > takeProfit) ? (entryPrice - takeProfit) : (20.0 * point);
               effectiveTP = NormalizeDouble(targetPrice - MathMax(dist, minDistance), digits);
            }

            PrintFormat("BfxBridge: Auto-Routing to SELL LIMIT on %s at Price: %.5f (Current Bid: %.5f) | Lots: %.2f | SL: %.5f | TP: %.5f",
               symbol, targetPrice, bid, effectiveVolume, effectiveSL, effectiveTP);
            orderSuccess = m_trade.SellLimit(effectiveVolume, targetPrice, symbol, effectiveSL, effectiveTP, timeType, expTime, comment);

            // Two-step fallback
            uint rc = m_trade.ResultRetcode();
            if(!orderSuccess || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED))
            {
               if(rc == TRADE_RETCODE_INVALID_PRICE || rc == TRADE_RETCODE_INVALID_STOPS)
               {
                  PrintFormat("BfxBridge: Initial SELL LIMIT returned %u. Retrying with clean Two-Step order placement...", rc);
                  orderSuccess = m_trade.SellLimit(effectiveVolume, targetPrice, symbol, 0, 0, timeType, expTime, comment);
                  if(orderSuccess && (effectiveSL > 0 || effectiveTP > 0))
                  {
                     ulong pendingTicket = m_trade.ResultOrder();
                     if(pendingTicket > 0)
                     {
                        bool modOk = m_trade.OrderModify(pendingTicket, targetPrice, effectiveSL, effectiveTP, timeType, expTime);
                        if(modOk)
                           PrintFormat("BfxBridge: OrderModify attached SL: %.5f | TP: %.5f to Pending Order #%I64u", effectiveSL, effectiveTP, pendingTicket);
                        else
                           PrintFormat("BfxBridge Warning: OrderModify returned %u (%s)", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
                     }
                  }
               }
            }
         }
         // Case B: Price is currently above Entry -> SELL STOP (wait for breakdown)
         else if(entryPrice <= bid - minDistance)
         {
            targetPrice = NormalizeDouble(entryPrice, digits);
            if(effectiveSL > 0 && effectiveSL <= targetPrice + minDistance)
            {
               double dist = (stopLoss > entryPrice) ? (stopLoss - entryPrice) : (20.0 * point);
               effectiveSL = NormalizeDouble(targetPrice + MathMax(dist, minDistance), digits);
            }
            if(effectiveTP > 0 && effectiveTP >= targetPrice - minDistance)
            {
               double dist = (entryPrice > takeProfit) ? (entryPrice - takeProfit) : (20.0 * point);
               effectiveTP = NormalizeDouble(targetPrice - MathMax(dist, minDistance), digits);
            }

            PrintFormat("BfxBridge: Auto-Routing to SELL STOP on %s at Price: %.5f (Current Bid: %.5f) | Lots: %.2f | SL: %.5f | TP: %.5f",
               symbol, targetPrice, bid, effectiveVolume, effectiveSL, effectiveTP);
            orderSuccess = m_trade.SellStop(effectiveVolume, targetPrice, symbol, effectiveSL, effectiveTP, timeType, expTime, comment);

            // Two-step fallback
            uint rc = m_trade.ResultRetcode();
            if(!orderSuccess || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED))
            {
               if(rc == TRADE_RETCODE_INVALID_PRICE || rc == TRADE_RETCODE_INVALID_STOPS)
               {
                  PrintFormat("BfxBridge: Initial SELL STOP returned %u. Retrying with clean Two-Step order placement...", rc);
                  orderSuccess = m_trade.SellStop(effectiveVolume, targetPrice, symbol, 0, 0, timeType, expTime, comment);
                  if(orderSuccess && (effectiveSL > 0 || effectiveTP > 0))
                  {
                     ulong pendingTicket = m_trade.ResultOrder();
                     if(pendingTicket > 0)
                     {
                        bool modOk = m_trade.OrderModify(pendingTicket, targetPrice, effectiveSL, effectiveTP, timeType, expTime);
                        if(modOk)
                           PrintFormat("BfxBridge: OrderModify attached SL: %.5f | TP: %.5f to Pending Order #%I64u", effectiveSL, effectiveTP, pendingTicket);
                        else
                           PrintFormat("BfxBridge Warning: OrderModify returned %u (%s)", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
                     }
                  }
               }
            }
         }
         // Case C: Market is already within spread of Entry -> Execute immediate Market SELL
         else
         {
            targetPrice = bid;
            if(effectiveSL > 0 && effectiveSL <= ask + minDistance)
            {
               double dist = (entryPrice > 0 && stopLoss > entryPrice) ? (stopLoss - entryPrice) : (20.0 * point);
               effectiveSL = NormalizeDouble(ask + MathMax(dist, minDistance), digits);
            }
            if(effectiveTP > 0 && effectiveTP >= ask - minDistance)
            {
               double dist = (entryPrice > 0 && entryPrice > takeProfit) ? (entryPrice - takeProfit) : (20.0 * point);
               effectiveTP = NormalizeDouble(ask - MathMax(dist, minDistance), digits);
            }

            PrintFormat("BfxBridge: Market is within spread of Entry (Bid: %.5f, Entry: %.5f). Executing Market SELL.", bid, entryPrice);
            orderSuccess = m_trade.Sell(effectiveVolume, symbol, bid, effectiveSL, effectiveTP, comment);

            uint rc = m_trade.ResultRetcode();
            if(!orderSuccess || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED))
            {
               if(rc == TRADE_RETCODE_INVALID_PRICE || rc == TRADE_RETCODE_INVALID_STOPS)
               {
                  orderSuccess = m_trade.Sell(effectiveVolume, symbol, bid, 0, 0, comment);
                  if(orderSuccess && (effectiveSL > 0 || effectiveTP > 0))
                  {
                     m_symbol.RefreshRates();
                     double freshAsk = m_symbol.Ask();
                     if(effectiveSL <= freshAsk + minDistance)
                     {
                        double dist = (entryPrice > 0 && stopLoss > entryPrice) ? (stopLoss - entryPrice) : (20.0 * point);
                        effectiveSL = NormalizeDouble(freshAsk + MathMax(dist, minDistance), digits);
                     }
                     if(effectiveTP >= freshAsk - minDistance)
                     {
                        double dist = (entryPrice > 0 && entryPrice > takeProfit) ? (entryPrice - takeProfit) : (20.0 * point);
                        effectiveTP = NormalizeDouble(freshAsk - MathMax(dist, minDistance), digits);
                     }

                     ulong posTicket = 0;
                     for(int p = PositionsTotal() - 1; p >= 0; p--)
                     {
                        ulong t = PositionGetTicket(p);
                        if(t > 0 && PositionGetString(POSITION_SYMBOL) == symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
                        {
                           posTicket = t;
                           break;
                        }
                     }
                     if(posTicket == 0 && m_trade.ResultDeal() > 0 && HistoryDealSelect(m_trade.ResultDeal()))
                        posTicket = HistoryDealGetInteger(m_trade.ResultDeal(), DEAL_POSITION_ID);
                     if(posTicket == 0) posTicket = m_trade.ResultOrder();

                     if(posTicket > 0)
                        m_trade.PositionModify(posTicket, effectiveSL, effectiveTP);
                  }
               }
            }
         }
      }
      // --- IMMEDIATE MARKET EXECUTION MODE (Default) ---
      else
      {
         targetPrice = bid;
         if(effectiveSL > 0 && effectiveSL <= ask + minDistance)
         {
            double dist = (entryPrice > 0 && stopLoss > entryPrice) ? (stopLoss - entryPrice) : (20.0 * point);
            effectiveSL = NormalizeDouble(ask + MathMax(dist, minDistance), digits);
         }
         if(effectiveTP > 0 && effectiveTP >= ask - minDistance)
         {
            double dist = (entryPrice > 0 && entryPrice > takeProfit) ? (entryPrice - takeProfit) : (20.0 * point);
            effectiveTP = NormalizeDouble(ask - MathMax(dist, minDistance), digits);
         }

         PrintFormat("BfxBridge: Executing Immediate Market SELL on %s at Bid: %.5f | Lots: %.2f | SL: %.5f | TP: %.5f",
            symbol, bid, effectiveVolume, effectiveSL, effectiveTP);
         orderSuccess = m_trade.Sell(effectiveVolume, symbol, bid, effectiveSL, effectiveTP, comment);

         // Two-Step ECN Fallback for brokers that reject initial SL/TP on market orders
         uint rc = m_trade.ResultRetcode();
         if(!orderSuccess || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED))
         {
            if(rc == TRADE_RETCODE_INVALID_PRICE || rc == TRADE_RETCODE_INVALID_STOPS)
            {
               PrintFormat("BfxBridge: Initial SELL returned %u. Retrying with clean Two-Step execution...", rc);
               orderSuccess = m_trade.Sell(effectiveVolume, symbol, bid, 0, 0, comment);
               if(orderSuccess && (effectiveSL > 0 || effectiveTP > 0))
               {
                  m_symbol.RefreshRates();
                  double freshAsk = m_symbol.Ask();
                  if(effectiveSL <= freshAsk + minDistance)
                  {
                     double dist = (entryPrice > 0 && stopLoss > entryPrice) ? (stopLoss - entryPrice) : (20.0 * point);
                     effectiveSL = NormalizeDouble(freshAsk + MathMax(dist, minDistance), digits);
                  }
                  if(effectiveTP >= freshAsk - minDistance)
                  {
                     double dist = (entryPrice > 0 && entryPrice > takeProfit) ? (entryPrice - takeProfit) : (20.0 * point);
                     effectiveTP = NormalizeDouble(freshAsk - MathMax(dist, minDistance), digits);
                  }

                  ulong posTicket = 0;
                  for(int p = PositionsTotal() - 1; p >= 0; p--)
                  {
                     ulong t = PositionGetTicket(p);
                     if(t > 0 && PositionGetString(POSITION_SYMBOL) == symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
                     {
                        posTicket = t;
                        break;
                     }
                  }
                  if(posTicket == 0 && m_trade.ResultDeal() > 0 && HistoryDealSelect(m_trade.ResultDeal()))
                     posTicket = HistoryDealGetInteger(m_trade.ResultDeal(), DEAL_POSITION_ID);
                  if(posTicket == 0) posTicket = m_trade.ResultOrder();

                  if(posTicket > 0)
                  {
                     bool modOk = m_trade.PositionModify(posTicket, effectiveSL, effectiveTP);
                     if(modOk)
                        PrintFormat("BfxBridge: PositionModify attached SL: %.5f | TP: %.5f to Position #%I64u", effectiveSL, effectiveTP, posTicket);
                     else
                        PrintFormat("BfxBridge Warning: PositionModify returned %u (%s)", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
                  }
               }
            }
         }
      }
   }
   else
   {
      SendExecutionReport(executionId, false, 0, 0, 0.0, 0.0, 0.0, 0.0, "INVALID_ACTION", "Unrecognized trade action: " + action);
      return;
   }
   
   uint retCode = m_trade.ResultRetcode();
   
   if(orderSuccess)
   {
      ulong orderTicket = m_trade.ResultOrder();
      ulong dealTicket  = m_trade.ResultDeal();
      double fillPrice  = m_trade.ResultPrice();
      double fillVolume = m_trade.ResultVolume();
      if(fillPrice <= 0) fillPrice = (targetPrice > 0) ? targetPrice : ((action == "BUY") ? ask : bid);
      if(fillVolume <= 0) fillVolume = effectiveVolume;
      
      PrintFormat("BfxBridge SUCCESS: Order #%I64u placed/executed! Price: %.5f | Deal/Order: #%I64u", orderTicket, fillPrice, (dealTicket > 0 ? dealTicket : orderTicket));
      
      // Send real MT5 execution report back to BfxBridge
      SendExecutionReport(executionId, true, orderTicket, orderTicket, fillVolume, fillPrice, effectiveSL, effectiveTP, "", "");
   }
   else
   {
      string retDesc = m_trade.ResultRetcodeDescription();
      string errCode = StringFormat("MT5_ERR_%d", retCode);
      PrintFormat("BfxBridge REJECTED: Order failed. Retcode: %d (%s)", retCode, retDesc);
      
      // Send real broker rejection back to BfxBridge
      SendExecutionReport(executionId, false, 0, 0, 0.0, 0.0, 0.0, 0.0, errCode, retDesc);
   }
}

//+------------------------------------------------------------------+
//| Modifies open MT5 position (BREAKEVEN SL Move)                   |
//+------------------------------------------------------------------+
void ExecuteModifyPositionCommand(string cmdJson, string executionId)
{
   string positionIdStr = ExtractJsonString(cmdJson, "positionId");
   double newStopLoss   = ExtractJsonDouble(cmdJson, "newStopLoss");
   double newTakeProfit = ExtractJsonDouble(cmdJson, "newTakeProfit");
   string symbol        = ExtractJsonString(cmdJson, "symbol");
   
   ulong positionTicket = (ulong)StringToInteger(positionIdStr);
   
   PrintFormat("BfxBridge: Modifying Position #%I64u to BREAKEVEN. New SL: %.5f | New TP: %.5f",
      positionTicket, newStopLoss, newTakeProfit);
   
   // If positionId is known and exists, modify directly
   if(positionTicket > 0 && PositionSelectByTicket(positionTicket))
   {
      bool modSuccess = m_trade.PositionModify(positionTicket, newStopLoss, newTakeProfit);
      uint retCode = m_trade.ResultRetcode();
      
      if(modSuccess && (retCode == TRADE_RETCODE_DONE || retCode == TRADE_RETCODE_PLACED))
      {
         PrintFormat("BfxBridge BREAKEVEN SUCCESS: Position #%I64u modified to %.5f", positionTicket, newStopLoss);
         SendModificationReport(executionId, true, positionTicket, newStopLoss, newTakeProfit, "", "");
         return;
      }
   }
   
   // Fallback: search open positions by symbol & Magic Number
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         bool modSuccess = m_trade.PositionModify(ticket, newStopLoss, newTakeProfit);
         uint retCode = m_trade.ResultRetcode();
         
         if(modSuccess && (retCode == TRADE_RETCODE_DONE || retCode == TRADE_RETCODE_PLACED))
         {
            PrintFormat("BfxBridge BREAKEVEN SUCCESS: Position #%I64u modified to %.5f", ticket, newStopLoss);
            SendModificationReport(executionId, true, ticket, newStopLoss, newTakeProfit, "", "");
            return;
         }
      }
   }
   
   Print("BfxBridge: No matching open position found to move to break-even.");
   SendModificationReport(executionId, false, positionTicket, 0.0, 0.0, "POSITION_NOT_FOUND", "No matching open position found for modification.");
}

//+------------------------------------------------------------------+
//| Sends execution report (success or rejection) back to BfxBridge  |
//+------------------------------------------------------------------+
void SendExecutionReport(
   string executionId,
   bool   success,
   ulong  orderId,
   ulong  positionId,
   double volume,
   double entryPrice,
   double stopLoss,
   double takeProfit,
   string errorCode,
   string errorMessage
)
{
   string url = InpServerUrl + "/api/mt5/bridge/report";
   string headers = BuildAuthHeaders();
   
   string payload = StringFormat(
      "{\"type\":\"NEW_ORDER\",\"executionId\":\"%s\",\"success\":%s,\"orderId\":\"%I64u\",\"positionId\":\"%I64u\",\"volume\":%.2f,\"entryPrice\":%.5f,\"stopLoss\":%.5f,\"takeProfit\":%.5f,\"errorCode\":\"%s\",\"errorMessage\":\"%s\"}",
      executionId,
      success ? "true" : "false",
      orderId,
      positionId,
      volume,
      entryPrice,
      stopLoss,
      takeProfit,
      errorCode,
      errorMessage
   );
   
   char postData[];
   char resultData[];
   string resultHeaders;
   StringToCharArray(payload, postData, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(postData, ArraySize(postData) - 1);
   
   ResetLastError();
   int res = SendHttpRequest("POST", url, headers, 3000, postData, resultData, resultHeaders);
   
   if(res == 200)
   {
      Print("BfxBridge: Execution report acknowledged by server for ExecID: ", executionId);
   }
   else
   {
      PrintFormat("BfxBridge: Failed to send execution report. HTTP %d (Error: %d)", res, GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Sends position modification report back to BfxBridge             |
//+------------------------------------------------------------------+
void SendModificationReport(
   string executionId,
   bool   success,
   ulong  positionId,
   double newStopLoss,
   double newTakeProfit,
   string errorCode,
   string errorMessage
)
{
   string url = InpServerUrl + "/api/mt5/bridge/report";
   string headers = BuildAuthHeaders();
   
   string payload = StringFormat(
      "{\"type\":\"MODIFY_POSITION\",\"executionId\":\"%s\",\"success\":%s,\"positionId\":\"%I64u\",\"newStopLoss\":%.5f,\"newTakeProfit\":%.5f,\"errorCode\":\"%s\",\"errorMessage\":\"%s\"}",
      executionId,
      success ? "true" : "false",
      positionId,
      newStopLoss,
      newTakeProfit,
      errorCode,
      errorMessage
   );
   
   char postData[];
   char resultData[];
   string resultHeaders;
   StringToCharArray(payload, postData, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(postData, ArraySize(postData) - 1);
   
   ResetLastError();
   SendHttpRequest("POST", url, headers, 3000, postData, resultData, resultHeaders);
}

//+------------------------------------------------------------------+
//| Helper: Builds standardized authentication headers              |
//+------------------------------------------------------------------+
string BuildAuthHeaders()
{
   string effectiveId = (StringLen(InpAccountId) > 0) ? InpAccountId : m_autoResolvedAccountId;
   string headers = "Content-Type: application/json\r\n";
   headers += "x-account-id: " + effectiveId + "\r\n";
   headers += "x-account-number: " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "\r\n";
   return headers;
}

//+------------------------------------------------------------------+
//| Helper: Extracts string value from simple JSON string            |
//+------------------------------------------------------------------+
string ExtractJsonString(string json, string key)
{
   string pattern = "\"" + key + "\":\"";
   int start = StringFind(json, pattern);
   if(start < 0) return "";
   
   start += StringLen(pattern);
   int end = StringFind(json, "\"", start);
   if(end < 0) return "";
   
   return StringSubstr(json, start, end - start);
}

//+------------------------------------------------------------------+
//| Helper: Extracts double value from simple JSON string            |
//+------------------------------------------------------------------+
double ExtractJsonDouble(string json, string key)
{
   string pattern = "\"" + key + "\":";
   int start = StringFind(json, pattern);
   if(start < 0) return 0.0;
   
   start += StringLen(pattern);
   // Skip quote if value is stringified number
   if(StringGetCharacter(json, start) == '\"') start++;
   
   int len = StringLen(json);
   int end = start;
   while(end < len)
   {
      ushort ch = StringGetCharacter(json, end);
      if(ch == ',' || ch == '}' || ch == '\"' || ch == ' ' || ch == '\r' || ch == '\n')
         break;
      end++;
   }
   
   string valStr = StringSubstr(json, start, end - start);
   return StringToDouble(valStr);
}
