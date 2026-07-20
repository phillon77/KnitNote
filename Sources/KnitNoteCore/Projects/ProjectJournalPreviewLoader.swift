import CoreGraphics
import Foundation
import ImageIO

public struct ProjectJournalPreview: @unchecked Sendable {
    public let image: CGImage

    public var pixelWidth: Int { image.width }
    public var pixelHeight: Int { image.height }

    init(image: CGImage) {
        self.image = image
    }
}

public enum ProjectJournalPreviewLoader {
    public static func load(data: Data, maximumPixelSize: Int) async -> ProjectJournalPreview? {
        guard maximumPixelSize > 0 else { return nil }
        return await detachedPreview {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return makePreview(source: source, maximumPixelSize: maximumPixelSize)
        }
    }

    public static func load(url: URL, maximumPixelSize: Int) async -> ProjectJournalPreview? {
        guard maximumPixelSize > 0 else { return nil }
        return await detachedPreview {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return makePreview(source: source, maximumPixelSize: maximumPixelSize)
        }
    }

    private static func detachedPreview(
        _ operation: @escaping @Sendable () -> ProjectJournalPreview?
    ) async -> ProjectJournalPreview? {
        let task = Task.detached(priority: .utility) { () -> ProjectJournalPreview? in
            guard !Task.isCancelled else { return nil }
            let preview = operation()
            guard !Task.isCancelled else { return nil }
            return preview
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func makePreview(
        source: CGImageSource,
        maximumPixelSize: Int
    ) -> ProjectJournalPreview? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return ProjectJournalPreview(image: image)
    }
}
