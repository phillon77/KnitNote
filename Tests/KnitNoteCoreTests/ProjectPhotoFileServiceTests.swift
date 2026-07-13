import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Test func projectPhotoSaveNormalizesAndUsesUniqueFilenames() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = ProjectPhotoFileService(directory: directory)
    let projectID = UUID()
    let source = try makeJPEG(width: 2400, height: 1200)

    let first = try service.save(data: source, projectID: projectID)
    let second = try service.save(data: source, projectID: projectID)

    #expect(first != second)
    #expect(first.hasPrefix(projectID.uuidString + "-"))
    #expect(first.hasSuffix(".jpg"))
    #expect(FileManager.default.fileExists(atPath: service.url(filename: first).path))
    #expect(FileManager.default.fileExists(atPath: service.url(filename: second).path))

    let saved = try Data(contentsOf: service.url(filename: first))
    let sourceRef = try #require(CGImageSourceCreateWithData(saved as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(sourceRef, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1600)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 800)
}

@Test func projectPhotoSaveRejectsInvalidDataAndDeleteIsIdempotent() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = ProjectPhotoFileService(directory: directory)

    #expect(throws: ProjectPhotoFileError.invalidImage) {
        try service.save(data: Data("not an image".utf8), projectID: UUID())
    }

    let filename = try service.save(data: makeJPEG(width: 40, height: 20), projectID: UUID())
    try service.delete(filename: filename)
    try service.delete(filename: filename)
    #expect(!FileManager.default.fileExists(atPath: service.url(filename: filename).path))
}

private func makeJPEG(width: Int, height: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.45, green: 0.35, blue: 0.75, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
