import AppKit
import SwiftUI
import TunerCore
import UniformTypeIdentifiers

/// Add / edit a playlist source (sheet). Presented from the main window (`model.sourceEditor`)
/// or from Settings → Playlists.
struct SourceEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SourceEditorRequest

    @ViewState private var draft: Source
    @ViewState private var extraEPGText: String
    @ViewState private var backupText: String
    @ViewState private var showPassword = false
    @ViewState private var showAdvanced: Bool
    @ViewState private var test: SourceEditorTestState = .idle
    @ViewState private var testTask: Task<Void, Never>?
    @FocusState private var focus: SourceEditorField?

    init(request: SourceEditorRequest) {
        self.request = request
        let source = request.source ?? Source(
            name: "", kind: request.kind, url: "",
            mac: request.kind == .stalker ? Self.macPrefix : nil
        )
        _draft = ViewState(initialValue: source)
        _extraEPGText = ViewState(initialValue: source.extraEPGURLs.joined(separator: "\n"))
        _backupText = ViewState(initialValue: source.backupURLs.joined(separator: "\n"))
        // Open Advanced straight away when an existing source already uses any of it.
        let usesAdvanced = source.epgURL != nil || !source.extraEPGURLs.isEmpty || source.epgTimeshiftHours != 0
            || source.userAgent != nil || !source.backupURLs.isEmpty || source.refreshHours != nil
            || !source.includeLive || !source.includeVOD || !source.autoLoadEPG
        _showAdvanced = ViewState(initialValue: request.source != nil && usesAdvanced)
    }

    private var isEditing: Bool { request.source != nil }
    static let macPrefix = "00:1A:79:"

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                generalSection
                connectionSection
                advancedSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 440, idealHeight: 520, maxHeight: 860)
        .onAppear { if !isEditing { focus = .url } }
        .onDisappear { testTask?.cancel() }
        .onChange(of: draft.url) { _, newValue in splitXtreamLinkIfNeeded(newValue) }
        .onChange(of: draft) { _, _ in if test != .testing { test = .idle } }
        .onChange(of: draft.kind) { _, kind in kindChanged(kind) }
    }

    // MARK: Header & footer

    private var header: some View {
        HStack(spacing: 14) {
            SettingsSourceIcon(kind: draft.kind, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit “\(request.source?.name ?? "")”" : "Add \(draft.kind.displayName)")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(kindDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    private var kindDescription: String {
        switch draft.kind {
        case .m3u: "A playlist link or file from your provider, usually ending in .m3u or .m3u8."
        case .xtream: "The server address, username and password your provider sent you."
        case .stalker: "The portal address and the MAC address registered with your provider."
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                runTest()
            } label: {
                Text("Test Connection")
            }
            .disabled(!isValid || test == .testing)

            testStatus
            Spacer(minLength: 8)

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "Save" : "Add") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var testStatus: some View {
        switch test {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            }
            .font(.callout)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .lineLimit(2)
                .help(message)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .help(message)
                .textSelection(.enabled)
        }
    }

    // MARK: Sections

    private var generalSection: some View {
        Section {
            Picker("Type", selection: $draft.kind) {
                ForEach(Source.Kind.allCases, id: \.self) { kind in
                    Text(kind.settingsBadge).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isEditing)
            .help(isEditing ? "The type of an existing playlist can't be changed" : "")

            TextField("Name", text: $draft.name, prompt: Text(defaultName ?? "My Provider"))
                .focused($focus, equals: .name)
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        switch draft.kind {
        case .m3u:
            Section {
                TextField("Playlist URL", text: $draft.url, prompt: Text("https://provider.com/playlist.m3u"))
                    .focused($focus, equals: .url)
                    .autocorrectionDisabled()
                LabeledContent {
                    Button("Choose File…", action: chooseFile)
                } label: {
                    Text(isFileURL ? "Local file" : "Or use a playlist file on this Mac")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if canSwitchToXtream {
                    HStack(alignment: .firstTextBaseline) {
                        SettingsFooter("This is an Xtream Codes link. Add it as Xtream Codes to get movies, shows and catch-up too.")
                        Spacer()
                        Button("Use Xtream Codes", action: switchToXtream)
                            .controlSize(.small)
                    }
                } else {
                    urlError
                }
            }

        case .xtream:
            Section {
                TextField("Server", text: $draft.url, prompt: Text("http://provider.com:8080"))
                    .focused($focus, equals: .url)
                    .autocorrectionDisabled()
                TextField("Username", text: optional(\.username), prompt: Text("Required"))
                    .focused($focus, equals: .username)
                    .autocorrectionDisabled()
                LabeledContent("Password") {
                    HStack(spacing: 6) {
                        Group {
                            if showPassword {
                                TextField("Password", text: optional(\.password), prompt: Text("Required"))
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("Password", text: optional(\.password), prompt: Text("Required"))
                            }
                        }
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .focused($focus, equals: .password)
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(Color.secondary)
                                .frame(width: 18)
                        }
                        .buttonStyle(.borderless)
                        .help(showPassword ? "Hide password" : "Show password")
                    }
                }
            } footer: {
                if let error = urlErrorText {
                    Text(error).font(.callout).foregroundStyle(.red)
                } else {
                    SettingsFooter("Tip: paste a full get.php or player_api.php link into Server to fill in everything at once.")
                }
            }

        case .stalker:
            Section {
                TextField("Portal URL", text: $draft.url, prompt: Text("http://portal.provider.com/c/"))
                    .focused($focus, equals: .url)
                    .autocorrectionDisabled()
                LabeledContent("MAC address") {
                    TextField("MAC address", text: optional(\.mac), prompt: Text("00:1A:79:XX:XX:XX"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                        .focused($focus, equals: .mac)
                        .autocorrectionDisabled()
                }
            } footer: {
                if let error = urlErrorText {
                    Text(error).font(.callout).foregroundStyle(.red)
                } else if macIsInvalid {
                    Text("Enter the MAC address as six pairs of hex digits, like 00:1A:79:12:AB:CD.")
                        .font(.callout)
                        .foregroundStyle(.red)
                } else {
                    SettingsFooter("Use the MAC address your provider registered for this portal.")
                }
            }
        }
    }

    @ViewBuilder
    private var urlError: some View {
        if let error = urlErrorText {
            Text(error).font(.callout).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            Button {
                withAnimation(.snappy(duration: 0.25)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Text("Advanced Options")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showAdvanced ? "Expanded" : "Collapsed")
        }

        if showAdvanced {
            Section("Content") {
                Toggle("Include Live TV", isOn: $draft.includeLive)
                Toggle("Include Movies & Shows", isOn: $draft.includeVOD)
                Picker("Refresh", selection: $draft.refreshHours) {
                    Text("Use Settings (\(SettingsGuidePane.intervalTitle(model.prefs.liveRefreshHours).lowercased()))")
                        .tag(Int?.none)
                    Divider()
                    ForEach(Self.refreshOptions(including: draft.refreshHours), id: \.self) { hours in
                        Text(SettingsGuidePane.intervalTitle(hours)).tag(Int?.some(hours))
                    }
                }
            }

            Section("Guide") {
                Toggle(isOn: $draft.autoLoadEPG) {
                    Text("Load provider guide automatically")
                    Text(draft.kind == .m3u ? "Uses the guide link in the playlist header." : "Uses the guide your provider publishes.")
                }
                TextField("Guide URL", text: optional(\.epgURL),
                          prompt: Text(draft.discoveredEPGURL ?? "Use provider guide"))
                    .autocorrectionDisabled()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Extra guide URLs")
                    SettingsFooter("One per line. Used to fill in programs the main guide is missing.")
                    SourceEditorTextBox(text: $extraEPGText, placeholder: "https://example.com/guide.xml.gz")
                }
                LabeledContent {
                    Stepper(value: $draft.epgTimeshiftHours, in: -12...12, step: 0.5) {
                        Text(Self.shiftTitle(draft.epgTimeshiftHours))
                            .monospacedDigit()
                    }
                } label: {
                    Text("Guide time shift")
                    Text("Corrects guides published in the wrong time zone.")
                }
            }

            Section("Connection") {
                TextField("User agent", text: optional(\.userAgent), prompt: Text("Default"))
                    .autocorrectionDisabled()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Backup server URLs")
                    SettingsFooter("One per line. Tried in order when the main address doesn't respond.")
                    SourceEditorTextBox(text: $backupText, placeholder: "http://backup.provider.com:8080")
                }
            }
        }
    }

    // MARK: Validation

    private var trimmedURL: String { draft.url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isFileURL: Bool { trimmedURL.lowercased().hasPrefix("file://") }

    /// The URL as it will be saved: `http://` added when the scheme is missing.
    private var normalizedURL: String? {
        var s = trimmedURL
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return (url.host?.isEmpty == false) ? s : nil
        case "file":
            return draft.kind == .m3u && !url.path.isEmpty ? s : nil
        default:
            return nil
        }
    }

    private var urlErrorText: String? {
        guard !trimmedURL.isEmpty, normalizedURL == nil else { return nil }
        return draft.kind == .m3u ? "Enter a web address (http or https) or choose a file." : "Enter a valid web address."
    }

    private var trimmedMAC: String { (draft.mac ?? "").trimmingCharacters(in: .whitespaces).uppercased() }

    private var macIsValid: Bool {
        trimmedMAC.range(of: #"^([0-9A-F]{2}:){5}[0-9A-F]{2}$"#, options: .regularExpression) != nil
    }

    /// Only complain once the user has typed past the prefill.
    private var macIsInvalid: Bool {
        !macIsValid && trimmedMAC.count >= 17
    }

    private var isValid: Bool {
        guard normalizedURL != nil else { return false }
        switch draft.kind {
        case .m3u:
            return true
        case .xtream:
            return !(draft.username ?? "").trimmingCharacters(in: .whitespaces).isEmpty && !(draft.password ?? "").isEmpty
        case .stalker:
            return macIsValid
        }
    }

    private var defaultName: String? {
        guard let s = normalizedURL, let url = URL(string: s) else { return nil }
        if url.isFileURL { return url.deletingPathExtension().lastPathComponent }
        guard var host = url.host, !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    // MARK: Actions

    private func kindChanged(_ kind: Source.Kind) {
        test = .idle
        if kind == .stalker, (draft.mac ?? "").isEmpty { draft.mac = Self.macPrefix }
        if kind != .stalker, draft.mac == Self.macPrefix { draft.mac = nil }
    }

    /// A pasted `get.php` / `player_api.php` link in the Xtream server field fills in server, username and password.
    private func splitXtreamLinkIfNeeded(_ text: String) {
        guard draft.kind == .xtream, looksLikeXtreamLink(text),
              let parts = XtreamClient.parseCredentials(from: text) else { return }
        draft.url = parts.base
        draft.username = parts.username
        draft.password = parts.password
        focus = .name
    }

    private func looksLikeXtreamLink(_ text: String) -> Bool {
        (text.contains("get.php") || text.contains("player_api.php")) && text.contains("username=") && text.contains("password=")
    }

    /// An M3U `get.php` link is an Xtream account; offer to switch so movies, shows and catch-up work.
    private var canSwitchToXtream: Bool {
        draft.kind == .m3u && !isEditing && looksLikeXtreamLink(trimmedURL) && XtreamClient.parseCredentials(from: trimmedURL) != nil
    }

    private func switchToXtream() {
        let link = trimmedURL
        draft.kind = .xtream
        splitXtreamLinkIfNeeded(link)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose an M3U playlist file."
        panel.allowedContentTypes = [UTType.m3uPlaylist, UTType(filenameExtension: "m3u8"), UTType.plainText].compactMap { $0 }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            draft.url = url.absoluteString
            if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
                draft.name = url.deletingPathExtension().lastPathComponent
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    /// The draft as it will be saved: trimmed, normalised and with defaults filled in.
    private func finalized() -> Source {
        var s = draft
        s.url = normalizedURL ?? trimmedURL
        let name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
        s.name = name.isEmpty ? (defaultName ?? s.kind.displayName) : name
        if s.kind == .xtream {
            s.username = Self.clean(s.username)
            s.password = s.password?.isEmpty == false ? s.password : nil
        } else {
            s.username = request.source?.username
            s.password = request.source?.password
        }
        s.mac = s.kind == .stalker ? trimmedMAC : nil
        s.epgURL = Self.clean(s.epgURL)
        s.userAgent = Self.clean(s.userAgent)
        s.extraEPGURLs = Self.lines(extraEPGText)
        s.backupURLs = Self.lines(backupText)
        return s
    }

    private func runTest() {
        testTask?.cancel()
        test = .testing
        let source = finalized()
        testTask = Task {
            do {
                let message = try await model.testSource(source)
                guard !Task.isCancelled else { return }
                test = .success(message)
            } catch {
                guard !Task.isCancelled else { return }
                test = .failure(error.localizedDescription)
            }
        }
    }

    private func save() {
        guard isValid else { return }
        let edited = finalized()
        if let original = request.source {
            // Start from the latest stored copy so sync status written while the sheet was open survives.
            var current = model.sources.first { $0.id == original.id } ?? original
            current.name = edited.name
            current.url = edited.url
            current.username = edited.username
            current.password = edited.password
            current.mac = edited.mac
            current.epgURL = edited.epgURL
            current.autoLoadEPG = edited.autoLoadEPG
            current.extraEPGURLs = edited.extraEPGURLs
            current.epgTimeshiftHours = edited.epgTimeshiftHours
            current.userAgent = edited.userAgent
            current.backupURLs = edited.backupURLs
            current.includeLive = edited.includeLive
            current.includeVOD = edited.includeVOD
            current.refreshHours = edited.refreshHours
            model.updateSource(current)
        } else {
            model.addSource(edited)
        }
        dismiss()
    }

    // MARK: Helpers

    /// Binds an optional string property as a plain string (empty = nil).
    private func optional(_ keyPath: WritableKeyPath<Source, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private static func clean(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func shiftTitle(_ hours: Double) -> String {
        if hours == 0 { return "None" }
        let value = hours.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(hours)) : String(format: "%.1f", hours)
        return (hours > 0 ? "+" : "") + value + " h"
    }

    private static func refreshOptions(including current: Int?) -> [Int] {
        let base = [0, 1, 3, 6, 12, 24, 48, 168]
        guard let current, !base.contains(current) else { return base }
        return (base + [current]).sorted()
    }
}

private enum SourceEditorField: Hashable {
    case name, url, username, password, mac
}

private enum SourceEditorTestState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)
}

/// Multi-line monospaced text box with a placeholder (for URL lists).
private struct SourceEditorTextBox: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.callout, design: .monospaced))
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.background.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .allowsHitTesting(false)
                }
            }
    }
}
