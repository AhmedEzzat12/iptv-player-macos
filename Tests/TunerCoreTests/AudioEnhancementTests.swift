import CoreAudioTypes
import Foundation
import Testing
@testable import TunerCore

@Suite("Biquad filters")
struct BiquadTests {
    @Test func peakingCoefficientsMatchTheCookbook() {
        let c = BiquadCoefficients.peaking(frequency: 1000, q: 1, gainDB: 6, sampleRate: 48_000)
        #expect(abs(c.b0 - 1.0439530870) < 1e-9)
        #expect(abs(c.b1 - -1.8953207239) < 1e-9)
        #expect(abs(c.b2 - 0.8677222848) < 1e-9)
        #expect(abs(c.a1 - -1.8953207239) < 1e-9)
        #expect(abs(c.a2 - 0.9116753718) < 1e-9)
    }

    /// Reference: FFmpeg's `equalizer=f=1000:t=q:w=1:g=6:precision=f64` fed a unit impulse at 48 kHz, i.e. what
    /// the mpv path applies.
    @Test func impulseResponseMatchesFFmpegsEqualizer() {
        var filter = BiquadFilter(.peaking(frequency: 1000, q: 1, gainDB: 6, sampleRate: 48_000))
        let response = (0..<4).map { filter.process($0 == 0 ? 1 : 0) }
        let ffmpeg = [1.043953087, 0.0833051967, 0.0738660317, 0.0640525246]
        for (got, want) in zip(response, ffmpeg) { #expect(abs(got - want) < 1e-9) }
    }

    @Test func peakingGainAtCentreAndUnityFarAway() {
        let c = BiquadCoefficients.peaking(frequency: 2500, q: 0.9, gainDB: 4, sampleRate: 44_100)
        #expect(abs(Dynamics.decibels(c.magnitude(at: 2500, sampleRate: 44_100)) - 4) < 1e-6)
        #expect(abs(Dynamics.decibels(c.magnitude(at: 20, sampleRate: 44_100))) < 0.05)
        let cut = BiquadCoefficients.peaking(frequency: 100, q: 0.7, gainDB: -5, sampleRate: 48_000)
        #expect(abs(Dynamics.decibels(cut.magnitude(at: 100, sampleRate: 48_000)) + 5) < 1e-6)
        #expect(abs(Dynamics.decibels(cut.magnitude(at: 8000, sampleRate: 48_000))) < 0.05)
    }

    @Test func invalidDesignsPassThrough() {
        #expect(BiquadCoefficients.peaking(frequency: 30_000, q: 1, gainDB: 6, sampleRate: 48_000) == .identity)
        #expect(BiquadCoefficients.peaking(frequency: 1000, q: 0, gainDB: 6, sampleRate: 48_000) == .identity)
        #expect(BiquadCoefficients.peaking(frequency: 1000, q: 1, gainDB: 6, sampleRate: 0) == .identity)
    }
}

@Suite("Compressor and leveller")
struct DynamicsTests {
    let night = CompressorSettings.nightMode

    @Test func gainCurveBelowAtAndAboveTheKnee() {
        // Well below threshold - knee/2 (-34.5 dBFS): untouched.
        #expect(Dynamics.gainReductionDB(levelDB: -40, settings: night) == 0)
        // Above the knee: (1/4 - 1) · overshoot.
        #expect(abs(Dynamics.gainReductionDB(levelDB: -10, settings: night) - -15) < 1e-9)
        // At the threshold, inside the 9 dB knee: (1/R - 1) · (W/2)² / (2W).
        #expect(abs(Dynamics.gainReductionDB(levelDB: -30, settings: night) - -0.84375) < 1e-9)
        // Continuous at both knee edges.
        for edge in [-34.5, -25.5] {
            let below = Dynamics.gainReductionDB(levelDB: edge - 1e-6, settings: night)
            let above = Dynamics.gainReductionDB(levelDB: edge + 1e-6, settings: night)
            #expect(abs(below - above) < 1e-5)
        }
    }

