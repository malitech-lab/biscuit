import Foundation

/// Builds the text a user copies into a bug report.
///
/// Lives here rather than beside `JobCoordinator` so it can be tested: the app
/// is an executable target the test target cannot import. That mattered — two
/// faults sat in this text undetected.
public enum DiagnosticsReport {
    /// One line of the operation log.
    public struct Entry: Sendable {
        public let timestamp: Date
        public let level: String
        public let source: String
        public let message: String

        public init(timestamp: Date, level: String, source: String, message: String) {
            self.timestamp = timestamp
            self.level = level
            self.source = source
            self.message = message
        }
    }

    /// Everything the header describes.
    public struct Context: Sendable {
        public var appVersion: String
        public var appBuild: String
        public var osVersion: String
        public var target: String?
        public var source: String?
        public var strategy: WriteStrategy
        /// Beschreibung der Antwortdatei, falls eine mitgeschrieben wird.
        public var answerFile: String?

        public init(
            appVersion: String,
            appBuild: String,
            osVersion: String,
            target: String? = nil,
            source: String? = nil,
            strategy: WriteStrategy,
            answerFile: String? = nil
        ) {
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.osVersion = osVersion
            self.target = target
            self.source = source
            self.strategy = strategy
            self.answerFile = answerFile
        }
    }

    /// Whether a strategy reads the selected source at all.
    ///
    /// `.eraseOnly` does not, and saying otherwise is not a cosmetic matter: a
    /// user selected a Windows ISO, ran `erase_only` three times in a row, and
    /// was surprised each time to find an empty stick. The header said
    /// "Quelle: Windows11_…iso" directly above "Methode: erase_only", which
    /// reads as a promise. The confirmation sheet already omitted the source
    /// for this strategy; this text did not.
    public static func strategyUsesSource(_ strategy: WriteStrategy) -> Bool {
        switch strategy {
        case .rawImage, .windowsFAT32, .macOSInstaller: return true
        case .eraseOnly: return false
        }
    }

    /// Renders the report.
    ///
    /// Labels are English on purpose. This is a diagnostic destined for an
    /// issue tracker, and the project's rule is that diagnostics stay
    /// unlocalised so two users reporting the same fault produce comparable
    /// text and a maintainer can search for a line. The first version used
    /// German labels — `Ziel`, `Quelle`, `Methode`, `FEHLER` — and the test
    /// meant to catch that scanned for a hand-written list of German words that
    /// did not contain any of them. A word list is never complete; this
    /// function is tested by its output instead.
    public static func render(
        context: Context,
        entries: [Entry],
        failure: BiscuitError? = nil,
        timestampFormat: String = "HH:mm:ss.SSS",
        timeZone: TimeZone? = nil
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = timestampFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let timeZone { formatter.timeZone = timeZone }

        var lines = [
            "Biscuit \(context.appVersion) (\(context.appBuild))",
            "macOS \(context.osVersion)",
            ""
        ]
        if let target = context.target {
            lines.append("Target: \(target)")
        }
        // Only when the method actually reads it.
        if let source = context.source, strategyUsesSource(context.strategy) {
            lines.append("Source: \(source)")
        }
        lines.append("Method: \(context.strategy.rawValue)")
        // Muss im Bericht stehen. Ein Medium wurde mit einer Antwortdatei
        // beschrieben, die der Nutzer nicht angefordert hatte, und sein
        // eingefügtes Protokoll gab davon keinen Hinweis — der Fehler war nur
        // im Protokoll des Helfers zu sehen.
        if let answerFile = context.answerFile, strategyUsesSource(context.strategy) {
            lines.append("Answer file: \(answerFile)")
        }
        // Said plainly, because the result surprised a real user.
        if !strategyUsesSource(context.strategy) {
            lines.append("Note: this method only erases; nothing is written to the disk.")
        }
        lines.append("")

        for entry in entries {
            lines.append(
                "[\(formatter.string(from: entry.timestamp))] "
                + "\(entry.level.uppercased()) \(entry.source): \(entry.message)"
            )
        }

        if let failure {
            lines.append("")
            lines.append("ERROR \(failure.kind.rawValue): \(failure.message)")
            if let remedy = failure.remedy { lines.append("REMEDY: \(remedy)") }
            if let diagnostics = failure.diagnostics { lines.append("DIAGNOSTICS: \(diagnostics)") }
        }
        return lines.joined(separator: "\n")
    }
}
