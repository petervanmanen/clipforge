# CLAUDE.md

Guidance for Claude (or anyone) working on FitMovie. Requirements and their status are in [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md). Read both before changing anything.

## What this is

FitMovie is a video editor for action and dive footage, with a **macOS app** (macOS 15+) and an **iPhone app** (iOS 18+). Both combine several clips into one movie, trim and cut, overlay FIT watch data, stabilize, apply filters and add background music. It is written in SwiftUI with AVFoundation, Core Image and Vision, and has no third-party dependencies.

The engine and the editing panels are shared source code that both apps compile:
- **macOS:** a Swift package (`Package.swift`) with one executable target and one test target. Its target path, `Sources/FitMovie`, contains both `Shared/` and `Mac/`.
- **iOS:** an Xcode project, `iOS/FitMovie.xcodeproj`, written by hand. It uses Xcode's folder-synced groups for `iOS/FitMovie/` and `../Sources/FitMovie/Shared/`, so new files in those folders are picked up automatically and the project file rarely needs editing.

## Commands

```bash
swift build                    # macOS debug build
swift test                     # 9 tests, ~6 s; includes real end-to-end exports
KEEP_TEST_OUTPUT=1 swift test  # keep generated clips and frames (path printed in the log)
./scripts/build_app.sh         # release universal macOS build → build/FitMovie.app (ad-hoc signed)
swift scripts/make_icon.swift  # regenerate Resources/AppIcon.icns, AppIcon.png and the iOS app-icon PNG

# iPhone app (simulator)
xcodebuild -project iOS/FitMovie.xcodeproj -scheme FitMovie \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build/ios-dd build
xcrun simctl install booted build/ios-dd/Build/Products/Debug-iphonesimulator/FitMovie.app
xcrun simctl launch booted nl.petervanmanen.fitmovie
```

- `build_app.sh` reads `VERSION` and `BUILD_NUMBER` for Info.plist; CI sets them.
- The Mac app can be opened with files: `open -a build/FitMovie.app clip.mov activity.fit music.m4a`.
- On iOS:
  - Add a test clip to the simulator's Photos with `xcrun simctl addmedia booted clip.mov`.
  - Send a FIT file to the running app with `xcrun simctl openurl booted file:///path/run.fit`. This goes through "Open in" → `onOpenURL` → `importFile`.
- Installing on a real iPhone needs your own team: open the project in Xcode and set Signing & Capabilities → Team. Change the bundle ID `nl.petervanmanen.fitmovie` if it's taken.
- To see the Mac app, `screencapture -l <windowID>` works. Get the ID from `CGWindowListCopyWindowInfo` with a small Swift script. Don't use `osascript` with System Events: it hangs on an Automation permission prompt.
- Simulator driving tips:
  - Screenshots often lag one action behind, so take two.
  - A tap doesn't flip a SwiftUI `Toggle`; a short horizontal swipe across it does.
  - `simctl launch` can leave the app in the background; tap its home-screen icon.

## Layout

