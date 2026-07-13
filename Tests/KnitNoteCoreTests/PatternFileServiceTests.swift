import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Test func rejectsEmptyAndUnsupportedPatternFiles() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service=PatternFileService(root:root)
    let empty=root.appendingPathComponent("empty.pdf"); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); try Data().write(to:empty)
    #expect(throws: PatternFileError.empty) { _ = try service.importFile(from:empty,projectID:UUID()) }
    let text=root.appendingPathComponent("notes.txt"); try Data("hello".utf8).write(to:text)
    #expect(throws: PatternFileError.unsupported) { _ = try service.importFile(from:text,projectID:UUID()) }
}

@Test func rejectsInvalidImageContent() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service=PatternFileService(root:root); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let fake=root.appendingPathComponent("fake.png"); try Data("not an image".utf8).write(to:fake)
    #expect(throws: PatternFileError.invalidContent) { _ = try service.importFile(from:fake,projectID:UUID()) }
}

@Test func importsValidPDFAndPNGWithUniqueStoredNames() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source=root.appendingPathComponent("source"); try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
    let pdf=source.appendingPathComponent("chart.pdf"); var box=CGRect(x:0,y:0,width:100,height:100)
    let consumer=CGDataConsumer(url:pdf as CFURL)!; let pdfContext=CGContext(consumer:consumer,mediaBox:&box,nil)!; pdfContext.beginPDFPage(nil); pdfContext.endPDFPage(); pdfContext.closePDF()
    let png=source.appendingPathComponent("chart.png"); let space=CGColorSpaceCreateDeviceRGB(); let bitmap=CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!; let image=bitmap.makeImage()!; let destination=CGImageDestinationCreateWithURL(png as CFURL,UTType.png.identifier as CFString,1,nil)!; CGImageDestinationAddImage(destination,image,nil); #expect(CGImageDestinationFinalize(destination))
    let service=PatternFileService(root:root.appendingPathComponent("stored")); let projectID=UUID()
    let first=try service.importFile(from:pdf,projectID:projectID); let second=try service.importFile(from:pdf,projectID:projectID); let third=try service.importFile(from:png,projectID:projectID)
    #expect(first.kind == .pdf); #expect(third.kind == .image); #expect(first.storedFilename != second.storedFilename)
    #expect(FileManager.default.fileExists(atPath:service.url(projectID:projectID,pattern:first).path))
    #expect(FileManager.default.fileExists(atPath:service.url(projectID:projectID,pattern:third).path))
}
