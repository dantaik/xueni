# Xueni for iPhone

A native reader for [Xueni](../README.md) — the journal that lives entirely on
Ethereum — with two local databases and a design in black, white and grey.
It reads both chains from your own choice of nodes, keeps everything it has
read on the phone, and never needs a wallet, a server or an account.

It is not the web app in a web view. The macOS app is that, and says so; a
phone wants something that opens instantly, reads from the cache when there
is no signal, and looks like it belongs on the device. So this is SwiftUI
over SwiftData, with the reading logic ported to Swift and held to the same
test vectors as the web app and the command-line tool.

## What it does

- **Read** — the newest posts from Ethereum and Taiko, merged newest-first by
  block time, with the same frontier marker the web app shows where the
  slower chain has been scanned less far; a single-chain view; "load earlier
  posts" that reads a block range at most once, ever.
- **A post** — the letter in a serif face, images resolved from the chain,
  tags, relations (`re`, `supersedes`, `prev`, `series`), the hook it went
  through, who relayed it, previous and next by the same author, "Raw" (the
  exact document the chain holds, with what it cost), copy link, copy the
  `[title](0x…)` reference, save as `.md`.
- **An author** — their posts across both chains, their ENS name when the
  reverse record resolves forward to the same address, follow/unfollow,
  export their complete output as an archive.
- **Following** — the cheap path the contract was designed for: one head read
  per author per chain, then a walk down single blocks, with a divider where
  you got to last time. No range scan anywhere.
- **Search and tags** — a word in any title, tag or body, as a substring so
  Chinese works; the tags seen so far; an address, an ENS name or a
  transaction hash typed into the search field opens the thing itself.
- **Write** — drafts kept on the phone as you type, a byte counter on the
  title, tags and relations, a preview. The phone does not publish (below);
  it hands the draft on as a Markdown file that the web app's "Import .md…"
  and `xueni publish` both read.
- **Settings** — RPC endpoints per chain in the order they are tried, the
  rescan delay, English or Chinese, the followed authors, settings and
  archive files in the web app's own formats, the scanned ranges, and one
  button to clear the chain cache.

## The two databases

Two SQLite stores under one SwiftData container (`Persistence/Containers.swift`):

| Store | Holds | Lifetime |
|---|---|---|
| `ChainCache.store` | post rows, the decompressed documents, the images, the block ranges each chain has been scanned over, the heads each scan reached | permanent (on-chain data does not change), but disposable: "Clear the chain cache" empties it and the next scan reads it back |
| `Reader.store` | the authors you follow, the draft you are writing | yours; carried by the settings file and never touched by a cache clear |

The reading logic works on an in-memory scan store per chain
(`MemoryScanStore` in the Kit), seeded from `ChainCache.store` at launch
and written through to it after every window a scan reads, so an
interrupted scan keeps what it had. Bodies and images are read cache-first;
a post opened once costs no request the second time.

## Why the phone does not publish

A post's bytes are `publish(title, brotli(document))`, signed by a wallet.
Apple's Compression framework decodes brotli but does not encode it, and
signing on a phone means WalletConnect's SDK and a project id. Both are
possible; neither is small, and neither is what a reader opens the app for.
The Write tab therefore does what a notebook does: keeps the letter until it
is handed on. The `.md` it saves is the document the web app would build,
with the title in front-matter as static-site generators write it, so
"Import .md…" on the web fills every field and `xueni publish letter.md`
sends it from a terminal. The bytes on chain are the same whichever way.

## Layout

```
ios/
  project.yml            the Xcode project as text (XcodeGen); Xueni.xcodeproj is generated from it
  Xueni.xcodeproj        generated — regenerate after editing project.yml
  Xueni/                 the app
    App/                 entry point, tabs and routes, the grey design tokens
    Persistence/         the SwiftData models, the two stores, the write-through cache
    Data/                preferences, one reader per chain, the hub the views observe, the body index, the archive builder
    Views/               one folder per tab, plus Shared/ for the pieces every page uses
    Resources/           the privacy manifest
    Assets.xcassets/     the icon (rendered from the SVG) and the monochrome accent colour
  XueniKit/              the Swift package with everything that is not a view (below)
  scripts/               the icon's SVG source and the script that renders it through the web app's Chromium
```

