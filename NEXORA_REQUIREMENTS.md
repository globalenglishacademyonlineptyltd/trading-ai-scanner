# NEXORA product requirements

## Trading modes
- Manual mode is the initial mode. NEXORA analyses and prepares trade plans; the user decides whether and where to place a live order.
- Automatic broker execution is a future optional capability. It must be OFF by default, require explicit user activation, and remain unavailable until data, risk controls and execution have been tested.
- The user must be able to disable automatic execution and pause new orders immediately.
- No broker or trading platform has been selected yet. Keep data analysis and execution integrations modular and broker-independent.

## Global market coverage
- Do not restrict scanning to a fixed shortlist or a few preferred markets.
- Discover and catalogue all instruments made available by connected data providers, exchanges and brokers, subject to licensing, jurisdiction, data quality and account permissions.
- Coverage should include all available fiat currencies and currency pairs, crypto assets and pairs, listed stocks and ETFs, indices, metals, energy, agricultural commodities, bonds/rates, futures, options and other supported instruments.
- Clearly report coverage and data status: connected, live, delayed, stale, unavailable, unsupported or restricted. Never claim to scan instruments for which the system has no valid data.

## Intelligence sources
- Combine market prices and historical data, financial news, economic calendars and reliable sentiment information.
- Analyse technical/quantitative signals, volatility, liquidity, volume, order-book information where available, correlations, cross-market effects and unusual activity.
- Match news/events to potentially affected instruments and retain source and timestamp information.
- Cross-check evidence; allow WAIT/no-trade decisions when information conflicts, data is stale or risk is unacceptable.

## Mandatory trade planning and management
- Every proposed trade must have a defined entry, protective stop-loss, take-profit target, risk/reward calculation and risk review.
- Validate direction: for long trades, stop-loss below entry and take-profit above entry; for short trades, stop-loss above entry and take-profit below entry.
- Stop-loss methods may include structure/volatility-based levels, fixed stops, break-even stops and trailing stops where suitable.
- Take-profit should support a target price and, in a later full execution layer, multiple targets and partial position exits.
- Trailing stop must be supported for both long and short positions. It follows only favourable price movement, ratchets in the protective direction and must never widen the stop to increase risk.
- Track the best favourable price since entry and calculate the trailing stop from that reference and the configured trailing distance or strategy rule.
- Explain that stop orders may fill worse than their trigger price because of gaps, slippage or low liquidity.
- Calculate position size only when verified contract size, tick/pip value, account-currency conversion, fees, leverage/margin and broker rules are known. A cash-risk budget alone is not enough.
- Risk controls must include per-trade risk, aggregate exposure, daily loss limits, spread/liquidity/volatility checks, duplicate-order prevention, error handling, audit logs and an emergency kill switch.

## Current prototype scope
- The manual trade planner provides local calculations for entry/stop/target distances, risk/reward, account cash-risk budget and an illustrative trailing-stop level.
- The trailing-stop calculator uses the best favourable price entered by the user and never loosens the displayed stop.
- The planner does not calculate broker-specific position quantity and does not place, modify or close orders.
- The market list and signal scores currently in the prototype are hard-coded demonstration data. Live market feeds, news ingestion, global instrument discovery, production AI signal analysis, persistence and broker execution are not yet implemented.
- All calculations must be tested and reviewed before any live trading use.
