import Baichuan
import Foundation

/// When a camera saw motion: closed spans plus, while motion lasts, an open one.
public struct MotionLog: Sendable {
    public private(set) var spans: [DateInterval] = []
    public private(set) var openSince: Date?

    public init() {}

    /// Records a change of the motion state. Repeating the current state changes nothing.
    public mutating func report(_ motion: Bool, at date: Date) {
        if motion {
            if openSince == nil { openSince = date }
        } else if let start = openSince {
            openSince = nil
            spans.append(DateInterval(start: start, end: max(start, date)))
        }
    }

    /// Every span, the open one ending at `now`.
    public func spans(now: Date) -> [DateInterval] {
        guard let openSince else { return spans }
        return spans + [DateInterval(start: openSince, end: max(openSince, now))]
    }

    /// The keep rule: whether motion, widened by `before` seconds at its start and `after`
    /// seconds at its end, touches `segment`.
    public func touches(_ segment: DateInterval, before: TimeInterval, after: TimeInterval, now: Date) -> Bool {
        spans(now: now).contains { span in
            span.start.addingTimeInterval(-before) <= segment.end && span.end.addingTimeInterval(after) >= segment.start
        }
    }

    /// The motion inside `segment`, clipped to it.
    public func spans(in segment: DateInterval, now: Date) -> [DateInterval] {
        spans(now: now).compactMap { $0.intersection(with: segment) }
    }

    /// Forgets spans that ended before `date`.
    public mutating func prune(before date: Date) {
        spans.removeAll { $0.end < date }
    }
}

/// Motion detection for a camera that pushes no motion events: judges by the size of the
/// predicted frames, without decoding. A still picture compresses to small P frames; movement
/// makes them grow. Compares each second's P-frame bytes with a slowly following baseline.
///
/// This is coarse: a camera that holds its bit rate constant hides most of the difference,
/// and rain, snow or a switch to night vision look like motion until the baseline has caught up.
public struct FrameSizeMotionDetector: Sendable {
    /// A second counts as motion when it is this many times the baseline …
    static let onRatio = 1.6
    /// … and as quiet again below this.
    static let offRatio = 1.3
    static let secondsToStart = 2
    static let secondsToStop = 3
    static let warmUpSeconds = 5

    private var bucketStart: Date?
    private var bucketBytes = 0
    private var warmUp: [Double] = []
    /// The quiet level in P-frame bytes per second; nil while warming up.
    public private(set) var baseline: Double?
    private var above = 0
    private var below = 0
    public private(set) var isMotion = false

    public init() {}

    /// Adds a frame. Returns the new motion state when this frame changed it.
    public mutating func add(_ frame: BCMediaFrame, at date: Date) -> Bool? {
        switch frame {
        case .videoKeyFrame: return add(bytes: 0, at: date)  // key frames are large whatever happens
        case .videoFrame(_, let data, _): return add(bytes: data.count, at: date)
        case .info, .aac, .adpcm: return nil
        }
    }

    mutating func add(bytes: Int, at date: Date) -> Bool? {
        guard let start = bucketStart else {
            bucketStart = date
            bucketBytes = bytes
            return nil
        }
        let elapsed = date.timeIntervalSince(start)
        guard elapsed >= 1 else {
            bucketBytes += bytes
            return nil
        }
        let rate = Double(bucketBytes) / elapsed
        bucketStart = date
        bucketBytes = bytes
        // A gap in the stream says nothing about the picture.
        guard elapsed < 3 else { return nil }
        return evaluate(rate)
    }

    private mutating func evaluate(_ rate: Double) -> Bool? {
        guard let level = baseline else {
            warmUp.append(rate)
            if warmUp.count >= Self.warmUpSeconds { baseline = warmUp.sorted()[warmUp.count / 2] }
            return nil
        }
        let ratio = rate / max(level, 1)
        if !isMotion {
            if ratio > Self.onRatio {
                above += 1
            } else {
                above = 0
                baseline = level + 0.1 * (rate - level)
            }
            if above >= Self.secondsToStart {
                isMotion = true
                below = 0
                return true
            }
        } else {
            // Follow slowly even now, so a lasting change of the scene ends the motion after a while.
            baseline = level + 0.01 * (rate - level)
            below = ratio < Self.offRatio ? below + 1 : 0
            if below >= Self.secondsToStop {
                isMotion = false
                above = 0
                return false
            }
        }
        return nil
    }
}
