import SwiftUI
import ServiceManagement

let historySamples = 60   // one hour of sparkline at the default 60 s poll

// MARK: - Severity colours (same scheme as SysWatch)

enum Severity: Int, Comparable {
    case ok, warn, bad
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    var color: Color { switch self { case .ok: .green; case .warn: .orange; case .bad: .red } }
    var nsColor: NSColor { switch self { case .ok: .systemGreen; case .warn: .systemOrange; case .bad: .systemRed } }
    /// Text colour: only problems get coloured, so normal rows stay quiet.
    var textColor: Color { self == .ok ? .primary : color }
}

/// Higher is worse: orange from 80% of the threshold, red at the threshold.
func severity(_ value: Double, over threshold: Double) -> Severity {
    value >= threshold ? .bad : value >= threshold * 0.8 ? .warn : .ok
}

struct Row: Identifiable {
    let server: Server
    let health: Health
    var id: String { server.id }
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var snap = Snapshot()
    @Published var fetching = false
    @Published var events: [AlertEvent] = []
    @Published var hist: [String: [Double]] = [:]   // server id → error % (services) or CPU % (hosts)
    @Published var known: [String] = UserDefaults.standard.stringArray(forKey: "knownServers") ?? []
    private var lastSigNoz: [Server] = [], lastGrafana: [Server] = [], lastAlerts: [Alert] = []   // last good answer per source
    let alerter = Alerter()
    private var timer: Timer?

    init() {
        alerter.onAlert = { [weak self] e in
            guard let self else { return }
            events.insert(e, at: 0)
            if events.count > 50 { events.removeLast() }
        }
        alerter.onOpen = { [weak self] path in self?.open(path) }
        alerter.setup()
        schedule()
    }

    var thresholds: Thresholds { .load() }
    var rows: [Row] { snap.servers.map { Row(server: $0, health: health($0, thresholds, alerts: snap.alerts)) } }
    var services: [Row] { rows.filter { $0.server.kind == .service } }
    var hosts: [Row] { rows.filter { $0.server.kind == .host } }
    var firing: [Alert] { snap.alerts.filter(\.firing) }
    var unhealthy: Int { rows.filter { $0.health.sev != .ok }.count }
    var overall: Severity { max(rows.map(\.health.sev).max() ?? .ok, firing.map(\.sev).max() ?? .ok, snap.error == nil ? .ok : .warn) }
    var label: String { labelText(unhealthy: unhealthy, hasData: !snap.servers.isEmpty, error: snap.error) }

    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: thresholds.pollSec, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func tick() { Task { await refresh() } }

    /// Each source fails on its own: a bad Grafana token must not blank the SigNoz rows or mark them missing.
    func refresh() async {
        let c = Config.load()
        guard c.isSet else { snap.error = "Set the SigNoz URL and API key under Settings"; return }
        if fetching { return }
        fetching = true
        defer { fetching = false }
        let signoz = Task { try await SigNozClient(config: c).fetch() }
        let grafana = Task { c.grafanaSet ? try await GrafanaClient(config: c).hosts() : [] }
        var errors: [String] = []
        do { let r = try await signoz.value; lastSigNoz = r.servers; lastAlerts = r.alerts } catch { errors.append("SigNoz: \(error.localizedDescription)") }
        do { lastGrafana = try await grafana.value } catch { errors.append("Grafana: \(error.localizedDescription)") }
        if errors.count == 2 && snap.servers.isEmpty { snap.error = errors.joined(separator: "\n"); return }
        let fresh = lastSigNoz.filter { s in !lastGrafana.contains { $0.id == s.id } } + lastGrafana   // same host in both: Grafana has more
        known = Array(Set(known).union(fresh.map(\.id))).sorted()
        UserDefaults.standard.set(known, forKey: "knownServers")
        snap = Snapshot(servers: merge(fresh, known: known), alerts: lastAlerts, date: Date(), error: errors.isEmpty ? nil : errors.joined(separator: "\n"))
        for s in fresh {
            hist[s.id, default: []].append(s.kind == .service ? s.errorPct : s.cpuPct)
            if hist[s.id]!.count > historySamples { hist[s.id]!.removeFirst() }
        }
        alerter.check(rows, firing: firing, thresholds)
    }

