import SwiftUI
import ServiceManagement
import UserNotifications

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

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var snap = Snapshot()
    @Published var fetching = false
    @Published var events: [AlertEvent] = []
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
    var machines: [Machine] { SigNozWatch.machines(rows) }
    var categories: [(String, [Machine])] { categorised(machines) }
    var firing: [Alert] { snap.alerts.filter(\.firing) }
    var unhealthy: Int { machines.filter { $0.sev != .ok }.count }
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
        if CommandLine.arguments.contains("--notify-test") { notifyTest() }
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

/// `SigNozWatch --notify-test`: prints the notification permission and posts one sample notification from this process.
/// Notification Center only shows the app icon for the copy macOS launched from /Applications, but the banner itself shows either way.
func notifyTest() -> Never {
    let a = Alerter()
    a.setup()
    UNUserNotificationCenter.current().getNotificationSettings { s in
        let name: String
        switch s.authorizationStatus {
        case .authorized: name = "authorized"
        case .provisional: name = "provisional (quiet, Notification Center only)"
        case .denied: name = "DENIED: turn SigNozWatch on in System Settings › Notifications"
        case .notDetermined: name = "NOT DETERMINED: macOS has not shown the permission prompt yet, or it was dismissed"
        @unknown default: name = "unknown"
        }
        print("permission: \(name); alerts \(s.alertSetting == .enabled ? "on" : "off"), banners \(s.alertStyle == .none ? "off" : "on"), sound \(s.soundSetting == .enabled ? "on" : "off")")
    }
    a.check([], firing: [Alert(id: "test", name: "SigNozWatch test notification", severity: "warning", env: "", state: "firing",
                                 detail: "If you can read this, notifications work. Click to open SigNoz.", text: "")], Thresholds())
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    exit(0)
}

