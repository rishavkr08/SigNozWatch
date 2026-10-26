import Foundation

private func check(_ ok: Bool, _ what: String) {
    if !ok { print("self-check FAILED: \(what)"); exit(1) }
}

/// `SigNozWatch --check`: the one runnable check for the pure logic. Touches no network and no preferences.
func selfCheck() {
    let services = Data(#"""
    [{"serviceName":"atlas","p99":262061607.06,"avgDuration":35406331.7,"numCalls":343,"callRate":0.394,"numErrors":0,"errorRate":0,"num4XX":0,"fourXXRate":0,"dataWarning":{"topLevelOps":["GET"]}},
     {"serviceName":"thrillophilia-partners","p99":6371423515.23,"avgDuration":1,"numCalls":24405,"callRate":1548.27,"numErrors":1465,"errorRate":6.0,"num4XX":0,"fourXXRate":0}]
    """#.utf8)
    let hosts = Data(#"""
    {"status":"success","data":{"type":"list","records":[{"hostName":"staging-1","active":true,"os":"linux","cpu":0.76,"memory":0.55,"wait":0.0011,"load15":4.93,"meta":{"host.name":"staging-1"}},
     {"hostName":"db-1","active":false,"cpu":0,"memory":0,"load15":0}],"total":2}}
    """#.utf8)
    let rules = Data(#"""
    {"status":"success","data":{"rules":[
     {"id":"r1","state":"firing","alert":"[Prod] Sidekiq job failures spiking","labels":{"severity":"warning"},"annotations":{"description":"Normal is ~10-40 failures."},"disabled":false,
      "condition":{"compositeQuery":{"queries":[{"spec":{"query":"SELECT count() WHERE serviceName = 'thrillophilia-partners'"}}]}}},
     {"id":"r2","state":"inactive","alert":"[Prod] DB saturated","labels":{"severity":"critical"},"disabled":false,"condition":{}},
     {"id":"r3","state":"inactive","alert":"Old rule","labels":{},"disabled":true,"condition":{}}]}}
    """#.utf8)

    guard let sv = try? Parse.services(services), let hs = try? Parse.hosts(hosts), let al = try? Parse.rules(rules) else {
        check(false, "parse threw"); return
    }
    check(sv.count == 2 && sv[0].name == "atlas" && Int(sv[0].p99Ms) == 262 && sv[1].numErrors == 1465 && sv[1].errorPct == 6.0, "services parse (p99 ns → ms)")
    check(hs.count == 2 && Int(hs[0].cpuPct.rounded()) == 76 && Int(hs[0].memPct.rounded()) == 55 && hs[0].os == "linux" && !hs[1].active, "hosts parse (fractions → %)")
    check(al.count == 3 && al[0].firing && al[0].sev == .warn && al[1].state == "inactive" && al[2].state == "disabled", "rules parse")
    check(al[0].matches("thrillophilia-partners") && !al[0].matches("atlas"), "rule matched to its service by name")
    check((try? Parse.rules(services)) == nil, "rules parser rejects the wrong shape")

    let t = Thresholds.load()
    check(t.errPct == 5 && t.p99Ms == 2000 && t.pollSec == 60, "limits come registered")
    check(health(sv[0], t, alerts: al).sev == .ok, "quiet service is green")
    let partners = health(sv[1], t, alerts: al)
    check(partners.sev == .bad && partners.why == "6.0% errors · p99 6.4 s", "errors over the limit are red, with both reasons")
    var warm = sv[0]; warm.errorPct = 4.2
    check(health(warm, t, alerts: []).sev == .warn, "80% of the error limit is orange")
    var idle = sv[0]; idle.numCalls = 0
    check(health(idle, t, alerts: []).why == "no traffic in 15 min", "no traffic is orange")
    check(health(hs[1], t, alerts: []).sev == .bad && health(hs[0], t, alerts: []).sev == .warn, "inactive host red, 76% CPU orange")
    let alerted = Server(kind: .service, name: "thrillophilia-partners")
    check(health(alerted, t, alerts: al).why == "no traffic in 15 min · [Prod] Sidekiq job failures spiking", "a firing warning rule shows on its service")

    let merged = merge(sv, known: ["service:atlas", "host:old-box", "junk"])
    check(merged.count == 3 && merged[2].kind == .host && merged[2].name == "old-box" && merged[2].missing, "known server missing from the poll is kept as missing")
    check(health(merged[2], t, alerts: []).sev == .bad, "missing server is red")

    check(labelText(unhealthy: 0, hasData: true, error: nil) == "OK", "label when all healthy")
    check(labelText(unhealthy: 2, hasData: true, error: "x") == "2", "label shows the count even when the last poll failed")
    check(labelText(unhealthy: 0, hasData: false, error: "x") == "?", "label before any data")
    check(fmtMs(242) == "242 ms" && fmtMs(6371) == "6.4 s" && fmt(0.277) == "0.3" && fmt(1548.3) == "1548", "number formatting")

    let a = Alerter()
    let item = Item(key: "service:x", title: "x", body: "", severity: .bad, path: "/")
    let now = Date()
    check(a.evaluate([item], cooldownMin: 30, now: now).count == 1, "first alert fires")
    check(a.evaluate([item], cooldownMin: 30, now: now.addingTimeInterval(600)).isEmpty, "cooldown suppresses the repeat")
    check(a.evaluate([item], cooldownMin: 30, now: now.addingTimeInterval(1801)).count == 1, "fires again after the cooldown")

    let tmp = NSTemporaryDirectory() + "signozwatch-check.json"
    try! #"{"mcpServers":{"signoz":{"env":{"SIGNOZ_URL":"https://s.example","SIGNOZ_API_KEY":"k"}}}}"#.write(toFile: tmp, atomically: true, encoding: .utf8)
    let c = Config.fromClaudeMCP(path: tmp)
    check(c?.url == "https://s.example" && c?.key == "k" && c?.isSet == true, "MCP config import")
    check(Config.fromClaudeMCP(path: "/nonexistent") == nil, "missing MCP config")
    check(Config(url: "https://s.example/", key: "k").base == "https://s.example", "trailing slash stripped")
    print("self-check OK")
}
