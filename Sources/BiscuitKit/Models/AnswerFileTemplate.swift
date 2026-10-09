import Foundation

/// Builds an `autounattend.xml` from a handful of choices.
///
/// ## Why this exists
///
/// Biscuit could already *validate* an answer file a user brought along, which
/// helps the few people who know how to write one. The options people actually
/// want are a short, well-known list, and hand-writing 60 lines of
/// Microsoft-namespaced XML to reach them is a poor use of anyone's evening.
///
/// ## What it refuses to pretend
///
/// The hardware-check bypass produces an installation Microsoft does not
/// support. That is not a side note: such a machine may be denied updates, and
/// Microsoft has said as much. The UI says so in those terms rather than
/// offering it as a free win — see `.answerTemplateBypassConsequence`.
///
/// `BypassNRO`, the local-account route, is also on borrowed time: Microsoft
/// removed the `bypassnro.cmd` helper from Insider builds in 2025. The registry
/// value this writes is a different mechanism and still worked when last
/// checked, but it is the one option here most likely to stop working, and the
/// text says that too.
public struct AnswerFileTemplate: Sendable, Hashable, Codable {
    /// A local account to create, skipping the online-account screens.
    public struct LocalAccount: Sendable, Hashable, Codable {
        public var name: String
        /// Stored in the answer file in plain text, because Windows Setup has
        /// no other option here. Surfaced as such.
        public var password: String?

        public init(name: String, password: String? = nil) {
            self.name = name
            self.password = password
        }
    }

    /// Target architecture. Decides the `processorArchitecture` attribute, which
    /// Windows Setup matches strictly — an `amd64` answer file is ignored
    /// outright on an ARM64 install.
    public var architecture: WindowsArchitecture
    /// TPM 2.0, Secure Boot, RAM, storage and CPU checks.
    public var bypassHardwareChecks: Bool
    /// Allows finishing setup without a Microsoft account.
    public var bypassMicrosoftAccount: Bool
    /// Hides the EULA, registration and wireless screens.
    public var skipSetupPages: Bool
    /// Declines the optional diagnostics and tailored-experience settings.
    public var declineTelemetry: Bool
    public var localAccount: LocalAccount?
    /// BCP-47 tag such as `de-DE`. Drives language, keyboard and locale.
    public var locale: String?

    public init(
        architecture: WindowsArchitecture = .x64,
        bypassHardwareChecks: Bool = false,
        bypassMicrosoftAccount: Bool = false,
        skipSetupPages: Bool = false,
        declineTelemetry: Bool = false,
        localAccount: LocalAccount? = nil,
        locale: String? = nil
    ) {
        self.architecture = architecture
        self.bypassHardwareChecks = bypassHardwareChecks
        self.bypassMicrosoftAccount = bypassMicrosoftAccount
        self.skipSetupPages = skipSetupPages
        self.declineTelemetry = declineTelemetry
        self.localAccount = localAccount
        self.locale = locale
    }

    /// True when no option would change anything.
    public var isEmpty: Bool {
        !bypassHardwareChecks && !bypassMicrosoftAccount && !skipSetupPages
            && !declineTelemetry && localAccount == nil && locale == nil
    }

    /// The value Windows Setup expects in `processorArchitecture`.
    ///
    /// Only these three exist for modern Setup; anything else is rejected
    /// rather than guessed, because a wrong value makes Setup ignore the file
    /// silently — the worst possible failure mode for an answer file.
    var processorArchitecture: String? {
        switch architecture {
        case .x64: return "amd64"
        case .arm64: return "arm64"
        case .x86: return "x86"
        case .mips, .alpha, .powerPC, .arm, .ia64: return nil
        }
    }

    // MARK: - Registry commands

    /// `LabConfig` values Windows Setup consults before enforcing requirements.
    static let hardwareBypassValues = [
        "BypassTPMCheck",
        "BypassSecureBootCheck",
        "BypassRAMCheck",
        "BypassStorageCheck",
        "BypassCPUCheck"
    ]

