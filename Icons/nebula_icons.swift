import Foundation
import CoreGraphics
import CoreText
import ImageIO

// Deterministic pseudo-random for reproducible star fields.
var seed: UInt64 = 42
func rnd() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat((seed >> 33) % 10000) / 10000.0
}

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func savePNG(_ ctx: CGContext, _ path: String) {
    let image = ctx.makeImage()!
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    return CGColor(srgbRed: r/255.0, green: g/255.0, blue: b/255.0, alpha: a)
}

// MARK: - Layers

// Styles: "deep" (original strong gradient), "flat" (solid color), "subtle" (gentle gradient).
let style = ProcessInfo.processInfo.environment["NEBULA_STYLE"] ?? "deep"

func drawBackground(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, withStars: Bool) {
    switch style {
    case "flat":
        // Solid indigo.
        ctx.setFillColor(color(68, 52, 126, 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    case "subtle":
        // Two close indigo tones, barely noticeable diagonal shift.
        let colors = [color(58, 44, 110, 1.0), color(78, 61, 144, 1.0)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    default:
        // Deep indigo vertical gradient (#1B1035 -> #4B3A8C).
        let colors = [color(27, 16, 53, 1.0), color(75, 58, 140, 1.0)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w * 0.3, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    if withStars {
        seed = 42
        let starAlphaScale: CGFloat = (style == "flat") ? 0.55 : 1.0
        for _ in 0..<150 {
            let x = rnd() * w
            let y = rnd() * h
            let radius = (0.4 + rnd() * 1.4) * (h / 240.0)
            let alpha = (0.25 + rnd() * 0.6) * starAlphaScale
            ctx.setFillColor(color(255, 255, 255, alpha))
            ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
    }
}

func drawNebula(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
    func blob(_ cx: CGFloat, _ cy: CGFloat, _ radius: CGFloat, _ c: CGColor) {
        let clear = c.copy(alpha: 0)!
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [c, clear] as CFArray, locations: [0.0, 1.0])!
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                               endCenter: CGPoint(x: cx, y: cy), endRadius: radius, options: [])
    }
    if style == "flat" {
        return // Flat look: no nebula glow at all.
    }
    let nebulaAlphaScale: CGFloat = (style == "subtle") ? 0.45 : 1.0
    blob(w * 0.30, h * 0.62, h * 0.55, color(176, 106, 224, 0.40 * nebulaAlphaScale)) // magenta-purple
    blob(w * 0.62, h * 0.35, h * 0.50, color(123, 79, 216, 0.38 * nebulaAlphaScale))  // purple
    blob(w * 0.74, h * 0.68, h * 0.42, color(79, 106, 216, 0.32 * nebulaAlphaScale))  // blue-purple
}

func drawPlanet(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat) {
    let tilt = CGFloat(-18.0 * .pi / 180.0)
    let ringWidth = r * 0.14
    let ringRX = r * 1.85
    let ringRY = r * 0.62

    func ringArc(_ fromAngle: CGFloat, _ toAngle: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: tilt)
        ctx.scaleBy(x: 1.0, y: ringRY / ringRX)
        ctx.setStrokeColor(color(255, 255, 255, 0.92))
        ctx.setLineWidth(ringWidth * (ringRX / ringRY) * 0.62)
        ctx.setLineCap(.round)
        ctx.addArc(center: .zero, radius: ringRX, startAngle: fromAngle, endAngle: toAngle, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Back half of the ring, then the planet, then the front half.
    ringArc(0, .pi)
    ctx.setFillColor(color(255, 255, 255, 1.0))
    ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    // Subtle crescent shade for depth.
    ctx.setFillColor(color(75, 58, 140, 0.22))
    ctx.fillEllipse(in: CGRect(x: cx - r * 0.92, y: cy - r * 1.08, width: r * 2, height: r * 2))
    ringArc(.pi, 2 * .pi)
}

func drawSparkles(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
    seed = 7
    for _ in 0..<6 {
        let x = w * (0.12 + rnd() * 0.76)
        let y = h * (0.12 + rnd() * 0.76)
        let s = (2.5 + rnd() * 3.5) * (h / 240.0)
        ctx.setStrokeColor(color(255, 255, 255, 0.85))
        ctx.setLineWidth(s * 0.28)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: x - s, y: y)); ctx.addLine(to: CGPoint(x: x + s, y: y))
        ctx.move(to: CGPoint(x: x, y: y - s)); ctx.addLine(to: CGPoint(x: x, y: y + s))
        ctx.strokePath()
    }
}

func makeLine(_ text: String, fontName: String, size: CGFloat, alpha: CGFloat, kern: CGFloat) -> CTLine {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(255, 255, 255, alpha),
        NSAttributedString.Key(kCTKernAttributeName as String): kern,
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
}

func drawText(_ ctx: CGContext, _ text: String, fontName: String, size: CGFloat,
              x: CGFloat, y: CGFloat, alpha: CGFloat, kern: CGFloat) {
    let line = makeLine(text, fontName: fontName, size: size, alpha: alpha, kern: kern)
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

func drawCenteredText(_ ctx: CGContext, _ text: String, fontName: String, size: CGFloat,
                      centerX: CGFloat, y: CGFloat, alpha: CGFloat, kern: CGFloat) {
    let line = makeLine(text, fontName: fontName, size: size, alpha: alpha, kern: kern)
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    ctx.textPosition = CGPoint(x: centerX - width / 2.0, y: y)
    CTLineDraw(line, ctx)
}

// MARK: - Outputs

let base = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
// NEBULA_ALTERNATES=1 skips the primary icon flow (see bottom of file).
let alternatesMode = ProcessInfo.processInfo.environment["NEBULA_ALTERNATES"] != nil

struct StackSpec { let dir: String; let w: Int; let h: Int; let prefix: String; let hasGlyph: Bool }

let stacks = [
    StackSpec(dir: "App Icon - Small.imagestack", w: 400, h: 240, prefix: "nebula", hasGlyph: true),
    StackSpec(dir: "App Icon - Large.imagestack", w: 1280, h: 768, prefix: "nebula", hasGlyph: false),
]

for spec in (alternatesMode ? [StackSpec]() : stacks) {
    for scale in [1, 2] {
        let w = spec.w * scale, h = spec.h * scale
        let cw = CGFloat(w), ch = CGFloat(h)
        let suffix = scale == 1 ? "" : "@2x"

        // Back: gradient + star field.
        var ctx = makeContext(w, h)
        drawBackground(ctx, cw, ch, withStars: true)
        savePNG(ctx, "\(base)/\(spec.dir)/Back.imagestacklayer/Content.imageset/\(spec.prefix)-back\(suffix).png")

        // Middle: nebula glow (transparent).
        ctx = makeContext(w, h)
        drawNebula(ctx, cw, ch)
        savePNG(ctx, "\(base)/\(spec.dir)/Middle.imagestacklayer/Content.imageset/\(spec.prefix)-middle\(suffix).png")

        // Front: planet + ring + "WEB BROWSER" caption (transparent). Sparkles go
        // here too when there is no dedicated Glyph layer.
        ctx = makeContext(w, h)
        if !spec.hasGlyph { drawSparkles(ctx, cw, ch) }
        drawPlanet(ctx, cx: cw * 0.5, cy: ch * 0.58, r: ch * 0.195)
        let captionSize = ch * 0.082
        drawCenteredText(ctx, "WEB BROWSER", fontName: "HelveticaNeue-Medium", size: captionSize,
                         centerX: cw * 0.5, y: ch * 0.175, alpha: 0.92, kern: captionSize * 0.38)
        savePNG(ctx, "\(base)/\(spec.dir)/Front.imagestacklayer/Content.imageset/\(spec.prefix)-front\(suffix).png")

        if spec.hasGlyph {
            ctx = makeContext(w, h)
            drawSparkles(ctx, cw, ch)
            savePNG(ctx, "\(base)/\(spec.dir)/Glyph.imagestacklayer/Content.imageset/\(spec.prefix)-glyph\(suffix).png")
        }
    }
}

// Top shelf banners.
struct ShelfSpec { let dir: String; let w: Int; let h: Int; let prefix: String }
let shelves = [
    ShelfSpec(dir: "Top Shelf Image.imageset", w: 1920, h: 720, prefix: "nebula-shelf"),
    ShelfSpec(dir: "Top Shelf Image Wide-1.imageset", w: 2320, h: 720, prefix: "nebula-shelf-wide"),
]

for spec in (alternatesMode ? [ShelfSpec]() : shelves) {
    for scale in [1, 2] {
        let w = spec.w * scale, h = spec.h * scale
        let cw = CGFloat(w), ch = CGFloat(h)
        let suffix = scale == 1 ? "" : "@2x"
        let ctx = makeContext(w, h)
        drawBackground(ctx, cw, ch, withStars: true)
        drawNebula(ctx, cw, ch)
        drawSparkles(ctx, cw, ch)
        let planetR = ch * 0.155
        drawPlanet(ctx, cx: cw * 0.355, cy: ch * 0.52, r: planetR)
        let titleSize = ch * 0.205
        drawText(ctx, "Nebula", fontName: "HelveticaNeue-Bold", size: titleSize,
                 x: cw * 0.45, y: ch * 0.47, alpha: 1.0, kern: titleSize * 0.02)
        drawText(ctx, "WEB BROWSER", fontName: "HelveticaNeue-Medium", size: titleSize * 0.30,
                 x: cw * 0.452, y: ch * 0.47 - titleSize * 0.52, alpha: 0.8, kern: titleSize * 0.12)
        savePNG(ctx, "\(base)/\(spec.dir)/\(spec.prefix)\(suffix).png")
    }
}
print("done")

// MARK: - Per-theme alternate icons (NEBULA_ALTERNATES=1)
// Generates one 400x240 imagestack per theme at the asset catalog root, named
// "AppIcon-<Theme>", for use with setAlternateIconName: and the
// ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES build setting.

if ProcessInfo.processInfo.environment["NEBULA_ALTERNATES"] != nil {
    // (name, accent RGB) — must match BrowserPreferencesStore's theme table.
    let themes: [(String, CGFloat, CGFloat, CGFloat)] = [
        ("Nebula", 123, 108, 222), ("Ocean", 10, 132, 255), ("Emerald", 48, 209, 88),
        ("Sunset", 255, 159, 10), ("Crimson", 255, 69, 58), ("Rose", 255, 45, 146),
        ("Sky", 100, 210, 255), ("Gold", 255, 214, 10), ("Lavender", 191, 90, 242),
    ]
    let fm = FileManager.default

    func writeJSON(_ path: String, _ contents: String) {
        try! contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    let layerListJSON = """
    {
      "layers" : [
        { "filename" : "Front.imagestacklayer" },
        { "filename" : "Middle.imagestacklayer" },
        { "filename" : "Back.imagestacklayer" }
      ],
      "info" : { "version" : 1, "author" : "xcode" }
    }
    """
    let infoOnlyJSON = "{ \"info\" : { \"version\" : 1, \"author\" : \"xcode\" } }"

    func imagesJSON(_ name: String) -> String {
        return """
        {
          "images" : [
            { "idiom" : "tv", "filename" : "\(name).png", "scale" : "1x" },
            { "idiom" : "tv", "filename" : "\(name)@2x.png", "scale" : "2x" }
          ],
          "info" : { "version" : 1, "author" : "xcode" }
        }
        """
    }

    for (name, tr, tg, tb) in themes {
        let stackDir = "\(base)/AppIcon-\(name).imagestack"
        for layer in ["Back", "Middle", "Front"] {
            try! fm.createDirectory(atPath: "\(stackDir)/\(layer).imagestacklayer/Content.imageset",
                                    withIntermediateDirectories: true)
            writeJSON("\(stackDir)/\(layer).imagestacklayer/Contents.json", infoOnlyJSON)
            writeJSON("\(stackDir)/\(layer).imagestacklayer/Content.imageset/Contents.json",
                      imagesJSON("icon-\(layer.lowercased())"))
        }
        writeJSON("\(stackDir)/Contents.json", layerListJSON)

        for scale in [1, 2] {
            let w = 400 * scale, h = 240 * scale
            let cw = CGFloat(w), ch = CGFloat(h)
            let suffix = scale == 1 ? "" : "@2x"

            // Back: flat, theme-tinted dark background + dim stars.
            var ctx = makeContext(w, h)
            ctx.setFillColor(color(max(tr * 0.30, 14), max(tg * 0.30, 12), max(tb * 0.30, 22), 1.0))
            ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
            seed = 42
            for _ in 0..<150 {
                let x = rnd() * cw, y = rnd() * ch
                let radius = (0.4 + rnd() * 1.4) * (ch / 240.0)
                let alpha = (0.25 + rnd() * 0.6) * 0.55
                ctx.setFillColor(color(255, 255, 255, alpha))
                ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
            savePNG(ctx, "\(stackDir)/Back.imagestacklayer/Content.imageset/icon-back\(suffix).png")

            // Middle: empty transparent layer (kept for parallax depth parity).
            ctx = makeContext(w, h)
            savePNG(ctx, "\(stackDir)/Middle.imagestacklayer/Content.imageset/icon-middle\(suffix).png")

            // Front: sparkles + planet + caption.
            ctx = makeContext(w, h)
            drawSparkles(ctx, cw, ch)
            drawPlanet(ctx, cx: cw * 0.5, cy: ch * 0.58, r: ch * 0.195)
            let captionSize = ch * 0.082
            drawCenteredText(ctx, "WEB BROWSER", fontName: "HelveticaNeue-Medium", size: captionSize,
                             centerX: cw * 0.5, y: ch * 0.175, alpha: 0.92, kern: captionSize * 0.38)
            savePNG(ctx, "\(stackDir)/Front.imagestacklayer/Content.imageset/icon-front\(suffix).png")
        }
        print("theme icon: AppIcon-\(name)")
    }

    // Flattened previews shown in the settings menu while cycling themes.
    func writePreview(_ name: String, bgR: CGFloat, bgG: CGFloat, bgB: CGFloat) {
        let dir = "\(base)/ThemePreview-\(name).imageset"
        try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        writeJSON("\(dir)/Contents.json", """
        {
          "images" : [
            { "idiom" : "tv", "filename" : "preview.png", "scale" : "1x" }
          ],
          "info" : { "version" : 1, "author" : "xcode" }
        }
        """)
        let w = 800, h = 480
        let cw = CGFloat(w), ch = CGFloat(h)
        let ctx = makeContext(w, h)
        ctx.setFillColor(color(bgR, bgG, bgB, 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        seed = 42
        for _ in 0..<150 {
            let x = rnd() * cw, y = rnd() * ch
            let radius = (0.4 + rnd() * 1.4) * (ch / 240.0)
            let alpha = (0.25 + rnd() * 0.6) * 0.55
            ctx.setFillColor(color(255, 255, 255, alpha))
            ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        drawSparkles(ctx, cw, ch)
        drawPlanet(ctx, cx: cw * 0.5, cy: ch * 0.58, r: ch * 0.195)
        let captionSize = ch * 0.082
        drawCenteredText(ctx, "WEB BROWSER", fontName: "HelveticaNeue-Medium", size: captionSize,
                         centerX: cw * 0.5, y: ch * 0.175, alpha: 0.92, kern: captionSize * 0.38)
        savePNG(ctx, "\(dir)/preview.png")
    }

    writePreview("Classic", bgR: 68, bgG: 52, bgB: 126) // primary icon's flat indigo
    for (name, tr, tg, tb) in themes {
        writePreview(name, bgR: max(tr * 0.30, 14), bgG: max(tg * 0.30, 12), bgB: max(tb * 0.30, 22))
    }
    print("alternates done")
    exit(0)
}
