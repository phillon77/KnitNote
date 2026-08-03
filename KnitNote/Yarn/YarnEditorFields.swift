import Foundation
import SwiftUI

enum YarnOperationFailure: String {
    case photoInvalid = "yarn.error.photoInvalid"
    case archiveUnavailable = "yarn.error.archiveUnavailable"
    case linkedProjectsChanged = "yarn.error.linkedProjectsChanged"
    case saveRetry = "yarn.error.saveRetry"
    case deleteFailed = "yarn.error.deleteFailed.message"
    case completedProjectLink = "yarn.error.completedProjectLink"

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
            case .persistenceFailed, .patternNotFound, .staleDataGeneration, .accessRestricted:
                return .saveRetry
            }
        }
        return .saveRetry
    }

    static func deleting(_ error: any Error) -> Self {
        if let linkError = error as? ProjectYarnLinkError,
           linkError == .projectCompleted {
            return .completedProjectLink
        }
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
    var ballWeightGrams = YarnInventoryEditValue()
    var lengthMeters = YarnInventoryEditValue()
    var fiberContent = ""
    var needleLowerMM = YarnInventoryEditValue()
    var needleUpperMM = YarnInventoryEditValue()
    var hookLowerMM = YarnInventoryEditValue()
    var hookUpperMM = YarnInventoryEditValue()
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
        ballWeightGrams = YarnInventoryEditValue(value: yarn.ballWeightGrams, locale: locale)
        lengthMeters = YarnInventoryEditValue(value: yarn.lengthMeters, locale: locale)
        fiberContent = yarn.fiberContent ?? ""
        needleLowerMM = YarnInventoryEditValue(value: yarn.recommendedNeedleMM?.lower, locale: locale)
        needleUpperMM = YarnInventoryEditValue(value: yarn.recommendedNeedleMM?.upper, locale: locale)
        hookLowerMM = YarnInventoryEditValue(value: yarn.recommendedHookMM?.lower, locale: locale)
        hookUpperMM = YarnInventoryEditValue(value: yarn.recommendedHookMM?.upper, locale: locale)
        remainingBalls = YarnInventoryEditValue(value: yarn.remainingBalls, locale: locale)
        remainingGrams = YarnInventoryEditValue(value: yarn.remainingGrams, locale: locale)
        storageLocation = yarn.storageLocation ?? ""
        notes = yarn.notes ?? ""
        linkedProjectIDs = yarn.linkedProjectIDs
    }

    func canSave(locale: Locale) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            remainingBalls.input(locale: locale).isValid &&
            remainingGrams.input(locale: locale).isValid &&
            ballWeightGrams.input(locale: locale).isValid &&
            lengthMeters.input(locale: locale).isValid &&
            metricRangeIsValid(lower: needleLowerMM, upper: needleUpperMM, locale: locale) &&
            metricRangeIsValid(lower: hookLowerMM, upper: hookUpperMM, locale: locale)
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
        try yarn.updateLabelDetails(
            ballWeightGrams: ballWeightGrams.resolvedValue(locale: locale),
            lengthMeters: lengthMeters.resolvedValue(locale: locale),
            fiberContent: fiberContent,
            recommendedNeedleMM: try metricRange(
                lower: needleLowerMM,
                upper: needleUpperMM,
                locale: locale
            ),
            recommendedHookMM: try metricRange(
                lower: hookLowerMM,
                upper: hookUpperMM,
                locale: locale
            )
        )
        yarn.setLinkedProjectIDs(linkedProjectIDs)
        return yarn
    }

    mutating func apply(_ seed: YarnLabelDraftSeed, locale: Locale) {
        if let value = seed.brand { brand = value }
        if let value = seed.series {
            series = value
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = value }
        }
        if let value = seed.color { color = value }
        if let value = seed.colorCode { colorCode = value }
        if let value = seed.dyeLot { dyeLot = value }
        if let value = seed.ballWeightGrams {
            ballWeightGrams = YarnInventoryEditValue(value: value, locale: locale)
        }
        if let value = seed.lengthMeters {
            lengthMeters = YarnInventoryEditValue(value: value, locale: locale)
        }
        if let value = seed.fiberContent { fiberContent = value }
        if let value = seed.recommendedNeedleMM {
            needleLowerMM = YarnInventoryEditValue(value: value.lower, locale: locale)
            needleUpperMM = YarnInventoryEditValue(value: value.upper, locale: locale)
        }
        if let value = seed.recommendedHookMM {
            hookLowerMM = YarnInventoryEditValue(value: value.lower, locale: locale)
            hookUpperMM = YarnInventoryEditValue(value: value.upper, locale: locale)
        }
    }

    private func metricRangeIsValid(
        lower: YarnInventoryEditValue,
        upper: YarnInventoryEditValue,
        locale: Locale
    ) -> Bool {
        let lowerInput = lower.input(locale: locale)
        let upperInput = upper.input(locale: locale)
        if lowerInput == .empty && upperInput == .empty { return true }
        guard case let .value(lowerValue) = lowerInput,
              case let .value(upperValue) = upperInput else { return false }
        return upperValue >= lowerValue
    }

    private func metricRange(
        lower: YarnInventoryEditValue,
        upper: YarnInventoryEditValue,
        locale: Locale
    ) throws -> YarnMetricRange? {
        guard let lowerValue = lower.resolvedValue(locale: locale),
              let upperValue = upper.resolvedValue(locale: locale) else { return nil }
        return try YarnMetricRange(lower: lowerValue, upper: upperValue)
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

        Section("yarn.label.details") {
            decimalField("yarn.ballWeightGrams", text: $draft.ballWeightGrams.text)
            validationMessage(for: draft.ballWeightGrams)
            decimalField("yarn.lengthMeters", text: $draft.lengthMeters.text)
            validationMessage(for: draft.lengthMeters)
            TextField("yarn.fiberContent", text: $draft.fiberContent, axis: .vertical)
                .lineLimit(2...5)
            metricRangeFields(
                "yarn.recommendedNeedleMM",
                lower: $draft.needleLowerMM.text,
                upper: $draft.needleUpperMM.text
            )
            metricRangeFields(
                "yarn.recommendedHookMM",
                lower: $draft.hookLowerMM.text,
                upper: $draft.hookUpperMM.text
            )
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

    private func metricRangeFields(
        _ titleKey: LocalizedStringKey,
        lower: Binding<String>,
        upper: Binding<String>
    ) -> some View {
        HStack {
            Text(titleKey)
            Spacer()
            decimalField("yarn.range.lower", text: lower)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 76)
            Text("–")
            decimalField("yarn.range.upper", text: upper)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 76)
            Text("mm")
                .foregroundStyle(.secondary)
        }
    }
}
