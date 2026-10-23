# CLAUDE.md

Guidance for Claude (or anyone) working on ClipForge. Requirements and their status are in [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md). Read both before changing anything.

## What this is

ClipForge is a native macOS 15+ video editor for action and dive footage. It trims and cuts, overlays FIT watch data, stabilizes, applies filters and adds background music. It is written in SwiftUI with AVFoundation, Core Image and Vision, and has no third-party dependencies. It is a Swift package (`Package.swift`) with one executable target and one test target, and no Xcode project.

## Commands

```bash
swift build                    # debug build
swift test                     # 7 tests, ~3 s; includes a real end-to-end export
KEEP_TEST_OUTPUT=1 swift test  # keep the generated clips and frame.png (path printed in the log)
./scripts/build_app.sh         # release universal build → build/ClipForge.app (ad-hoc signed)
open build/ClipForge.app
swift scripts/make_icon.swift  # regenerate Resources/AppIcon.icns + AppIcon.png
```

`build_app.sh` reads the `VERSION` and `BUILD_NUMBER` environment variables for Info.plist; CI sets them. The app can be opened with files: `open -a build/ClipForge.app clip.mov activity.fit music.m4a` loads all three. This is the easiest way to try a change by hand.

To see the running app, `screencapture -l <windowID>` works. Get the window ID from `CGWindowListCopyWindowInfo` with a small Swift script. Don't use `osascript` with System Events: it hangs waiting for an Automation permission.

## Layout

```
Sources/ClipForge/
  ClipForgeApp.swift        App, menu commands, AppDelegate (Finder "Open With" → model.handleDrop)
  FIT/FITParser.swift       Low-level FIT decoder → [FITMessage] (numeric fields only)
  FIT/FITActivity.swift     OverlayMetric enum, FITSeries (interpolation/smoothing), FITActivity.decode
  Models/EditTimeline.swift Trim/cut model, source↔output time mapping, formatTimecode
  Models/Settings.swift     FilterKind (CI filter chains), Filter/Stabilization/Overlay/Audio settings, export presets
  Models/EditorModel.swift  @MainActor ObservableObject: the single view model (player, rebuilds, scrub, analysis, export)
  Engine/SourceVideo.swift  Loads an asset: tracks, orientation, fps, codec, creation date, supported UTTypes
  Engine/CompositionBuilder.swift  AVMutableComposition + CI video composition + audio mix; VideoExporter
  Engine/FrameRenderer.swift       RenderSnapshot / RenderState (lock-protected) / per-frame pipeline
  Engine/Stabilizer.swift          Motion analysis (Vision), path smoothing, per-frame apply
  Engine/OverlayRenderer.swift     Draws the metric panel + graph with CoreGraphics/CoreText, cached
  UI/ContentView.swift      Main window, preview (AVPlayerView, no controls), transport bar, drop handling
  UI/TimelineStrip.swift    Filmstrip with trim handles, cuts, In/Out selection, playhead
  UI/InspectorView.swift    Tabbed inspector: Trim, Stabilize, Filters, Audio, Export panels
  UI/OverlayPanel.swift     The "Data" (FIT overlay) inspector panel
Tests/ClipForgeTests/       FITTests (+ FITWriter that builds FIT files in memory), TimelineTests, PipelineTests
scripts/                    build_app.sh, make_icon.swift
Resources/                  AppIcon.icns / AppIcon.png (generated; committed)
.github/workflows/build.yml CI
```

## How it works

### Two time bases
- **Source time** is seconds in the original file. Trim points, cuts, stabilization analysis, the FIT sync and the timeline view all use source time.
- **Output time** is seconds in the edited result, which is what the AVPlayer and the export use.
- `EditTimeline.keptRanges` (trim minus cuts) defines the mapping in both directions. `outputTime(forSource:)` snaps a time inside a removed part to the next kept frame.
- The video compositor receives output time (`request.compositionTime`) and converts it to source time with `EditTimeline.sourceTime(forOutput:kept:)` using the snapshot's `keptRanges`.

