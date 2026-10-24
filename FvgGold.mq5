//+------------------------------------------------------------------+
//|                                                    FvgGold.mq5    |
//|   Fair Value Gap Order-Entry EA for XAUUSD                       |
//|   Quality-scored FVG entries + OB confluence + Killzone filter   |
//|   H1 EMA bias + ATR-based TP + fixed/risk-based lot sizing       |
//|   v2.20 Production: Fixed Auth, HTTP 1003 fix & Shared Hosting   |
//+------------------------------------------------------------------+
#property copyright "FvgGold AI Trader"
#property link      ""
#property version   "2.20"
#property strict
#property description "FvgGold AI Conservative v2.20 - Gemini approval + local risk controls"

#include <Trade/Trade.mqh>

//--- Inputs: FVG detection ------------------------------------------+
input ENUM_TIMEFRAMES FVGTimeframe    = PERIOD_M15;  // Execution / FVG detection TF
input int    MinGapSize      = 25;        // Minimum FVG size (points)
input int    MaxAgeBars      = 20;        // Max FVG age in bars
input int    MinAgeBars      = 2;         // Min FVG age (bars since formation)
input double FVGBuffer       = 3.0;       // Buffer beyond FVG edge for SL (price units, e.g. $3.00)

//--- Inputs: FVG quality --------------------------------------------+
input double MinScoreFVG     = 50.0;      // Minimum FVG quality score (0-100)
input double ScoreGapWeight  = 30.0;      // Score weight: gap size (0-30)
input double ScoreDispWeight = 30.0;      // Score weight: displacement (0-30)
input double ScoreHTFWeight  = 20.0;      // Score weight: HTF alignment (0-20)
input double ScoreFreshWeight= 10.0;      // Score weight: freshness (0-10)
input double ScorePDWeight   = 10.0;      // Score weight: premium/discount (0-10)

//--- Inputs: Order Block confluence ---------------------------------+
input bool   UseOBFilter     = true;      // Require Order Block confluence
input double OB_ImpulseATR   = 1.5;       // Min impulse body = ATR * this
input int    OB_LookbackBars = 50;        // How far back to scan for OBs
input double OB_MinSize      = 10.0;      // Min OB size (points)
input double OB_ConfluenceBonus = 20.0;   // Score bonus for FVG+OB overlap
input double OB_MaxDistance  = 200.0;     // Max distance FVG-OB to count (points)

//--- Inputs: HTF Bias ------------------------------------------------+
input ENUM_TIMEFRAMES HTF_Period      = PERIOD_H1;   // Higher TF for bias
input int    EMA_Fast        = 50;        // Fast EMA for trend
input int    EMA_Slow        = 200;       // Slow EMA for trend

//--- Inputs: Risk management -----------------------------------------+
input double FixedLot        = 0.0;       // Fixed lot size (0 = risk-based calculation)
input double RiskPercent     = 0.25;      // Risk per trade in % (if FixedLot = 0)
input int    MaxTrades       = 1;         // Max concurrent trades
input double DailyLossLimit  = 5.0;       // Daily loss limit in $ (closed + floating) (0=off)
input double ATR_TP_Mult     = 2.0;       // TP = ATR * this multiplier
input double RiskRewardRatio = 1.5;       // TP = entry + SL_distance * this (fixed R:R)
input bool   UseFixedRR      = true;      // Use fixed R:R instead of ATR for TP

//--- Inputs: Killzone ------------------------------------------------+
input bool   UseKillzone     = true;      // Enable killzone filter
input int    KZ_LondonStart  = 7;         // London open start (GMT)
input int    KZ_LondonEnd    = 10;        // London open end (GMT)
input int    KZ_OverlapStart = 12;        // London/NY overlap start (GMT)
input int    KZ_OverlapEnd   = 16;        // London/NY overlap end (GMT)
input int    KZ_NYEnd        = 21;        // NY session end (GMT)
input bool   KZ_PreferOverlap= false;     // Only trade overlap (highest quality)
input bool   CloseAtEOD      = false;     // Close all at session end

//--- Inputs: Execution & Order Placement -----------------------------+
enum ENUM_EXECUTION_MODE
{
   EXEC_MARKET = 0, // Direct Market Order (trade.Buy / trade.Sell)
   EXEC_LIMIT  = 1  // Limit Order at FVG boundary (trade.BuyLimit / trade.SellLimit)
};
input ENUM_EXECUTION_MODE ExecutionMode = EXEC_MARKET; // Order Execution Mode (Market vs Limit)

//--- Inputs: Misc ----------------------------------------------------+
input ulong  MagicNumber     = 7777;
input int    SlippagePoints  = 20;

//--- AI service (Windows VPS or Shared Hosting HTTPS) ----------------
input bool   UseAIApproval       = true;       // Require Gemini approval for every new FVG order
input string AIServiceBaseURL    = "http://127.0.0.1:8787"; // Add this exact URL to MT5 WebRequest allow-list!
input string AIServiceToken      = "CHANGE_ME_TO_MATCH_ENV"; // Shared service token; must match .env AI_SERVICE_TOKEN
input int    AIRequestTimeoutMs  = 12000;      // Fail closed on timeout (12s recommended)
input double AIApprovalConfidence= 0.70;       // Minimum confidence returned by AI service
input int    AIPollSeconds       = 5;          // Status sync / heartbeat interval (seconds)
input bool   CancelPendingIfAIUnavailable = true; // Conservative fail-closed behaviour
input double MaxSpreadPoints     = 80;         // Reject entries above this spread (points)
input double ConservativeRiskPercent = 0.25;  // Risk-based sizing cap when FixedLot=0

//--- Structures ------------------------------------------------------+
struct FVGZone
{
   int       type;         // 1=bullish, -1=bearish
   double    top;          // upper edge
   double    bottom;       // lower edge
   double    midpoint;     // 50% level
   datetime  time;         // bar time of middle candle
   bool      mitigated;
   bool      orderPlaced;
   double    score;        // quality score 0-100
};

struct OrderBlock
{
   int       type;         // 1=bullish, -1=bearish
   double    top;          // OB upper edge
   double    bottom;       // OB lower edge
   datetime  time;
   bool      mitigated;
};