    private static func labConfigCommand(_ value: String) -> String {
        #"reg add HKLM\SYSTEM\Setup\LabConfig /v \#(value) /t REG_DWORD /d 1 /f"#
    }

    private static let bypassNROCommand =
        #"reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f"#

    // MARK: - Rendering

    /// Renders the file.
    ///
    /// The result is checked by ``AnswerFileInspector`` before it is offered to
    /// the user — see ``build()`` — so a template that would produce something
    /// the rest of the pipeline rejects cannot escape this type.
    public func render() -> String {
        var settings: [String] = []

        if let windowsPE = renderWindowsPE() { settings.append(windowsPE) }
        if let specialize = renderSpecialize() { settings.append(specialize) }
        if let oobe = renderOOBESystem() { settings.append(oobe) }

        return """
            <?xml version="1.0" encoding="utf-8"?>
            <unattend xmlns="\(AnswerFile.unattendNamespace)">
            \(settings.joined(separator: "\n"))
            </unattend>
            """
    }

    /// Runs before any files are copied, which is where the requirement checks
    /// happen — later passes are too late for them.
    private func renderWindowsPE() -> String? {
        guard bypassHardwareChecks, let arch = processorArchitecture else { return nil }

        var commands: [String] = []
        for (index, value) in Self.hardwareBypassValues.enumerated() {
            commands.append(
                """
                      <RunSynchronousCommand wcm:action="add">
                        <Order>\(index + 1)</Order>
                        <Path>\(Self.escape(Self.labConfigCommand(value)))</Path>
                      </RunSynchronousCommand>
                """
            )
        }

        return """
              <settings pass="windowsPE">
                <component name="Microsoft-Windows-Setup" processorArchitecture="\(arch)" \
            publicKeyToken="31bf3856ad364e35" language="neutral" \
            versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                  <RunSynchronous>
            \(commands.joined(separator: "\n"))
                  </RunSynchronous>
                </component>
              </settings>
            """
    }

    private func renderSpecialize() -> String? {
        guard bypassMicrosoftAccount, let arch = processorArchitecture else { return nil }
        return """
              <settings pass="specialize">
                <component name="Microsoft-Windows-Deployment" processorArchitecture="\(arch)" \
            publicKeyToken="31bf3856ad364e35" language="neutral" \
            versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                  <RunSynchronous>
                    <RunSynchronousCommand wcm:action="add">
                      <Order>1</Order>
                      <Path>\(Self.escape(Self.bypassNROCommand))</Path>
                    </RunSynchronousCommand>
                  </RunSynchronous>
                </component>
              </settings>
            """
    }

