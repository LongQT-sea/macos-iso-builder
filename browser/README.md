# Feather: a lightweight Chromium browser for macOS 10.14 Mojave

Feather is a small, tabbed web browser built on **Chromium 116** through
**Electron 26.6.10**. It is meant for Intel Macs that can't upgrade past
**macOS 10.14 Mojave**.

| | Feather |
|---|---|
| Engine | Chromium 116 (Electron 26.6.10) |
| Minimum macOS | 10.14 Mojave (Intel, x86_64) |
| Download size | ~86 MB (zip / DMG) |
| Installed size | ~215 MB |
| RAM | ~500 MB for one simple tab, ~850 MB for five. Heavy sites use more. Sleeping tabs drop back toward the one-tab figure. |
| Build requirements | < 2 GB disk, < 2 GB RAM, ~5 min |

## Why Electron 26 and not a newer Chromium?

Chromium 117 and later need macOS 10.15 or newer. Electron 26 is the last
release that bundles a Chromium that still runs on Mojave.

Building Chromium itself from source is not practical on a modest machine. It
needs about 100 GB of disk, 16 GB or more of RAM and several hours. Feather
reuses Electron's prebuilt Chromium, so it builds in minutes and stays well
under 15 GB of RAM and 20 GB of storage.

> [!WARNING]
> Chromium 116 no longer gets security fixes. Feather keeps web pages
> sandboxed: no Node.js in pages, context isolation, the Chromium sandbox,
> and permissions denied unless you allow them. Even so, it is an old engine.
> Keep it for everyday browsing and do your banking on a maintained browser
> where you can.

## What makes it light

- **Tab sleeping.** A background tab unused for 10 minutes has its renderer
  process freed. It keeps its title and reloads when you click it. Tabs
  playing audio are never put to sleep. You can change the timer with
  `FEATHER_TAB_SLEEP_SECONDS=<n>`, where `0` turns it off.
- **A cap of 4 renderer processes.** Extra tabs share processes instead of
  each starting a new one of about 100 MB.
- **Fewer Chromium extras:** back/forward cache, Media Router/Cast,
  Translate and optimization hints are off, as is the spellchecker. V8 runs
  in `--optimize-for-size` mode.
- **Autoplay** with sound needs a click first.
- **Only English locales** are bundled, and packages use maximum compression.
- **A plain HTML toolbar**, with no framework and no extensions system.

## Features

Tabs, an address bar that also searches (DuckDuckGo), back/forward/reload,
find in page, zoom, full screen, downloads saved to `~/Downloads`, a
permission prompt for camera, microphone, location and notifications, dark
mode, and set-as-default-browser support for http/https.

### Keyboard shortcuts

| Action | Keys |
|---|---|
| New tab / window | ⌘T / ⌘N |
| Close tab | ⌘W |
| Address bar | ⌘L |
| Reload / force reload | ⌘R / ⇧⌘R |
| Back / forward | ⌘[ / ⌘] |
| Switch to tab 1–8 / last tab | ⌘1–⌘8 / ⌘9 |
| Next / previous tab | ⌃Tab / ⌃⇧Tab |
| Find in page | ⌘F |
| Zoom in / out / reset | ⌘= / ⌘- / ⌘0 |
| Developer tools | ⌥⌘I |

## Get it

### Build with GitHub Actions (no Mac needed)

1. Open the **Actions** tab and choose **Build Feather browser (macOS 10.14+)**.
2. Click **Run workflow**. You can enter a tag to publish a release.
3. Download `Feather-macOS-x64` from the run's artifacts. It contains a `.dmg`
   and a `.zip`.

### Build locally (any macOS, Linux or Windows with Node.js 18+)

```sh
cd browser
npm install
npm start          # run it
npm run dist       # build dist/Feather-1.0.0-macOS-x64.dmg and .zip (.dmg only on macOS)
```

On Linux or Windows, build only the zip: `npx electron-builder --mac zip --x64`.

### First launch

The app is not signed with an Apple Developer ID. On the first launch,
**right-click Feather.app → Open → Open**. After that it opens normally.
