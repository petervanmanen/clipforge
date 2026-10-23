import SwiftUI

struct OverlayPanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        if let activity = model.activity {
            activityInfo(activity)
            metricsSection(activity)
            styleSection(activity)
            syncSection(activity)
        } else {
            PanelSection(title: "Activity data") {
                Text("Load a .fit file from your watch to show heart rate, pace or – for dives – depth on the video.")
                    .foregroundStyle(.secondary)
                Button {
                    model.loadFITPanel()
                } label: {
                    Label("Load FIT File…", systemImage: "applewatch").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Text("Export a FIT file from Suunto, Garmin Connect, Coros, Strava (original file), … You can also drop it on the window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func activityInfo(_ activity: FITActivity) -> some View {
        PanelSection(title: "Activity data") {
            HStack(alignment: .top) {
                Image(systemName: activity.isDive ? "water.waves" : "figure.run")
                    .font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.sportName).font(.headline)
                    Text(activity.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text(activity.startDate.formatted(date: .abbreviated, time: .shortened) + " · "
                         + formatTimecode(activity.endDate.timeIntervalSince(activity.startDate), fractional: false))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Replace…") { model.loadFITPanel() }
                    Button("Remove", role: .destructive) { model.removeFIT() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
            Toggle("Show overlay", isOn: $model.overlay.enabled).toggleStyle(.switch)
        }
    }

    private func metricsSection(_ activity: FITActivity) -> some View {
        PanelSection(title: "Show") {
            ForEach(activity.availableMetrics) { metric in
                Toggle(metric.title, isOn: Binding(
                    get: { model.overlay.metrics.contains(metric) },
                    set: { on in
                        if on { model.overlay.metrics.insert(metric) } else { model.overlay.metrics.remove(metric) }
                    }))
            }
            let missing = OverlayMetric.allCases.filter { !activity.availableMetrics.contains($0) }
            if !missing.isEmpty {
                Text("Not in this file: " + missing.map(\.title).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Show profile graph", isOn: $model.overlay.showGraph)
            if model.overlay.showGraph {
                Picker("Graph", selection: $model.overlay.graphMetric) {
                    ForEach(activity.availableMetrics.filter(\.isGraphable)) { Text($0.title).tag($0) }
                }
            }
        }
        .disabled(!model.overlay.enabled)
    }

    private func styleSection(_ activity: FITActivity) -> some View {
        PanelSection(title: "Style") {
            Picker("Position", selection: $model.overlay.position) {
                ForEach(OverlayPosition.allCases) { Text($0.title).tag($0) }
            }
            Picker("Layout", selection: $model.overlay.layout) {
                ForEach(OverlayLayout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Units", selection: $model.overlay.units) {
                ForEach(UnitSystem.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledSlider(title: "Size", value: $model.overlay.scale, range: 0.5...2.2) { "\(Int(($0 * 100).rounded()))%" }
            LabeledSlider(title: "Background", value: $model.overlay.backgroundOpacity, range: 0...0.9) { "\(Int(($0 * 100).rounded()))%" }
            ColorPicker("Text color", selection: Binding(
                get: {
                    let c = model.overlay.textColor
                    return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
                },
                set: { color in
                    let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
                    model.overlay.textColor = RGBAColor(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
                }))
        }
        .disabled(!model.overlay.enabled)
    }

    private func syncSection(_ activity: FITActivity) -> some View {
        PanelSection(title: "Sync with video") {
            if let created = model.source?.creationDate {
                HStack {
                    Text("Video recorded")
                    Spacer()
                    Text((model.videoStartDate ?? created).formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                }
                .font(.callout)
                Toggle("Camera clock is local time", isOn: $model.videoClockIsLocal)
                    .help("GoPro and DJI store local time without a time zone. Turn this on if the data is off by whole hours.")
            }
            if let status = model.syncStatus {
                Text(status).font(.caption)
                    .foregroundStyle(status.hasPrefix("⚠︎") ? .orange : .secondary)
            }
            HStack {
                Text("Offset")
                Spacer()
                TextField("", value: $model.overlay.timeOffset, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                Text("s")
                Stepper("", value: $model.overlay.timeOffset, step: 1).labelsHidden()
            }
            Slider(value: $model.overlay.timeOffset, in: -120...120, step: 0.5)
            HStack {
                Button("−1 h") { model.overlay.timeOffset -= 3600 }
                Button("+1 h") { model.overlay.timeOffset += 3600 }
                Spacer()
                Button("Align to Activity Start") { model.alignToActivityStart() }
            }
            .controlSize(.small)
            Text("Scrub to a recognizable moment (a start, a jump in heart rate, the descent) and nudge the offset until the numbers match.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
