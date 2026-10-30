import Accelerate
import CoreAudioTypes
import Foundation
import Synchronization

/// Applies Dialogue Boost, Volume Levelling and Night Mode to float audio in place, for the AVFoundation engine's
/// `MTAudioProcessingTap` (mpv does the same with FFmpeg filters, see `MPVAudioFilterChain`).
///
/// Realtime-safe: everything is allocated in `init`; `process` takes no locks and allocates nothing. The enabled
/// set can be changed from any thread (`setEnabled`, one atomic byte) and takes effect on the next block; a stage
/// that switches on starts from a clean state. `prepare` and `process` must not run concurrently (the tap
/// guarantees that).
///
/// Order: dialogue (EQ, centre emphasis) → levelling (slow gain) → night (compressor) → limiter (always, when
/// anything is on).
public final class AudioEnhancementProcessor: @unchecked Sendable {
    public static let maxChannels = 16

    private enum Layout {
        case unsupported
        case planar(channels: Int)
        case interleaved(channels: Int)
    }

    private let enabledBits = Atomic<UInt8>(0)

    // Render state: touched only by prepare/process.
    private var sampleRate = 48_000.0
    private var layout = Layout.planar(channels: 2)
    private var activeBits: UInt8 = 0
    private let channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    /// Per channel: [low cut, presence lift] (surround and mono).
    private let channelFilters: UnsafeMutablePointer<BiquadFilter>
    private var midLow = BiquadFilter()
    private var midPresence = BiquadFilter()
    private var sideLow = BiquadFilter()
    private var leveller = Leveller()
    private var levellerGain = 1.0
    private var night = Compressor(settings: .nightMode, sampleRate: 48_000)
    private var limiter = Compressor(settings: .limiter, sampleRate: 48_000)

    public init() {
        channelPointers = .allocate(capacity: Self.maxChannels)
        channelPointers.initialize(repeating: nil, count: Self.maxChannels)
        channelFilters = .allocate(capacity: Self.maxChannels * 2)
        channelFilters.initialize(repeating: BiquadFilter(), count: Self.maxChannels * 2)
        configure(sampleRate: sampleRate)
    }

    deinit {
        channelPointers.deinitialize(count: Self.maxChannels)
        channelPointers.deallocate()
        channelFilters.deinitialize(count: Self.maxChannels * 2)
        channelFilters.deallocate()
    }

    /// Any thread.
    public func setEnabled(_ settings: AudioEnhancementSettings) {
        enabledBits.store(settings.bitmask, ordering: .relaxed)
    }

    public var enabled: AudioEnhancementSettings {
        let bits = enabledBits.load(ordering: .relaxed)
        return AudioEnhancementSettings(Set(AudioEnhancement.allCases.filter { bits & $0.bit != 0 }))
    }

    /// Whether `prepare` was given a format this processor handles (32-bit float PCM).
    public var isFormatSupported: Bool {
        if case .unsupported = layout { return false }
        return true
    }

    /// Called with the tap's processing format before audio flows (and again when it changes).
    public func prepare(format: AudioStreamBasicDescription) {
        let flags = format.mFormatFlags
        let channels = Int(format.mChannelsPerFrame)
        guard format.mFormatID == kAudioFormatLinearPCM, flags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, channels > 0, format.mSampleRate > 0 else {
            layout = .unsupported
            return
        }
        layout = flags & kAudioFormatFlagIsNonInterleaved != 0 ? .planar(channels: channels) : .interleaved(channels: channels)
        configure(sampleRate: format.mSampleRate)
    }

