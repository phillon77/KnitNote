# Lemon App Icon Design

## Purpose

Create the production App icon for KnitNote using the daughter's original watercolor illustration of the family rabbit, Lemon, resting on a lavender yarn ball. The icon must preserve the personal meaning and hand-painted character of the source artwork while remaining recognizable at small system-icon sizes.

## Approved Direction

Use the existing `LemonYarn` artwork as the icon subject without redrawing Lemon or changing the rabbit's proportions, markings, pose, or original brushwork. The composition contains only Lemon, the yarn ball, and a restrained watercolor background. It does not include the app name, letters, borders, flowers, extra knitting tools, or decorative shadows.

## Composition

- Start from a 1024-by-1024 pixel opaque master image.
- Center Lemon and the yarn ball as one visual unit.
- Scale the subject to remain prominent while preserving approximately 12 percent clear space around its outermost visible edges.
- Keep both ears, the complete resting body, paws, and the readable round form of the yarn ball within the safe composition.
- Do not pre-apply rounded corners or platform masks. Apple platforms apply their own icon shape.
- Do not use transparency in the delivered App icon.

## Background and Color

Use a soft watercolor field derived from the existing family artwork and app theme:

- pale sky blue as the main atmosphere;
- subtle lavender toward the lower portion and edges;
- a small amount of warm soft white behind the subject to maintain separation;
- no hard geometric gradient, strong vignette, high-contrast outline, or photorealistic lighting.

The background must support the original illustration without changing its colors. The lavender yarn remains the main color accent, and Lemon's gray-brown markings must remain distinguishable at small sizes.

## Asset Delivery

- Preserve the current `LemonYarn` source asset unchanged.
- Add a separate `AppIcon.appiconset` for the main KnitNote target.
- Use the same approved master composition for iPhone, iPad, and Mac icon renditions.
- Provide the same composition for the Watch target when its asset catalog is configured, so the product identity remains consistent across platforms.
- Configure the Xcode project to use `AppIcon` instead of leaving the App icon compiler setting empty.

## Quality and Validation

- Inspect the 1024-pixel master for edge artifacts, accidental transparency, or cropping.
- Review representative small previews at 60, 40, 32, and 20 points to confirm Lemon and the yarn ball remain recognizable.
- Verify the icon under the platform's normal rounded-square and circular masks without embedding those masks in the source.
- Build the iOS device, iOS Simulator, and macOS targets after adding the asset.
- Validate the generated application's `Info.plist` identifies `AppIcon` as its icon asset.
- If a watchOS SDK is unavailable, validate the Watch asset structure and record the unverified Watch build explicitly.

## Accessibility and Localization

The App icon contains no text and requires no localized variants. It should not add in-app accessibility labels because the operating system announces the localized app name.

## Out of Scope

- Redrawing or AI-restyling Lemon.
- Adding the mother or full family scene to the App icon.
- Creating dark-mode or tinted icon variants for version one.
- Changing the launch image, home-screen artwork, or existing in-app `LemonYarn` asset.
