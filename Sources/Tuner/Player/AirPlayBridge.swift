import Darwin
import Foundation
import Network
import os
import TunerCore

/// Makes streams AirPlay devices can't open (MKV, raw TS from M3U panels…) AirPlay-able.
///
/// Apple TVs only accept MP4/MOV/HLS. The video/audio *inside* IPTV MKVs is usually H.264/HEVC + AAC/AC-3,
/// so ffmpeg re-wraps the stream into HLS on the fly (`-c copy`, no re-encode; unsupported audio such as DTS is
/// converted to AAC) and a small HTTP server publishes it on the local network. AVFoundation plays that URL and,
/// when the user picks an AirPlay device, the Apple TV fetches the segments from this Mac — the provider still
/// sees a single connection (ffmpeg's).
@MainActor
final class AirPlayBridge {
    struct Session {
        /// HLS URL on the LAN (reachable by AirPlay devices).
        let url: URL
        /// Position in the original media where the bridged stream starts.
        let offset: Double
    }

    enum BridgeError: LocalizedError {
        case ffmpegMissing
        case noNetwork
        case unsupportedVideo(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .ffmpegMissing: "AirPlay for this format needs ffmpeg (brew install ffmpeg)."
            case .noNetwork: "This Mac isn't on a local network the AirPlay device can reach."
            case .unsupportedVideo(let codec): "Its video codec (\(codec)) can't be played by AirPlay devices."
            case .failed(let detail): "Couldn't prepare the stream for AirPlay: \(detail)"
            }
        }
    }

    /// Codecs Apple TVs decode from HLS.
    static let copyableVideo: Set<String> = ["h264", "avc", "avc1", "hevc", "h265", "hvc1"]
    static let copyableAudio: Set<String> = ["aac", "ac3", "eac3", "mp3"]

    /// Never log the source URL: Xtream URLs carry the account's credentials.
    private static let log = Logger(subsystem: "app.tuner.macos", category: "AirPlayBridge")

    private var process: Process?
    private var server: HLSFileServer?
    private var directory: URL?

    var isRunning: Bool { process?.isRunning == true }

    /// Starts re-wrapping `stream` from `startAt` and returns the LAN URL once the first segments exist.
    func start(stream: PlayableStream, startAt: Double, isLive: Bool, videoCodec: String?, audioCodec: String?) async throws -> Session {
        stop()
        guard let ffmpeg = RecordingService.ffmpegPath() else { throw BridgeError.ffmpegMissing }
        guard let host = Self.lanAddress() else { throw BridgeError.noNetwork }

        let video = (videoCodec ?? "h264").lowercased()
        guard Self.copyableVideo.contains(where: { video.hasPrefix($0) }) else { throw BridgeError.unsupportedVideo(video.uppercased()) }
        let isHEVC = video.hasPrefix("hevc") || video.hasPrefix("h265") || video.hasPrefix("hvc1")
        let audio = (audioCodec ?? "").lowercased()
        let copyAudio = Self.copyableAudio.contains(audio)

        Self.removeOrphanedDirectories()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.directoryPrefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir

        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-user_agent", stream.userAgent]
        if let referrer = stream.referrer { args += ["-headers", "Referer: \(referrer)\r\n"] }
        if stream.url.scheme?.hasPrefix("http") == true {
            args += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
        }
        if startAt > 1, !isLive { args += ["-ss", String(format: "%.3f", startAt)] }
        args += ["-i", stream.url.absoluteString, "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy"]
        if isHEVC { args += ["-tag:v", "hvc1"] }
        if copyAudio {
            args += ["-c:a", "copy"]
            // MPEG-TS carries AAC with ADTS headers, which MP4 segments can't hold. The HLS muxer doesn't strip
            // them itself and fails with a misleading "Operation not permitted". No-op for AAC without ADTS.
            if isHEVC, audio == "aac" { args += ["-bsf:a", "aac_adtstoasc"] }
        } else {
            args += ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]
        }
        args += ["-f", "hls", "-hls_time", "6",
                 "-hls_flags", isLive ? "delete_segments+independent_segments+temp_file" : "independent_segments+temp_file"]
        if isLive {
            args += ["-hls_list_size", "10"]
        } else {
            args += ["-hls_list_size", "0", "-hls_playlist_type", "event"]
        }
        if isHEVC {
            args += ["-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4",
                     "-hls_segment_filename", dir.appendingPathComponent("seg%05d.m4s").path]
        } else {
            args += ["-hls_segment_type", "mpegts", "-hls_segment_filename", dir.appendingPathComponent("seg%05d.ts").path]
        }
        args.append(dir.appendingPathComponent("index.m3u8").path)

        // Through the watchdog, so a crash or force-quit can't leave ffmpeg holding the provider connection.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.watchdogScript, "tuner-airplay", String(getpid()), ffmpeg] + args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        self.process = process

        let server = HLSFileServer(root: dir)
        let port = try await server.start()
        self.server = server

        // Wait for the playlist and two segments (≈12 s of media) so playback can start smoothly.
        let playlist = dir.appendingPathComponent("index.m3u8")
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if !process.isRunning {
                let detail = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
                    .split(separator: "\n").last.map(String.init) ?? "ffmpeg stopped"
                stop()
                throw BridgeError.failed(detail)
            }
            if let text = try? String(contentsOf: playlist, encoding: .utf8),
               text.components(separatedBy: "#EXTINF").count - 1 >= 2 {
                Self.log.notice("Bridge ready on \(host, privacy: .public):\(port) (\(video, privacy: .public) → \(isHEVC ? "fMP4" : "TS", privacy: .public), audio \(copyAudio ? "copy" : "AAC", privacy: .public))")
                return Session(url: URL(string: "http://\(host):\(port)/index.m3u8")!, offset: isLive ? 0 : max(0, startAt))
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        stop()
        throw BridgeError.failed("the stream didn't start in time")
    }

    /// Seconds of media written so far (sum of segment durations) — seeking beyond needs a restart.
    func generatedSeconds() -> Double {
        guard let dir = directory,
              let text = try? String(contentsOf: dir.appendingPathComponent("index.m3u8"), encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").reduce(0) { total, line in
            guard line.hasPrefix("#EXTINF:") else { return total }
            return total + (Double(line.dropFirst(8).prefix { $0 != "," }) ?? 0)
        }
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        server?.stop()
        server = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private static let directoryPrefix = "tuner-airplay-"

    /// Runs `$2…` (ffmpeg and its arguments) and stops it when process `$1` (this app) is gone. macOS has no
    /// parent-death signal, and an orphaned live re-wrap would hold the provider's only connection forever.
    /// SIGTERM from `stop()` is forwarded; the exit status is ffmpeg's.
    private static let watchdogScript = """
        parent=$1; shift
        "$@" &
        child=$!
        trap 'kill $child 2>/dev/null; wait $child; exit 143' TERM INT HUP
        while kill -0 "$parent" 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 1; done
        kill -0 $child 2>/dev/null && kill $child
        wait $child
        """

    /// Deletes bridge folders left by app instances that crashed (folder names carry the owner's pid).
    private static func removeOrphanedDirectories() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix(directoryPrefix) {
            let pidText = name.dropFirst(directoryPrefix.count).prefix { $0.isNumber }
            guard let pid = pid_t(pidText), pid != getpid() else { continue }
            // kill(pid, 0) fails with ESRCH once that process is gone.
            if kill(pid, 0) != 0, errno == ESRCH {
                try? fm.removeItem(at: tmp.appendingPathComponent(name))
            }
        }
    }

    /// First private IPv4 address on an active interface (Wi-Fi/Ethernet), e.g. 192.168.1.20.
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, ip: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue }
            candidates.append((String(cString: ifa.pointee.ifa_name), ip))
        }
        // Prefer en* (Wi-Fi / Ethernet) over VPN tunnels and bridges.
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.ip
    }
}