```
Sources/FitMovie/
  Shared/                       Compiled into BOTH apps (keep it free of AppKit/UIKit except behind #if)
    FIT/FITParser.swift         Low-level FIT decoder → [FITMessage] (numeric fields only)
    FIT/FITActivity.swift       OverlayMetric, FITSeries (interpolation/smoothing), FITActivity.decode
    Models/EditTimeline.swift   Trim/cut model, source↔output time mapping, formatTimecode
    Models/Settings.swift       FilterKind (CI filter chains), Filter/Stabilization/Overlay/Audio settings, export presets
    Models/Project.swift        Clip, ClipInput, ClipSegment, ProjectTimeline (combined timeline ↔ clip/source time)
    Models/EditorModel.swift    @MainActor ObservableObject: the single view model (clips, selection, player, rebuilds,
                                scrub, analysis, import/export requests, preview fallback). ImportKind lives here too.
    Models/PhotoLibrary.swift   iOS only: save the export to Photos
    Engine/SourceVideo.swift    Loads an asset: tracks, orientation, natural/display size, fps, codec, creation date
    Engine/EffectsCompositor.swift  Our AVVideoCompositing: orientation + per-frame CI render (used everywhere)
    Engine/CompositionBuilder.swift AVMutableComposition + effects composition + audio mix; VideoExporter
    Engine/FrameRenderer.swift  RenderSnapshot / RenderState (lock-protected) / per-frame pipeline
    Engine/Stabilizer.swift     Motion analysis (Vision), path smoothing, per-frame apply
    Engine/OverlayRenderer.swift  Draws the metric panel + graph with CoreGraphics/CoreText, cached
    UI/PlatformViews.swift      PlayerSurface (AVPlayerView / AVPlayerLayer), FileImportHandler, LimitedPreviewBadge
    UI/ClipsBar.swift           Clip chips in playback order (select, move, remove) + add tile; ClipActions menu
    UI/TimelineStrip.swift      Filmstrip of the SELECTED clip with trim handles, cuts, In/Out selection, playhead
    UI/InspectorView.swift      Tabbed panels: Trim, Stabilize, Filters, Audio, Export (+ ExportResultView)
    UI/OverlayPanel.swift       The "Data" (FIT overlay) panel
  Mac/
    FitMovieApp.swift          App, menu commands, AppDelegate (Finder "Open With" → model.handleDrop)
    MacContentView.swift        Window: preview, transport bar with keyboard shortcuts, inspector, drag & drop
iOS/
  FitMovie.xcodeproj           Hand-written project (objectVersion 77, synced folders, no shared scheme committed)
  Info.plist                    Document types + imported UTI nl.petervanmanen.fitmovie.fit (merged with generated keys)
  FitMovie/FitMoviePhoneApp.swift  App entry, AVAudioSession .playback, onOpenURL
  FitMovie/PhoneEditorView.swift    Phone layout, PhotosPicker import (PickedMovie), compact transport
  FitMovie/Assets.xcassets     AppIcon (generated, opaque 1024 px), AccentColor
Tests/FitMovieTests/           FITTests (+ FITWriter), TimelineTests, PipelineTests (synthetic video/audio/FIT)
scripts/                        build_app.sh, make_icon.swift
Resources/                      AppIcon.icns / AppIcon.png (generated; committed)
.github/workflows/build.yml     CI: macOS tests + app zip; iOS simulator compile check
.github/workflows/testflight.yml  Archive + upload to TestFlight (manual or v* tag); see docs/appstore/TESTFLIGHT.md
docs/appstore/                  Listing text, review notes, TestFlight setup, sample FIT files (scripts/make_sample_fit.swift)
docs/PRIVACY.md                 Privacy policy (linked from App Store Connect; keep it accurate)
```

## How it works

### Clips and time bases
- A project is `EditorModel.clips: [Clip]`, played in order. Each clip has its own `EditTimeline` (trim and cuts), thumbnails and `StabilizationAnalysis`.
- **Source time** is seconds in one clip's file. Trim points, cuts, stabilization, the FIT sync and the timeline strip use it.
- **Output time** is seconds in the combined movie, which is what the AVPlayer and the export use.
- `ProjectTimeline.segments` lists every clip's kept ranges back to back as `ClipSegment`s.
  - `locate(outputTime)` gives (clip, source time).
  - `outputTime(clipID:sourceTime:)` goes the other way; times inside removed parts snap to the next kept frame.
- **Selected clip:** `EditorModel.timeline`, `source`, `thumbnails` and `currentSourceTime` refer to the selected clip, so the Trim panel and timeline strip work unchanged. `timeline`'s setter writes back into `clips`.
  - During playback `followPlayhead` moves the selection to whichever clip is playing.
  - `currentOutputTime` is the position in the whole movie.
- **Frame size:** the first clip's display size (`ProjectTimeline.renderSize`). Other clips are fitted with black bars by `FrameRenderer.fit`, after stabilization (which works in the clip's own pixels) and before filters and the overlay.
- **Frame rate:** the highest of all clips.