/// `SigNozWatch --once`: one poll printed to the terminal, to check the URL and key without the menu bar.
func pollOnce() -> Never {
    Task {
        let c = Config.load()
        do {
            var (servers, alerts) = try await SigNozClient(config: c).fetch()
            if c.grafanaSet { servers += try await GrafanaClient(config: c).hosts() } else { print("Grafana: not configured") }
            let rows = servers.map { Row(server: $0, health: health($0, .load(), alerts: alerts)) }
            for (cat, ms) in categorised(machines(rows)) {
                print("== \(cat)")
                for m in ms {
                    let parts = m.services.map { "\($0.server.service)/\($0.server.env): \(fmt($0.server.callRate))/s, \($0.server.numErrors) errors (\(fmt($0.server.errorPct))%), p99 \(fmtMs($0.server.p99Ms))" }
                        + (m.host.map { h in ["host: cpu \(Int(h.server.cpuPct))%, mem \(Int(h.server.memPct))%, disk \(Int(h.server.diskPct))%, load/core \(fmt(h.server.loadPerCore)), stale \(Int(h.server.staleSec))s [\(h.server.os)]"] } ?? [])
                    print("\(m.sev) \(m.name): " + parts.joined(separator: " | ") + (m.why.isEmpty ? "" : " — \(m.why)"))
                }
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
    @State private var tab = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    var tabs: [String] { model.categories.map(\.0) + ["Alerts"] }
    @State private var contentHeight: CGFloat = 0   // tallest tab content measured so far
    var current: String { tabs.contains(tab) ? tab : tabs[0] }

    var body: some View {
        // A MenuBarExtra window that shrinks drifts away from the menu bar, so the scroll area keeps the height of the
        // tallest tab it has shown (measured, not estimated) and only lets go of it when the settings card closes.
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if let e = model.snap.error {
                        Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).lineLimit(3)
                    }
                    if showSettings || url.isEmpty || key.isEmpty { settingsCard }
                    if model.machines.isEmpty && model.snap.error == nil {
                        Card { Text("No machine sent traces or host metrics in the last \(windowMinutes) min").font(.callout).foregroundStyle(.secondary) }
                    }
                    if current == "Alerts" {
                        AlertsCard(model: model)
                        EventsCard(model: model)
                    } else if let group = model.categories.first(where: { $0.0 == current }) {
                        CategoryCard(title: group.0, machines: group.1, model: model)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            }
            .frame(height: min(max(contentHeight, 120), 640))
            .onPreferenceChange(HeightKey.self) { h in contentHeight = max(contentHeight, h) }
            .onChange(of: showSettings) { _, on in if !on { contentHeight = 0 } }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 640)
        // A menu bar app's panel never becomes the key window on its own, so text fields ignore typing and paste
        // until the app is activated. Do it on every open; Esc or a click outside still closes the panel.
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }

    var header: some View {
        VStack(spacing: 8) {
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
            Picker("", selection: Binding(get: { current }, set: { tab = $0 })) {
                ForEach(tabs, id: \.self) { t in
                    let n = model.categories.first { $0.0 == t }?.1.filter { $0.sev != .ok }.count ?? (t == "Alerts" ? model.firing.count : 0)
                    Text(n > 0 ? "\(t) (\(n))" : t).tag(t)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }

    var settingsCard: some View {
        Card {
            Text("SigNoz").fontWeight(.semibold)
            TextField("https://signoz.example.com", text: $url).textFieldStyle(.roundedBorder)
            // ponytail: SecureField in the menu bar window keeps the pasted text out of the binding; a plain field saves it.
            TextField("API key (Settings › API Keys in SigNoz)", text: $key).textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
            Text("Stored in this app's preferences only. Prefilled from the SigNoz MCP server in ~/.claude.json when present.")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            Text("Grafana (optional: hosts from its Prometheus datasource)").fontWeight(.semibold)
            TextField("https://grafana.example.com", text: $grafanaURL).textFieldStyle(.roundedBorder)
            TextField("Service account token (glsa_…), or your Grafana user:password", text: $grafanaKey).textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
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

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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

// MARK: - Machines by role

struct CategoryCard: View {
    let title: String
    let machines: [Machine]
    @ObservedObject var model: Model

    var body: some View {
        Card {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                Text("\(machines.filter { $0.sev == .ok }.count) of \(machines.count) healthy · last \(windowMinutes) min").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(machines) { m in
                MachineRow(m: m, model: model)
                MachineRings(m: m, model: model)
                if m.id != machines.last?.id { Divider() }
            }
        }
    }
}

/// One machine: name and reason on the left, trace numbers and host numbers as one line each on the right.
struct MachineRow: View {
    let m: Machine
    @ObservedObject var model: Model

    var body: some View {
        let t = model.thresholds
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(m.sev.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name).fontWeight(m.sev == .ok ? .medium : .semibold).lineLimit(1).truncationMode(.middle)
                Text(m.sev == .ok ? detail : m.why).font(.caption2).foregroundStyle(m.sev == .ok ? .secondary : m.sev.color).lineLimit(2)
            }
            .frame(width: 180, alignment: .leading)
            Spacer()
            if m.missing && m.rows.allSatisfy(\.server.missing) {
                Button("Forget") { m.rows.forEach { model.forget($0.id) } }.buttonStyle(.bordered).controlSize(.mini)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(m.services) { r in
                        let s = r.server
                        HStack(spacing: 0) {
                            if m.services.count > 1 { Text(s.service).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                            metric("\(fmt(s.callRate))/s", .ok, width: 58)
                            metric("\(fmt(s.errorPct))% err", severity(s.errorPct, over: t.errPct), width: 64)
                            metric("p99 \(fmtMs(s.p99Ms))", severity(s.p99Ms, over: t.p99Ms), width: 80)
                        }
                    }
                    if let h = m.host?.server {
                        HStack(spacing: 0) {
                            metric("cpu \(Int(h.cpuPct))%", severity(h.cpuPct, over: t.cpuPct), width: 58)
                            metric("mem \(Int(h.memPct))%", severity(h.memPct, over: t.memPct), width: 64)
                            metric(h.diskPct > 0 ? "disk \(Int(h.diskPct))%" : "", severity(h.diskPct, over: t.diskPct), width: 64)
                            if h.loadPerCore > 0 { metric("\(fmt(h.loadPerCore))/core", severity(h.loadPerCore, over: t.loadPerCore), width: 80) }
                            else { metric("load \(fmt(h.load15))", .ok, width: 80) }
                        }
                    }
                }
            }
            Button { model.open(m.link) } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Open in " + (m.link.contains("grafana") ? "Grafana" : "SigNoz"))
        }
    }

    var detail: String {
        var parts = m.services.map { "\($0.server.service) · \($0.server.env)" }
        if let h = m.host?.server {
            parts.append(h.os.isEmpty ? "host" : h.os)
            if h.staleSec > 0 { parts.append("seen \(Int(h.staleSec)) s ago") }
        }
        return parts.joined(separator: " · ")
    }

    func metric(_ text: String, _ sev: Severity, width: CGFloat) -> some View {
        Text(text).font(.caption).monospacedDigit().foregroundStyle(sev.textColor).fontWeight(sev == .ok ? .regular : .semibold)
            .frame(width: width, alignment: .trailing)
    }
}

/// Three rings under a machine: CPU, memory, root disk for hosts (share of 100%); errors and p99 against their limits
/// plus the request rate for trace-only machines.
struct MachineRings: View {
    let m: Machine
    @ObservedObject var model: Model

    var body: some View {
        let t = model.thresholds
        HStack(spacing: 0) {
            if let h = m.host?.server {
                ring("CPU", h.cpuPct, of: 100, limit: t.cpuPct, text: "\(Int(h.cpuPct))%")
                ring("Memory", h.memPct, of: 100, limit: t.memPct, text: "\(Int(h.memPct))%")
                if h.diskPct > 0 { ring("Root disk", h.diskPct, of: 100, limit: t.diskPct, text: "\(Int(h.diskPct))%") }
                else { ring("Load", h.load15, of: max(h.load15, 1), limit: .infinity, text: fmt(h.load15)) }
            } else if let s = m.services.first?.server {
                ring("Requests", s.callRate, of: max(s.callRate, 1), limit: .infinity, text: "\(fmt(s.callRate))/s")
                ring("Errors", s.errorPct, of: t.errPct, limit: t.errPct, text: "\(fmt(s.errorPct))%")
                ring("p99", s.p99Ms, of: t.p99Ms, limit: t.p99Ms, text: fmtMs(s.p99Ms))
            }
        }
        .padding(.leading, 19)
    }

    /// `of` is the full circle; `limit` colours it (orange from 80%, red at it). The requests ring is always full and quiet.
    func ring(_ title: String, _ value: Double, of full: Double, limit: Double, text: String) -> some View {
        let sev = limit.isFinite ? severity(value, over: limit) : .ok
        return VStack(spacing: 4) {
            Ring(fraction: value / max(full, 0.001), color: sev.color, text: text, textColor: sev.textColor)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Same drawing as SysWatch's ring, smaller.
struct Ring: View {
    let fraction: Double
    let color: Color
    let text: String
    let textColor: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 6)
            Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(text).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(textColor)
        }
        .frame(width: 56, height: 56)
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
