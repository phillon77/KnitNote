import SwiftUI

struct PatternDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    let patternID: UUID

    @State private var showingRename = false
    @State private var showingNoteEditor = false
    @State private var showingProjectChooser = false
    @State private var showingReadingChooser = false
    @State private var showingDeleteConfirmation = false
    @State private var readerRoute: PatternReaderRoute?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let pattern, let asset {
                ZStack {
                    WatercolorBackground()
                    ScrollView {
                        VStack(spacing: 18) {
                            responsiveHeader(pattern: pattern)
                            informationCard(pattern: pattern, asset: asset)
                            noteCard(pattern: pattern)
                            linkedProjectsCard
                            actionsCard
                            deletionCard
                        }
                        .padding()
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                }
                .navigationTitle(pattern.displayName)
                .patternDetailNavigationTitleStyle()
                .toolbar {
                    Menu {
                        Button("patterns.detail.rename", systemImage: "pencil") {
                            showingRename = true
                        }
                        Button("patterns.detail.editNote", systemImage: "note.text") {
                            showingNoteEditor = true
                        }
                    } label: {
                        Label("patterns.detail.rename", systemImage: "ellipsis.circle")
                            .patternToolbarTextLabelStyle()
                    }
                    .accessibilityLabel(Text("patterns.detail.rename"))
                }
                .sheet(isPresented: $showingRename) {
                    PatternNameEditor(initialValue: pattern.displayName) { value in
                        perform {
                            try store.renamePattern(id: patternID, to: value)
                        }
                    }
                }
                .sheet(isPresented: $showingNoteEditor) {
                    PatternNoteEditor(initialValue: pattern.note ?? "") { value in
                        perform {
                            try store.setPatternNote(id: patternID, note: value)
                        }
                    }
                }
                .sheet(isPresented: $showingProjectChooser) {
                    ChoosePatternProjectLinkView(
                        patternID: patternID,
                        projects: availableProjects
                    ) { projectID in
                        perform {
                            try store.linkPattern(patternID: patternID, to: projectID)
                        }
                    }
                }
                .sheet(isPresented: $showingReadingChooser) {
                    ChoosePatternReadingContextView(
                        patternID: patternID,
                        choices: readingChoices
                    ) { context in
                        readerRoute = PatternReaderRoute(context: context)
                    }
                }
                .patternReaderPresentation(item: $readerRoute) { route in
                    PatternReaderView(context: route.context)
                }
                .confirmationDialog(
                    "patterns.detail.delete.confirm.title",
                    isPresented: $showingDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("patterns.detail.delete", role: .destructive) {
                        deletePattern()
                    }
                    Button("common.cancel", role: .cancel) {}
                } message: {
                    Text("patterns.detail.delete.confirm.message")
                }
                .alert(
                    "patterns.error",
                    isPresented: Binding(
                        get: { errorMessage != nil },
                        set: { if !$0 { errorMessage = nil } }
                    )
                ) {
                    Button("common.ok") {}
                } message: {
                    Text(errorMessage ?? "")
                }
            } else {
                ContentUnavailableView(
                    "patterns.missing",
                    systemImage: "doc.questionmark"
                )
            }
        }
    }

    @ViewBuilder
    private func responsiveHeader(pattern: StoredPattern) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 22) {
                thumbnail
                headerDetails(pattern: pattern)
            }
            VStack(spacing: 16) {
                thumbnail
                headerDetails(pattern: pattern)
            }
        }
    }

    private var thumbnail: some View {
        PatternThumbnailView(patternID: patternID)
            .frame(width: 180, height: 220)
    }

    private func headerDetails(pattern: StoredPattern) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pattern.displayName)
                .font(.title2.bold())
                .foregroundStyle(WatercolorTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Button("patterns.detail.open", systemImage: "book") {
                openPattern()
            }
            .buttonStyle(.borderedProminent)
            .tint(WatercolorTheme.actionBerry)
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func informationCard(
        pattern: StoredPattern,
        asset: PatternAsset
    ) -> some View {
        WatercolorCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("patterns.detail.information")
                    .font(.headline)
                    .foregroundStyle(WatercolorTheme.ink)
                detailRow("patterns.detail.fileType") {
                    Text(patternAssetDescription(asset, locale: locale))
                }
                detailRow("patterns.detail.fileSize") {
                    Text(asset.byteCount, format: .byteCount(style: .file))
                }
                detailRow("patterns.detail.added") {
                    Text(pattern.createdAt, format: .dateTime.year().month().day())
                }
            }
        }
    }

    private func noteCard(pattern: StoredPattern) -> some View {
        WatercolorCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("patterns.detail.note")
                        .font(.headline)
                        .foregroundStyle(WatercolorTheme.ink)
                    Spacer()
                    Button("patterns.detail.editNote") {
                        showingNoteEditor = true
                    }
                }
                Text(pattern.note ?? String(
                    localized: "patterns.detail.note.empty",
                    locale: locale
                ))
                    .foregroundStyle(pattern.note == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var linkedProjectsCard: some View {
        WatercolorCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("patterns.detail.linkedProjects")
                    .font(.headline)
                    .foregroundStyle(WatercolorTheme.ink)

                if activeProjects.isEmpty {
                    Text("patterns.library.unused")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activeProjects) { project in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name)
                                    .fixedSize(horizontal: false, vertical: true)
                                if project.isCompleted {
                                    Text("project.status.completed")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            Button("patterns.detail.unlink", role: .destructive) {
                                unlink(projectID: project.id)
                            }
                            .buttonStyle(.borderless)
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionsCard: some View {
        WatercolorCard {
            VStack(spacing: 12) {
                Button {
                    showingProjectChooser = true
                } label: {
                    Label("patterns.detail.linkProject", systemImage: "link.badge.plus")
                        .patternActionLabelLayout()
                }

                if let originalURL = try? store.patternAssetURL(patternID: patternID) {
                    ShareLink(item: originalURL) {
                        Label("patterns.detail.export", systemImage: "square.and.arrow.up")
                            .patternActionLabelLayout()
                    }
                }
            }
        }
    }

    private var deletionCard: some View {
        WatercolorCard {
            VStack(alignment: .leading, spacing: 10) {
                if !activeProjects.isEmpty {
                    Text("patterns.detail.deleteBlocked")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(activeProjects.map(\.name).joined(separator: "\n"))
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("patterns.detail.delete", systemImage: "trash")
                        .patternActionLabelLayout()
                }
                .disabled(!activeProjects.isEmpty)
            }
        }
    }

    private var pattern: StoredPattern? {
        store.patterns.first { $0.id == patternID }
    }

    private var asset: PatternAsset? {
        guard let pattern else { return nil }
        return store.patternAssets.first { $0.id == pattern.assetID }
    }

    private var activeUsages: [PatternProjectUsage] {
        store.patternUsages
            .filter { $0.patternID == patternID && $0.isActive }
            .sorted {
                $0.linkedAt == $1.linkedAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.linkedAt < $1.linkedAt
            }
    }

    private var readingChoices: [PatternReadingChoice] {
        activeUsages.compactMap { usage in
            guard let project = store.projects.first(where: { $0.id == usage.projectID }) else {
                return nil
            }
            return PatternReadingChoice(usage: usage, project: project)
        }
    }

    private var activeProjects: [StoredProject] {
        readingChoices.map(\.project)
    }

    private var availableProjects: [StoredProject] {
        let activeProjectIDs = Set(activeUsages.map(\.projectID))
        return store.projects
            .filter { !activeProjectIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func openPattern() {
        if activeUsages.isEmpty {
            readerRoute = PatternReaderRoute(
                context: .readOnly(patternID: patternID)
            )
        } else if activeUsages.count == 1, let choice = readingChoices.first {
            readerRoute = PatternReaderRoute(
                context: .project(
                    patternID: patternID,
                    usageID: choice.usage.id,
                    projectID: choice.project.id,
                    projectIsCompleted: choice.project.isCompleted
                )
            )
        } else {
            showingReadingChooser = true
            return
        }
        try? store.markPatternOpened(id: patternID)
    }

    private func unlink(projectID: UUID) {
        perform {
            try store.unlinkPattern(patternID: patternID, from: projectID)
        }
    }

    private func deletePattern() {
        guard perform({ try store.deletePatternPermanently(id: patternID) }) else {
            return
        }
        dismiss()
    }

    @discardableResult
    private func perform(_ mutation: () throws -> Void) -> Bool {
        do {
            try mutation()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func detailRow<Content: View>(
        _ key: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            content()
                .multilineTextAlignment(.trailing)
        }
    }
}

private extension View {
    @ViewBuilder
    func patternDetailNavigationTitleStyle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    func patternActionLabelLayout() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

private struct ChoosePatternProjectLinkView: View {
    @Environment(\.dismiss) private var dismiss
    let patternID: UUID
    let projects: [StoredProject]
    let onSelect: (UUID) -> Bool

    var body: some View {
        NavigationStack {
            List {
                if projects.isEmpty {
                    Text("patterns.detail.noProjects")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(projects) { project in
                        Button {
                            if onSelect(project.id) {
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name)
                                if project.isCompleted {
                                    Text("project.status.completed")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                }
            }
            .navigationTitle("patterns.detail.chooseProject")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
        }
    }
}

private struct PatternNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    let onSave: (String) -> Bool

    init(initialValue: String, onSave: @escaping (String) -> Bool) {
        _value = State(initialValue: initialValue)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("patterns.detail.rename", text: $value)
            }
            .navigationTitle("patterns.detail.rename")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        if onSave(value) { dismiss() }
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct PatternNoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    let onSave: (String) -> Bool

    init(initialValue: String, onSave: @escaping (String) -> Bool) {
        _value = State(initialValue: initialValue)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextEditor(text: $value)
                    .frame(minHeight: 180)
            }
            .navigationTitle("patterns.detail.editNote")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        if onSave(value) { dismiss() }
                    }
                }
            }
        }
    }
}
