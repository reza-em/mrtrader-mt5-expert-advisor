//+------------------------------------------------------------------+
//| MRTRADER.mq5                                                     |
//| Simple Alpari / MetaTrader 5 bot: Forex + Gold + news filter     |
//+------------------------------------------------------------------+
#property copyright "MRTRADER contributors"
#property version   "1.00"
#property description "Simple trend EA for Alpari MT5. Gold + Forex. Forex Factory news pause."

#include <Trade/Trade.mqh>

CTrade trade;

input group "Symbols"
input string InpSymbols             = "XAUUSD,EURUSD,GBPUSD"; // Gold + two majors. Missing names are skipped.
input ENUM_TIMEFRAMES InpTF         = PERIOD_H1;

input group "Strategy (EMA trend)"
input int    InpFastEMA             = 21;
input int    InpSlowEMA             = 50;
input int    InpATRPeriod           = 14;
input double InpSL_ATR              = 2.0;   // stop loss = this * ATR
input double InpTP_ATR              = 3.0;   // take profit = this * ATR

input group "Risk"
input double InpRiskPercent         = 0.5;   // percent of balance per trade
input double InpMaxLot              = 0.50;
input int    InpMagic               = 8801;
input int    InpSlippagePoints      = 30;
input bool   InpAllowTrading        = true;  // false = only show account / prices

input group "Forex Factory news"
input bool   InpUseNewsFilter       = true;
input int    InpNewsMinsBefore      = 30;
input int    InpNewsMinsAfter       = 30;
input string InpNewsUrl             = "https://nfs.faireconomy.media/ff_calendar_thisweek.xml";
input string InpNewsCurrencies      = "USD,EUR,GBP"; // gold follows USD

input group "Hours (server time)"
input int    InpStartHour           = 7;
input int    InpEndHour             = 21;

string   g_symbols[];
int      g_fast_h[];
int      g_slow_h[];
int      g_atr_h[];
datetime g_last_bar[];
string   g_news_xml = "";
datetime g_news_loaded = 0;
string   g_status = "";

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   StringSplit(InpSymbols, ',', g_symbols);
   int n = ArraySize(g_symbols);
   if(n <= 0)
     {
      Print("No symbols in InpSymbols");
      return(INIT_PARAMETERS_INCORRECT);
     }

   ArrayResize(g_fast_h, n);
   ArrayResize(g_slow_h, n);
   ArrayResize(g_atr_h, n);
   ArrayResize(g_last_bar, n);

   for(int i = 0; i < n; i++)
     {
      StringTrimLeft(g_symbols[i]);
      StringTrimRight(g_symbols[i]);
      g_fast_h[i] = iMA(g_symbols[i], InpTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_slow_h[i] = iMA(g_symbols[i], InpTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_atr_h[i]  = iATR(g_symbols[i], InpTF, InpATRPeriod);
      g_last_bar[i] = 0;
      if(g_fast_h[i] == INVALID_HANDLE || g_slow_h[i] == INVALID_HANDLE || g_atr_h[i] == INVALID_HANDLE)
        {
         Print("Indicator failed for ", g_symbols[i], " (symbol may not exist on this broker)");
        }
     }

   EventSetTimer(60);
   LoadNews();
   g_status = "MRTRADER started";
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i = 0; i < ArraySize(g_fast_h); i++)
     {
      if(g_fast_h[i] != INVALID_HANDLE) IndicatorRelease(g_fast_h[i]);
      if(g_slow_h[i] != INVALID_HANDLE) IndicatorRelease(g_slow_h[i]);
      if(g_atr_h[i]  != INVALID_HANDLE) IndicatorRelease(g_atr_h[i]);
     }
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   if(InpUseNewsFilter)
      LoadNews();
   DrawPanel();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   DrawPanel();
   if(!InpAllowTrading)
      return;
   if(!IsTradeHour())
      return;

   int n = ArraySize(g_symbols);
   for(int i = 0; i < n; i++)
     {
      string sym = g_symbols[i];
      if(!SymbolSelect(sym, true))
         continue;
      if(g_fast_h[i] == INVALID_HANDLE || g_slow_h[i] == INVALID_HANDLE || g_atr_h[i] == INVALID_HANDLE)
         continue;
      if(!IsNewBar(i, sym))
         continue;

      if(InpUseNewsFilter && NewsBlocked(sym))
        {
         Print(sym, ": skip, high-impact Forex Factory news nearby");
         continue;
        }

      int signal = TrendSignal(i, sym);
      int pos = PositionDir(sym);

      if(signal == 1 && pos <= 0)
        {
         if(pos < 0)
            CloseSymbol(sym);
         OpenBuy(i, sym);
        }
      else if(signal == -1 && pos >= 0)
        {
         if(pos > 0)
            CloseSymbol(sym);
         OpenSell(i, sym);
        }
     }
  }

