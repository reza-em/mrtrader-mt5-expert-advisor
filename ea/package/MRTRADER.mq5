//+------------------------------------------------------------------+
//| MRTRADER.mq5                                                     |
//| Simple Ninja-style bot for Alpari MT5                            |
//| Gold + Forex | pending breakout | news pause | no grid           |
//+------------------------------------------------------------------+
#property copyright "MRTRADER"
#property version   "1.00"
#property description "Simple gold/forex robot. Buy Stop / Sell Stop. Forex Factory news. No martingale, no grid."

#include <Trade/Trade.mqh>

CTrade trade;

input group "=== Symbols ==="
input string InpSymbols        = "XAUUSD,EURUSD";
input ENUM_TIMEFRAMES InpTF    = PERIOD_H1;

input group "=== Ninja entry ==="
input int    InpLookback       = 10;    // bars for recent high/low
input int    InpBufferPoints   = 50;    // extra distance above/below (gold needs more)
input int    InpExpireBars     = 6;     // cancel pending after N bars

input group "=== Risk ==="
input double InpRiskPercent    = 0.5;
input double InpSL_ATR         = 2.0;
input double InpTP_ATR         = 3.0;
input int    InpATRPeriod      = 14;
input double InpMaxLot         = 0.30;
input int    InpMagic          = 8801;
input int    InpSlippage       = 40;
input bool   InpAllowTrading   = true;

input group "=== Forex Factory ==="
input bool   InpUseNews        = true;
input int    InpNewsBefore     = 30;
input int    InpNewsAfter      = 30;
input string InpNewsUrl        = "https://nfs.faireconomy.media/ff_calendar_thisweek.xml";
input string InpNewsFx         = "USD,EUR,GBP";

input group "=== Hours (broker server) ==="
input int    InpStartHour      = 7;
input int    InpEndHour        = 21;

string   g_sym[];
int      g_atr[];
datetime g_bar[];
string   g_xml = "";
datetime g_xml_at = 0;
string   g_note = "ready";

int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   StringSplit(InpSymbols, ',', g_sym);
   int n = ArraySize(g_sym);
   if(n < 1)
      return(INIT_PARAMETERS_INCORRECT);

   ArrayResize(g_atr, n);
   ArrayResize(g_bar, n);

   for(int i=0;i<n;i++)
     {
      StringTrimLeft(g_sym[i]);
      StringTrimRight(g_sym[i]);
      g_atr[i] = iATR(g_sym[i], InpTF, InpATRPeriod);
      g_bar[i] = 0;
     }

   EventSetTimer(60);
   LoadNews();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
   for(int i=0;i<ArraySize(g_atr);i++)
      if(g_atr[i]!=INVALID_HANDLE) IndicatorRelease(g_atr[i]);
  }

void OnTimer()
  {
   if(InpUseNews) LoadNews();
   Panel();
  }

void OnTick()
  {
   Panel();
   if(!InpAllowTrading) return;
   if(!HourOk()) return;

   for(int i=0;i<ArraySize(g_sym);i++)
     {
      string s = g_sym[i];
      if(!SymbolSelect(s, true)) continue;
      if(g_atr[i]==INVALID_HANDLE) continue;
      if(!NewBar(i,s)) continue;

      if(InpUseNews && NewsNear(s))
        {
         CancelPendings(s);
         g_note = s+" news pause";
         continue;
        }

      if(HasPosition(s))
        {
         CancelPendings(s);
         continue;
        }

      PlaceBreakout(i, s);
     }
  }

bool NewBar(const int i, const string s)
  {
   datetime t = iTime(s, InpTF, 0);
   if(t==0 || t==g_bar[i]) return(false);
   g_bar[i]=t;
   return(true);
  }

bool HourOk()
  {
   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);
   if(InpStartHour==InpEndHour) return(true);
   if(InpStartHour<InpEndHour) return(d.hour>=InpStartHour && d.hour<InpEndHour);
   return(d.hour>=InpStartHour || d.hour<InpEndHour);
  }

double AtrVal(const int i)
  {
   double a[1];
   if(CopyBuffer(g_atr[i], 0, 1, 1, a)<1) return(0);
   return(a[0]);
  }

