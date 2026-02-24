import SwiftUI
import AppKit

// MARK: - Models

struct VolumeInfo: Identifiable, Equatable {
    let id: String // mount point
    let name: String
    let mountPoint: String
    let totalBytes: Int64
    let freeBytes: Int64
    let isBootVolume: Bool
    let isRemovable: Bool
    let isNetwork: Bool

    var usedBytes: Int64 { totalBytes - freeBytes }
    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }

    var usedFormatted: String { formatBytes(usedBytes) }
    var freeFormatted: String { formatBytes(freeBytes) }
    var totalFormatted: String { formatBytes(totalBytes) }

    var category: VolumeCategory {
        if isBootVolume { return .boot }
        if isNetwork { return .network }
        if isRemovable { return .removable }
        return .internal
    }

    var statusColor: Color {
        if usedPercent >= 90 { return .red }
        if usedPercent >= 75 { return .orange }
        return Color(red: 0.22, green: 0.59, blue: 0.55) // teal green
    }

    var statusIcon: String {
        switch category {
        case .boot: return "internaldrive.fill"
        case .internal: return "internaldrive"
        case .removable: return "externaldrive.fill"
        case .network: return "network"
        }
    }
}

enum VolumeCategory: String, CaseIterable {
    case boot = "Boot"
    case `internal` = "Internal"
    case removable = "External"
    case network = "Network"

    var sortOrder: Int {
        switch self {
        case .boot: return 0
        case .internal: return 1
        case .removable: return 2
        case .network: return 3
        }
    }
}

// MARK: - Volume Scanner

@Observable
class VolumeScanner {
    var volumes: [VolumeInfo] = []
    var lastScan: Date = Date()
    private var timer: Timer?

    init() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    deinit {
        timer?.invalidate()
    }

    func scan() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
        ]

        guard let mountedVolumes = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return }

        let bootVolume = "/" // always the boot volume on macOS

        var scanned: [VolumeInfo] = []

        for url in mountedVolumes {
            let path = url.path
            // Skip system/snapshot volumes
            if path.hasPrefix("/System") { continue }
            if path.contains("/Volumes/com.apple") { continue }
            if path == "/dev" { continue }

            guard let attrs = try? fm.attributesOfFileSystem(forPath: path) else { continue }
            guard let totalSize = attrs[.systemSize] as? Int64,
                  totalSize > 0 else { continue }

            // Use "important usage" capacity if available (more accurate on APFS)
            let freeSize: Int64
            if let resourceValues = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let importantCapacity = resourceValues.volumeAvailableCapacityForImportantUsage {
                freeSize = importantCapacity
            } else if let free = attrs[.systemFreeSize] as? Int64 {
                freeSize = free
            } else {
                continue
            }

            let name: String
            if let resourceValues = try? url.resourceValues(forKeys: [.volumeNameKey]),
               let volumeName = resourceValues.volumeName {
                name = volumeName
            } else {
                name = url.lastPathComponent
            }

            let isRemovable: Bool
            let isLocal: Bool
            if let rv = try? url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsLocalKey]) {
                isRemovable = rv.volumeIsRemovable ?? false
                isLocal = rv.volumeIsLocal ?? true
            } else {
                isRemovable = false
                isLocal = true
            }

            let info = VolumeInfo(
                id: path,
                name: name,
                mountPoint: path,
                totalBytes: totalSize,
                freeBytes: freeSize,
                isBootVolume: path == bootVolume,
                isRemovable: isRemovable,
                isNetwork: !isLocal
            )
            scanned.append(info)
        }

        // Sort: boot first, then by category, then by name
        scanned.sort { a, b in
            if a.category.sortOrder != b.category.sortOrder {
                return a.category.sortOrder < b.category.sortOrder
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        volumes = scanned
        lastScan = Date()
    }

    var bootVolume: VolumeInfo? {
        volumes.first { $0.isBootVolume }
    }

    var menuBarText: String {
        guard let boot = bootVolume else { return "?" }
        return "\(Int(boot.usedPercent))%"
    }

    var menuBarColor: Color {
        bootVolume?.statusColor ?? .gray
    }

    var totalFreeFormatted: String {
        guard let boot = bootVolume else { return "—" }
        return boot.freeFormatted
    }
}

