# imp-rec

Lightweight macOS menu bar screen recorder.

## Build

```bash
xcodebuild -project imp-rec.xcodeproj -scheme imp-rec -configuration Debug build
```

## Run

```bash
open build/Debug/imp-rec.app
# Or open imp-rec.xcodeproj in Xcode and hit Cmd+R
```

## Architecture

- **Menu bar only** — `LSUIElement = true`, no Dock icon, no main window
- **Left-click** status item → toggle recording (start/stop)
- **Right-click** status item → context menu (quit)
- **ScreenCaptureKit** → `AVAssetWriter` (H.264 .mov) → `~/Movies/imp-rec/`
- Post-recording popover with video preview and "Reveal in Finder"

## Key files

| File | Purpose |
|------|---------|
| `ImpRecApp.swift` | `@main` entry point |
| `AppDelegate.swift` | `NSStatusItem` setup, click handling, popover |
| `ScreenRecorder.swift` | ScreenCaptureKit capture + AVAssetWriter |
| `RecordingPopoverView.swift` | Post-recording SwiftUI popover |
