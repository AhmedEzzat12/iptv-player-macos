import SwiftUI
import TunerCore

/// Geometry of the visible guide window: maps dates to x positions in the programme area.
struct LiveGuideLayout: Equatable {
    var start: Date
    var end: Date
    var width: CGFloat

    var pointsPerSecond: CGFloat { width / CGFloat(max(1, end.timeIntervalSince(start))) }

    func x(_ date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(start)) * pointsPerSecond }

    func overlaps(_ program: Program) -> Bool { program.end > start && program.start < end }
}

/// Apple TV–style programme guide: sticky time ruler, channel column and programme rows in one
/// vertical lazy scroll (fixed 64 pt rows, so it stays smooth with 20k+ channels).
struct LiveGuideGrid: View {
    static let channelColumnWidth: CGFloat = 230
    static let rowHeight: CGFloat = 64
    static let rulerHeight: CGFloat = 38
    static let trailingInset: CGFloat = 16
    static let cellGap: CGFloat = 2

    @Environment(AppModel.self) private var model
    let store: LiveGuideStore
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let timelineWidth = max(200, geo.size.width - Self.channelColumnWidth - Self.trailingInset)
            let hours = LiveGuideStore.visibleHours(forWidth: timelineWidth)
            let start = store.windowStart
            let layout = LiveGuideLayout(start: start, end: start.addingTimeInterval(hours * 3600), width: timelineWidth)
            VStack(spacing: 0) {
                LiveGuideRuler(store: store, layout: layout)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                rows(layout)
            }
            .overlay(alignment: .topLeading) {
                nowLine(layout, height: geo.size.height)
            }
            .onChange(of: hours, initial: true) { _, value in store.visibleHours = value }
        }
    }

    private func rows(_ layout: LiveGuideLayout) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(store.channels) { channel in
                        LiveGuideRow(channel: channel, layout: layout, store: store, gridFocused: focused) {
                            focused = true
                        }
                        .id(channel.id)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { store.moveSelection(by: -1); return .handled }
            .onKeyPress(.downArrow) { store.moveSelection(by: 1); return .handled }
            .onKeyPress(.pageUp) { store.moveSelection(by: -8); return .handled }
            .onKeyPress(.pageDown) { store.moveSelection(by: 8); return .handled }
            .onKeyPress(.home) { store.moveToEdge(top: true); return .handled }
            .onKeyPress(.end) { store.moveToEdge(top: false); return .handled }
            .onKeyPress(.return) { store.openSelection(); return .handled }
            .onKeyPress(.leftArrow) {
                withAnimation(.snappy(duration: 0.3)) { store.shiftWindow(by: -1) }
                return .handled
            }
            .onKeyPress(.rightArrow) {
                withAnimation(.snappy(duration: 0.3)) { store.shiftWindow(by: 1) }
                return .handled
            }
            .onAppear {
                guard let request = store.scrollRequest else { return }
                Task {
                    await Task.yield()
                    proxy.scrollTo(request.channelId, anchor: request.anchor)
                }
            }
            .onChange(of: store.scrollRequest) { _, request in
                guard let request else { return }
                proxy.scrollTo(request.channelId, anchor: request.anchor)
            }
        }
    }

    @ViewBuilder
    private func nowLine(_ layout: LiveGuideLayout, height: CGFloat) -> some View {
        let now = store.now
        if now >= layout.start, now <= layout.end {
            let x = Self.channelColumnWidth + layout.x(now)
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .padding(.top, 6)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 9, height: 9)
                    .padding(.top, 2)
            }
            .frame(width: 10, height: height)
            .shadow(color: Color.accentColor.opacity(0.5), radius: 3)
            .offset(x: x - 5)
            .allowsHitTesting(false)
            .animation(.smooth(duration: 0.4), value: x)
        }
    }
}

// MARK: - Time ruler

