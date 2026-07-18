import SwiftUI

struct FamilyLaunchAnimationView: View {
    private static let paintingAspectRatio = 2560.0 / 1440.0

    /// Source and destination frames supplied to this view must both be
    /// measured in this coordinate space. The root container installs it.
    static let rootCoordinateSpaceName = "KnitNoteRoot"

    let phase: LaunchExperiencePhase
    let destinationFrame: CGRect

    @State private var blinkProgress: CGFloat = 0
    @State private var revealProgress: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                let outerFrame = geometry.frame(
                    in: .named(Self.rootCoordinateSpaceName)
                )
                let sourceFrame = CGRect(
                    x: outerFrame.midX - (canvasSize.width / 2),
                    y: outerFrame.midY - (canvasSize.height / 2),
                    width: canvasSize.width,
                    height: canvasSize.height
                )
                let transition = PaintingCompositeTransition(
                    phase: phase,
                    sourceFrame: sourceFrame,
                    destinationFrame: destinationFrame,
                    reduceMotion: reduceMotion
                )
                let blink = PaintingBlinkState(
                    phase: phase,
                    progress: blinkProgress
                )

                layeredPainting(size: canvasSize, blink: blink)
                    .transaction { transaction in
                        if phase != .animating {
                            transaction.animation = nil
                        }
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .scaleEffect(x: transition.scaleX, y: transition.scaleY)
                    .opacity(
                        launchPaintingOpacity(
                            revealProgress: revealProgress,
                            transitionOpacity: transition.opacity
                        )
                    )
                    .position(
                        x: geometry.size.width / 2 + transition.offset.width,
                        y: geometry.size.height / 2 + transition.offset.height
                    )
                    // Deliberately animate only the phase edge into enteringHome.
                    // Destination changes during that fixed phase snap to converge;
                    // Task 4 must publish the hero frame before the phase begins.
                    .animation(
                        .easeInOut(duration: LaunchExperienceTiming.homeTransitionSeconds),
                        value: phase
                    )
            }
            .aspectRatio(Self.paintingAspectRatio, contentMode: .fit)
            .task(id: phase) {
                await animateLocalPainting(for: phase)
            }
            .task {
                await revealPainting()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("art.familyHero.accessibility"))
        }
    }

    private func layeredPainting(
        size: CGSize,
        blink: PaintingBlinkState
    ) -> some View {
        ZStack {
            paintingImage(size: size)
                .accessibilityHidden(true)

            originalPixelOverlay(
                sourceRegion: .lemonEyeCoverSource,
                maskRegion: .lemonEyes,
                size: size
            )
            .opacity(blink.opacity)
            .accessibilityHidden(true)

            originalPixelOverlay(region: .lemonEyes, size: size)
                .scaleEffect(
                    x: 1,
                    y: blink.scaleY,
                    anchor: anchor(for: .lemonEyes)
                )
                .opacity(blink.opacity)
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
    private func revealPainting() async {
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: LaunchExperienceTiming.revealSeconds)) {
            revealProgress = 1
        }
    }

    @MainActor
    private func animateLocalPainting(for phase: LaunchExperiencePhase) async {
        resetLocalPainting()
        guard phase == .animating, !reduceMotion else { return }

        for cycle in 0..<2 {
            guard !Task.isCancelled else { return }

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