//--- Globals ---------------------------------------------------------+
CTrade    trade;
int       hEMAfast_htf = INVALID_HANDLE;
int       hEMAslow_htf = INVALID_HANDLE;
int       hATR_exec    = INVALID_HANDLE;
int       hATR_htf     = INVALID_HANDLE;

FVGZone   fvgZones[];
OrderBlock obZones[];

double    dailyPL       = 0.0;
double    floatingPL    = 0.0;
datetime  dailyDate     = 0;
bool      AIServiceActive = false;
datetime  lastAIStatusCheck = 0;
string    lastAIStatusText = "AI service not yet checked";

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints((ulong)(SlippagePoints * GetPipScale()));
   trade.SetTypeFillingBySymbol(Symbol());

   hEMAfast_htf = iMA(Symbol(), HTF_Period, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMAslow_htf = iMA(Symbol(), HTF_Period, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hATR_exec    = iATR(Symbol(), FVGTimeframe, 14);
   hATR_htf     = iATR(Symbol(), HTF_Period, 14);

   if(hEMAfast_htf == INVALID_HANDLE || hEMAslow_htf == INVALID_HANDLE ||
      hATR_exec == INVALID_HANDLE)
   {
      Print("ERROR: indicator handles failed to initialize");
      return(INIT_FAILED);
   }

   ArrayResize(fvgZones, 0);
   ArrayResize(obZones, 0);
   EventSetTimer(MathMax(2, AIPollSeconds));
   AIServiceActive = false;
   dailyPL = 0;
   floatingPL = 0;
   dailyDate = 0;

   // Immediate initial sync
   RefreshAIServiceState();

   Print("FvgGold AI v2.20 Initialized | TF=", EnumToString(FVGTimeframe),
         " HTF=", EnumToString(HTF_Period),
         " MinScore=", DoubleToString(MinScoreFVG, 0),
         " OB=", (UseOBFilter ? "ON" : "OFF"),
         " KZ=", (UseKillzone ? "ON" : "OFF"),
         " ServiceURL=", AIServiceBaseURL);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(hEMAfast_htf != INVALID_HANDLE) IndicatorRelease(hEMAfast_htf);
   if(hEMAslow_htf != INVALID_HANDLE) IndicatorRelease(hEMAslow_htf);
   if(hATR_exec != INVALID_HANDLE)    IndicatorRelease(hATR_exec);
   if(hATR_htf != INVALID_HANDLE)     IndicatorRelease(hATR_htf);
   ObjectsDeleteAll(0, "FVG_");
   ObjectsDeleteAll(0, "OB_");
   Comment("");
}

//+------------------------------------------------------------------+
//| Auto-detect point multiplier for 3-digit gold / 5-digit forex    |
//| Standard gold: 2 digits (_Point = 0.01)  -> scale multiplier 1.0 |
//| Exness gold:   3 digits (_Point = 0.001) -> scale multiplier 10.0|
//+------------------------------------------------------------------+
double GetPipScale()
{
   int d = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   if(d == 3 || d == 5) return 10.0;
   return 1.0;
}

//+------------------------------------------------------------------+
//| Get HTF Bias (EMA 50/200)                                        |
//+------------------------------------------------------------------+
int GetHTFBias()
{
   double emaF[1], emaS[1];
   if(CopyBuffer(hEMAfast_htf, 0, 0, 1, emaF) < 1) return(0);
   if(CopyBuffer(hEMAslow_htf, 0, 0, 1, emaS) < 1) return(0);
   if(emaF[0] > emaS[0]) return(1);
   if(emaF[0] < emaS[0]) return(-1);
   return(0);
}

//+------------------------------------------------------------------+
//| Get ATR value                                                     |
//+------------------------------------------------------------------+
double GetATR(int handle, int shift = 0)
{
   double buf[1];
   if(CopyBuffer(handle, 0, shift, 1, buf) < 1) return(0);
   return buf[0];
}

//+------------------------------------------------------------------+
//| Killzone filter                                                   |
//+------------------------------------------------------------------+
bool IsKillzoneActive()
{
   if(!UseKillzone) return(true);

   MqlDateTime dt;
   TimeGMT(dt);
   int hour = dt.hour;

   if(KZ_PreferOverlap)
      return(hour >= KZ_OverlapStart && hour < KZ_OverlapEnd);

   bool londonOpen = (hour >= KZ_LondonStart && hour < KZ_LondonEnd);
   bool overlap    = (hour >= KZ_OverlapStart && hour < KZ_OverlapEnd);
   bool nySession  = (hour >= KZ_OverlapStart && hour < KZ_NYEnd);

   return(londonOpen || overlap || nySession);
}

//+------------------------------------------------------------------+
//| Daily P/L tracking (Closed deals + Unrealized floating loss)      |
//+------------------------------------------------------------------+
void UpdateDailyPL()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today = StringToTime(IntegerToString(dt.year) + "." +
                                 IntegerToString(dt.mon) + "." +
                                 IntegerToString(dt.day));
   if(today != dailyDate)
   {
      dailyPL = 0;
      floatingPL = 0;
      dailyDate = today;
   }
}

void TrackDailyPL()
{
   HistorySelect(dailyDate, TimeCurrent());
   double closedPL = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != (long)MagicNumber) continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != Symbol()) continue;
      datetime dealTime = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
      if(dealTime < dailyDate) continue;
      closedPL += HistoryDealGetDouble(tk, DEAL_PROFIT)
                + HistoryDealGetDouble(tk, DEAL_SWAP)
                + HistoryDealGetDouble(tk, DEAL_COMMISSION);
   }
   dailyPL = closedPL;

   // Incorporate floating P/L on active positions for accurate risk control
   double curFloating = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == Symbol())
      {
         curFloating += PositionGetDouble(POSITION_PROFIT)
                      + PositionGetDouble(POSITION_SWAP);
      }
   }
   floatingPL = curFloating;
}

bool IsDailyLimitHit()
{
   if(DailyLossLimit <= 0) return(false);
   double totalNetPL = dailyPL + MathMin(0.0, floatingPL);
   return(totalNetPL <= -DailyLossLimit);
}

