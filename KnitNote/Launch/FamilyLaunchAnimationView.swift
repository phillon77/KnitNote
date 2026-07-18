import SwiftUI

struct FamilyLaunchAnimationView: View {
    private static let paintingAspectRatio = 2560.0 / 1440.0

    let phase: LaunchExperiencePhase
    let destinationFrame: CGRect

    @State private var motionProgress: CGFloat = 0
    @State private var blinkProgress: CGFloat = 0

    var body: some View {
        if phase == .complete {
            EmptyView()
        } else {
            GeometryReader { geometry in
                let canvasWidth = min(
                    geometry.size.width,
                    geometry.size.height * Self.paintingAspectRatio
                )
                let canvasSize = CGSize(
                    width: canvasWidth,
                    height: canvasWidth / Self.paintingAspectRatio
                )
                let outerFrame = geometry.frame(in: .global)
                let sourceFrame = CGRect(
                    x: outerFrame.midX - (canvasSize.width / 2),
                    y: outerFrame.midY - (canvasSize.height / 2),
                    width: canvasSize.width,
                    height: canvasSize.height
                )
                let isEnteringHome = phase == .enteringHome
                let scaleX = isEnteringHome && sourceFrame.width > 0
                    ? destinationFrame.width / sourceFrame.width
                    : 1
                let scaleY = isEnteringHome && sourceFrame.height > 0
                    ? destinationFrame.height / sourceFrame.height
                    : 1
                let destinationOffset = CGSize(
                    width: isEnteringHome ? destinationFrame.midX - sourceFrame.midX : 0,
                    height: isEnteringHome ? destinationFrame.midY - sourceFrame.midY : 0
                )
                let motion = PaintingOverlayMotion(
                    phase: phase,
                    motionProgress: motionProgress,
                    blinkProgress: blinkProgress
                )

                layeredPainting(size: canvasSize, motion: motion)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .scaleEffect(x: scaleX, y: scaleY)
                    .position(
                        x: geometry.size.width / 2 + destinationOffset.width,
                        y: geometry.size.height / 2 + destinationOffset.height
                    )
                    .animation(.easeInOut(duration: 0.6), value: isEnteringHome)
            }
            .aspectRatio(Self.paintingAspectRatio, contentMode: .fit)
            .task(id: phase) {
                await animateLocalPainting(for: phase)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("art.familyHero.accessibility"))
        }
    }

    private func layeredPainting(
        size: CGSize,
        motion: PaintingOverlayMotion
    ) -> some View {
        ZStack {
            paintingImage(size: size)
                .accessibilityHidden(true)

            originalPixelOverlay(region: .handsAndYarn, size: size)
                .rotationEffect(
                    .degrees(motion.handsRotationDegrees),
                    anchor: anchor(for: .handsAndYarn)
                )
                .offset(motion.handsOffset)
                .accessibilityHidden(true)

            originalPixelOverlay(region: .yarnBall, size: size)
                .rotationEffect(
                    .degrees(motion.yarnRotationDegrees),
                    anchor: anchor(for: .yarnBall)
                )
                .accessibilityHidden(true)

            originalPixelOverlay(region: .lemonEars, size: size)
                .rotationEffect(
                    .degrees(motion.earsRotationDegrees),
                    anchor: anchor(for: .lemonEars)
                )
                .offset(motion.earsOffset)
                .accessibilityHidden(true)

            originalPixelOverlay(
                sourceRegion: .lemonEyeCoverSource,
                maskRegion: .lemonEyes,
                size: size
            )
            .opacity(motion.blinkOpacity)
            .accessibilityHidden(true)

            originalPixelOverlay(region: .lemonEyes, size: size)
                .scaleEffect(
                    x: 1,
                    y: motion.blinkScaleY,
                    anchor: anchor(for: .lemonEyes)
                )
                .opacity(motion.blinkOpacity)
                .accessibilityHidden(true)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func paintingImage(size: CGSize) -> some View {
        Image("FamilyKnittingHero")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
    }

    private func originalPixelOverlay(
        region: PaintingOverlayRegion,
        size: CGSize
    ) -> some View {
        originalPixelOverlay(
            sourceRegion: region,
            maskRegion: region,
            size: size
        )
    }

    private func originalPixelOverlay(
        sourceRegion: PaintingOverlayRegion,
        maskRegion: PaintingOverlayRegion,
        size: CGSize
    ) -> some View {
        paintingImage(size: size)
            .offset(
                x: (maskRegion.rect.minX - sourceRegion.rect.minX) * size.width,
                y: (maskRegion.rect.minY - sourceRegion.rect.minY) * size.height
            )
            .mask {
                GeometryReader { _ in
                    Rectangle()
                        .frame(
                            width: maskRegion.rect.width * size.width,
                            height: maskRegion.rect.height * size.height
                        )
                        .offset(
                            x: maskRegion.rect.minX * size.width,
                            y: maskRegion.rect.minY * size.height
                        )
                }
            }
    }

    private func anchor(for region: PaintingOverlayRegion) -> UnitPoint {
        UnitPoint(x: region.rect.midX, y: region.rect.midY)
    }

    @MainActor
    private func animateLocalPainting(for phase: LaunchExperiencePhase) async {
        resetLocalPainting()
        guard phase == .animating else { return }

        for cycle in 0..<2 {
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.28)) {
                motionProgress = 1
            }

            if cycle == 0 {
                do {
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
                withAnimation(.easeIn(duration: 0.06)) {
                    blinkProgress = 1
                }
                do {
                    try await Task.sleep(for: .milliseconds(70))
                } catch {
                    return
                }
                withAnimation(.easeOut(duration: 0.08)) {
                    blinkProgress = 0
                }
                do {
                    try await Task.sleep(for: .milliseconds(30))
                } catch {
                    return
                }
            } else {
                do {
                    try await Task.sleep(for: .milliseconds(280))
                } catch {
                    return
                }
            }

            withAnimation(.easeInOut(duration: 0.28)) {
                motionProgress = 0
            }
            do {
                try await Task.sleep(for: .milliseconds(280))
            } catch {
                return
            }
        }

        resetLocalPainting()
    }

    @MainActor
    private func resetLocalPainting() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            motionProgress = 0
            blinkProgress = 0
        }
    }
}

private struct FamilyLaunchAnimationView_Previews: PreviewProvider {
    static var previews: some View {
        FamilyLaunchAnimationView(
            phase: .animating,
            destinationFrame: CGRect(x: 32, y: 32, width: 256, height: 144)
        )
        .frame(width: 960, height: 540)
        .previewDisplayName("Family painting animation")
    }
}
