import SwiftUI

struct ProjectCard: View {
    let project: StoredProject
    let photoURL: URL?

    var body: some View {
        WatercolorCard {
            HStack(spacing: 16) {
                ProjectPhotoView(url: photoURL)
                    .frame(width: 58, height: 58)
                    .clipShape(.rect(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.headline)
                        .foregroundStyle(WatercolorTheme.ink)
                    if project.isCompleted {
                        Label("project.status.completed", systemImage: "checkmark.seal.fill")
                            .font(.caption.bold())
                            .foregroundStyle(WatercolorTheme.actionBerry)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WatercolorTheme.actionBerry)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
    }
}
