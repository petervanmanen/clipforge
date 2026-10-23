import SwiftUI

/// Filmstrip of the whole source clip with trim handles, removed parts, the In/Out selection and the playhead.
struct TimelineStrip: View {
    @EnvironmentObject private var model: EditorModel
    private let stripHeight: CGFloat = 56

    var body: some View {
        let timeline = model.displayedTimeline
        let duration = max(timeline.sourceDuration, 0.001)

        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                let x = { (t: Double) -> CGFloat in CGFloat(t / duration) * width }
                let time = { (px: CGFloat) -> Double in Double(min(max(px, 0), width) / max(width, 1)) * duration }

                ZStack(alignment: .topLeading) {
                    filmstrip(width: width)

                    // Trimmed-away head and tail.
                    Rectangle().fill(.black.opacity(0.65))
                        .frame(width: max(0, x(timeline.trimStart)), height: stripHeight)
                    Rectangle().fill(.black.opacity(0.65))
                        .frame(width: max(0, width - x(timeline.trimEnd)), height: stripHeight)
                        .offset(x: x(timeline.trimEnd))

                    // Removed middle parts.
                    ForEach(timeline.cuts) { cut in
                        RemovedPart()
                            .frame(width: max(2, x(cut.end) - x(cut.start)), height: stripHeight)
                            .offset(x: x(cut.start))
                            .help("Removed \(formatTimecode(cut.start)) – \(formatTimecode(cut.end))")
                    }

                    // In/Out selection.
                    if let i = model.markIn {
                        let o = model.markOut ?? model.currentSourceTime
                        let lo = min(i, o), hi = max(i, o)
                        Rectangle()
                            .fill(Color.yellow.opacity(0.25))
                            .overlay(Rectangle().strokeBorder(Color.yellow, lineWidth: 1.5))
                            .frame(width: max(2, x(hi) - x(lo)), height: stripHeight)
                            .offset(x: x(lo))
                    } else if let o = model.markOut {
                        Rectangle().fill(Color.yellow).frame(width: 2, height: stripHeight).offset(x: x(o) - 1)
                    }

                    // Kept range outline.
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .frame(width: max(4, x(timeline.trimEnd) - x(timeline.trimStart)), height: stripHeight)
                        .offset(x: x(timeline.trimStart))
                        .allowsHitTesting(false)

                    // Playhead.
                    Rectangle()
                        .fill(Color.white)
                        .shadow(radius: 1)
                        .frame(width: 2, height: stripHeight + 10)
                        .offset(x: x(model.currentSourceTime) - 1, y: -5)
                        .allowsHitTesting(false)

                    TrimHandle(systemImage: "chevron.compact.left")
                        .offset(x: x(timeline.trimStart) - 7)
                        .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                            .onChanged { model.dragTrimStart(to: time($0.location.x)) }
                            .onEnded { _ in model.endTrimDrag() })
                        .help("Drag to trim the start")
                    TrimHandle(systemImage: "chevron.compact.right")
                        .offset(x: x(timeline.trimEnd) - 7)
                        .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                            .onChanged { model.dragTrimEnd(to: time($0.location.x)) }
                            .onEnded { _ in model.endTrimDrag() })
                        .help("Drag to trim the end")
                }
                .frame(width: width, height: stripHeight)
                .coordinateSpace(name: "strip")
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { model.scrub(toSource: time($0.location.x)) }
                    .onEnded { _ in model.endScrub() })
            }
            .frame(height: stripHeight)

            HStack {
                Text(formatTimecode(0)).foregroundStyle(.tertiary)
                Spacer()
                Text("Source position \(formatTimecode(model.currentSourceTime))")
                    .foregroundStyle(timeline.isRemoved(source: model.currentSourceTime) ? .red : .secondary)
                Spacer()
                Text(formatTimecode(timeline.sourceDuration)).foregroundStyle(.tertiary)
            }
            .font(.caption.monospacedDigit())
        }
    }

    @ViewBuilder
    private func filmstrip(width: CGFloat) -> some View {
        let thumbs = model.thumbnails
        if thumbs.isEmpty {
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2)).frame(width: width, height: stripHeight)
        } else {
            HStack(spacing: 0) {
                ForEach(thumbs.indices, id: \.self) { i in
                    Image(decorative: thumbs[i], scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(thumbs.count), height: stripHeight)
                        .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

private struct RemovedPart: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color.red.opacity(0.35))
            Canvas { ctx, size in
                var path = Path()
                var x: CGFloat = -size.height
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += 8
                }
                ctx.stroke(path, with: .color(.red.opacity(0.8)), lineWidth: 1.5)
            }
            Image(systemName: "scissors").font(.caption.bold()).foregroundStyle(.white)
        }
        .clipped()
    }
}

private struct TrimHandle: View {
    let systemImage: String

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .frame(width: 14, height: 56)
            .overlay(Image(systemName: systemImage).font(.system(size: 14, weight: .bold)).foregroundStyle(.white))
            .contentShape(Rectangle().inset(by: -6))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}