    func forget(_ id: String) {
        known.removeAll { $0 == id }
        UserDefaults.standard.set(known, forKey: "knownServers")
        snap.servers.removeAll { $0.id == id && $0.missing }
    }

    func open(_ path: String) {
        if let u = URL(string: path.hasPrefix("http") ? path : Config.load().base + path) { NSWorkspace.shared.open(u) }
    }
}

// MARK: - App

@main
struct SigNozWatchApp: App {
    @StateObject private var model = Model()

    init() {
        if CommandLine.arguments.contains("--check") { selfCheck(); exit(0) }
        if CommandLine.arguments.contains("--once") { pollOnce() }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel(model: model)
        } label: {
            Image(nsImage: statusImage(dot: model.overall.nsColor, text: model.label))
        }
        .menuBarExtraStyle(.window)
    }
}

/// `SigNozWatch --once`: one poll printed to the terminal, to check the URL and key without the menu bar.
func pollOnce() -> Never {
    Task {
        let c = Config.load()
        do {
            var (servers, alerts) = try await SigNozClient(config: c).fetch()
            if c.grafanaSet { servers += try await GrafanaClient(config: c).hosts() } else { print("Grafana: not configured") }
            for s in servers {
                let h = health(s, .load(), alerts: alerts)
                print("\(h.sev) \(s.kind.rawValue) \(s.name)" + (s.service.isEmpty ? "" : " (\(s.service), \(s.env))") + ": " + (s.kind == .service
                    ? "\(fmt(s.callRate))/s, \(s.numErrors) errors (\(fmt(s.errorPct))%), p99 \(fmtMs(s.p99Ms))"
                    : "cpu \(Int(s.cpuPct))%, mem \(Int(s.memPct))%, disk \(Int(s.diskPct))%, load/core \(fmt(s.loadPerCore)), load15 \(fmt(s.load15)), stale \(Int(s.staleSec))s [\(s.os)]")
                    + (h.why.isEmpty ? "" : " — \(h.why)"))
            }
            for a in alerts { print("\(a.state) alert (\(a.severity)): \(a.name)") }
        } catch { print("error: \(error.localizedDescription)") }
        exit(0)
    }
    RunLoop.main.run()
    fatalError()
}

// MARK: - Panel

