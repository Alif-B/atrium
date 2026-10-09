import AppKit
import CoreAudio

/// Which apps are making sound or using the microphone right now, from Core Audio's public list of audio processes.
/// Apps often play through a helper process (Edge's audio service, Electron helpers), so each process is traced up
/// through its parents to the app that owns it. No permission needed.
@MainActor
enum AudioActivity {
    static func appsUsingAudio() -> Set<String> {
        var result: Set<String> = []
        for object in processObjects() {
            let pid: pid_t = property(object, kAudioProcessPropertyPID, 0)
            let output: UInt32 = property(object, kAudioProcessPropertyIsRunningOutput, 0)
            let input: UInt32 = property(object, kAudioProcessPropertyIsRunningInput, 0)
            guard pid > 0, output != 0 || input != 0, let id = owningApp(of: pid) else { continue }
            result.insert(id)
        }
        return result
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func property<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ fallback: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) { buffer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!) == noErr
        } ? value : fallback
    }

    /// The regular app a process belongs to: itself, or the nearest app among its parents.
    private static func owningApp(of pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<8 where current > 1 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular,
               let id = app.bundleIdentifier { return id }
            var info = proc_bsdinfo()
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
            current = pid_t(info.pbi_ppid)
        }
        return nil
    }
}
