import SwiftUI

struct YarnDetailView: View {
    @EnvironmentObject private var store: JSONProjectStore
    @Environment(\.locale) private var locale
    let yarnID: UUID
    @State private var showingEdit = false

    var body: some View {
        if let yarn = store.yarn(id: yarnID) {
            ZStack {
                WatercolorBackground()
                ScrollView {
                    VStack(spacing: 20) {
                        YarnPhotoView(url: store.photoURL(for: yarn))
                            .frame(width: 180, height: 180)
                            .clipShape(.rect(cornerRadius: 28, style: .continuous))

                        if hasDetails(yarn) {
                            WatercolorCard {
                                VStack(alignment: .leading, spacing: 14) {
                                    if let balls = yarn.remainingBalls {
                                        detailRow("yarn.remainingBalls") {
                                            Text(balls, format: .number)
                                        }
                                    }
                                    if let grams = yarn.remainingGrams {
                                        detailRow("yarn.remainingGrams") {
                                            Text(grams, format: .number)
                                        }
                                    }
                                    if let brand = yarn.brand {
                                        detailRow("yarn.brand") { Text(brand) }
                                    }
                                    if let series = yarn.series {
                                        detailRow("yarn.series") { Text(series) }
                                    }
                                    if let color = yarn.color {
                                        detailRow("yarn.color") { Text(color) }
                                    }
                                    if let colorCode = yarn.colorCode {
                                        detailRow("yarn.colorCode") { Text(colorCode) }
                                    }
                                    if let dyeLot = yarn.dyeLot {
                                        detailRow("yarn.dyeLot") { Text(dyeLot) }
                                    }
                                    if let storageLocation = yarn.storageLocation {
                                        detailRow("yarn.storageLocation") { Text(storageLocation) }
                                    }
                                    if let notes = yarn.notes {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text("yarn.notes")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(notes)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if hasLabelDetails(yarn) {
                            WatercolorCard {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("yarn.label.details")
                                        .font(.headline)
                                        .foregroundStyle(WatercolorTheme.ink)
                                    if let ballWeightGrams = yarn.ballWeightGrams {
                                        detailRow("yarn.ballWeightGrams") {
                                            Text(decimalText(ballWeightGrams))
                                        }
                                    }
                                    if let lengthMeters = yarn.lengthMeters {
                                        detailRow("yarn.lengthMeters") {
                                            Text(decimalText(lengthMeters))
                                        }
                                    }
                                    if let fiberContent = yarn.fiberContent {
                                        detailRow("yarn.fiberContent") { Text(fiberContent) }
                                    }
                                    if let recommendedNeedleMM = yarn.recommendedNeedleMM {
                                        detailRow("yarn.recommendedNeedleMM") {
                                            Text(metricRangeText(recommendedNeedleMM))
                                        }
                                    }
                                    if let recommendedHookMM = yarn.recommendedHookMM {
                                        detailRow("yarn.recommendedHookMM") {
                                            Text(metricRangeText(recommendedHookMM))
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        let labelPhotoURLs = store.labelPhotoURLs(for: yarn)
                        if !labelPhotoURLs.isEmpty {
                            WatercolorCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("yarn.labelPhotos")
                                        .font(.headline)
                                        .foregroundStyle(WatercolorTheme.ink)
                                    YarnLabelPhotoGallery(
                                        items: labelPhotoURLs.map(YarnLabelPhotoItem.stored)
                                    )
                                }
                            }
                        }

                        let linkedProjects = linkedProjects(for: yarn)
                        if !linkedProjects.isEmpty {
                            WatercolorCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("yarn.linkedProjects")
                                        .font(.headline)
                                        .foregroundStyle(WatercolorTheme.ink)

                                    ForEach(linkedProjects) { project in
                                        NavigationLink {
                                            ProjectDetailView(projectID: project.id)
                                        } label: {
                                            HStack(spacing: 10) {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(project.name)
                                                    if project.isCompleted {
                                                        Text("project.status.completed")
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                                Spacer(minLength: 8)
                                                Image(systemName: "chevron.right")
                                                    .accessibilityHidden(true)
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                            .contentShape(.rect)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(yarn.name)
            .toolbar {
                Button("yarn.edit", systemImage: "pencil") {
                    showingEdit = true
                }
            }
            .sheet(isPresented: $showingEdit) {
                EditYarnView(yarnID: yarnID)
            }
        }
    }

    private func hasDetails(_ yarn: StoredYarn) -> Bool {
        yarn.remainingBalls != nil ||
            yarn.remainingGrams != nil ||
            yarn.brand != nil ||
            yarn.series != nil ||
            yarn.color != nil ||
            yarn.colorCode != nil ||
            yarn.dyeLot != nil ||
            yarn.storageLocation != nil ||
            yarn.notes != nil
    }

    private func hasLabelDetails(_ yarn: StoredYarn) -> Bool {
        yarn.ballWeightGrams != nil ||
            yarn.lengthMeters != nil ||
            yarn.fiberContent != nil ||
            yarn.recommendedNeedleMM != nil ||
            yarn.recommendedHookMM != nil
    }

    private func decimalText(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    private func metricRangeText(_ range: YarnMetricRange) -> String {
        let lower = decimalText(range.lower)
        let upper = decimalText(range.upper)
        return range.lower == range.upper ? "\(lower) mm" : "\(lower)–\(upper) mm"
    }

    private func linkedProjects(for yarn: StoredYarn) -> [StoredProject] {
        store.projects.filter { yarn.linkedProjectIDs.contains($0.id) }
    }

    private func detailRow<Value: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder value: () -> Value
    ) -> some View {
        LabeledContent {
            value()
                .multilineTextAlignment(.trailing)
        } label: {
            Text(title)
                .foregroundStyle(.secondary)
        }
    }
}
