# CLAUDE.md

Guidance for Claude (or anyone) working on ClipForge. Requirements and their status are in [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md). Read both before changing anything.

## What this is

ClipForge is a video editor for action and dive footage, with a **macOS app** (macOS 15+) and an **iPhone app** (iOS 18+). Both trim and cut, overlay FIT watch data, stabilize, apply filters and add background music. It is written in SwiftUI with AVFoundation, Core Image and Vision, and has no third-party dependencies.

The engine and the editing panels are shared source code that both apps compile:
- **macOS:** a Swift package (`Package.swift`) with one executable target and one test target. Its target path, `Sources/ClipForge`, contains both `Shared/` and `Mac/`.
- **iOS:** an Xcode project, `iOS/ClipForge.xcodeproj`, written by hand. It uses Xcode's folder-synced groups for `iOS/ClipForge/` and `../Sources/ClipForge/Shared/`, so new files in those folders are picked up automatically and the project file rarely needs editing.

## Commands

```bash
swift build                    # macOS debug build
swift test                     # 9 tests, ~6 s; includes real end-to-end exports
KEEP_TEST_OUTPUT=1 swift test  # keep generated clips and frames (path printed in the log)
./scripts/build_app.sh         # release universal macOS build → build/ClipForge.app (ad-hoc signed)
swift scripts/make_icon.swift  # regenerate Resources/AppIcon.icns, AppIcon.png and the iOS app-icon PNG

# iPhone app (simulator)
xcodebuild -project iOS/ClipForge.xcodeproj -scheme ClipForge \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build/ios-dd build
xcrun simctl install booted build/ios-dd/Build/Products/Debug-iphonesimulator/ClipForge.app
xcrun simctl launch booted app.clipforge.ClipForge
```

- `build_app.sh` reads `VERSION` and `BUILD_NUMBER` for Info.plist; CI sets them.
- The Mac app can be opened with files: `open -a build/ClipForge.app clip.mov activity.fit music.m4a`.
- On iOS:
  - Add a test clip to the simulator's Photos with `xcrun simctl addmedia booted clip.mov`.
  - Send a FIT file to the running app with `xcrun simctl openurl booted file:///path/run.fit`. This goes through "Open in" → `onOpenURL` → `importFile`.
- Installing on a real iPhone needs your own team: open the project in Xcode and set Signing & Capabilities → Team. Change the bundle ID `app.clipforge.ClipForge` if it's taken.
- To see the Mac app, `screencapture -l <windowID>` works. Get the ID from `CGWindowListCopyWindowInfo` with a small Swift script. Don't use `osascript` with System Events: it hangs on an Automation permission prompt.
- Simulator driving tips:
  - Screenshots often lag one action behind, so take two.
  - A tap doesn't flip a SwiftUI `Toggle`; a short horizontal swipe across it does.
  - `simctl launch` can leave the app in the background; tap its home-screen icon.

## Layout

```
Sources/ClipForge/
  Shared/                       Compiled into BOTH apps (keep it free of AppKit/UIKit except behind #if)
    FIT/FITParser.swift         Low-level FIT decoder → [FITMessage] (numeric fields only)
    FIT/FITActivity.swift       OverlayMetric, FITSeries (interpolation/smoothing), FITActivity.decode
    Models/EditTimeline.swift   Trim/cut model, source↔output time mapping, formatTimecode
    Models/Settings.swift       FilterKind (CI filter chains), Filter/Stabilization/Overlay/Audio settings, export presets
    Models/EditorModel.swift    @MainActor ObservableObject: the single view model (player, rebuilds, scrub,
                                analysis, import/export requests, preview fallback). ImportKind lives here too.
    Models/PhotoLibrary.swift   iOS only: save the export to Photos
    Engine/SourceVideo.swift    Loads an asset: tracks, orientation, natural/display size, fps, codec, creation date
    Engine/EffectsCompositor.swift  Our AVVideoCompositing: orientation + per-frame CI render (used everywhere)
    Engine/CompositionBuilder.swift AVMutableComposition + effects composition + audio mix; VideoExporter
    Engine/FrameRenderer.swift  RenderSnapshot / RenderState (lock-protected) / per-frame pipeline
    Engine/Stabilizer.swift     Motion analysis (Vision), path smoothing, per-frame apply
    Engine/OverlayRenderer.swift  Draws the metric panel + graph with CoreGraphics/CoreText, cached
    UI/PlatformViews.swift      PlayerSurface (AVPlayerView / AVPlayerLayer), FileImportHandler, LimitedPreviewBadge
    UI/TimelineStrip.swift      Filmstrip with trim handles, cuts, In/Out selection, playhead
    UI/InspectorView.swift      Tabbed panels: Trim, Stabilize, Filters, Audio, Export (+ ExportResultView)
    UI/OverlayPanel.swift       The "Data" (FIT overlay) panel
  Mac/
    ClipForgeApp.swift          App, menu commands, AppDelegate (Finder "Open With" → model.handleDrop)
    MacContentView.swift        Window: preview, transport bar with keyboard shortcuts, inspector, drag & drop
iOS/
  ClipForge.xcodeproj           Hand-written project (objectVersion 77, synced folders, no shared scheme committed)
  Info.plist                    Document types + imported UTI app.clipforge.fit (merged with generated keys)
  ClipForge/ClipForgePhoneApp.swift  App entry, AVAudioSession .playback, onOpenURL
  ClipForge/PhoneEditorView.swift    Phone layout, PhotosPicker import (PickedMovie), compact transport
  ClipForge/Assets.xcassets     AppIcon (generated, opaque 1024 px), AccentColor
Tests/ClipForgeTests/           FITTests (+ FITWriter), TimelineTests, PipelineTests (synthetic video/audio/FIT)
scripts/                        build_app.sh, make_icon.swift
Resources/                      AppIcon.icns / AppIcon.png (generated; committed)
.github/workflows/build.yml     CI: macOS tests + app zip; iOS simulator compile check
```

