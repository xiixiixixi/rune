# Rune Optical Lens Rail — Design QA

## Comparison target

- Source visual truth: `/Users/tc/.codex/generated_images/01a04cef-17b1-7ee2-bdd7-0529745a8824/exec-6e37bdfd-d480-412d-b97c-2c44a0c1e6c1.png`
- Native implementation capture: `/Users/tc/git/rune/artifacts/ui-audit/optical-lens-rail/settings-general.png`
- Normalized source: `/Users/tc/git/rune/artifacts/ui-audit/optical-lens-rail/reference-general-normalized.png`
- Normalized implementation: `/Users/tc/git/rune/artifacts/ui-audit/optical-lens-rail/implementation-general-normalized.png`
- Full-view comparison: `/Users/tc/git/rune/artifacts/ui-audit/optical-lens-rail/general-comparison.png`
- Focused control comparison: `/Users/tc/git/rune/artifacts/ui-audit/optical-lens-rail/controls-comparison.png`
- State: General settings, dark appearance, Desktop save location, PNG export, Chinese production copy, slate sample background for equal-state visual QA.

## Viewport and normalization

- Source pixels: `1548 x 1016`.
- Native Rune window: `1160 x 760 pt` at Retina `2x`.
- Implementation capture pixels: `2320 x 1520`.
- CSS viewport: not applicable; Rune is a native AppKit/SwiftUI macOS application.
- Density normalization: the source was center-cropped from `1548 x 1016` to `1548 x 1014` and resampled to `1160 x 760`; the implementation was resampled from Retina `2320 x 1520` to `1160 x 760`.

## Findings

- Fonts and typography: passed. Space Grotesk/system fallbacks, weights, title hierarchy, compact row copy, monospaced values, wrapping, and Chinese localization retain the selected design's density and legibility.
- Spacing and layout rhythm: passed. The `184 pt` sidebar, central section groups, `316–336 pt` embedded inspector, card spacing, row heights, compact `5–9 pt` radii, and no-horizontal-scroll layout align with the normalized visual target.
- Colors and visual tokens: passed. The workspace stays near-black. Cyan, aubergine, magenta, and amber are confined to refractive rims, micro-underlines, selected seams, and glass edges rather than broad gradient fills.
- Image quality and asset fidelity: passed. The real Rune eggplant asset and bundled forest raster are used; the preview crop is centered, contained, sharp, and never overflows its frame. SF Symbols supply the coherent thin icon family.
- Copy and content: passed with intentional production mapping. The generated mock's internally inconsistent sample label/background is replaced by truthful live state; real settings, menus, shortcuts, update controls, editor tools, and recording options remain connected to production data.
- Controls and affordances: passed. Sliders keep native keyboard/focus behavior under a neutral `2 pt` rail and optical lens. Switch membranes remain neutral while state is shown by lens position and refractive rim. Segment selection, menus, cards, and primary buttons use the same neutral-inset plus spectral-seam language.
- Accessibility: passed for the changed component surfaces. Icon-only controls retain labels, native sliders remain in the hierarchy, focus rings remain visible, disabled states are dimmed, and Reduce Transparency receives opaque fallbacks.

## Full-view comparison evidence

`general-comparison.png` shows the selected generated image on the left and the native implementation on the right at the same `1160 x 760` viewport. Major-region proportions, sidebar width, title position, card density, inspector placement, and vertical rhythm align. The implementation intentionally preserves truthful Chinese product data and functional controls.

## Focused comparison evidence

`controls-comparison.png` isolates the right inspector at equal scale. It verifies the contained forest preview, thin neutral rails, optical lens thumbs, compact spacing, background swatches, low radii, and restrained dark glass material.

## Comparison history

### Initial implementation — blocked

- Evidence: `/Users/tc/git/rune/artifacts/ui-audit/library-settings-shell/settings.png` and `/Users/tc/git/rune/artifacts/ui-audit/settings-spectral-controls/general.png`.
- P1: slider progress was a thick flat four-color gradient rather than transparent optical refraction.
- P1: enabled switches used a filled rainbow/purple track, creating a generic AI-dashboard look.
- P2: broad purple selected states and primary buttons conflicted with the selected neutral glass direction.
- P2: the right inspector was too narrow and separated by an unnecessary vertical rule.

### Final implementation — passed

- Evidence: `general-comparison.png`, `controls-comparison.png`, and the final native captures under `artifacts/ui-audit/optical-lens-rail/`.
- Fixes: rebuilt shared sliders and switches around a neutral rail/membrane and a single optical lens; widened and embedded the right stage; removed the separator; replaced broad accent fills with neutral insets and spectral seams; propagated the language to menus, library selection, editor tools, and video-editor tabs.
- No actionable P0, P1, or P2 visual differences remain. Persisted user appearance choices can intentionally change the live preview background and are not design drift.

## Cross-product extension — passed

- Final native captures: `/Users/tc/git/rune/artifacts/ui-audit/product-system-final/`.
- Covered surfaces: Capture settings, menu-bar command rail, material library, saved-capture preview, pinned screenshot toolbar, confirmation toolbar, image editor, recording status, video editor, permission guide, OCR result, burst setup, burst review, update window, long-capture status, and toast.
- Scroll behavior: passed. Settings, library, burst review, update notes, menu overflow, and OCR keep wheel/trackpad scrolling while persistent system scrollbars remain hidden.
- Selected states: passed. Solid purple blocks and check circles were replaced with neutral insets, optical marks, and thin spectral seams. Destructive and recording states retain semantic red.
- Transient surfaces: passed. Pinned controls, burst panels, toast, OCR, and preview now use the same dark membrane, low radius, thin spectral edge, and neutral icon language as the main product shell.
- Editing surfaces: passed. Image and video editors preserve real tools, crop/trim behavior, background selection, and export actions while sharing inspector tabs, compact buttons, and selection borders.

## Runtime verification

- `make build`: passed.
- `codesign --verify --deep --strict`: passed as part of the build target.
- Signing identity: `Rune Local Developer`.
- Bundle identifier: `com.tc.rune`.
- Native audit routes rendered General, Capture, Recording, About, Material Library, Menu, Preview, Pin, Confirm Toolbar, Editor, Recording Status, Video Editor, Permission, OCR, Burst Setup, Burst Review, Update, Long Capture, and Toast states.
- Impeccable mechanical detector: passed with no findings across the changed UI targets.
- `git diff --check`: passed.
- Browser console checks are not applicable to this native macOS build.

## Follow-up polish

- P3: macOS material luminance varies slightly with the user's wallpaper and Reduce Transparency setting; the explicit dark overlay keeps the inspector within the selected direction without replacing native material behavior.

final result: passed