//+------------------------------------------------------------------+
//| Count positions + pending orders                                  |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == Symbol())
         count++;
   }
   return count;
}

int CountMyPending()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) == (long)MagicNumber &&
         OrderGetString(ORDER_SYMBOL) == Symbol())
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| ORDER BLOCK DETECTION                                             |
//+------------------------------------------------------------------+
void DetectOrderBlocks()
{
   int bars = iBars(Symbol(), FVGTimeframe);
   int scan = MathMin(bars - 2, OB_LookbackBars + 5);
   if(scan < 5) return;

   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   if(point <= 0) point = 0.01;
   double atr = GetATR(hATR_exec);
   if(atr <= 0) return;

   for(int i = 2; i < scan; i++)
   {
      double o1 = iOpen(Symbol(), FVGTimeframe, i + 1);
      double c1 = iClose(Symbol(), FVGTimeframe, i + 1);

      double o2 = iOpen(Symbol(), FVGTimeframe, i);
      double c2 = iClose(Symbol(), FVGTimeframe, i);

      datetime t1 = iTime(Symbol(), FVGTimeframe, i + 1);

      double body2 = MathAbs(c2 - o2);
      if(body2 < atr * OB_ImpulseATR) continue;

      int obType = 0;
      double obTop = 0, obBot = 0;

      // Bullish OB: bearish candle before bullish impulse
      if(c2 > o2 && c1 < o1)
      {
         obType = 1;
         obTop = MathMax(o1, c1);
         obBot = MathMin(o1, c1);
      }
      // Bearish OB: bullish candle before bearish impulse
      else if(c2 < o2 && c1 > o1)
      {
         obType = -1;
         obTop = MathMax(o1, c1);
         obBot = MathMin(o1, c1);
      }

      if(obType == 0) continue;
      double obSize = (obTop - obBot) / point;
      if(obSize < OB_MinSize * GetPipScale()) continue;

      bool exists = false;
      for(int j = 0; j < ArraySize(obZones); j++)
      {
         if(obZones[j].time == t1) { exists = true; break; }
      }
      if(exists) continue;

      int sz = ArraySize(obZones);
      ArrayResize(obZones, sz + 1);
      obZones[sz].type      = obType;
      obZones[sz].top       = obTop;
      obZones[sz].bottom    = obBot;
      obZones[sz].time      = t1;
      obZones[sz].mitigated = false;
   }

   PruneOBs();
}

void PruneOBs()
{
   datetime oldest = TimeCurrent() - OB_LookbackBars * PeriodSeconds(FVGTimeframe);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);

   for(int i = ArraySize(obZones) - 1; i >= 0; i--)
   {
      bool remove = false;
      if(obZones[i].time < oldest) remove = true;

      if(!remove && !obZones[i].mitigated)
      {
         if(obZones[i].type == 1 && bid < obZones[i].bottom)
            obZones[i].mitigated = true;
         else if(obZones[i].type == -1 && ask > obZones[i].top)
            obZones[i].mitigated = true;
      }

      if(remove || obZones[i].mitigated)
      {
         string name = "OB_" + TimeToString(obZones[i].time, TIME_DATE|TIME_MINUTES);
         ObjectDelete(0, name);
         for(int j = i; j < ArraySize(obZones) - 1; j++)
            obZones[j] = obZones[j + 1];
         ArrayResize(obZones, ArraySize(obZones) - 1);
      }
   }
}

bool HasOBConfluence(FVGZone &fvg)
{
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double maxDist = OB_MaxDistance * point * GetPipScale();

   for(int i = 0; i < ArraySize(obZones); i++)
   {
      if(obZones[i].mitigated) continue;
      if(obZones[i].type != fvg.type) continue;

      if(fvg.top >= obZones[i].bottom && fvg.bottom <= obZones[i].top)
         return(true);

      double dist = 0;
      if(fvg.type == 1)
         dist = fvg.bottom - obZones[i].top;
      else
         dist = obZones[i].bottom - fvg.top;

      if(dist >= 0 && dist <= maxDist)
         return(true);
   }
   return(false);
}

void DrawOB(OrderBlock &ob)
{
   string name = "OB_" + TimeToString(ob.time, TIME_DATE|TIME_MINUTES);
   color clr = (ob.type == 1) ? clrDodgerBlue : clrOrangeRed;
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, ob.time, ob.top,
                ob.time + PeriodSeconds(FVGTimeframe) * 3, ob.bottom);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
}

//+------------------------------------------------------------------+
//| FVG QUALITY SCORING                                               |
//+------------------------------------------------------------------+
double CalcDisplacement(int barIndex)
{
   double o = iOpen(Symbol(), FVGTimeframe, barIndex);
   double c = iClose(Symbol(), FVGTimeframe, barIndex);
   double h = iHigh(Symbol(), FVGTimeframe, barIndex);
   double l = iLow(Symbol(), FVGTimeframe, barIndex);
   double range = h - l;
   if(range <= 0) return(0);
   double body = MathAbs(c - o);
   return body / range;
}

double CalcFVGScore(int fvgType, double gapTop, double gapBot, datetime fvgTime)
{
   double score = 0;
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double atr = GetATR(hATR_exec);
   if(atr <= 0 || point <= 0) return(0);

   // 1. Gap size score
   double gapSize = (gapTop - gapBot) / point;
   double gapRatio = gapSize / (atr / point);
   score += MathMin(gapRatio, 1.0) * ScoreGapWeight;

   // 2. Displacement strength of candle 2
   int barIdx = iBarShift(Symbol(), FVGTimeframe, fvgTime, false);
   if(barIdx >= 0)
   {
      double disp = CalcDisplacement(barIdx);
      score += disp * ScoreDispWeight;
   }

   // 3. HTF alignment
   int bias = GetHTFBias();
   if(fvgType == bias)
      score += ScoreHTFWeight;

   // 4. Freshness
   int ageBars = iBarShift(Symbol(), FVGTimeframe, fvgTime, false);
   double freshness = 1.0 - ((double)ageBars / (double)MaxAgeBars);
   score += freshness * ScoreFreshWeight;

   // 5. Premium/Discount
   double htfATR = GetATR(hATR_htf);
   if(htfATR > 0)
   {
      double htfBid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      double htfEMA = 0;
      double emaBuf[1];
      if(CopyBuffer(hEMAfast_htf, 0, 0, 1, emaBuf) >= 1)
         htfEMA = emaBuf[0];

      if(htfEMA > 0)
      {
         double dist = htfBid - htfEMA;
         if(fvgType == 1 && dist < 0) score += ScorePDWeight;
         else if(fvgType == -1 && dist > 0) score += ScorePDWeight;
      }
   }

   return NormalizeDouble(score, 1);
}

