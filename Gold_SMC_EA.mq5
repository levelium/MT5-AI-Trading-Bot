//+------------------------------------------------------------------+
//|                                                Gold_SMC_EA.mq5   |
//| Strategy: Liquidity Sweep + BOS/CHoCH + FVG                      |
//| Timeframes: M5 entry, M15 trend                                  |
//| Risk: 0.25% equity per trade                                     |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================
// INPUT PARAMETERS
//====================================================================

input group "General Settings"
input string          InpSymbol               = "XAUUSD";
input ENUM_TIMEFRAMES InpEntryTF               = PERIOD_M5;
input ENUM_TIMEFRAMES InpTrendTF               = PERIOD_M15;
input ulong           InpMagic                 = 2601023;
input string          InpTradeComment          = "Gold_SMC_EA";
input bool            InpAllowBuy              = true;
input bool            InpAllowSell             = true;
input bool            InpRequireExactSymbol    = true;

input group "Risk Management"
input double          InpRiskPercent           = 0.25;
input double          InpMinimumRR             = 2.0;
input double          InpMaxDailyDrawdownPct   = 1.0;
input double          InpMaxDailyLossPct       = 1.0;
input bool            InpUseDailyProtection    = true;

input group "SMC Settings"
input int             InpATRPeriod             = 14;
input int             InpEMAPeriod              = 200;
input int             InpLookbackBars           = 200;
input int             InpSwingLeftRight         = 3;
input double          InpEqualLevelATR          = 0.10;
input double          InpDisplacementATR        = 0.80;
input double          InpStopBufferATR          = 0.20;
input int             InpMaximumSetupAgeBars    = 12;

input group "Position Management"
input bool            InpUseBreakEven           = true;
input double          InpBreakEvenAtR           = 1.0;
input double          InpBreakEvenBufferPoints  = 5.0;
input bool            InpUseATRTrailing         = true;
input double          InpTrailingStartR         = 2.0;
input double          InpTrailingATRMultiplier  = 1.5;

input group "Execution Filters"
input int             InpMaxSpreadPoints        = 30;
input double          InpMaxSpreadATRFraction   = 0.15;
input double          InpMaxATRExpansion        = 2.0;
input double          InpMaxCandleRangeATR      = 2.5;
input int             InpDeviationPoints        = 30;
input int             InpMaxOrderAttempts       = 3;

input group "Economic Calendar"
input bool            InpUseNewsFilter          = true;
input int             InpNewsMinutesBefore      = 30;
input int             InpNewsMinutesAfter       = 30;

input group "Session Filter"
input bool            InpUseSessionFilter       = true;

// UTC session windows. These fixed windows do NOT automatically
// adjust for UK/US daylight-saving time.
input int             InpLondonStartUTC         = 8;
input int             InpLondonEndUTC           = 17;
input int             InpNewYorkStartUTC        = 13;
input int             InpNewYorkEndUTC          = 22;

//====================================================================
// GLOBAL VARIABLES
//====================================================================

int g_atrHandle = INVALID_HANDLE;
int g_emaHandle = INVALID_HANDLE;

datetime g_lastBarTime = 0;
datetime g_dayStart = 0;

double g_dayStartEquity = 0.0;
double g_dayStartBalance = 0.0;

bool g_dailyLocked = false;

// Initial setup-state implementation.
// 0 = waiting for sweep
// 1 = waiting for structure break
// 2 = waiting for FVG
// 3 = waiting for retracement and entry confirmation
int g_buyStage = 0;
int g_sellStage = 0;

int g_buyAge = 0;
int g_sellAge = 0;

double g_buySweepExtreme = 0.0;
double g_sellSweepExtreme = 0.0;

double g_buyLiquidityLevel = 0.0;
double g_sellLiquidityLevel = 0.0;

double g_buyFvgLower = 0.0;
double g_buyFvgUpper = 0.0;
double g_sellFvgLower = 0.0;
double g_sellFvgUpper = 0.0;

datetime g_buySetupTime = 0;
datetime g_sellSetupTime = 0;

//====================================================================
// INITIALIZATION
//====================================================================

