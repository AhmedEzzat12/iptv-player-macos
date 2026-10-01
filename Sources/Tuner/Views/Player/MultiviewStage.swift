import SwiftUI
import TunerCore

/// Cell rectangles for each multiview layout, by position (0 = main, audible), in stage coordinates.
enum MultiviewGeometry {
    static let gap: CGFloat = 6

    static func rects(for layout: MultiviewLayout, in bounds: CGRect, pipBottomInset: CGFloat) -> [CGRect] {
        let g = gap
        switch layout {
        case .single:
            return [bounds]
        case .pictureInPicture:
            let width = min(520, max(220, bounds.width * 0.28)).rounded()
            let height = (width * 9 / 16).rounded()
            let y = max(bounds.minY + 80, bounds.maxY - pipBottomInset - height)
            return [bounds, CGRect(x: bounds.maxX - 24 - width, y: y, width: width, height: height)]
        case .bigAndBottom:
            let inner = bounds.insetBy(dx: g, dy: g)
            let topHeight = ((inner.height - g) * 0.72).rounded()
            let main = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: topHeight)
            let rowY = main.maxY + g
            let rowHeight = max(0, inner.maxY - rowY)
            let cellWidth = max(0, (inner.width - 2 * g) / 3)
            let row = (0..<3).map { i in
                CGRect(x: inner.minX + CGFloat(i) * (cellWidth + g), y: rowY, width: cellWidth, height: rowHeight)
            }
            return [main] + row
        case .grid2x2:
            let inner = bounds.insetBy(dx: g, dy: g)
            let w = max(0, (inner.width - g) / 2)
            let h = max(0, (inner.height - g) / 2)
            return [
                CGRect(x: inner.minX, y: inner.minY, width: w, height: h),
                CGRect(x: inner.minX + w + g, y: inner.minY, width: w, height: h),
                CGRect(x: inner.minX, y: inner.minY + h + g, width: w, height: h),
                CGRect(x: inner.minX + w + g, y: inner.minY + h + g, width: w, height: h),
            ]
        }
    }

    static func cornerRadius(for layout: MultiviewLayout, position: Int) -> CGFloat {
        switch layout {
        case .single: 0
        case .pictureInPicture: position == 0 ? 0 : 12
        case .bigAndBottom, .grid2x2: 10
        }
    }

    /// Where slots the layout doesn't show wait (invisible), so they grow from the centre when revealed.
    /// Where idle video views wait: a 1×1 rect just outside the stage. Must not overlap content, because
    /// SwiftUI opacity doesn't hide embedded AppKit views.
    static func parkedRect(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX - 4, y: bounds.minY - 4, width: 1, height: 1)
    }
}

/// Interaction and decorations for one multiview cell (full-window mode). The video itself is drawn
/// underneath by `PlayerHost`; this layer handles clicks (main: toggle chrome, others: promote),
/// double-click (window full screen), hover labels, close, the audio badge and status overlays.
struct MultiviewCellOverlay: View {
    @Environment(AppModel.self) private var model
    let slot: PlayerSlot
    let position: Int
    let layout: MultiviewLayout
    let size: CGSize
    /// Keeps the header clear of the chrome's top bar for cells touching the top edge.
    let topInset: CGFloat
    /// Area of the cell covered by the chrome (top bar, control panel); status cards stay out of it.
    var statusInsets = EdgeInsets()
    let chrome: PlayerChromeController
    let onClose: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        let isMain = position == 0
        let isMultiview = layout != .single
        let hasMedia = slot.item != nil
        let radius = MultiviewGeometry.cornerRadius(for: layout, position: position)

        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.toggleWindowFullScreen() }
                .onTapGesture {
                    if isMain || !hasMedia {
                        chrome.toggle()
                    } else {
                        model.player.promote(position: position)
                    }
                }

            if hasMedia {
                let statusHeight = max(0, size.height - statusInsets.top - statusInsets.bottom)
                PlayerStatusOverlay(slot: slot, size: CGSize(width: size.width, height: statusHeight), onClose: onClose)
                    .padding(.top, statusInsets.top)
                    .padding(.bottom, statusInsets.bottom)
            } else if isMultiview {
                MultiviewEmptyCell(size: size)
                    .allowsHitTesting(false)
            }

            if isMultiview, hasMedia {
                header(isMain: isMain)
                    .padding(.horizontal, 10)
                    .padding(.top, topInset)
            }

            // Audio-focused cell outline (grid layouts) and hover highlight for the others.
            if isMultiview, layout != .pictureInPicture || !isMain {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(isMain && layout != .pictureInPicture ? 0.7 : (hovering && hasMedia ? 0.45 : 0)),
                                  lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .onHover { inside in withAnimation(.easeInOut(duration: 0.18)) { hovering = inside } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(slot.item?.title ?? "Empty multiview cell")
    }

    private func header(isMain: Bool) -> some View {
        HStack(spacing: 6) {
            if isMain {
                Image(systemName: slot.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .playerGlass(in: Circle())
                    .allowsHitTesting(false)
                    .accessibilityLabel("Sound")
            }
            if hovering, let title = slot.item?.title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .playerGlass(in: Capsule())
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            Spacer(minLength: 4)
            if hovering {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(PlayerGlassButtonStyle(size: 26))
                    .help("Close")
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
    }
}

/// "+" placeholder for a multiview cell with nothing playing.
private struct MultiviewEmptyCell: View {
    let size: CGSize

    var body: some View {
        let density = PlayerOverlayDensity(size)
        let circle: CGFloat = density == .tiny ? 34 : 50
        VStack(spacing: density.isRegular ? 12 : 6) {
            Image(systemName: "plus")
                .font(.system(size: circle * 0.42, weight: .medium))
                .frame(width: circle, height: circle)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
            if density != .tiny {
                Text("Add a Channel")
                    .font(density.isRegular ? .headline : .callout.weight(.semibold))
            }
            Text("Right-click a channel in the guide → Add to Multiview")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                .padding(1)
        )
    }
}
