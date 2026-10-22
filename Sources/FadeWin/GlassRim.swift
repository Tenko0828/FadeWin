import AppKit
import CoreImage

/// 窗口的哪几条边是“真边”（没被屏幕边缘截掉）。只有真边才画圆角和玻璃边框
struct Edges: OptionSet, Equatable {
    let rawValue: Int
    static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    static let all: Edges = [.left, .right, .top, .bottom]
}

/// 透视模式下窗口边缘的“液态玻璃”：边缘一圈把后面的画面往里折（扭曲），
/// 红绿蓝三色折得不一样多（色散），再加一道左上来光的高光
enum GlassRim {
    /// 单位都是“点”，用的时候乘屏幕倍率
    static let cornerRadius: CGFloat = 22
    static let band: CGFloat = 16
    static let strength: CGFloat = 12
    static let spread: CGFloat = 0.35

    private static let kernel: CIKernel? = CIKernel(source: """
    kernel vec4 glassRim(sampler src, vec4 rect, float radius, float band, float strength, float spread) {
        vec2 p = destCoord();
        vec2 c = (rect.xy + rect.zw) * 0.5;
        vec2 hs = (rect.zw - rect.xy) * 0.5;
        vec2 rel = p - c;
        vec2 q = abs(rel) - (hs - vec2(radius));
        float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
        float t = clamp(1.0 + d / band, 0.0, 1.0);
        float inside = 1.0 - step(0.0, d);
        vec2 sg = sign(rel);
        vec2 n = vec2(0.0, sg.y);
        if (q.x > 0.0 && q.y > 0.0) { n = normalize(q) * sg; }
        else if (q.x > q.y) { n = vec2(sg.x, 0.0); }
        float k = t * t * strength;
        vec2 off = -n * k;
        float r = sample(src, samplerTransform(src, p + off * (1.0 + spread))).r;
        float g = sample(src, samplerTransform(src, p + off)).g;
        float b = sample(src, samplerTransform(src, p + off * (1.0 - spread))).b;
        vec3 col = vec3(r, g, b);
        float light = max(dot(n, normalize(vec2(-0.55, 0.83))), 0.0);
        float line = 1.0 - smoothstep(0.0, 2.5, abs(d + 1.5));
        col = min(col + vec3(t * t * t * light * 0.35 + line * (0.25 + 0.5 * light)), vec3(1.0));
        float a = smoothstep(0.0, 1.0, t) * inside;
        return vec4(col * a, a);
    }
    """)

    /// 不做色彩管理：边框和中间透出来的画面颜色要一模一样
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    static var available: Bool { kernel != nil }

    /// 把一帧“窗口后面”的画面加工成边框，画进 dest
    static func render(_ surface: IOSurface, scale: CGFloat, edges: Edges, into dest: IOSurface) -> Bool {
        guard let kernel else { return false }
        let src = CIImage(ioSurface: surface)
        let e = src.extent
        let pad = strength * scale * 2
        // 被屏幕截掉的边：把形状往外延伸到画面之外，那一侧就既没有圆角也没有边框（图像坐标 y 向上）
        let ext = (cornerRadius + band + strength * 2) * scale
        let rect = CIVector(x: edges.contains(.left) ? 0 : -ext,
                            y: edges.contains(.bottom) ? 0 : -ext,
                            z: edges.contains(.right) ? e.width : e.width + ext,
                            w: edges.contains(.top) ? e.height : e.height + ext)
        guard let out = kernel.apply(extent: e, roiCallback: { _, r in r.insetBy(dx: -pad, dy: -pad) },
                                     arguments: [src.clampedToExtent(), rect,
                                                 cornerRadius * scale, band * scale, strength * scale, spread]) else { return false }
        context.render(out, to: dest, bounds: e, colorSpace: nil)
        return true
    }

