# SigNozWatch

Menu bar status of every server in your SigNoz, for macOS 14+. Native Swift/SwiftUI, no dependencies. Sibling of [SysWatch](../SysWatch).

- **Menu bar:** a green/orange/red dot plus the number of unhealthy servers (`OK` when none).
- **Panel:** a tab per role (App servers, Web & UI, Data stores, Tooling, Staging, Alerts). One row per machine with three rings under it: CPU, memory and root disk for hosts, or requests, errors and p99 for trace-only machines. A row merges the machine's trace numbers (service, environment, requests/s, error rate, p99) with its host numbers (CPU, memory, disk, load). Then SigNoz alert rules (firing first) and the notifications sent. Every row has a one-line reason and a link into SigNoz or Grafana. Roles come from a keyword table in `category()`.
- **Colours:** orange within 80% of a limit or a warning alert, red over a limit, a critical alert, a host that stopped sending metrics or a server that disappeared from SigNoz.
- **Grafana, optional:** paste a Grafana URL and a Viewer service-account token (or, without Admin rights, your own `user:password`) under Settings… and every host in its Prometheus datasource (node exporter) joins the Host metrics card with CPU, memory, root disk, load per core and seconds since the last scrape. The token is only in the app's preferences.
- **Server IPs:** nothing in SigNoz or Prometheus reports addresses, so paste them once under Settings… (`hostname ip`, one per line). Each machine then shows its IP with a copy button.
- **Notifications** when a server turns red or a rule starts firing, at most once per cooldown (30 min by default). Clicking one opens it in SigNoz.

## Install

**Download:** [rishavkr08.github.io/SigNozWatch](https://rishavkr08.github.io/SigNozWatch/). Or paste this into Terminal. It downloads the latest release, checks its checksum, installs it to /Applications and opens it, with no security prompt:

```sh
curl -fsSL https://github.com/rishavkr08/SigNozWatch/releases/latest/download/install.sh | sh
```

Or download [SigNozWatch.dmg](https://github.com/rishavkr08/SigNozWatch/releases/latest/download/SigNozWatch.dmg) and drag it to Applications (then right-click, Open the first time, since the app is not notarized).

Then click **Settings…** in the panel and paste your SigNoz API key (SigNoz › Settings › API Keys, Viewer role) and, optionally, the Grafana URL with a service-account token or your own `user:password`.

### Build from source

Needs Apple's Command Line Tools (`xcode-select --install`), not Xcode.

```sh
./build.sh --install
```

`./release.sh` builds the universal app, DMG, zip and checksums into `dist/` for a GitHub release; set `DEVELOPER_ID` and `NOTARY_PROFILE` to sign and notarize.

On first launch the app takes the SigNoz URL and API key from the SigNoz MCP server entry in `~/.claude.json` if there is one; otherwise paste them under **Settings…** in the panel. The key lives only in the app's preferences (`local.signozwatch.monitor`), never in this repo.

## Checks

```sh
.build/release/SigNozWatch --check   # pure logic: parsing, severity, cooldown, config import
.build/release/SigNozWatch --once    # one real poll printed to the terminal
```

## SigNoz API used

`POST /api/v5/query_range` (traces grouped by `service.name`, `host.name` and `deployment.environment` with `count()`, `countIf(has_error = true)` and `p99(duration_nano)`), `POST /api/v1/hosts/list` and `GET /api/v1/rules`, with the `SIGNOZ-API-KEY` header; Grafana: `GET /api/datasources` once, then five PromQL instant queries through `/api/datasources/proxy/uid/<uid>/api/v1/query` with a Bearer token, over the last 15 minutes, every 60 s (adjustable).
