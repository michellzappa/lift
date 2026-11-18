import Foundation

enum LiftPosture: String, Codable, CaseIterable {
    case sitting
    case standing
    case unknown
    /// Nobody at this Mac, or Lift not running.
    case away

    var title: String {
        switch self {
        case .sitting: "Sitting"
        case .standing: "Standing"
        case .unknown: "Unknown"
        case .away: "Away"
        }
    }
}

struct PostureEvent: Codable, Equatable {
    let date: Date
    let posture: LiftPosture
    let height: Double?
}

enum HistoryRange: String, CaseIterable {
    case day
    case week
    case month
    case ninetyDays

    var title: String {
        switch self {
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .ninetyDays: "Last 90 days"
        }
    }

    var shortTitle: String {
        switch self {
        case .day: "24h"
        case .week: "7d"
        case .month: "30d"
        case .ninetyDays: "90d"
        }
    }
}

struct HistorySegment: Equatable {
    let start: Date
    let end: Date
    let posture: LiftPosture

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct HistoryBucket: Equatable {
    let start: Date
    let end: Date
    let sitting: TimeInterval
    let standing: TimeInterval
    let unknown: TimeInterval
    let away: TimeInterval

    /// Time someone was at this Mac.
    var active: TimeInterval { sitting + standing + unknown }
    var known: TimeInterval { sitting + standing }
}

struct HistorySummary: Equatable {
    let range: HistoryRange
    let start: Date
    let end: Date
    let segments: [HistorySegment]
    let buckets: [HistoryBucket]
    let sitting: TimeInterval
    let standing: TimeInterval
    let unknown: TimeInterval
    let away: TimeInterval
    let switches: Int

    var known: TimeInterval { sitting + standing }
    /// Time someone was at this Mac.
    var active: TimeInterval { known + unknown }
    /// Standing as a share of active time with a known posture.
    var standingShare: Double? { known > 0 ? standing / known : nil }
}

/// Stores stable sit/stand/away transitions locally. Sitting and standing
/// count only while `PresenceMonitor` says someone is at this Mac. The event
/// stream is kept separate from settings so reporting can change without
/// losing history.
@MainActor
final class PostureHistoryStore {
    static let didChange = Notification.Name("PostureHistoryStore.didChange")

    private static let settleDelay: Duration = .seconds(2)
    private static let retention: TimeInterval = 366 * 24 * 60 * 60

    private var events: [PostureEvent]
    private var currentPosture: LiftPosture?
    private var candidatePosture: LiftPosture?
    private var candidateStartedAt: Date?
    private var settleTask: Task<Void, Never>?

    private let fileURL: URL
    private let calendar: Calendar

    init(
        fileURL: URL? = nil,
        calendar: Calendar = .current
    ) {
        self.calendar = calendar
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.events = Self.load(from: self.fileURL).sorted { $0.date < $1.date }
        self.currentPosture = events.last?.posture
    }

    deinit {
        settleTask?.cancel()
    }

    /// Starts a new app session. A clean app termination also records this
    /// boundary so the previous session cannot run into the next one.
    func beginSession(at date: Date = Date()) {
        settleTask?.cancel()
        candidatePosture = nil
        candidateStartedAt = nil
        commit(.away, height: nil, at: date)
    }

    func endSession(at date: Date = Date()) {
        beginSession(at: date)
    }

    /// Feed the current desk observation into the history tracker.
    /// Only a posture that remains settled for a short delay is committed.
    func observe(
        status: DeskController.Status,
        height: Double?,
        isMoving: Bool,
        settings: LiftSettings,
        isPresent: Bool,
        presenceChangedAt: Date,
        at date: Date = Date()
    ) {
        guard isPresent else {
            settleTask?.cancel()
            candidatePosture = nil
            candidateStartedAt = nil
            commit(.away, height: nil, at: presenceChangedAt)
            return
        }

        guard case .connected = status, let height, !isMoving else {
            settleTask?.cancel()
            candidatePosture = nil
            candidateStartedAt = nil
            commit(.unknown, height: nil, at: date)
            return
        }

        let posture = settings.posture(at: height)
        guard posture != currentPosture else {
            settleTask?.cancel()
            candidatePosture = nil
            candidateStartedAt = nil
            return
        }

        if candidatePosture == posture, candidateStartedAt != nil { return }

        settleTask?.cancel()
        candidatePosture = posture
        candidateStartedAt = date
        let candidateDate = date
        settleTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.settleDelay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.candidatePosture == posture,
                  self.candidateStartedAt == candidateDate
            else { return }
            self.commit(posture, height: height, at: candidateDate.addingTimeInterval(2))
            self.candidatePosture = nil
            self.candidateStartedAt = nil
            self.settleTask = nil
        }
    }

    func clear() {
        settleTask?.cancel()
        candidatePosture = nil
        candidateStartedAt = nil
        currentPosture = nil
        events.removeAll()
        save()
        changed()
    }

