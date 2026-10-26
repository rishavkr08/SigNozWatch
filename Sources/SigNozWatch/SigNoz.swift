import Foundation

// MARK: - Config

/// SigNoz endpoint and API key, kept in UserDefaults. Never in the source, never committed.
struct Config {
    var url = "", key = ""         // SigNoz
    var gURL = "", gKey = ""       // Grafana (optional second source), service-account token
    var base: String { trim(url) }
    var gBase: String { trim(gURL) }
    var isSet: Bool { !url.isEmpty && !key.isEmpty }
    var grafanaSet: Bool { !gURL.isEmpty && !gKey.isEmpty }
    private func trim(_ u: String) -> String { u.hasSuffix("/") ? String(u.dropLast()) : u }

    static func load() -> Config {
        let d = UserDefaults.standard
        var c = Config(url: d.string(forKey: "signozURL") ?? "", key: d.string(forKey: "signozKey") ?? "",
                       gURL: d.string(forKey: "grafanaURL") ?? "", gKey: d.string(forKey: "grafanaKey") ?? "")
        if !c.isSet, let mcp = fromClaudeMCP() {   // first run: borrow the SigNoz MCP server's settings
            c = mcp
            d.set(c.url, forKey: "signozURL")
            d.set(c.key, forKey: "signozKey")
        }
        return c
    }

    /// ~/.claude.json → mcpServers.signoz.env.{SIGNOZ_URL, SIGNOZ_API_KEY}
    static func fromClaudeMCP(path: String = NSHomeDirectory() + "/.claude.json") -> Config? {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = ((root["mcpServers"] as? [String: Any])?["signoz"] as? [String: Any])?["env"] as? [String: Any],
              let url = env["SIGNOZ_URL"] as? String, let key = env["SIGNOZ_API_KEY"] as? String, !url.isEmpty, !key.isEmpty
        else { return nil }
        return Config(url: url, key: key)
    }
}

struct Thresholds {
    var errPct = 5.0, p99Ms = 2000.0, cpuPct = 90.0, memPct = 90.0, diskPct = 90.0, loadPerCore = 1.5, staleSec = 120.0, cooldownMin = 30.0, pollSec = 60.0
    static let defaults: [String: Any] = ["errPct": 5.0, "p99Ms": 2000.0, "cpuPct": 90.0, "memPct": 90.0, "diskPct": 90.0, "loadPerCore": 1.5,
                                          "staleSec": 120.0, "cooldownMin": 30.0, "pollSec": 60.0]
    static func load() -> Thresholds {
        let d = UserDefaults.standard
        d.register(defaults: defaults)   // here, not only in Model.init, so --once and --check see the same limits
        return Thresholds(errPct: d.double(forKey: "errPct"), p99Ms: d.double(forKey: "p99Ms"), cpuPct: d.double(forKey: "cpuPct"),
                          memPct: d.double(forKey: "memPct"), diskPct: d.double(forKey: "diskPct"), loadPerCore: d.double(forKey: "loadPerCore"),
                          staleSec: d.double(forKey: "staleSec"), cooldownMin: d.double(forKey: "cooldownMin"), pollSec: max(d.double(forKey: "pollSec"), 15))
    }
}

// MARK: - Models

let windowMinutes = 15   // services and hosts are summarised over this trailing window

enum Kind: String { case service, host }

struct Server: Identifiable {
    let kind: Kind
    let name: String          // machine (host.name) for both kinds
    var service = "", env = ""   // service rows: which app and deployment.environment runs on that machine
    var id: String { kind == .service ? "service:\(service)@\(name)" : "host:\(name)" }
    // service, over the window
    var callRate = 0.0, numCalls = 0, numErrors = 0, errorPct = 0.0, p99Ms = 0.0
    // host (SigNoz infra agent, or Grafana's Prometheus node exporter)
    var cpuPct = 0.0, memPct = 0.0, load15 = 0.0, os = ""
    var diskPct = 0.0, loadPerCore = 0.0, staleSec = 0.0   // Grafana only
    var active = true     // host still sending metrics
    var missing = false   // seen on an earlier poll, absent now
    var link = ""         // absolute URL for rows that live outside SigNoz

    /// Relative to the SigNoz base, unless `link` is set.
    var path: String {
        if !link.isEmpty { return link }
        switch kind {
        case .service: return "/services/" + (service.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? service)
        case .host: return "/infrastructure-monitoring/hosts"
        }
    }
}

