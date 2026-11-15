import Testing
@testable import TunerCore

@Suite("Pull charge")
struct PullChargeTests {
    /// Steps at 60 Hz for `seconds`.
    private func hold(_ charge: inout PullCharge, pull: Double, seconds: Double, holdSeconds: Double = 2) {
        for _ in 0..<Int((seconds * 60).rounded()) { charge.step(pull: pull, dt: 1.0 / 60, holdSeconds: holdSeconds) }
    }

    @Test func holdingAtTheLineTakesTheHoldTime() {
        var c = PullCharge()
        hold(&c, pull: PullCharge.line, seconds: 1.9)
        #expect(c.isPastLine && !c.isFull)
        hold(&c, pull: PullCharge.line, seconds: 0.2)
        #expect(c.isFull)
    }

    @Test func pullingFartherFillsFasterButNeverInstantly() {
        var c = PullCharge()
        hold(&c, pull: 400, seconds: 0.5) // a quick deep flick
        #expect(!c.isFull)
        hold(&c, pull: 400, seconds: 0.55)
        #expect(c.isFull) // about half the hold time at full depth
    }

    @Test func nothingBeforeTheLine() {
        var c = PullCharge()
        hold(&c, pull: 70, seconds: 5)
        #expect(c.value == 0 && !c.isPastLine)
    }

    @Test func saggingALittleKeepsItEasingBackDrains() {
        var c = PullCharge()
        hold(&c, pull: 100, seconds: 1)
        let before = c.value
        hold(&c, pull: 65, seconds: 0.2) // between keep and line: still filling
        #expect(c.isPastLine && c.value > before)
        hold(&c, pull: 30, seconds: 0.1) // let off: drains
        #expect(!c.isPastLine && c.value < before)
        hold(&c, pull: 30, seconds: 1)
        #expect(c.value == 0)
    }
}
