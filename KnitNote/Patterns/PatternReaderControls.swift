import SwiftUI

struct PatternReaderControls: View {
    let currentRow: Int
    let pageIndex: Int
    let pageCount: Int
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onUndoRow: () -> Void
    let onCompleteRow: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if pageCount > 0 {
                HStack {
                    Button(action: onPreviousPage) {
                        Label("patterns.previousPage", systemImage: "chevron.left")
                    }
                    .disabled(pageIndex == 0)
                    Spacer()
                    Text(verbatim: "\(pageIndex + 1) / \(pageCount)")
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Button(action: onNextPage) {
                        Label("patterns.nextPage", systemImage: "chevron.right")
                    }
                    .disabled(pageIndex >= pageCount - 1)
                }
                .labelStyle(.iconOnly)
            }

            HStack(spacing: 16) {
                Button(action: onUndoRow) {
                    Label("project.undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(currentRow == 0)

                Spacer()

                VStack(spacing: 1) {
                    Text("project.currentRow")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(currentRow, format: .number)
                        .font(.title3.bold().monospacedDigit())
                }

                Spacer()

                Button(action: onCompleteRow) {
                    Label("project.completeRow", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
