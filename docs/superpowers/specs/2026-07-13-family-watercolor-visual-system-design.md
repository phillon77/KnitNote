# Family Watercolor Visual System Design

## Purpose

Transform KnitNote into a warm, recognizable knitting companion based on the user's daughter's illustration of her mother knitting beside the family rabbit, Lemon. Preserve the illustration's emotional value and hand-drawn character while keeping frequent knitting actions and pattern reading clear.

## Approved Direction

Use a balanced brand system rather than an illustrated background on every screen. Combine a prominent full illustration on the home screen with smaller Lemon, flower, cloud, and yarn motifs in emotionally appropriate states. Version one uses a fixed light appearance.

The source artwork is `IMG_5327 2 (2).JPEG`. The full composition must preserve the woman, knitted fabric, continuous yarn, Lemon, yarn ball, flowers, and surrounding sky. Do not stretch the image or crop away the relationship between the woman and Lemon.

## Visual Language

Derive semantic colors from the illustration:

- Sky blue for page atmosphere and selected navigation.
- Lavender for secondary actions, yarn references, and supporting accents.
- Berry pink from the sweater for primary actions and completion.
- Warm flower yellow for highlights and gentle notices.
- Soft white for cards, forms, and reading surfaces.
- Deep blue-gray for text instead of pure black.

Use a very pale blue-to-lavender watercolor gradient for general page backgrounds. Cards use translucent soft white, generous rounded corners, and restrained blue-purple shadows. Preserve standard red for destructive actions. All final color tokens must pass the platform's normal text contrast requirements.

## Home and Project Experience

Place the complete illustration as a responsive hero at the top of the Projects screen. Use aspect-fit sizing with a shorter presentation on iPhone and a wider presentation on iPad and Mac. Content begins below the image; text must not be overlaid on the artwork.

Use the same complete illustration on the native iOS launch screen with aspect-fit presentation and a matching soft sky background. The launch screen must not add a timed delay or simulate app content. Mac opens directly into its normal window.

Represent projects as soft white cards. A card contains a project photo when available, otherwise a lavender yarn placeholder, plus project name, current row, and recent activity. The most recently used project receives stronger visual priority. A thin yarn-like line may communicate progress without replacing accessible text.

The row counter remains visually focused on the large number. The Complete Row action uses a subtle berry-to-lavender treatment; undo, notes, and pattern actions use translucent soft-white capsules. Completion feedback may use a brief flower glint and haptic feedback, and must respect Reduce Motion.

## Lemon and Illustration Motifs

Version one extracts Lemon with the lavender yarn ball from the original art, retaining the daughter's original brushwork. Use this asset for empty or supportive states:

- No projects: Lemon rests on the yarn beside the first-project action.
- No patterns: Lemon looks toward an empty page.
- Empty yarn library: Lemon sits beside an empty yarn area.
- Inactive project reminder: Lemon sleeps by the yarn, paired with pressure-free copy.
- Completion: Lemon accompanies a gentle success state.

Do not repeat Lemon on ordinary content screens or place Lemon over operational controls. Flowers may appear near headings, success states, and empty states. Clouds remain faint background atmosphere. Yarn curves may guide visual flow but never cross text or controls.

Future releases may add newly illustrated Lemon poses for sleeping, reminders, completion, and missing content. Each derivative must be reviewed for consistency with the original proportions, palette, and watercolor texture before inclusion.

## Navigation, Forms, and Settings

Use a translucent soft-white tab bar. Selected tabs receive a sky-blue capsule treatment. Retain Apple system icons for recognition and accessibility rather than replacing all controls with hand-drawn icons.

Forms and settings remain simple, with pale lavender grouping, soft-white cards, and standard platform behavior. Sheets use soft white with restrained blue-purple shadow. Touch targets remain at least 44 points.

## Pattern Reader Protection

Pattern content remains on pure white or neutral light gray. Never put watercolor, flowers, Lemon, or the hero artwork behind a PDF, image pattern, markup canvas, or essential pattern text.

Use the brand colors only for surrounding controls: translucent blue-lavender toolbar material, berry and lavender actions, existing yellow horizontal highlight, and existing pink vertical highlight. Preserve iPad full-screen presentation, page navigation, highlights, markup, notes, counters, and all reading-state persistence.

## Platform and Accessibility Requirements

- Support iPhone, iPad, and Mac responsive layouts.
- Version one uses a fixed light appearance to faithfully represent the artwork.
- Support Dynamic Type without truncating essential actions or data.
- Provide localized Traditional Chinese and English accessibility descriptions for meaningful artwork.
- Mark decorative flowers, clouds, and yarn flourishes as hidden from assistive technologies.
- Preserve sufficient contrast for text, controls, and states.
- Respect Reduce Motion by disabling floating and glint animations.
- Keep all existing interaction behavior and stored data unchanged.

## Version One Scope

- Add the original artwork as an optimized app asset.
- Add a native iOS launch screen using the complete artwork without an artificial delay.
- Add a full responsive hero to Projects.
- Establish semantic theme colors, gradient backgrounds, cards, buttons, sheets, and tab styling.
- Add the original Lemon empty-state asset.
- Restyle project cards, the counter screen, and pattern-reader chrome.
- Apply responsive behavior on iPhone, iPad, and Mac.
- Add Traditional Chinese and English accessibility text.
- Add visual regression checks through simulator screenshots and retain all automated behavior tests.

## Deferred Scope

- Newly drawn Lemon poses.
- Elaborate completion animation.
- Dark appearance.
- Watercolor backgrounds inside pattern content.
- Replacement of all system icons with custom illustrations.

## Delivery Strategy

Implement the theme foundation and optimized artwork assets first, then Projects and project detail, then empty states and Lemon, and finally pattern-reader chrome. Validate each stage on iPhone and iPad before applying it more broadly. This keeps core knitting workflows usable throughout the redesign and makes visual feedback easy to isolate.
