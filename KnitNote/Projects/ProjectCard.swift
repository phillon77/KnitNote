import SwiftUI

struct ProjectCard: View {
    let project: StoredProject

    var body: some View {
        WatercolorCard {
            HStack(spacing: 16) {
                Image(systemName: "balloon.2.fill")
                    .font(.title2)
                    .foregroundStyle(WatercolorTheme.actionBerry, WatercolorTheme.lavender)
                    .frame(width: 48, height: 48)
                    .background(WatercolorTheme.lavender.opacity(0.22), in: .circle)
                    .accessibilityHidden(true)

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