### XueniKit

The part with logic worth testing, kept apart from the app the way the macOS
app keeps its image crate apart from its shell: plain Foundation, no UI, so
`swift test` runs on Linux as well as on a Mac.

- `Codec`, `Title`, `Document`, `Payload` — the post codec ([`codec/SPEC.md`](../codec/SPEC.md)),
  all three call forms, the front-matter grammar with its frozen reading
  rules, version detection, decompression bounded while it happens.
  `Tests/…/Resources/vectors.json` is a copy of the codec's own test
  vectors; CI checks it is byte for byte the same file, and every vector
  is decoded (on Linux through a stand-in brotli that knows only those
  payloads; on a Mac through Apple's decoder, for real).
- `Segments`, `MemoryScanStore`, `Scanner`, `FeedController`,
  `AuthorListController`, `MergedFeed`, `MergedWalks`, `Timeline` — ports of
  the web app's data layer: coverage as a set of ranges, the bounded sweep,
  the reverse-linked walk, the cross-chain merge and its frontier. The tests
  drive them over an in-memory chain and count requests, as the web app's do.
- `OrderedTransport`, `ChainIO`, `ENS` — JSON-RPC with ordered failover and
  a cool-down for a failed node, the contract's two views and one event,
  bodies and images from transactions, ENS reverse-then-forward.
- `Markdown` — the subset of xueni-spec §8, parsed to blocks and inlines with
  no HTML anywhere; `LinkTarget` and `ImageSource` say what a URL may do.
- `Identicon` — blockies, the same seed and pattern `blo` draws on the web,
  painted in three tones of grey.
- `Archive`, `SettingsFile`, `Strings`, `Search`, `Format`.

## Building

Requires Xcode 16 or later. The generated project is committed, so:

```bash
open ios/Xueni.xcodeproj      # pick a simulator or a device, run
```

To change the project itself, edit `project.yml` and regenerate:

```bash
brew install xcodegen
cd ios && xcodegen generate
```

The Kit's tests, anywhere Swift runs:

```bash
cd ios/XueniKit && swift test
```

The icon PNG is committed; to redraw it after changing `scripts/icon.svg`:

```bash
cd webapp && npm install && cd .. && node ios/scripts/render-icon.mjs
```

`.github/workflows/ios.yml` runs the Kit's tests on Linux and on macOS, checks
the vectors file against the codec's, regenerates the project from its spec
and builds the app for the simulator on every pull request that touches
`ios/`.

## Design

No colour. Every tone is one of the system's semantic greys, so the light
and dark appearances, bold text and increased contrast all come for free,
and the one accent the web app allows itself — its indigo — is replaced by
the ink: links, buttons, selection and the tab bar are black on white or
white on black. Titles and the letters themselves are set in the system
serif (New York); bylines, dates and addresses in the system sans with
tabular figures; the raw document in monospace. Identicons keep their
pattern and lose their colour. Photographs are the one thing left in colour,
because they are the author's, not the interface's.

## Formats it shares

- The archive (`.xueni.json`, format 2) and the settings file
  (`xueni.settings`, format 1) are the web app's and the CLI's; a file from
  any of them restores any other. The three settings the phone has no use
  for — the publish target, the theme, the console log switch — are carried
  through unchanged.
- The `.md` a post or a draft is saved as is the exact stored document; a
  draft adds `title:` for the tools that read one.
- Links copied from a post are the web app's canonical URLs
  (`https://xueni.xyz/<chain>/tx/<hash>/<n>`), and a pasted one opens in the app.
