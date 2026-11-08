# Scribe

An iPad notebook with an AI tutor that works on the page. Write with the Pencil, import PDFs, then ask by
voice, by typing, or by lassoing a region. The agent answers by writing and drawing on the page in handwriting,
and can open small interactive visualizations.

## Stack

- Swift, SwiftUI, PencilKit, PDFKit, Vision (iPadOS 18+)
- [Claude](https://docs.anthropic.com) (Haiku 5.5) for the agent
- [ElevenLabs](https://elevenlabs.io) for speech to text and text to speech
- WebKit, sandboxed, for the visualizations
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) generates the Xcode project from `project.yml`

## Run locally

```sh
brew install xcodegen
xcodegen generate
open Scribe.xcodeproj
```

Run the `Scribe` scheme on an iPad or an iPad simulator. Then, in the app's Settings, add an Anthropic API key
(and an ElevenLabs key for voice). Keys are kept in the Keychain.

## Architecture

```
Scribe/
  Library/         notes and folders, saved on device (CanvasStore)
  Canvas/          the note screen: pages, ink, chrome; CanvasModel runs it all
  PageMap/         reads a page into objects with ids (text, ink, figures, free space)
  Agent/           the agent's tools, checked against the page map, and its marks
  AI/              Claude and ElevenLabs clients, microphone and speaker
  Visualizations/  agent-written HTML cards in a locked-down WebView
  Settings/        API keys
```

A turn: you speak or type → `CanvasModel` sends the conversation, a picture of the page and its page map to
Claude → Claude calls tools (write, circle, draw, show a visualization) → each call is validated and drawn on
the page → the answer is spoken, or shown under the agent control.

Design rules are in [DESIGN.md](DESIGN.md).
