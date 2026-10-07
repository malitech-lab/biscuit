import BiscuitKit
import SwiftUI

/// Collapsible log at the bottom of the window.
///
/// Collapsed by default: a progress bar is what a user wants, and a wall of
/// scrolling text reads as something going wrong. Expanded it is the first thing
/// to ask for in a bug report, so it carries a one-click copy action.
struct LogPane: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var isExpanded: Bool
    @State private var minimumLevel: LogLevel = .info
    @State private var autoScroll = true

    private var coordinator: JobCoordinator { env.coordinator }

    private var visibleEntries: [LogEntry] {
        coordinator.logs.filter { $0.level >= minimumLevel }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if isExpanded {
                Divider()
                logList
                    .frame(height: 170)
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(t(.logTitle))
                        .font(.caption.weight(.medium))
                    if !coordinator.logs.isEmpty {
                        Text("\(coordinator.logs.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(nsColor: .separatorColor), in: Capsule())
                    }
                }
            }
            .buttonStyle(.plain)

            if let errorCount = countByLevel(.error), errorCount > 0 {
                Label("\(errorCount)", systemImage: "xmark.octagon.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if let warningCount = countByLevel(.warning), warningCount > 0 {
                Label("\(warningCount)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if isExpanded {
                Picker("", selection: $minimumLevel) {
                    Text(t(.logFilterAll)).tag(LogLevel.debug)
                    Text(t(.logFilterInfo)).tag(LogLevel.info)
                    Text(t(.logFilterWarnings)).tag(LogLevel.warning)
                    Text(t(.logFilterErrors)).tag(LogLevel.error)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 120)

                Toggle(t(.logFollow), isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(coordinator.exportableLog(), forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(t(.logCopyTooltip))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleEntries) { entry in
                        LogRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: visibleEntries.count) {
                guard autoScroll, let last = visibleEntries.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func countByLevel(_ level: LogLevel) -> Int? {
        let count = coordinator.logs.count { $0.level == level }
        return count > 0 ? count : nil
    }
}

private struct LogRow: View {
    let entry: LogEntry

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.formatter.string(from: entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)

            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(tint)
                .frame(width: 11)

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.level == .debug ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private var symbol: String {
        switch entry.level {
        case .debug: return "circle.fill"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch entry.level {
        case .debug: return .secondary.opacity(0.4)
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
