# Scribe design rules

## Typography

Keep it simple: two typefaces, each with one job.

### UI text: SF Pro Rounded

- Every piece of interface text uses SF Pro Rounded: `.font(.system(size:weight:design: .rounded))`.
- Use **two weights at most**: `.regular` for body and secondary text and `.semibold` for titles, the wordmark
  and emphasis. Don't add other weights (light, medium, bold and so on).
- Make hierarchy with size and colour, not with more weights or more typefaces.

### Agent drawing and writing: Caveat

- Everything the agent writes or draws by hand on the page (labels, equations, annotations) uses
  [Caveat](https://fonts.google.com/specimen/Caveat).
- The font is bundled at `Scribe/Fonts/Caveat.ttf` and registered through `UIAppFonts` in `project.yml`. Its
  PostScript name is `Caveat-Regular`, and its licence (SIL OFL 1.1) is at `Scribe/Fonts/Caveat-OFL.txt`.
- In code, go through `Handwriting` (`Scribe/Landing/LandingSupport.swift`) rather than naming the font
  directly, so there is one place to change it. For SwiftUI text, use `Handwriting.text(_:size:)`: the app sets
  `.fontDesign(.rounded)` everywhere, which would otherwise turn Caveat into SF Pro Rounded.
- Never use Caveat for UI text, and never use SF Pro Rounded for agent ink.

## Liquid Glass

Follow Apple's Liquid Glass guidance (iOS 26 and later). Liquid Glass is the layer of controls that floats above
the content. It is not the content itself.

### Where glass goes

- **Use system controls first.** Navigation bars, toolbars, menus, popovers, sheets and alerts get Liquid Glass on
  their own. Put actions in `.toolbar` wherever the screen has a navigation bar, as the library does.
- **Custom floating controls** (the canvas chrome, which floats over a full-screen page) use `canvasChrome(_:)`.
  It gives `glassEffect(.regular.interactive())` on iOS 26 and a material with a hairline before that. Pass
  `interactive: false` for glass that only holds controls (a banner), so it doesn't react to touch like a button.
- **Never put glass in the content layer.** Pages, tiles, cards and empty states are content. Buttons there use
  `primaryActionButton()` (filled capsule) or `secondaryActionButton()` (tinted capsule), never `.glass` or
  `.glassProminent`.
- **Never stack glass on glass.** A button inside a glass bar, capsule or popover is plain (`ChromeButton`) or
  uses the action-button styles above.

### Grouping and motion

- **Group by job.** Controls that belong together share one capsule (Undo / Redo; Share / More; the tools; the
  colours). Separate groups sit `CanvasChromeMetrics.groupGap` (12 pt) apart.
- **One container per edge.** Wrap each cluster of floating glass in `ChromeGroup`, which is a
  `GlassEffectContainer` on iOS 26. Glass in a container is drawn together and can blend.
- **Morph, don't pop.** Glass that appears or disappears next to other glass gets `chromeGlassID(_:in:)`, so it
  grows out of its neighbour (the colours capsule out of the tools). Animate it with `CanvasChromeMetrics.morph`.

### Look

- **Shapes:** capsules for bars and groups, circles for a lone button. Every button is at least 44 x 44 pt.
- **Symbols** use the system's default size. Don't add weight to make a symbol stand out.
- **Selection is tint, not more glass.** A selected control shows an accent-tinted symbol on a soft accent circle
  (`ChromeSymbol(selected:)`). Disabled controls fade to 35%.
- **Tint sparingly.** Only the one main action in a bar is filled (Place, Try Again, Send). Everything else is
  neutral.
- **No custom shadows, borders or backgrounds** on glass from iOS 26 on. The system adapts glass to what is
  behind it.
