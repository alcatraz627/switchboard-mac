// Drives the agent-policy panel's real store headlessly against a fixture
// policy directory: every write the panel can make (set, snooze, cancel,
// reset, a repo override), read back through pol.sh. Also proves the panel
// strips the agent-shell markers, by running from a shell that carries them
// against a store pol.sh would otherwise refuse to write.
// Run: bash tests/fixtures/policy-probe.sh
import AppKit
import Foundation

var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("  ok    \(name)") } else { fail += 1; print("  FAIL  \(name) \(detail)") }
}

let env = ProcessInfo.processInfo.environment
let fakeHome = env["PROBE_HOME"]!
let repo = env["PROBE_REPO"]!

// pol.sh's default store under a throwaway HOME: the one it refuses to write
// from an agent shell. The probe itself runs with CLAUDECODE set.
PolicyCLI.extraEnv = ["HOME": fakeHome]
check("probe runs with an agent marker in its own env", env["CLAUDECODE"] != nil)

let store = PolicyStore()

/// Let the store's background write and reload land.
func settle(_ from: Date) {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        if store.busyKey == nil && store.pending.isEmpty && store.now > from { return }
    }
}
func item(_ k: String) -> PolicyItem? { store.items.first { $0.key == k } }

var t = Date(); store.reload(); settle(t)
check("store loads every registry entry", store.items.count > 15, "\(store.items.count)")
check("no load error", store.error == nil, store.error ?? "")

// A switch flip, as the Toggle binding makes it. The row shows the asked value
// at once, before pol.sh has answered.
t = Date(); store.set(item("slack.post")!, .text("block"))
check("the row shows the asked value before the save lands",
      store.pending["slack.post"]?.target == .text("block") && item("slack.post")?.value == .text("allow"))
settle(t)
check("toggle writes through pol.sh despite the agent marker", item("slack.post")?.value == .text("block"), store.error ?? "")
check("a confirmed change leaves nothing pending", store.pending["slack.post"] == nil)
check("written value reports source global", item("slack.post")?.source == "global")

// A segmented choice and a slider.
t = Date(); store.set(item("git.push_main")!, .text("allow")); settle(t)
check("segmented choice writes", item("git.push_main")?.value == .text("allow"))
t = Date(); store.set(item("ops.usage_gate_pct")!, .number(70)); settle(t)
check("slider writes a number", item("ops.usage_gate_pct")?.value == .number(70))

// An out-of-range value is refused by pol.sh and surfaces as an error.
t = Date(); store.set(item("ops.usage_gate_pct")!, .number(20)); settle(t)
check("out-of-range value refused", item("ops.usage_gate_pct")?.value == .number(70))
let refusal = store.failures["ops.usage_gate_pct"] ?? ""
check("refusal shown on that row", refusal.contains("invalid value"), refusal.isEmpty ? "nil" : refusal)
check("a row's refusal is not a load error", store.error == nil, store.error ?? "")
check("the refused row falls back to the stored value", store.pending["ops.usage_gate_pct"] == nil)
t = Date(); store.retry("ops.usage_gate_pct"); settle(t)
check("retry resends the same change and is refused again",
      (store.failures["ops.usage_gate_pct"] ?? "").contains("invalid value"))
store.failures["ops.usage_gate_pct"] = nil
check("dismiss clears the row's failure", store.failures.isEmpty)

// Snooze, then cancel.
t = Date(); store.snooze(item("github.comment")!, seconds: 3600, then: .text("block")); settle(t)
let z = item("github.comment")?.snooze
check("snooze recorded", z != nil && z!.then == .text("block") && !z!.expired)
check("snooze keeps the current value", item("github.comment")?.value == .text("allow"))
t = Date(); store.cancelSnooze(item("github.comment")!); settle(t)
check("cancel removes the snooze", item("github.comment")?.snooze == nil)

