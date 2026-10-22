import AppKit
import CoreImage

/// 透视模式下窗口边缘的“液态玻璃”：边缘一圈把后面的画面往里折（扭曲），
/// 红绿蓝三色折得不一样多（色散），再加一道左上来光的高光
enum GlassRim {
    /// 单位都是“点”，用的时候乘屏幕倍率
    static let cornerRadius: CGFloat = 22
    static let band: CGFloat = 16
    static let strength: CGFloat = 12
    static let spread: CGFloat = 0.35

    private static let kernel: CIKernel? = CIKernel(source: """
    kernel vec4 glassRim(sampler src, vec2 size, float radius, float band, float strength, float spread) {
        vec2 p = destCoord();
        vec2 c = size * 0.5;
        vec2 rel = p - c;
        vec2 q = abs(rel) - (c - vec2(radius));
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
    static func render(_ surface: IOSurface, scale: CGFloat, into dest: IOSurface) -> Bool {
        guard let kernel else { return false }
        let src = CIImage(ioSurface: surface)
        let e = src.extent
        let pad = strength * scale * 2
        guard let out = kernel.apply(extent: e, roiCallback: { _, r in r.insetBy(dx: -pad, dy: -pad) },
                                     arguments: [src.clampedToExtent(), CIVector(x: e.width, y: e.height),
                                                 cornerRadius * scale, band * scale, strength * scale, spread]) else { return false }
        context.render(out, to: dest, bounds: e, colorSpace: nil)
        return true
    }

    static func makeSurface(width: Int, height: Int) -> IOSurface? {
        IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                               .pixelFormat: kCVPixelFormatType_32BGRA])
    }
}

/// 透视雾层的内容：底层是“窗口后面”的实时画面，上层是玻璃边框
final class SeeView: NSView {
    let base = CALayer()
    let rim = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = GlassRim.cornerRadius
        layer?.masksToBounds = true
        for l in [base, rim] {
            l.contentsGravity = .resize
            l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            // 关掉隐式动画：透明度和画面每帧都在变，自带的 0.25 秒过渡会让它一闪一闪
            l.actions = ["contents": NSNull(), "opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
            l.opacity = 0
            layer?.addSublayer(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        rim.frame = bounds
        CATransaction.commit()
    }
}
