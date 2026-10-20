import CompressCore
import Foundation
import Testing
@testable import Compress

@MainActor
@Suite struct DragWheelTests {
    private let images = WheelSlice.slices(for: [.image], fileCount: 1)

    @Test func imagesGetEditingAndConversionSlices() {
        let titles = images.map(\.title)
        #expect(titles.first == "Compress")
        #expect(titles.contains("Convert") && titles.contains("Rotate") && titles.contains("No BG"))
        #expect(!titles.contains("Split") && !titles.contains("Merge"))
    }

    @Test func pdfsOfferSplitOnlyForOneFile() {
        #expect(WheelSlice.slices(for: [.pdf], fileCount: 1).map(\.title).contains("Split"))
        let many = WheelSlice.slices(for: [.pdf], fileCount: 3).map(\.title)
        #expect(many.contains("Merge") && !many.contains("Split"))
    }

    @Test func convertOffersOnlyFormatsThatApply() {
        #expect(ConvertChoice.choices(for: [.audio]) == [.m4a, .wav, .aiff])
        #expect(ConvertChoice.choices(for: [.pdf]) == [.pagesPNG, .pagesJPEG])
        #expect(ConvertChoice.mp4.spec(for: .image) == nil)
    }

    @Test func pointsMapToSlicesClockwiseFromTheTop() {
        let count = images.count
        let r: CGFloat = 120
        #expect(WheelGeometry.hit(dx: 0, dy: -r, slices: images, expanded: nil) == .slice(0))
        // Straight right is a quarter of the way round.
        let quarter = Int((Double(count) / 4).rounded())
        #expect(WheelGeometry.hit(dx: r, dy: 0, slices: images, expanded: nil) == .slice(quarter % count))
        // Just left of the top belongs to the last slice.
        #expect(WheelGeometry.hit(dx: -4, dy: -r, slices: images, expanded: nil) == .slice(0))
        #expect(WheelGeometry.hit(dx: 0, dy: 10, slices: images, expanded: nil) == .center)
    }

    @Test func outerRingFollowsTheExpandedSlice() {
        let convert = images.firstIndex { $0.title == "Convert" }!
        let angle = WheelGeometry.center(of: convert, count: images.count) * .pi / 180
        let r: CGFloat = 215
        let dx = r * CGFloat(sin(angle)), dy = -r * CGFloat(cos(angle))
        let hit = WheelGeometry.hit(dx: dx, dy: dy, slices: images, expanded: convert)
        guard case .child(let parent, let index) = hit else { Issue.record("expected a child, got \(hit)"); return }
        #expect(parent == convert)
        // Children are centered on the parent, so this lands in the middle one.
        #expect(index == images[convert].children.count / 2)
        #expect(WheelGeometry.hit(dx: dx, dy: dy, slices: images, expanded: nil) == .none)
    }
}
