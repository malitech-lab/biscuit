import BiscuitKit
import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showConfirmation = false
    @State private var isLogExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    UpdateBanner()

                    ForEach(env.startupWarnings, id: \.self) { warning in
                        CalloutView(kind: .warning, text: warning)
                    }

                    if env.coordinator.isRunning {
                        ProgressSection()
                    } else {
                        SourceSection()
                        AnswerFileSection()
                        TargetSection()
                        OptionsSection()
                        OutcomeSection()
                    }
                }
                .padding(20)
            }

            Divider()

            LogPane(isExpanded: $isLogExpanded)

            Divider()

            ActionBar(showConfirmation: $showConfirmation)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showConfirmation) {
            ConfirmationSheet(isPresented: $showConfirmation)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text("Biscuit")
                    .font(.headline)
                Text(t(.appTagline))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if env.monitor.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                Task { await env.monitor.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(t(.actionRefreshDevicesShortcut))
            .disabled(env.coordinator.isRunning)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var showConfirmation: Bool

    private var coordinator: JobCoordinator { env.coordinator }

    var body: some View {
        HStack(spacing: 12) {
            if let first = coordinator.blockers.first, !coordinator.isRunning {
                Label(first, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if coordinator.isRunning {
                Text(coordinator.isCancelling ? t(.statusCancelling) : t(.statusRunning))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if coordinator.isRunning {
                Button(t(.actionCancel), role: .destructive) {
                    coordinator.cancel()
                }
                .disabled(coordinator.isCancelling)
            } else {
                if coordinator.state == .succeeded || coordinator.state == .failed {
                    Button(t(.actionReset)) { coordinator.reset() }
                }

                Button {
                    showConfirmation = true
                } label: {
                    Text(coordinator.strategy == .eraseOnly ? t(.actionErase) : t(.actionWrite))
                        .frame(minWidth: 90)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!coordinator.canStart)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