int OnInit()
{
   if(InpRiskPercent <= 0.0 ||
      InpMinimumRR < 2.0 ||
      InpATRPeriod < 1 ||
      InpEMAPeriod < 1 ||
      InpSwingLeftRight < 1)
   {
      Print("Initialization failed: invalid strategy parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpSymbol == "")
   {
      Print("Initialization failed: symbol cannot be empty.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!SymbolSelect(InpSymbol, true))
   {
      Print("Initialization failed: cannot select ", InpSymbol);
      return INIT_FAILED;
   }

   g_atrHandle = iATR(InpSymbol, InpEntryTF, InpATRPeriod);
   g_emaHandle = iMA(InpSymbol, InpTrendTF,
                     InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(g_atrHandle == INVALID_HANDLE ||
      g_emaHandle == INVALID_HANDLE)
   {
      Print("Initialization failed: indicator handle error.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(InpSymbol);

   ResetDailyReference();

   Print("Gold_SMC_EA initialized. Symbol=", InpSymbol,
         ", entry TF=", EnumToString(InpEntryTF),
         ", trend TF=", EnumToString(InpTrendTF));

   return INIT_SUCCEEDED;
}

//====================================================================
// DEINITIALIZATION
//====================================================================

void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);

   if(g_emaHandle != INVALID_HANDLE)
      IndicatorRelease(g_emaHandle);

   Print("Gold_SMC_EA deinitialized. Reason=", reason);
}

//====================================================================
// MAIN EVENT
//====================================================================

void OnTick()
{
   if(_Symbol != InpSymbol && InpRequireExactSymbol)
      return;

   // Existing positions must continue to be managed even if a
   // filter blocks new entries.
   ManageOpenPositions();

   UpdateDailyProtection();

   if(g_dailyLocked)
      return;

   if(!IsNewEntryBar())
      return;

   if(!BasicDataReady())
   {
      Print("Entry blocked: indicator/history data unavailable.");
      return;
   }

   if(HasOurOpenPosition())
      return;

   if(!TradingSessionAllowed())
      return;

   if(!SpreadAllowed())
      return;

   if(!VolatilityAllowed())
      return;

   if(InpUseNewsFilter && IsHighImpactUSDNews())
      return;

   UpdateSetups();

   if(HasOurOpenPosition())
      return;

   if(InpAllowBuy && g_buyStage == 3)
   {
      if(TrendIsBullish() && BuyConfirmation())
      {
         if(ExecuteBuy())
            ResetBuySetup();
      }
   }

   if(HasOurOpenPosition())
      return;

   if(InpAllowSell && g_sellStage == 3)
   {
      if(TrendIsBearish() && SellConfirmation())
      {
         if(ExecuteSell())
            ResetSellSetup();
      }
   }
}

//====================================================================
// NEW BAR DETECTION
//====================================================================

bool IsNewEntryBar()
{
   datetime barTime = iTime(InpSymbol, InpEntryTF, 0);

   if(barTime <= 0)
      return false;

   if(barTime == g_lastBarTime)
      return false;

   g_lastBarTime = barTime;
   return true;
}

//====================================================================
// DATA VALIDATION
//====================================================================

bool BasicDataReady()
{
   if(BarsCalculated(g_atrHandle) < InpATRPeriod + 10)
      return false;

   if(BarsCalculated(g_emaHandle) < InpEMAPeriod + 10)
      return false;

   if(Bars(InpSymbol, InpEntryTF) < InpLookbackBars)
      return false;

   if(Bars(InpSymbol, InpTrendTF) < InpEMAPeriod + 10)
      return false;

   return true;
}

double GetATR(const int shift = 1)
{
   double values[];
   ArraySetAsSeries(values, true);

   if(CopyBuffer(g_atrHandle, 0, shift, 1, values) != 1)
      return 0.0;

   return values[0];
}

double GetEMA(const int shift = 1)
{
   double values[];
   ArraySetAsSeries(values, true);

   if(CopyBuffer(g_emaHandle, 0, shift, 1, values) != 1)
      return 0.0;

   return values[0];
}

//====================================================================
// SPREAD FILTER
// Both conditions must pass.
//====================================================================

bool SpreadAllowed()
{
   MqlTick tick;

   if(!SymbolInfoTick(InpSymbol, tick))
      return false;

   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   double atr = GetATR(1);

   if(point <= 0.0 || atr <= 0.0)
      return false;

   double spreadPoints = (tick.ask - tick.bid) / point;

   if(spreadPoints > InpMaxSpreadPoints)
   {
      Print("Spread filter blocked entry: ",
            DoubleToString(spreadPoints, 1), " points.");
      return false;
   }

   if((tick.ask - tick.bid) > atr * InpMaxSpreadATRFraction)
   {
      Print("Spread exceeds ATR-relative threshold.");
      return false;
   }

   return true;
}

//====================================================================
// VOLATILITY FILTER
//====================================================================

bool VolatilityAllowed()
{
   double atrNow = GetATR(1);

   if(atrNow <= 0.0)
      return false;

   double atrValues[];
   ArraySetAsSeries(atrValues, true);

   if(CopyBuffer(g_atrHandle, 0, 1, 50, atrValues) != 50)
      return false;

   double sum = 0.0;

   for(int i = 0; i < 50; i++)
      sum += atrValues[i];

   double averageATR = sum / 50.0;

   if(averageATR <= 0.0)
      return false;

   if(atrNow > InpMaxATRExpansion * averageATR)
      return false;

   double candleHigh = iHigh(InpSymbol, InpEntryTF, 1);
   double candleLow  = iLow(InpSymbol, InpEntryTF, 1);

   if(candleHigh <= candleLow)
      return false;

   if((candleHigh - candleLow) > InpMaxCandleRangeATR * atrNow)
      return false;

   return true;
}

//====================================================================
// SESSION FILTER
// Uses fixed UTC windows. DST conversion must be added before
// treating this as a complete London/New York session implementation.
//====================================================================

bool TradingSessionAllowed()
{
   if(!InpUseSessionFilter)
      return true;

   datetime utc = TimeGMT();

   MqlDateTime dt;
   TimeToStruct(utc, dt);

   int hour = dt.hour;

   bool london =
      (hour >= InpLondonStartUTC && hour < InpLondonEndUTC);

   bool newYork =
      (hour >= InpNewYorkStartUTC && hour < InpNewYorkEndUTC);

   return london || newYork;
}

//====================================================================
// USD HIGH-IMPACT ECONOMIC CALENDAR FILTER
// If calendar access fails, fail closed.
//====================================================================

bool IsHighImpactUSDNews()
{
   if(!InpUseNewsFilter)
      return false;

   datetime now = TimeTradeServer();

   if(now <= 0)
   {
      Print("Calendar filter: server time unavailable.");
      return true;
   }

   datetime fromTime = now - InpNewsMinutesBefore * 60;
   datetime toTime   = now + InpNewsMinutesAfter * 60;

   MqlCalendarValue values[];

   ResetLastError();

   int count = CalendarValueHistory(values,
                                    fromTime,
                                    toTime,
                                    NULL,
                                    "USD");

   if(count < 0)
   {
      Print("Calendar access failed. Error=", GetLastError(),
            ". Blocking new entries.");
      return true;
   }

   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent event;

      if(!CalendarEventById(values[i].event_id, event))
      {
         Print("Calendar event lookup failed. Blocking entries.");
         return true;
      }

      if(event.importance == CALENDAR_IMPORTANCE_HIGH)
      {
         Print("High-impact USD event detected: ", event.name);
         return true;
      }
   }

   return false;
}

//====================================================================
// CONFIRMED SWING DETECTION
// A swing at shift 4 is checked against 3 newer and 3 older candles.
// All three newer candles are closed when called on a new bar.
//====================================================================

bool IsSwingHigh(const int shift)
{
   double candidate = iHigh(InpSymbol, InpEntryTF, shift);

   if(candidate <= 0.0)
      return false;

   for(int k = 1; k <= InpSwingLeftRight; k++)
   {
      if(iHigh(InpSymbol, InpEntryTF, shift - k) >= candidate)
         return false;

      if(iHigh(InpSymbol, InpEntryTF, shift + k) > candidate)
         return false;
   }

   return true;
}

bool IsSwingLow(const int shift)
{
   double candidate = iLow(InpSymbol, InpEntryTF, shift);

   if(candidate <= 0.0)
      return false;

   for(int k = 1; k <= InpSwingLeftRight; k++)
   {
      if(iLow(InpSymbol, InpEntryTF, shift - k) <= candidate)
         return false;

      if(iLow(InpSymbol, InpEntryTF, shift + k) < candidate)
         return false;
   }

   return true;
}

double LatestSwingHigh(const int startShift = 4)
{
   int maximum = MathMin(InpLookbackBars,
                        Bars(InpSymbol, InpEntryTF) - 10);

   for(int shift = startShift; shift < maximum; shift++)
   {
      if(IsSwingHigh(shift))
         return iHigh(InpSymbol, InpEntryTF, shift);
   }

   return 0.0;
}

double LatestSwingLow(const int startShift = 4)
{
   int maximum = MathMin(InpLookbackBars,
                        Bars(InpSymbol, InpEntryTF) - 10);

   for(int shift = startShift; shift < maximum; shift++)
   {
      if(IsSwingLow(shift))
         return iLow(InpSymbol, InpEntryTF, shift);
   }

   return 0.0;
}

//====================================================================
// TREND FILTER
// EMA alignment plus a basic recent swing-structure check.
// Full two-transition structure validation remains to be added.
//====================================================================

bool TrendIsBullish()
{
   double ema = GetEMA(1);
   double close = iClose(InpSymbol, InpTrendTF, 1);

   if(ema <= 0.0 || close <= ema)
      return false;

   double high1 = iHigh(InpSymbol, InpTrendTF, 1);
   double high2 = iHigh(InpSymbol, InpTrendTF, 2);
   double low1  = iLow(InpSymbol, InpTrendTF, 1);
   double low2  = iLow(InpSymbol, InpTrendTF, 2);

   return high1 > high2 && low1 > low2;
}

bool TrendIsBearish()
{
   double ema = GetEMA(1);
   double close = iClose(InpSymbol, InpTrendTF, 1);

   if(ema <= 0.0 || close >= ema)
      return false;

   double high1 = iHigh(InpSymbol, InpTrendTF, 1);
   double high2 = iHigh(InpSymbol, InpTrendTF, 2);
   double low1  = iLow(InpSymbol, InpTrendTF, 1);
   double low2  = iLow(InpSymbol, InpTrendTF, 2);

   return high1 < high2 && low1 < low2;
}

//====================================================================
// SETUP MANAGEMENT
//
// This is a simplified state machine. It identifies the sweep,
// subsequent structural break, FVG and midpoint retracement.
// It does not yet implement full multi-swing liquidity clustering,
// complete CHoCH/BOS classification, or persistent setup recovery.
//====================================================================

void UpdateSetups()
{
   double atr = GetATR(1);

   if(atr <= 0.0)
      return;

   double close1 = iClose(InpSymbol, InpEntryTF, 1);
   double open1  = iOpen(InpSymbol, InpEntryTF, 1);
   double high1  = iHigh(InpSymbol, InpEntryTF, 1);
   double low1   = iLow(InpSymbol, InpEntryTF, 1);

   double swingHigh = LatestSwingHigh();
   double swingLow  = LatestSwingLow();

   // Expire stale setups.
   if(g_buyStage > 0)
   {
      g_buyAge++;

      if(g_buyAge > InpMaximumSetupAgeBars ||
         close1 < g_buyFvgLower && g_buyStage >= 3)
      {
         ResetBuySetup();
      }
   }

   if(g_sellStage > 0)
   {
      g_sellAge++;

      if(g_sellAge > InpMaximumSetupAgeBars ||
         close1 > g_sellFvgUpper && g_sellStage >= 3)
      {
         ResetSellSetup();
      }
   }

   // ---------------------------------------------------------------
   // BUY SETUP
   // Stage 0: sell-side liquidity sweep
   // Stage 1: bullish structural break with displacement
   // Stage 2: bullish FVG formation
   // Stage 3: wait for midpoint retracement and confirmation
   // ---------------------------------------------------------------

   if(InpAllowBuy && swingLow > 0.0)
   {
      if(g_buyStage == 0)
      {
         if(low1 < swingLow && close1 > swingLow)
         {
            g_buySweepExtreme = low1;
            g_buyLiquidityLevel = swingLow;
            g_buySetupTime = iTime(InpSymbol, InpEntryTF, 1);
            g_buyStage = 1;
            g_buyAge = 0;

            Print("Potential bullish liquidity sweep detected.");
         }
      }
      else if(g_buyStage == 1)
      {
         double body = MathAbs(close1 - open1);
         double structuralHigh = LatestSwingHigh();

         if(structuralHigh > 0.0 &&
            close1 > structuralHigh &&
            close1 > open1 &&
            body >= InpDisplacementATR * atr)
         {
            g_buyStage = 2;
            Print("Bullish structural break detected.");
         }
      }
      else if(g_buyStage == 2)
      {
         // Three-candle FVG using closed candles:
         // C1 = shift 3, C2 = shift 2, C3 = shift 1.
         double highC1 = iHigh(InpSymbol, InpEntryTF, 3);
         double lowC3  = iLow(InpSymbol, InpEntryTF, 1);
         double bodyC2 = MathAbs(
            iClose(InpSymbol, InpEntryTF, 2) -
            iOpen(InpSymbol, InpEntryTF, 2));

         if(lowC3 > highC1 &&
            bodyC2 >= InpDisplacementATR * atr)
         {
            g_buyFvgLower = highC1;
            g_buyFvgUpper = lowC3;
            g_buyStage = 3;

            Print("Bullish FVG detected.");
         }
      }
      else if(g_buyStage == 3)
      {
         double midpoint = (g_buyFvgLower + g_buyFvgUpper) / 2.0;

         if(low1 <= midpoint &&
            close1 > midpoint &&
            close1 > open1)
         {
            Print("Bullish FVG midpoint retracement confirmed.");
         }
      }
   }

   // ---------------------------------------------------------------
   // SELL SETUP
   // ---------------------------------------------------------------

   if(InpAllowSell && swingHigh > 0.0)
   {
      if(g_sellStage == 0)
      {
         if(high1 > swingHigh && close1 < swingHigh)
         {
            g_sellSweepExtreme = high1;
            g_sellLiquidityLevel = swingHigh;
            g_sellSetupTime = iTime(InpSymbol, InpEntryTF, 1);
            g_sellStage = 1;
            g_sellAge = 0;

            Print("Potential bearish liquidity sweep detected.");
         }
      }
      else if(g_sellStage == 1)
      {
         double body = MathAbs(close1 - open1);
         double structuralLow = LatestSwingLow();

         if(structuralLow > 0.0 &&
            close1 < structuralLow &&
            close1 < open1 &&
            body >= InpDisplacementATR * atr)
         {
            g_sellStage = 2;
            Print("Bearish structural break detected.");
         }
      }
      else if(g_sellStage == 2)
      {
         double lowC1 = iLow(InpSymbol, InpEntryTF, 3);
         double highC3 = iHigh(InpSymbol, InpEntryTF, 1);

         double bodyC2 = MathAbs(
            iClose(InpSymbol, InpEntryTF, 2) -
            iOpen(InpSymbol, InpEntryTF, 2));

         if(highC3 < lowC1 &&
            bodyC2 >= InpDisplacementATR * atr)
         {
            g_sellFvgLower = highC3;
            g_sellFvgUpper = lowC1;
            g_sellStage = 3;

            Print("Bearish FVG detected.");
         }
      }
      else if(g_sellStage == 3)
      {
         double midpoint = (g_sellFvgLower + g_sellFvgUpper) / 2.0;

         if(high1 >= midpoint &&
            close1 < midpoint &&
            close1 < open1)
         {
            Print("Bearish FVG midpoint retracement confirmed.");
         }
      }
   }
}

//====================================================================
// ENTRY CONFIRMATION
//====================================================================

bool BuyConfirmation()
{
   double close1 = iClose(InpSymbol, InpEntryTF, 1);
   double minorHigh = LatestSwingHigh(4);

   if(minorHigh <= 0.0)
      return false;

   return close1 > minorHigh;
}

bool SellConfirmation()
{
   double close1 = iClose(InpSymbol, InpEntryTF, 1);
   double minorLow = LatestSwingLow(4);

   if(minorLow <= 0.0)
      return false;

   return close1 < minorLow;
}

//====================================================================
// POSITION OWNERSHIP
//====================================================================

bool HasOurOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

      if(symbol == InpSymbol && magic == InpMagic)
         return true;
   }

   return false;
}

//====================================================================
// RISK-BASED VOLUME CALCULATION
// Uses the broker's tick size and tick value.
//====================================================================

double CalculateRiskVolume(const double entry,
                           const double stopLoss)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;

   double tickSize = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE);

   double minVolume = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);
   double volumeStep = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);

   double distance = MathAbs(entry - stopLoss);

   if(distance <= 0.0 || tickSize <= 0.0 ||
      tickValue <= 0.0 || volumeStep <= 0.0)
   {
      Print("Position sizing failed: invalid broker specifications.");
      return 0.0;
   }

   double lossPerLot = (distance / tickSize) * tickValue;

   if(lossPerLot <= 0.0)
      return 0.0;

   double rawVolume = riskMoney / lossPerLot;

   // Round DOWN to the broker's volume step.
   double volume = MathFloor(rawVolume / volumeStep) * volumeStep;

   if(volume < minVolume)
   {
      Print("Trade skipped: minimum volume exceeds risk budget.");
      return 0.0;
   }

   volume = MathMin(volume, maxVolume);
   volume = NormalizeDouble(volume, 8);

   // Recalculate approximate risk after volume normalization.
   double estimatedRisk = lossPerLot * volume;

   if(estimatedRisk > riskMoney * 1.001)
   {
      Print("Trade skipped: normalized volume exceeds risk budget.");
      return 0.0;
   }

   return volume;
}

