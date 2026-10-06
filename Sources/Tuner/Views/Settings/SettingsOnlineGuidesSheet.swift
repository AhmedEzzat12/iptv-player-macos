#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import TunerCore

/// Settings → Playlists → Browse Online Guides…: the epgshare01.online catalogue of free XMLTV guides
/// (by country and network), searchable, with one-click Add. Added guides become global guide feeds.
struct SettingsOnlineGuidesSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Global feeds already added (guides with the same URL show as added).
    let feeds: [EPGFeed]
    /// Ids of global feeds that are downloading.
    let downloading: Set<String>
    /// Saves a global feed for the URL and downloads it; returns an error message.
    let add: (String) async -> String?

    @ViewState private var phase: SettingsOnlineGuidesPhase = .loading
    @ViewState private var query = ""
    /// Guides (by id) whose Add is in progress, including the first download.
    @ViewState private var adding: Set<String> = []
    @ViewState private var errors: [String: String] = [:]
    @ViewState private var reloadToken = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 560, height: 620)
        .task(id: reloadToken) { await load() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.teal.gradient))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Online TV Guides")
                        .font(.title3.weight(.semibold))
                    Text("Free program guides by country and network. Added guides fill in programs for channels from every playlist.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $query, prompt: Text("Search countries and networks"))
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Search")
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator))
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading guides…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Guides", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { reloadToken += 1 }
            }
        case .loaded(let guides):
            let shown = Self.filter(guides, query: query)
            if guides.isEmpty {
                ContentUnavailableView("No Guides Available", systemImage: "calendar.badge.exclamationmark",
                                       description: Text("The catalogue is empty right now. Try again later."))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(shown) { guide in
                    SettingsOnlineGuideRow(
                        guide: guide,
                        feed: feeds.first { $0.url == guide.url },
                        isAdding: adding.contains(guide.id),
                        downloading: downloading,
                        error: errors[guide.id],
                        onAdd: { addGuide(guide) }
                    )
                }
                #if os(macOS)
                .listStyle(.inset(alternatesRowBackgrounds: true))
                #else
                .listStyle(.insetGrouped)
                #endif
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Guides from epgshare01.online — free, community-maintained.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Actions

    private func load() async {
        if case .loaded = phase { return }
        phase = .loading
        do {
            let guides = try await OnlineGuideCatalog.fetch()
            guard !Task.isCancelled else { return }
            phase = .loaded(guides)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func addGuide(_ guide: OnlineGuide) {
        guard !adding.contains(guide.id) else { return }
        adding.insert(guide.id)
        errors[guide.id] = nil
        Task {
            let error = await add(guide.url)
            adding.remove(guide.id)
            errors[guide.id] = error
        }
    }

    /// Matches the name, variant, file name, country code and the country's name in the user's language.
    static func filter(_ guides: [OnlineGuide], query: String) -> [OnlineGuide] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return guides }
        return guides.filter { guide in
            var haystack = [guide.name, guide.variant ?? "", guide.id]
            if let code = guide.countryCode {
                haystack.append(code)
                if let country = SettingsCountryFlag.countryName(code) { haystack.append(country) }
            }
            let text = haystack.joined(separator: " ")
            return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

private enum SettingsOnlineGuidesPhase {
    case loading
    case loaded([OnlineGuide])
    case failed(String)
}

// MARK: - Row

private struct SettingsOnlineGuideRow: View {
    let guide: OnlineGuide
    /// The global feed already added for this guide's URL.
    let feed: EPGFeed?
    let isAdding: Bool
    let downloading: Set<String>
    let error: String?
    let onAdd: () -> Void

    private var isDownloading: Bool {
        isAdding || feed.map { downloading.contains($0.id) } == true
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(guide.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if let variant = guide.variant?.nilIfEmpty {
                        Text(variant)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Guide \(variant)")
                    }
                }
                detail
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Copy Guide URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(guide.url, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let flag = SettingsCountryFlag.emoji(guide.countryCode) {
            Text(flag)
                .font(.system(size: 24))
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let message = error ?? feed?.lastError?.nilIfEmpty, !isDownloading {
            Text(message)
                .foregroundStyle(.red)
                .help(message)
        } else if let feed, feed.lastFetchedAt != nil, !isDownloading {
            Text("\(feed.channelCount.formatted()) channels · \(feed.programCount.formatted()) programs")
                .foregroundStyle(.secondary)
        } else {
            Text(guide.id)
                .foregroundStyle(.tertiary)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isDownloading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let feed {
            Label("Added", systemImage: feed.lastError?.nilIfEmpty == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(feed.lastError?.nilIfEmpty == nil ? Color.green : Color.orange)
                .help(feed.lastError?.nilIfEmpty ?? "This guide is in your Global Guide Feeds.")
        } else {
            Button(error == nil ? "Add" : "Try Again", action: onAdd)
                .controlSize(.small)
                .accessibilityLabel(error == nil ? "Add \(guide.name)" : "Try Adding \(guide.name) Again")
        }
    }
}

// MARK: - Flags

/// Flag emoji for ISO country codes ("SA" → 🇸🇦), and country names for search.
enum SettingsCountryFlag {
    private static let regions: Set<String> = Set(Locale.Region.isoRegions.map(\.identifier))

    /// Common non-ISO codes used by guide catalogues.
    private static func normalized(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces).uppercased(), code.count == 2 else { return nil }
        let iso = code == "UK" ? "GB" : code
        return regions.contains(iso) ? iso : nil
    }

    static func emoji(_ code: String?) -> String? {
        guard let iso = normalized(code) else { return nil }
        var flag = ""
        for scalar in iso.unicodeScalars {
            guard let indicator = Unicode.Scalar(0x1F1E6 + scalar.value - 0x41) else { return nil }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }

    static func countryName(_ code: String?) -> String? {
        guard let iso = normalized(code) else { return nil }
        return Locale.current.localizedString(forRegionCode: iso)
    }
}

/// Friendly names for guide URLs from the epgshare01.online catalogue ("epg_ripper_SA1.xml.gz" → "Saudi
/// Arabia 1"), so several feeds from the same site can be told apart in Settings.
enum SettingsGuideFeedName {
    static func describe(_ urlString: String) -> (title: String, countryCode: String?)? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased(), host.contains("epgshare01") else { return nil }
        var file = url.lastPathComponent
        for suffix in [".gz", ".xml"] where file.lowercased().hasSuffix(suffix) {
            file = String(file.dropLast(suffix.count))
        }
        if file.lowercased().hasPrefix("epg_ripper_") { file = String(file.dropFirst("epg_ripper_".count)) }
        guard !file.isEmpty else { return nil }
        let letters = file.prefix { $0.isLetter }
        let digits = file.dropFirst(letters.count)
        if letters.count == 2, digits.allSatisfy(\.isNumber), let country = SettingsCountryFlag.countryName(String(letters)) {
            return (digits.isEmpty ? country : "\(country) \(digits)", String(letters))
        }
        return (file.replacingOccurrences(of: "_", with: " "), nil)
    }
}
