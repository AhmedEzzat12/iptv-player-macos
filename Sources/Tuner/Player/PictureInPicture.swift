import Foundation

/// What a Picture in Picture window asks of the player. AVFoundation's own PiP drives its player directly; mpv on
/// iPhone/iPad draws its PiP window itself and goes through these, so pausing and skipping there keep `PlayerSlot`'s
/// state right.
@MainActor
struct PictureInPictureControls {
    var isPaused: () -> Bool
    var setPaused: (Bool) -> Void
    var position: () -> Double?
    var duration: () -> Double?
    var isLive: () -> Bool
    var seekBy: (Double) -> Void
    /// The video's display size (frames for the window are drawn in its shape).
    var videoSize: () -> CGSize?
}

/// An engine that can show its video in Picture in Picture.
@MainActor
protocol PictureInPictureEngine: AnyObject {
    var isPictureInPicturePossible: Bool { get }
    var isPictureInPictureActive: Bool { get }
    var onPictureInPictureChanged: ((Bool) -> Void)? { get set }
    func togglePictureInPicture()
    func attachPictureInPictureControls(_ controls: PictureInPictureControls)
}

extension PictureInPictureEngine {
    func attachPictureInPictureControls(_ controls: PictureInPictureControls) {}
}

extension AVEngine: PictureInPictureEngine {}
