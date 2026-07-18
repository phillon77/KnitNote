import SwiftUI

struct FamilyLaunchAnimationView: View {
    private static let paintingAspectRatio = 2560.0 / 1440.0

    /// Source and destination frames supplied to this view must both be
    /// measured in this coordinate space. The root container installs it.
    static let rootCoordinateSpaceName = "KnitNoteRoot"

    let phase: LaunchExperiencePhase
    let destinationFrame: CGRect
    let revealProgress: Double

    @State private var localAnimationStartDate: Date?
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
                timelinePainting(
                    size: canvasSize,
                    transitionOpacity: transition.opacity
                )
                    .scaleEffect(x: transition.scaleX, y: transition.scaleY)
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
            .onChange(of: phase, initial: true) { _, nextPhase in
                if nextPhase == .animating {
                    localAnimationStartDate = Date()
                } else if nextPhase != .settling {
                    localAnimationStartDate = nil
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("art.familyHero.accessibility"))
        }
    }

    private func timelinePainting(
        size: CGSize,
        transitionOpacity: Double
    ) -> some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 60.0,
            paused: phase != .animating && phase != .settling
        )) { context in
            let frame = timelineFrame(at: context.date)
            let camera = cameraTransform(frame: frame, size: size)
            let motion = PaintingOverlayMotion(
                handProgress: frame.handProgress,
                blinkProgress: frame.blinkProgress
            )

            revealedPainting(
                size: size,
                motion: motion,
                transitionOpacity: transitionOpacity
            )
            .scaleEffect(camera.scale)
            .offset(camera.offset)
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    private func timelineFrame(at date: Date) -> FamilyLaunchFrame {
        guard !reduceMotion else {
            return FamilyLaunchTimeline.frame(atMilliseconds: 0)
        }
        guard phase == .animating || phase == .settling,
              let localAnimationStartDate else {
            return FamilyLaunchTimeline.frame(
                atMilliseconds: phase == .enteringHome
                    ? FamilyLaunchTimeline.localSequenceMilliseconds
                    : 0
            )
        }
        let elapsed = Int(date.timeIntervalSince(localAnimationStartDate) * 1_000)
        return FamilyLaunchTimeline.frame(atMilliseconds: elapsed)
    }

    private func cameraTransform(
        frame: FamilyLaunchFrame,
        size: CGSize
    ) -> (scale: CGFloat, offset: CGSize) {
        let scale = CGFloat(frame.cameraZoom)
        return (
            scale,
            CGSize(
                width: (0.5 - frame.cameraFocusX) * size.width * scale,
                height: (0.5 - frame.cameraFocusY) * size.height * scale
            )
        )
    }

    private func revealedPainting(
        size: CGSize,
        motion: PaintingOverlayMotion,
        transitionOpacity: Double
    ) -> some View {
        layeredPainting(size: size, motion: motion)
            .transaction { transaction in
                if phase != .animating {
                    transaction.animation = nil
                }
            }
            .frame(width: size.width, height: size.height)
            .opacity(
                launchPaintingOpacity(
                    revealProgress: revealProgress,
                    transitionOpacity: transitionOpacity
                )
            )
            .animation(
                .easeInOut(duration: LaunchExperienceTiming.revealVisualSeconds),
                value: revealProgress
            )
    }

    private func layeredPainting(
        size: CGSize,
        motion: PaintingOverlayMotion
    ) -> some View {
        ZStack {
            paintingImage(size: size)
                .accessibilityHidden(true)

            originalPixelOverlay(region: .handsAndYarn, size: size)
                .mask { featheredHandsMask(size: size) }
                .rotationEffect(
                    .degrees(motion.handsRotationDegrees),
                    anchor: anchor(for: .handsAndYarn)
                )
                .offset(
                    y: CGFloat(motion.handsVerticalTravel) * max(1, size.width / 390)
                )
                .accessibilityHidden(true)

            originalPixelOverlay(
                sourceRegion: .lemonEyeCoverSource,
                maskRegion: .lemonEyes,
                size: size
            )
            .opacity(motion.eyeCoverOpacity)
            .accessibilityHidden(true)

            originalPixelOverlay(region: .lemonEyes, size: size)
                .scaleEffect(
                    x: 1,
                    y: motion.eyeScaleY,
                    anchor: anchor(for: .lemonEyes)
                )
                .opacity(motion.eyeCoverOpacity)
                .accessibilityHidden(true)
        }
        .frame(width: size.width, height: size.height)
        .compositingGroup()
        .clipped()
    }

    private func featheredHandsMask(size: CGSize) -> some View {
        Canvas { context, _ in
            context.addFilter(.blur(radius: max(2, size.width * 0.005)))
            let regions = [
                CGRect(x: 0.304, y: 0.335, width: 0.058, height: 0.135),
                CGRect(x: 0.348, y: 0.335, width: 0.058, height: 0.135),
                CGRect(x: 0.320, y: 0.385, width: 0.078, height: 0.115)
            ]
            for region in regions {
                let rect = CGRect(
                    x: region.minX * size.width,
                    y: region.minY * size.height,
                    width: region.width * size.width,
                    height: region.height * size.height
                )
                context.fill(Path(ellipseIn: rect), with: .color(.white))
            }
        }
        .frame(width: size.width, height: size.height)
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

}

private struct FamilyLaunchAnimationView_Previews: PreviewProvider {
    static var previews: some View {
        FamilyLaunchAnimationView(
            phase: .animating,
            destinationFrame: CGRect(x: 32, y: 32, width: 256, height: 144),
            revealProgress: 1
        )
        .frame(width: 960, height: 540)
        .previewDisplayName("Family painting animation")
    }
}
