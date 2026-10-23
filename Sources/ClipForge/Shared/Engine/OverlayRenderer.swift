import CoreImage
import CoreText
#if canImport(AppKit)
import AppKit
private typealias PlatformFont = NSFont
#else
import UIKit
private typealias PlatformFont = UIFont
#endif

/// Draws the activity-data panel (metric tiles + optional graph) for one frame.
final class OverlayRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: CGImage] = [:]
    private var cacheOrder: [String] = []

    struct Tile {
        var label: String
        var value: String
        var unit: String
        var accent: CGColor
    }

    func overlay(for snapshot: RenderSnapshot, sourceTime: Double, frame: CGRect) -> CIImage? {
        let settings = snapshot.overlay
        guard settings.enabled, let activity = snapshot.activity, let videoStart = snapshot.videoStartDate else { return nil }
        let date = videoStart.addingTimeInterval(sourceTime + settings.timeOffset)

        let metrics = OverlayMetric.allCases.filter { settings.metrics.contains($0) && activity.availableMetrics.contains($0) }
        let tiles = metrics.map { tile(for: $0, value: activity.value($0, at: date), units: settings.units) }

        let graphMetric = settings.showGraph && activity.availableMetrics.contains(settings.graphMetric) && settings.graphMetric.isGraphable
            ? settings.graphMetric : nil
        guard !tiles.isEmpty || graphMetric != nil else { return nil }

        let base = min(frame.width, frame.height) * 0.055 * settings.scale
        let graphWidth = (base * 7).rounded()
        // The graph spans the whole source clip; the marker position is quantized to whole pixels for caching.
        let windowStart = videoStart.addingTimeInterval(settings.timeOffset)
        let windowLength = max(snapshot.sourceDuration, 1)
        let markerX = Int((sourceTime / windowLength * Double(graphWidth)).rounded())

        let key = [
            tiles.map { $0.value }.joined(separator: "|"),
            "\(Int(frame.width))x\(Int(frame.height))", "\(graphMetric?.rawValue ?? "-")", "\(markerX)",
            "\(settings.scale)", "\(settings.layout)", "\(settings.textColor)", "\(settings.backgroundOpacity)",
            "\(settings.units)", "\(settings.timeOffset)", "\(snapshot.videoStartDate?.timeIntervalSince1970 ?? 0)",
            activity.fileName,
        ].joined(separator: "#")

        let panel: CGImage
        if let cached = cachedImage(key) {
            panel = cached
        } else {
            guard let drawn = drawPanel(
                tiles: tiles, base: base, settings: settings,
                graph: graphMetric.map { (metric: $0, activity: activity, start: windowStart, length: windowLength, markerX: CGFloat(markerX), width: graphWidth) }
            ) else { return nil }
            store(drawn, key: key)
            panel = drawn
        }

        let margin = min(frame.width, frame.height) * 0.04
        let w = CGFloat(panel.width), h = CGFloat(panel.height)
        let x: CGFloat
        let y: CGFloat
        switch settings.position {
        case .topLeft: x = margin; y = frame.maxY - margin - h
        case .topRight: x = frame.maxX - margin - w; y = frame.maxY - margin - h
        case .bottomLeft: x = margin; y = margin
        case .bottomRight: x = frame.maxX - margin - w; y = margin
        }
        return CIImage(cgImage: panel).transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
    }

    // MARK: - Values

    private func tile(for metric: OverlayMetric, value: Double?, units: UnitSystem) -> Tile {
        let metricUnits = units == .metric
        let dash = "--"
        switch metric {
        case .heartRate:
            return Tile(label: metric.overlayLabel, value: value.map { String(Int($0.rounded())) } ?? dash, unit: "bpm",
                        accent: CGColor(red: 1, green: 0.27, blue: 0.33, alpha: 1))
        case .pace:
            let perUnit = metricUnits ? 1000.0 : 1609.344
            var text = dash
            if let v = value, v > 0.3 {
                let secs = Int((perUnit / v).rounded())
                text = secs >= 3600 ? dash : String(format: "%d:%02d", secs / 60, secs % 60)
            }
            return Tile(label: metric.overlayLabel, value: text, unit: metricUnits ? "/km" : "/mi",
                        accent: CGColor(red: 0.2, green: 0.85, blue: 0.45, alpha: 1))
        case .speed:
            let v = value.map { $0 * (metricUnits ? 3.6 : 2.236936) }
            return Tile(label: metric.overlayLabel, value: v.map { String(format: "%.1f", $0) } ?? dash, unit: metricUnits ? "km/h" : "mph",
                        accent: CGColor(red: 0.2, green: 0.85, blue: 0.45, alpha: 1))
        case .depth:
            let v = value.map { metricUnits ? $0 : $0 * 3.28084 }
            return Tile(label: metric.overlayLabel, value: v.map { String(format: metricUnits ? "%.1f" : "%.0f", $0) } ?? dash, unit: metricUnits ? "m" : "ft",
                        accent: CGColor(red: 0.25, green: 0.6, blue: 1, alpha: 1))
        case .distance:
            let v = value.map { $0 / (metricUnits ? 1000 : 1609.344) }
            return Tile(label: metric.overlayLabel, value: v.map { String(format: "%.2f", $0) } ?? dash, unit: metricUnits ? "km" : "mi",
                        accent: CGColor(red: 1, green: 0.75, blue: 0.2, alpha: 1))
        case .temperature:
            let v = value.map { metricUnits ? $0 : $0 * 9 / 5 + 32 }
            return Tile(label: metric.overlayLabel, value: v.map { String(format: "%.0f", $0) } ?? dash, unit: metricUnits ? "°C" : "°F",
                        accent: CGColor(red: 1, green: 0.55, blue: 0.2, alpha: 1))
        case .altitude:
            let v = value.map { metricUnits ? $0 : $0 * 3.28084 }
            return Tile(label: metric.overlayLabel, value: v.map { String(format: "%.0f", $0) } ?? dash, unit: metricUnits ? "m" : "ft",
                        accent: CGColor(red: 0.7, green: 0.5, blue: 1, alpha: 1))
        case .elapsed:
            return Tile(label: metric.overlayLabel, value: value.map { formatTimecode($0, fractional: false) } ?? dash, unit: "",
                        accent: CGColor(gray: 0.85, alpha: 1))
        }
    }

    // MARK: - Drawing

    private func font(_ size: CGFloat, _ weight: PlatformFont.Weight) -> CTFont {
        let font = PlatformFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        #if canImport(AppKit)
        let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) }
        #else
        let rounded = font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) }
        #endif
        return (rounded ?? font) as CTFont
    }

    private func line(_ text: String, _ font: CTFont, _ color: CGColor) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    private func width(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private typealias GraphSpec = (metric: OverlayMetric, activity: FITActivity, start: Date, length: Double, markerX: CGFloat, width: CGFloat)

    private func drawPanel(tiles: [Tile], base: CGFloat, settings: OverlaySettings, graph: GraphSpec?) -> CGImage? {
        let c = settings.textColor
        let textColor = CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
        let labelColor = CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * 0.75)
        let valueFont = font(base, .bold)
        let unitFont = font(base * 0.45, .semibold)
        let labelFont = font(base * 0.32, .semibold)
        let pad = base * 0.45
        let gap = base * 0.35
        let barWidth = max(2, base * 0.08)

        struct Laid { var label: CTLine; var value: CTLine; var unit: CTLine; var accent: CGColor; var size: CGSize }
        let laid: [Laid] = tiles.map { t in
            let l = line(t.label, labelFont, labelColor)
            let v = line(t.value, valueFont, textColor)
            let u = line(t.unit, unitFont, labelColor)
            let w = max(self.width(l), self.width(v) + (t.unit.isEmpty ? 0 : base * 0.15 + self.width(u))) + barWidth + base * 0.3
            return Laid(label: l, value: v, unit: u, accent: t.accent, size: CGSize(width: w, height: base * 1.5))
        }

        let graphHeight = (base * 2.4).rounded()
        var contentW: CGFloat = 0
        var contentH: CGFloat = 0
        if settings.layout == .vertical {
            contentW = laid.map(\.size.width).max() ?? 0
            contentH = laid.map(\.size.height).reduce(0, +) + gap * CGFloat(max(0, laid.count - 1))
        } else {
            contentW = laid.map(\.size.width).reduce(0, +) + gap * 1.5 * CGFloat(max(0, laid.count - 1))
            contentH = laid.map(\.size.height).max() ?? 0
        }
        if let graph {
            contentW = max(contentW, graph.width)
            contentH += (laid.isEmpty ? 0 : gap) + graphHeight + CTFontGetSize(labelFont) * 1.4
        }

        let width = Int((contentW + pad * 2).rounded(.up))
        let height = Int((contentH + pad * 2).rounded(.up))
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        if settings.backgroundOpacity > 0 {
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: base * 0.35, cornerHeight: base * 0.35, transform: nil))
            ctx.setFillColor(CGColor(gray: 0, alpha: settings.backgroundOpacity))
            ctx.fillPath()
        }

        // CoreGraphics is y-up here; lay out from the top.
        var cursorY = CGFloat(height) - pad
        var cursorX = pad

        func drawTile(_ t: Laid, x: CGFloat, top: CGFloat) {
            let h = t.size.height
            ctx.setFillColor(t.accent)
            ctx.fill(CGRect(x: x, y: top - h + base * 0.12, width: barWidth, height: h - base * 0.14))
            let tx = x + barWidth + base * 0.3
            ctx.textPosition = CGPoint(x: tx, y: top - CTFontGetSize(labelFont) * 0.95)
            CTLineDraw(t.label, ctx)
            let valueBaseline = top - h + base * 0.22
            ctx.textPosition = CGPoint(x: tx, y: valueBaseline)
            CTLineDraw(t.value, ctx)
            ctx.textPosition = CGPoint(x: tx + self.width(t.value) + base * 0.15, y: valueBaseline)
            CTLineDraw(t.unit, ctx)
        }

        if settings.layout == .vertical {
            for t in laid {
                drawTile(t, x: pad, top: cursorY)
                cursorY -= t.size.height + gap
            }
        } else {
            for t in laid {
                drawTile(t, x: cursorX, top: cursorY)
                cursorX += t.size.width + gap * 1.5
            }
            if !laid.isEmpty { cursorY -= (laid.map(\.size.height).max() ?? 0) + gap }
        }

        if let graph {
            drawGraph(graph, in: ctx, rect: CGRect(x: pad, y: pad, width: graph.width, height: graphHeight),
                      labelTop: cursorY, labelFont: labelFont, labelColor: labelColor, base: base)
        }
        return ctx.makeImage()
    }

    private func drawGraph(_ g: GraphSpec, in ctx: CGContext, rect: CGRect, labelTop: CGFloat, labelFont: CTFont, labelColor: CGColor, base: CGFloat) {
        ctx.textPosition = CGPoint(x: rect.minX, y: labelTop - CTFontGetSize(labelFont) * 0.95)
        CTLineDraw(line(g.metric.overlayLabel + " PROFILE", labelFont, labelColor), ctx)

        guard let series = g.activity.series[g.metric] else { return }
        let t0 = g.start.timeIntervalSince1970
        let t1 = t0 + g.length
        guard var range = series.range(from: t0, to: t1) else { return }
        if range.upperBound - range.lowerBound < 1e-6 { range = (range.lowerBound - 1)...(range.upperBound + 1) }
        // Depth is drawn downward, like a dive profile. The pace series holds speed, so faster plots higher.
        func y(_ v: Double) -> CGFloat {
            var f = (v - range.lowerBound) / (range.upperBound - range.lowerBound)
            if g.metric == .depth { f = 1 - f }
            return rect.minY + CGFloat(f) * rect.height
        }

        let steps = max(2, Int(rect.width / 2))
        let path = CGMutablePath()
        var started = false
        for i in 0...steps {
            let t = t0 + g.length * Double(i) / Double(steps)
            guard let v = series.value(at: t) else { started = false; continue }
            let p = CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(steps), y: y(v))
            if started { path.addLine(to: p) } else { path.move(to: p); started = true }
        }

        let accent = tile(for: g.metric, value: nil, units: .metric).accent
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0.5))
        ctx.addPath(path)
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(max(1.5, base * 0.07))
        ctx.setLineJoin(.round)
        ctx.strokePath()

        let mx = rect.minX + min(max(g.markerX, 0), rect.width)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
        ctx.fill(CGRect(x: mx - 1, y: rect.minY, width: 2, height: rect.height))
        if let v = series.value(at: t0 + g.length * Double(mx - rect.minX) / Double(rect.width)) {
            let r = max(3, base * 0.13)
            ctx.setFillColor(accent)
            ctx.fillEllipse(in: CGRect(x: mx - r, y: y(v) - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: - Cache

    private func cachedImage(_ key: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    private func store(_ image: CGImage, key: String) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = image
        cacheOrder.append(key)
        if cacheOrder.count > 120 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
