import AppKit
import CoreAudio
import IOKit.pwr_mgt

/// 找出“正在播放视频”的 App，两路信号：
/// 1. 向系统申请“别让屏幕休眠”的（不少播放器和网页会申请，但不可靠：Chrome 在窗口被挡住时就撤销了）；
/// 2. 正在出声的（有声视频都会出声；顺带音乐播放器也不褪色）。
/// 静音视频靠 MotionWatch 看画面在不在动。
/// 浏览器的视频往往由辅助进程（如 WebKit GPU 进程）申请，所以要追溯到它所属的 App
enum VideoWatch {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    /// 系统私有函数：一个进程“归属”于哪个 App（XPC 辅助进程 → 浏览器本体）
    private static let responsible: ResponsibleFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleFn.self) }

    private static let displayTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    private static func owner(of pid: pid_t) -> pid_t {
        if let r = responsible?(pid), r > 0 { return r }
        return pid
    }

    /// 正在阻止屏幕休眠的 App 的进程号
    static func playingPids() -> Set<pid_t> {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let d = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var out = Set<pid_t>()
        for (k, list) in d {
            for a in list {
                guard let t = a["AssertType"] as? String, displayTypes.contains(t) else { continue }
                // 系统自己的申请（powerd 等）不算；我们自己也不算
                if let behalf = a["AssertionOnBehalfOfPID"] as? NSNumber { out.insert(owner(of: behalf.int32Value)) }
                out.insert(owner(of: k.int32Value))
            }
        }
        out.formUnion(audioPids())
        out.remove(me)
        return out
    }

    /// 正在往扬声器出声的 App（macOS 14.2+ 才有这个接口）。浏览器的声音由辅助进程发出，同样追溯回浏览器本体
    static func audioPids() -> Set<pid_t> {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var out = Set<pid_t>()
        for id in ids {
            var running: UInt32 = 0
            var pid: pid_t = 0
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var s = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &running) == noErr, running != 0 else { continue }
            a.mSelector = kAudioProcessPropertyPID
            s = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &pid) == noErr, pid > 0 else { continue }
            out.insert(owner(of: pid))
        }
        return out
    }
}