### The edit pipeline
1. `CompositionBuilder.build` creates an `AVMutableComposition`. It inserts each kept range of the first video track and the chosen audio track, then the music track (looped as needed). It also builds an `AVMutableAudioMix` for volumes and fades.
2. The video composition is `AVMutableVideoComposition.videoComposition(with:applyingCIFiltersWithHandler:)`. Its handler calls `FrameRenderer.render`, which applies stabilization, then the filter (blended by intensity with `CIDissolveTransition`), then colour adjustments and vignette, then the overlay. The result is cropped to the frame.
3. The player and the export use the same `EditedMovie`, so the preview matches the exported file. The export builds a fresh `EditedMovie` from the same `FrameRenderer`.

### Settings reach the renderer without a rebuild
- `RenderState` holds an immutable `RenderSnapshot` behind an `NSLock`. The compositor reads it on its own threads for every frame.
- `EditorModel.pushSnapshot()` writes a new snapshot whenever filter, overlay, stabilization or FIT settings change, then calls `refreshFrame()`.
- Only changes to the timeline or audio rebuild the composition (`scheduleRebuild`, debounced by 120 ms). After a rebuild, playback continues at the same source time.
- `refreshFrame()` redraws the paused frame by assigning `item.videoComposition = vc.mutableCopy()`, a known trick for forcing AVPlayer to re-render. ⚠️ Nobody has confirmed by hand that every effect change shows up immediately while paused. Check this first if a paused preview looks stale.

### Scrubbing
While dragging on the timeline or a trim handle, the preview shows `scrubImage` from an `AVAssetImageGenerator` on the *raw source asset*. That generator has its own CI video composition (`previewComposition`), which calls `FrameRenderer.render(_:sourceTime:)`, so effects show while scrubbing, even inside removed parts. When the drag ends, the player seeks and `scrubImage` is cleared. Trim-handle drags keep a `pendingTimeline` and only commit it, triggering a rebuild, when the drag ends.

### Stabilization
- **Analysis** (`Stabilizer.analyze`) runs off the main actor. An `AVAssetReaderVideoCompositionOutput` with a CI composition delivers frames that are already rotated and downscaled to a 640 px long side; `renderSize` is set on the mutable composition. For each frame pair, `VNTranslationalImageRegistrationRequest` runs with the previous frame as reference and the current frame as target. The cumulative trajectory is stored in full-resolution display pixels. Jumps larger than 25% of the frame width count as scene cuts and are ignored.
- **Path** (`Stabilizer.path`) smooths the trajectory with two box-filter passes (radius = strength × fps × 2 frames). Four passes then clamp the correction to the crop margin and re-smooth it, so the correction never exceeds `frameSize × maxCrop / 2`. The path is cached in `EditorModel` and recomputed only when strength or maxCrop change.
- **Apply** shifts the frame by the correction, zooms by `1/(1-maxCrop)` about the centre, and uses `clampedToExtent` and `cropped(to:)`.