//+------------------------------------------------------------------+
//| Detect FVGs with quality scoring                                 |
//+------------------------------------------------------------------+
void DetectFVGs()
{
   int bars = iBars(Symbol(), FVGTimeframe);
   int scanBars = MathMin(bars - 3, MaxAgeBars + 10);
   if(scanBars < 5) return;

   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   if(point <= 0) point = 0.01;

   for(int i = 3; i < scanBars; i++)
   {
      double h1 = iHigh(Symbol(), FVGTimeframe, i);
      double l1 = iLow(Symbol(), FVGTimeframe, i);
      double h3 = iHigh(Symbol(), FVGTimeframe, i - 2);
      double l3 = iLow(Symbol(), FVGTimeframe, i - 2);

      datetime t1 = iTime(Symbol(), FVGTimeframe, i - 1);

      double gapTop = 0, gapBot = 0;
      int fvgType = 0;

      if(l3 > h1)      { gapTop = l3; gapBot = h1; fvgType = 1; }
      else if(h3 < l1) { gapTop = l1; gapBot = h3; fvgType = -1; }
      if(fvgType == 0) continue;

      double gapSize = (gapTop - gapBot) / point;
      if(gapSize < MinGapSize * GetPipScale()) continue;

      int fvgAgeBars = iBarShift(Symbol(), FVGTimeframe, t1, false);
      if(fvgAgeBars < MinAgeBars || fvgAgeBars > MaxAgeBars) continue;

      bool exists = false;
      for(int j = 0; j < ArraySize(fvgZones); j++)
      {
         if(fvgZones[j].time == t1) { exists = true; break; }
      }
      if(exists) continue;

      double score = CalcFVGScore(fvgType, gapTop, gapBot, t1);

      FVGZone temp;
      temp.type = fvgType;
      temp.top = gapTop;
      temp.bottom = gapBot;
      temp.midpoint = (gapTop + gapBot) / 2.0;

      if(UseOBFilter)
      {
         if(HasOBConfluence(temp))
            score += OB_ConfluenceBonus;
      }

      if(score < MinScoreFVG) continue;

      int sz = ArraySize(fvgZones);
      ArrayResize(fvgZones, sz + 1);
      fvgZones[sz].type        = fvgType;
      fvgZones[sz].top         = gapTop;
      fvgZones[sz].bottom      = gapBot;
      fvgZones[sz].midpoint    = (gapTop + gapBot) / 2.0;
      fvgZones[sz].time        = t1;
      fvgZones[sz].mitigated   = false;
      fvgZones[sz].orderPlaced = false;
      fvgZones[sz].score       = score;
   }

   PruneFVGs();
}

void PruneFVGs()
{
   datetime oldestAllowed = TimeCurrent() - MaxAgeBars * PeriodSeconds(FVGTimeframe);
   for(int i = ArraySize(fvgZones) - 1; i >= 0; i--)
   {
      bool remove = false;
      if(fvgZones[i].time < oldestAllowed) remove = true;

      if(!remove && !fvgZones[i].mitigated)
      {
         double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
         double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
         if(fvgZones[i].type == 1 && bid < fvgZones[i].midpoint)
            fvgZones[i].mitigated = true;
         else if(fvgZones[i].type == -1 && ask > fvgZones[i].midpoint)
            fvgZones[i].mitigated = true;
      }

      if(remove || fvgZones[i].mitigated)
      {
         string name = "FVG_" + TimeToString(fvgZones[i].time, TIME_DATE|TIME_MINUTES);
         ObjectDelete(0, name);
         ObjectDelete(0, name + "_mid");
         ObjectDelete(0, name + "_score");
         for(int j = i; j < ArraySize(fvgZones) - 1; j++)
            fvgZones[j] = fvgZones[j + 1];
         ArrayResize(fvgZones, ArraySize(fvgZones) - 1);
      }
   }
}