    @Test func hardKneeAndRatioOne() {
        var hard = night
        hard.kneeDB = 0
        #expect(Dynamics.gainReductionDB(levelDB: -30.01, settings: hard) == 0)
        #expect(abs(Dynamics.gainReductionDB(levelDB: -20, settings: hard) - -7.5) < 1e-9)
        hard.ratio = 1
        #expect(Dynamics.gainReductionDB(levelDB: 0, settings: hard) == 0)
    }

    @Test func nightModeSqueezesTheRangeAndLiftsQuietParts() {
        func output(_ level: Double) -> Double {
            level + Dynamics.gainReductionDB(levelDB: level, settings: night) + night.makeupDB
        }
        #expect(output(-45) > -45 + 8.9) // quiet: +9 dB
        #expect(output(0) < -12) // full scale: well below clipping
        #expect(output(0) - output(-30) < 30 / 2) // 30 dB in → under 15 dB out
    }

    @Test func smoothingFollowsTheTimeConstants() {
        #expect(Dynamics.smoothingCoefficient(time: 0, sampleRate: 48_000) == 0)
        #expect(abs(Dynamics.smoothingCoefficient(time: 0.01, sampleRate: 48_000) - exp(-1 / 480)) < 1e-12)

        var compressor = Compressor(settings: night, sampleRate: 48_000)
        let target = Dynamics.gainReductionDB(levelDB: 0, settings: night) // -22.5 dB
        for _ in 0..<240 { _ = compressor.gainDB(levelDB: 0) } // one 5 ms attack time constant
        #expect(abs(compressor.reductionDB / target - (1 - exp(-1))) < 0.01)
        for _ in 0..<(48_000 / 10) { _ = compressor.gainDB(levelDB: 0) }
        #expect(abs(compressor.reductionDB - target) < 0.01)
        // Release (200 ms) is slower than attack: after 5 ms of silence most of the reduction remains.
        for _ in 0..<240 { _ = compressor.gainDB(levelDB: -90) }
        #expect(compressor.reductionDB < target * 0.95)
        #expect(abs(compressor.gainDB(levelDB: -90) - (compressor.reductionDB + night.makeupDB)) < 1e-12)
    }

    @Test func levellerRaisesQuietAndLowersLoudWithinLimits() {
        let rate = 48_000.0, block = 1024
        var quiet = Leveller()
        for _ in 0..<(20 * 48_000 / block) {
            quiet.update(blockMeanSquare: pow(10, -40 / 10), frames: block, sampleRate: rate)
        }
        #expect(abs(quiet.gainDB - 12) < 0.01) // wants +20, capped at +12

        var loud = Leveller()
        for _ in 0..<(20 * 48_000 / block) {
            loud.update(blockMeanSquare: pow(10, -14 / 10), frames: block, sampleRate: rate)
        }
        #expect(abs(loud.gainDB - -6) < 0.05)
    }

    @Test func levellerIsSlewLimitedAndGated() {
        var leveller = Leveller()
        // One second of very quiet audio: the gain may rise at most 2 dB.
        for _ in 0..<(48_000 / 480) {
            leveller.update(blockMeanSquare: pow(10, -50 / 10), frames: 480, sampleRate: 48_000)
        }
        #expect(leveller.gainDB > 0)
        #expect(leveller.gainDB <= 2.0001)
        // Silence (below the gate) holds the gain and doesn't count towards the loudness.
        let held = leveller.gainDB, level = leveller.levelDB
        for _ in 0..<100 { leveller.update(blockMeanSquare: 0, frames: 480, sampleRate: 48_000) }
        #expect(leveller.gainDB == held)
        #expect(leveller.levelDB == level)
    }
}

@Suite("Audio enhancement processor")
struct AudioEnhancementProcessorTests {
    static let rate = 48_000.0

