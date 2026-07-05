import Dependencies
import Foundation
import Testing
@testable import PhotoCurationClient

/// The live PhotoKit path needs an app host + Photos authorization, so it's exercised via the
/// `-photoCurationSpike` in-app harness on the simulator. These unit tests cover the pure /
/// dependency surface that runs anywhere.
struct PhotoCurationClientTests {
    @Test func previewValueReportsAddedImages() async {
        let client = PhotoCurationClient.previewValue
        let result = await client.addImages([Data([0x1]), Data([0x2])], "Bacán — TV")
        #expect(result.addedCount == 2)
        #expect(result.albumLocalIdentifier == "preview-album-id")
    }

    @Test func addImagesEmptyInputYieldsEmptyResult() async {
        // The live engine short-circuits empty input before touching PhotoKit; assert the shape.
        let result = await PhotoCurationEngine.addImages([], toAlbumNamed: "Bacán — TV")
        #expect(result.addedCount == 0)
        #expect(result.assetLocalIdentifiers.isEmpty)
    }

    @Test func sampleImageDataProducesRealPNG() {
        let data = PhotoCurationDemoView.sampleImageData(seed: "Fajita", color: .systemTeal)
        #expect(data != nil)
        // PNG magic number.
        #expect(data?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }
}