void DrawFVG(FVGZone &fvg)
{
   string name = "FVG_" + TimeToString(fvg.time, TIME_DATE|TIME_MINUTES);
   string midName = name + "_mid";
   string scoreName = name + "_score";

   color clr = (fvg.type == 1) ? clrLime : clrRed;
   if(fvg.score >= 70)
      clr = (fvg.type == 1) ? clrYellow : clrMagenta;

   ObjectCreate(0, name, OBJ_RECTANGLE, 0, fvg.time, fvg.top,
                fvg.time + PeriodSeconds(FVGTimeframe) * 2, fvg.bottom);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);

   ObjectCreate(0, midName, OBJ_TREND, 0, fvg.time, fvg.midpoint,
                fvg.time + PeriodSeconds(FVGTimeframe) * 2, fvg.midpoint);
   ObjectSetInteger(0, midName, OBJPROP_COLOR, clrYellow);
   ObjectSetInteger(0, midName, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, midName, OBJPROP_BACK, true);
   ObjectSetInteger(0, midName, OBJPROP_RAY_RIGHT, false);

   ObjectCreate(0, scoreName, OBJ_TEXT, 0, fvg.time, fvg.top);
   ObjectSetString(0, scoreName, OBJPROP_TEXT, DoubleToString(fvg.score, 0));
   ObjectSetInteger(0, scoreName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, scoreName, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, scoreName, OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
//| Normalize lot to exact broker volume step                        |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

   if(lotStep <= 0) lotStep = 0.01;
   if(minLot <= 0) minLot = 0.01;
   if(maxLot <= 0) maxLot = 100.0;

   // Determine decimal digits of lot step (e.g. 0.01 -> 2 decimals)
   int lotDigits = 2;
   if(lotStep >= 1.0) lotDigits = 0;
   else if(lotStep >= 0.1) lotDigits = 1;
   else if(lotStep >= 0.01) lotDigits = 2;
   else lotDigits = 3;

   double validMin = MathMax(minLot, lotStep);
   
   // Floor to nearest step with precision epsilon to avoid floating point truncation
   lot = MathFloor((lot / lotStep) + 0.00001) * lotStep;
   lot = NormalizeDouble(lot, lotDigits);

   // Clamping
   if(lot < validMin) lot = validMin;
   if(lot > maxLot) lot = maxLot;

   return NormalizeDouble(lot, lotDigits);
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk and broker limits               |
//+------------------------------------------------------------------+
double CalcLot(double slDistance)
{
   double minLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

   if(lotStep <= 0) lotStep = 0.01;
   if(minLot <= 0) minLot = 0.01;

   double lot = 0;

   if(FixedLot > 0)
   {
      lot = FixedLot;
   }
   else if(slDistance > 0)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double effectiveRiskPercent = (ConservativeRiskPercent > 0 ? MathMin(RiskPercent, ConservativeRiskPercent) : RiskPercent);
      double riskMoney = equity * effectiveRiskPercent / 100.0;

      double tickVal  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
      if(tickVal <= 0 || tickSize <= 0 || slDistance <= 0 || riskMoney <= 0) return(0);

      lot = riskMoney / (slDistance / tickSize * tickVal);
      double validMin = MathMax(minLot, lotStep);
      
      // Conservative risk gate: never force broker minimum if it breaches risk budget
      if(lot < validMin - 0.0000001) return(0);
      
      double maxLotByBalance = MathMin(0.10, equity * 0.01);
      lot = MathMin(lot, maxLotByBalance);
   }

   return NormalizeLot(lot);
}

bool IsValidLot(double lot)
{
   double minLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

   if(lotStep <= 0) lotStep = 0.01;
   if(minLot <= 0) minLot = 0.01;
   double validMin = MathMax(minLot, lotStep);

   if(lot < validMin - 0.0000001) return false;
   if(lot > maxLot + 0.0000001) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Check for existing order at this FVG                             |
//+------------------------------------------------------------------+
bool HasOrderNearFVG(datetime fvgTime)
{
   string tag = "FVG_" + TimeToString(fvgTime, TIME_DATE|TIME_MINUTES);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)MagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != Symbol()) continue;
      if(StringFind(OrderGetString(ORDER_COMMENT), tag) >= 0) return(true);
   }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), tag) >= 0) return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| JSON Helpers & Secure AI Service Transport                       |
//+------------------------------------------------------------------+
string JsonEscape(string value)
{
   StringReplace(value, "\\", "\\\\");
   StringReplace(value, "\"", "\\\"");
   StringReplace(value, "\r", "\\r");
   StringReplace(value, "\n", "\\n");
   StringReplace(value, "\t", "\\t");
   return value;
}

string JSONValue(string body, string key)
{
   string needle = "\"" + key + "\"";
   int p = StringFind(body, needle);
   if(p < 0) return "";
   p = StringFind(body, ":", p + StringLen(needle));
   if(p < 0) return "";
   p++;
   while(p < StringLen(body) && (StringGetCharacter(body, p) == ' ' || StringGetCharacter(body, p) == '\t')) p++;
   if(p >= StringLen(body)) return "";
   if(StringGetCharacter(body, p) == '\"')
   {
      p++;
      int e = p;
      while(e < StringLen(body) && StringGetCharacter(body, e) != '\"')
      {
         if(StringGetCharacter(body, e) == '\\') e++;
         e++;
      }
      if(e >= StringLen(body)) return "";
      return StringSubstr(body, p, e - p);
   }
   int e = p;
   while(e < StringLen(body) && StringGetCharacter(body, e) != ',' && StringGetCharacter(body, e) != '}' && 
         StringGetCharacter(body, e) != ' ' && StringGetCharacter(body, e) != '\r' && StringGetCharacter(body, e) != '\n') e++;
   return StringSubstr(body, p, e - p);
}

//+------------------------------------------------------------------+
//| Repaired AI HTTP Request Function                                |
//| Fixes: Connection: close, User-Agent, Accept, and 1003 decoding  |
//+------------------------------------------------------------------+
bool AIHttpRequest(string method, string path, string payload, string &response)
{
   if(AIServiceToken == "" || AIServiceToken == "CHANGE_ME_TO_MATCH_ENV" || StringFind(AIServiceToken, "REPLACE_") >= 0)
   {
      lastAIStatusText = "AI token not configured (set AIServiceToken in EA Inputs)";
      return false;
   }
   string url = AIServiceBaseURL + path;
   
   // Fix: Added Connection: close, User-Agent, and Accept headers to prevent MT5 read timeouts (HTTP 1003)
   string headers = "Content-Type: application/json\r\n" +
                    "Connection: close\r\n" +
                    "User-Agent: FvgGold-EA/2.20\r\n" +
                    "Accept: application/json\r\n" +
                    "X-Service-Token: " + AIServiceToken + "\r\n";
                    
   char data[]; char result[]; string resultHeaders;
   if(method == "GET") ArrayResize(data, 0);
   else StringToCharArray(payload, data, 0, StringLen(payload), CP_UTF8);
   
   ResetLastError();
   int code = WebRequest(method, url, headers, AIRequestTimeoutMs, data, result, resultHeaders);
   
   if(code == -1)
   {
      int err = GetLastError();
      if(err == 4014)
         lastAIStatusText = "URL not allowed (Add '" + AIServiceBaseURL + "' in Tools->Options->Expert Advisors)";
      else
         lastAIStatusText = "WebRequest failed: error=" + IntegerToString(err);
      return false;
   }
   
   response = CharArrayToString(result, 0, -1, CP_UTF8);
   
   // Clarify MT5 WebRequest internal timeout/connection code (1003) vs actual HTTP status codes
   if(code == 1003)
   {
      lastAIStatusText = "MT5 WebRequest timeout/connection error (1003)";
      return false;
   }
   else if(code >= 1000)
   {
      lastAIStatusText = "MT5 WebRequest internal error " + IntegerToString(code);
      return false;
   }
   else if(code < 200 || code >= 300)
   {
      if(code == 401)
         lastAIStatusText = "HTTP 401 Unauthorized (AIServiceToken does not match service .env)";
      else if(code == 503)
         lastAIStatusText = "HTTP 503 AI Service Unavailable";
      else
         lastAIStatusText = "AI service HTTP " + IntegerToString(code);
      return false;
   }
   
   return true;
}

void CancelMyPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)MagicNumber || OrderGetString(ORDER_SYMBOL) != Symbol()) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT || 
         type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP || 
         type == ORDER_TYPE_BUY_STOP_LIMIT || type == ORDER_TYPE_SELL_STOP_LIMIT)
      {
         if(!trade.OrderDelete(tk)) 
            Print("AI fail-closed: pending order delete failed #", tk, " retcode=", trade.ResultRetcode());
      }
   }
}

string BuildCandleJson(ENUM_TIMEFRAMES timeframe, int count)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(Symbol(), timeframe, 1, count, rates); // closed candles only
   if(copied <= 0) return "[]";
   string out = "[";
   for(int i = 0; i < copied; i++)
   {
      if(i > 0) out += ",";
      out += "{\"time\":" + IntegerToString((int)rates[i].time) +
             ",\"open\":" + DoubleToString(rates[i].open, _Digits) +
             ",\"high\":" + DoubleToString(rates[i].high, _Digits) +
             ",\"low\":" + DoubleToString(rates[i].low, _Digits) +
             ",\"close\":" + DoubleToString(rates[i].close, _Digits) +
             ",\"tick_volume\":" + IntegerToString((int)rates[i].tick_volume) + "}";
   }
   return out + "]";
}

//+------------------------------------------------------------------+
//| Unified Heartbeat & State Synchronization                        |
//| Sends telemetry and retrieves service state in a single call     |
//+------------------------------------------------------------------+
void RefreshAIServiceState()
{
   lastAIStatusCheck = TimeCurrent();
   
   string payload = "{\"symbol\":\"" + JsonEscape(Symbol()) + "\"," +
      "\"balance\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "," +
      "\"equity\":" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "," +
      "\"daily_pl\":" + DoubleToString(dailyPL, 2) + "," +
      "\"floating_pl\":" + DoubleToString(floatingPL, 2) + "," +
      "\"positions\":" + IntegerToString(CountMyPositions()) + "," +
      "\"pending\":" + IntegerToString(CountMyPending()) + "," +
      "\"server_time\":" + IntegerToString((int)TimeCurrent()) + "}";
      
   string response;
   if(!AIHttpRequest("POST", "/heartbeat", payload, response))
   {
      AIServiceActive = false;
      if(CancelPendingIfAIUnavailable) CancelMyPendingOrders();
      return;
   }

   string active = JSONValue(response, "active");
   AIServiceActive = (active == "true");
   string status = JSONValue(response, "status");
   lastAIStatusText = (status == "" ? (AIServiceActive ? "active" : "paused") : status);

   if(!AIServiceActive && CancelPendingIfAIUnavailable)
      CancelMyPendingOrders();
}

void OnTimer()
{
   RefreshAIServiceState();
}