//====================================================================
// PRICE NORMALIZATION
//====================================================================

double NormalizePriceToTick(const double price)
{
   double tickSize = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   if(tickSize <= 0.0)
      return NormalizeDouble(price, digits);

   return NormalizeDouble(
      MathRound(price / tickSize) * tickSize,
      digits);
}

//====================================================================
// OPPOSING LIQUIDITY TARGETS
//
// Simplified target selection: latest opposing confirmed swing.
// A production version must search all relevant opposing liquidity
// and validate broker constraints before submission.
//====================================================================

double BuyTarget(const double entry, const double stopLoss)
{
   double target = LatestSwingHigh();

   if(target <= entry)
      return 0.0;

   double risk = entry - stopLoss;

   if(risk <= 0.0 || (target - entry) / risk < InpMinimumRR)
      return 0.0;

   return target;
}

double SellTarget(const double entry, const double stopLoss)
{
   double target = LatestSwingLow();

   if(target <= 0.0 || target >= entry)
      return 0.0;

   double risk = stopLoss - entry;

   if(risk <= 0.0 || (entry - target) / risk < InpMinimumRR)
      return 0.0;

   return target;
}

//====================================================================
// ORDER EXECUTION
//====================================================================

bool ExecuteBuy()
{
   MqlTick tick;

   if(!SymbolInfoTick(InpSymbol, tick))
      return false;

   double atr = GetATR(1);

   if(atr <= 0.0 || g_buySweepExtreme <= 0.0)
      return false;

   double entry = tick.ask;
   double sl = NormalizePriceToTick(
      g_buySweepExtreme - InpStopBufferATR * atr);

   if(sl >= entry)
      return false;

   double tp = BuyTarget(entry, sl);

   if(tp <= entry)
   {
      Print("BUY skipped: no valid opposing-liquidity target meeting RR.");
      return false;
   }

   tp = NormalizePriceToTick(tp);

   double volume = CalculateRiskVolume(entry, sl);

   if(volume <= 0.0)
      return false;

   return SubmitOrder(ORDER_TYPE_BUY, volume, sl, tp);
}

