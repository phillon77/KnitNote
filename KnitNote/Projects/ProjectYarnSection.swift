import SwiftUI

struct ProjectYarnSection: View {
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    let isEditable: Bool
    @State private var showingPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("project.yarn.title", systemImage: "shippingbox")
                    .font(.headline)
                    .foregroundStyle(linkedYarns.isEmpty ? Color.primary : WatercolorTheme.actionBerry)
                Spacer()
                if isEditable {
                    Button("project.yarn.manage") {
                        showingPicker = true
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }

            if linkedYarns.isEmpty {
                Text("project.yarn.empty")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(linkedYarns) { yarn in
                    NavigationLink {
                        YarnDetailView(yarnID: yarn.id)
                    } label: {
                        HStack(spacing: 12) {
                            YarnPhotoView(url: store.photoURL(for: yarn))
                                .frame(width: 52, height: 52)
                                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(yarn.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                YarnInventoryText(yarn: yarn)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingPicker) {
            ChooseProjectYarnsView(
                projectID: projectID,
                initialSelection: Set(linkedYarns.map(\.id))
            )
        }
    }

    private var linkedYarns: [StoredYarn] {
        store.yarns(linkedTo: projectID)
    }
}