//+------------------------------------------------------------------+
//| AI Candidate Evaluation with Replay Protection & Deduplication    |
//+------------------------------------------------------------------+
bool AIApproveFVG(FVGZone &fvg, string direction, double entry, double sl, double tp, double lot, double atr, double spread, int bias)
{
   if(!UseAIApproval) return true;
   if(!AIServiceActive)
   {
      Print("AI FAIL-CLOSED: Service not active; rejecting order. State=", lastAIStatusText);
      return false;
   }
   
   double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   if(tickValue <= 0 || tickSize <= 0 || equity <= 0)
   {
      Print("AI risk gate: Cannot calculate exact tick risk values");
      return false;
   }
   
   double riskMoney = (MathAbs(entry - sl) / tickSize) * tickValue * lot;
   double actualRiskPercent = (riskMoney / equity) * 100.0;
   if(actualRiskPercent > ConservativeRiskPercent + 0.0001)
   {
      Print("AI risk gate: Actual risk ", DoubleToString(actualRiskPercent, 3), "% exceeds cap ", DoubleToString(ConservativeRiskPercent, 3), "%");
      return false;
   }
   
   // Generate deterministic signal ID for duplicate prevention
   string signalTag = Symbol() + "_" + direction + "_" + IntegerToString((int)fvg.time) + "_" + DoubleToString(entry, 2);
   
   string payload = "{\"symbol\":\"" + JsonEscape(Symbol()) + "\"," +
      "\"direction\":\"" + direction + "\"," +
      "\"timeframe\":\"" + EnumToString(FVGTimeframe) + "\"," +
      "\"higher_timeframe\":\"" + EnumToString(HTF_Period) + "\"," +
      "\"bias\":" + IntegerToString(bias) + "," +
      "\"fvg_score\":" + DoubleToString(fvg.score, 1) + "," +
      "\"fvg_type\":" + IntegerToString(fvg.type) + "," +
      "\"fvg_top\":" + DoubleToString(fvg.top, _Digits) + "," +
      "\"fvg_bottom\":" + DoubleToString(fvg.bottom, _Digits) + "," +
      "\"fvg_time\":" + IntegerToString((int)fvg.time) + "," +
      "\"entry\":" + DoubleToString(entry, _Digits) + "," +
      "\"stop_loss\":" + DoubleToString(sl, _Digits) + "," +
      "\"take_profit\":" + DoubleToString(tp, _Digits) + "," +
      "\"lot\":" + DoubleToString(lot, 2) + "," +
      "\"atr\":" + DoubleToString(atr, _Digits) + "," +
      "\"spread_points\":" + DoubleToString(spread / _Point, 1) + "," +
      "\"max_spread_points\":" + DoubleToString(MaxSpreadPoints, 1) + "," +
      "\"equity\":" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "," +
      "\"balance\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "," +
      "\"daily_pl\":" + DoubleToString(dailyPL + MathMin(0.0, floatingPL), 2) + "," +
      "\"daily_loss_limit\":" + DoubleToString(DailyLossLimit, 2) + "," +
      "\"risk_percent\":" + DoubleToString(actualRiskPercent, 4) + "," +
      "\"client_timestamp\":" + IntegerToString((int)TimeCurrent()) + "," +
      "\"signal_id\":\"" + JsonEscape(signalTag) + "\"," +
      "\"candles_exec\":" + BuildCandleJson(FVGTimeframe, 12) + "," +
      "\"candles_htf\":" + BuildCandleJson(HTF_Period, 12) + "}";
      
   string response;
   if(!AIHttpRequest("POST", "/decision", payload, response))
   {
      Print("AI FAIL-CLOSED: Decision request failed. ", lastAIStatusText);
      return false;
   }
   
   string decision = JSONValue(response, "decision");
   string approved = JSONValue(response, "approved");
   string confidenceText = JSONValue(response, "confidence");
   double confidence = StringToDouble(confidenceText);
   string reason = JSONValue(response, "reason");
   string marketBias = JSONValue(response, "market_bias");
   string setupQuality = JSONValue(response, "setup_quality");
   string invalidation = JSONValue(response, "invalidation_reason");
   
   Print("Gemini Review: Decision=", decision, " Approved=", approved, " Conf=", DoubleToString(confidence, 2), 
         " Bias=", marketBias, " Quality=", setupQuality, " Reason=", reason);
   if(invalidation != "")
      Print("Gemini Invalidation Note: ", invalidation);

   if(approved != "true" || decision != direction || confidence < AIApprovalConfidence)
   {
      Print("AI FAIL-CLOSED: Candidate rejected by AI or failed confidence threshold (", DoubleToString(confidence, 2), " < ", DoubleToString(AIApprovalConfidence, 2), ")");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Place order at FVG boundary or immediate Market Execution        |
//+------------------------------------------------------------------+
void PlaceFVGOrder(FVGZone &fvg)
{
   int openCount = CountMyPositions() + CountMyPending();
   if(openCount >= MaxTrades) return;
   if(HasOrderNearFVG(fvg.time)) return;

   double point   = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double ask     = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid     = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double spread  = ask - bid;
   double maxAllowedSpreadPoints = MaxSpreadPoints * GetPipScale();
   if(MaxSpreadPoints > 0 && spread / point > maxAllowedSpreadPoints)
   {
      Print("AI risk gate: Spread too high (", DoubleToString(spread / point, 1), " points > ", DoubleToString(maxAllowedSpreadPoints, 1), " max)");
      return;
   }
   long   stopLvl = SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopLvl * point + spread;

   double atr = GetATR(hATR_exec);
   if(atr <= 0) return;

   double slDist = 0;
   double tpDist = atr * ATR_TP_Mult;

   string tag = "FVG_" + TimeToString(fvg.time, TIME_DATE|TIME_MINUTES)
                + " S" + IntegerToString((int)fvg.score);

   if(fvg.type == 1)
   {
      double entry = (ExecutionMode == EXEC_MARKET) ? ask : (fvg.bottom + FVGBuffer * 0.5);
      double sl    = fvg.bottom - FVGBuffer;
      slDist = entry - sl;
      if(ExecutionMode == EXEC_LIMIT && (ask - entry < minDist)) return;
      if(sl >= entry) return;

      double lot = CalcLot(slDist);
      if(lot <= 0) return;
      if(!IsValidLot(lot)) { Print("Invalid lot size: ", DoubleToString(lot, 2)); return; }
      double tp = UseFixedRR ? entry + slDist * RiskRewardRatio : entry + tpDist;
      
      if(!AIApproveFVG(fvg, "BUY", entry, sl, tp, lot, atr, spread, GetHTFBias())) return;

      if(ExecutionMode == EXEC_MARKET)
      {
         if(trade.Buy(lot, _Symbol, 0.0, sl, tp, tag))
         {
            fvg.orderPlaced = true;
            Print("FVG Market BUY Placed: ", tag, " lot=", DoubleToString(lot, 2),
                  " @ ", DoubleToString(ask, _Digits),
                  " SL=", DoubleToString(sl, _Digits), " TP=", DoubleToString(tp, _Digits),
                  " Score=", DoubleToString(fvg.score, 0),
                  " R:R=", DoubleToString((tp - entry) / (entry - sl), 1));
         }
         else
            Print("Market Buy failed: ", tag, " retcode=", IntegerToString(trade.ResultRetcode()));
      }
      else
      {
         if(trade.BuyLimit(lot, entry, Symbol(), sl, tp, ORDER_TIME_GTC, 0, tag))
         {
            fvg.orderPlaced = true;
            Print("FVG BuyLimit Placed: ", tag, " @ ", DoubleToString(entry, 2),
                  " SL=", DoubleToString(sl, 2), " TP=", DoubleToString(tp, 2),
                  " Score=", DoubleToString(fvg.score, 0),
                  " R:R=", DoubleToString((tp - entry) / (entry - sl), 1));
         }
         else
            Print("BuyLimit failed: ", tag, " retcode=", IntegerToString(trade.ResultRetcode()));
      }
   }
   else
   {
      double entry = (ExecutionMode == EXEC_MARKET) ? bid : (fvg.top - FVGBuffer * 0.5);
      double sl    = fvg.top + FVGBuffer;
      slDist = sl - entry;
      if(ExecutionMode == EXEC_LIMIT && (entry - bid < minDist)) return;
      if(sl <= entry) return;

      double lot = CalcLot(slDist);
      if(lot <= 0) return;
      if(!IsValidLot(lot)) { Print("Invalid lot size: ", DoubleToString(lot, 2)); return; }
      double tp = UseFixedRR ? entry - slDist * RiskRewardRatio : entry - tpDist;
      
      if(!AIApproveFVG(fvg, "SELL", entry, sl, tp, lot, atr, spread, GetHTFBias())) return;

      if(ExecutionMode == EXEC_MARKET)
      {
         if(trade.Sell(lot, _Symbol, 0.0, sl, tp, tag))
         {
            fvg.orderPlaced = true;
            Print("FVG Market SELL Placed: ", tag, " lot=", DoubleToString(lot, 2),
                  " @ ", DoubleToString(bid, _Digits),
                  " SL=", DoubleToString(sl, _Digits), " TP=", DoubleToString(tp, _Digits),
                  " Score=", DoubleToString(fvg.score, 0),
                  " R:R=", DoubleToString((entry - tp) / (sl - entry), 1));
         }
         else
            Print("Market Sell failed: ", tag, " retcode=", IntegerToString(trade.ResultRetcode()));
      }
      else
      {
         if(trade.SellLimit(lot, entry, Symbol(), sl, tp, ORDER_TIME_GTC, 0, tag))
         {
            fvg.orderPlaced = true;
            Print("FVG SellLimit Placed: ", tag, " @ ", DoubleToString(entry, 2),
                  " SL=", DoubleToString(sl, 2), " TP=", DoubleToString(tp, 2),
                  " Score=", DoubleToString(fvg.score, 0),
                  " R:R=", DoubleToString((entry - tp) / (sl - entry), 1));
         }
         else
            Print("SellLimit failed: ", tag, " retcode=", IntegerToString(trade.ResultRetcode()));
      }
   }
}

//+------------------------------------------------------------------+
//| Position Management (Break-even trigger)                         |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      long   type      = PositionGetInteger(POSITION_TYPE);

      double atr = GetATR(hATR_exec);
      if(atr <= 0) continue;
      double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
      double beTrigger = atr * 0.5;

      if(type == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
         if(bid - openPrice >= beTrigger && sl < openPrice)
            trade.PositionModify(tk, openPrice + 2 * point, tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
         if(openPrice - ask >= beTrigger && sl > openPrice)
            trade.PositionModify(tk, openPrice - 2 * point, tp);
      }
   }
}

void CloseEOD()
{
   if(!CloseAtEOD) return;
   MqlDateTime dt;
   TimeGMT(dt);
   if(dt.hour == KZ_NYEnd && dt.min == 55)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong tk = PositionGetTicket(i);
         if(tk == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == Symbol())
            trade.PositionClose(tk);
      }
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong tk = OrderGetTicket(i);
         if(tk == 0) continue;
         if(OrderGetInteger(ORDER_MAGIC) == (long)MagicNumber &&
            OrderGetString(ORDER_SYMBOL) == Symbol())
            trade.OrderDelete(tk);
      }
   }
}

