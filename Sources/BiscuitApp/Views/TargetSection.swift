import BiscuitKit
import SwiftUI

/// Step 2: choose the device to overwrite.
///
/// Only removable, non-system devices are selectable. Ineligible devices are
/// still listed, greyed out and with the reason spelled out, because silently
/// omitting the user's drive reads as a bug and invites them to go looking for a
/// workaround in Terminal.
struct TargetSection: View {
    @Environment(AppEnvironment.self) private var env

    private var coordinator: JobCoordinator { env.coordinator }
    private var monitor: DeviceMonitor { env.monitor }

    var body: some View {
        SectionCard(
            title: t(.targetSectionTitle),
            systemImage: "externaldrive",
            subtitle: t(.targetSectionSubtitle)
        ) {
            if let error = monitor.lastError {
                CalloutView(kind: .warning, text: error.message, detail: error.diagnostics)
            }

            if monitor.eligibleDevices.isEmpty {
                emptyState
            } else {
                VStack(spacing: 6) {
                    ForEach(monitor.eligibleDevices) { device in
                        DeviceRow(
                            device: device,
                            isSelected: coordinator.selectedDeviceBSDName == device.bsdName,
                            requiredBytes: requiredBytes
                        ) {
                            coordinator.selectedDeviceBSDName = device.bsdName
                        }
                    }
                }
            }

            if !monitor.blockedDevices.isEmpty {
                DisclosureGroup {
                    VStack(spacing: 6) {
                        ForEach(monitor.blockedDevices) { device in
                            BlockedDeviceRow(device: device)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text(t(.targetBlockedCount, monitor.blockedDevices.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var requiredBytes: UInt64? {
        guard coordinator.strategy != .eraseOnly else { return nil }
        return coordinator.source?.requiredCapacityBytes
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(t(.targetNoneAttached))
                .font(.callout)
            Text(t(.targetNoneAttachedHint))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }
}

// MARK: - Rows

private struct DeviceRow: View {
    let device: StorageDevice
    let isSelected: Bool
    let requiredBytes: UInt64?
    let onSelect: () -> Void

    private var isTooSmall: Bool {
        guard let requiredBytes else { return false }
        return device.sizeBytes < requiredBytes
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)

                Image(systemName: device.bus == .sdCard ? "sdcard" : "externaldrive.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(ByteCount.format(device.sizeBytes))
                        Text("·")
                        Text(device.bus.displayName)
                        Text("·")
                        Text(device.bsdName)
                        if let volumes = device.volumeSummary {
                            Text("·")
                            Text(volumes).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if isTooSmall {
                    Label(t(.targetBadgeTooSmall), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
                if device.exceedsPlausibleFlashSize {
                    Label(t(.targetBadgeVeryLarge), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel(
            "\(device.displayName), \(ByteCount.format(device.sizeBytes)), \(device.bus.displayName)"
        )
    }
}

private struct BlockedDeviceRow: View {
    let device: StorageDevice

    private var reason: String {
        if device.isSystemDisk { return t(.targetBlockedSystemDisk) }
        if !device.isWritable { return t(.targetBlockedReadOnly) }
        if device.bus == .internalDrive { return t(.targetBlockedInternal) }
        if device.bus == .virtual { return t(.targetBlockedVirtual) }
        if device.bus == .thunderbolt { return t(.targetBlockedThunderbolt) }
        if device.sizeBytes == 0 { return t(.targetBlockedNoMedia) }
        return t(.targetBlockedNotRemovable)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(device.displayName)
                .font(.caption)
                .lineLimit(1)
            Text("·")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(ByteCount.format(device.sizeBytes))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .separatorColor).opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
    }
}