struct Panel: View {
    @ObservedObject var model: Model
    @AppStorage("signozURL") private var url = ""
    @AppStorage("signozKey") private var key = ""
    @AppStorage("errPct") private var errPct = 5.0
    @AppStorage("p99Ms") private var p99Ms = 2000.0
    @AppStorage("cpuPct") private var cpuPct = 90.0
    @AppStorage("memPct") private var memPct = 90.0
    @AppStorage("diskPct") private var diskPct = 90.0
    @AppStorage("loadPerCore") private var loadPerCore = 1.5
    @AppStorage("staleSec") private var staleSec = 120.0
    @AppStorage("grafanaURL") private var grafanaURL = ""
    @AppStorage("grafanaKey") private var grafanaKey = ""
    @AppStorage("cooldownMin") private var cooldownMin = 30.0
    @AppStorage("pollSec") private var pollSec = 60.0
    @State private var showSettings = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        // Fixed size on purpose: a MenuBarExtra window that grows with its content drifts off screen when it shrinks again.
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if let e = model.snap.error {
                        Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).lineLimit(3)
                    }
                    if showSettings || url.isEmpty || key.isEmpty { settingsCard }
                    ServersCard(title: "Servers", rows: model.services, model: model, empty: "No machine sent traces in the last \(windowMinutes) min")
                    ServersCard(title: "Host metrics", rows: model.hosts, model: model, empty: "No host sending infra metrics")
                    AlertsCard(model: model)
                    EventsCard(model: model)
                }
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 640, height: 680)
    }

    var header: some View {
        HStack(spacing: 8) {
            Text("SigNozWatch").font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.fetching {
                ProgressView().controlSize(.small)
            } else if model.snap.date > .distantPast {
                (Text("updated ") + Text(model.snap.date, style: .relative) + Text(" ago")).font(.caption).foregroundStyle(.secondary)
            }
            Button { model.tick() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh now")
            Button("Open SigNoz") { model.open("/") }.buttonStyle(.link).font(.callout)
        }
    }

    var settingsCard: some View {
        Card {
            Text("SigNoz").fontWeight(.semibold)
            TextField("https://signoz.example.com", text: $url).textFieldStyle(.roundedBorder)
            SecureField("API key (Settings › API Keys in SigNoz)", text: $key).textFieldStyle(.roundedBorder)
            Text("Stored in this app's preferences only. Prefilled from the SigNoz MCP server in ~/.claude.json when present.")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            Text("Grafana (optional: hosts from its Prometheus datasource)").fontWeight(.semibold)
            TextField("https://grafana.example.com", text: $grafanaURL).textFieldStyle(.roundedBorder)
            SecureField("Service account token with Viewer role", text: $grafanaKey).textFieldStyle(.roundedBorder)
                .onChange(of: grafanaURL) { _, _ in UserDefaults.standard.removeObject(forKey: "grafanaDS") }
            Divider()
            Text("Limits").fontWeight(.semibold)
            Stepper("Error rate ≥ \(fmt(errPct))%", value: $errPct, in: 0.5...50, step: 0.5)
            Stepper("p99 latency ≥ \(fmtMs(p99Ms))", value: $p99Ms, in: 100...30000, step: 100)
            Stepper("Host CPU ≥ \(Int(cpuPct))%", value: $cpuPct, in: 50...100, step: 5)
            Stepper("Host memory ≥ \(Int(memPct))%", value: $memPct, in: 50...100, step: 5)
            Stepper("Root disk ≥ \(Int(diskPct))% full", value: $diskPct, in: 50...100, step: 5)
            Stepper("Load per core ≥ \(fmt(loadPerCore))", value: $loadPerCore, in: 0.5...8, step: 0.25)
            Stepper("No data for ≥ \(Int(staleSec)) s", value: $staleSec, in: 30...1800, step: 30)
            Stepper("Repeat a notification at most every \(Int(cooldownMin)) min", value: $cooldownMin, in: 1...240, step: 5)
            Stepper("Poll SigNoz every \(Int(pollSec)) s", value: $pollSec, in: 15...600, step: 15)
                .onChange(of: pollSec) { _, _ in model.schedule() }
            Text("Orange = within 80% of a limit or a warning alert, red = over it or a critical alert.").font(.caption2).foregroundStyle(.secondary)
            Button("Apply and refresh") { showSettings = false; model.tick() }.controlSize(.small)
        }
        .font(.callout)
    }

    var footer: some View {
        HStack {
            Button(showSettings ? "Hide settings" : "Settings…") { showSettings.toggle() }.buttonStyle(.link)
            Spacer()
            Toggle("Launch at login", isOn: $launchAtLogin).toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { model.snap.error = "Login item: \(error.localizedDescription)" }
                }
            Spacer()
            Button("Quit SigNozWatch") { NSApp.terminate(nil) }.buttonStyle(.link).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }
}

// MARK: - Servers

struct ServersCard: View {
    let title: String
    let rows: [Row]
    @ObservedObject var model: Model
    let empty: String

    var body: some View {
        Card {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                Text(rows.isEmpty ? "" : "\(rows.filter { $0.health.sev == .ok }.count) of \(rows.count) healthy · last \(windowMinutes) min")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if rows.isEmpty { Text(empty).font(.callout).foregroundStyle(.secondary) }
            ForEach(rows.sorted { ($0.health.sev, $1.server.env, $1.server.name) > ($1.health.sev, $0.server.env, $0.server.name) }) { ServerRow(row: $0, model: model) }
        }
    }
}

struct ServerRow: View {
    let row: Row
    @ObservedObject var model: Model

