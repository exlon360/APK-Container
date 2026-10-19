// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
enum AndroidSystemBarsTests {
    static func main() {
        typealias Bars = AndroidSystemBars
        typealias Crop = RuntimeDisplayGeometry.Crop
        func dump(w: Int = 1280, h: Int = 960, rotation: Int = 0,
                  status: String = "[0,0][1280,24]", navigation: String = "[0,912][1280,960]",
                  visible: Bool = true) -> String {
            """
            WINDOW MANAGER DISPLAY CONTENTS (dumpsys window displays)
              Display: mDisplayId=0 (organized)
              DisplayFrames w=\(w) h=\(h) r=\(rotation)
              WindowInsetsStateController
                InsetsState
                  mDisplayFrame=Rect(0, 0 - \(w), \(h))
                  mRoundedCornerFrame=Rect(0, 0 - \(w), \(h))
                    InsetsSource id=1 type=statusBars frame=\(status) visible=\(visible) flags= sideHint=TOP boundingRects=null
                    InsetsSource id=2 type=navigationBars frame=\(navigation) visible=\(visible) flags= sideHint=BOTTOM boundingRects=null
                    InsetsSource id=3 type=ime frame=[0,400][1280,960] visible=true flags= sideHint=BOTTOM boundingRects=null
                    InsetsSource id=4 type=captionBar frame=[0,24][1280,80] visible=true flags= sideHint=TOP boundingRects=null
                Control map:
                  InsetsSource id=1 type=statusBars frame=[0,0][1280,200] visible=true flags= sideHint=TOP boundingRects=null
              Display: mDisplayId=2
              DisplayFrames w=640 h=480 r=0
              WindowInsetsStateController
                InsetsState
                  mDisplayFrame=Rect(0, 0 - 640, 480)
                    InsetsSource id=1 type=statusBars frame=[0,0][640,100] visible=true flags= sideHint=TOP boundingRects=null
                Control map:
            """
        }
        func near(_ a: Double, _ b: Double) { precondition(abs(a - b) < 0.000001, "\(a) != \(b)") }
        let sample = dump()
        let parsed = Bars.parse(sample)!
        precondition(parsed.physicalWidth == 1280 && parsed.physicalHeight == 960)
        precondition(parsed.content == Crop(left: 0, top: 24.0 / 960, right: 1, bottom: 912.0 / 960))
        precondition(parsed.crop(width: 960, height: 1280) == nil)
        precondition(Bars.parse(dump(visible: false))!.content == .full, "Immersive app keeps its complete frame")
        precondition(Bars.parse(sample.replacingOccurrences(of: "frame=[0,0][1280,24] visible=",
                    with: "frame=[0,0][1280,24] visibleFrame=[0,0][1280,24] visible=")) == parsed)
        // Ignore IME, app captions, provider duplicates, and other displays.
        precondition(parsed.content.top < 80.0 / 960 && parsed.content.bottom > 400.0 / 960)
        for (rotation, expected) in [
            (1, Crop(left: 0.05, top: 0, right: 0.975, bottom: 1)),
            (2, Crop(left: 0, top: 0.05, right: 1, bottom: 0.975)),
            (3, Crop(left: 0.025, top: 0, right: 0.95, bottom: 1)),
        ] {
            let state = Bars.parse(dump(rotation: rotation))!
            near(state.content.left, expected.left); near(state.content.top, expected.top)
            near(state.content.right, expected.right); near(state.content.bottom, expected.bottom)
            precondition(state.physicalWidth == (rotation % 2 == 0 ? 1280 : 960))
            precondition(state.physicalHeight == (rotation % 2 == 0 ? 960 : 1280))
        }
        let sideBar = Bars.parse(dump(navigation: "[1232,0][1280,960]"))!
        near(sideBar.content.right, 1232.0 / 1280)
        let leftBar = Bars.parse(dump(navigation: "[0,0][48,960]"))!
        near(leftBar.content.left, 48.0 / 1280)
        for invalid in [
            "", sample.replacingOccurrences(of: "DisplayFrames w=1280 h=960 r=0", with: "DisplayFrames w=1280 h=960 r=9"),
            String(sample.prefix(while: { $0 != "C" })),
            sample.replacingOccurrences(of: "Control map:", with: "TRUNCATED"),
            sample.replacingOccurrences(of: "Rect(0, 0 - 1280, 960)", with: "Rect(0, 0 - 720, 1280)"),
            dump(status: "[0,0][1279,24]"), dump(status: "[0,10][1280,24]"),
            dump(status: "[0,0][1280,960]"), dump(status: "[0,0][1280,800]"),
            dump(status: "[-1,0][1280,24]"), dump(navigation: "[0,912][1280,961]"),
            sample.replacingOccurrences(of: "visible=true", with: "visible=maybe"),
            sample.replacingOccurrences(of: "Display: mDisplayId=2", with: "Display: mDisplayId=0"),
            sample.replacingOccurrences(of: "type=statusBars", with: "type=unknown").replacingOccurrences(of: "type=navigationBars", with: "type=unknown"),
        ] { precondition(Bars.parse(invalid) == nil, "Malformed/missing geometry must stay covered") }

        let state = Bars()
        precondition(state.crop(width: 1280, height: 960) == nil)
        precondition(state.update(fromDisplayDump: sample))
        precondition(state.crop(width: 1280, height: 960) == parsed.content)
        precondition(state.crop(width: 800, height: 600) == nil)
        precondition(!state.update(fromDisplayDump: "bridge failed"))
        precondition(state.crop(width: 1280, height: 960) == nil, "Do not retain a stale crop after invalid data")
        _ = state.update(fromDisplayDump: sample)
        state.reset()
        precondition(state.crop(width: 1280, height: 960) == nil)

        let geometry = RuntimeDisplayGeometry(width: 1280, height: 960, rotated: false, crop: parsed.content)
        near(geometry.contentHeight, 888)
        let topLeft = geometry.normalizedPoint(x: 0, y: 0, viewWidth: 1280, viewHeight: 888)!
        near(topLeft.x, 0.5 / 1280); near(topLeft.y, 24.5 / 960)
        let guestPixel = RuntimeDisplayGeometry.pixels(topLeft, width: 1280, height: 960)!
        precondition(guestPixel.0 == 0 && guestPixel.1 == 24)
        let center = geometry.normalizedPoint(x: 640, y: 444, viewWidth: 1280, viewHeight: 888)!
        near(center.x, 0.5); near(center.y, 468.0 / 960)
        precondition(geometry.normalizedPoint(x: 20, y: 0, viewWidth: 1280, viewHeight: 960) == nil,
                     "Touches in the new letterbox must not hit hidden bars")
        let rotated = RuntimeDisplayGeometry(width: 1280, height: 960, rotated: true, crop: parsed.content)
        let rotatedCorner = rotated.normalizedPoint(x: 0, y: 0, viewWidth: 888, viewHeight: 1280)!
        near(rotatedCorner.x, 1279.5 / 1280); near(rotatedCorner.y, 24.5 / 960)
        let sideGeometry = RuntimeDisplayGeometry(width: 1280, height: 960, rotated: true, crop: sideBar.content)
        let sidePoint = sideGeometry.normalizedPoint(x: 0, y: 0, viewWidth: sideGeometry.effectiveWidth,
                                                     viewHeight: sideGeometry.effectiveHeight)!
        precondition(RuntimeDisplayGeometry.pixels(sidePoint, width: 1280, height: 960)!.0 == 1231,
                     "A rotated edge must not activate the hidden navigation column")
        print("Android system bar crop tests passed")
    }
}
