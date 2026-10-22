import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let fader = Fader()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.statusIcon()
        statusItem.button?.toolTip = "窗口褪色"
        menu.delegate = self
        statusItem.menu = menu
        fader.start()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("暂停褪色", #selector(togglePause), on: fader.paused))

        let speedItem = NSMenuItem(title: "褪色速度", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in FadeSpeed.allCases {
            let mi = item(s.title, #selector(pickSpeed(_:)), on: fader.speed == s)
            mi.representedObject = s.rawValue
            sub.addItem(mi)
        }
        speedItem.submenu = sub
        menu.addItem(speedItem)

        do {
            let styleItem = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
            let sm = NSMenu()
            for st in FadeStyle.allCases where st != .glass || FadeStyle.glassAvailable {
                let mi = item(st.title, #selector(pickStyle(_:)), on: fader.style == st)
                mi.representedObject = st.rawValue
                sm.addItem(mi)
            }
            if fader.style == .seeThrough, !SeeThrough.hasPermission {
                sm.addItem(.separator())
                sm.addItem(item("还没授权屏幕录制，现在用玻璃顶着 · 去授权…", #selector(openScreenCaptureSettings)))
            }
            styleItem.submenu = sm
            menu.addItem(styleItem)
            if fader.style == .seeThrough {
                menu.addItem(item("透视时加隐私薄雾（看不清窗口上的字）", #selector(togglePrivacy), on: fader.privacyFrost))
            }
        }

        addExemptionItems(to: menu)

        // 被遗忘最久的窗口，点一下把它的 App 叫回前台
        let forgotten = fader.snapshot
            .map { ($0, fader.idleSeconds(of: $0.id)) }
            .filter { $0.1 >= 300 }
            .sorted { $0.1 > $1.1 }
        menu.addItem(.separator())
        let header = NSMenuItem(title: forgotten.isEmpty ? "没有被遗忘的窗口" : "被遗忘的窗口", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (w, idle) in forgotten.prefix(12) {
            let name = w.title.isEmpty ? w.owner : "\(w.owner) · \(w.title.prefix(24))"
            let mi = item("\(name)　\(Self.format(idle))", #selector(bringBack(_:)))
            mi.representedObject = Int(w.pid)
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        menu.addItem(item("开机时启动", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(item("退出", #selector(quit), key: "q"))
    }

    private static func format(_ s: Double) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : "\(m) 分钟"
    }

    private func item(_ title: String, _ sel: Selector, key: String = "", on: Bool = false) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        mi.state = on ? .on : .off
        return mi
    }

    @objc private func togglePause() { fader.paused.toggle() }

    @objc private func pickSpeed(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let s = FadeSpeed(rawValue: raw) { fader.speed = s }
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = FadeStyle(rawValue: raw) else { return }
        fader.style = st
        if st == .seeThrough, !SeeThrough.hasPermission { openScreenCaptureSettings() }
    }

    @objc private func togglePrivacy() { fader.privacyFrost.toggle() }

    @objc private func openScreenCaptureSettings() {
        _ = CGRequestScreenCaptureAccess()   // 让系统把 FadeWin 加进“屏幕录制”列表
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func bringBack(_ sender: NSMenuItem) {
        if let pid = sender.representedObject as? Int {
            NSRunningApplication(processIdentifier: pid_t(pid))?.activate(options: [.activateAllWindows])
        }
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "没能设置开机启动"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// 菜单栏图标：三块越来越淡的窗口
    static func statusIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            for (i, a) in [1.0, 0.55, 0.25].enumerated() {
                let r = NSRect(x: 2 + CGFloat(i) * 3.2, y: 2 + CGFloat(i) * 3.2, width: 9, height: 8)
                NSColor.black.withAlphaComponent(a).setFill()
                NSBezierPath(roundedRect: r, xRadius: 1.8, yRadius: 1.8).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - 不褪色的窗口和 App

extension AppDelegate {
    func addExemptionItems(to menu: NSMenu) {
        menu.addItem(.separator())

        // 正在放视频的 App：自动不褪色，这里只是告诉用户
        let playing = Set(fader.snapshot.filter { fader.videoPids.contains($0.pid) }.map(\.owner)).sorted()
        if !playing.isEmpty {
            let mi = NSMenuItem(title: "正在播放视频，暂不褪色：\(playing.joined(separator: "、"))", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
        }

        if let w = fader.frontWindow, let bid = fader.bundleID(of: w.pid) {
            let mi = item("「\(w.owner)」永不褪色", #selector(toggleExemptApp(_:)), on: fader.exemptApps.contains(bid))
            mi.representedObject = bid
            menu.addItem(mi)
        }

        // 已锁定的窗口和永不褪色的 App，点一下取消
        let locked = fader.snapshot.filter { fader.isLocked($0.id) }
        let apps = fader.exemptApps.sorted()
        guard !locked.isEmpty || !apps.isEmpty else { return }
        let listItem = NSMenuItem(title: "不褪色的窗口和 App（\(locked.count + apps.count)）", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for w in locked {
            let name = w.title.isEmpty ? w.owner : "\(w.owner) · \(w.title.prefix(24))"
            let mi = item("🔒 \(name)　点击解锁", #selector(unlockWindow(_:)))
            mi.representedObject = Int(w.id)
            sub.addItem(mi)
        }
        if !locked.isEmpty, !apps.isEmpty { sub.addItem(.separator()) }
        for bid in apps {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bid
            let mi = item("「\(name)」永不褪色　点击取消", #selector(toggleExemptApp(_:)))
            mi.representedObject = bid
            sub.addItem(mi)
        }
        listItem.submenu = sub
        menu.addItem(listItem)
    }

    @objc func toggleExemptApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        var apps = fader.exemptApps
        if apps.remove(bid) == nil { apps.insert(bid) }
        fader.exemptApps = apps
    }

    @objc func unlockWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int else { return }
        fader.toggleLock(CGWindowID(id))
    }
}

/// 构建脚本用：把 App 图标渲染成 PNG
@MainActor func renderIcon(to path: String) {
    let view = ZStack {
        RoundedRectangle(cornerRadius: 185, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 0.95), Color(red: 0.55, green: 0.38, blue: 0.9)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
        ForEach(0..<3, id: \.self) { i in
            RoundedRectangle(cornerRadius: 46, style: .continuous)
                .fill(Color.white.opacity([0.95, 0.55, 0.28][i]))
                .frame(width: 440, height: 360)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.black.opacity(0.18)).frame(width: 26, height: 26) }
                    }.padding(26)
                }
                .offset(x: CGFloat(i - 1) * 120, y: CGFloat(i - 1) * 100)
        }
    }
    .frame(width: 1024, height: 1024)
    .scaleEffect(824.0 / 1024)
    .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
    .frame(width: 1024, height: 1024)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let cg = renderer.cgImage else { return }
    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { renderIcon(to: CommandLine.arguments[i + 1]) }
    exit(0)
}

/// 排查用：列出被认定为“正在播放视频”的 App
if CommandLine.arguments.contains("--list-video") {
    for pid in VideoWatch.playingPids().sorted() {
        let app = NSRunningApplication(processIdentifier: pid)
        print(pid, app?.localizedName ?? "-", app?.bundleIdentifier ?? "-")
    }
    exit(0)
}

if CommandLine.arguments.contains("--check-permission") {
    print("screen capture permission:", SeeThrough.hasPermission)
    exit(0)
}

if CommandLine.arguments.contains("--enable-login-item") {
    do {
        if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        print("login item:", SMAppService.mainApp.status == .enabled ? "enabled" : "status \(SMAppService.mainApp.status.rawValue)")
        exit(0)
    } catch {
        print("login item failed:", error.localizedDescription)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