### The edit pipeline
1. `CompositionBuilder.build(clips:)` creates an `AVMutableComposition`:
   - one video track holding every kept range of every clip, back to back;
   - one audio track with each clip's sound (its first non-spatial audio track);
   - the music, looped as needed, plus an `AVMutableAudioMix` for volumes and fades.
2. The video composition comes from `EffectsComposition.make(trackID:pieces:…)`: our own `AVVideoCompositing` class (`EffectsCompositor`) with one `EffectsInstruction` per kept range ("piece"). Each piece carries its clip's orientation and a render closure that already knows its clip ID and source start, so frames at clip boundaries are exact. For each frame the compositor:
   - takes the source pixel buffer (BGRA) and rotates it to display orientation with `orientationTransform`;
   - calls the piece's closure, which is `FrameRenderer.render(_:clipID:sourceTime:)`: stabilization, then fitting to the frame size, then the filter (blended by intensity), adjustments and vignette, then the overlay;
   - renders the result into the output buffer.
   - The composition track's `preferredTransform` is the first clip's; it only matters for the simulator's plain-playback fallback.
3. The same `EffectsComposition.make` is used for player, export, scrub previews (an `AVAssetImageGenerator` on the raw source) and stabilization analysis, so every path sees identically oriented frames.
4. **Colour is passed through, not managed.** The `CIContext` has `workingColorSpace: NSNull()`, input images are created with `.colorSpace: NSNull()`, rendering uses `colorSpace: nil`, and the source buffer's colour tags are copied to the output. An unfiltered frame is therefore bit-for-bit what the decoder gave. HDR clips come out tagged as HDR but rendered through an 8-bit BGRA buffer; true HDR preservation is still open.

### Settings reach the renderer without a rebuild
- `RenderState` holds an immutable `RenderSnapshot` behind a lock, and the compositor reads it on its own queue.
- `RenderSnapshot` holds the segments, per-clip `ClipInfo` (stabilization path, recording start), the frame size, the overlay graph window (span of all clips) and the project-wide settings. `RenderSnapshot.singleClip(...)` builds one for a single clip (tests).
- `EditorModel.pushSnapshot()` writes a new snapshot whenever filter, overlay, stabilization or FIT settings change, then calls `refreshFrame()`.
- `refreshFrame()` redraws the paused frame by assigning `item.videoComposition = vc.mutableCopy()`. ⚠️ This is still not confirmed by hand on a Mac or an iPhone. Check it first if a paused preview looks stale.
- Only changes to the timeline or audio rebuild the composition (debounced by 120 ms).

### Preview fallback (`previewIsLimited`)
The iOS 27 Simulator cannot play any `AVPlayerItem` that has a video composition. It fails with -12784, even with a plain `AVMutableVideoComposition(propertiesOf:)`, while export and image generation work. `EditorModel.watchForPlaybackFailure` detects the failed item and swaps in the plain edit without effects. It sets `previewIsLimited`, which:
- shows each paused or scrubbed frame with all effects, rendered through the scrub generator (`showStillFrame`);
- shows "Effects show when paused" during playback (`LimitedPreviewBadge`).

Export is unaffected. On a real device and on macOS the effects composition is expected to play normally, and the fallback never triggers. ⚠️ Live effects playback has not been verified on a physical iPhone.

### Scrubbing
While dragging on the timeline or a trim handle, the preview shows `scrubImage` from an `AVAssetImageGenerator` on the selected clip's raw source. There is one generator per clip, cached in `scrubGenerators`, and they are rebuilt when the frame size changes. They use `previewComposition(clipID:…)`, which renders at the project frame size, so effects and letterboxing show while scrubbing, even inside removed parts. Trim-handle drags keep a `pendingTimeline` and commit it when the drag ends.

### Import and export per platform
- `EditorModel.requestImport(kind)` sets `importRequest`, and `FileImportHandler` (`.fileImports(for:)`) shows SwiftUI's `fileImporter` on both platforms.
  - It allows multiple selection for videos.
  - `ImportKind.video` starts a new movie and `.clip` appends.
  - Videos without an explicit kind (drag & drop, "Open in") start a movie if there is none, and are appended otherwise.
  - `importFiles` loads videos one after another so the chosen order is kept.
