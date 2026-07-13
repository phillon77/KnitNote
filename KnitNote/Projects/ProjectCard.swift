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

                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name)
                        .font(.headline)
                        .foregroundStyle(WatercolorTheme.ink)
                    HStack(spacing: 5) {
                        Text("project.currentRow")
                        Text(project.currentRow, format: .number)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
