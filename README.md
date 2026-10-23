# Halu Converter

A macOS file converter that lives in the background. Drag any file, hold **⇧ Shift**, and a flower of actions blooms under the cursor; drop on a petal and the result lands next to the original. No window needed. Everything runs locally.

## Ways to open the wheel

- **Drag + Shift**: start dragging a file anywhere (Finder, Desktop, Mail…), then hold Shift. The key can be changed from the menu bar icon.
- **Right-click → Quick Actions / Services → Convert with Halu**: the wheel opens at the cursor; click a petal or press 1–9, Esc closes.
- **Open With → Halu Converter**: same as above.
- **The full window**: menu bar icon → Open Halu Converter, or drop on the wheel's center. Use it for batches and detailed settings.

The moons under the flower work for any file: **AirDrop**, **ZIP** and **Copy Path**.

## What it converts

| Files | Petals |
|-------|--------|
| Images | JPEG, PNG, HEIC, AVIF, compress, resize, to PDF |
| PDF | Compress (two levels), split pages, pages to PNG/JPEG, merge |
| Video | 720p, HEVC, MP4 ⇄ MOV, GIF, extract audio |
| Audio | M4A, FLAC, ALAC, WAV, AIFF, CAF |
| Documents | PDF, Word, Pages, Markdown, Text, RTF, HTML, ODT, DOC |
| Slides | PDF, PowerPoint, Keynote, PNG/JPEG slides |
| Spreadsheets | Excel, Numbers, CSV, TSV, PDF |
| Archives | Extract ZIP, RAR, 7Z, TAR, GZ; pack folders into ZIP or TAR.GZ |
| Subtitles | SRT, VTT, TXT |
| Logos & drawings | SVG, PDF, Illustrator (.ai), PNG/JPEG → DXF sketch for CAD |

**DXF sketches** open in Shapr3D, Fusion, Onshape and other CAD apps as editable sketches (each closed outline is its own region, ready to extrude). SVG, PDF and .ai keep their exact curves (cubic splines, circles as circles); PNG/JPEG are traced (background and up to 8 colours found automatically, sharp corners kept). Options: width in mm, one file / a file per colour / a file per piece, smooth splines or polylines. Text must be converted to outlines first.

Office and text formats convert natively. Pages, Keynote and Numbers files (and Word → PDF, for the best layout) are converted by the iWork apps in the background; macOS asks once for permission to control them.

## Build

Needs macOS 15+ and the Swift toolchain (Command Line Tools is enough).

```bash
./build.sh            # → build/Halu Converter.app
./build.sh --install  # also installs to /Applications
```

On first launch the app adds itself to Login Items (toggle in the menu bar icon).

## Layout

- `Wheel.swift`: drag detection (`DragWatcher` polls the system drag pasteboard, no Accessibility permission needed), the floating panel, the petal flower.
- `QuickActions.swift`: which petals and moons each file type gets.
- `ImageEngine`, `PDFEngine`, `MediaEngine`, `DocumentEngine` (incl. iWork automation, Markdown), `ArchiveEngine` (archives, subtitles): the processing.
- `SketchEngine` (→ DXF): `SVGImporter`, `PDFVectorImporter` (CGPDFScanner), `Tracer` (bitmap tracing), `Sketch` (geometry, pieces), `DXFWriter` (AC1015, mm).
- `Toast.swift`: the progress card at the bottom of the screen.
- `AppModel.swift`, `ContentView.swift`, `OptionsCard.swift`: the full window.
