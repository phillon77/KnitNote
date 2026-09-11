#if os(iOS)
import SwiftUI
import UIKit

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
        _model = State(initialValue: JournalSharePreviewModel(
            source: source,
            locale: locale,
            renderer: SwiftUIJournalShareCardRenderer(),
            exportService: JournalShareTemporaryExportService(root: exportRoot),
            photoSaver: IOSJournalPhotoSaver(),
            textCopier: IOSJournalTextCopier()
        ))
    }

    var body: some View {
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
        .sheet(item: $activityPayload, onDismiss: finishPresentedShare) { payload in
            JournalActivityView(payload: payload) { finishShare(payload) }
        }
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
                if let data = model.previewJPEG, let image = UIImage(data: data) {
                    Image(uiImage: image)
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
        Button("journal.share.action.share", systemImage: "square.and.arrow.up") {
            Task { await prepareShare() }
        }
        .buttonStyle(YarnPrimaryButtonStyle())
        .disabled(!(model.canShare && !model.isSavingPhoto))
        .accessibilityIdentifier("journalShare.share")

        Button {
            Task { await model.saveToPhotos() }
        } label: {
            Label("journal.share.action.save", systemImage: "square.and.arrow.down")
                .frame(minHeight: 44)
        }
        .disabled(!(model.canShare && !model.isSavingPhoto))
        .accessibilityIdentifier("journalShare.save")

        Button {
            model.copyText()
            showsCopyFeedback = true
            announce("journal.share.announcement.copied")
        } label: {
            Label("journal.share.action.copy", systemImage: "doc.on.doc")
                .frame(minHeight: 44)
        }
        .disabled(!model.canCopy)
        .accessibilityIdentifier("journalShare.copy")
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
            Label("journal.share.saved", systemImage: "checkmark.circle.fill")
        case .failed(.denied):
            VStack(alignment: .leading) {
                Text("journal.share.error.photosDenied")
                Button("journal.share.openSettings") { openSettings() }
            }
        case .failed(.writeFailed):
            Text("journal.share.error.saveFailed")
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

    private func prepareShare() async {
        do {
            let payload = try await model.prepareShare()
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

    private func finishPresentedShare() {
        guard let payload = retainedActivityPayload else { return }
        model.finishSharing(payload)
        retainedActivityPayload = nil
        activityPayload = nil
    }

    private func announcePhotoSaveState() {
        switch model.photoSaveState {
        case .saved: announce("journal.share.announcement.saved")
        case .failed(.denied): announce("journal.share.announcement.photosDenied")
        case .failed(.writeFailed): announce("journal.share.announcement.saveFailed")
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
        UIAccessibility.post(notification: .announcement, argument: LocaleAwareText.string(key, locale: locale))
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var actionErrorIsPresented: Binding<Bool> {
        Binding(get: { actionErrorKey != nil }, set: { if !$0 { actionErrorKey = nil } })
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
#endif
