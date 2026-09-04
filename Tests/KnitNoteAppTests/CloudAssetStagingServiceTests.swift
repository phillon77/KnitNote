import CryptoKit
import Foundation
import Testing

@testable import KnitNote

@Suite struct CloudAssetStagingServiceTests {
    @Test func serviceReservesTheTaskFourExtensionBoundary() {
        requireTaskFourBoundary(CloudAssetStagingService.self)
    }

    @Test func canonicalMetadataStillRejectsInvalidDigest() throws {
        #expect(throws: SyncAttachmentVersionError.invalidMetadata) {
            _ = try SyncAttachmentVersion.issuing(
                slot: SyncAttachmentSlot(
                    owner: SyncEntityID(kind: .project, uuid: UUID()),
                    role: "cover",
                    slotID: "primary"
                ),
                contentSHA256: Data(repeating: 1, count: 31),
                byteCount: 1,
                mediaType: "image/jpeg",
                displayFilename: "cover.jpg"
            )
        }
    }
}

private func requireTaskFourBoundary<T: CloudAssetStagingBoundary>(_: T.Type) {}
