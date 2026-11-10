import AppKit
import SwiftUI
import Testing

@testable import GlintApp

@MainActor @Suite struct RecordingDetailsTests {
    @Test func cameraAndStatusChangesKeepSheetHeightStable() {
        var heights: [CGFloat] = []
        for camera in [false, true] {
            for text in [
                "Checking…", "About 121.1 MB a minute.",
                String(repeating: "A device needs permission. Open System Settings to enable it. ", count: 20),
            ] {
                let view = NSHostingView(
                    rootView: VStack(spacing: 16) {
                        Text("Recording options")
                        RecordingDetails {
                            if camera { Color.black.frame(height: 56) }
                            Text(text).fixedSize(horizontal: false, vertical: true)
                        }
                        Button("Record") {}
                    }.frame(width: 516))
                heights.append(view.fittingSize.height)
            }
        }
        #expect(heights.allSatisfy { abs($0 - heights[0]) < 0.5 })
        #expect(heights[0] > 128)
    }
}
