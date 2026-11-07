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
  directly, so there is one place to change it.
- Never use Caveat for UI text, and never use SF Pro Rounded for agent ink.
