#if TUNER_APP_STORE
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import os

/// The Mac App Store app's AirPlay bridge engine: re-wraps a stream for AirPlay devices with FFmpeg's libraries (the
/// LGPL build inside MPVKit), in-process. The sandbox can't run Homebrew's ffmpeg, which the GitHub app's bridge
/// starts as a separate program.
///
/// MPVKit's FFmpeg has no HLS muxer, so the DASH muxer writes the segments: fragmented MP4 (CMAF), which AirPlay
/// devices play for H.264 and HEVC alike, with HLS playlists next to them (`index.m3u8` and one `media_N.m3u8` per
/// stream). Video and audio are copied, never re-encoded; the MP4 muxer strips AAC's ADTS headers by itself.
///
/// Runs on its own thread until `stop()`; blocking network reads give up when `stop()` is called (interrupt
/// callback). Never logs the source URL: Xtream URLs carry the account's credentials.
final class InAppRemuxer: @unchecked Sendable {
    private static let log = Logger(subsystem: "app.tuner.macos", category: "AirPlayBridge")

    /// Audio AirPlay devices accept in fragmented MP4 without converting.
    static let copyableAudio: Set<AVCodecID> = [AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3, AV_CODEC_ID_MP3]

    /// The video playlist (the first stream written).
    static let mediaPlaylist = "media_0.m3u8"

    private let state = OSAllocatedUnfairLock(initialState: (stopped: false, running: false, failure: String?.none))
    /// Where the output really starts in the movie, in seconds (a seek lands on the keyframe before the asked time).
    private let startPosition = OSAllocatedUnfairLock<Double?>(initialState: nil)
    private var thread: Thread?

    var isRunning: Bool { state.withLock { $0.running } }
    var failure: String? { state.withLock { $0.failure } }
    /// Set once the first video packet is read (nil for live TV).
    var startOffset: Double? { startPosition.withLock { $0 } }
    fileprivate var isStopped: Bool { state.withLock { $0.stopped } }

    /// Starts reading `url` and writing the playlists and segments into `directory`.
    func start(url: URL, userAgent: String, referrer: String?, startAt: Double, isLive: Bool, directory: URL) {
        state.withLock { $0 = (false, true, nil) }
        let thread = Thread { [self] in
            let failure = run(url: url, userAgent: userAgent, referrer: referrer, startAt: startAt, isLive: isLive, directory: directory)
            if let failure { Self.log.error("Bridge stopped: \(failure, privacy: .public)") }
            state.withLock { $0.running = false; $0.failure = failure }
        }
        thread.name = "app.tuner.airplay-remux"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    /// Asks the thread to finish (it closes the connection and the files on its way out).
    func stop() {
        state.withLock { $0.stopped = true }
    }

    // MARK: - Work (remux thread)

    /// Returns nil when stopped on purpose or at the end of the media, else what went wrong.
    private func run(url: URL, userAgent: String, referrer: String?, startAt: Double, isLive: Bool, directory: URL) -> String? {
        var input: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let allocated = input else { return "out of memory" }
        allocated.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                return Unmanaged<InAppRemuxer>.fromOpaque(opaque).takeUnretainedValue().isStopped ? 1 : 0
            },
            opaque: Unmanaged.passUnretained(self).toOpaque())

        var inputOptions: OpaquePointer?
        defer { av_dict_free(&inputOptions) }
        av_dict_set(&inputOptions, "user_agent", userAgent, 0)
        av_dict_set(&inputOptions, "fflags", "+genpts", 0)
        if let referrer { av_dict_set(&inputOptions, "headers", "Referer: \(referrer)\r\n", 0) }
        // Only the source's own kind of protocol, also for what its playlists point to: a provider's HLS playlist
        // could otherwise name file: URLs and have files from the app's container served on the network.
        let isRemote = url.scheme == "http" || url.scheme == "https"
        guard isRemote || url.isFileURL else { return "unsupported address" }
        av_dict_set(&inputOptions, "protocol_whitelist", isRemote ? "http,https,tcp,tls,crypto" : "file,crypto", 0)
        if isRemote {
            av_dict_set(&inputOptions, "reconnect", "1", 0)
            av_dict_set(&inputOptions, "reconnect_streamed", "1", 0)
            av_dict_set(&inputOptions, "reconnect_delay_max", "5", 0)
            av_dict_set(&inputOptions, "rw_timeout", "20000000", 0)
        }
        var status = avformat_open_input(&input, url.absoluteString, nil, &inputOptions)
        guard status >= 0, let ic = input else { return isStopped ? nil : "couldn't open the stream (\(Self.describe(status)))" }
        defer { avformat_close_input(&input) }
        status = avformat_find_stream_info(ic, nil)
        guard status >= 0 else { return isStopped ? nil : "couldn't read the stream (\(Self.describe(status)))" }

