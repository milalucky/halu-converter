# Halu Converter

Native macOS file converter: drop files, pick an action. Everything runs locally on Apple frameworks (PDFKit, ImageIO, AVFoundation), with no third-party dependencies.

## Quick wheel

Start dragging any file (Finder, Desktop, any app), then hold **⇧ Shift**. A wheel opens under the cursor with actions for that file type; drop on a slice and the result lands next to the original, with a small progress card at the bottom of the screen. Drop on the center to open the files in the main window. The key can be changed in the menu bar icon or on the main screen. The app keeps running in the menu bar after the window is closed.

How it works: `DragWatcher` (in `Wheel.swift`) polls the system drag pasteboard and the modifier keys 30 times a second, so no Accessibility permission is needed. Wheel slices per file type are defined in `QuickActions.swift`.

## Everything

| Files  | Actions |
|--------|---------|
| Images | Convert (JPEG, PNG, HEIC, AVIF, TIFF, GIF, BMP), compress, resize |
| PDF    | Combine (PDFs + images), split (every page / ranges), compress (3 levels), export pages as images |
| Video  | Compress (480p–4K, H.264/HEVC), MP4 ⇄ MOV, video → GIF, extract audio |
| Audio  | Convert to M4A, WAV, AIFF, CAF |

## Build

Needs macOS 14+ and the Swift toolchain (Command Line Tools is enough, Xcode not required).

```bash
./build.sh            # → build/Halu Converter.app
./build.sh --install  # also copies it to /Applications
```

Files can be dropped onto the window or the Dock icon, or opened with **Open With → Halu Converter**.

## Layout

- `Sources/HaluConverter/ImageEngine.swift`, `PDFEngine.swift`, `MediaEngine.swift`: the processing.
- `Models.swift`: file kinds, the `Tool` list, which tool accepts which files, settings.
- `AppModel.swift`: state, job queue, `Processor` that dispatches a tool to an engine.
- `ContentView.swift`, `Components.swift`, `OptionsCard.swift`: the UI.

To add a tool: add a case to `Tool` (title, icon, `accepts`), its options in `OptionsCard`, and a branch in `Processor.run`.