bool ExecuteSell()
{
   MqlTick tick;

   if(!SymbolInfoTick(InpSymbol, tick))
      return false;

   double atr = GetATR(1);

   if(atr <= 0.0 || g_sellSweepExtreme <= 0.0)
      return false;

   double entry = tick.bid;
   double sl = NormalizePriceToTick(
      g_sellSweepExtreme + InpStopBufferATR * atr);

   if(sl <= entry)
      return false;

   double tp = SellTarget(entry, sl);

   if(tp <= 0.0 || tp >= entry)
   {
      Print("SELL skipped: no valid opposing-liquidity target meeting RR.");
      return false;
   }

   tp = NormalizePriceToTick(tp);

   double volume = CalculateRiskVolume(entry, sl);

   if(volume <= 0.0)
      return false;

   return SubmitOrder(ORDER_TYPE_SELL, volume, sl, tp);
}

bool SubmitOrder(const ENUM_ORDER_TYPE orderType,
                 const double volume,
                 const double sl,
                 const double tp)
{
   for(int attempt = 1; attempt <= InpMaxOrderAttempts; attempt++)
   {
      if(!SpreadAllowed())
         return false;

      MqlTick tick;

      if(!SymbolInfoTick(InpSymbol, tick))
         return false;

      bool sent = false;

      if(orderType == ORDER_TYPE_BUY)
      {
         sent = trade.Buy(volume, InpSymbol, 0.0, sl, tp,
                          InpTradeComment);
      }
      else if(orderType == ORDER_TYPE_SELL)
      {
         sent = trade.Sell(volume, InpSymbol, 0.0, sl, tp,
                           InpTradeComment);
      }

      uint retcode = trade.ResultRetcode();

      if(sent &&
         (retcode == TRADE_RETCODE_DONE ||
          retcode == TRADE_RETCODE_DONE_PARTIAL ||
          retcode == TRADE_RETCODE_PLACED))
      {
         Print("Order accepted. Type=", EnumToString(orderType),
               ", volume=", DoubleToString(volume, 2),
               ", SL=", DoubleToString(sl, _Digits),
               ", TP=", DoubleToString(tp, _Digits));

         return true;
      }

      Print("Order attempt ", attempt,
            " failed. Retcode=", retcode,
            ", description=", trade.ResultRetcodeDescription());

      // Do not retry permanent failures.
      if(retcode == TRADE_RETCODE_INVALID ||
         retcode == TRADE_RETCODE_INVALID_VOLUME ||
         retcode == TRADE_RETCODE_INVALID_PRICE ||
         retcode == TRADE_RETCODE_INVALID_STOPS ||
         retcode == TRADE_RETCODE_NO_MONEY ||
         retcode == TRADE_RETCODE_MARKET_CLOSED ||
         retcode == TRADE_RETCODE_TRADE_DISABLED)
      {
         return false;
      }

      if(attempt < InpMaxOrderAttempts)
         Sleep(500);
   }

   return false;
}

