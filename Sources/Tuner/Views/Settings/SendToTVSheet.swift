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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("On the TV, open Antenna, go to Settings and choose Add a Playlist, then scan the code it shows or type the address under it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    #if os(iOS)
                    if QRScannerView.isAvailable && !sent {
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
                    Text("The playlist's link\(source.password == nil ? "" : " and password") go only to the TV, over your home network.")
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
            .navigationTitle("Send “\(source.name)” to TV")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
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
        .frame(width: 460, height: 300)
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
            do {
                try await PlaylistShare.send(source, to: url)
                sent = true
            } catch let shareError as PlaylistShare.ShareError {
                error = shareError.errorDescription
            } catch {
                self.error = "Couldn't reach the TV. Check that this device and the TV are on the same network."
            }
        }
    }
}
