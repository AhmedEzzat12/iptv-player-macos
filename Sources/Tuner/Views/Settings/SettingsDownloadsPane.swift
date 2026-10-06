#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import TunerCore

/// Settings → Downloads: where downloads are saved, how much they use, and deleting them all.
struct SettingsDownloadsPane: View {
    @Environment(AppModel.self) private var model
    @ViewState private var freeSpace: Int64?
    @ViewState private var confirmDeleteAll = false

    private var items: [DownloadItem] { model.downloadItems }
    private var totalOnDisk: Int64 { items.map(DownloadFormat.sizeOnDisk).reduce(0, +) }
    private var folderURL: URL { URL(fileURLWithPath: model.prefs.downloadsPath, isDirectory: true) }

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Show in Finder") { DownloadActions.revealFolder(model: model) }
                        Button("Choose…", action: chooseFolder)
                    }
                } label: {
                    Label {
                        Text("Save downloads to")
                        Text((model.prefs.downloadsPath as NSString).abbreviatingWithTildeInPath)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } icon: {
                        Image(nsImage: folderIcon)
                            .resizable()
                            .frame(width: 22, height: 22)
                    }
                }
            }

            Section {
                LabeledContent {
                    Text(DownloadFormat.bytes(totalOnDisk))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Used by downloads")
                    Text(summary)
                }
                if let freeSpace {
                    LabeledContent("Available on this disk") {
                        Text(DownloadFormat.bytes(freeSpace))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    Button("Delete All Downloads…", role: .destructive) { confirmDeleteAll = true }
                        .disabled(items.isEmpty)
                } label: {
                    Text("Delete all downloads")
                    Text("Removes every downloaded movie and episode from this Mac and cancels unfinished ones.")
                }
            } header: {
                Text("Storage")
            }

            Section {
                Label {
                    Text("One at a time")
                    Text("Downloads run one after another, in the order you add them, and continue after you quit and reopen Tuner.")
                } icon: {
                    Image(systemName: "list.number").foregroundStyle(.secondary)
                }
                Label {
                    Text("Single-connection accounts")
                    Text("When your account allows only one stream at a time, downloads pause while you stream from it and continue when you stop watching. Downloaded movies and episodes don't count — they play from this Mac.")
                } icon: {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                }
            } header: {
                Text("How Downloads Work")
            } footer: {
                SettingsFooter("To download, choose Download on a movie's page, or right-click an episode on a show's page. Downloads play without an internet connection; find them in Downloads in the sidebar.")
            }
        }
        .formStyle(.grouped)
        .task(id: model.prefs.downloadsPath) {
            let path = model.prefs.downloadsPath
            freeSpace = await Task.detached(priority: .utility) { DownloadActions.availableCapacity(at: path) }.value
        }
        .task { await model.refreshDownloads() }
        .confirmationDialog("Delete all downloads?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All Downloads", role: .destructive) { model.deleteAllDownloads() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(summary) (\(DownloadFormat.bytes(totalOnDisk))) will be removed from this Mac. You can still stream them or download them again.")
        }
    }

    private var summary: String {
        let movies = items.filter { $0.kind == .movie }.count
        let episodes = items.count - movies
        var parts: [String] = []
        if movies > 0 { parts.append(movies == 1 ? "1 movie" : "\(movies) movies") }
        if episodes > 0 { parts.append(episodes == 1 ? "1 episode" : "\(episodes) episodes") }
        return parts.isEmpty ? "No downloads" : parts.joined(separator: ", ")
    }

    private var folderIcon: NSImage {
        FileManager.default.fileExists(atPath: folderURL.path)
            ? NSWorkspace.shared.icon(forFile: folderURL.path)
            : NSWorkspace.shared.icon(for: .folder)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Tuner saves downloaded movies and episodes. Existing downloads stay where they are."
        panel.directoryURL = folderURL
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            model.setDownloadsFolder(url)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }
}
