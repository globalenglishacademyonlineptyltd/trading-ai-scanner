# NEXORA product requirements

## Trading modes
- Manual mode is the initial mode. NEXORA analyses and prepares trade plans; the user decides whether and where to place a live order.
- Automatic broker execution is a future optional capability. It must be OFF by default, require explicit user activation, and remain unavailable until data, risk controls and execution have been tested.
- The user must be able to disable automatic execution and pause new orders immediately.
- No broker or trading platform has been selected yet. Keep data analysis and execution integrations modular and broker-independent.

## User-controlled automatic trading master switch
- Automatic trading permission must default to OFF on every server start.
- Provide a user-visible ON/OFF switch and a separate emergency OFF control.
- The server, not only the browser UI, must enforce the permission: every future automatic order submission path must check the current server-side permission immediately before sending an order. If OFF, reject the request.
- Switching OFF must synchronously block new automatic entries. In a broker integration, cancel unfilled automatic entry orders where supported; do not silently close existing positions or remove protective stop-loss/take-profit orders. Clearly report what was and was not cancelled.
- Switching ON only grants permission; it must not bypass broker connection checks, risk limits, instrument validation, market-data freshness, duplicate-order protection or kill-switch checks.
- Keep broker execution unavailable until a verified broker adapter, authenticated connection, order lifecycle handling and safety tests exist. Never present a UI toggle as proof that live trading is connected.
- The current prototype stores the permission in server memory and resets to OFF on restart; durable per-user settings and authenticated access control are required before production multi-user use.

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


## Automation control prototype implementation
- A server-backed ON/OFF permission control and emergency OFF button are provided. OFF is the default and resets after a server restart.
- The server exposes automation status and mode endpoints. Future automatic order routes/workers must invoke `assertAutomaticExecutionAllowed()` immediately before order submission.
- Broker execution remains hard-disabled in this prototype; turning permission ON only arms the preference and cannot place trades.
- Existing trailing-stop planning/calculation remains available. Live trailing-stop updates, stop-loss and take-profit placement/modification require a broker adapter and are not active yet.
