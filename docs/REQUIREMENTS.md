# FitMovie requirements

FitMovie is a video editor for action and dive footage, for macOS and iPhone. This file lists what the owner asked for and how each item is met. Status: ✅ done and tested · 🟡 done, not fully verified · ⬜ not done.

## Original brief

The owner asked for a Mac video app that can:

1. Trim a video, removing parts at the start, the end or in the middle.
2. Overlay data: load a FIT file and display heart rate, pace, or depth for a dive activity. The overlay must be configurable.
3. Stabilize: use an algorithm to stabilize the video, with a configurable amount.
4. Filters: black and white, sepia, extra vivid, and similar.
5. Support the normal video file types from iPhone, DJI, GoPro and Android.
6. Audio: let the user add background audio.

Later requests:

7. An app icon.
8. A GitHub Actions workflow that builds the app.
9. Project documentation detailed enough for another Claude to continue the work (this file and `CLAUDE.md`).
10. An open-source license (MIT).
11. An iPhone version.

## Requirements in detail

### R1 Trim and cut ✅
- Set the start and end by dragging handles on the timeline, with `[` / `]`, or with "Set to Playhead".
- Remove any number of middle parts: mark In (`I`) and Out (`O`), then press ⌫ or "Remove Selection". Overlapping cuts merge.
- Removed parts are listed in the Trim panel and can be restored one by one. "Reset All Edits" clears everything.
- The timeline always shows the whole source clip, with trimmed and removed areas shaded. The player plays the edited result.
- Scrubbing shows any source frame, including frames inside removed parts.
- Covered by: `TimelineTests.testTrimAndCuts`, `PipelineTests.testFullPipelineExport`.

### R2 FIT data overlay ✅
- Reads `.fit` files from Suunto, Garmin, Coros and others with a decoder written for this project (no dependencies). It handles compressed timestamps, developer fields, big- and little-endian records and chained files.
- Metrics: heart rate, pace, speed, depth, distance, temperature, elevation and elapsed time. Only metrics present in the file are offered.
- Dives are detected (sport 53, or any depth data) and default to depth, heart rate, temperature and a depth profile.
- Configurable: which metrics to show, corner position, stacked or in-a-row layout, size, text colour, background opacity, metric or imperial units, and an optional profile graph of one metric with a current-time marker.
- Sync: the video's recording date plus a user offset (slider, field, stepper, ±1 h, and "Align to Activity Start"). The "camera clock is local time" toggle exists because GoPro and DJI store local time with no time zone. It defaults to on for `GX*`, `GH*`, `GOPR*`, `GP*` and `DJI_*` files and uses the FIT file's UTC offset.
- Covered by: `FITTests`, plus the overlay in `PipelineTests` (checked visually: 150 bpm, 5:00 /km).
- 🟡 Not yet tried with a real Suunto, Garmin or dive FIT file.

### R3 Stabilization ✅
- Two passes. First, measure camera translation between frames with `VNTranslationalImageRegistrationRequest` on downscaled (640 px), correctly oriented frames. Then, at render time, shift each frame toward a smoothed path and zoom in to hide the edges.
- Configurable: Smoothness (averaging window up to about ±2 s) and Max crop (2–25%). The correction is limited so edges never show.
- The ends of the camera path are extended by point reflection, so a steady pan is kept rather than flattened.
- Covered by: `TimelineTests.testStabilizationPathStaysInsideCrop` and `PipelineTests.testStabilizationRemovesShakeButKeepsPan` (shake 33 → 0.9; pan −268 → −254 px).
- ⬜ Rotation and rolling shutter are not corrected; it handles translation only.

### R4 Filters ✅
- Original, Extra Vivid, Black & White, Noir, Sepia, Chrome, Fade, Instant, Warm, Cool and Underwater Fix (restores red in dive footage). Each has an intensity setting.
- Adjustments: brightness, contrast, saturation and vignette.
- The Filters panel shows a thumbnail preview of each filter on a frame from the clip.

### R5 Video formats ✅ / 🟡
- Opens anything AVFoundation can decode: MOV and MP4 in HEVC (including 10-bit) or H.264, plus `.lrv`, `.m4v`, `.3gp` and `.mts`. Orientation (portrait iPhone video) is kept.
- iPhone spatial-audio (APAC) tracks are skipped in favour of a normal audio track. GoPro timecode and GPMF metadata tracks are ignored.
- Export: HEVC or H.264 at original size, 4K, 1080p or 720p, as MP4 or MOV.
- Tested only with generated HEVC clips. All four recording orientations (0°, 90°, 180°, 270°) match AVFoundation's own rotation (`testCompositorOrientationMatchesAVFoundation`).
- 🟡 Not yet tried with real iPhone, GoPro, DJI or Android files.
- ⬜ HDR (iPhone Dolby Vision or HLG) comes out as SDR.

### R6 Background audio ✅
- Add an MP3, M4A/AAC, WAV, AIFF, CAF or FLAC file by button or drag-and-drop.
- Music volume, start offset within the track, loop to fill the video, fade in and fade out. Original sound volume can be changed or muted.
- Covered by: `PipelineTests` (looped music track present in the export).

### R7 App icon ✅
- Drawn in code by `scripts/make_icon.swift`, which outputs `Resources/AppIcon.icns` and `Resources/AppIcon.png`. The design is an ocean gradient, film strip, play button and red heart-rate trace.

### R8 CI build ✅
- `.github/workflows/build.yml` runs on the `macos-15` runner. It runs `swift test`, builds the universal app and uploads `FitMovie.zip`. A `v*` tag also creates a GitHub release. A second job compiles the iPhone app for the simulator.
- 🟡 The tag-release path has never been run.

### R10 License ✅
- MIT, in `LICENSE`.

### R11 iPhone version ✅ / 🟡
- Same engine and editing panels as the Mac app (shared source), in a phone layout: preview, transport, timeline, and the tabbed panels below. Portrait only, iPhone only (no iPad layout yet).
- Import: from Photos (keeps HEVC and the recording date), from Files, or "Open in FitMovie" from other apps. A `.fit` from the Suunto app can be shared straight to FitMovie.
- Export: rendered into a temporary file, then Save to Photos or Share.
- Verified in the iOS 27 Simulator: Photos import, filters, the FIT overlay from "Open in", stabilization analysis, and export.
- 🟡 The simulator can't play video with effects (an Apple simulator limitation). The app then plays the plain edit and shows effects on the paused frame. Live effects playback on a real iPhone is expected to work but hasn't been tested.
- 🟡 Not yet run on a physical iPhone, which needs your own signing team in Xcode. Memory and time for long 4K clips are unknown.
- ⬜ App Store distribution.

## Non-functional
- macOS 15 or later, universal binary (arm64 and x86_64). iOS 18 or later on iPhone.
- Signed ad-hoc only. ⬜ Not notarized, so other people's Macs will block it in Gatekeeper.
- No third-party dependencies.

## Ideas not yet requested
- Rotation-aware stabilization, for example using the angle from `VNHomographicImageRegistrationRequest`. It was unreliable on synthetic test images and needs real footage to evaluate.
- A GPS map overlay from FIT position data (fields 0 and 1 of the record message are not decoded yet).
- Saving and reopening projects.
- Joining several clips into one video.