struct Alert: Identifiable {
    let id: String
    let name: String
    let severity: String   // label from the rule: critical / warning / …
    let env: String        // label from the rule, "" when it has none
    let state: String      // firing / inactive / disabled
    let detail: String     // annotations.description
    let text: String       // name + condition, used to match a server by name
    var firing: Bool { state == "firing" }
    var sev: Severity { severity == "critical" ? .bad : .warn }
    var path: String { "/alerts/overview?ruleId=\(id)" }
    // ponytail: rules carry no service label here, so a rule belongs to a machine when its name or query mentions
    // the machine or its service, and the rule's env label (if any) is that machine's environment.
    func matches(_ s: Server) -> Bool {
        (env.isEmpty || s.env.isEmpty || env == s.env) && [s.name, s.service].contains { !$0.isEmpty && text.range(of: $0, options: .caseInsensitive) != nil }
    }
}

struct Snapshot {
    var servers: [Server] = []
    var alerts: [Alert] = []
    var date = Date.distantPast
    var error: String?
}

struct Health { let sev: Severity; let why: String }

/// Row colour: worst of the numeric limits and any firing alert that mentions the server. `why` names what tripped.
func health(_ s: Server, _ t: Thresholds, alerts: [Alert]) -> Health {
    if s.missing { return Health(sev: .bad, why: "no longer reported by SigNoz") }
    var parts: [(Severity, String)] = []
    switch s.kind {
    case .service:
        parts.append((severity(s.errorPct, over: t.errPct), "\(fmt(s.errorPct))% errors"))
        parts.append((severity(s.p99Ms, over: t.p99Ms), "p99 \(fmtMs(s.p99Ms))"))
        if s.numCalls == 0 { parts.append((.warn, "no traffic in \(windowMinutes) min")) }
    case .host:
        if !s.active { parts.append((.bad, "no metrics")) }
        if s.staleSec > 0 { parts.append((severity(s.staleSec, over: t.staleSec), "no data for \(Int(s.staleSec / 60)) min")) }
        parts.append((severity(s.cpuPct, over: t.cpuPct), "CPU \(Int(s.cpuPct))%"))
        parts.append((severity(s.memPct, over: t.memPct), "memory \(Int(s.memPct))%"))
        if s.diskPct > 0 { parts.append((severity(s.diskPct, over: t.diskPct), "disk \(Int(s.diskPct))% full")) }
        if s.loadPerCore > 0 { parts.append((severity(s.loadPerCore, over: t.loadPerCore), "load \(fmt(s.loadPerCore)) per core")) }
    }
    parts += alerts.filter { $0.firing && $0.matches(s) }.map { ($0.sev, $0.name) }
    let worst = parts.map(\.0).max() ?? .ok
    return Health(sev: worst, why: worst == .ok ? "" : parts.filter { $0.0 == worst }.map(\.1).joined(separator: " · "))
}

/// Servers seen before but absent from this poll stay listed as missing (a dead host simply vanishes from SigNoz).
func merge(_ fresh: [Server], known: [String]) -> [Server] {
    let ids = Set(fresh.map(\.id))
    let gone = known.filter { !ids.contains($0) }.compactMap { id -> Server? in
        let p = id.split(separator: ":", maxSplits: 1)
        guard p.count == 2, let k = Kind(rawValue: String(p[0])) else { return nil }
        let at = p[1].split(separator: "@", maxSplits: 1)   // service:<service>@<host>
        guard k == .host || at.count == 2 else { return nil }
        var s = Server(kind: k, name: String(at.last ?? p[1]), service: k == .service ? String(at[0]) : "")
        s.missing = true
        return s
    }
    return fresh + gone
}

/// Menu bar text next to the dot.
func labelText(unhealthy: Int, hasData: Bool, error: String?) -> String {
    !hasData && error != nil ? "?" : unhealthy == 0 ? "OK" : "\(unhealthy)"
}

func fmt(_ v: Double) -> String { v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v) }
func fmtMs(_ ms: Double) -> String { ms < 1000 ? "\(Int(ms)) ms" : String(format: "%.1f s", ms / 1000) }

