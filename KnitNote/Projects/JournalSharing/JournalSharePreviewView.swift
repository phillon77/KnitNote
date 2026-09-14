import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
struct JournalSharePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: JournalSharePreviewModel
    @State private var activityPayload: JournalSharePayload?
    @State private var retainedActivityPayload: JournalSharePayload?
    @State private var showsCopyFeedback = false
    @State private var actionErrorKey: String?

    init(source: JournalShareSource, locale: Locale) {
        let exportRoot = FileManager.default.temporaryDirectory
            .appending(path: "KnitNoteJournalShareExports", directoryHint: .isDirectory)
        #if os(iOS)
        let imageSaver: any JournalPhotoSaving = IOSJournalPhotoSaver()
        let textCopier: any JournalTextCopying = IOSJournalTextCopier()
        #elseif os(macOS)
        let imageSaver: any JournalPhotoSaving = MacJournalImageSaver()
        let textCopier: any JournalTextCopying = MacJournalTextCopier()
        #endif
        _model = State(initialValue: JournalSharePreviewModel(
            source: source,
            locale: locale,
            renderer: SwiftUIJournalShareCardRenderer(),
            exportService: JournalShareTemporaryExportService(root: exportRoot),
            photoSaver: imageSaver,
            textCopier: textCopier
        ))
    }

    var body: some View {
        #if os(iOS)
        shareContent
            .sheet(item: $activityPayload, onDismiss: finishPresentedShare) { payload in
                JournalActivityView(payload: payload) { finishShare(payload) }
            }
        #elseif os(macOS)
        shareContent
            .frame(minWidth: 620, minHeight: 680)
        #endif
    }

    private var shareContent: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    previewImage
                    formatPicker
                    visibilityControls
                    TextField("journal.share.text", text: editableText, axis: .vertical)
                        .lineLimit(3...8)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("journalShare.text")
                    Toggle("journal.share.hashtag", isOn: includesHashtag)
                        .accessibilityIdentifier("journalShare.hashtag")
                    actionBar
                    resultMessage
                }
                .padding()
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(WatercolorBackground())
            .navigationTitle("journal.share.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.done") { dismiss() }
                }
            }
        }
        .tint(WatercolorTheme.actionBerry)
        .task(id: previewSettings) { await model.refreshPreview() }
        .task(id: model.photoSaveState) { announcePhotoSaveState() }
        .task(id: model.state) { announcePreviewFailure() }
        .onDisappear { model.dismiss() }
        .alert("journal.share.error.title", isPresented: actionErrorIsPresented) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(actionErrorKey ?? "journal.share.error.render"))
        }
    }

    private var previewImage: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("journal.share.loading")
                    .frame(maxWidth: .infinity, minHeight: 240)
            case .ready:
                if let data = model.previewJPEG, let image = platformImage(data) {
                    image
                        .resizable()
                        .scaledToFit()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("journal.share.preview.accessibility"))
                        .accessibilityIdentifier("journalShare.preview")
                }
            case .failed(.photoUnavailable):
                ContentUnavailableView {
                    Label("journal.share.error.photoUnavailable", systemImage: "photo.badge.exclamationmark")
                } actions: {
                    Button("common.retry") { Task { await model.refreshPreview() } }
                }
            case .failed(.renderingFailed):
                ContentUnavailableView {
                    Label("journal.share.error.render", systemImage: "photo.badge.exclamationmark")
                } actions: {
                    Button("common.retry") { Task { await model.refreshPreview() } }
                }
            case .dismissed:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .background(WatercolorTheme.softWhite.opacity(0.92), in: .rect(cornerRadius: 24))
    }

    @ViewBuilder
    private var formatPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text("journal.share.format").font(.headline)
                formatButton("journal.share.format.post", format: .post)
                formatButton("journal.share.format.story", format: .story)
            }
            .accessibilityIdentifier("journalShare.format")
        } else {
            Picker("journal.share.format", selection: format) {
                Text("journal.share.format.post").tag(JournalShareFormat.post)
                Text("journal.share.format.story").tag(JournalShareFormat.story)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("journalShare.format")
        }
    }

    private func formatButton(_ key: LocalizedStringKey, format: JournalShareFormat) -> some View {
        Button {
            model.format = format
        } label: {
            Label(key, systemImage: model.format == format ? "checkmark.circle.fill" : "circle")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityAddTraits(model.format == format ? .isSelected : [])
    }

    private var visibilityControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("journal.share.showProject", isOn: visibility(\.showsProjectName))
                .accessibilityIdentifier("journalShare.showProject")
            Toggle("journal.share.showDate", isOn: visibility(\.showsDate))
                .accessibilityIdentifier("journalShare.showDate")
            Toggle("journal.share.showCaption", isOn: visibility(\.showsCaption))
                .accessibilityIdentifier("journalShare.showCaption")
            Toggle("journal.share.showBrand", isOn: visibility(\.showsBrand))
                .accessibilityIdentifier("journalShare.showBrand")
        }
        .padding()
        .background(WatercolorTheme.softWhite.opacity(0.92), in: .rect(cornerRadius: 20))
    }

    @ViewBuilder private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actionButtons }
            VStack(spacing: 12) { actionButtons }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        shareActionButton

        Button {
            Task { await model.saveToPhotos() }
        } label: {
            Group {
                #if os(iOS)
                Label("journal.share.action.save", systemImage: "square.and.arrow.down")
                #elseif os(macOS)
                Label("journal.share.action.saveFile", systemImage: "square.and.arrow.down")
                #endif
            }
            .frame(minHeight: 44)
        }
        .disabled(!(model.canShare && !model.isSavingPhoto))
        .accessibilityIdentifier("journalShare.save")

        Button {
            if model.copyText() {
                showsCopyFeedback = true
                announce("journal.share.announcement.copied")
            } else {
                showsCopyFeedback = false
                actionErrorKey = "journal.share.error.unavailable"
                announce("journal.share.announcement.failed")
            }
        } label: {
            Label("journal.share.action.copy", systemImage: "doc.on.doc")
                .frame(minHeight: 44)
        }
        .disabled(!model.canCopy)
        .accessibilityIdentifier("journalShare.copy")
    }

    @ViewBuilder private var shareActionButton: some View {
        #if os(iOS)
        shareButton
        #elseif os(macOS)
        JournalActivityView(
            isEnabled: model.canShare && !model.isSavingPhoto,
            accessibilityLabel: LocaleAwareText.string("journal.share.action.share", locale: locale),
            preparePayload: { try model.prepareShare() },
            completion: finishShare
        )
        .frame(maxWidth: .infinity, minHeight: 44)
        #endif
    }

    private var shareButton: some View {
        Button("journal.share.action.share", systemImage: "square.and.arrow.up") {
            prepareShare()
        }
        .buttonStyle(YarnPrimaryButtonStyle())
        .disabled(!(model.canShare && !model.isSavingPhoto))
        .accessibilityIdentifier("journalShare.share")
    }

    @ViewBuilder private var resultMessage: some View {
        if showsCopyFeedback {
            Label("journal.share.copyFeedback", systemImage: "checkmark.circle.fill")
                .accessibilityIdentifier("journalShare.copyFeedback")
        }
        switch model.photoSaveState {
        case .saving:
            ProgressView("journal.share.saving")
        case .saved:
            Label {
                Text(LocalizedStringKey(savedMessageKey))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
        case .failed(.denied):
            VStack(alignment: .leading) {
                Text("journal.share.error.photosDenied")
                Button("journal.share.openSettings") { openSettings() }
            }
        case .failed(.writeFailed):
            Text(LocalizedStringKey(saveFailedMessageKey))
        case .cancelled:
            Text("journal.share.saveCancelled")
        case .idle:
            EmptyView()
        }
    }

    private var previewSettings: PreviewSettings {
        PreviewSettings(format: model.format, visibility: model.visibility, editableText: model.editableText)
    }

    private var format: Binding<JournalShareFormat> {
        Binding(get: { model.format }, set: { model.format = $0 })
    }

    private var editableText: Binding<String> {
        Binding(get: { model.editableText }, set: { model.editableText = $0 })
    }

    private var includesHashtag: Binding<Bool> {
        Binding(get: { model.includesHashtag }, set: { model.includesHashtag = $0 })
    }

    private func visibility(_ keyPath: WritableKeyPath<JournalShareVisibility, Bool>) -> Binding<Bool> {
        Binding(get: { model.visibility[keyPath: keyPath] }, set: { model.visibility[keyPath: keyPath] = $0 })
    }

    private func prepareShare() {
        do {
            let payload = try model.prepareShare()
            retainedActivityPayload = payload
            activityPayload = payload
        }
        catch {
            actionErrorKey = "journal.share.error.unavailable"
            announce("journal.share.announcement.failed")
        }
    }

    private func finishShare(_ payload: JournalSharePayload) {
        model.finishSharing(payload)
        if retainedActivityPayload?.id == payload.id { retainedActivityPayload = nil }
        if activityPayload?.id == payload.id { activityPayload = nil }
    }

    #if os(macOS)
    private func finishShare(
        _ payload: JournalSharePayload?,
        outcome: JournalShareActivityOutcome
    ) {
        if let payload { finishShare(payload) }
        if outcome == .failed {
            actionErrorKey = "journal.share.error.unavailable"
            announce("journal.share.announcement.failed")
        }
    }
    #endif

    private func finishPresentedShare() {
        guard let payload = retainedActivityPayload else { return }
        model.finishSharing(payload)
        retainedActivityPayload = nil
        activityPayload = nil
    }

    private func announcePhotoSaveState() {
        switch model.photoSaveState {
        case .saved: announce(savedAnnouncementKey)
        case .failed(.denied): announce("journal.share.announcement.photosDenied")
        case .failed(.writeFailed): announce(saveFailedAnnouncementKey)
        case .cancelled: announce("journal.share.announcement.saveCancelled")
        case .idle, .saving: break
        }
    }

    private func announcePreviewFailure() {
        switch model.state {
        case .failed(.photoUnavailable): announce("journal.share.announcement.photoUnavailable")
        case .failed(.renderingFailed): announce("journal.share.announcement.renderFailed")
        case .loading, .ready, .dismissed: break
        }
    }

    private func announce(_ key: String) {
        #if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: LocaleAwareText.string(key, locale: locale))
        #elseif os(macOS)
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: LocaleAwareText.string(key, locale: locale),
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
        #endif
    }

    private func openSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(iOS)
        UIImage(data: data).map(Image.init(uiImage:))
        #elseif os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }

    private var actionErrorIsPresented: Binding<Bool> {
        Binding(get: { actionErrorKey != nil }, set: { if !$0 { actionErrorKey = nil } })
    }

    private var savedMessageKey: String {
        #if os(iOS)
        "journal.share.saved"
        #elseif os(macOS)
        "journal.share.savedFile"
        #endif
    }

    private var saveFailedMessageKey: String {
        #if os(iOS)
        "journal.share.error.saveFailed"
        #elseif os(macOS)
        "journal.share.error.saveFileFailed"
        #endif
    }

    private var savedAnnouncementKey: String {
        #if os(iOS)
        "journal.share.announcement.saved"
        #elseif os(macOS)
        "journal.share.announcement.savedFile"
        #endif
    }

    private var saveFailedAnnouncementKey: String {
        #if os(iOS)
        "journal.share.announcement.saveFailed"
        #elseif os(macOS)
        "journal.share.error.saveFileFailed"
        #endif
    }
}

private struct PreviewSettings: Equatable {
    let format: String
    let visibility: JournalShareVisibility
    let editableText: String

    init(format: JournalShareFormat, visibility: JournalShareVisibility, editableText: String) {
        self.format = format.rawValue
        self.visibility = visibility
        self.editableText = editableText
    }
}
