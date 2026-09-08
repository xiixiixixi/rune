# Rune Settings — layout redesign QA

## Spatial thesis

- Primary path: choose a domain in the left rail, change its settings in the central flow, and read the result in the right glass stage.
- Grouping: file, behavior, shortcut, capture-flow, recording-content, update, and license settings are separated by meaning rather than by equal-size dashboard cards.
- Hierarchy: the central settings flow leads; the glass stage is contextual support and never repeats the left-side fields.
- Density: compact native Mac rows with restrained 8 pt group radii and one persistent 9 pt glass surface.

## Implemented

- Replaced the horizontal tabs and inconsistent page templates with one vertical navigation rail and one shared three-zone workspace.
- Rebuilt General, Capture, Recording, and About on the same layout system.
- Removed the decorative green leaves and dots. Active icons use a compact spectral stroke language.
- Retained the approved black workspace, cyan-magenta-amber glass refraction, low corner radii, and eggplant brand asset.
- Preserved real menus, segmented pickers, sliders, toggles, shortcut recording, permissions, update checks, destructive resets, and appearance editing.
- General, Capture, and Recording stages render actual output-driven previews; About uses the same stage as product identity rather than a duplicate settings summary.

## Verification

- Build: passed (`make build`).
- Impeccable layout detector: passed with no findings.
- Signed development app: `/Users/tc/git/rune/.build/Build/Products/Debug/Rune.app`.
- Final captures: `settings-layout-final/general.png`, `capture.png`, `recording.png`, and `about.png`.
- Style comparison: `settings-layout-final/reference-general-comparison.png`.
- First visual pass exposed an unreadable capture-position menu and a wrapping recording status bar; both were fixed in the final pass.

Final result: passed. The layout intentionally departs from the supplied mock while retaining its material, palette, contrast, and embedded-glass character.