// MARK: - Parsing (pure; covered by --check)

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Parse {
    private struct ServiceJSON: Decodable { let serviceName: String; let p99, callRate, errorRate, numCalls, numErrors: Double }
    private struct HostsJSON: Decodable {
        struct Data: Decodable { let records: [Host] }
        struct Host: Decodable { let hostName: String; let active: Bool; let cpu, memory, load15: Double; let os: String? }
        let data: Data
    }

    /// POST /api/v5/query_range, traces grouped by service, host and environment with count(), countIf(has_error), p99(duration_nano).
    static func traces(_ data: Data, windowSec: Double = Double(windowMinutes * 60)) throws -> [Server] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = (((root["data"] as? [String: Any])?["data"] as? [String: Any])?["results"] as? [[String: Any]])?.first,
              let columns = (result["columns"] as? [[String: Any]])?.compactMap({ $0["name"] as? String }),
              let rows = result["data"] as? [[Any]] else { throw APIError(message: "traces: unexpected JSON") }
        func col(_ row: [Any], _ name: String) -> Any? { columns.firstIndex(of: name).flatMap { $0 < row.count ? row[$0] : nil } }
        return rows.compactMap { row in
            guard let host = col(row, "host.name") as? String, let svc = col(row, "service.name") as? String else { return nil }
            var s = Server(kind: .service, name: host, service: svc, env: col(row, "deployment.environment") as? String ?? "")
            let calls = (col(row, "__result_0") as? NSNumber)?.doubleValue ?? 0
            let errors = (col(row, "__result_1") as? NSNumber)?.doubleValue ?? 0
            s.numCalls = Int(calls); s.numErrors = Int(errors); s.callRate = calls / windowSec
            s.errorPct = calls > 0 ? errors / calls * 100 : 0
            s.p99Ms = ((col(row, "__result_2") as? NSNumber)?.doubleValue ?? 0) / 1e6
            return s
        }
    }

    /// POST /api/v1/hosts/list → cpu and memory as fractions of 1.
    static func hosts(_ data: Data) throws -> [Server] {
        try JSONDecoder().decode(HostsJSON.self, from: data).data.records.map {
            var s = Server(kind: .host, name: $0.hostName)
            s.active = $0.active; s.cpuPct = $0.cpu * 100; s.memPct = $0.memory * 100; s.load15 = $0.load15; s.os = $0.os ?? ""
            return s
        }
    }

    /// Prometheus instant-query vector → (labels, value) pairs.
    static func prometheus(_ data: Data) throws -> [(labels: [String: String], value: Double)] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = (root["data"] as? [String: Any])?["result"] as? [[String: Any]] else { throw APIError(message: "prometheus: unexpected JSON") }
        return result.compactMap { r in
            guard let labels = r["metric"] as? [String: String], let v = (r["value"] as? [Any])?.last else { return nil }
            let value = (v as? NSNumber)?.doubleValue ?? Double(v as? String ?? "") ?? .nan
            return value.isNaN ? nil : (labels, value)
        }
    }

    /// GET /api/v1/rules → every rule with its state; the condition is kept as text for name matching.
    static func rules(_ data: Data) throws -> [Alert] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = (root["data"] as? [String: Any])?["rules"] as? [[String: Any]] else { throw APIError(message: "rules: unexpected JSON") }
        return rules.compactMap { r in
            guard let id = r["id"] as? String, let name = r["alert"] as? String else { return nil }
            let labels = r["labels"] as? [String: String] ?? [:]
            let disabled = r["disabled"] as? Bool ?? false
            return Alert(id: id, name: name, severity: labels["severity"] ?? "warning", env: labels["env"] ?? "",
                         state: disabled ? "disabled" : (r["state"] as? String ?? "inactive"),
                         detail: (r["annotations"] as? [String: String])?["description"] ?? "",
                         text: name + " " + String(describing: r["condition"] ?? ""))
        }
    }
}

// MARK: - HTTP

struct SigNozClient {
    let config: Config

    func fetch() async throws -> (servers: [Server], alerts: [Alert]) {
        let now = Date(), start = now.addingTimeInterval(-Double(windowMinutes * 60))
        let ms = { (d: Date) in Int64(d.timeIntervalSince1970 * 1000) }
        async let traces = post("/api/v5/query_range", tracesQuery(start: ms(start), end: ms(now)))
        async let hosts = post("/api/v1/hosts/list", ["start": ms(start), "end": ms(now), "filters": ["items": [], "op": "and"],
                                                      "groupBy": [], "orderBy": ["columnName": "cpu", "order": "desc"], "offset": 0, "limit": 200])
        async let rules = get("/api/v1/rules")
        return (try Parse.traces(await traces) + Parse.hosts(await hosts), try Parse.rules(await rules))
    }

    /// One scalar query: every (service, machine, environment) seen in traces, with calls, errors and p99.
    func tracesQuery(start: Int64, end: Int64) -> [String: Any] {
        let group = ["service.name", "host.name", "deployment.environment"].map {
            ["name": $0, "fieldDataType": "string", "signal": "traces", "fieldContext": "resource"]
        }
        let spec: [String: Any] = ["name": "A", "signal": "traces", "disabled": false, "limit": 200, "offset": 0,
                                   "having": ["expression": ""], "filter": ["expression": ""],
                                   "aggregations": [["expression": "count()"], ["expression": "countIf(has_error = true)"], ["expression": "p99(duration_nano)"]],
                                   "groupBy": group, "order": [["key": ["name": "count()"], "direction": "desc"]]]
        return ["schemaVersion": "v1", "start": start, "end": end, "requestType": "scalar",
                "compositeQuery": ["queries": [["type": "builder_query", "spec": spec]]],
                "formatOptions": ["formatTableResultForUI": false, "fillGaps": false], "variables": [:]]
    }

