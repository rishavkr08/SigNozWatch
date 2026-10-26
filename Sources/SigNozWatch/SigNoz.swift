import Foundation

// MARK: - Config

/// SigNoz endpoint and API key, kept in UserDefaults. Never in the source, never committed.
struct Config {
    var url = "", key = ""
    var base: String { url.hasSuffix("/") ? String(url.dropLast()) : url }
    var isSet: Bool { !url.isEmpty && !key.isEmpty }

    static func load() -> Config {
        let d = UserDefaults.standard
        var c = Config(url: d.string(forKey: "signozURL") ?? "", key: d.string(forKey: "signozKey") ?? "")
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
    var errPct = 5.0, p99Ms = 2000.0, cpuPct = 90.0, memPct = 90.0, cooldownMin = 30.0, pollSec = 60.0
    static let defaults: [String: Any] = ["errPct": 5.0, "p99Ms": 2000.0, "cpuPct": 90.0, "memPct": 90.0, "cooldownMin": 30.0, "pollSec": 60.0]
    static func load() -> Thresholds {
        let d = UserDefaults.standard
        d.register(defaults: defaults)   // here, not only in Model.init, so --once and --check see the same limits
        return Thresholds(errPct: d.double(forKey: "errPct"), p99Ms: d.double(forKey: "p99Ms"), cpuPct: d.double(forKey: "cpuPct"),
                          memPct: d.double(forKey: "memPct"), cooldownMin: d.double(forKey: "cooldownMin"), pollSec: max(d.double(forKey: "pollSec"), 15))
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
    // host
    var cpuPct = 0.0, memPct = 0.0, load15 = 0.0, os = ""
    var active = true     // host still sending metrics
    var missing = false   // seen on an earlier poll, absent now

    var path: String {
        switch kind {
        case .service: "/services/" + (service.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? service)
        case .host: "/infrastructure-monitoring/hosts"
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
        parts.append((severity(s.cpuPct, over: t.cpuPct), "CPU \(Int(s.cpuPct))%"))
        parts.append((severity(s.memPct, over: t.memPct), "memory \(Int(s.memPct))%"))
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