- `importFile(_:as:)` copies the file on iOS, because picked URLs are security-scoped and only readable briefly. The copy goes to `tmp/Imported/<uuid>/<original name>`, and the original name is kept because it identifies GoPro and DJI clips.
- iOS also imports from Photos via `PhotosPicker` with `preferredItemEncoding: .current`, so HEVC is not transcoded and the creation date survives. `PickedMovie` is a `Transferable` that copies the file.
- `requestExport()`: on macOS this is an `NSSavePanel`; on iOS it renders into `tmp/Exports/`, after which `ExportResultView` offers Save to Photos (add-only permission) and a Share sheet.

### Stabilization
- **Per clip:** `analyzeStabilization()` analyzes every clip that has no analysis yet, in order, with progress across all clips. Clips added while stabilization is on are analyzed automatically. Paths are cached per clip in `stabilizationPaths` and cleared when strength or crop change.
- **Analysis** reads frames through the effects compositor at 640 px on the long side, using Lanczos downscaling because plain scaling aliases and reads as false motion. Vision's `VNTranslationalImageRegistrationRequest` runs with the previous frame as reference and the current frame as target, and the cumulative trajectory is stored in display pixels. Jumps larger than 25% of the width count as scene cuts and are ignored.
- **Path:** two box-filter passes with radius = strength × fps × 2 frames. The ends are extended by point reflection, so a steady pan stays a straight line instead of flattening at the clip ends. Then four passes clamp the correction to the crop margin and re-smooth it.
- **Apply** shifts the frame by the correction, zooms by `1/(1-maxCrop)` about the centre, and uses `clampedToExtent` and `cropped`.

### Overlay and FIT
- The FIT time for a frame is `clip's videoStartDate + sourceTime + overlay.timeOffset`.
  - `EditorModel.videoStartDates` gives each clip its own recording start.
  - A clip without a recording date is assumed to follow the previous one, and the first such clip uses the activity start.
  - "Align to Activity Start" aligns the first clip; the offset is shared by all clips.
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

## Releasing the iPhone app
- App Store Connect app: FitMovie, bundle ID `nl.petervanmanen.fitmovie`, team `9XCZUWMGXB`. Build 1 (version 1.0) was uploaded from this Mac.
- CI uploads: the TestFlight workflow archives **unsigned** (`CODE_SIGNING_ALLOWED=NO`), then `-exportArchive` with `-allowProvisioningUpdates` and the API key signs with Apple's cloud-managed distribution certificate.
  - This was verified locally: the exported IPA had an Apple Distribution signature, App Store entitlements and the overridden build number, and this Mac has no distribution certificate.
  - Build number = 100 + run number. A `v*` tag sets `MARKETING_VERSION`.
- Secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_API_KEY_P8` (Admin-role key). Never commit `.p8` files.
- The shared scheme `iOS/FitMovie.xcodeproj/xcshareddata/xcschemes/FitMovie.xcscheme` is required by `xcodebuild archive` on CI.

## Conventions
- Match the existing style: value-type settings, one `EditorModel`, panels as private SwiftUI structs, comments only where something is non-obvious.
- Keep the engine free of SwiftUI so it can be tested headless (`@testable import FitMovie`). Add a test for engine changes. `PipelineTests` shows how to generate synthetic video, audio and FIT data.
- Commit messages end with a `Co-Authored-By:` line. The repository is `git@github.com:petervanmanen/fitmovie.git` on branch `main`, and CI runs on every push.

## Known limitations / next steps
See the ⬜ and 🟡 items in [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md). The most important:
- Test on a real iPhone, including live effects playback, Save to Photos, and large 4K HEVC clips (memory and time).
- Try real iPhone, GoPro, DJI and Android clips, and real Suunto/Garmin FIT files.
- Preserve HDR. Notarize the Mac app. Add rotation stabilization.