    private func renderOOBESystem() -> String? {
        guard skipSetupPages || declineTelemetry || localAccount != nil || locale != nil,
              let arch = processorArchitecture
        else { return nil }

        var components: [String] = []

        // Sprache und Tastatur gehören in `Microsoft-Windows-International-Core`.
        //
        // Sie standen hier zuerst in `Microsoft-Windows-Shell-Setup`, und das
        // war kein Schönheitsfehler: Windows Setup prüft jede Komponente gegen
        // ihr Schema und bricht bei einem fremden Element den ganzen Durchlauf
        // ab — „Windows could not parse or process the unattend answer file".
        // Die Installation scheiterte dadurch reproduzierbar.
        //
        // Aufgefallen ist es erst an einem echten Windows-Installer. Die eigene
        // Prüfung ließ es durch, weil sie Wurzelelement und Namensraum kennt,
        // aber keine Komponentenschemata — und der Test „jede Optionskombination
        // besteht die Prüfung" bestätigte damit nur, dass beide dieselbe Lücke
        // haben. `AnswerFileTemplate.schemaViolations` schließt sie für die
        // Elemente, die diese Vorlage selbst erzeugt.
        if let locale, Self.isPlausibleLocale(locale) {
            let escaped = Self.escape(locale)
            components.append(
                """
                      <component name="Microsoft-Windows-International-Core" \
                processorArchitecture="\(arch)" publicKeyToken="31bf3856ad364e35" \
                language="neutral" versionScope="nonSxS" \
                xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                      <InputLocale>\(escaped)</InputLocale>
                      <SystemLocale>\(escaped)</SystemLocale>
                      <UILanguage>\(escaped)</UILanguage>
                      <UserLocale>\(escaped)</UserLocale>
                    </component>
                """
            )
        }

        var shell: [String] = []
        var oobe: [String] = []
        if skipSetupPages {
            oobe.append("          <HideEULAPage>true</HideEULAPage>")
            oobe.append("          <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>")
            oobe.append("          <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>")
        }
        if bypassMicrosoftAccount {
            oobe.append("          <HideOnlineAccountScreens>true</HideOnlineAccountScreens>")
        }
        if declineTelemetry {
            // 3 means "decline every optional setting"; 1 would accept the
            // recommended ones, which is the opposite of what was asked for.
            oobe.append("          <ProtectYourPC>3</ProtectYourPC>")
        }
        if !oobe.isEmpty {
            shell.append("        <OOBE>\n\(oobe.joined(separator: "\n"))\n        </OOBE>")
        }
        if let account = localAccount, !account.name.isEmpty {
            shell.append(renderLocalAccount(account))
        }

        if !shell.isEmpty {
            components.append(
                """
                      <component name="Microsoft-Windows-Shell-Setup" \
                processorArchitecture="\(arch)" publicKeyToken="31bf3856ad364e35" \
                language="neutral" versionScope="nonSxS" \
                xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                \(shell.joined(separator: "\n"))
                    </component>
                """
            )
        }

        guard !components.isEmpty else { return nil }
        return """
              <settings pass="oobeSystem">
            \(components.joined(separator: "\n"))
              </settings>
            """
    }

    private func renderLocalAccount(_ account: LocalAccount) -> String {
        let name = Self.escape(account.name)
        var lines = ["        <UserAccounts>", "          <LocalAccounts>",
                     #"            <LocalAccount wcm:action="add">"#]
        if let password = account.password, !password.isEmpty {
            // Plain text because Windows Setup offers nothing else at this
            // point. `AnswerFileInspector` will flag it, which is correct and
            // deliberately not suppressed.
            lines.append("              <Password>")
            lines.append("                <Value>\(Self.escape(password))</Value>")
            lines.append("                <PlainText>true</PlainText>")
            lines.append("              </Password>")
        }
        lines.append("              <Name>\(name)</Name>")
        lines.append("              <Group>Administrators</Group>")
        lines.append("            </LocalAccount>")
        lines.append("          </LocalAccounts>")
        lines.append("        </UserAccounts>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Escaping

    /// Escapes text for an XML element body or attribute value.
    ///
    /// Not optional politeness: the account name and password come from a text
    /// field, and an unescaped `&` or `<` turns the file into something
    /// `XMLDocument` refuses — which, before the build-then-validate step
    /// below, would have meant shipping a medium whose answer file Windows
    /// Setup silently ignores.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                // Control characters are not representable in XML 1.0 at all,
                // so they are dropped rather than encoded into something a
                // parser will still reject.
                if let ascii = character.asciiValue, ascii < 0x20,
                   character != "\t", character != "\n", character != "\r" {
                    continue
                }
                result.append(character)
            }
        }
        return result
    }

