import SwiftUI

enum ProjectJournalPhotoLoadState: Equatable {
    case idle
    case loading
    case loaded
    case unavailable

    func cardAccessibilityFormatKey(hasCaption: Bool) -> String {
        switch (self, hasCaption) {
        case (.idle, true):
            "journal.card.accessibility.withCaption.unavailable.format"
        case (.idle, false):
            "journal.card.accessibility.withoutCaption.unavailable.format"
        case (.loaded, true):
            "journal.card.accessibility.withCaption.format"
        case (.loaded, false):
            "journal.card.accessibility.withoutCaption.format"
        case (.loading, true):
            "journal.card.accessibility.withCaption.loading.format"
        case (.loading, false):
            "journal.card.accessibility.withoutCaption.loading.format"
        case (.unavailable, true):
            "journal.card.accessibility.withCaption.unavailable.format"
        case (.unavailable, false):
            "journal.card.accessibility.withoutCaption.unavailable.format"
        }
    }
}

struct ProjectJournalSection: View {
    @Environment(\.locale) private var locale
    let project: StoredProject
    let thumbnailURL: (ProjectJournalEntry) -> URL?
    let onAdd: () -> Void
    let onOpen: (ProjectJournalEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("journal.title")
                    .font(.headline)
                Spacer()
                if !project.isCompleted {
                    Button("journal.add", systemImage: "plus", action: onAdd)
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                        .accessibilityLabel(Text("journal.accessibility.add"))
                }
            }

            if project.journalEntries.isEmpty {
                Text(project.isCompleted ? "journal.empty.completed" : "journal.empty.active")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityAddTraits(project.isCompleted ? .isStaticText : [])
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(project.journalEntries, id: \.id) { entry in
                            ProjectJournalCard(
                                entry: entry,
                                thumbnailURL: thumbnailURL(entry),
                                onOpen: { onOpen(entry) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProjectJournalCard: View {
    @Environment(\.locale) private var locale
    let entry: ProjectJournalEntry
    let thumbnailURL: URL?
    let onOpen: () -> Void
    @State private var photoLoadState: ProjectJournalPhotoLoadState

    init(entry: ProjectJournalEntry, thumbnailURL: URL?, onOpen: @escaping () -> Void) {
        self.entry = entry
        self.thumbnailURL = thumbnailURL
        self.onOpen = onOpen
        _photoLoadState = State(initialValue: thumbnailURL == nil ? .unavailable : .loading)
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                ProjectJournalPhotoView(
                    url: thumbnailURL,
                    maximumPixelSize: 360,
                    onLoadStateChange: { photoLoadState = $0 }
                )
                    .frame(width: 148, height: 104)
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))

                if let caption = entry.caption {
                    Text(caption)
                        .font(.subheadline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(entry.createdAt, format: .dateTime.year().month().day().locale(locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 148, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: Text {
        let date = entry.createdAt.formatted(.dateTime.year().month().day().locale(locale))
        let format = String(
            localized: String.LocalizationValue(
                photoLoadState.cardAccessibilityFormatKey(hasCaption: entry.caption != nil)
            ),
            locale: locale
        )
        if let caption = entry.caption {
            return Text(verbatim: String(format: format, locale: locale, caption, date))
        } else {
            return Text(verbatim: String(format: format, locale: locale, date))
        }
    }
}

struct ProjectJournalPhotoView: View {
    let url: URL?
    let data: Data?
    let dataRevision: UUID?
    let maximumPixelSize: Int
    let contentMode: ContentMode
    let loadedAccessibilityLabelKey: LocalizedStringKey
    let onLoadStateChange: ((ProjectJournalPhotoLoadState) -> Void)?
    @State private var preview: ProjectJournalPreview?
    @State private var loadState: ProjectJournalPhotoLoadState

    init(
        url: URL?,
        data: Data? = nil,
        dataRevision: UUID? = nil,
        maximumPixelSize: Int = 1600,
        contentMode: ContentMode = .fill,
        loadedAccessibilityLabelKey: LocalizedStringKey = "journal.accessibility.photo",
        onLoadStateChange: ((ProjectJournalPhotoLoadState) -> Void)? = nil
    ) {
        self.url = url
        self.data = data
        self.dataRevision = dataRevision
        self.maximumPixelSize = maximumPixelSize
        self.contentMode = contentMode
        self.loadedAccessibilityLabelKey = loadedAccessibilityLabelKey
        self.onLoadStateChange = onLoadStateChange
        _loadState = State(initialValue: url == nil && data == nil ? .idle : .loading)
    }

    var body: some View {
        Group {
            if let preview {
                let image = Image(decorative: preview.image, scale: 1)
                if contentMode == .fit {
                    image
                        .resizable()
                        .scaledToFit()
                } else {
                    image
                        .resizable()
                        .scaledToFill()
                }
            } else {
                ZStack {
                    WatercolorTheme.lavender.opacity(0.22)
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(WatercolorTheme.actionBerry)
                }
            }
        }
        .accessibilityLabel(Text(accessibilityLabelKey))
        .task(id: previewRequestID) {
            preview = nil
            guard data != nil || url != nil else {
                return
            }
            updateLoadState(.loading)
            let loadedPreview: ProjectJournalPreview?
            if let data {
                loadedPreview = await ProjectJournalPreviewLoader.load(
                    data: data,
                    maximumPixelSize: maximumPixelSize
                )
            } else if let url {
                loadedPreview = await ProjectJournalPreviewLoader.load(
                    url: url,
                    maximumPixelSize: maximumPixelSize
                )
            } else {
                loadedPreview = nil
            }
            guard !Task.isCancelled else { return }
            preview = loadedPreview
            updateLoadState(loadedPreview == nil ? .unavailable : .loaded)
        }
    }

    private var previewRequestID: ProjectJournalPreviewRequestID {
        ProjectJournalPreviewRequestID(
            url: data == nil ? url : nil,
            dataRevision: data == nil ? nil : dataRevision,
            hasData: data != nil
        )
    }

    private var accessibilityLabelKey: LocalizedStringKey {
        switch loadState {
        case .idle:
            "journal.photo.select"
        case .loading:
            "journal.photo.loading"
        case .loaded:
            loadedAccessibilityLabelKey
        case .unavailable:
            "journal.photo.unavailable"
        }
    }

    private func updateLoadState(_ newState: ProjectJournalPhotoLoadState) {
        guard loadState != newState else { return }
        loadState = newState
        onLoadStateChange?(newState)
    }
}

private struct ProjectJournalPreviewRequestID: Equatable {
    let url: URL?
    let dataRevision: UUID?
    let hasData: Bool
}
