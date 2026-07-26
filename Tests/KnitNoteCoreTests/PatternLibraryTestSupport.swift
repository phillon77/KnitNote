import CoreGraphics
import Foundation

func makeTestPatternPDF(at url: URL, pageCount: Int = 1) throws {
    let pageCount = max(1, pageCount)
    guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }

    let mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
    for _ in 0..<pageCount {
        context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
        context.endPDFPage()
    }
    context.closePDF()
}

func readRepositoryFile(_ relativePath: String) throws -> String {
    try String(contentsOf: patternLibraryRepositoryURL(relativePath), encoding: .utf8)
}

func patternLibraryRepositoryURL(_ relativePath: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(relativePath)
}