private struct LiveGuideRuler: View {
    let store: LiveGuideStore
    let layout: LiveGuideLayout

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(Fmt.day(layout.start))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                navButton("chevron.left", help: "Earlier") { store.shiftWindow(by: -1) }
                Button("Now") {
                    withAnimation(.snappy(duration: 0.3)) { store.hourOffset = 0 }
                }
                .buttonStyle(LiveRulerButtonStyle(emphasized: store.hourOffset != 0))
                .disabled(store.hourOffset == 0)
                .help("Jump to now")
                navButton("chevron.right", help: "Later") { store.shiftWindow(by: 1) }
            }
            .padding(.leading, 24)
            .padding(.trailing, 10)
            .frame(width: LiveGuideGrid.channelColumnWidth)

            ticks
                .frame(width: layout.width, height: LiveGuideGrid.rulerHeight, alignment: .topLeading)
                .clipped()
        }
        .frame(height: LiveGuideGrid.rulerHeight)
    }

    private func navButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) { action() }
        } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
        }
        .buttonStyle(LiveRulerButtonStyle(emphasized: false))
        .help(help)
    }

    private var ticks: some View {
        let cal = Calendar.current
        var dates: [Date] = []
        var t = layout.start
        while t < layout.end {
            dates.append(t)
            t = t.addingTimeInterval(1800)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(dates, id: \.self) { date in
                let isHour = cal.component(.minute, from: date) == 0
                HStack(alignment: .center, spacing: 6) {
                    Rectangle()
                        .fill(Color.primary.opacity(isHour ? 0.45 : 0.25))
                        .frame(width: 1, height: isHour ? 12 : 8)
                    Text(Fmt.time(date))
                        .font(.system(size: 11.5, weight: isHour ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isHour ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(height: LiveGuideGrid.rulerHeight)
                .padding(.leading, layout.x(date))
            }
        }
    }
}

private struct LiveRulerButtonStyle: ButtonStyle {
    var emphasized: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 8)
            .frame(minWidth: 24, minHeight: 22)
            .foregroundStyle(emphasized ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary)
            .background(Capsule().fill(emphasized ? Color.primary : Color.primary.opacity(configuration.isPressed ? 0.2 : 0.09)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

// MARK: - Row

private struct LiveGuideRow: View {
    @Environment(AppModel.self) private var model
    let channel: Channel
    let layout: LiveGuideLayout
    let store: LiveGuideStore
    let gridFocused: Bool
    let focusGrid: () -> Void

    var body: some View {
        let isPlaying = model.player.main.item?.channel?.id == channel.id
        HStack(spacing: 0) {
            LiveGuideChannelCell(
                channel: channel,
                store: store,
                isPlaying: isPlaying,
                isKeyboardSelected: gridFocused && store.isKeyboardNavigating && store.keyboardChannelId == channel.id,
                focusGrid: focusGrid
            )
            .frame(width: LiveGuideGrid.channelColumnWidth)
            LiveGuideProgramStrip(channel: channel, layout: layout, store: store, focusGrid: focusGrid)
                .frame(width: layout.width, alignment: .leading)
        }
        .frame(height: LiveGuideGrid.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { store.rowAppeared(channel.epgKey) }
        .onDisappear { store.rowDisappeared(channel.epgKey) }
        .onChange(of: channel.epgKey) { old, new in
            store.rowDisappeared(old)
            store.rowAppeared(new)
        }
    }
}

// MARK: - Channel cell

private struct LiveGuideChannelCell: View {
    @Environment(AppModel.self) private var model
    let channel: Channel
    let store: LiveGuideStore
    let isPlaying: Bool
    let isKeyboardSelected: Bool
    let focusGrid: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        let favorite = store.isFavorite(channel)
        let recording = model.isRecording(channel)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 10) {
            ChannelLogo(url: channel.logoURL, name: channel.displayName, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if model.prefs.showChannelNumbers, let number = channel.number {
                        Text("\(number)")
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(channel.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                if isPlaying || favorite || channel.hasCatchup || recording {
                    HStack(spacing: 6) {
                        if isPlaying {
                            Image(systemName: "waveform")
                                .foregroundStyle(Color.accentColor)
                                .symbolEffect(.variableColor.iterative, isActive: model.player.main.isPlaying)
                        }
                        if favorite {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                        if channel.hasCatchup {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        }
                        if recording {
                            Circle().fill(.red).frame(width: 6, height: 6)
                        }
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            shape.fill(isPlaying ? Color.accentColor.opacity(hovering ? 0.30 : 0.22) : Color.primary.opacity(hovering ? 0.10 : 0.045))
        )
        .overlay {
            if isKeyboardSelected {
                shape.strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, LiveGuideGrid.cellGap)
        .padding(.vertical, LiveGuideGrid.cellGap)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onTapGesture {
            focusGrid()
            store.activate(channel)
        }
        .contextMenu { LiveGuideChannelMenu(channel: channel, store: store) }
        .help(channel.displayName)
        // VoiceOver / accessibility clients: a pressable channel with a full-screen action.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            focusGrid()
            store.activate(channel)
        }
        .accessibilityAction(named: "Watch Full Screen") { model.play(channel, fullWindow: true) }
    }
}

// MARK: - Programme strip

private struct LiveGuideProgramStrip: View {
    let channel: Channel
    let layout: LiveGuideLayout
    let store: LiveGuideStore
    let focusGrid: () -> Void

    var body: some View {
        let now = store.now
        let visible = (store.programs(for: channel) ?? []).filter(layout.overlaps)
        let loaded = store.isLoaded(channel)
        let nowX = layout.x(now)
        ZStack(alignment: .topLeading) {
            if !visible.isEmpty {
                ForEach(visible, id: \.start) { program in
                    let x0 = max(0, layout.x(program.start))
                    let x1 = min(layout.width, layout.x(program.end))
                    let width = x1 - x0 - LiveGuideGrid.cellGap
                    if width >= 2 {
                        LiveGuideProgramCell(
                            channel: channel,
                            program: program,
                            store: store,
                            width: width,
                            continuesFromLeft: program.start < layout.start,
                            progressWidth: program.isLive(at: now) ? min(width, max(0, nowX - x0)) : nil,
                            focusGrid: focusGrid
                        )
                        .frame(width: width)
                        .padding(.leading, x0)
                    }
                }
            } else {
                emptyCell(showText: loaded)
            }
        }
        .padding(.vertical, LiveGuideGrid.cellGap)
        .frame(width: layout.width, height: LiveGuideGrid.rowHeight, alignment: .topLeading)
        .clipped()
    }

    /// "No guide information" (or a blank placeholder while the row's programmes load).
    private func emptyCell(showText: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(showText ? 0.035 : 0.025))
            .overlay(alignment: .leading) {
                if showText {
                    Text("No guide information")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 12)
                        .lineLimit(1)
                }
            }
            .padding(.trailing, LiveGuideGrid.cellGap)
            .contentShape(Rectangle())
            .onTapGesture {
                focusGrid()
                store.activate(channel)
            }
    }
}

// MARK: - Programme cell

private enum LiveProgramTiming {
    case past, current, future

    init(_ program: Program, now: Date) {
        if program.end <= now { self = .past }
        else if program.start <= now { self = .current }
        else { self = .future }
    }
}

private struct LiveGuideProgramCell: View {
    @Environment(AppModel.self) private var model
    let channel: Channel
    let program: Program
    let store: LiveGuideStore
    let width: CGFloat
    let continuesFromLeft: Bool
    /// Width of the elapsed part (current programme only).
    let progressWidth: CGFloat?
    let focusGrid: () -> Void

    @ViewState private var hovering = false
    @ViewState private var showDetails = false

    var body: some View {
        let now = store.now
        let timing = LiveProgramTiming(program, now: now)
        let catchup = timing == .past && LiveGuideStore.catchupAvailable(channel, program, now: now)
        let reminder = model.hasReminder(for: program)
        let scheduled = model.isScheduled(program, on: channel)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        ZStack(alignment: .leading) {
            shape.fill(fill(timing))
            if let progressWidth, progressWidth > 0 {
                Rectangle()
                    .fill(Color.accentColor.opacity(hovering ? 0.30 : 0.22))
                    .frame(width: progressWidth)
            }
            if width >= 22 {
                content(timing: timing, catchup: catchup, reminder: reminder, scheduled: scheduled)
                    .opacity(timing == .past && !catchup ? 0.55 : (timing == .past ? 0.75 : 1))
            }
        }
        .clipShape(shape)
        .overlay {
            if timing == .current {
                shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
            }
        }
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onTapGesture { tap(timing: timing, catchup: catchup) }
        .contextMenu { menu(timing: timing, catchup: catchup, scheduled: scheduled) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(program.title), \(Fmt.timeRange(program.start, program.end))")
        .accessibilityAction { tap(timing: timing, catchup: catchup) }
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            LiveGuideProgramDetails(channel: channel, program: program, store: store)
                .environment(model)
        }
        .help(program.title)
    }

    private func fill(_ timing: LiveProgramTiming) -> Color {
        switch timing {
        case .current: Color.accentColor.opacity(hovering ? 0.22 : 0.14)
        case .past: Color.primary.opacity(hovering ? 0.08 : 0.03)
        case .future: Color.primary.opacity(hovering ? 0.13 : 0.065)
        }
    }

    private func content(timing: LiveProgramTiming, catchup: Bool, reminder: Bool, scheduled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if continuesFromLeft {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                if scheduled {
                    Circle().fill(.red).frame(width: 7, height: 7)
                }
                if reminder {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                if catchup {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(program.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            if width >= 110 {
                Text(timing == .current ? "\(Fmt.timeRange(program.start, program.end)) · \(Fmt.remaining(until: program.end, now: store.now))"
                                        : Fmt.timeRange(program.start, program.end))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, width > 60 ? 10 : 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tap(timing: LiveProgramTiming, catchup: Bool) {
        focusGrid()
        switch timing {
        case .current:
            store.activate(channel)
        case .past where catchup:
            store.select(channel)
            model.playCatchup(channel, program: program)
        default:
            store.select(channel)
            showDetails = true
        }
    }

    @ViewBuilder
    private func menu(timing: LiveProgramTiming, catchup: Bool, scheduled: Bool) -> some View {
        switch timing {
        case .current:
            Button { store.select(channel); model.play(channel) } label: { Label("Watch Live", systemImage: "play") }
            Button { store.select(channel); model.play(channel, fullWindow: true) } label: {
                Label("Watch Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            if LiveGuideStore.catchupAvailable(channel, program, now: store.now) {
                Button { store.select(channel); model.playCatchup(channel, program: program) } label: {
                    Label("Play from Start", systemImage: "backward.end")
                }
            }
            Button { model.playInMultiview(channel) } label: { Label("Add to Multiview", systemImage: "square.grid.2x2") }
            Divider()
            if model.isRecording(channel) {
                Button {} label: { Label("Recording", systemImage: "record.circle.fill") }.disabled(true)
            } else {
                Button { model.recordNow(channel) } label: { Label("Record Now", systemImage: "record.circle") }
            }
        case .past:
            if catchup {
                Button { store.select(channel); model.playCatchup(channel, program: program) } label: {
                    Label("Watch", systemImage: "play")
                }
            }
        case .future:
            Button { model.toggleReminder(channel: channel, program: program) } label: {
                model.hasReminder(for: program)
                    ? Label("Remove Reminder", systemImage: "bell.slash")
                    : Label("Remind Me", systemImage: "bell")
            }
            if !model.hasReminder(for: program) {
                Button { model.toggleReminder(channel: channel, program: program, autoSwitch: true) } label: {
                    Label("Remind Me and Switch Channel", systemImage: "bell.and.waves.left.and.right")
                }
            }
            if scheduled {
                if let recording = LiveGuideProgramDetails.scheduledRecording(model, channel, program) {
                    Button { model.cancelRecording(recording) } label: { Label("Cancel Recording", systemImage: "xmark.circle") }
                }
            } else {
                Button { model.record(channel, program: program) } label: { Label("Record", systemImage: "record.circle") }
            }
        }
        Divider()
        Button { store.select(channel); showDetails = true } label: { Label("Details…", systemImage: "info.circle") }
    }
}

// MARK: - Programme details popover

private struct LiveGuideProgramDetails: View {
    @Environment(AppModel.self) private var model
    let channel: Channel
    let program: Program
    let store: LiveGuideStore
    @ViewState private var autoSwitch = false

    static func scheduledRecording(_ model: AppModel, _ channel: Channel, _ program: Program) -> Recording? {
        model.recordings.first {
            $0.channelId == channel.id && ($0.status == .scheduled || $0.status == .recording)
                && $0.start <= program.start.addingTimeInterval(60) && $0.end >= program.end.addingTimeInterval(-60)
        }
    }

    var body: some View {
        let now = store.now
        let timing = LiveProgramTiming(program, now: now)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ChannelLogo(url: channel.logoURL, name: channel.displayName, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text("\(Fmt.day(program.start)) · \(Fmt.timeRange(program.start, program.end)) · \(Fmt.duration(program.duration))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(program.title)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if let sub = program.subtitle?.nilIfEmpty ?? program.episode?.nilIfEmpty {
                    Text(sub)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if let category = program.category?.nilIfEmpty {
                    Text(category)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .padding(.top, 2)
                }
            }

            if let summary = program.summary?.nilIfEmpty {
                ScrollView {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            actions(timing, now: now)
        }
        .padding(16)
        .frame(width: 340)
    }

    @ViewBuilder
    private func actions(_ timing: LiveProgramTiming, now: Date) -> some View {
        switch timing {
        case .future:
            let hasReminder = model.hasReminder(for: program)
            let recording = Self.scheduledRecording(model, channel, program)
            VStack(alignment: .leading, spacing: 10) {
                if !hasReminder {
                    Toggle("Switch to channel when it starts", isOn: $autoSwitch)
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #endif
                        .font(.callout)
                }
                HStack(spacing: 8) {
                    if hasReminder {
                        Button {
                            model.toggleReminder(channel: channel, program: program)
                        } label: {
                            Label("Remove Reminder", systemImage: "bell.slash")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            model.toggleReminder(channel: channel, program: program, autoSwitch: autoSwitch)
                        } label: {
                            Label("Remind Me", systemImage: "bell")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let recording {
                        Button {
                            model.cancelRecording(recording)
                        } label: {
                            Label("Cancel Recording", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            model.record(channel, program: program)
                        } label: {
                            Label("Record", systemImage: "record.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
            }
        case .current:
            HStack(spacing: 8) {
                Button {
                    store.select(channel)
                    model.play(channel, fullWindow: true)
                } label: {
                    Label("Watch Live", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                if LiveGuideStore.catchupAvailable(channel, program, now: now) {
                    Button {
                        store.select(channel)
                        model.playCatchup(channel, program: program)
                    } label: {
                        Label("From Start", systemImage: "backward.end.fill")
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    model.recordNow(channel)
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .buttonStyle(.bordered)
                .disabled(model.isRecording(channel))
            }
            .controlSize(.large)
        case .past:
            if LiveGuideStore.catchupAvailable(channel, program, now: now) {
                Button {
                    store.select(channel)
                    model.playCatchup(channel, program: program)
                } label: {
                    Label("Watch", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Label(channel.hasCatchup ? "No longer in the archive" : "This channel has no catch-up archive",
                      systemImage: "clock.badge.xmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Channel context menu

/// Channel actions shared by the guide's channel cells and the header's "more" menu.
struct LiveGuideChannelMenu: View {
    @Environment(AppModel.self) private var model
    let channel: Channel
    let store: LiveGuideStore
    var includePlayback = true

    var body: some View {
        if includePlayback {
            Button {
                store.select(channel)
                model.play(channel)
            } label: {
                Label("Play", systemImage: "play")
            }
            Button {
                store.select(channel)
                model.play(channel, fullWindow: true)
            } label: {
                Label("Play Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button { model.playInMultiview(channel) } label: {
                Label("Add to Multiview", systemImage: "square.grid.2x2")
            }
            Divider()
        }
        Button { store.toggleFavorite(channel) } label: {
            store.isFavorite(channel)
                ? Label("Remove from Favorites", systemImage: "star.slash")
                : Label("Add to Favorites", systemImage: "star")
        }
        Menu {
            ForEach(model.customGroups) { group in
                Button(group.name) { model.addToGroup(channel, groupId: group.id) }
            }
            if !model.customGroups.isEmpty { Divider() }
            Button("New Group…") { store.beginNewGroup(channel) }
        } label: {
            Label("Add to Group", systemImage: "folder.badge.plus")
        }
        if case .group(let groupId) = model.liveScope {
            Button { model.removeFromGroup(channel, groupId: groupId) } label: {
                Label("Remove from Group", systemImage: "folder.badge.minus")
            }
        }
        Divider()
        Button { store.beginRename(channel) } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Button { model.setHidden(channel, hidden: true) } label: {
            Label("Hide Channel", systemImage: "eye.slash")
        }
        Divider()
        Button { model.recordNow(channel) } label: {
            Label("Record Now", systemImage: "record.circle")
        }
        .disabled(model.isRecording(channel))
    }
}
