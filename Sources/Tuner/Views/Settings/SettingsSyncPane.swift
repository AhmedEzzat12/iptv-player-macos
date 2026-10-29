#if os(macOS)
import AppKit
#endif
import SwiftUI
import TunerCore
import UniformTypeIdentifiers

/// Settings → Sync: iCloud Drive sync of watch progress, favourites, groups and settings between the user's devices.
struct SettingsSyncPane: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @ViewState private var pickingFolder = false
    #endif

    private var sync: CloudSyncController { model.cloudSync }

    var body: some View {
        Form {
            Section {
                Toggle("Sync with iCloud Drive", isOn: Binding(get: { sync.isEnabled }, set: { sync.isEnabled = $0 }))
                    .disabled(sync.debugFolder != nil)
            } footer: {
                SettingsFooter("Syncs watch progress, favourites, groups, hidden and pinned categories, recent searches and settings, and your playlists without their passwords. Each device keeps a small file in your iCloud Drive folder (end-to-end encrypted only with Advanced Data Protection). Downloads, recordings, reminders and the guide stay on each device.")
            }

            folderSection

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
                ForEach(sync.peers) { peer in
                    LabeledContent {
                        SettingsRelativeDate(prefix: "Updated", date: peer.exportedAt)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(peer.name, systemImage: peer.platform == "iOS" ? "iphone" : "laptopcomputer")
                    }
                }
                HStack {
                    Spacer()
                    Button("Sync Now") { sync.syncNow() }
                        .disabled(!sync.isEnabled || sync.isSyncing)
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { sync.chooseFolder(url) }
        }
        #endif
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
                #if os(macOS)
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
                #if os(macOS)
                SettingsFooter("By default, a “Tuner Sync” folder in iCloud Drive. Use the same folder on every device.")
                #else
                SettingsFooter("In the picker, open iCloud Drive, create a folder named “Tuner Sync” (or open the one your Mac made) and choose it. Use the same folder on every device.")
                #endif
            }
        }
    }

    #if os(macOS)
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
