import SwiftUI
import UIKit

/// iOS counterpart of the macOS reporter in Sources/Tuner/Views/Common/Components.swift: reports its frame in
/// window coordinates (top-left origin) every display frame while it is in a window, so the window-level
/// player can sit exactly over the Live TV guide's preview slot, even while it scrolls or animates.
struct PlayerPreviewFrameReporter: UIViewRepresentable {
    let onChange: (CGRect?) -> Void

    func makeUIView(context: Context) -> FrameReportingView {
        let view = FrameReportingView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: FrameReportingView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    static func dismantleUIView(_ view: FrameReportingView, coordinator: ()) {
        view.stop()
        view.onChange?(nil)
    }

    final class FrameReportingView: UIView {
        var onChange: ((CGRect?) -> Void)?
        private var link: CADisplayLink?
        private var last: CGRect?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stop()
            if window != nil {
                let link = CADisplayLink(target: self, selector: #selector(tick))
                link.add(to: .main, forMode: .common)
                self.link = link
                report()
            } else {
                last = nil
                onChange?(nil)
            }
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick() { report() }

        func report() {
            guard window != nil else { return }
            let frame = convert(bounds, to: nil).integral
            guard frame != last else { return }
            last = frame
            onChange?(frame)
        }
    }
}