    func summary(for range: HistoryRange, now: Date = Date()) -> HistorySummary {
        let bounds = bounds(for: range, now: now)
        let segments = intervals(in: DateInterval(start: bounds.start, end: bounds.end))

        let buckets = bucketRanges(for: range, bounds: bounds).map { bucket in
            var sitting: TimeInterval = 0
            var standing: TimeInterval = 0
            var unknown: TimeInterval = 0
            var away: TimeInterval = 0
            for segment in segments {
                let start = max(segment.start, bucket.start)
                let end = min(segment.end, bucket.end)
                guard start < end else { continue }
                switch segment.posture {
                case .sitting: sitting += end.timeIntervalSince(start)
                case .standing: standing += end.timeIntervalSince(start)
                case .unknown: unknown += end.timeIntervalSince(start)
                case .away: away += end.timeIntervalSince(start)
                }
            }
            return HistoryBucket(start: bucket.start, end: bucket.end, sitting: sitting, standing: standing, unknown: unknown, away: away)
        }

        var sitting: TimeInterval = 0
        var standing: TimeInterval = 0
        var unknown: TimeInterval = 0
        var away: TimeInterval = 0
        for segment in segments {
            switch segment.posture {
            case .sitting: sitting += segment.duration
            case .standing: standing += segment.duration
            case .unknown: unknown += segment.duration
            case .away: away += segment.duration
            }
        }

        return HistorySummary(
            range: range,
            start: bounds.start,
            end: bounds.end,
            segments: segments,
            buckets: buckets,
            sitting: sitting,
            standing: standing,
            unknown: unknown,
            away: away,
            switches: switchCount(in: DateInterval(start: bounds.start, end: bounds.end))
        )
    }

    private func commit(_ posture: LiftPosture, height: Double?, at date: Date) {
        guard currentPosture != posture else { return }
        // Away can be backdated to the last input; never before the last event.
        let date = max(date, events.last?.date ?? date)
        events.append(PostureEvent(date: date, posture: posture, height: height))
        events.sort { $0.date < $1.date }
        currentPosture = posture
        prune(around: date)
        save()
        changed()
    }

    private func intervals(in range: DateInterval) -> [HistorySegment] {
        let sorted = events.sorted { $0.date < $1.date }
        var posture = sorted.last(where: { $0.date <= range.start })?.posture ?? .unknown
        var cursor = range.start
        var result: [HistorySegment] = []

        for event in sorted where event.date > range.start && event.date < range.end {
            if cursor < event.date {
                result.append(HistorySegment(start: cursor, end: event.date, posture: posture))
            }
            posture = event.posture
            cursor = event.date
        }
        if cursor < range.end {
            result.append(HistorySegment(start: cursor, end: range.end, posture: posture))
        }
        return result
    }

    private func switchCount(in range: DateInterval) -> Int {
        let relevant = events.filter { $0.date > range.start && $0.date <= range.end }
        var previous: LiftPosture? = events.last(where: {
            $0.date <= range.start && ($0.posture == .sitting || $0.posture == .standing)
        })?.posture
        var count = 0
        for event in relevant {
            guard event.posture == .sitting || event.posture == .standing else { continue }
            if let previous, previous != event.posture { count += 1 }
            previous = event.posture
        }
        return count
    }

    private func bounds(for range: HistoryRange, now: Date) -> (start: Date, end: Date) {
        switch range {
        case .day:
            return (now.addingTimeInterval(-24 * 60 * 60), now)
        case .week:
            let today = calendar.startOfDay(for: now)
            return (calendar.date(byAdding: .day, value: -6, to: today) ?? today, now)
        case .month:
            let today = calendar.startOfDay(for: now)
            return (calendar.date(byAdding: .day, value: -29, to: today) ?? today, now)
        case .ninetyDays:
            let today = calendar.startOfDay(for: now)
            return (calendar.date(byAdding: .day, value: -89, to: today) ?? today, now)
        }
    }

    private func bucketRanges(for range: HistoryRange, bounds: (start: Date, end: Date)) -> [DateInterval] {
        if range == .day { return [DateInterval(start: bounds.start, end: bounds.end)] }

        let step = range == .ninetyDays ? 7 : 1
        var result: [DateInterval] = []
        var start = calendar.startOfDay(for: bounds.start)
        while start < bounds.end {
            let next = calendar.date(byAdding: .day, value: step, to: start) ?? bounds.end
            result.append(DateInterval(start: start, end: min(next, bounds.end)))
            start = next
        }
        return result
    }

    private func prune(around date: Date) {
        let cutoff = date.addingTimeInterval(-Self.retention)
        events = events.filter { $0.date >= cutoff }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(events) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> [PostureEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PostureEvent].self, from: data)) ?? []
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Lift", isDirectory: true).appendingPathComponent("posture-history.json")
    }
}
