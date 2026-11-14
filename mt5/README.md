# NEXORA MT5 Demo Connector (heartbeat-only)

This is the first integration milestone for the existing NEXORA application.

## Safety scope
- Sends a heartbeat from the MT5 desktop terminal to NEXORA.
- Reports a masked account login, broker server/company, account currency, and terminal/trading permissions.
- Does **not** place, modify, or close trades.
- Automatic trading remains disabled.

## Required server configuration
Set `NEXORA_MT5_TOKEN` in the NEXORA Railway service to a long random secret (at least 24 characters). The same value is entered privately in the EA Inputs in MT5. Do not commit the token or send it in chat.

## Compile and install
1. Download `NEXORA_Connector.mq5`.
2. In MT5 desktop, press F4 to open MetaEditor.
3. In MetaEditor, open the file and press F7 to compile. This creates `NEXORA_Connector.ex5`.
4. In MT5, use File → Open Data Folder → MQL5 → Experts and place the compiled `.ex5` file there.
5. Return to MT5 and refresh Navigator → Expert Advisors.
6. Attach NEXORA_Connector to a chart on a **demo** account.
7. In Tools → Options → Expert Advisors, allow WebRequest for the exact NEXORA HTTPS host (for example, the Railway app host).
8. In EA Inputs, set the NEXORA HTTPS base URL and privately enter the connector token.
9. Confirm the Experts tab reports a successful heartbeat and NEXORA reports the demo terminal as connected.

## Important
The `.mq5` source is not a compiled `.ex5` binary. Compile it with MetaEditor. The Railway service must have the matching `NEXORA_MT5_TOKEN` environment variable and the API endpoint implemented. A successful heartbeat proves connectivity only; it does not verify order execution.