## How it works

### Two time bases
- **Source time** is seconds in the original file. Trim points, cuts, stabilization analysis, the FIT sync and the timeline view all use source time.
- **Output time** is seconds in the edited result, which is what the AVPlayer and the export use.
- `EditTimeline.keptRanges` (trim minus cuts) defines the mapping in both directions. `outputTime(forSource:)` snaps a time inside a removed part to the next kept frame.

### The edit pipeline
1. `CompositionBuilder.build` creates an `AVMutableComposition`. It inserts each kept range of the first video track and the chosen audio track, then the music (looped as needed). It also builds an `AVMutableAudioMix` for volumes and fades.
2. The video composition comes from `EffectsComposition.make`: our own `AVVideoCompositing` class (`EffectsCompositor`) plus a single `EffectsInstruction` that carries the render closure. For each frame the compositor:
   - takes the source pixel buffer (BGRA) and rotates it to display orientation with `orientationTransform`;
   - calls the closure, which is `FrameRenderer.render`: stabilization, then the filter (blended by intensity), then adjustments and vignette, then the overlay;
   - renders the result into the output buffer.
3. The same `EffectsComposition.make` is used for player, export, scrub previews (an `AVAssetImageGenerator` on the raw source) and stabilization analysis, so every path sees identically oriented frames.
4. **Colour is passed through, not managed.** The `CIContext` has `workingColorSpace: NSNull()`, input images are created with `.colorSpace: NSNull()`, rendering uses `colorSpace: nil`, and the source buffer's colour tags are copied to the output. An unfiltered frame is therefore bit-for-bit what the decoder gave. HDR clips come out tagged as HDR but rendered through an 8-bit BGRA buffer; true HDR preservation is still open.

### Settings reach the renderer without a rebuild
- `RenderState` holds an immutable `RenderSnapshot` behind a lock, and the compositor reads it on its own queue.
- `EditorModel.pushSnapshot()` writes a new snapshot whenever filter, overlay, stabilization or FIT settings change, then calls `refreshFrame()`.
- `refreshFrame()` redraws the paused frame by assigning `item.videoComposition = vc.mutableCopy()`. ⚠️ This is still not confirmed by hand on a Mac or an iPhone. Check it first if a paused preview looks stale.
- Only changes to the timeline or audio rebuild the composition (debounced by 120 ms).

### Preview fallback (`previewIsLimited`)
The iOS 27 Simulator cannot play any `AVPlayerItem` that has a video composition. It fails with -12784, even with a plain `AVMutableVideoComposition(propertiesOf:)`, while export and image generation work. `EditorModel.watchForPlaybackFailure` detects the failed item and swaps in the plain edit without effects. It sets `previewIsLimited`, which:
- shows each paused or scrubbed frame with all effects, rendered through the scrub generator (`showStillFrame`);
- shows "Effects show when paused" during playback (`LimitedPreviewBadge`).

Export is unaffected. On a real device and on macOS the effects composition is expected to play normally, and the fallback never triggers. ⚠️ Live effects playback has not been verified on a physical iPhone.

### Scrubbing
While dragging on the timeline or a trim handle, the preview shows `scrubImage` from an `AVAssetImageGenerator` on the raw source, using `previewComposition` (`FrameRenderer.render(_:sourceTime:)`). Effects therefore show while scrubbing, even inside removed parts. Trim-handle drags keep a `pendingTimeline` and commit it when the drag ends.

### Import and export per platform
- `EditorModel.requestImport(kind)` sets `importRequest`, and `FileImportHandler` (`.fileImports(for:)`) shows SwiftUI's `fileImporter` on both platforms.
- `importFile(_:as:)` copies the file on iOS, because picked URLs are security-scoped and only readable briefly. The copy goes to `tmp/Imported/<uuid>/<original name>`, and the original name is kept because it identifies GoPro and DJI clips.
- iOS also imports from Photos via `PhotosPicker` with `preferredItemEncoding: .current`, so HEVC is not transcoded and the creation date survives. `PickedMovie` is a `Transferable` that copies the file.
- `requestExport()`: on macOS this is an `NSSavePanel`; on iOS it renders into `tmp/Exports/`, after which `ExportResultView` offers Save to Photos (add-only permission) and a Share sheet.

