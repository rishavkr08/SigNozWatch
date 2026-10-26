# SigNozWatch

Menu bar status of every server in your SigNoz, for macOS 14+. Native Swift/SwiftUI, no dependencies. Sibling of [SysWatch](../SysWatch).

- **Menu bar:** a green/orange/red dot plus the number of unhealthy servers (`OK` when none).
- **Panel:** APM services (requests/s, error rate, p99), infra hosts (CPU, memory, load), SigNoz alert rules (firing first) and the notifications sent. Every row has a one-line reason and a link into SigNoz.
- **Colours:** orange within 80% of a limit or a warning alert, red over a limit, a critical alert, a host that stopped sending metrics or a server that disappeared from SigNoz.
- **Notifications** when a server turns red or a rule starts firing, at most once per cooldown (30 min by default). Clicking one opens it in SigNoz.

## Build and install

Needs Apple's Command Line Tools (`xcode-select --install`), not Xcode.

```sh
./build.sh --install
```

On first launch the app takes the SigNoz URL and API key from the SigNoz MCP server entry in `~/.claude.json` if there is one; otherwise paste them under **Settings…** in the panel. The key lives only in the app's preferences (`local.signozwatch.monitor`), never in this repo.

## Checks

```sh
.build/release/SigNozWatch --check   # pure logic: parsing, severity, cooldown, config import
.build/release/SigNozWatch --once    # one real poll printed to the terminal
```

## SigNoz API used

`POST /api/v1/services`, `POST /api/v1/hosts/list` and `GET /api/v1/rules`, with the `SIGNOZ-API-KEY` header, over the last 15 minutes, every 60 s (adjustable).