    /// Runs `seconds` of a sine through the processor in 512-frame blocks (planar) and returns the output RMS (dBFS)
    /// of the last second, per channel.
    static func run(_ processor: AudioEnhancementProcessor, frequency: Double, amplitudeDB: Double,
                    left: Double = 1, right: Double = 1, seconds: Double = 3) -> (Double, Double) {
        let block = 512
        let l = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let channels = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
        defer { l.deallocate(); r.deallocate(); channels.deallocate() }
        channels[0] = l
        channels[1] = r
        let amplitude = Dynamics.linear(amplitudeDB) * sqrt(2) // RMS → peak
        let total = Int(seconds * rate), measureFrom = total - Int(rate)
        var sumL = 0.0, sumR = 0.0, n = 0
        var t = 0
        while t < total {
            for i in 0..<block {
                let x = amplitude * sin(2 * .pi * frequency * Double(t + i) / rate)
                l[i] = Float(x * left)
                r[i] = Float(x * right)
            }
            processor.process(channels: channels, channelCount: 2, stride: 1, frameCount: block)
            for i in 0..<block where t + i >= measureFrom {
                sumL += Double(l[i] * l[i])
                sumR += Double(r[i] * r[i])
                n += 1
            }
            t += block
        }
        return (10 * log10(sumL / Double(n)), 10 * log10(sumR / Double(n)))
    }

    static func make(_ enabled: Set<AudioEnhancement>) -> AudioEnhancementProcessor {
        let processor = AudioEnhancementProcessor()
        processor.prepare(format: AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32,
            mReserved: 0))
        processor.setEnabled(AudioEnhancementSettings(enabled))
        return processor
    }

    @Test func offLeavesTheAudioUntouched() {
        let (l, r) = Self.run(Self.make([]), frequency: 1000, amplitudeDB: -20)
        #expect(abs(l - -20) < 0.01)
        #expect(abs(r - -20) < 0.01)
    }

    @Test func dialogueBoostLiftsCentredSpeechAndLowersTheSides() {
        // Centred (identical L/R) 2.5 kHz: presence +4 dB, mid ×1.12 (+1 dB), headroom -2 dB → about +3 dB.
        let (centre, _) = Self.run(Self.make([.dialogueBoost]), frequency: 2500, amplitudeDB: -30)
        #expect(abs(centre - -27) < 0.3)
        // Out-of-phase (pure side) 1 kHz: side ×0.6 (-4.4 dB), headroom -2 dB.
        let (side, _) = Self.run(Self.make([.dialogueBoost]), frequency: 1000, amplitudeDB: -30, right: -1)
        #expect(side < -35.5)
        // Rumble at 100 Hz is cut.
        let (rumble, _) = Self.run(Self.make([.dialogueBoost]), frequency: 100, amplitudeDB: -30)
        #expect(rumble < -35)
    }

    @Test func nightModeCompressesLevels() {
        let (quiet, _) = Self.run(Self.make([.nightMode]), frequency: 440, amplitudeDB: -45)
        let (loud, _) = Self.run(Self.make([.nightMode]), frequency: 440, amplitudeDB: -6)
        #expect(quiet > -45 + 8)
        #expect(loud < -6 - 8)
        #expect(loud - quiet < 39 * 0.6) // 39 dB apart in, much closer out
    }

    @Test func levellingBringsQuietAndLoudCloser() {
        let (quiet, _) = Self.run(Self.make([.volumeLevelling]), frequency: 440, amplitudeDB: -34, seconds: 20)
        let (loud, _) = Self.run(Self.make([.volumeLevelling]), frequency: 440, amplitudeDB: -10, seconds: 20)
        #expect(abs(quiet - -22) < 0.5) // +12 dB, the maximum boost
        #expect(abs(loud - -20) < 0.5) // cut to the target
    }

    @Test func everythingOnNeverClips() {
        let (l, r) = Self.run(Self.make(Set(AudioEnhancement.allCases)), frequency: 2500, amplitudeDB: -1, seconds: 2)
        #expect(l <= -3)
        #expect(r <= -3)
    }

    @Test func switchingOffAndOnAgainIsImmediate() {
        let processor = Self.make([.nightMode])
        _ = Self.run(processor, frequency: 440, amplitudeDB: -6, seconds: 1)
        processor.setEnabled(AudioEnhancementSettings())
        let (bypassed, _) = Self.run(processor, frequency: 440, amplitudeDB: -6, seconds: 1)
        #expect(abs(bypassed - -6) < 0.01)
        #expect(processor.enabled == AudioEnhancementSettings())
        processor.setEnabled(AudioEnhancementSettings(nightMode: true))
        #expect(processor.enabled.nightMode)
    }