### Overlay
- The FIT time for a frame is `snapshot.videoStartDate + sourceTime + overlay.timeOffset`.
- `videoStartDate` is the asset's creation date. When "camera clock is local time" is on, the FIT file's UTC offset is subtracted (or the Mac's time zone if the file has none). If the video has no creation date, the FIT start is used.
- The panel is drawn into a small `CGContext` with CoreText; this is thread-safe, so don't use AppKit drawing here. It is turned into a `CIImage` and positioned in Core Image coordinates (y points up).
- Rendered panels are cached (up to 120) by a key made of the displayed strings, the graph marker's pixel position and the style settings, so most frames reuse a cached image.

### FIT decoding
- Record message (global 20) fields used: 253 timestamp, 3 heart rate, 6/73 speed (÷1000 m/s; enhanced preferred), 5 distance (÷100 m), 92 depth (÷1000 m), 13 temperature (°C), 2/78 altitude (÷5 − 500 m).
- Session (18) and Sport (12) messages give the sport: field 5/0 = sport, 6/1 = sub-sport, and sport 53 is diving. The Activity message (34) gives `local_timestamp` (field 5) minus timestamp, which is the UTC offset rounded to 15 minutes.
- The FIT epoch is 1989-12-31 UTC, which is `FITParser.fitEpochOffset` = 631065600 seconds.
- Speed and altitude are smoothed over 5 s. The pace series is the smoothed speed series, converted when formatted.
- Values are interpolated linearly. Across gaps longer than 15 s the value is shown as `--`.

## Facts that were verified by experiment (don't re-derive)
- **Vision sign:** with handler = image A and target = image B, where B is A shifted by (+20, +10) in Core Image coordinates, `alignmentTransform` is `tx = −20, ty = −10`. So content motion = −alignmentTransform. Pass `CIImage`s, not `CVPixelBuffer`s, so the coordinates match the render handler's (y up).
- **Orientation:** with `applyingCIFiltersWithHandler`, `request.sourceImage` is already rotated by the track's `preferredTransform`, and `renderSize` is the display size. The composition track must copy `preferredTransform` from the source; the builder does this.
- **Homography:** `VNHomographicImageRegistrationRequest` returned garbage translation on synthetic images, which is why stabilization is translation-only.
- **Warm and cool:** `CITemperatureAndTint` with neutral 6500 and target **below** 6500 makes the image warmer. Warm uses 4700, cool uses 9000.
- **Stabilization works:** in the end-to-end test, mean frame-to-frame acceleration fell from about 85 to about 9.5 (strength 0.8, crop 12%).

## Gotchas
- **Toolchain gap:** the local Mac has Xcode 27 (Swift 6.4); the CI runner `macos-15` uses Xcode 26.3 via `setup-xcode latest-stable`. Code that builds locally can fail on CI. Two cases so far:
  - A call to a method `width(_:)` inside a function that later declares `let width` failed on the older compiler. Write `self.width(...)`.
  - Long `zip/map/reduce` chains timed out the older type checker. Use plain loops or add type annotations.

  After pushing, check the CI run with `gh run list` / `gh run watch`.
- **Swift version:** `Package.swift` uses tools version 6.0 (needed for `.macOS(.v15)`) with `swiftLanguageModes: [.v5]`. Strict Swift 6 concurrency is deliberately off. Thread safety relies on `@unchecked Sendable` classes with locks: `RenderState`, `FrameRenderer`, `OverlayRenderer`. Keep compositor code free of main-actor state.
- **Keyboard shortcuts:** the transport bar uses shortcuts without modifiers (space, `,` `.` `[` `]` `I` `O` ⌫). These steal keystrokes from text fields. The only text field is the overlay offset, which takes digits. Don't add free-text fields without adding modifiers or scoping the shortcuts.
- **Audio tracks:** iPhone spatial audio adds an `apac` track, which `SourceVideo.load` skips. Audio is often a few milliseconds shorter than video (GoPro, DJI), so only the overlap of each kept range is inserted.
- **AVPlayerView:** `allowsVideoFrameAnalysis = false` hides the Live Text button.
- **AppDelegate:** it sets `.regular` activation policy so `swift run` (no bundle) still gets a menu bar and focus.
- **Frame rate:** variable-frame-rate phone video uses `minFrameDuration` for `frameDuration`. This is untested with real Android VFR files.

## Conventions
- Match the existing style: small value-type settings structs, one `EditorModel`, panels as private SwiftUI structs, comments only where something is non-obvious.
- Keep the engine (`FIT/`, `Engine/`, `Models/EditTimeline.swift`, `Models/Settings.swift`) free of SwiftUI so it can be tested headless. The tests use `@testable import ClipForge`.
- Add a test for engine changes. `PipelineTests` shows how to generate synthetic video (`makeShakyVideo`), audio (`makeTone`) and FIT data (`FITWriter` in `FITTests.swift`).
- Commit messages end with a `Co-Authored-By:` line. The repository is `git@github.com:petervanmanen/clipforge.git` on branch `main`, and CI runs on every push.

## Known limitations / next steps
See the ⬜ and 🟡 items in [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md). The most important:
- Verify with real iPhone, GoPro, DJI and Android clips and real Suunto/Garmin FIT files (dives especially).
- Preserve HDR on export.
- Notarize the app (needs a Developer ID).
- Add rotation stabilization.