//+------------------------------------------------------------------+
bool IsNewBar(const int i, const string sym)
  {
   datetime t = iTime(sym, InpTF, 0);
   if(t == 0 || t == g_last_bar[i])
      return(false);
   g_last_bar[i] = t;
   return(true);
  }

bool IsTradeHour()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpStartHour == InpEndHour)
      return(true);
   if(InpStartHour < InpEndHour)
      return(dt.hour >= InpStartHour && dt.hour < InpEndHour);
   return(dt.hour >= InpStartHour || dt.hour < InpEndHour);
  }

int TrendSignal(const int i, const string sym)
  {
   double fast[3], slow[3];
   if(CopyBuffer(g_fast_h[i], 0, 0, 3, fast) < 3)
      return(0);
   if(CopyBuffer(g_slow_h[i], 0, 0, 3, slow) < 3)
      return(0);
   // buffers are series: [0]=current forming bar, [1]=last closed, [2]=previous
   double f1 = fast[1], f2 = fast[2];
   double s1 = slow[1], s2 = slow[2];
   if(f2 <= s2 && f1 > s1)
      return(1);
   if(f2 >= s2 && f1 < s1)
      return(-1);
   return(0);
  }

int PositionDir(const string sym)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)
         return(1);
      if(type == POSITION_TYPE_SELL)
         return(-1);
     }
   return(0);
  }