// The multi-day presets go out as "--for Nd"; the end time must land N days out.
for days in [2, 3] {
    t = Date(); store.snooze(item("github.comment")!, seconds: days * 86400, then: .text("block")); settle(t)
    let until = item("github.comment")?.snooze?.until.timeIntervalSinceNow ?? 0
    check("\(days)-day snooze ends \(days) days out", abs(until - Double(days * 86400)) < 120,
          "until in \(Int(until))s, \(store.error ?? "")")
    t = Date(); store.cancelSnooze(item("github.comment")!); settle(t)
}

// "At the end of today" snooze.
t = Date(); store.snoozeTonight(item("model.fable")!, then: .text("block")); settle(t)
check("end-of-today snooze recorded", item("model.fable")?.snooze != nil, store.error ?? "")

// Reset to default.
t = Date(); store.reset(item("slack.post")!); settle(t)
check("reset returns to the default", item("slack.post")?.value == .text("allow") && item("slack.post")?.source == "default")

// A repo override, set from the repo scope.
guard let root = PolicyCLI.root(of: repo) else { print("no repo root"); exit(1) }
store.scope = .project(root)
t = Date(); store.reload(); settle(t)
check("repo scope shows only per-repo policies", store.visibleItems.allSatisfy { $0.projectScoped })
check("repo scope hides global-only policies", !store.visibleItems.contains { $0.key == "slack.post" })
t = Date(); store.set(item("git.commit")!, .text("block")); settle(t)
check("repo override written", item("git.commit")?.source == "project" && item("git.commit")?.value == .text("block"))
store.scope = .global
t = Date(); store.reload(); settle(t)
check("global value untouched by the repo override", item("git.commit")?.value == .text("allow"))
check("scope list offers the overridden repo", store.scopes.contains(.project(root)))
store.scope = .project(root)
t = Date(); store.reload(); settle(t)
t = Date(); store.reset(item("git.commit")!); settle(t)
check("override reset falls back to Everywhere", item("git.commit")?.source != "project")

// An Everywhere snooze seen from a repo view is cancelled Everywhere (Codex P2).
store.scope = .global
t = Date(); store.reload(); settle(t)
t = Date(); store.snooze(item("git.push")!, seconds: 3600, then: .text("block")); settle(t)
store.scope = .project(root)
t = Date(); store.reload(); settle(t)
check("repo view shows the inherited snooze", item("git.push")?.snooze?.scope == "global")
t = Date(); store.cancelSnooze(item("git.push")!); settle(t)
store.scope = .global
t = Date(); store.reload(); settle(t)
check("cancelling it from the repo view removes the global snooze", item("git.push")?.snooze == nil)

// The dump used by --dump-policy renders every group.
store.scope = .global
t = Date(); store.reload(); settle(t)
let dump = policyDump(store)
check("dump names every group", ["Acting as you", "Code", "Deploy", "Models", "Machine", "Limits", "Gates"].allSatisfy { dump.contains("[\($0)]") })

// A failed read keeps the rows it already had; rows read for another scope are dropped instead.
let rowsBefore = store.items.count
store.applyLoaded((items: [], projects: [], error: "pol.sh timed out"), for: .global)
check("a failed read keeps the rows already shown", store.items.count == rowsBefore && rowsBefore > 0, "\(store.items.count) of \(rowsBefore)")
check("and says why beside them", store.error == "pol.sh timed out")
store.scope = .project(root)
store.applyLoaded((items: [], projects: [], error: "pol.sh timed out"), for: .project(root))
check("a failed read for another scope does not show the old scope's rows", store.items.isEmpty)
check("a clean read clears the error and the loading flag", {
    store.applyLoaded((items: [], projects: [], error: nil), for: .project(root))
    return store.error == nil && !store.loading && store.loadedScope == .project(root)
}())
check("a multi-line complaint reads as its first sentence",
      plainErrorText("key is read-only\n  usage: see the help\n", fallback: "x") == "key is read-only")

print("policy-probe: \(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
