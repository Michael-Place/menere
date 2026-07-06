import Photos
import Testing
@testable import PhotoLibraryClient

struct PhotoLibraryClientTests {
    @Test
    func mediaTypeMapsFromPHAssetMediaType() {
        #expect(PhotoMediaType(.image) == .image)
        #expect(PhotoMediaType(.video) == .video)
        #expect(PhotoMediaType(.audio) == .audio)
        #expect(PhotoMediaType(.unknown) == .unknown)
    }

    @Test
    func filterDefaultsToImagesUncapped() {
        let filter = PhotoAssetFilter()
        #expect(filter.mediaType == .image)
        #expect(filter.onlyFavorites == false)
        #expect(filter.dateRange == nil)
        #expect(filter.albumID == nil)
        #expect(filter.limit == nil)
    }

    @Test
    func previewClientIsAuthorizedAndEmpty() async {
        let client = PhotoLibraryClient.previewValue
        #expect(client.authorizationStatus() == .authorized)
        #expect(await client.requestAccess() == .authorized)
        #expect(await client.fetchAssets(PhotoAssetFilter()).isEmpty)
        #expect(await client.fetchAlbums().isEmpty)
        #expect(await client.loadFullImage("x") == nil)
    }

    @Test
    func changeStreamDefaultFinishesImmediately() async {
        // The default (test) endpoint yields no changes and completes — safe for units.
        var count = 0
        for await _ in PhotoLibraryClient.previewValue.observeLibraryChanges() { count += 1 }
        #expect(count == 0)
    }
}