        let videoIndex = av_find_best_stream(ic, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard videoIndex >= 0, let videoIn = ic.pointee.streams[Int(videoIndex)] else { return "the stream has no video" }
        let videoCodec = videoIn.pointee.codecpar.pointee.codec_id
        guard videoCodec == AV_CODEC_ID_H264 || videoCodec == AV_CODEC_ID_HEVC else {
            return "its video (\(String(cString: avcodec_get_name(videoCodec)))) can't be played by AirPlay devices"
        }
        let audioIndex = av_find_best_stream(ic, AVMEDIA_TYPE_AUDIO, -1, Int32(videoIndex), nil, 0)
        var audioIn: UnsafeMutablePointer<AVStream>?
        if audioIndex >= 0, let stream = ic.pointee.streams[Int(audioIndex)] {
            let codec = stream.pointee.codecpar.pointee.codec_id
            guard Self.copyableAudio.contains(codec) else {
                return "its audio (\(String(cString: avcodec_get_name(codec)).uppercased())) can't be sent to AirPlay devices from this app"
            }
            audioIn = stream
        }

        if startAt > 1, !isLive {
            let target = Int64(startAt * Double(AV_TIME_BASE))
            if avformat_seek_file(ic, -1, Int64.min, target, target, 0) < 0 {
                Self.log.notice("Bridge couldn't seek: starting from the beginning")
            }
        }

        // Output: the DASH muxer with HLS playlists, fragmented MP4 segments of about 6 s.
        var output: UnsafeMutablePointer<AVFormatContext>?
        status = avformat_alloc_output_context2(&output, nil, "dash", directory.appendingPathComponent("manifest.mpd").path)
        guard status >= 0, let oc = output else { return "couldn't prepare the output (\(Self.describe(status)))" }
        defer { avformat_free_context(oc) }
        // A stream joined late, or a seek, starts at 0 in the output (the bridge reports the offset).
        oc.pointee.avoid_negative_ts = 2 // AVFMT_AVOID_NEG_TS_MAKE_ZERO

        var mapping: [Int32: (index: Int32, input: AVRational)] = [:]
        for (inputIndex, source) in [(videoIndex, Optional(videoIn)), (audioIndex, audioIn)] {
            guard let source, inputIndex >= 0, let target = avformat_new_stream(oc, nil) else { continue }
            avcodec_parameters_copy(target.pointee.codecpar, source.pointee.codecpar)
            // Apple devices want HEVC tagged hvc1 (parameter sets in the sample description), not hev1.
            target.pointee.codecpar.pointee.codec_tag = source.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
                ? Self.fourCC("hvc1") : 0
            target.pointee.time_base = source.pointee.time_base
            mapping[inputIndex] = (target.pointee.index, source.pointee.time_base)
        }

        var muxerOptions: OpaquePointer?
        defer { av_dict_free(&muxerOptions) }
        av_dict_set(&muxerOptions, "seg_duration", "6", 0)
        av_dict_set(&muxerOptions, "use_template", "1", 0)
        av_dict_set(&muxerOptions, "use_timeline", "1", 0)
        av_dict_set(&muxerOptions, "hls_playlist", "1", 0)
        av_dict_set(&muxerOptions, "hls_master_name", "index.m3u8", 0)
        av_dict_set(&muxerOptions, "adaptation_sets", audioIn == nil ? "id=0,streams=v" : "id=0,streams=v id=1,streams=a", 0)
        // Live: a sliding window (old segments deleted); otherwise every segment stays, for seeking back.
        av_dict_set(&muxerOptions, "window_size", isLive ? "10" : "0", 0)
        av_dict_set(&muxerOptions, "extra_window_size", isLive ? "5" : "0", 0)
        status = avformat_write_header(oc, &muxerOptions)
        guard status >= 0 else { return "couldn't start the output (\(Self.describe(status)))" }
        Self.log.notice("Bridge started (\(String(cString: avcodec_get_name(videoCodec)), privacy: .public), audio \(audioIn.map { String(cString: avcodec_get_name($0.pointee.codecpar.pointee.codec_id)) } ?? "none", privacy: .public))")

        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let pkt = packet else { return "out of memory" }
        var failure: String?
        // Live streams jump in time (clock wraps, encoder restarts); the MP4 muxer refuses timestamps that go back,
        // where the ffmpeg program patches them. `shift` (µs, every stream) carries the timeline on across a jump;
        // small hiccups move the packet just after the one before.
        let micro = AVRational(num: 1, den: 1_000_000)
        var shift: Int64 = 0
        var lastDTS: [Int32: Int64] = [:]
        while !isStopped {
            status = av_read_frame(ic, pkt)
            if status < 0 {
                if isStopped || status == Self.endOfFile { break }
                failure = "the stream stopped (\(Self.describe(status)))"
                break
            }
            defer { av_packet_unref(pkt) }
            guard let target = mapping[pkt.pointee.stream_index], let out = oc.pointee.streams[Int(target.index)] else { continue }
            if !isLive, pkt.pointee.stream_index == videoIndex, pkt.pointee.pts != Self.noTimestamp,
               startPosition.withLock({ $0 }) == nil {
                let origin = videoIn.pointee.start_time == Self.noTimestamp ? 0 : videoIn.pointee.start_time
                let seconds = Double(pkt.pointee.pts &- origin) * Double(target.input.num) / Double(target.input.den)
                startPosition.withLock { $0 = max(0, seconds) }
            }
            pkt.pointee.stream_index = target.index
            av_packet_rescale_ts(pkt, target.input, out.pointee.time_base)
            if pkt.pointee.dts == Self.noTimestamp { pkt.pointee.dts = pkt.pointee.pts }
            guard pkt.pointee.dts != Self.noTimestamp else { continue }
            if pkt.pointee.pts == Self.noTimestamp { pkt.pointee.pts = pkt.pointee.dts }
            let timeBase = out.pointee.time_base
            let streamShift = av_rescale_q(shift, micro, timeBase)
            pkt.pointee.dts &+= streamShift
            pkt.pointee.pts &+= streamShift
            if let last = lastDTS[target.index], pkt.pointee.dts <= last {
                let gap = last &- pkt.pointee.dts &+ 1
                if av_rescale_q(gap, timeBase, micro) > 1_000_000 { shift &+= av_rescale_q(gap, timeBase, micro) }
                pkt.pointee.dts &+= gap
                pkt.pointee.pts &+= gap
            }
            if pkt.pointee.pts < pkt.pointee.dts { pkt.pointee.pts = pkt.pointee.dts }
            lastDTS[target.index] = pkt.pointee.dts
            pkt.pointee.pos = -1
            status = av_interleaved_write_frame(oc, pkt)
            if status < 0 {
                failure = "couldn't write the stream (\(Self.describe(status)))"
                break
            }
        }
        // Finishes the playlists (a movie's gets its end marker, so the device knows its length).
        av_write_trailer(oc)
        return failure
    }

    // MARK: - Helpers

    /// `AV_NOPTS_VALUE` (a C macro, not imported).
    private static let noTimestamp = Int64.min

    /// `AVERROR_EOF` (a C macro, not imported).
    private static let endOfFile: Int32 = -Int32(bitPattern: UInt32(0x45) | UInt32(0x4F) << 8 | UInt32(0x46) << 16 | UInt32(0x20) << 24)

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func describe(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }
}
#endif