    static func makeSurface(width: Int, height: Int) -> IOSurface? {
        IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                               .pixelFormat: kCVPixelFormatType_32BGRA])
    }
}

/// 透视雾层的内容，从下到上：
/// 磨砂（模糊的是窗口自己的内容，挡住文字，保护隐私）→ “窗口后面”的实时画面 → 玻璃边框
final class SeeView: NSView {
    let frost = NSVisualEffectView()
    private let canvas = NSView()
    let base = CALayer()
    let rim = CALayer()

    var edges: Edges = .all {
        didSet {
            guard edges != oldValue else { return }
            applyCorners()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = GlassRim.cornerRadius
        layer?.masksToBounds = true

        frost.blendingMode = .behindWindow
        frost.material = .underWindowBackground
        frost.state = .active          // 雾层窗口永远不是活动窗口，不设成 active 就不会磨砂
        applyCorners()
        frost.alphaValue = 0
        frost.autoresizingMask = [.width, .height]
        addSubview(frost)

        canvas.wantsLayer = true
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
        for l in [base, rim] {
            l.contentsGravity = .resize
            // 关掉隐式动画：透明度和画面每帧都在变，自带的 0.25 秒过渡会让它一闪一闪
            l.actions = ["contents": NSNull(), "opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
            l.opacity = 0
            canvas.layer?.addSublayer(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        frost.frame = bounds
        canvas.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = canvas.bounds
        rim.frame = canvas.bounds
        CATransaction.commit()
    }

    /// 只有两条相邻边都是真边的角才是圆角；被屏幕截掉那一侧是直角
    private func applyCorners() {
        var m: CACornerMask = []
        if edges.contains(.left), edges.contains(.bottom) { m.insert(.layerMinXMinYCorner) }
        if edges.contains(.right), edges.contains(.bottom) { m.insert(.layerMaxXMinYCorner) }
        if edges.contains(.left), edges.contains(.top) { m.insert(.layerMinXMaxYCorner) }
        if edges.contains(.right), edges.contains(.top) { m.insert(.layerMaxXMaxYCorner) }
        layer?.maskedCorners = m
        frost.maskImage = Self.roundedMask(radius: GlassRim.cornerRadius, corners: m)
    }

    /// 可拉伸的圆角遮罩，让系统磨砂也跟着圆角走
    private static func roundedMask(radius: CGFloat, corners: CACornerMask) -> NSImage {
        let side = radius * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            NSColor.black.setFill()
            let p = NSBezierPath()
            func corner(_ c: CACornerMask) -> CGFloat { corners.contains(c) ? radius : 0 }
            let bl = corner(.layerMinXMinYCorner), br = corner(.layerMaxXMinYCorner)
            let tl = corner(.layerMinXMaxYCorner), tr = corner(.layerMaxXMaxYCorner)
            p.move(to: NSPoint(x: r.minX + bl, y: r.minY))
            p.line(to: NSPoint(x: r.maxX - br, y: r.minY))
            if br > 0 { p.appendArc(withCenter: NSPoint(x: r.maxX - br, y: r.minY + br), radius: br, startAngle: 270, endAngle: 360) }
            p.line(to: NSPoint(x: r.maxX, y: r.maxY - tr))
            if tr > 0 { p.appendArc(withCenter: NSPoint(x: r.maxX - tr, y: r.maxY - tr), radius: tr, startAngle: 0, endAngle: 90) }
            p.line(to: NSPoint(x: r.minX + tl, y: r.maxY))
            if tl > 0 { p.appendArc(withCenter: NSPoint(x: r.minX + tl, y: r.maxY - tl), radius: tl, startAngle: 90, endAngle: 180) }
            p.line(to: NSPoint(x: r.minX, y: r.minY + bl))
            if bl > 0 { p.appendArc(withCenter: NSPoint(x: r.minX + bl, y: r.minY + bl), radius: bl, startAngle: 180, endAngle: 270) }
            p.close()
            p.fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}