//====================================================================
// POSITION MANAGEMENT
//
// Uses the initial stop-loss distance as R. This first version
// reconstructs R from the current broker position's SL, so it does
// NOT preserve the original R after the SL has been modified.
// A production version must persist initial R separately.
//====================================================================

void ManageOpenPositions()
{
   double atr = GetATR(1);

   if(atr <= 0.0)
      return;

   MqlTick tick;

   if(!SymbolInfoTick(InpSymbol, tick))
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      if(sl <= 0.0 || entry <= 0.0)
         continue;

      double initialRisk = MathAbs(entry - sl);

      if(initialRisk <= 0.0)
         continue;

      double currentPrice =
         (type == POSITION_TYPE_BUY) ? tick.bid : tick.ask;

      double profitDistance =
         (type == POSITION_TYPE_BUY)
         ? currentPrice - entry
         : entry - currentPrice;

      double currentR = profitDistance / initialRisk;
      double newSL = sl;
      bool modify = false;

      // Breakeven
      if(InpUseBreakEven && currentR >= InpBreakEvenAtR)
      {
         double buffer = InpBreakEvenBufferPoints *
                         SymbolInfoDouble(InpSymbol, SYMBOL_POINT);

         double be = (type == POSITION_TYPE_BUY)
                     ? entry + buffer
                     : entry - buffer;

         if(type == POSITION_TYPE_BUY && be > newSL &&
            be < currentPrice)
         {
            newSL = be;
            modify = true;
         }

         if(type == POSITION_TYPE_SELL && be < newSL &&
            be > currentPrice)
         {
            newSL = be;
            modify = true;
         }
      }

      // ATR trailing
      if(InpUseATRTrailing && currentR >= InpTrailingStartR)
      {
         double distance = atr * InpTrailingATRMultiplier;

         double candidate =
            (type == POSITION_TYPE_BUY)
            ? currentPrice - distance
            : currentPrice + distance;

         candidate = NormalizePriceToTick(candidate);

         if(type == POSITION_TYPE_BUY &&
            candidate > newSL &&
            candidate < currentPrice)
         {
            newSL = candidate;
            modify = true;
         }

         if(type == POSITION_TYPE_SELL &&
            candidate < newSL &&
            candidate > currentPrice)
         {
            newSL = candidate;
            modify = true;
         }
      }

      if(modify)
      {
         newSL = NormalizePriceToTick(newSL);

         // Never loosen an existing stop.
         bool tightens =
            (type == POSITION_TYPE_BUY && newSL > sl) ||
            (type == POSITION_TYPE_SELL && newSL < sl);

         if(tightens)
         {
            if(!trade.PositionModify(ticket, newSL, tp))
            {
               Print("Position modification failed. Ticket=", ticket,
                     ", retcode=", trade.ResultRetcode(),
                     ", description=", trade.ResultRetcodeDescription());
            }
         }
      }
   }
}