    /// Processes the tap's buffers in place (`prepare` must have been called).
    public func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        // AudioBufferList is a variable-length C struct: `mNumberBuffers` AudioBuffers start at `mBuffers`.
        guard let offset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) else { return }
        let first = (UnsafeMutableRawPointer(bufferList) + offset).assumingMemoryBound(to: AudioBuffer.self)
        let buffers = UnsafeMutableBufferPointer(start: first, count: Int(bufferList.pointee.mNumberBuffers))
        switch layout {
        case .unsupported:
            return
        case .planar(let channels):
            let count = min(channels, buffers.count, Self.maxChannels)
            var frames = frameCount
            for c in 0..<count {
                guard let data = buffers[c].mData else { return }
                channelPointers[c] = data.assumingMemoryBound(to: Float.self)
                frames = min(frames, Int(buffers[c].mDataByteSize) / MemoryLayout<Float>.size)
            }
            process(channels: channelPointers, channelCount: count, stride: 1, frameCount: frames)
        case .interleaved(let channels):
            guard buffers.count > 0, let data = buffers[0].mData else { return }
            let base = data.assumingMemoryBound(to: Float.self)
            let count = min(channels, Self.maxChannels)
            for c in 0..<count { channelPointers[c] = base + c }
            let frames = min(frameCount, Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * channels))
            process(channels: channelPointers, channelCount: count, stride: channels, frameCount: frames)
        }
    }

    /// Core entry point: sample `i` of channel `c` is `channels[c]![i * stride]`.
    public func process(channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, channelCount: Int,
                        stride: Int, frameCount: Int) {
        let bits = enabledBits.load(ordering: .relaxed)
        let n = min(channelCount, Self.maxChannels)
        guard bits != 0, n > 0, frameCount > 0, stride > 0 else {
            activeBits = 0
            return
        }
        for c in 0..<n where channels[c] == nil { return }
        let switchedOn = bits & ~activeBits
        if switchedOn & AudioEnhancement.dialogueBoost.bit != 0 { resetDialogue() }
        if switchedOn & AudioEnhancement.volumeLevelling.bit != 0 {
            leveller.reset()
            levellerGain = 1
        }
        if switchedOn & AudioEnhancement.nightMode.bit != 0 { night.reset() }
        if activeBits == 0 { limiter.reset() }
        activeBits = bits

        if bits & AudioEnhancement.dialogueBoost.bit != 0 {
            applyDialogueBoost(channels, n, stride, frameCount)
        }
        if bits & AudioEnhancement.volumeLevelling.bit != 0 {
            applyLevelling(channels, n, stride, frameCount)
        }
        let useNight = bits & AudioEnhancement.nightMode.bit != 0
        // Night Mode and the limiter share one pass: both follow the loudest channel (linked stereo image).
        for i in 0..<frameCount {
            let index = i * stride
            var peak: Float = 0
            for c in 0..<n { peak = max(peak, abs(channels[c]![index])) }
            var gain = 1.0
            if useNight {
                gain = Dynamics.linear(night.gainDB(levelDB: Dynamics.decibels(Double(peak))))
            }
            gain *= Dynamics.linear(limiter.gainDB(levelDB: Dynamics.decibels(Double(peak) * gain)))
            let g = Float(gain)
            for c in 0..<n {
                channels[c]![index] = min(max(channels[c]![index] * g, -1), 1)
            }
        }
    }

    // MARK: - Stages

    private func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        let low = BiquadCoefficients.peaking(frequency: DialogueBoost.lowFrequency, q: DialogueBoost.lowQ,
                                             gainDB: DialogueBoost.lowGainDB, sampleRate: sampleRate)
        let presence = BiquadCoefficients.peaking(frequency: DialogueBoost.presenceFrequency, q: DialogueBoost.presenceQ,
                                                  gainDB: DialogueBoost.presenceGainDB, sampleRate: sampleRate)
        for c in 0..<Self.maxChannels {
            channelFilters[2 * c] = BiquadFilter(low)
            channelFilters[2 * c + 1] = BiquadFilter(presence)
        }
        midLow = BiquadFilter(low)
        midPresence = BiquadFilter(presence)
        sideLow = BiquadFilter(low)
        leveller.reset()
        levellerGain = 1
        night = Compressor(settings: .nightMode, sampleRate: sampleRate)
        limiter = Compressor(settings: .limiter, sampleRate: sampleRate)
        activeBits = 0
    }

    private func resetDialogue() {
        for i in 0..<(Self.maxChannels * 2) { channelFilters[i].reset() }
        midLow.reset()
        midPresence.reset()
        sideLow.reset()
    }

    /// Stereo: mid/side, with the EQ on the mid (where dialogue sits), the mid raised and the side lowered.
    /// Mono and surround: the EQ on every channel (the tap doesn't know which channel is the centre).
    private func applyDialogueBoost(_ channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, _ n: Int,
                                    _ stride: Int, _ frames: Int) {
        let headroom = Dynamics.linear(DialogueBoost.headroomDB)
        if n == 2, let left = channels[0], let right = channels[1] {
            for i in 0..<frames {
                let index = i * stride
                let l = Double(left[index]), r = Double(right[index])
                let mid = midPresence.process(midLow.process((l + r) / 2)) * DialogueBoost.midGain
                let side = sideLow.process((l - r) / 2) * DialogueBoost.sideGain
                left[index] = Float((mid + side) * headroom)
                right[index] = Float((mid - side) * headroom)
            }
            return
        }
        for c in 0..<n {
            guard let samples = channels[c] else { continue }
            for i in 0..<frames {
                let index = i * stride
                let x = channelFilters[2 * c].process(Double(samples[index]))
                samples[index] = Float(channelFilters[2 * c + 1].process(x) * headroom)
            }
        }
    }

    private func applyLevelling(_ channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, _ n: Int,
                                _ stride: Int, _ frames: Int) {
        var sum = 0.0
        for c in 0..<n {
            var meanSquare: Float = 0
            vDSP_measqv(channels[c]!, vDSP_Stride(stride), &meanSquare, vDSP_Length(frames))
            sum += Double(meanSquare)
        }
        let target = Dynamics.linear(leveller.update(blockMeanSquare: sum / Double(n), frames: frames,
                                                     sampleRate: sampleRate))
        // Ramp from the previous block's gain to avoid zipper noise.
        let start = levellerGain
        let step = (target - start) / Double(frames)
        for i in 0..<frames {
            let index = i * stride
            let g = Float(start + step * Double(i + 1))
            for c in 0..<n { channels[c]![index] *= g }
        }
        levellerGain = target
    }
}
