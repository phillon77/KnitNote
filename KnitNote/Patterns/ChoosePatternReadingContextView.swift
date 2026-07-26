import SwiftUI

struct PatternReadingChoice: Identifiable {
    let usage: PatternProjectUsage
    let project: StoredProject
    var id: UUID { usage.id }
}

struct PatternReaderRoute: Identifiable {
    let context: PatternReaderContext
    var id: String {
        context.usageID?.uuidString ?? "readonly-\(context.patternID.uuidString)"
    }
}

struct ChoosePatternReadingContextView: View {
    @Environment(\.dismiss) private var dismiss
    let patternID: UUID
    let choices: [PatternReadingChoice]
    let onSelect: (PatternReaderContext) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    select(PatternReaderContext.readOnly(patternID: patternID))
                } label: {
                    Label("patterns.reader.readOnly", systemImage: "book")
                        .frame(minHeight: 44)
                }

                ForEach(choices) { choice in
                    Button {
                        select(PatternReaderContext.project(
                            patternID: patternID,
                            usageID: choice.usage.id,
                            projectID: choice.project.id,
                            projectIsCompleted: choice.project.isCompleted
                        ))
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(choice.project.name)
                                    .foregroundStyle(WatercolorTheme.ink)
                                if choice.project.isCompleted {
                                    Text("project.status.completed")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityHint(Text("patterns.reader.chooseContext.message"))
                }
            }
            .navigationTitle("patterns.reader.chooseContext.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
        }
    }

    private func select(_ context: PatternReaderContext) {
        onSelect(context)
        dismiss()
    }
}
