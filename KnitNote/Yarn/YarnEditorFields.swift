import Foundation
import SwiftUI

enum YarnOperationFailure: String {
    case photoInvalid = "yarn.error.photoInvalid"
    case archiveUnavailable = "yarn.error.archiveUnavailable"
    case linkedProjectsChanged = "yarn.error.linkedProjectsChanged"
    case saveRetry = "yarn.error.saveRetry"
    case deleteFailed = "yarn.error.deleteFailed.message"

    static func saving(_ error: any Error) -> Self {
        if error is YarnPhotoFileError {
            return .photoInvalid
        }
        if let storeError = error as? ProjectStoreError {
            switch storeError {
            case .unreadableArchive, .archiveUnavailable:
                return .archiveUnavailable
            case .invalidYarnProjectLinks:
                return .linkedProjectsChanged
            case .persistenceFailed:
                return .saveRetry
            }
        }
        return .saveRetry
    }

    static func deleting(_ error: any Error) -> Self {
        if let storeError = error as? ProjectStoreError,
           storeError == .unreadableArchive || storeError == .archiveUnavailable {
            return .archiveUnavailable
        }
        return .deleteFailed
    }
}

struct YarnEditorDraft {
    var name = ""
    var brand = ""
    var series = ""
    var color = ""
    var colorCode = ""
    var dyeLot = ""
    var remainingBalls = YarnInventoryEditValue()
    var remainingGrams = YarnInventoryEditValue()
    var storageLocation = ""
    var notes = ""
    var linkedProjectIDs: Set<UUID> = []

    init() {}

    init(yarn: StoredYarn, locale: Locale) {
        name = yarn.name
        brand = yarn.brand ?? ""
        series = yarn.series ?? ""
        color = yarn.color ?? ""
        colorCode = yarn.colorCode ?? ""
        dyeLot = yarn.dyeLot ?? ""
        remainingBalls = YarnInventoryEditValue(value: yarn.remainingBalls, locale: locale)
        remainingGrams = YarnInventoryEditValue(value: yarn.remainingGrams, locale: locale)
        storageLocation = yarn.storageLocation ?? ""
        notes = yarn.notes ?? ""
        linkedProjectIDs = yarn.linkedProjectIDs
    }

    func canSave(locale: Locale) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            remainingBalls.input(locale: locale).isValid &&
            remainingGrams.input(locale: locale).isValid
    }

    func makeYarn(locale: Locale) throws -> StoredYarn {
        let yarn = try StoredYarn(name: name)
        return try applyingDetails(to: yarn, locale: locale)
    }

    func applying(to yarn: StoredYarn, locale: Locale) throws -> StoredYarn {
        var yarn = yarn
        try yarn.rename(to: name)
        return try applyingDetails(to: yarn, locale: locale)
    }

    private func applyingDetails(to yarn: StoredYarn, locale: Locale) throws -> StoredYarn {
        var yarn = yarn
        try yarn.updateInventory(
            balls: remainingBalls.resolvedValue(locale: locale),
            grams: remainingGrams.resolvedValue(locale: locale)
        )
        try yarn.updateDetails(
            brand: brand,
            series: series,
            color: color,
            colorCode: colorCode,
            dyeLot: dyeLot,
            storageLocation: storageLocation,
            notes: notes
        )
        yarn.setLinkedProjectIDs(linkedProjectIDs)
        return yarn
    }
}

struct YarnEditorFields: View {
    @Environment(\.locale) private var locale
    @Binding var draft: YarnEditorDraft

    var body: some View {
        Section {
            TextField("yarn.name", text: $draft.name)
        }

        Section {
            TextField("yarn.brand", text: $draft.brand)
            TextField("yarn.series", text: $draft.series)
            TextField("yarn.color", text: $draft.color)
            TextField("yarn.colorCode", text: $draft.colorCode)
            TextField("yarn.dyeLot", text: $draft.dyeLot)
        }

        Section {
            decimalField("yarn.remainingBalls", text: $draft.remainingBalls.text)
            validationMessage(for: draft.remainingBalls)
            decimalField("yarn.remainingGrams", text: $draft.remainingGrams.text)
            validationMessage(for: draft.remainingGrams)
        }

        Section {
            TextField("yarn.storageLocation", text: $draft.storageLocation)
            TextField("yarn.notes", text: $draft.notes, axis: .vertical)
                .lineLimit(3...8)
        }

        Section {
            NavigationLink {
                ChooseYarnProjectsView(selectedProjectIDs: $draft.linkedProjectIDs)
            } label: {
                LabeledContent("yarn.linkedProjects") {
                    Text(draft.linkedProjectIDs.count, format: .number)
                }
            }
        }
    }

    @ViewBuilder
    private func decimalField(_ titleKey: LocalizedStringKey, text: Binding<String>) -> some View {
#if os(iOS)
        TextField(titleKey, text: text)
            .keyboardType(.decimalPad)
#else
        TextField(titleKey, text: text)
#endif
    }

    @ViewBuilder
    private func validationMessage(for value: YarnInventoryEditValue) -> some View {
        switch value.input(locale: locale) {
        case .invalid:
            Text("yarn.error.invalidNumber")
                .font(.caption)
                .foregroundStyle(.red)
        case .negative:
            Text("yarn.error.negativeInventory")
                .font(.caption)
                .foregroundStyle(.red)
        case .empty, .value:
            EmptyView()
        }
    }
}