    func get(_ path: String) async throws -> Data { try await send(request(path)) }

    func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var r = request(path)
        r.httpMethod = "POST"
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(r)
    }

    private func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: URL(string: config.base + path) ?? URL(fileURLWithPath: "/"), timeoutInterval: 20)
        r.setValue(config.key, forHTTPHeaderField: "SIGNOZ-API-KEY")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let hint = code == 401 || code == 403 ? "API key rejected" : String(decoding: data.prefix(120), as: UTF8.self)
            throw APIError(message: "\(r.url?.path ?? "") → HTTP \(code): \(hint)")
        }
        return data
    }
}

// MARK: - Grafana (Prometheus through the datasource proxy)

/// Node-exporter queries, by (instance, server); `server` is Alloy's short name. `stale` catches a host that stopped pushing
/// while its `up` series still reads 1. These match the "Infra — Fleet Overview" dashboard.
let prometheusQueries: [String: String] = [
    "cpu": #"100 - avg by (instance, server)(rate(node_cpu_seconds_total{job="integrations/unix",mode="idle"}[5m])) * 100"#,
    "mem": #"max by (instance, server)((1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100)"#,
    "disk": #"max by (instance, server)((1 - node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}) * 100)"#,
    "load": #"sum by (instance, server)(node_load1) / count by (instance, server)(count by (instance, server, cpu)(node_cpu_seconds_total{mode="idle"}))"#,
    "stale": #"time() - max by (instance, server)(timestamp(up{job="integrations/unix"}))"#,
]

/// One host row per instance from the five query results.
func mergeHosts(_ results: [String: [(labels: [String: String], value: Double)]], link: String) -> [Server] {
    var hosts: [String: Server] = [:]
    for (metric, rows) in results {
        for r in rows {
            guard let instance = r.labels["instance"] else { continue }
            var h = hosts[instance] ?? Server(kind: .host, name: instance, os: (r.labels["server"].map { "\($0) · " } ?? "") + "Grafana", link: link)
            switch metric {
            case "cpu": h.cpuPct = r.value
            case "mem": h.memPct = r.value
            case "disk": h.diskPct = r.value
            case "load": h.loadPerCore = r.value
            case "stale": h.staleSec = max(r.value, 0)
            default: break
            }
            hosts[instance] = h
        }
    }
    return hosts.values.sorted { $0.name < $1.name }
}

/// Service-account tokens start with "glsa_" and need an org Admin to create; anyone can use their own "user:password" instead.
func grafanaAuth(_ key: String) -> String {
    key.hasPrefix("glsa_") || !key.contains(":") ? "Bearer " + key : "Basic " + Data(key.utf8).base64EncodedString()
}

struct GrafanaClient {
    let config: Config

    func hosts() async throws -> [Server] {
        let uid = try await datasourceUID()
        var results: [String: [(labels: [String: String], value: Double)]] = [:]
        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            for (name, expr) in prometheusQueries {
                group.addTask {
                    let q = expr.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? expr
                    return (name, try await send("/api/datasources/proxy/uid/\(uid)/api/v1/query?query=\(q)"))
                }
            }
            for try await (name, data) in group { results[name] = try Parse.prometheus(data) }
        }
        return mergeHosts(results, link: config.gBase + "/d/infra-fleet")
    }

    /// The first Prometheus datasource, looked up once and remembered.
    func datasourceUID() async throws -> String {
        if let uid = UserDefaults.standard.string(forKey: "grafanaDS"), !uid.isEmpty { return uid }
        guard let list = try JSONSerialization.jsonObject(with: try await send("/api/datasources")) as? [[String: Any]],
              let uid = list.first(where: { $0["type"] as? String == "prometheus" })?["uid"] as? String
        else { throw APIError(message: "Grafana has no Prometheus datasource") }
        UserDefaults.standard.set(uid, forKey: "grafanaDS")
        return uid
    }

    private func send(_ path: String) async throws -> Data {
        var r = URLRequest(url: URL(string: config.gBase + path) ?? URL(fileURLWithPath: "/"), timeoutInterval: 20)
        r.setValue(grafanaAuth(config.gKey), forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let hint = code == 401 || code == 403 ? "token rejected" : String(decoding: data.prefix(120), as: UTF8.self)
            throw APIError(message: "Grafana \(path.prefix(40)) → HTTP \(code): \(hint)")
        }
        return data
    }
}
