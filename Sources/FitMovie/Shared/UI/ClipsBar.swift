import SwiftUI

/// The project's clips in playback order. Tap to edit a clip; right-click / long-press to move or remove it.
struct ClipsBar<AddButton: View>: View {
    @EnvironmentObject private var model: EditorModel
    private let addButton: AddButton

    init(@ViewBuilder addButton: () -> AddButton) {
        self.addButton = addButton()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                        ClipChip(number: index + 1, clip: clip, isSelected: clip.id == model.selectedClipID)
                            .id(clip.id)
                            .onTapGesture { model.select(clip.id) }
                            .contextMenu { ClipActions(clipID: clip.id) }
                    }
                    addButton
                }
                .padding(.vertical, 2)
            }
            .onChange(of: model.selectedClipID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .frame(height: 58)
    }
}

/// Move earlier / later / remove, for menus and the Trim panel.
struct ClipActions: View {
    @EnvironmentObject private var model: EditorModel
    let clipID: UUID

    var body: some View {
        Button("Move Earlier", systemImage: "arrow.left") { model.moveClip(clipID, by: -1) }
            .disabled(!model.canMoveClip(clipID, by: -1))
        Button("Move Later", systemImage: "arrow.right") { model.moveClip(clipID, by: 1) }
            .disabled(!model.canMoveClip(clipID, by: 1))
        Divider()
        Button("Remove Clip", systemImage: "trash", role: .destructive) { model.removeClip(clipID) }
    }
}

private struct ClipChip: View {
    let number: Int
    let clip: Clip
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let thumb = clip.thumbnails.first {
                    Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.25)
                }
            }
            .frame(width: 84, height: 54)
            .clipped()

            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(3)

            Text(formatTimecode(clip.timeline.outputDuration, fractional: false))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(3)
                .frame(width: 84, height: 54, alignment: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3))
        .contentShape(Rectangle())
        .help(clip.name)
        .accessibilityLabel("Clip \(number), \(clip.name)")
    }
}

/// The square "+" tile at the end of the clips bar.
struct AddClipTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(.secondary)
            .frame(width: 54, height: 54)
            .overlay(Image(systemName: "plus").font(.title3.weight(.semibold)).foregroundStyle(Color.accentColor))
            .contentShape(Rectangle())
            .accessibilityLabel("Add clips")
    }
}
