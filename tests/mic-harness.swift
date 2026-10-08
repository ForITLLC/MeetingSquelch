// mic-harness.swift: checks which mic Squelch names (Sources/MicPick.swift) with a real setup as data,
// then reads, without changing anything, which input each recording process uses right now
// (MicWatcher.inputs). It never mutes, never presses and never sets a device. Run on any Mac:
//   tests/mic-harness.sh        (exit 0 = every check passed)
import CoreAudio
import Foundation

var failed = 0
var passed = 0
func check(_ ok: Bool, _ what: String) {
    if ok { passed += 1; print("ok   \(what)") } else { failed += 1; print("FAIL \(what)") }
}

// A MacBook on 2026-10-06: Teams' helper records the Jabra, Monologue (dictation) records the RØDE,
// SoundSource's daemon records but names no device, so Core Audio lists no use for it.
let jabra = UInt32(151), rode = UInt32(155), builtIn = UInt32(89)
let teamsOnJabra = MicUse(bundleID: "com.microsoft.teams2.modulehost", device: jabra, name: "Jabra Speak 710")
let dictation = MicUse(bundleID: "com.zeitalabs.jottleai", device: rode, name: "Wireless MICRO")
let ben = [teamsOnJabra, dictation]

check(MicPick.callInputs("Teams", ben) == [teamsOnJabra], "Teams call: only Teams' own input, not the dictation mic")
check(MicPick.label(MicPick.callInputs("Teams", ben)) == "Jabra Speak 710", "Teams call is named Jabra Speak 710")
let switched = [MicUse(bundleID: "com.microsoft.teams2.modulehost", device: rode, name: "Wireless MICRO"), dictation]
check(MicPick.label(MicPick.callInputs("Teams", switched)) == "Wireless MICRO", "Teams switched to the RØDE mid-call: named so")
check(MicPick.callInputs("Zoom", ben).isEmpty, "Zoom call with no Zoom process recording: no device named")
check(MicPick.label([]) == nil, "nothing recording: no label")

let edge = MicUse(bundleID: "com.microsoft.edgemac.helper", device: builtIn, name: "MacBook Pro Microphone")
check(MicPick.callInputs("Meet", [teamsOnJabra, edge]) == [edge], "Meet in Edge: Edge's helper, not the Teams app")
check(MicPick.callInputs("Teams web", [teamsOnJabra, edge]) == [edge], "Teams in a browser tab: the browser, not the Teams app")
check(MicPick.callInputs("Teams", [teamsOnJabra, edge]) == [teamsOnJabra], "Teams app: not the browser")

let twice = [teamsOnJabra, MicUse(bundleID: "com.microsoft.teams2", device: jabra, name: "Jabra Speak 710")]
check(MicPick.callInputs("Teams", twice).count == 1, "two Teams processes on one mic: named once")
let two = [teamsOnJabra, MicUse(bundleID: "com.microsoft.teams2", device: rode, name: "Wireless MICRO")]
check(MicPick.label(MicPick.callInputs("Teams", two)) == "Jabra Speak 710 + Wireless MICRO", "a call on two mics names both")

check(MicPick.callInputs("Zoom", [MicUse(bundleID: "us.zoom.xos", device: jabra, name: "Jabra Speak 710")]).count == 1, "Zoom's own process counts")
check(MicPick.callInputs("Slack", [MicUse(bundleID: "com.tinyspeck.slackmacgap.helper", device: jabra, name: "Jabra Speak 710")]).count == 1,
      "Slack's helper counts")
check(MicPick.callInputs("Discord", ben).isEmpty, "Discord call never takes another app's mic")

check(MicPick.short("Jabra Speak 710") == "Jabra Speak 710", "short name keeps Jabra Speak 710 whole")
check(MicPick.short("Wireless MICRO") == "Wireless MICRO", "short name keeps Wireless MICRO whole")
let long = MicPick.short("MacBook Pro Microphone")
check(long.count <= 18 && long.hasSuffix("…") && long.hasPrefix("MacBook Pro"), "long names are cut for the menu bar (\(long))")

// Live and read-only: what each recording process on this Mac uses right now.
let watcher = MicWatcher()
watcher.start()
let live = MicWatcher.inputs(watcher.objects)
print("live: \(watcher.objects.count) process(es) recording")
for u in live { print("live: \(u.bundleID.isEmpty ? "(no-bundle)" : u.bundleID) -> \(u.name) (device \(u.device))") }
check(live.allSatisfy { $0.device != 0 && !$0.name.isEmpty }, "every live input has a device and a name")
check(Set(live.map { $0.bundleID }).isSubset(of: Set(watcher.objects.values)), "live inputs come only from recording processes")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