void SetFill(const string s)
  {
   long f = SymbolInfoInteger(s, SYMBOL_FILLING_MODE);
   if((f & SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((f & SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else trade.SetTypeFilling(ORDER_FILLING_RETURN);
  }

bool HasPosition(const string s)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(PositionGetTicket(i)==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=s) continue;
      if((int)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      return(true);
     }
   return(false);
  }

int CountPendings(const string s)
  {
   int c=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong t = OrderGetTicket(i);
      if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=s) continue;
      if((int)OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      c++;
     }
   return(c);
  }

void CancelPendings(const string s)
  {
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong t = OrderGetTicket(i);
      if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=s) continue;
      if((int)OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      trade.OrderDelete(t);
     }
  }

double Lots(const string s, const double sl_dist)
  {
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk = bal * InpRiskPercent / 100.0;
   double ts = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
   double vmin = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(s, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP);
   if(sl_dist<=0 || ts<=0 || tv<=0 || step<=0) return(vmin);
   double per = (sl_dist/ts)*tv;
   if(per<=0) return(vmin);
   double lots = MathFloor((risk/per)/step)*step;
   if(lots<vmin) lots=vmin;
   if(lots>vmax) lots=vmax;
   if(lots>InpMaxLot) lots=InpMaxLot;
   return(NormalizeDouble(lots,2));
  }

void PlaceBreakout(const int idx, const string s)
  {
   if(CountPendings(s)>=2) return;

   int hi_i = iHighest(s, InpTF, MODE_HIGH, InpLookback, 1);
   int lo_i = iLowest(s, InpTF, MODE_LOW, InpLookback, 1);
   if(hi_i<0 || lo_i<0) return;

   double hi = iHigh(s, InpTF, hi_i);
   double lo = iLow(s, InpTF, lo_i);
   double atr = AtrVal(idx);
   if(hi<=0 || lo<=0 || atr<=0) return;

   double pt = SymbolInfoDouble(s, SYMBOL_POINT);
   int dg = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   double buf = InpBufferPoints * pt;
   double buy_px  = NormalizeDouble(hi + buf, dg);
   double sell_px = NormalizeDouble(lo - buf, dg);

   double ask = SymbolInfoDouble(s, SYMBOL_ASK);
   double bid = SymbolInfoDouble(s, SYMBOL_BID);
   double stops = SymbolInfoInteger(s, SYMBOL_TRADE_STOPS_LEVEL) * pt;

   if(buy_px - ask < MathMax(stops, buf))
      buy_px = NormalizeDouble(ask + MathMax(stops, buf)*2, dg);
   if(bid - sell_px < MathMax(stops, buf))
      sell_px = NormalizeDouble(bid - MathMax(stops, buf)*2, dg);

   double buy_sl = NormalizeDouble(buy_px - InpSL_ATR*atr, dg);
   double buy_tp = NormalizeDouble(buy_px + InpTP_ATR*atr, dg);
   double sell_sl= NormalizeDouble(sell_px + InpSL_ATR*atr, dg);
   double sell_tp= NormalizeDouble(sell_px - InpTP_ATR*atr, dg);

   double lots = Lots(s, InpSL_ATR*atr);
   datetime exp = TimeCurrent() + PeriodSeconds(InpTF)*InpExpireBars;

   SetFill(s);
   trade.SetExpertMagicNumber(InpMagic);

   if(CountPendings(s)==0)
     {
      trade.BuyStop(lots, buy_px, s, buy_sl, buy_tp, ORDER_TIME_SPECIFIED, exp, "MRTRADER buy-stop");
      trade.SellStop(lots, sell_px, s, sell_sl, sell_tp, ORDER_TIME_SPECIFIED, exp, "MRTRADER sell-stop");
      g_note = s+" pending set";
     }
  }

void LoadNews()
  {
   if(!InpUseNews) return;
   if(g_xml_at>0 && TimeCurrent()-g_xml_at < 1800) return;
   char res[], data[];
   string hdr;
   ResetLastError();
   int code = WebRequest("GET", InpNewsUrl, "", 8000, data, res, hdr);
   if(code==-1)
     {
      g_note = "Allow WebRequest: nfs.faireconomy.media";
      return;
     }
   g_xml = CharArrayToString(res, 0, WHOLE_ARRAY, CP_UTF8);
   g_xml_at = TimeCurrent();
   g_note = "news loaded";
  }

bool NewsNear(const string s)
  {
   if(StringLen(g_xml)<20) return(false);
   string cur = SymbolInfoString(s, SYMBOL_CURRENCY_BASE)+","+
                SymbolInfoString(s, SYMBOL_CURRENCY_PROFIT)+","+
                SymbolInfoString(s, SYMBOL_CURRENCY_MARGIN);
   int pos=0;
   while(true)
     {
      int a=StringFind(g_xml,"<event>",pos);
      if(a<0) break;
      int b=StringFind(g_xml,"</event>",a);
      if(b<0) break;
      pos=b+8;
      string ev=StringSubstr(g_xml,a,b-a);
      if(StringFind(Tag(ev,"impact"),"High")<0) continue;
      string ctry=Tag(ev,"country");
      if(StringFind(InpNewsFx,ctry)<0) continue;
      if(StringFind(cur,ctry)<0 && ctry!="USD") continue;
      datetime when=ParseFF(Tag(ev,"date"), Tag(ev,"time"));
      if(when<=0) continue;
      int d=(int)(TimeCurrent()-when);
      if(d>-InpNewsBefore*60 && d<InpNewsAfter*60) return(true);
     }
   return(false);
  }

string Tag(const string xml, const string name)
  {
   string a="<"+name+">", b="</"+name+">";
   int i=StringFind(xml,a), j=StringFind(xml,b);
   if(i<0||j<=i) return("");
   string v=StringSubstr(xml,i+StringLen(a), j-i-StringLen(a));
   StringReplace(v,"<![CDATA[","");
   StringReplace(v,"]]>","");
   StringTrimLeft(v); StringTrimRight(v);
   return(v);
  }

datetime ParseFF(string d, string t)
  {
   StringReplace(d,"/","-");
   StringTrimLeft(d); StringTrimRight(d);
   StringTrimLeft(t); StringTrimRight(t);
   string p[];
   if(StringSplit(d,'-',p)<3) return(0);
   int mo=(int)StringToInteger(p[0]);
   int dy=(int)StringToInteger(p[1]);
   int yr=(int)StringToInteger(p[2]);
   if(yr<100) yr+=2000;
   bool pm=(StringFind(t,"pm")>=0 || StringFind(t,"PM")>=0);
   bool am=(StringFind(t,"am")>=0 || StringFind(t,"AM")>=0);
   StringReplace(t,"am",""); StringReplace(t,"pm","");
   StringReplace(t,"AM",""); StringReplace(t,"PM","");
   StringTrimLeft(t); StringTrimRight(t);
   int hh=0,mm=0,c=StringFind(t,":");
   if(c>0){ hh=(int)StringToInteger(StringSubstr(t,0,c)); mm=(int)StringToInteger(StringSubstr(t,c+1)); }
   else hh=(int)StringToInteger(t);
   if(pm && hh<12) hh+=12;
   if(am && hh==12) hh=0;
   datetime gmt=StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d",yr,mo,dy,hh,mm))+4*3600;
   return(gmt+(TimeCurrent()-TimeGMT()));
  }

void Panel()
  {
   double bid=SymbolInfoDouble("XAUUSD", SYMBOL_BID);
   double ask=SymbolInfoDouble("XAUUSD", SYMBOL_ASK);
   if(bid<=0){ bid=SymbolInfoDouble("GOLD", SYMBOL_BID); ask=SymbolInfoDouble("GOLD", SYMBOL_ASK); }
   string s;
   s+="========================\n";
   s+="   MRTRADER  NINJA\n";
   s+="========================\n";
   s+="Balance   "+DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2)+"\n";
   s+="Equity    "+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2)+"\n";
   s+="Margin    "+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN),2)+"\n";
   s+="Free      "+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE),2)+"\n";
   s+="PnL       "+DoubleToString(AccountInfoDouble(ACCOUNT_PROFIT),2)+"\n";
   if(bid>0) s+="Gold      "+DoubleToString(bid,2)+" / "+DoubleToString(ask,2)+"\n";
   s+="Auto      "+(InpAllowTrading?"ON":"OFF")+"\n";
   s+=g_note+"\n";
   Comment(s);
  }
