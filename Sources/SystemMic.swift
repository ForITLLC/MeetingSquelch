// SystemMic.swift: the default input device's own mute, for presses with no call.
// Uses kAudioDevicePropertyMute (input scope, main element, then element 1). A device without a
// settable mute is muted by setting its input volume to 0; the old volume is kept per device UID
// in UserDefaults and put back on unmute. A device with neither (the RØDE Wireless MICRO) cannot
// be muted here, and the HUD says so.
//
// SoundSource (Rogue Amoeba) has no AppleScript or URL scheme; its only outside door is App Intents,
// which run through Shortcuts. Its mic mute is this same switch: Rogue Amoeba's 6.x release notes
// say a mic without a hardware mute cannot be muted in SoundSource either, and "force software
// volume control" exists for outputs only. So with SoundSource running a press flips the switch
// SoundSource shows, and without it the press is macOS's own mute. SoundSource's per-device Mute
// lock puts the switch back; AppDelegate checks for that after the press.
import AppKit
import CoreAudio

func caAddr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
            _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: el)
}

func caU32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32? {
    var a = caAddr(s); var v: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &v) == noErr ? v : nil
}

func caString(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = caAddr(s)
    var cf: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(o, &a, 0, nil, &sz, $0) }
    guard st == noErr, let cf = cf else { return "" }
    return cf.takeRetainedValue() as String
}

struct MicResult {
    let name: String
    let ok: Bool
    let muted: Bool? // nil = the device has no mute and no input volume
}

enum SystemMic {
    static let scope = kAudioDevicePropertyScopeInput
    static let fallbackVolume: Float32 = 0.8

    static func defaultInput() -> AudioDeviceID? {
        var a = caAddr(kAudioHardwarePropertyDefaultInputDevice)
        var d = AudioDeviceID(0); var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &d) == noErr,
              d != kAudioObjectUnknown else { return nil }
        return d
    }

    static func name(_ d: AudioDeviceID) -> String { caString(d, kAudioObjectPropertyName) }
    static func uid(_ d: AudioDeviceID) -> String { caString(d, kAudioDevicePropertyDeviceUID) }

    private static func settable(_ d: AudioDeviceID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        guard AudioObjectHasProperty(d, &a) else { return false }
        var s: DarwinBoolean = false
        return AudioObjectIsPropertySettable(d, &a, &s) == noErr && s.boolValue
    }

    private static func muteAddr(_ d: AudioDeviceID) -> AudioObjectPropertyAddress? {
        for el in [kAudioObjectPropertyElementMain, 1] {
            let a = caAddr(kAudioDevicePropertyMute, scope, el)
            if settable(d, a) { return a }
        }
        return nil
    }

    private static func volumeAddrs(_ d: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        let main = caAddr(kAudioDevicePropertyVolumeScalar, scope, kAudioObjectPropertyElementMain)
        if settable(d, main) { return [main] }
        return (1...8).map { caAddr(kAudioDevicePropertyVolumeScalar, scope, $0) }.filter { settable(d, $0) }
    }

    private static func volume(_ d: AudioDeviceID, _ a: AudioObjectPropertyAddress) -> Float32? {
        var a = a; var v: Float32 = 0; var sz = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &v) == noErr, v.isFinite else { return nil }
        return v
    }

    private static func setVolume(_ d: AudioDeviceID, _ addrs: [AudioObjectPropertyAddress], _ v: Float32) -> Bool {
        var ok = true
        for a in addrs {
            var a = a; var v = v
            ok = AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr && ok
        }
        return ok
    }

    static func isMuted(_ d: AudioDeviceID) -> Bool? {
        if var a = muteAddr(d) {
            var v: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &v) == noErr ? v != 0 : nil
        }
        let vs = volumeAddrs(d).compactMap { volume(d, $0) }
        if vs.isEmpty { return nil }
        return vs.allSatisfy { $0 <= 0.0001 }
    }

    static func setMuted(_ d: AudioDeviceID, _ mute: Bool) -> Bool {
        if var a = muteAddr(d) {
            var v: UInt32 = mute ? 1 : 0
            return AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
        }
        let addrs = volumeAddrs(d)
        if addrs.isEmpty { return false }
        let key = "savedVolume." + uid(d)
        if mute {
            let cur = addrs.compactMap { volume(d, $0) }.max() ?? 0
            if cur > 0 { UserDefaults.standard.set(cur, forKey: key) }
            return setVolume(d, addrs, 0)
        }
        let saved = UserDefaults.standard.object(forKey: key) as? Float32 ?? fallbackVolume
        return setVolume(d, addrs, saved > 0 ? saved : fallbackVolume)
    }

    static func toggle() -> MicResult {
        guard let d = defaultInput() else { return MicResult(name: "no microphone", ok: false, muted: nil) }
        let n = name(d)
        guard let cur = isMuted(d) else { return MicResult(name: n, ok: false, muted: nil) }
        let ok = setMuted(d, !cur)
        return MicResult(name: n, ok: ok, muted: isMuted(d))
    }

    // In a call the app owns the mute, so a system-muted mic is put back to live first.
    static func releaseForCall() {
        guard let d = defaultInput(), isMuted(d) == true else { return }
        if setMuted(d, false) { Log.i("system mic \(name(d)) unmuted: the call app owns the mute") }
    }

    static func state() -> (name: String, muted: Bool?) {
        guard let d = defaultInput() else { return ("no microphone", nil) }
        return (name(d), isMuted(d))
    }
}

enum SoundSource {
    static let bundleID = "com.rogueamoeba.soundsource"
    static var running: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }
}

// Calls onChange (on the main queue) when the default mic changes, or its mute or volume does,
// whoever changed it (SoundSource, Control Center, another app), so the menu bar icon follows.
final class MicStateWatcher {
    var onChange: (() -> Void)?
    private var device = AudioDeviceID(0)
    private var attached: [AudioObjectPropertyAddress] = []
    private lazy var block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }

    func start() {
        var a = caAddr(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
            self?.attach()
            self?.onChange?()
        }
        attach()
    }

    private func attach() {
        for a in attached { var a = a; AudioObjectRemovePropertyListenerBlock(device, &a, .main, block) }
        attached = []
        guard let d = SystemMic.defaultInput() else { return }
        device = d
        let props: [(AudioObjectPropertySelector, AudioObjectPropertyElement)] = [
            (kAudioDevicePropertyMute, kAudioObjectPropertyElementMain), (kAudioDevicePropertyMute, 1),
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain), (kAudioDevicePropertyVolumeScalar, 1),
        ]
        for (sel, el) in props {
            var a = caAddr(sel, SystemMic.scope, el)
            guard AudioObjectHasProperty(d, &a), AudioObjectAddPropertyListenerBlock(d, &a, .main, block) == noErr
            else { continue }
            attached.append(a)
        }
    }
}
