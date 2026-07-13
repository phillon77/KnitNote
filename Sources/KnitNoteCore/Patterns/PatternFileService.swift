import Foundation
import CoreGraphics
import ImageIO
public enum PatternFileError: Error, Equatable { case empty, tooLarge, unsupported, invalidContent }
public struct PatternFileService: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static func live() -> PatternFileService { .init(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KnitNote/Patterns")) }
    public func importFile(from source: URL, projectID: UUID) throws -> PatternDocument {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw PatternFileError.empty }
        guard size <= 100_000_000 else { throw PatternFileError.tooLarge }
        let ext = source.pathExtension.lowercased(); let kind: PatternKind
        if ext == "pdf" { kind = .pdf; guard let pdf=CGPDFDocument(source as CFURL), pdf.numberOfPages > 0 else { throw PatternFileError.invalidContent } }
        else if ["png","jpg","jpeg","heic"].contains(ext) { kind = .image; guard let image=CGImageSourceCreateWithURL(source as CFURL,nil), CGImageSourceGetCount(image)>0 else { throw PatternFileError.invalidContent } }
        else { throw PatternFileError.unsupported }
        let id=UUID(); let dir=root.appendingPathComponent(projectID.uuidString); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename="\(id.uuidString).\(ext)"; try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(filename))
        return PatternDocument(id:id, displayName:source.deletingPathExtension().lastPathComponent, kind:kind, storedFilename:filename)
    }
    public func url(projectID: UUID, pattern: PatternDocument) -> URL { root.appendingPathComponent(projectID.uuidString).appendingPathComponent(pattern.storedFilename) }
    public func delete(projectID: UUID, pattern: PatternDocument) throws { try FileManager.default.removeItem(at: url(projectID: projectID, pattern: pattern)) }
}
