#if os(macOS)
import AppKit
#endif
import SwiftUI
import TunerCore
import UniformTypeIdentifiers

/// Settings → Sync: iCloud Drive sync of watch progress, favourites, groups and settings between the user's devices.
struct SettingsSyncPane: View {
    @Environment(AppModel.self) private var model
    #if os(iOS) || TUNER_APP_STORE
    @ViewState private var pickingFolder = false
    #endif
    @ViewState private var nameDraft = ""
    @ViewState private var removing: CloudSyncPeer?

    private var sync: CloudSyncController { model.cloudSync }

    var body: some View {
        Form {
            Section {
                Toggle("Sync with iCloud Drive", isOn: Binding(get: { sync.isEnabled }, set: { sync.isEnabled = $0 }))
                    .disabled(sync.debugFolder != nil)
            } footer: {
                SettingsFooter("Syncs watch progress, favourites, groups, hidden and pinned categories, recent searches and settings, and your playlists. Each device keeps a small file in your iCloud Drive folder (end-to-end encrypted only with Advanced Data Protection). Downloads, recordings, reminders and the guide stay on each device.")
            }

            Section {
                Toggle("Include Playlist Passwords", isOn: Binding(get: { sync.includePasswords }, set: { sync.includePasswords = $0 }))
            } footer: {
                SettingsFooter("Playlists sync with their passwords and full links, so they turn on by themselves on your other devices. Passwords are encrypted separately for each of your devices: the sync folder never holds them in readable form, and removed devices can't read new ones.")
            }

            folderSection

            devicesSection

            Section("Status") {
                statusRow
                if let error = sync.lastError, sync.isEnabled {
                    Label {
                        Text(error).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.callout)
                    .foregroundStyle(.red)
                }
                ForEach(sync.notices, id: \.self) { notice in
                    Label(notice, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Sync Now") { sync.syncNow() }
                        .disabled(!sync.isEnabled || sync.isSyncing)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { nameDraft = sync.deviceName }
        .onDisappear(perform: commitName)
        .confirmationDialog("Remove “\(removing?.name ?? "")” from sync?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let removing { sync.removeDevice(removing) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Its sync file is deleted. If the device is still in use, it turns sync off the next time it opens \(Distribution.appName); turning sync on there adds it again.")
        }
        #if os(iOS) || TUNER_APP_STORE
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { sync.chooseFolder(url) }
        }
        #endif
    }

    // MARK: Devices

    private var devicesSection: some View {
        Section {
            LabeledContent {
                TextField("Name", text: $nameDraft, prompt: Text(CloudSyncController.systemDeviceName))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commitName)
            } label: {
                Label("This \(Self.thisDeviceKind)", systemImage: Self.symbol(for: Self.thisPlatform))
            }
            ForEach(sync.peers) { peer in
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name)
                            SettingsRelativeDate(prefix: "Updated", date: peer.exportedAt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: Self.symbol(for: peer.platform))
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { removing = peer }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Devices")
        } footer: {
            SettingsFooter("To add a device, install \(Distribution.appName) on it, turn on sync and choose the same folder. Remove devices you no longer use, or old entries left by reinstalling an earlier version.")
        }
    }

    private func commitName() {
        guard nameDraft != sync.deviceName else { return }
        sync.setDeviceName(nameDraft)
        nameDraft = sync.deviceName
    }

    #if os(macOS)
    private static let thisPlatform = "macOS"
    private static let thisDeviceKind = "Mac"
    #else
    private static let thisPlatform = "iOS"
    private static var thisDeviceKind: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    #endif

    private static func symbol(for platform: String) -> String {
        platform == "iOS" ? "iphone" : "laptopcomputer"
    }

    @ViewBuilder
    private var statusRow: some View {
        if !sync.isEnabled {
            Text("Off").foregroundStyle(.secondary)
        } else if sync.isSyncing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Syncing…").foregroundStyle(.secondary)
            }
        } else if let date = sync.lastSync {
            SettingsRelativeDate(prefix: "Last synced", date: date).foregroundStyle(.secondary)
        } else {
            Text("Not synced yet").foregroundStyle(.secondary)
        }
        if sync.isEnabled, sync.lastError == nil, sync.lastSync != nil, sync.peers.isEmpty {
            Text("No other devices yet. Turn on sync with the same folder on your other Mac, iPhone or iPad.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var folderSection: some View {
        Section {
            if let debug = sync.debugFolder {
                LabeledContent("Folder") {
                    Text(debug.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            } else {
                #if os(macOS) && !TUNER_APP_STORE
                LabeledContent {
                    HStack(spacing: 8) {
                        if !sync.usesDefaultFolder {
                            Button("Use Default") { sync.chooseFolder(nil) }
                        }
                        Button("Choose…", action: chooseMacFolder)
                    }
                } label: {
                    Text("Folder")
                    Text(sync.folderDescription ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                #else
                LabeledContent {
                    Button("Choose Folder…") { pickingFolder = true }
                } label: {
                    Text("Folder")
                    Text(sync.folderDescription ?? "None chosen")
                        .foregroundStyle(sync.needsFolder ? Color.orange : Color.secondary)
                }
                #endif
            }
        } header: {
            Text("Folder")
        } footer: {
            if sync.debugFolder != nil {
                SettingsFooter("Set by TUNER_SYNC_DIR for testing.")
            } else {
                #if os(macOS) && !TUNER_APP_STORE
                SettingsFooter("By default, a “Tuner Sync” folder in iCloud Drive. Use the same folder on every device.")
                #else
                SettingsFooter("In the picker, open iCloud Drive, create a folder named “\(Distribution.appName) Sync” (or open the one your Mac made) and choose it. Use the same folder on every device.")
                #endif
            }
        }
    }

    #if os(macOS) && !TUNER_APP_STORE
    private func chooseMacFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Sync Folder"
        panel.message = "Choose a folder in iCloud Drive that all your devices use for Tuner sync."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = CloudSyncController.defaultMacFolder.deletingLastPathComponent()
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            sync.chooseFolder(url)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }
    #endif
}
