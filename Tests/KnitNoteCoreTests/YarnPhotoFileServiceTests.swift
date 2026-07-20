import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Test func yarnPhotoSaveNormalizesAndUsesUniqueFilenames() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = YarnPhotoFileService(directory: directory)
    let yarnID = UUID()
    let source = try makeYarnJPEG(width: 2400, height: 1200)

    let first = try service.save(data: source, yarnID: yarnID)
    let second = try service.save(data: source, yarnID: yarnID)

    #expect(first != second)
    #expect(first.hasPrefix(yarnID.uuidString + "-"))
    #expect(first.hasSuffix(".jpg"))
    #expect(FileManager.default.fileExists(atPath: service.url(filename: first).path))
    #expect(FileManager.default.fileExists(atPath: service.url(filename: second).path))

    let saved = try Data(contentsOf: service.url(filename: first))
    let sourceRef = try #require(CGImageSourceCreateWithData(saved as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(sourceRef, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1600)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 800)
}

@Test func invalidYarnPhotoIsRejectedAndDeleteIsIdempotent() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = YarnPhotoFileService(directory: directory)

    #expect(throws: YarnPhotoFileError.invalidImage) {
        try service.save(data: Data("not-image".utf8), yarnID: UUID())
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path))

    let filename = try service.save(data: makeYarnJPEG(width: 40, height: 20), yarnID: UUID())
    try service.delete(filename: filename)
    try service.delete(filename: filename)
    #expect(!FileManager.default.fileExists(atPath: service.url(filename: filename).path))
}

@Test func reconciliationDeletesOnlyUnreferencedManagedPhotos() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = YarnPhotoFileService(directory: directory)
    let retained = try service.save(data: makeYarnJPEG(width: 40, height: 20), yarnID: UUID())
    let orphan = try service.save(data: makeYarnJPEG(width: 40, height: 20), yarnID: UUID())
    let unrelatedURL = directory.appendingPathComponent("keep-me.txt")
    try Data("not managed by YarnPhotoFileService".utf8).write(to: unrelatedURL)

    try service.reconcile(referencedFilenames: [retained])

    #expect(FileManager.default.fileExists(atPath: service.url(filename: retained).path))
    #expect(!FileManager.default.fileExists(atPath: service.url(filename: orphan).path))
    #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
}

private func makeYarnJPEG(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.7, green: 0.3, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