### Stabilization
- **Analysis** reads frames through the effects compositor at 640 px on the long side, using Lanczos downscaling because plain scaling aliases and reads as false motion. Vision's `VNTranslationalImageRegistrationRequest` runs with the previous frame as reference and the current frame as target, and the cumulative trajectory is stored in display pixels. Jumps larger than 25% of the width count as scene cuts and are ignored.
- **Path:** two box-filter passes with radius = strength × fps × 2 frames. The ends are extended by point reflection, so a steady pan stays a straight line instead of flattening at the clip ends. Then four passes clamp the correction to the crop margin and re-smooth it.
- **Apply** shifts the frame by the correction, zooms by `1/(1-maxCrop)` about the centre, and uses `clampedToExtent` and `cropped`.

### Overlay and FIT
- The FIT time for a frame is `videoStartDate + sourceTime + overlay.timeOffset`.
- With "camera clock is local time" on (GoPro and DJI), the FIT file's UTC offset is subtracted from the video start.
- The panel is drawn with CoreText, which is thread-safe, and cached by its displayed values.
- Record fields used: 253 timestamp, 3 heart rate, 6/73 speed (÷1000), 5 distance (÷100), 92 depth (÷1000), 13 temperature, 2/78 altitude (÷5 − 500).
- Sport comes from Session (18) or Sport (12); sport 53 is diving. The UTC offset is local_timestamp minus timestamp from the Activity message (34).
- The FIT epoch is 631065600 seconds after the Unix epoch.

## Facts verified by experiment (don't re-derive)
- **Vision sign:** with handler = A and target = B, where B is A shifted by (+20, +10) in Core Image coordinates, `alignmentTransform` is `(−20, −10)`. So content motion = −alignmentTransform.
- **Orientation:** `EffectsComposition.orientationTransform` matches `AVAssetImageGenerator.appliesPreferredTrackTransform` for 0°, 90°, 180° and 270° (`testCompositorOrientationMatchesAVFoundation`). Brightness also matches, because colour is passed through.
- **Colour:** rendering with `itur_709` or `sRGB` output spaces made frames 11–17 levels brighter than AVFoundation's. Pass-through fixed it.
- **Simulator playback:** see "Preview fallback" above. `applyingCIFiltersWithHandler`, a custom compositor and a plain property-based composition all fail in Simulator playback; export works.
- **Test content matters:**
  - `CIRandomGenerator` tiles every 512 px, which makes frame registration ambiguous. Tests use random discs (`makeTexture`).
  - A static overlay dominates Vision's motion estimate, so stabilization is measured on exports without the overlay (`testStabilizationRemovesShakeButKeepsPan`).
- **Stabilization result:** shake 33 → 0.9 (mean frame-to-frame acceleration), pan −268 → −254 px (kept).
- **Warm and cool:** `CITemperatureAndTint` with target below 6500 warms the image. Warm uses 4700, cool uses 9000.

## Gotchas
- **Toolchain gap:** local Xcode 27 (Swift 6.4) versus the CI runner's Xcode 26.3. Code that builds locally can fail on CI. Known traps:
  - A method `width(_:)` called in a function that later declares `let width`: write `self.width(...)`.
  - Long `zip/map/reduce` chains time out the older type checker: use loops.

  Check the CI run (`gh run list` / `gh run watch`) after pushing.
- **Platform code:** `Shared/` must compile on both platforms. Wrap AppKit/UIKit with `#if os(macOS)` / `#if canImport(AppKit)`. Mac-only SwiftUI styles break the iOS build (`.buttonStyle(.link)`, `.menuStyle(.borderlessButton)`). User-facing hints that mention keys go through `platformHint(mac:phone:)`.
- **Swift version:** tools version 6.0 with `swiftLanguageModes: [.v5]` (package) and `SWIFT_VERSION = 5.0` (iOS project). Thread safety relies on `@unchecked Sendable` classes with locks. Keep compositor code free of main-actor state.
- **Mac shortcuts:** the transport bar uses keys without modifiers, which steal keystrokes from text fields. Don't add free-text fields there.
- **Audio tracks:** iPhone spatial audio adds an `apac` track, which is skipped. Audio is often a few milliseconds shorter than video, so only the overlap of each kept range is inserted.
- **iOS icon:** it must be opaque. `make_icon.swift` writes it with `noneSkipLast`.

## Conventions
- Match the existing style: value-type settings, one `EditorModel`, panels as private SwiftUI structs, comments only where something is non-obvious.
- Keep the engine free of SwiftUI so it can be tested headless (`@testable import ClipForge`). Add a test for engine changes. `PipelineTests` shows how to generate synthetic video, audio and FIT data.
- Commit messages end with a `Co-Authored-By:` line. The repository is `git@github.com:petervanmanen/clipforge.git` on branch `main`, and CI runs on every push.

## Known limitations / next steps
See the ⬜ and 🟡 items in [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md). The most important:
- Test on a real iPhone, including live effects playback, Save to Photos, and large 4K HEVC clips (memory and time).
- Try real iPhone, GoPro, DJI and Android clips, and real Suunto/Garmin FIT files.
- Preserve HDR. Notarize the Mac app. Add rotation stabilization.
