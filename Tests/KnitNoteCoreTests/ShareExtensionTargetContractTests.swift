import Foundation
import Testing
import UniformTypeIdentifiers

@Suite struct ShareExtensionTargetContractTests {
    @Test func appAndShareExtensionUseTheSameAppGroupEntitlement() throws {
        let appURL = patternLibraryRepositoryURL("KnitNote/KnitNote-iOS.entitlements")
        let shareURL = patternLibraryRepositoryURL("KnitNoteShare/KnitNoteShare.entitlements")
        let appExists = FileManager.default.fileExists(atPath: appURL.path)
        let shareExists = FileManager.default.fileExists(atPath: shareURL.path)

        #expect(appExists)
        #expect(shareExists)
        guard appExists, shareExists else { return }

        let expected = ["group.com.phillon.KnitNote"]
        #expect(try applicationGroups(at: appURL) == expected)
        #expect(try applicationGroups(at: shareURL) == expected)
    }

    @Test func activationRuleAcceptsExactlyOneSupportedFileAndNothingElse() throws {
        let plistURL = patternLibraryRepositoryURL("KnitNoteShare/Info.plist")
        let exists = FileManager.default.fileExists(atPath: plistURL.path)

        #expect(exists)
        guard exists else { return }

        let plist = try #require(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: plistURL),
                format: nil
            ) as? [String: Any]
        )
        let extensionDictionary = try #require(plist["NSExtension"] as? [String: Any])
        #expect(extensionDictionary["NSExtensionPointIdentifier"] as? String == "com.apple.share-services")
        let attributes = try #require(extensionDictionary["NSExtensionAttributes"] as? [String: Any])
        let rule = try #require(attributes["NSExtensionActivationRule"] as? String)
        let predicate = NSPredicate(format: rule)

        #expect(predicate.evaluate(with: activationContext([[UTType.pdf.identifier]])))
        #expect(predicate.evaluate(with: activationContext([[UTType.png.identifier]])))
        #expect(predicate.evaluate(with: activationContext([[UTType.jpeg.identifier]])))
        #expect(predicate.evaluate(with: activationContext([[UTType.heic.identifier]])))
        #expect(!predicate.evaluate(with: activationContext([])))
        #expect(!predicate.evaluate(with: activationContext([[UTType.url.identifier]])))
        #expect(!predicate.evaluate(with: activationContext([
            [UTType.pdf.identifier],
            [UTType.pdf.identifier],
        ])))
        #expect(predicate.evaluate(with: activationContext([[
            UTType.pdf.identifier,
            UTType.url.identifier,
        ]])))
    }

    @Test func canonicalProjectHasAnEmbeddedIOSOnlyShareTarget() throws {
        let project = try readRepositoryFile("KnitNote.xcodeproj/project.pbxproj")

        #expect(project.contains("KnitNoteShare.appex"))
        #expect(project.contains("com.phillon.KnitNote.share"))
        #expect(project.contains("KnitNoteShare.appex in Embed Foundation Extensions"))
        #expect(project.contains("platformFilter = ios;"))
        #expect(!project.contains("KnitNoteShare.appex in Embed Watch Content"))
    }
}

private func applicationGroups(at url: URL) throws -> [String] {
    let plist = try #require(
        PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            format: nil
        ) as? [String: Any]
    )
    return try #require(plist["com.apple.security.application-groups"] as? [String])
}

private func activationContext(_ attachmentTypes: [[String]]) -> [String: Any] {
    let item = NSExtensionItem()
    item.attachments = attachmentTypes.map { typeIdentifiers in
        let provider = NSItemProvider()
        for typeIdentifier in typeIdentifiers {
            provider.registerDataRepresentation(
                forTypeIdentifier: typeIdentifier,
                visibility: .all
            ) { completion in
                completion(Data([0x00]), nil)
                return nil
            }
        }
        return provider
    }
    return ["extensionItems": attachmentTypes.isEmpty ? [] : [item]]
}