// MARK: - Formatting

func formatBytes(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1000 {
        return String(format: "%.1f TB", gb / 1024)
    }
    if gb >= 100 {
        return String(format: "%.0f GB", gb)
    }
    if gb >= 10 {
        return String(format: "%.1f GB", gb)
    }
    if gb >= 1 {
        return String(format: "%.2f GB", gb)
    }
    let mb = Double(bytes) / 1_048_576
    return String(format: "%.0f MB", mb)
}

// MARK: - App

@main
struct DiskPulseApp: App {
    @State private var scanner = VolumeScanner()

    var body: some Scene {
        MenuBarExtra {
            PopupView(scanner: scanner)
                .frame(width: 340)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 11))
                Text(scanner.menuBarText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Popup View

struct PopupView: View {
    let scanner: VolumeScanner
    @State private var hoveredVolume: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))

            if scanner.volumes.isEmpty {
                emptyState
            } else {
                volumeList
            }

            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("DiskPulse")
                .font(.system(size: 14, weight: .bold))
            Spacer()
            Button {
                scanner.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Volume List

    private var volumeList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(groupedVolumes, id: \.0) { category, vols in
                    if scanner.volumes.count > 1 {
                        sectionHeader(category)
                    }
                    ForEach(vols) { volume in
                        VolumeRow(
                            volume: volume,
                            isHovered: hoveredVolume == volume.id
                        )
                        .onHover { isHovered in
                            hoveredVolume = isHovered ? volume.id : nil
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 400)
    }

    private var groupedVolumes: [(VolumeCategory, [VolumeInfo])] {
        let grouped = Dictionary(grouping: scanner.volumes) { $0.category }
        return VolumeCategory.allCases
            .compactMap { cat in
                guard let vols = grouped[cat], !vols.isEmpty else { return nil }
                return (cat, vols)
            }
    }

    private func sectionHeader(_ category: VolumeCategory) -> some View {
        HStack(spacing: 4) {
            Text(category.rawValue.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "internaldrive.trianglebadge.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No volumes found")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let boot = scanner.bootVolume {
                Text("\(boot.freeFormatted) free")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Updated \(scanner.lastScan, style: .relative) ago")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Divider().frame(height: 10)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 11))
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Volume Row

struct VolumeRow: View {
    let volume: VolumeInfo
    let isHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Name + icon row
            HStack(spacing: 6) {
                Image(systemName: volume.statusIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(volume.statusColor)
                    .frame(width: 16)

                Text(volume.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                if volume.isBootVolume {
                    Text("BOOT")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(volume.statusColor, in: RoundedRectangle(cornerRadius: 3))
                }

                Spacer()

                Text("\(Int(volume.usedPercent))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(volume.statusColor)
            }

            // Usage bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(volume.statusColor.opacity(0.8))
                        .frame(width: geo.size.width * CGFloat(min(volume.usedPercent, 100)) / 100.0)
                }
            }
            .frame(height: 6)

            // Details row
            HStack(spacing: 0) {
                Text("\(volume.usedFormatted) used")
                    .foregroundStyle(.secondary)
                Text(" / ")
                    .foregroundStyle(.quaternary)
                Text("\(volume.freeFormatted) free")
                    .foregroundStyle(volume.usedPercent >= 90 ? Color.red.opacity(0.8) : .secondary)
                Text(" / ")
                    .foregroundStyle(.quaternary)
                Text("\(volume.totalFormatted) total")
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .font(.system(size: 10))

            // Mount point (on hover)
            if isHovered {
                Text(volume.mountPoint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: volume.mountPoint)
        }
    }
}