    @Test func interleavedBufferListMatchesPlanar() {
        let frames = 256
        // Interleaved stereo AudioBufferList (one buffer).
        let interleaved = AudioEnhancementProcessor()
        interleaved.prepare(format: AudioStreamBasicDescription(
            mSampleRate: Self.rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0))
        interleaved.setEnabled(AudioEnhancementSettings(dialogueBoost: true, nightMode: true))
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { samples.deallocate() }
        for i in 0..<frames {
            samples[2 * i] = Float(0.3 * sin(Double(i) / 7))
            samples[2 * i + 1] = Float(0.2 * sin(Double(i) / 5))
        }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: UnsafeMutableRawPointer(samples)))
        interleaved.process(&list, frameCount: frames)

        let planar = Self.make([.dialogueBoost, .nightMode])
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let channels = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
        defer { l.deallocate(); r.deallocate(); channels.deallocate() }
        for i in 0..<frames {
            l[i] = Float(0.3 * sin(Double(i) / 7))
            r[i] = Float(0.2 * sin(Double(i) / 5))
        }
        channels[0] = l
        channels[1] = r
        planar.process(channels: channels, channelCount: 2, stride: 1, frameCount: frames)
        for i in 0..<frames {
            #expect(samples[2 * i] == l[i])
            #expect(samples[2 * i + 1] == r[i])
        }
        #expect((0..<frames).contains { l[$0] != Float(0.3 * sin(Double($0) / 7)) }) // and it did change something
    }

    @Test func nonFloatFormatsAreBypassed() {
        let processor = AudioEnhancementProcessor()
        processor.prepare(format: AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0))
        #expect(!processor.isFormatSupported)
        processor.setEnabled(AudioEnhancementSettings(nightMode: true))
        var value: Int16 = 1234
        withUnsafeMutablePointer(to: &value) { pointer in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: 2, mData: UnsafeMutableRawPointer(pointer)))
            processor.process(&list, frameCount: 1)
        }
        #expect(value == 1234)
    }
}

@Suite("mpv audio filter chain")
struct MPVAudioFilterChainTests {
    static let homebrew = Set(MPVAudioFilterChain.filterNames)
    /// What MPVKit 1.0.0's FFmpeg (iPhone/iPad) has among the chain's filters.
    static let mpvKit: Set<String> = ["aformat", "equalizer", "pan", "volume"]

    @Test func fullChainWithEveryFilter() {
        let chain = MPVAudioFilterChain.build(AudioEnhancementSettings(Set(AudioEnhancement.allCases)), available: Self.homebrew)
        #expect(chain.applied == Set(AudioEnhancement.allCases))
        #expect(chain.value == [
            "@tuner-dialogue-mix:lavfi-pan=[stereo|FL<FL+1.5*FC+0.6*BL+0.6*SL|FR<FR+1.5*FC+0.6*BR+0.6*SR]",
            "@tuner-dialogue-enhance:lavfi-dialoguenhance=original=1:enhance=1:voice=2",
            "@tuner-dialogue-format:lavfi-aformat=channel_layouts=stereo",
            "@tuner-dialogue-gain:lavfi-volume=volume=0.7943",
            "@tuner-dialogue-low:lavfi-equalizer=f=100:t=q:w=0.7:g=-5",
            "@tuner-dialogue-presence:lavfi-equalizer=f=2500:t=q:w=0.9:g=4",
            "@tuner-levelling:lavfi-speechnorm=e=6.25:r=0.00001:l=1",
            "@tuner-night:lavfi-acompressor=threshold=0.0316:ratio=4:attack=5:release=200:knee=2.8184:makeup=2.8184",
        ].joined(separator: ","))
        // Every entry carries one of the labels the engine removes.
        let labels = chain.value.split(separator: ",").map { $0.split(separator: ":")[0].dropFirst() }
        #expect(labels.map(String.init) == MPVAudioFilterChain.labels)
    }

    @Test func nothingEnabledIsAnEmptyChain() {
        let chain = MPVAudioFilterChain.build(AudioEnhancementSettings(), available: Self.homebrew)
        #expect(chain.value.isEmpty)
        #expect(chain.applied.isEmpty)
    }

    @Test func missingFiltersSkipTheirEnhancement() {
        let all = AudioEnhancementSettings(Set(AudioEnhancement.allCases))
        let ios = MPVAudioFilterChain.build(all, available: Self.mpvKit)
        #expect(ios.applied == [.dialogueBoost])
        #expect(!ios.value.contains("dialoguenhance"))
        #expect(!ios.value.contains("acompressor"))
        #expect(ios.value.hasPrefix("@tuner-dialogue-mix:lavfi-pan="))
        #expect(MPVAudioFilterChain.supported(by: Self.mpvKit) == [.dialogueBoost])
        #expect(MPVAudioFilterChain.supported(by: []) == [])
        // No equalizer: no Dialogue Boost at all (not just a downmix).
        let noEQ = MPVAudioFilterChain.build(all, available: ["pan", "volume", "acompressor"])
        #expect(noEQ.applied == [.nightMode])
        #expect(noEQ.value.hasPrefix("@tuner-night:"))
    }

    @Test func numbersUseADotAndNoTrailingZeros() {
        #expect(MPVAudioFilterChain.number(100) == "100")
        #expect(MPVAudioFilterChain.number(0.70) == "0.7")
        #expect(MPVAudioFilterChain.number(-5) == "-5")
        #expect(MPVAudioFilterChain.number(0.00001) == "0")
        #expect(MPVAudioFilterChain.number(2.81838) == "2.8184")
    }
}