//+------------------------------------------------------------------+
//| Chart Dashboard                                                  |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   int bias = GetHTFBias();
   string biasStr = (bias == 1) ? "BULLISH" : (bias == -1) ? "BEARISH" : "NEUTRAL";
   int openPos = CountMyPositions();
   int pendCount = CountMyPending();
   double atr = GetATR(hATR_exec);

   MqlDateTime dt;
   TimeGMT(dt);
   string sessionStr = "CLOSED";
   if(!UseKillzone) sessionStr = "ALL_HOURS";
   else if(KZ_PreferOverlap)
      sessionStr = (dt.hour >= KZ_OverlapStart && dt.hour < KZ_OverlapEnd) ? "OVERLAP_OPEN" : "WAIT";
   else
   {
      bool london = (dt.hour >= KZ_LondonStart && dt.hour < KZ_LondonEnd);
      bool overlap = (dt.hour >= KZ_OverlapStart && dt.hour < KZ_OverlapEnd);
      bool ny = (dt.hour >= KZ_OverlapStart && dt.hour < KZ_NYEnd);
      if(london || overlap || ny) sessionStr = "ACTIVE";
   }

   string s = "=== FvgGold AI Trader v2.20 ===\n";
   s += "HTF Bias: " + biasStr + " | Exec TF: " + EnumToString(FVGTimeframe) + "\n";
   s += "ATR: " + DoubleToString(atr, 2) + " | Session: " + sessionStr + "\n";
   s += "Active FVGs: " + IntegerToString(ArraySize(fvgZones)) + " | OBs: " + IntegerToString(ArraySize(obZones)) + "\n";
   s += "Open Trades: " + IntegerToString(openPos) + " | Pending: " + IntegerToString(pendCount) + "\n";
   s += "Daily P/L: $" + DoubleToString(dailyPL, 2) + " (Floating: $" + DoubleToString(floatingPL, 2) + ")\n";
   s += "AI Gate: " + (AIServiceActive ? "ACTIVE (CONNECTED)" : "FAIL-CLOSED (PROTECTED)") + "\n";
   s += "Status: " + lastAIStatusText + "\n";
   Comment(s);
}

double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   if(trades <= 0) return(-1.0);
   double wins  = TesterStatistics(STAT_PROFIT_TRADES);
   double wr    = wins / trades;
   double net   = TesterStatistics(STAT_PROFIT);
   if(net <= 0) return(-1.0 - wr);
   return(wr);
}

//+------------------------------------------------------------------+
//| Expert Tick Function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdateDailyPL();
   TrackDailyPL();

   // Manage open positions and session close
   ManagePositions();
   CloseEOD();

   if(IsDailyLimitHit())
   {
      if(CancelPendingIfAIUnavailable) CancelMyPendingOrders();
      UpdateDashboard();
      return;
   }
   
   if(UseAIApproval && !AIServiceActive)
   {
      UpdateDashboard();
      return;
   }

   // Detect structure
   DetectOrderBlocks();
   DetectFVGs();

   int bias = GetHTFBias();
   if(bias == 0) { UpdateDashboard(); return; }

   if(!IsKillzoneActive()) { UpdateDashboard(); return; }

   // Place orders at valid quality FVGs
   for(int i = 0; i < ArraySize(fvgZones); i++)
   {
      if(fvgZones[i].mitigated) continue;
      if(fvgZones[i].orderPlaced) continue;
      if(fvgZones[i].type != bias) continue;
      if(fvgZones[i].score < MinScoreFVG) continue;

      DrawFVG(fvgZones[i]);
      PlaceFVGOrder(fvgZones[i]);
   }

   UpdateDashboard();
}
//+------------------------------------------------------------------+
