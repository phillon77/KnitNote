import Foundation
import Testing

@Suite struct YarnLabelStorageContractTests {
    @Test func settingsIncludesAsynchronousLabelPhotoStorageRow() throws {
        let settings = try source("KnitNote/Settings/SettingsView.swift")
        let row = try source("KnitNote/Settings/YarnLabelStorageRow.swift")

        #expect(settings.contains("YarnLabelStorageRow()"))
        #expect(row.contains("ByteCountFormatter"))
        #expect(row.contains("ProgressView"))
        #expect(row.contains("yarn.labelPhotos.storage.unavailable"))
        #expect(row.contains(".accessibilityValue"))
        #expect(row.contains("await store.yarnLabelPhotoStorageBytes()"))
    }

    @Test func storageRefreshesAfterLabelPhotoMutation() throws {
        let row = try source("KnitNote/Settings/YarnLabelStorageRow.swift")
        let store = try source("Sources/KnitNoteCore/Projects/JSONProjectStore.swift")

        #expect(row.contains(".yarnLabelPhotosDidChange"))
        #expect(row.contains(".task"))
        #expect(store.contains("NotificationCenter.default.post"))
        #expect(store.contains(".yarnLabelPhotosDidChange"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }
}
