import SwiftUI

struct JournalShareCardView: View {
    let description: JournalShareCardDescription
    let photo: Image

    private var metrics: JournalShareCardMetrics { .init(description: description) }

    var body: some View {
        ZStack {
            JournalSharePaperBackground()

            VStack(spacing: metrics.sectionSpacing) {
                JournalShareInstantPhoto(photo: photo, metrics: metrics)

                if metrics.hasMetadata {
                    JournalShareMetadata(description: description, metrics: metrics)
                }
            }
            .padding(.horizontal, metrics.sideInset)
            .padding(.top, metrics.topInset)
            .padding(.bottom, metrics.bottomInset)
        }
        .frame(width: metrics.canvasWidth, height: metrics.canvasHeight)
        .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
    }
}

private struct JournalSharePaperBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.956, green: 0.918, blue: 0.843)
            Canvas { context, size in
                let fiber = Color(red: 0.50, green: 0.38, blue: 0.25).opacity(0.055)
                for index in 0..<34 {
                    let y = (CGFloat(index) + 0.5) * size.height / 34
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y + CGFloat(index % 3) - 1))
                    context.stroke(path, with: .color(fiber), lineWidth: 1)
                }
            }
        }
    }
}

private struct JournalShareInstantPhoto: View {
    let photo: Image
    let metrics: JournalShareCardMetrics

    var body: some View {
        photo
            .resizable()
            .scaledToFill()
            .frame(width: metrics.photoWidth, height: metrics.photoHeight)
            .clipped()
            .background(Color.white)
            .padding(.horizontal, metrics.photoBorder)
            .padding(.top, metrics.photoBorder)
            .padding(.bottom, metrics.photoBottomBorder)
            .background(Color(red: 0.992, green: 0.982, blue: 0.955))
            .shadow(color: Color.black.opacity(0.16), radius: 15, x: 4, y: 13)
            .rotationEffect(.degrees(-1.2))
    }
}

private struct JournalShareMetadata: View {
    let description: JournalShareCardDescription
    let metrics: JournalShareCardMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.textSpacing) {
            if let projectName = description.projectName, !projectName.isEmpty {
                Text(projectName)
                    .font(.system(size: metrics.titleSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.25, green: 0.20, blue: 0.15))
                    .lineLimit(1)
            }

            if let formattedDate = description.formattedDate, !formattedDate.isEmpty {
                Text(formattedDate)
                    .font(.system(size: metrics.dateSize, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.48, green: 0.37, blue: 0.28))
                    .lineLimit(1)
            }

            if let caption = description.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: metrics.captionSize, weight: .regular, design: .rounded))
                    .foregroundStyle(Color(red: 0.30, green: 0.25, blue: 0.20))
                    .lineSpacing(metrics.captionLineSpacing)
                    .lineLimit(metrics.captionLineLimit)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if description.showsBrand {
                HStack(spacing: 10) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: metrics.brandSize * 0.72))
                    Text("KnitNote")
                        .font(.system(size: metrics.brandSize, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Color(red: 0.55, green: 0.27, blue: 0.20))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, metrics.noteHorizontalPadding)
        .padding(.vertical, metrics.noteVerticalPadding)
        .background(Color(red: 0.997, green: 0.963, blue: 0.875).opacity(0.97))
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(Color(red: 0.73, green: 0.47, blue: 0.34).opacity(0.28))
                .frame(width: 128, height: 30)
                .rotationEffect(.degrees(-4))
                .offset(x: 40, y: -17)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 2, y: 6)
    }
}

private struct JournalShareCardMetrics {
    let canvasWidth: CGFloat
    let canvasHeight: CGFloat
    let sideInset: CGFloat = 76
    let topInset: CGFloat
    let bottomInset: CGFloat
    let sectionSpacing: CGFloat
    let photoWidth: CGFloat
    let photoHeight: CGFloat
    let photoBorder: CGFloat = 26
    let photoBottomBorder: CGFloat = 42
    let titleSize: CGFloat
    let dateSize: CGFloat
    let captionSize: CGFloat
    let brandSize: CGFloat
    let textSpacing: CGFloat
    let captionLineSpacing: CGFloat
    let captionLineLimit: Int
    let noteHorizontalPadding: CGFloat = 38
    let noteVerticalPadding: CGFloat
    let hasMetadata: Bool

    init(description: JournalShareCardDescription) {
        canvasWidth = CGFloat(description.format.pixelWidth)
        canvasHeight = CGFloat(description.format.pixelHeight)
        hasMetadata = description.projectName?.isEmpty == false
            || description.formattedDate?.isEmpty == false
            || description.caption?.isEmpty == false
            || description.showsBrand

        switch description.format {
        case .post:
            topInset = 80
            bottomInset = 82
            sectionSpacing = 34
            photoWidth = hasMetadata ? 850 : 870
            photoHeight = hasMetadata ? 690 : 1_040
            titleSize = 42
            dateSize = 28
            captionSize = 34
            brandSize = 28
            textSpacing = 13
            captionLineSpacing = 7
            captionLineLimit = 4
            noteVerticalPadding = 24
        case .story:
            topInset = 92
            bottomInset = 92
            sectionSpacing = 40
            photoWidth = hasMetadata ? 850 : 870
            photoHeight = hasMetadata ? 1_100 : 1_570
            titleSize = 44
            dateSize = 30
            captionSize = 32
            brandSize = 29
            textSpacing = 15
            captionLineSpacing = 4
            captionLineLimit = 6
            noteVerticalPadding = 22
        }
    }
}
