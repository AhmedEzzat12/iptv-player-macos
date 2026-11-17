import SwiftUI
import TunerCore

/// Sends a playlist to Antenna on a Google TV: scan the QR code on the TV's "Add a playlist" screen (iPhone/iPad) or
/// type the address shown under it. The playlist goes straight to the TV over the home network; the TV asks before
/// adding it.
struct SendToTVSheet: View {
    let source: Source
    @Environment(\.dismiss) private var dismiss
    @ViewState private var address = ""
    @ViewState private var sending = false
    @ViewState private var sent = false
    @ViewState private var error: String?
    /// iPhone/iPad: whether the camera scanner can show (asked for on first open).
    @ViewState private var canScan = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("On the TV, open Antenna, go to Settings and choose Add a Playlist, then scan the code it shows or type the address under it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    #if os(iOS)
                    if canScan && !sent {
                        QRScannerView { code in
                            // Only fills in the address: the user checks it and taps Send.
                            guard !sending, !sent, PlaylistShare.receiverURL(code) != nil else { return }
                            address = code
                            error = nil
                        }
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .listRowInsets(EdgeInsets())
                    }
                    #endif
                    TextField("Address on the TV", text: $address, prompt: Text("192.168.1.20:8790/…"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit(send)
                } footer: {
                    SettingsFooter("The playlist's \(source.password?.isEmpty == false ? "link and password go" : "link goes") only to the TV, over your home network.")
                }
                if sent {
                    Label("Sent. Confirm on the TV to add “\(source.name)”.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            #if os(iOS)
            .navigationTitle("Send to TV")
            .navigationBarTitleDisplayMode(.inline)
            #else
            .navigationTitle("Send “\(source.name)” to TV")
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent ? "Done" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending { ProgressView().controlSize(.small) }
                    else if !sent { Button("Send", action: send).disabled(address.isEmpty) }
                }
            }
        }
        #if os(macOS)
        // Room for the status row (sent, or an error) under the field.
        .frame(width: 480, height: sent || error != nil ? 300 : 250)
        #else
        .task { canScan = await QRScannerView.requestAccess() }
        #endif
    }

    private static var localNetworkSetting: String {
        #if os(macOS)
        "System Settings → Privacy & Security → Local Network"
        #else
        "Settings → Privacy & Security → Local Network"
        #endif
    }

    private func send() {
        guard !sending, !sent else { return }
        guard let url = PlaylistShare.receiverURL(address) else {
            error = PlaylistShare.ShareError.notATVCode.errorDescription
            return
        }
        sending = true
        error = nil
        Task { @MainActor in
            defer { sending = false }
            // The first message to the TV can make the system ask for local network access, and that request fails
            // while the question is up: try once more after a moment.
            for attempt in 1...2 {
                do {
                    try await PlaylistShare.send(source, to: url)
                    sent = true
                    return
                } catch let shareError as PlaylistShare.ShareError {
                    error = shareError.errorDescription
                    return
                } catch where attempt == 1 {
                    try? await Task.sleep(for: .seconds(2))
                } catch {
                    self.error = "Couldn't reach the TV. Check that this device and the TV are on the same network, and that \(Distribution.appName) is allowed to use the local network (\(Self.localNetworkSetting))."
                }
            }
        }
    }
}
