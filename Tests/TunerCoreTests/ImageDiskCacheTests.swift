import Foundation
import Testing
@testable import TunerCore

@Suite("Artwork disk cache")
struct ImageDiskCacheTests {
    private func makeCache(limit: Int64, trimInterval: Int = 1000) -> (ImageDiskCache, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tuner-imagecache-\(UUID().uuidString)")
        return (ImageDiskCache(directory: dir, limitBytes: limit, trimInterval: trimInterval), dir)
    }

    @Test func storesAndReadsBytesPerURL() async {
        let (cache, dir) = makeCache(limit: 1_000_000)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = URL(string: "https://img.example/a.jpg")!
        let b = URL(string: "https://img.example/b.jpg")!
        await cache.store(Data([1, 2, 3]), for: a)
        #expect(await cache.data(for: a) == Data([1, 2, 3]))
        #expect(await cache.data(for: b) == nil)
    }

    @Test func fileNamesDontContainTheURL() {
        let (cache, dir) = makeCache(limit: 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(string: "http://panel.example/images/user/secret/1.png")!
        let name = cache.fileURL(for: url).lastPathComponent
        #expect(name.count == 64)
        #expect(!name.contains("secret"))
    }

    @Test func trimRemovesTheLeastRecentlyUsedFirst() async throws {
        let (cache, dir) = makeCache(limit: 250)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = (0..<3).map { URL(string: "https://img.example/\($0).jpg")! }
        for (index, url) in urls.enumerated() {
            await cache.store(Data(repeating: UInt8(index), count: 100), for: url)
            // Distinct "last used" times, oldest first.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 10))],
                                                  ofItemAtPath: cache.fileURL(for: url).path)
        }
        // Reading the oldest makes it the most recently used.
        _ = await cache.data(for: urls[0])
        await cache.trim()
        // 300 bytes > 250: trimmed to ≤ 200 by removing the least recently used (urls[1]).
        #expect(await cache.data(for: urls[1]) == nil)
        #expect(await cache.data(for: urls[0]) != nil)
        #expect(await cache.data(for: urls[2]) != nil)
        #expect(await cache.size() <= 200)
    }

    @Test func storingTrimsEveryFewWrites() async {
        let (cache, dir) = makeCache(limit: 150, trimInterval: 2)
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<4 {
            await cache.store(Data(repeating: 0, count: 100), for: URL(string: "https://img.example/\(index)")!)
        }
        #expect(await cache.size() <= 150)
    }

    @Test func removeAllEmptiesTheFolder() async {
        let (cache, dir) = makeCache(limit: 1_000_000)
        defer { try? FileManager.default.removeItem(at: dir) }
        await cache.store(Data([1]), for: URL(string: "https://img.example/x")!)
        await cache.removeAll()
        #expect(await cache.size() == 0)
        #expect(await cache.data(for: URL(string: "https://img.example/x")!) == nil)
    }
}
