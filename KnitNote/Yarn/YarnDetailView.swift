import SwiftUI

struct YarnDetailView: View {
    @EnvironmentObject private var store: JSONProjectStore
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
