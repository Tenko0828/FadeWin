import AppKit
import CoreMedia
import ScreenCaptureKit

/// 一个窗口的“动静探头”：以 64×40 的极低分辨率、每秒最多 2 帧抓这个窗口自己的画面（不含我们的雾层），
/// 大块区域在变就记一次“在动”
final class Probe: NSObject, SCStreamOutput, SCStreamDelegate {
    static let width = 64, height = 40
    private(set) var stream: SCStream!
    private var prev: [UInt8] = []
    /// 最近几次“在动”的时间，只在主线程读写
    var activeTimes: [CFTimeInterval] = []
    var onStop: (() -> Void)?

    init(filter: SCContentFilter, config: SCStreamConfiguration) {
        super.init()
        stream = SCStream(filter: filter, configuration: config, delegate: self)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        // 画面不变时系统根本不送帧，所以“在动”只能按时间窗口算，不能靠“没变的帧”来清零
        guard type == .screen, sb.isValid,
              let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = arr.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var luma = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * row + x * 4   // BGRA
                let r = Int(p[o + 2]) * 77, g = Int(p[o + 1]) * 150, b = Int(p[o]) * 29
                luma[y * w + x] = UInt8((r + g + b) >> 8)
            }
        }
        defer { prev = luma }
        guard prev.count == luma.count else { return }
        var changed = 0
        for i in 0..<luma.count where abs(Int(luma[i]) - Int(prev[i])) > 14 { changed += 1 }
        // 超过 12% 的面积在变才算：光标闪烁、转圈、聊天“正在输入”之类的小动静不算
        guard Double(changed) / Double(luma.count) > 0.12 else { return }
        let t = CACurrentMediaTime()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activeTimes.append(t)
            self.activeTimes.removeAll { t - $0 > 3 }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onStop?() }
    }
}

/// 找出“画面在持续变化”（多半是在放视频）的窗口。不管是哪个 App、网页，静音也能认出来。
/// 需要屏幕录制权限（透视外观本来就要）
@MainActor final class MotionWatch {
    static let maxProbes = 8

    private var probes: [CGWindowID: Probe] = [:]
    private var starting: Set<CGWindowID> = []
    private var content: SCShareableContent?
    private var contentDate = Date.distantPast
    private var refreshing = false
    private let queue = DispatchQueue(label: "local.tenko.fadewin.motion")

    /// 最近 2.5 秒里至少 3 次大块变化，就算在放视频
    func isMoving(_ id: CGWindowID) -> Bool {
        guard let p = probes[id] else { return false }
        let now = CACurrentMediaTime()
        return p.activeTimes.filter { now - $0 < 2.5 }.count >= 3
    }

    func stopAll() {
        for (_, p) in probes { Task { try? await p.stream.stopCapture() } }
        probes.removeAll()
    }

    /// candidates：要盯着的窗口（按前后顺序，前面的优先）
    func sync(candidates: [CGWindowID]) {
        let wanted = Set(candidates.prefix(Self.maxProbes))
        for id in probes.keys where !wanted.contains(id) {
            if let p = probes.removeValue(forKey: id) { Task { try? await p.stream.stopCapture() } }
        }
        let known = Set((content?.windows ?? []).map(\.windowID))
        if !wanted.isSubset(of: known) || Date().timeIntervalSince(contentDate) > 10 { refresh() }
        guard let content else { return }
        for id in candidates.prefix(Self.maxProbes) where probes[id] == nil && !starting.contains(id) {
            guard let win = content.windows.first(where: { $0.windowID == id }) else { continue }
            start(id: id, window: win)
        }
    }

    private func refresh() {
        guard !refreshing, Date().timeIntervalSince(contentDate) > 0.5 else { return }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false; contentDate = Date() }
            content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    private func start(id: CGWindowID, window: SCWindow) {
        let cfg = SCStreamConfiguration()
        cfg.width = Probe.width
        cfg.height = Probe.height
        cfg.scalesToFit = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.queueDepth = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        let probe = Probe(filter: SCContentFilter(desktopIndependentWindow: window), config: cfg)
        probe.onStop = { [weak self] in Task { @MainActor in self?.probes[id] = nil } }
        starting.insert(id)
        Task { @MainActor in
            defer { starting.remove(id) }
            do {
                try probe.stream.addStreamOutput(probe, type: .screen, sampleHandlerQueue: queue)
                try await probe.stream.startCapture()
                probes[id] = probe
            } catch {
                NSLog("FadeWin: 动静探头启动失败 \(error.localizedDescription)")
            }
        }
    }
}
