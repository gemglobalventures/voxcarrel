# VoxCarrel

A native Mac app for managing a personal library of audiobooks and ebooks: a modern replacement for Calibre that treats audiobooks and ebooks as equals, with one entry per book whatever forms you own it in.

VoxCarrel files your books into a tidy folder layout, writes details and covers into the files themselves, and looks books up online. It manages files you already own; it is not a store or a downloader.

**Status:** early. It has been tested on generated sample books, not yet widely on real collections. Try it on copies first.

## What it does

- Imports audiobooks (M4B, M4A, MP3, including a folder of parts as one book) and ebooks (EPUB, PDF; MOBI and AZW3 are filed but never modified), by move or copy, through a review sheet.
- Keeps an audiobook, its ebook and companion files together as one book, in `Author/Series/Title` folders.
- Edits details and covers for one book or many, written into the files and checked before they replace the originals.
- Looks books up on Open Library and the Audible catalogue; you choose which fields to take.
- Tracks books you own on Audible alongside your local files, so a series shows complete.
- Read status, tags, ratings and collections; undo for the last operation; a check of the library at launch.

## Requirements

macOS 15 or later. Building needs the Swift 6 toolchain (Xcode 16 or later). There is no Xcode project; Xcode can open either `Package.swift` directly.

## Layout

- `VoxCarrelCore/` — the engine: scanning, filing, tags, the catalogue database, online lookup. No user interface.
- `VoxCarrelApp/` — the app: `VoxCarrelAppCore` holds everything the window shows and does (tested without a window); `VoxCarrel` holds the SwiftUI views, which contain no logic.

## Build

```bash
VoxCarrelApp/Scripts/build-app.sh
```

This produces `VoxCarrelApp/build/VoxCarrel.app`, a release build signed for this Mac only. Pass `debug` for a debug build.

## Try it on a demo library

Nothing here touches real books. The demo tool generates sample audiobooks and ebooks. Run these from `VoxCarrelApp/`:

```bash
swift run voxcarrel-demo library ~/VoxCarrelDemo/Library
swift run voxcarrel-demo inbox ~/VoxCarrelDemo/Inbox
open build/VoxCarrel.app --args -libraryPath ~/VoxCarrelDemo/Library
```

- `library <folder>` makes a library of sample books already imported. Add `--count 2000` for a large one.
- `inbox <folder>` makes a folder of loose files to drag onto the window.
- `-libraryPath <folder>` opens that library for this launch without changing the remembered one.

## First run on real books

Create a new, empty folder for the library. Import a handful of books with "Copy files, leave originals in place" ticked, and check the result before importing more.

## Tests

```bash
VoxCarrelApp/Scripts/test-all.sh
VoxCarrelApp/Scripts/smoke-launch.sh
```

`test-all.sh` runs both packages' tests as debug and as optimised builds. `smoke-launch.sh` builds the app, opens it on a fresh temporary demo library, checks it stays running, and quits it. Tests never use the network; lookup tests run on recorded answers.

## Online lookup and privacy

Look Up sends the title, author, ISBN or Audible ID you search for to Open Library and Audible, and downloads cover images from them. Nothing is sent until you press Look Up. The Audible catalogue search is an unofficial interface and may change. VoxCarrel does not sign in to any account.

## Licence

VoxCarrel is free software, released under the [GNU Affero General Public License, version 3](LICENSE). You may use, study, change and share it; anything built from it must be shared under the same licence, including when it is offered to others over a network.

Copyright © 2026 the VoxCarrel authors.
