import AppKit
import HouseKit

@MainActor
final class HistoryPage: SettingsForm {
    private let history: PostureHistoryStore
    private let sittingLabel = SettingsForm.label("—")
    private let standingLabel = SettingsForm.label("—")
    private let shareLabel = SettingsForm.label("—")
    private let switchesLabel = SettingsForm.label("—")
    private let activeLabel = SettingsForm.label("—")
    private let chart = HistoryChartView()
    private lazy var rangePopup = SettingsForm.popup()
    private lazy var clearButton = SettingsForm.button("Clear History…", target: self, action: #selector(clearHistory))
    private var timer: Timer?

    init(history: PostureHistoryStore, store: LiftStore) {
        self.history = history
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: PostureHistoryStore.didChange, object: history)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: LiftStore.didChange, object: store)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        section("Posture history")
        rangePopup.addItems(withTitles: HistoryRange.allCases.map(\.title))
        rangePopup.target = self
        rangePopup.action = #selector(rangeChanged(_:))
        row("Range", rangePopup)
        row("Sitting", sittingLabel)
        row("Standing", standingLabel)
        row("Standing share", shareLabel)
        row("Switches", switchesLabel)
        row("At this Mac", activeLabel)
        row(nil, chart)
        chart.heightAnchor.constraint(equalToConstant: 190).isActive = true
        note("Lift counts sitting and standing only while you are at this Mac: local keyboard or mouse input in the last 5 minutes, screen awake and unlocked. A Screen Sharing session counts as away. Bars show time at this Mac. Unknown means you were here but the desk was disconnected, moving, or between presets.")
        section("Data")
        row(nil, clearButton)
        note("History is stored locally on this Mac. Clearing it cannot be undone.")
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        timer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(refreshTimer(_:)), userInfo: nil, repeats: true)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        timer?.invalidate()
        timer = nil
    }

    @objc private func rangeChanged(_ sender: NSPopUpButton) {
        refresh()
    }

    @objc private func refreshTimer(_ timer: Timer) {
        refresh()
    }

    @objc func refresh() {
        let range = HistoryRange.allCases[min(max(rangePopup.indexOfSelectedItem, 0), HistoryRange.allCases.count - 1)]
        let summary = history.summary(for: range)
        sittingLabel.stringValue = Self.formatDuration(summary.sitting)
        standingLabel.stringValue = Self.formatDuration(summary.standing)
        shareLabel.stringValue = summary.standingShare.map { String(Int(($0 * 100).rounded())) + "%" } ?? "—"
        switchesLabel.stringValue = String(summary.switches)
        activeLabel.stringValue = Self.formatDuration(summary.active)
        chart.summary = summary
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear posture history?"
        alert.informativeText = "All stored sitting and standing history will be removed from this Mac."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        history.clear()
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = max(0, Int(duration.rounded(.down) / 60))
        if minutes < 60 { return String(minutes) + "m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? String(hours) + "h" : String(hours) + "h " + String(remainder) + "m"
    }
}

@MainActor
private final class HistoryChartView: NSView {
    var summary: HistorySummary? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let summary else { return }
        let inset: CGFloat = 8
        let legendHeight: CGFloat = 24
        let chartRect = NSRect(x: inset, y: legendHeight, width: bounds.width - inset * 2, height: bounds.height - legendHeight - 8)
        guard chartRect.width > 0, chartRect.height > 0 else { return }

        drawLegend(at: NSPoint(x: inset, y: 4))
        if summary.range == .day {
            drawTimeline(summary, in: chartRect)
        } else {
            drawBuckets(summary.buckets, in: chartRect)
        }
    }

    private func drawLegend(at origin: NSPoint) {
        let items: [(String, NSColor)] = [
            ("Sitting", .systemBlue),
            ("Standing", .systemGreen),
            ("Unknown", .systemGray),
            ("Away", .quaternaryLabelColor)
        ]
        var x = origin.x
        for (title, color) in items {
            color.setFill()
            NSBezierPath(rect: NSRect(x: x, y: origin.y + 3, width: 9, height: 9)).fill()
            let text = NSString(string: title)
            text.draw(at: NSPoint(x: x + 13, y: origin.y), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            x += 76
        }
    }

    private func drawTimeline(_ summary: HistorySummary, in rect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(rect: rect).fill()
        let duration = max(summary.end.timeIntervalSince(summary.start), 1)
        for segment in summary.segments where segment.posture != .away {
            let x = rect.minX + rect.width * CGFloat(segment.start.timeIntervalSince(summary.start) / duration)
            let endX = rect.minX + rect.width * CGFloat(segment.end.timeIntervalSince(summary.start) / duration)
            color(for: segment.posture).setFill()
            NSBezierPath(rect: NSRect(x: x, y: rect.minY, width: max(endX - x, 1), height: rect.height)).fill()
        }
        drawTimelineLabel("24 hours ago", at: rect.minX, y: rect.maxY + 3, alignment: .left)
        drawTimelineLabel("Now", at: rect.maxX, y: rect.maxY + 3, alignment: .right)
    }

    private func drawBuckets(_ buckets: [HistoryBucket], in rect: NSRect) {
        guard !buckets.isEmpty else { return }
        let gap: CGFloat = buckets.count > 20 ? 2 : 5
        let width = max((rect.width - gap * CGFloat(buckets.count - 1)) / CGFloat(buckets.count), 2)
        let maxTotal = max(buckets.map(\.active).max() ?? 0, 1)

        for (index, bucket) in buckets.enumerated() {
            let x = rect.minX + CGFloat(index) * (width + gap)
            let height = rect.height * CGFloat(bucket.active / maxTotal)
            let barRect = NSRect(x: x, y: rect.maxY - height, width: width, height: height)
            let total = max(bucket.active, 1)
            var y = barRect.minY
            for (value, posture) in [(bucket.sitting, LiftPosture.sitting), (bucket.standing, .standing), (bucket.unknown, .unknown)] {
                let segmentHeight = barRect.height * CGFloat(value / total)
                color(for: posture).setFill()
                NSBezierPath(rect: NSRect(x: x, y: y, width: width, height: segmentHeight)).fill()
                y += segmentHeight
            }
            // 30 daily bars cannot all carry a date; label every seventh.
            if buckets.count <= 14 || index % 7 == 0 {
                let label = DateFormatter.shortDate.string(from: bucket.start)
                drawTimelineLabel(label, at: x + width / 2, y: rect.maxY + 3, alignment: .center)
            }
        }
    }

    private func color(for posture: LiftPosture) -> NSColor {
        switch posture {
        case .sitting: .systemBlue
        case .standing: .systemGreen
        case .unknown: .systemGray
        case .away: .quaternaryLabelColor
        }
    }

    private func drawTimelineLabel(_ string: String, at x: CGFloat, y: CGFloat, alignment: NSTextAlignment) {
        let text = NSString(string: string)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        let drawX: CGFloat
        switch alignment {
        case .right: drawX = x - size.width
        case .center: drawX = x - size.width / 2
        default: drawX = x
        }
        text.draw(at: NSPoint(x: drawX, y: y), withAttributes: attributes)
    }
}

private extension DateFormatter {
    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}