/// Minimal HTTP/1.1 file server for the bridge's HLS directory (GET/HEAD, one request per connection).
final class HLSFileServer: @unchecked Sendable {
    private let root: URL
    private let queue = DispatchQueue(label: "app.tuner.airplay-server")
    private var listener: NWListener?

    init(root: URL) {
        self.root = root
    }

    /// Starts listening on an ephemeral port on all interfaces; returns the port.
    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            // The listener can report several states; resume the continuation only once.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, Error>
                switch state {
                case .ready: result = .success(listener.port?.rawValue ?? 0)
                case .failed(let error): result = .failure(error)
                default: return
                }
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            self.respond(to: request, on: connection)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let parts = request.split(separator: "\r\n").first?.split(separator: " ") ?? []
        let method = parts.first.map(String.init) ?? ""
        let rawPath = parts.count > 1 ? String(parts[1]) : "/"
        let name = String(rawPath.split(separator: "?").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Only plain file names from the bridge directory (no traversal).
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard method == "GET" || method == "HEAD", !name.isEmpty, !name.contains(".."),
              name.unicodeScalars.allSatisfy(allowed.contains),
              let body = try? Data(contentsOf: root.appendingPathComponent(name)) else {
            send(status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8), headOnly: false, on: connection)
            return
        }
        let type: String = switch (name as NSString).pathExtension.lowercased() {
        case "m3u8": "application/vnd.apple.mpegurl"
        case "ts": "video/mp2t"
        case "m4s", "mp4": "video/mp4"
        default: "application/octet-stream"
        }
        send(status: "200 OK", type: type, body: body, headOnly: method == "HEAD", on: connection)
    }

    private func send(status: String, type: String, body: Data, headOnly: Bool, on connection: NWConnection) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        if !headOnly { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}
