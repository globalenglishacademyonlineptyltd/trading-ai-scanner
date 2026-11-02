# NEXORA live intelligence setup

## What this release adds
- Server-side Twelve Data quote and candle endpoints.
- GDELT public news search endpoint.
- A deterministic technical analysis baseline (EMA 20/50, RSI 14, momentum and average candle range).
- A live analyzer and news panel in the web UI.
- No broker adapter and no live order submission. Automatic execution remains disabled.

## Required Railway configuration
Set `TWELVEDATA_API_KEY` on the `trading-ai-scanner` service in the production environment. Obtain the key from Twelve Data and keep it in Railway Variables; never place it in browser JavaScript or commit it to Git.

After setting the variable, Railway redeploys the service. Check:
- `/api/health`
- `/api/intelligence/status`
- `/api/market/quote?symbol=EUR/USD`
- `/api/signals?symbol=EUR/USD&interval=1h`
- `/api/news?q=markets%20OR%20finance`

Symbols, exchange coverage, request limits, delays and entitlements are determined by the connected data provider. This is not an exhaustive global exchange feed. Add provider-specific instrument discovery and a second market-data provider before claiming broad global coverage.

## Signal and risk limitations
The current technical baseline is not an AI model and does not ingest news into the signal score. Its score is a rule-based technical score, not a probability of winning. Stop and target distances use recent average candle range and are illustrative only. Do not place a trade solely from these outputs.

Before real trading, add and test: multi-provider data validation and freshness checks, news/event-to-instrument mapping and sentiment verification, historical backtesting with fees/slippage, paper-trading ledger, persistent audit trail, broker-specific contract sizing and risk limits, authenticated user access, and an independently tested broker adapter. Automatic order execution must remain disabled until all of those controls pass review and the user explicitly enables it.
