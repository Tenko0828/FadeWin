import AppKit
import IOKit.pwr_mgt

/// 找出“正在播放视频”的 App。
/// 播放视频的 App 和网页都会向系统申请“别让屏幕休眠”（播放音乐不会），这里读这些申请。
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
        out.remove(me)
        return out
    }
}