    /// Accepts `de`, `de-DE`, `sr-Latn-RS`; rejects anything else.
    ///
    /// A malformed locale makes Setup fall back silently, so a bad value is
    /// dropped rather than written.
    static func isPlausibleLocale(_ locale: String) -> Bool {
        let parts = locale.split(separator: "-")
        guard (1...3).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            (2...8).contains(part.count) && part.allSatisfy(\.isLetter)
        }
    }

    // MARK: - Schema

    /// Welche Elemente in welcher Komponente erlaubt sind.
    ///
    /// Bewusst eng: nur die Elemente, die diese Vorlage selbst erzeugt. Eine
    /// vollständige Nachbildung des Unattend-Schemas wäre viel Pflegeaufwand
    /// für wenig Gewinn — diese Tabelle fängt genau den Fehler, der bereits
    /// passiert ist, und jeden gleichartigen beim nächsten Umbau.
    static let elementOwners: [String: String] = [
        "InputLocale": "Microsoft-Windows-International-Core",
        "SystemLocale": "Microsoft-Windows-International-Core",
        "UILanguage": "Microsoft-Windows-International-Core",
        "UserLocale": "Microsoft-Windows-International-Core",
        "OOBE": "Microsoft-Windows-Shell-Setup",
        "UserAccounts": "Microsoft-Windows-Shell-Setup",
        "HideEULAPage": "Microsoft-Windows-Shell-Setup",
        "HideOEMRegistrationScreen": "Microsoft-Windows-Shell-Setup",
        "HideWirelessSetupInOOBE": "Microsoft-Windows-Shell-Setup",
        "HideOnlineAccountScreens": "Microsoft-Windows-Shell-Setup",
        "ProtectYourPC": "Microsoft-Windows-Shell-Setup"
    ]

    /// Findet Elemente, die in der falschen Komponente stehen.
    ///
    /// Windows Setup prüft jede Komponente gegen ihr Schema und bricht bei
    /// einem fremden Element den gesamten Durchlauf ab. Das ist keine
    /// Warnung, die man übersehen kann — die Installation endet.
    public func schemaViolations() -> [String] {
        var violations: [String] = []
        var currentComponent: String?

        for rawLine in render().split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("<component "), let range = line.range(of: #"name=""#) {
                let rest = line[range.upperBound...]
                currentComponent = rest.prefix { $0 != "\"" }.description
                continue
            }
            if line.hasPrefix("</component") { currentComponent = nil; continue }

            guard line.hasPrefix("<"), !line.hasPrefix("</"), !line.hasPrefix("<?") else { continue }
            let name = line.dropFirst().prefix { $0.isLetter || $0.isNumber }.description
            guard let owner = Self.elementOwners[name] else { continue }
            guard let component = currentComponent else { continue }
            if component != owner {
                violations.append("<\(name)> is in \(component), belongs in \(owner)")
            }
        }
        return violations
    }

    // MARK: - Building

    /// Renders and validates in one step.
    ///
    /// Running the output through the very inspector that guards user-supplied
    /// files means generated and hand-written answer files are held to the same
    /// standard, and that a bug in the renderer surfaces here rather than on a
    /// finished USB stick.
    public func build(fileName: String = AnswerFile.standardFileName) throws -> AnswerFile {
        guard processorArchitecture != nil else {
            throw BiscuitError(
                kind: .internalInconsistency,
                message: t(.errorAnswerTemplateArchitecture),
                diagnostics: "no autounattend architecture for \(architecture.displayName)"
            )
        }

        // Vor der allgemeinen Prüfung: die Komponentenzuordnung. Die
        // allgemeine Prüfung kennt Wurzelelement und Namensraum, aber keine
        // Schemata — sie hat eine fehlplatzierte Spracheinstellung
        // durchgelassen, an der jede Installation scheiterte.
        let violations = schemaViolations()
        guard violations.isEmpty else {
            throw BiscuitError(
                kind: .internalInconsistency,
                message: t(.errorAnswerTemplateInvalid),
                diagnostics: violations.joined(separator: "; ")
            )
        }

        let data = Data(render().utf8)
        let answer = AnswerFileInspector().inspect(fileName: fileName, contents: data)

        guard answer.isUsable else {
            throw BiscuitError(
                kind: .internalInconsistency,
                message: t(.errorAnswerTemplateInvalid),
                diagnostics: answer.findings
                    .filter { $0.severity == .blocking }
                    .map(\.kind.rawValue)
                    .joined(separator: ", ")
            )
        }
        return answer
    }
}
