import Foundation

private func check(_ ok: Bool, _ what: String) {
    if !ok { print("self-check FAILED: \(what)"); exit(1) }
}

/// `SigNozWatch --check`: the one runnable check for the pure logic. Touches no network and no preferences.
func selfCheck() {
    let traces = Data(#"""
    {"status":"success","data":{"type":"scalar","data":{"results":[{"queryName":"A","columns":[{"name":"service.name"},{"name":"host.name"},{"name":"deployment.environment"},{"name":"__result_0"},{"name":"__result_1"},{"name":"__result_2"}],
     "data":[["atlas","atlas-prod-app-server","production",343,0,262061607.06],["thrillophilia-partners","thrillo-partners-prod-app-server-3","production",24405,1465,6371423515.23]]}]}}}
    """#.utf8)
    let hosts = Data(#"""
    {"status":"success","data":{"type":"list","records":[{"hostName":"staging-1","active":true,"os":"linux","cpu":0.76,"memory":0.55,"wait":0.0011,"load15":4.93,"meta":{"host.name":"staging-1"}},
     {"hostName":"db-1","active":false,"cpu":0,"memory":0,"load15":0}],"total":2}}
    """#.utf8)
    let rules = Data(#"""
    {"status":"success","data":{"rules":[
     {"id":"r1","state":"firing","alert":"[Prod] Sidekiq job failures spiking","labels":{"severity":"warning","env":"production"},"annotations":{"description":"Normal is ~10-40 failures."},"disabled":false,
      "condition":{"compositeQuery":{"queries":[{"spec":{"query":"SELECT count() WHERE serviceName = 'thrillophilia-partners'"}}]}}},
     {"id":"r2","state":"inactive","alert":"[Prod] DB saturated","labels":{"severity":"critical"},"disabled":false,"condition":{}},
     {"id":"r3","state":"inactive","alert":"Old rule","labels":{},"disabled":true,"condition":{}}]}}
    """#.utf8)

    guard let sv = try? Parse.traces(traces, windowSec: 900), let hs = try? Parse.hosts(hosts), let al = try? Parse.rules(rules) else {
        check(false, "parse threw"); return
    }
    check(sv.count == 2 && sv[0].name == "atlas-prod-app-server" && sv[0].service == "atlas" && sv[0].env == "production" && Int(sv[0].p99Ms) == 262
          && sv[1].numErrors == 1465 && Int(sv[1].errorPct.rounded()) == 6 && Int(sv[1].callRate.rounded()) == 27, "traces parse (one row per machine, p99 ns → ms, rate per s)")
    check(sv[0].id == "service:atlas@atlas-prod-app-server" && sv[0].path == "/services/atlas", "id and link")
    check(hs.count == 2 && Int(hs[0].cpuPct.rounded()) == 76 && Int(hs[0].memPct.rounded()) == 55 && hs[0].os == "linux" && !hs[1].active, "hosts parse (fractions → %)")
    check(al.count == 3 && al[0].firing && al[0].sev == .warn && al[1].state == "inactive" && al[2].state == "disabled", "rules parse")
    check(al[0].matches(sv[1]) && !al[0].matches(sv[0]), "rule matched to its service's machines by name")
    check(!al[0].matches(Server(kind: .service, name: "staging-1", service: "thrillophilia-partners", env: "staging")), "a production rule leaves staging machines alone")
    check((try? Parse.rules(traces)) == nil && (try? Parse.traces(rules)) == nil, "parsers reject the wrong shape")

    let t = Thresholds.load()
    check(t.errPct == 5 && t.p99Ms == 2000 && t.pollSec == 60, "limits come registered")
    check(health(sv[0], t, alerts: al).sev == .ok, "quiet service is green")
    let partners = health(sv[1], t, alerts: al)
    check(partners.sev == .bad && partners.why == "6.0% errors · p99 6.4 s", "errors over the limit are red, with both reasons")
    let quietPartners = Server(kind: .service, name: "box-9", service: "thrillophilia-partners", env: "production")
    check(health(quietPartners, t, alerts: al).why == "no traffic in 15 min · [Prod] Sidekiq job failures spiking", "a firing rule naming the service colours its machines orange")
    var warm = sv[0]; warm.errorPct = 4.2
    check(health(warm, t, alerts: []).sev == .warn, "80% of the error limit is orange")
    var idle = sv[0]; idle.numCalls = 0
    check(health(idle, t, alerts: []).why == "no traffic in 15 min", "no traffic is orange")
    check(health(hs[1], t, alerts: []).sev == .bad && health(hs[0], t, alerts: []).sev == .warn, "inactive host red, 76% CPU orange")

    let merged = merge(sv, known: ["service:atlas@atlas-prod-app-server", "service:atlas@atlas-prod-app-server-2", "host:old-box", "junk", "service:bare"])
    check(merged.count == 4 && merged[2].service == "atlas" && merged[2].name == "atlas-prod-app-server-2" && merged[2].missing
          && merged[3].kind == .host && merged[3].name == "old-box", "known servers missing from the poll are kept as missing")
    check(health(merged[3], t, alerts: []).sev == .bad, "missing server is red")

    let prom = Data(#"""
    {"status":"success","data":{"resultType":"vector","result":[{"metric":{"instance":"thrillophilia-admin-server","server":"admin-ui"},"value":[1793017000.1,"100.0"]},
     {"metric":{"instance":"thrillo-prod-redis-server","server":"redis"},"value":[1793017000.1,"3.4"]}]}}
    """#.utf8)
    guard let pv = try? Parse.prometheus(prom) else { check(false, "prometheus parse threw"); return }
    check(pv.count == 2 && pv[0].labels["server"] == "admin-ui" && pv[0].value == 100 && pv[1].value == 3.4, "prometheus vector parse (string values)")
    check((try? Parse.prometheus(rules)) == nil, "prometheus parser rejects the wrong shape")
    let one = { (v: Double) in [(labels: ["instance": "thrillophilia-admin-server", "server": "admin-ui"], value: v)] }
    let gh = mergeHosts(["cpu": pv, "mem": one(20), "disk": one(95), "load": one(2.06), "stale": one(400)], link: "https://g.example/d/infra-fleet")
    check(gh.count == 2 && gh[0].name == "thrillo-prod-redis-server" && gh[0].cpuPct == 3.4 && gh[0].diskPct == 0, "hosts merged per instance, sorted by name")
    let admin = gh[1]
    check(admin.os == "admin-ui · Grafana" && admin.memPct == 20 && admin.diskPct == 95 && admin.loadPerCore == 2.06 && admin.staleSec == 400
          && admin.id == "host:thrillophilia-admin-server" && admin.path == "https://g.example/d/infra-fleet", "merged host fields and link")
    check(health(admin, t, alerts: []).why == "no data for 6 min · CPU 100% · disk 95% full · load 2.1 per core", "stale, CPU, disk and load all red")
    var warmHost = gh[0]; warmHost.loadPerCore = 1.3; warmHost.diskPct = 75
    check(health(warmHost, t, alerts: []).why == "disk 75% full · load 1.3 per core", "80% of the disk and load limits is orange")
    check(Config(url: "https://s", key: "k").grafanaSet == false && Config(url: "https://s", key: "k", gURL: "https://g/", gKey: "t").gBase == "https://g", "grafana config")

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
