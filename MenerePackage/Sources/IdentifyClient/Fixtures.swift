import Foundation

/// Bundled fixtures for exercising the identify pipeline in later phases / tests.
public enum IdentifyFixtures {
    /// A synthetic wine-label PNG with readable text, for driving Vision OCR end-to-end.
    public static var sampleLabelImageData: Data {
        (try? Data(contentsOf: Bundle.module.url(forResource: "SampleLabel", withExtension: "png")!)) ?? Data()
    }
}
