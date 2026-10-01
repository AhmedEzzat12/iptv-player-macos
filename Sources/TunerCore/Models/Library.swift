import Foundation

/// A reminder for an upcoming programme; optionally switches to the channel when it starts.
public struct Reminder: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var channelId: String
    public var channelName: String
    public var programKey: String
    public var title: String
    public var start: Date
    public var end: Date
    public var autoSwitch: Bool
    public var notified: Bool

    public init(id: String = UUID().uuidString, channelId: String, channelName: String, programKey: String, title: String, start: Date, end: Date, autoSwitch: Bool, notified: Bool = false) {
        self.id = id
        self.channelId = channelId
        self.channelName = channelName
        self.programKey = programKey
        self.title = title
        self.start = start
        self.end = end
        self.autoSwitch = autoSwitch
        self.notified = notified
    }
}

public struct Recording: Codable, Sendable, Identifiable, Hashable {
    public enum Status: String, Codable, Sendable {
        case scheduled
        case recording
        case completed
        case failed
        case cancelled
    }

    public var id: String
    public var channelId: String
    public var channelName: String
    public var title: String
    public var start: Date
    public var end: Date
    public var status: Status
    public var filePath: String?
    public var error: String?
    public var createdAt: Date

    public init(id: String = UUID().uuidString, channelId: String, channelName: String, title: String, start: Date, end: Date, status: Status = .scheduled, createdAt: Date = Date()) {
        self.id = id
        self.channelId = channelId
        self.channelName = channelName
        self.title = title
        self.start = start
        self.end = end
        self.status = status
        self.createdAt = createdAt
    }
}

public struct CustomGroup: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var sortIndex: Int

    public init(id: String = UUID().uuidString, name: String, sortIndex: Int) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
    }
}
