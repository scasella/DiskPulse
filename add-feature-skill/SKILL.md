---
name: add-feature-skill
description: >
  Guide for adding new features to DiskPulse. Covers architecture,
  extension points, patterns, and build process.
---

## Overview

DiskPulse is a macOS menu bar app that monitors mounted disk volumes, showing usage percentages with color-coded bars and boot volume stats in the menu bar.

## Architecture

DiskPulse is a single-file SwiftUI menu bar app (`DiskPulse.swift`, ~443 lines). The `@main` struct `DiskPulseApp` owns a `@State VolumeScanner` instance as the single source of truth. The scanner uses `FileManager.mountedVolumeURLs` (no shell commands) to discover volumes every 30 seconds, reads their capacity via `attributesOfFileSystem` and URL resource values, and exposes a sorted volume list. The popup UI renders inside a `MenuBarExtra(.window)` scene.

State flows one way: `VolumeScanner` holds all mutable state (`volumes`, `lastScan`), views read from it directly, and user actions call scanner methods. The `@Observable` macro on `VolumeScanner` drives SwiftUI updates automatically.

## Key Types

- **`VolumeInfo`** (struct, Identifiable, Equatable) -- Represents a mounted volume. Fields: `id` (mount point path), `name`, `mountPoint`, `totalBytes`, `freeBytes`, `isBootVolume`, `isRemovable`, `isNetwork`. Computed properties: `usedBytes`, `usedPercent`, `usedFormatted`, `freeFormatted`, `totalFormatted`, `category`, `statusColor`, `statusIcon`.
- **`VolumeCategory`** (enum, CaseIterable, 4 cases: `boot`, `internal`, `removable`, `network`) -- Categorizes volumes by their mount properties. Provides a `sortOrder` for display ordering (boot first, then internal, removable, network).
- **`VolumeScanner`** (@Observable class) -- Core scanner. Reads `FileManager.mountedVolumeURLs` with `.skipHiddenVolumes`, queries resource keys for capacity and volume type, filters out system/snapshot volumes, and sorts by category then name. Exposes `bootVolume`, `menuBarText` (boot disk usage %), and `menuBarColor`.
- **`PopupView`** (View) -- Main popup with header, grouped volume list (sections by category), empty state, and footer. Tracks `@State hoveredVolume` for hover effects.
- **`VolumeRow`** (View) -- Renders a single volume with status icon, name, boot badge, usage percentage, colored usage bar (via `GeometryReader`), size breakdown, and hover-to-reveal mount point. Tap opens the volume in Finder via `NSWorkspace.shared.selectFile`.

## How to Add a Feature

1. **Add model fields** -- If your feature needs new data, add properties to `VolumeInfo`. Update the initializer in `scan()` where `VolumeInfo` instances are created. You may need to add new `URLResourceKey` entries to the `keys` array.
2. **Extend the scanner** -- Add state properties to `VolumeScanner` (they will automatically be observable). Add methods for any new logic (e.g., threshold checking, alerts).
3. **Add UI** -- Create a new view or add elements to `VolumeRow`/`PopupView`. Follow the existing section pattern with category headers and dividers.
4. **Wire into PopupView** -- Insert your new section in the `VStack(spacing: 0)` body of `PopupView`, between appropriate `Divider()` calls, or extend `VolumeRow` with additional rows of information.
5. **Rebuild** -- Run `bash build.sh` to compile and package.

## Extension Points

- **New VolumeCategory cases** -- Add a case to the enum with a `sortOrder`, update the `category` computed property on `VolumeInfo`, and add a corresponding `statusIcon` entry.
- **Alerts and thresholds** -- Add threshold properties to `VolumeScanner` (e.g., `alertThreshold: Double = 90`). Check `usedPercent` in `scan()` and trigger `UserNotifications` (import `UserNotifications` first -- not currently imported). The color thresholds in `statusColor` (75% orange, 90% red) provide a pattern to follow.
- **Per-volume actions** -- Follow the tap-to-open-in-Finder pattern in `VolumeRow` (`.onTapGesture` calling `NSWorkspace`). Add context menu items or additional buttons for actions like eject (removable volumes) or open Terminal at path.
- **Poll frequency** -- The timer interval is `30.0` in `VolumeScanner.init()`. Add a configurable property or a UI control to let users adjust it.
- **New data sources** -- The `scan()` method can be extended to read additional `URLResourceKey` values (e.g., `.volumeIsEncryptedKey`, `.volumeSupportsFileCloningKey`) and surface them in `VolumeInfo`.
- **Summary statistics** -- Add computed properties on `VolumeScanner` like `totalUsedBytes`, `totalCapacity`, or per-category aggregates for display in the header or footer.

## Conventions

- **Naming**: Types use PascalCase, properties use camelCase. The `internal` category case uses backtick escaping since it is a Swift keyword.
- **SF Symbols**: All icons use SF Symbols (e.g., `"internaldrive.fill"`, `"externaldrive.fill"`, `"network"`). Filled variants for primary/boot volumes.
- **@Observable**: `VolumeScanner` is the single `@Observable` class. `PopupView` receives it as a plain `let` property (read-only). No `@Published` -- the `@Observable` macro handles change tracking.
- **Hover pattern**: `PopupView` tracks `@State hoveredVolume: String?` and passes `isHovered` to each `VolumeRow`. The row uses it to reveal the mount point and change background color.
- **Color thresholds**: `statusColor` on `VolumeInfo` returns red at >=90%, orange at >=75%, and teal green otherwise. Usage bars use `.opacity(0.8)` on the fill color.
- **Menu bar label**: Shows boot volume usage percentage via `menuBarText`. Keep it compact -- the menu bar has limited space.
- **No shell commands**: DiskPulse uses only `FileManager` APIs, not subprocess calls. Maintain this pattern for reliability and sandboxing compatibility.

## Build & Test

Run `bash build.sh` from the repo root. This invokes `swiftc -parse-as-library -O` to compile `DiskPulse.swift` into a macOS app bundle with `LSUIElement=true` (no Dock icon). The output is `DiskPulse.app`. No Xcode project is needed. Requires macOS 14.0+.
