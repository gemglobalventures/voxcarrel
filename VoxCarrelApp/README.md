# VoxCarrel app

The Mac app. All logic lives in `Sources/VoxCarrelAppCore` (tested); `Sources/VoxCarrel` holds the SwiftUI views. The engine is the sibling package `../VoxCarrelCore`.

## Build

```bash
Scripts/build-app.sh
```

This produces `build/VoxCarrel.app` (release build, signed for this Mac only). Pass `debug` for a debug build. There is no Xcode project; Xcode can open `Package.swift` directly if you want to browse or debug.

## Try it on a demo library

Nothing here touches real books. The demo tool generates sample audiobooks and ebooks.

```bash
swift run voxcarrel-demo library ~/VoxCarrelDemo/Library
swift run voxcarrel-demo inbox ~/VoxCarrelDemo/Inbox
open build/VoxCarrel.app --args -libraryPath ~/VoxCarrelDemo/Library
```

- `library <folder>` makes a library of 12 books already imported. Add `--count 2000` for a large one.
- `inbox <folder>` makes a folder of loose files to drag onto the window.
- `-libraryPath <folder>` opens that library for this launch without changing the remembered one.

## Tests

```bash
swift test
Scripts/smoke-launch.sh
```

`Scripts/test-all.sh` runs both packages' tests as debug and as optimised builds; run it before calling anything done.

`smoke-launch.sh` builds the app, opens it on a fresh temporary demo library, checks it stays running, and quits it.

## First run on real books

Create a new, empty folder for the library. Import a handful of books with "Copy files, leave originals in place" ticked, and check the result before importing more.

## Online lookup

Look Up (inspector, Book menu, import sheet) searches Open Library and the Audible catalogue. Nothing is sent until you press it. Choose your Audible country in Settings. Tests never use the network; they run on recorded answers in `VoxCarrelCore/Tests/VoxCarrelCoreTests/Fixtures/Lookup`.