@Suite("Sleep timer")
struct SleepTimerTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func minutesCountDownByTheClock() {
        let timer = SleepTimer(.minutes(15), now: start)
        #expect(timer.remaining(now: start, itemTimeLeft: nil) == 900)
        #expect(timer.remaining(now: start.addingTimeInterval(890), itemTimeLeft: 5) == 10)
        #expect(timer.remaining(now: start.addingTimeInterval(1000), itemTimeLeft: nil) == 0)
        #expect(!timer.shouldFire(remaining: 1, isLive: false))
        #expect(timer.shouldFire(remaining: 0, isLive: false))
        #expect(timer.shouldFire(remaining: 0, isLive: true))
        #expect(SleepTimerOption.presets == [.minutes(15), .minutes(30), .minutes(45), .minutes(60), .minutes(90)])
    }

    @Test func endOfItemFollowsThePlayingItem() {
        let timer = SleepTimer(.endOfItem, now: start)
        #expect(timer.isEndOfItem)
        #expect(timer.deadline == nil)
        #expect(timer.remaining(now: start, itemTimeLeft: nil) == nil)
        #expect(timer.remaining(now: start, itemTimeLeft: 42) == 42)
        // Movies and episodes stop on the player's end event; live TV when the programme ends.
        #expect(!timer.shouldFire(remaining: 0, isLive: false))
        #expect(timer.shouldFire(remaining: 0, isLive: true))
        #expect(!timer.shouldFire(remaining: nil, isLive: true))
    }

    @Test func itemTimeLeftAccountsForSpeed() {
        #expect(SleepTimer.itemTimeLeft(position: 100, duration: 160, rate: 1) == 60)
        #expect(SleepTimer.itemTimeLeft(position: 100, duration: 160, rate: 2) == 30)
        #expect(SleepTimer.itemTimeLeft(position: 170, duration: 160) == 0)
        #expect(SleepTimer.itemTimeLeft(position: nil, duration: 160) == nil)
        #expect(SleepTimer.itemTimeLeft(position: 10, duration: 0) == nil)
    }

    @Test func fadesOverTheLastTenSeconds() {
        #expect(SleepTimer.volumeFactor(remaining: nil) == 1)
        #expect(SleepTimer.volumeFactor(remaining: 600) == 1)
        #expect(SleepTimer.volumeFactor(remaining: 10) == 1)
        #expect(SleepTimer.volumeFactor(remaining: 5) == 0.5)
        #expect(SleepTimer.volumeFactor(remaining: 0) == 0)
    }

    @Test func labels() {
        #expect(SleepTimer.label(900) == "15:00")
        #expect(SleepTimer.label(59.2) == "1:00")
        #expect(SleepTimer.label(3723) == "1:02:03")
        #expect(SleepTimer.label(0) == "0:00")
    }
}
