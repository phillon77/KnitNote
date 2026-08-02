import SwiftUI

struct ChooseProjectYarnsView: View {
    private enum SaveFailure: String {
        case projectUnavailable = "project.yarn.error.projectUnavailable"
        case yarnUnavailable = "project.yarn.error.yarnUnavailable"
        case projectCompleted = "project.yarn.completed.readOnly"
        case retry = "project.yarn.error.saveRetry"
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    private let initialYarnIDs: Set<UUID>
    @State private var selectedYarnIDs: Set<UUID>
    @State private var pendingUnlink: StoredYarn?
    @State private var saveError: SaveFailure?

    init(projectID: UUID, initialSelection: Set<UUID>) {
        self.projectID = projectID
        initialYarnIDs = initialSelection
        _selectedYarnIDs = State(initialValue: initialSelection)
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.yarns.isEmpty {
                    ContentUnavailableView(
                        "project.yarn.libraryEmpty.title",
                        systemImage: "shippingbox",
                        description: Text("project.yarn.libraryEmpty.message")
                    )
                } else {
                    List {
                        Section {
                            ForEach(store.yarns) { yarn in
                                Button {
                                    toggle(yarn)
                                } label: {
                                    HStack(spacing: 12) {
                                        YarnPhotoView(url: store.photoURL(for: yarn))
                                            .frame(width: 48, height: 48)
                                            .clipShape(.rect(cornerRadius: 11, style: .continuous))
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(yarn.name)
                                                .foregroundStyle(.primary)
                                            YarnInventoryText(yarn: yarn)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if selectedYarnIDs.contains(yarn.id) {
                                            Image(systemName: "checkmark")
                                                .fontWeight(.semibold)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    .contentShape(.rect)
                                }
                                .accessibilityAddTraits(selectedYarnIDs.contains(yarn.id) ? .isSelected : [])
                            }
                        } footer: {
                            Text("project.yarn.unlink.message")
                        }
                    }
                }
            }
            .navigationTitle("project.yarn.choose")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { save() }
                }
            }
            .confirmationDialog(
                "project.yarn.unlink.title",
                isPresented: Binding(
                    get: { pendingUnlink != nil },
                    set: { if !$0 { pendingUnlink = nil } }
                ),
                presenting: pendingUnlink
            ) { yarn in
                Button("project.yarn.unlink.action", role: .destructive) {
                    selectedYarnIDs.remove(yarn.id)
                    pendingUnlink = nil
                }
                Button("common.cancel", role: .cancel) {
                    pendingUnlink = nil
                }
            } message: { _ in
                Text("project.yarn.unlink.message")
            }
            .alert("error.saveFailed", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("common.ok") {}
            } message: {
                Text(LocalizedStringKey(saveError?.rawValue ?? SaveFailure.retry.rawValue))
            }
        }
        .frame(minWidth: 340, minHeight: 480)
        .tint(WatercolorTheme.actionBerry)
    }

    private func toggle(_ yarn: StoredYarn) {
        if selectedYarnIDs.contains(yarn.id) {
            pendingUnlink = yarn
        } else {
            selectedYarnIDs.insert(yarn.id)
        }
    }

    private func save() {
        do {
            let currentYarnIDs = Set(store.yarns(linkedTo: projectID).map(\.id))
            let mergedYarnIDs = YarnLinkSelectionMerge.merged(
                initial: initialYarnIDs,
                edited: selectedYarnIDs,
                current: currentYarnIDs
            )
            try store.setProjectYarns(projectID: projectID, yarnIDs: mergedYarnIDs)
            dismiss()
        } catch {
            if let linkError = error as? ProjectYarnLinkError {
                switch linkError {
                case .projectNotFound:
                    saveError = .projectUnavailable
                case .yarnNotFound:
                    saveError = .yarnUnavailable
                case .projectCompleted:
                    saveError = .projectCompleted
                }
            } else {
                saveError = .retry
            }
        }
    }
}