void SetFilling(const string sym)
  {
   long fill = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((fill & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((fill & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
  }

double Atr(const int i)
  {
   double a[2];
   if(CopyBuffer(g_atr_h[i], 0, 1, 1, a) < 1)
      return(0);
   return(a[0]);
  }

double LotsForRisk(const string sym, const double sl_distance)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk = balance * InpRiskPercent / 100.0;
   if(sl_distance <= 0 || risk <= 0)
      return(0);

   double tick_size  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double vol_min    = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vol_max    = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double vol_step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(tick_size <= 0 || tick_value <= 0 || vol_step <= 0)
      return(vol_min);

   double loss_per_lot = (sl_distance / tick_size) * tick_value;
   if(loss_per_lot <= 0)
      return(vol_min);

   double lots = risk / loss_per_lot;
   lots = MathFloor(lots / vol_step) * vol_step;
   if(lots < vol_min)
      lots = vol_min;
   if(lots > vol_max)
      lots = vol_max;
   if(lots > InpMaxLot)
      lots = InpMaxLot;
   return(NormalizeDouble(lots, 2));
  }

bool OpenBuy(const int i, const string sym)
  {
   double atr = Atr(i);
   if(atr <= 0)
      return(false);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double sl = ask - InpSL_ATR * atr;
   double tp = ask + InpTP_ATR * atr;
   double lots = LotsForRisk(sym, ask - sl);
   if(lots <= 0)
      return(false);
   SetFilling(sym);
   trade.SetExpertMagicNumber(InpMagic);
   bool ok = trade.Buy(lots, sym, ask, sl, tp, "MRTRADER buy");
   Print("BUY ", sym, " lots=", lots, " sl=", sl, " tp=", tp, " ok=", ok, " ", trade.ResultRetcodeDescription());
   return(ok);
  }

bool OpenSell(const int i, const string sym)
  {
   double atr = Atr(i);
   if(atr <= 0)
      return(false);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double sl = bid + InpSL_ATR * atr;
   double tp = bid - InpTP_ATR * atr;
   double lots = LotsForRisk(sym, sl - bid);
   if(lots <= 0)
      return(false);
   SetFilling(sym);
   trade.SetExpertMagicNumber(InpMagic);
   bool ok = trade.Sell(lots, sym, bid, sl, tp, "MRTRADER sell");
   Print("SELL ", sym, " lots=", lots, " sl=", sl, " tp=", tp, " ok=", ok, " ", trade.ResultRetcodeDescription());
   return(ok);
  }

void CloseSymbol(const string sym)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Forex Factory weekly XML                                          |
//+------------------------------------------------------------------+
void LoadNews()
  {
   if(!InpUseNewsFilter)
      return;
   if(g_news_loaded > 0 && TimeCurrent() - g_news_loaded < 30 * 60)
      return;

   char result[];
   char data[];
   string headers;
   ResetLastError();
   int code = WebRequest("GET", InpNewsUrl, "", 8000, data, result, headers);
   if(code == -1)
     {
      g_status = "News WebRequest failed. Allow URL in Tools > Options > Expert Advisors";
      Print(g_status, " err=", GetLastError());
      return;
     }
   g_news_xml = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   g_news_loaded = TimeCurrent();
   g_status = "Forex Factory calendar loaded";
  }

bool NewsBlocked(const string sym)
  {
   if(StringLen(g_news_xml) < 20)
      return(false);

   string cur = SymbolCurrency(sym);
   int pos = 0;
   while(true)
     {
      int e1 = StringFind(g_news_xml, "<event>", pos);
      if(e1 < 0)
         break;
      int e2 = StringFind(g_news_xml, "</event>", e1);
      if(e2 < 0)
         break;
      pos = e2 + 8;
      string ev = StringSubstr(g_news_xml, e1, e2 - e1);
      string impact = XmlTag(ev, "impact");
      string country = XmlTag(ev, "country");
      if(StringFind(impact, "High") < 0)
         continue;
      if(StringFind(InpNewsCurrencies, country) < 0)
         continue;
      if(StringLen(cur) > 0 && StringFind(cur, country) < 0 && country != "USD")
         continue;

      datetime when = ParseFfTime(XmlTag(ev, "date"), XmlTag(ev, "time"));
      if(when <= 0)
         continue;
      int delta = (int)(TimeCurrent() - when);
      if(delta > -InpNewsMinsBefore * 60 && delta < InpNewsMinsAfter * 60)
         return(true);
     }
   return(false);
  }

string SymbolCurrency(const string sym)
  {
   string base = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
   string profit = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
   string margin = SymbolInfoString(sym, SYMBOL_CURRENCY_MARGIN);
   return(base + "," + profit + "," + margin);
  }

string XmlTag(const string xml, const string tag)
  {
   string a = "<" + tag + ">";
   string b = "</" + tag + ">";
   int i = StringFind(xml, a);
   int j = StringFind(xml, b);
   if(i < 0 || j < 0 || j <= i)
      return("");
   string v = StringSubstr(xml, i + StringLen(a), j - i - StringLen(a));
   StringReplace(v, "<![CDATA[", "");
   StringReplace(v, "]]>", "");
   StringTrimLeft(v);
   StringTrimRight(v);
   return(v);
  }

datetime ParseFfTime(string d, string t)
  {
   // typical: date 08-19-2026  time 8:30am  (US Eastern)
   StringReplace(d, "/", "-");
   StringTrimLeft(d);
   StringTrimRight(d);
   StringTrimLeft(t);
   StringTrimRight(t);
   if(StringLen(d) < 8)
      return(0);

   string parts[];
   if(StringSplit(d, '-', parts) < 3)
      return(0);
   int month = (int)StringToInteger(parts[0]);
   int day   = (int)StringToInteger(parts[1]);
   int year  = (int)StringToInteger(parts[2]);
   if(year < 100)
      year += 2000;

   bool pm = (StringFind(t, "pm") >= 0 || StringFind(t, "PM") >= 0);
   bool am = (StringFind(t, "am") >= 0 || StringFind(t, "AM") >= 0);
   StringReplace(t, "am", "");
   StringReplace(t, "pm", "");
   StringReplace(t, "AM", "");
   StringReplace(t, "PM", "");
   StringTrimLeft(t);
   StringTrimRight(t);

   int hour = 0, minute = 0;
   int c = StringFind(t, ":");
   if(c > 0)
     {
      hour = (int)StringToInteger(StringSubstr(t, 0, c));
      minute = (int)StringToInteger(StringSubstr(t, c + 1));
     }
   else
      hour = (int)StringToInteger(t);

   if(pm && hour < 12)
      hour += 12;
   if(am && hour == 12)
      hour = 0;

   // FF times are Eastern. Convert roughly to GMT then to server.
   // EDT = GMT-4, EST = GMT-5. Use GMT-4 in Aug.
   datetime gmt = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", year, month, day, hour, minute));
   gmt += 4 * 3600;
   datetime server = gmt + (TimeCurrent() - TimeGMT());
   return(server);
  }

//+------------------------------------------------------------------+
void DrawPanel()
  {
   double bid = SymbolInfoDouble("XAUUSD", SYMBOL_BID);
   double ask = SymbolInfoDouble("XAUUSD", SYMBOL_ASK);
   if(bid <= 0)
     {
      bid = SymbolInfoDouble("GOLD", SYMBOL_BID);
      ask = SymbolInfoDouble("GOLD", SYMBOL_ASK);
     }

   string s = "";
   s += "MRTRADER  simple Alpari bot\n";
   s += "Balance     " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n";
   s += "Equity      " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "\n";
   s += "Margin      " + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN), 2) + "\n";
   s += "Free margin " + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2) + "\n";
   s += "Profit      " + DoubleToString(AccountInfoDouble(ACCOUNT_PROFIT), 2) + "\n";
   if(bid > 0)
      s += "Gold Bid/Ask " + DoubleToString(bid, 2) + " / " + DoubleToString(ask, 2) + "\n";
   s += "Trading     " + (InpAllowTrading ? "ON" : "OFF (panel only)") + "\n";
   s += g_status + "\n";
   Comment(s);
  }
//+------------------------------------------------------------------+