//====================================================================
// DAILY PROTECTION
//
// This basic implementation tracks equity from EA initialization
// and uses server-day boundaries. It does not persist state across
// restarts and does not yet calculate EA-only realized daily losses.
//====================================================================

void ResetDailyReference()
{
   datetime serverTime = TimeTradeServer();

   if(serverTime <= 0)
      serverTime = TimeCurrent();

   MqlDateTime dt;
   TimeToStruct(serverTime, dt);

   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;

   g_dayStart = StructToTime(dt);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dailyLocked = false;
}

void UpdateDailyProtection()
{
   datetime serverTime = TimeTradeServer();

   if(serverTime <= 0)
      return;

   MqlDateTime now;
   MqlDateTime start;

   TimeToStruct(serverTime, now);
   TimeToStruct(g_dayStart, start);

   if(now.year != start.year ||
      now.mon != start.mon ||
      now.day != start.day)
   {
      ResetDailyReference();
   }

   if(!InpUseDailyProtection || g_dailyLocked)
      return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(g_dayStartEquity > 0.0)
   {
      double equityDD =
         100.0 * (g_dayStartEquity - equity) / g_dayStartEquity;

      if(equityDD >= InpMaxDailyDrawdownPct)
      {
         g_dailyLocked = true;
         Print("Daily lockout: equity drawdown limit reached.");
         return;
      }
   }

   // Approximate balance-loss protection.
   // This is NOT EA-only realized-loss accounting.
   if(g_dayStartBalance > 0.0)
   {
      double balanceLoss =
         100.0 * (g_dayStartBalance - balance) / g_dayStartBalance;

      if(balanceLoss >= InpMaxDailyLossPct)
      {
         g_dailyLocked = true;
         Print("Daily lockout: balance-loss limit reached.");
      }
   }
}

//====================================================================
// SETUP RESET
//====================================================================

void ResetBuySetup()
{
   g_buyStage = 0;
   g_buyAge = 0;
   g_buySweepExtreme = 0.0;
   g_buyLiquidityLevel = 0.0;
   g_buyFvgLower = 0.0;
   g_buyFvgUpper = 0.0;
   g_buySetupTime = 0;
}

void ResetSellSetup()
{
   g_sellStage = 0;
   g_sellAge = 0;
   g_sellSweepExtreme = 0.0;
   g_sellLiquidityLevel = 0.0;
   g_sellFvgLower = 0.0;
   g_sellFvgUpper = 0.0;
   g_sellSetupTime = 0;
}
//+------------------------------------------------------------------+