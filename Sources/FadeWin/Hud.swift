import AppKit

final class Hud {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        // 提示不抢焦点，也要保持毛玻璃效果
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        effect.addSubview(label)
        panel.contentView = effect
    }

    func show(_ message: String) {
        // 鼠标所在屏幕也是菜单点击所在的屏幕，多屏时提示不会跑到另一边
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        timer?.invalidate()
        label.stringValue = message
        label.sizeToFit()
        let visible = screen.visibleFrame
        let width = min(max(label.frame.width + 40, 180), max(visible.width - 32, 1))
        let height: CGFloat = 48
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.maxY - height - 28,
                              width: width, height: height), display: false)
        label.frame = NSRect(x: 20, y: (height - label.frame.height) / 2,
                             width: max(width - 40, 1), height: label.frame.height)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let fadeAt = Date().addingTimeInterval(1.2)
        // 用同一个计时器控制淡出，连续操作时取消它就不会有旧动画把新提示藏起来
        let timer = Timer(fire: fadeAt, interval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.panel.alphaValue = max(0, 1 - Date().timeIntervalSince(fadeAt) / 0.2)
            if self.panel.alphaValue <= 0 {
                self.panel.orderOut(nil)
                timer.invalidate()
                self.timer = nil
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { timer?.invalidate() }
}
