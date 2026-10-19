// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Authoritative default-display system bar geometry, shared by the guest probe
/// and both renderers. Missing, truncated, or mismatched observations are covered;
/// never guess a status bar height or crop an application's own toolbar.
final class AndroidSystemBars {
    nonisolated(unsafe) static let shared = AndroidSystemBars()
    private let lock = NSLock()
    private var observation: Observation?

    @discardableResult
    func update(fromDisplayDump dump: String) -> Bool {
        let parsed = Self.parse(dump)
        lock.lock()
        observation = parsed
        lock.unlock()
        return parsed != nil
    }

    func reset() {
        lock.lock()
        observation = nil
        lock.unlock()
    }

    func crop(width: Int, height: Int) -> RuntimeDisplayGeometry.Crop? {
        lock.lock()
        defer { lock.unlock() }
        return observation?.crop(width: width, height: height)
    }

    struct Observation: Equatable {
        let physicalWidth: Int
        let physicalHeight: Int
        let content: RuntimeDisplayGeometry.Crop

        func crop(width: Int, height: Int) -> RuntimeDisplayGeometry.Crop? {
            guard width == physicalWidth, height == physicalHeight else { return nil }
            return content
        }
    }

    /// AOSP DisplayContent.dump -> WindowInsetsStateController -> InsetsState.
    /// Stop before Control map, whose provider copies may have stale visibility.
    /// RotationUtils defines the logical-to-physical transform used below.
    static func parse(_ dump: String) -> Observation? {
        var inDefaultDisplay = false
        var displayCount = 0
        var frames: [Int]?
        var controller = false
        var state = false
        var finished = false
        var displayFrame: [Int]?
        var bars: [[Int]] = []
        var barSourceCount = 0

        for rawLine in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = captures(#"^Display: mDisplayId=(\d+)(?:\s|$)"#, line)?.first.flatMap(Int.init) {
                inDefaultDisplay = id == 0
                if inDefaultDisplay {
                    displayCount += 1
                    guard displayCount == 1 else { return nil }
                }
                continue
            }
            guard inDefaultDisplay else { continue }
            if line.hasPrefix("DisplayFrames ") {
                guard frames == nil,
                      let values = captures(#"^DisplayFrames w=(\d+) h=(\d+) r=([0-3])$"#, line),
                      values.count == 3 else { return nil }
                frames = values.compactMap(Int.init)
                continue
            }
            if line == "WindowInsetsStateController" {
                guard !controller else { return nil }
                controller = true
                continue
            }
            guard controller, !finished else { continue }
            if line == "InsetsState" {
                guard !state else { return nil }
                state = true
                continue
            }
            guard state else { continue }
            if line == "Control map:" { finished = true; continue }
            if line.hasPrefix("mDisplayFrame=") {
                guard displayFrame == nil,
                      let values = captures(#"^mDisplayFrame=Rect\((-?\d+),\s*(-?\d+)\s*-\s*(-?\d+),\s*(-?\d+)\)$"#, line),
                      values.count == 4 else { return nil }
                displayFrame = values.compactMap(Int.init)
                continue
            }
            guard line.hasPrefix("InsetsSource "),
                  line.contains("type=statusBars") || line.contains("type=navigationBars") else { continue }
            guard let values = captures(#"^InsetsSource id=\S+ type=(statusBars|navigationBars) frame=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\](?: visibleFrame=\[-?\d+,-?\d+\]\[-?\d+,-?\d+\])? visible=(true|false)(?:\s|$)"#, line),
                  values.count == 6 else { return nil }
            barSourceCount += 1
            if values[5] == "true" {
                let rect = values[1...4].compactMap(Int.init)
                guard rect.count == 4 else { return nil }
                bars.append(rect)
            }
        }
        guard displayCount == 1, finished, barSourceCount > 0,
              let frames, frames.count == 3, let displayFrame, displayFrame.count == 4 else { return nil }
        let w = frames[0], h = frames[1], rotation = frames[2]
        guard w > 0, h > 0, w <= 16384, h <= 16384,
              displayFrame == [0, 0, w, h] else { return nil }
        var left = 0, top = 0, right = w, bottom = h
        for bar in bars {
            let l = bar[0], t = bar[1], r = bar[2], b = bar[3]
            guard l >= 0, t >= 0, r <= w, b <= h, r > l, b > t else { return nil }
            if l == 0 && r == w && t == 0 && b < h { top = max(top, b) }
            else if l == 0 && r == w && b == h && t > 0 { bottom = min(bottom, t) }
            else if t == 0 && b == h && l == 0 && r < w { left = max(left, r) }
            else if t == 0 && b == h && r == w && l > 0 { right = min(right, l) }
            else { return nil } // Floating/partial rectangles cannot define a safe full-edge crop.
        }
        guard right - left >= w / 2, bottom - top >= h / 2 else { return nil }
        let logical = RuntimeDisplayGeometry.Crop(left: Double(left) / Double(w), top: Double(top) / Double(h),
            right: Double(right) / Double(w), bottom: Double(bottom) / Double(h))
        let physical: RuntimeDisplayGeometry.Crop
        switch rotation {
        case 1:
            physical = .init(left: 1 - logical.bottom, top: logical.left,
                             right: 1 - logical.top, bottom: logical.right)
        case 2:
            physical = .init(left: 1 - logical.right, top: 1 - logical.bottom,
                             right: 1 - logical.left, bottom: 1 - logical.top)
        case 3:
            physical = .init(left: logical.top, top: 1 - logical.right,
                             right: logical.bottom, bottom: 1 - logical.left)
        default: physical = logical
        }
        guard physical.isValid else { return nil }
        return Observation(physicalWidth: rotation % 2 == 0 ? w : h,
                           physicalHeight: rotation % 2 == 0 ? h : w, content: physical)
    }

    private static func captures(_ pattern: String, _ input: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: input).map { String(input[$0]) }
        }
    }
}
