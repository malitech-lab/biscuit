import BiscuitKit
import SwiftUI

/// Replaces the form while a job runs.
struct ProgressSection: View {
    @Environment(AppEnvironment.self) private var env

    private var coordinator: JobCoordinator { env.coordinator }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if coordinator.state == .awaitingAuthorisation {
                SectionCard(title: t(.progressAuthorisationTitle), systemImage: "lock.shield") {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t(.progressAwaitingAdmin))
                                .font(.callout)
                            Text(t(.progressAwaitingAdminDetail))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            SectionCard(title: t(.progressSectionTitle), systemImage: "gauge.with.needle") {
                VStack(alignment: .leading, spacing: 14) {
                    overallBar
                    PhaseStepper(
                        phases: coordinator.phasePlan,
                        current: coordinator.currentPhase,
                        completed: coordinator.completedPhases
                    )
                    statistics
                }
            }

            if coordinator.isCancelling {
                CalloutView(
                    kind: .warning,
                    text: t(.progressCancelling),
                    detail: t(.progressCancellingDetail)
                )
            }

            if let device = coordinator.selectedDevice {
                CalloutView(
                    kind: .warning,
                    text: t(.progressDoNotUnplug),
                    detail: t(.progressDoNotUnplugDetail, device.displayName, device.bsdName)
                )
            }
        }
    }

    // MARK: - Pieces

    private var overallBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(coordinator.currentPhase?.displayName ?? t(.phasePreparing))
                    .font(.callout.weight(.medium))
                Spacer()
                if let fraction = coordinator.overallFraction {
                    Text("\(Int((fraction * 100).rounded())) %")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let fraction = coordinator.overallFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if let detail = coordinator.progress?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var statistics: some View {
        if let progress = coordinator.progress {
            HStack(spacing: 0) {
                statistic(
                    t(.progressStatWritten),
                    progress.bytesTotal.map {
                        "\(ByteCount.format(progress.bytesProcessed)) / \(ByteCount.format($0))"
                    } ?? ByteCount.format(progress.bytesProcessed)
                )
                statistic(
                    t(.progressStatSpeed),
                    progress.bytesPerSecond.map { ByteCount.formatRate(bytesPerSecond: $0) } ?? "–"
                )
                statistic(
                    t(.progressStatRemaining),
                    progress.secondsRemaining.map { ByteCount.formatDuration($0) } ?? "–"
                )
            }
        }
    }

    private func statistic(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Phase stepper

/// Horizontal step indicator. Phases come from `JobPhase.plan`, so the list
/// matches the strategy actually in flight.
struct PhaseStepper: View {
    let phases: [JobPhase]
    let current: JobPhase?
    let completed: Set<JobPhase>

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(phases.enumerated()), id: \.element) { index, phase in
                if index > 0 {
                    Rectangle()
                        .fill(connectorColour(before: phase))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 7)
                }
                step(phase)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private func step(_ phase: JobPhase) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol(for: phase))
                .font(.system(size: 14))
                .foregroundStyle(colour(for: phase))
            Text(phase.displayName)
                .font(.system(size: 9))
                .foregroundStyle(phase == current ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 62)
        }
    }

    private func symbol(for phase: JobPhase) -> String {
        if completed.contains(phase) { return "checkmark.circle.fill" }
        if phase == current { return "circle.dotted.circle" }
        return "circle"
    }

    private func colour(for phase: JobPhase) -> Color {
        if completed.contains(phase) { return .green }
        if phase == current { return .accentColor }
        return .secondary.opacity(0.5)
    }

    private func connectorColour(before phase: JobPhase) -> Color {
        completed.contains(phase) ? .green : .secondary.opacity(0.25)
    }

    private var accessibilityDescription: String {
        let position = (phases.firstIndex(where: { $0 == current }) ?? 0) + 1
        let name = current?.displayName ?? t(.phasePreparing)
        return t(.progressStepAccessibility, position, phases.count, name)
    }
}
