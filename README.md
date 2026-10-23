# ClipForge

A native macOS (15+) video editor for action and dive footage, built with SwiftUI, AVFoundation, Core Image and Vision.

Requirements and their status are in [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md). Architecture notes and gotchas for contributors (and Claude) are in [CLAUDE.md](CLAUDE.md).

## Features

- **Trim and cut**: drag the blue handles (or press `[` / `]`) to set the start and end. To remove a part in the middle, mark it with `I` / `O` and press ⌫. Removed parts can be restored from the Trim panel.
- **Data overlay from a FIT file**: heart rate, pace, speed, distance, elevation, temperature, elapsed time and, for dives, depth. You can choose the metrics, position, layout, size, colour, background, units and an optional profile graph. The data is synced to the video's recording date. You can set a fine offset, and there is a "camera clock is local time" option for GoPro and DJI.
- **Stabilization**: camera motion is measured with Vision translational image registration. The path is then smoothed, and the frame is shifted and zoomed so the edges stay hidden. *Smoothness* and *max crop* are adjustable.
- **Filters**: Extra Vivid, Black & White, Noir, Sepia, Chrome, Fade, Instant, Warm, Cool and Underwater Fix, each with an intensity setting. There are also brightness, contrast, saturation and vignette controls.
- **Audio**: background music with volume, start offset, looping and fade in/out. The volume of the original sound can be changed or muted.
- **Formats**: MOV and MP4 in HEVC or H.264, as recorded by iPhone, GoPro (MP4/LRV), DJI and Android. Export is HEVC or H.264 to MP4 or MOV.

You can drop videos, `.fit` files and music onto the window, or open them with the app from Finder.

## Build and run

```bash
./scripts/build_app.sh        # → build/ClipForge.app
open build/ClipForge.app
```

The app icon is drawn by `scripts/make_icon.swift` (`swift scripts/make_icon.swift` regenerates `Resources/AppIcon.icns`).

GitHub Actions (`.github/workflows/build.yml`) runs the tests and builds a universal `ClipForge.zip` on every push and pull request; download it from the run's artifacts. Pushing a `v*` tag (e.g. `v1.0`) also publishes it as a GitHub release.

Run the tests with `swift test`. They cover FIT decoding, trim math, and a full end-to-end export that checks stabilization reduces shake. You can also open `Package.swift` in Xcode.

## Layout

- `FIT/`: a FIT protocol decoder with no dependencies, plus the activity time series.
- `Engine/`: composition (trim/cut/audio mix), per-frame rendering (stabilization, filters, overlay), stabilization analysis and export.
- `Models/`: the edit timeline, settings and the editor view model.
- `UI/`: the SwiftUI views.

## License

MIT – see [LICENSE](LICENSE).