    var body: some View {
        let s = row.server, h = row.health, t = model.thresholds
        HStack(spacing: 10) {
            Circle().fill(h.sev.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).fontWeight(h.sev == .ok ? .medium : .semibold).lineLimit(1).truncationMode(.middle)
                Text(h.sev == .ok ? detail : h.why).font(.caption2).foregroundStyle(h.sev == .ok ? .secondary : h.sev.color).lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)
            Spacer()
            if s.missing {
                Button("Forget") { model.forget(s.id) }.buttonStyle(.bordered).controlSize(.mini)
            } else if s.kind == .service {
                metric("\(fmt(s.callRate))/s", .ok, width: 58)
                metric("\(fmt(s.errorPct))% err", severity(s.errorPct, over: t.errPct), width: 64)
                metric("p99 \(fmtMs(s.p99Ms))", severity(s.p99Ms, over: t.p99Ms), width: 80)
            } else {
                metric("cpu \(Int(s.cpuPct))%", severity(s.cpuPct, over: t.cpuPct), width: 58)
                metric("mem \(Int(s.memPct))%", severity(s.memPct, over: t.memPct), width: 64)
                metric(s.diskPct > 0 ? "disk \(Int(s.diskPct))%" : "", severity(s.diskPct, over: t.diskPct), width: 64)
                if s.loadPerCore > 0 { metric("\(fmt(s.loadPerCore))/core", severity(s.loadPerCore, over: t.loadPerCore), width: 80) }
                else { metric("load \(fmt(s.load15))", .ok, width: 80) }
            }
            Sparkline(values: model.hist[s.id] ?? [], color: h.sev.color,
                      range: 0...max(model.hist[s.id]?.max() ?? 1, s.kind == .service ? t.errPct : t.cpuPct))
                .frame(width: 40, height: 18)
            Button { model.open(s.path) } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Open in SigNoz")
        }
    }

    var detail: String {
        let s = row.server
        switch s.kind {
        case .service: return "\(s.service) · \(s.env) · \(s.numErrors) errors"
        case .host: return (s.os.isEmpty ? "host" : s.os) + (s.staleSec > 0 ? " · seen \(Int(s.staleSec)) s ago" : "")
        }
    }

    func metric(_ text: String, _ sev: Severity, width: CGFloat) -> some View {
        Text(text).font(.caption).monospacedDigit().foregroundStyle(sev.textColor).fontWeight(sev == .ok ? .regular : .semibold)
            .frame(width: width, alignment: .trailing)
    }
}

/// Newest sample at the right edge; the line grows in from the right until the buffer is full.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { g in
            Path { p in
                guard values.count > 1 else { return }
                let n = max(values.count, historySamples)
                let span = max(range.upperBound - range.lowerBound, 0.0001)
                for (i, v) in values.enumerated() {
                    let x = g.size.width * CGFloat(i + n - values.count) / CGFloat(n - 1)
                    let clamped = min(max(v, range.lowerBound), range.upperBound)
                    let y = 1.5 + (g.size.height - 3) * (1 - CGFloat((clamped - range.lowerBound) / span))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

// MARK: - Alerts and notifications

struct AlertsCard: View {
    @ObservedObject var model: Model

    var body: some View {
        let rules = model.snap.alerts
        let quiet = rules.filter { !$0.firing }
        Card {
            HStack {
                Text("SigNoz alerts").fontWeight(.semibold)
                Spacer()
                Text(rules.isEmpty ? "" : "\(model.firing.count) firing · \(quiet.count) quiet").font(.caption).foregroundStyle(.secondary)
            }
            if rules.isEmpty { Text("No alert rules").font(.callout).foregroundStyle(.secondary) }
            ForEach(model.firing) { a in
                HStack(spacing: 10) {
                    Circle().fill(a.sev.color).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.name).fontWeight(.semibold).lineLimit(1)
                        Text(a.detail.isEmpty ? "\(a.severity) · firing" : a.detail).font(.caption2).foregroundStyle(a.sev.color).lineLimit(2)
                    }
                    Spacer()
                    Button { model.open(a.path) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Open in SigNoz")
                }
            }
            if !quiet.isEmpty {
                Text(quiet.map { $0.state == "disabled" ? "\($0.name) (disabled)" : $0.name }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }
}

struct EventsCard: View {
    @ObservedObject var model: Model
    var body: some View {
        Card {
            HStack {
                Text("Notifications sent").fontWeight(.semibold)
                Spacer()
                if model.events.isEmpty { Text("none yet").font(.caption).foregroundStyle(.secondary) }
                else { Button("Clear") { model.events.removeAll() }.controlSize(.small) }
            }
            ForEach(model.events.prefix(8)) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(e.date.formatted(date: .omitted, time: .shortened)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Circle().fill(e.severity.color).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.callout)
                        Text(e.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                }
            }
        }
    }
}
