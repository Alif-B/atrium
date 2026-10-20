# Atrium

**One window for all your Mac apps.** A Liquid Glass sidebar holds your installed apps and your web apps, and the one you pick fills the space beside it, so the whole thing reads as a single window. Think Rambox, but for the native apps you already have, plus web apps that run inside it.

Built for macOS 26 (Tahoe). Pure Swift and AppKit/SwiftUI, Apple frameworks only, no third-party packages.

> **Status:** a personal project that is now usable day to day, with plenty of rough edges. Issues and pull requests are welcome.

## What it does

- **Native apps, in one window.** Click an icon and that app's real window snaps beside the sidebar. All the apps move, resize, minimize, hide and close together with Atrium, like one app. You can resize Atrium from any edge or corner, or resize an app by its own edge and Atrium follows.
- **Web apps, built in.** Add any website as an app. It runs in Atrium itself (WebKit), with its own private sign-in, separate from your browsers and from your other web apps. Links to other sites open in your default browser, sign-in popups work, downloads go to Downloads, and the page's notifications become Mac notifications.
- **Premium feel.** A real Liquid Glass rail, a lens that glides between apps, hover magnification, a crossfade when switching, and a still snapshot while the window moves so nothing flickers.
- **Badges and sounds.** Unread counts from Dock badges (native apps) or the page title (web apps), with an optional sound when something new arrives.
- **Hibernation.** Optionally put an app to sleep after 15 minutes of not using it (never while it plays sound or is on a call).
- **Calm and tidy.** Apps preload at launch behind a loading card, closed apps are greyed out, empty states are friendly, and it repairs itself after sleep and display changes.
- **Yours to arrange.** Drag icons to reorder; custom icons (choose a file or paste an image, with a size slider); right-click for Reload, Edit, Hibernate and more.

## How it works

macOS has no API for embedding another app's window in your own. Atrium instead uses the Accessibility API to place each app's real window exactly over its workspace area, keeps its own window directly underneath, and treats the pair as one. Web apps skip all of that: they are web views inside Atrium's window.

## Requirements

- macOS 26 (Tahoe), Apple Silicon recommended
- Swift toolchain from the **Command Line Tools** (Xcode is not needed, and the project is set up not to use it)
- **Accessibility** permission (required, to place app windows)
- **Screen Recording** permission (optional, for the smooth snapshot while moving and switching)

## Build and run

```bash
git clone https://github.com/Alif-B/atrium.git
cd atrium
./scripts/build.sh      # builds, signs and installs to ~/Applications/Atrium.app
open ~/Applications/Atrium.app
```

Use the scripts rather than bare `swift build`: `scripts/env.sh` works around a stale `PackageDescription` interface in some Command Line Tools installs.

Other commands:

| Command | What it does |
|---|---|
| `./scripts/run.sh` | Build and relaunch (add `--demo` for sample data that touches nothing) |
| `./scripts/test.sh` | Run the tests (Swift Testing) |
| `log stream --predicate 'subsystem == "com.alif.atrium"' --level debug` | Watch Atrium's logs |

**Signing:** macOS forgets the Accessibility permission every time an ad-hoc signed app changes. [`scripts/SIGNING.md`](scripts/SIGNING.md) shows how to create a free self-signed certificate once, so the permission survives rebuilds.

## Project layout

| Path | What's there |
|---|---|
| `Sources/AtriumCore` | Pure logic with tests: app library, layout maths, badge parsing, hibernation rules, link rules |
| `Sources/Atrium` | The app: sidebar, windows, services (window snapping, web apps, badges, hibernation) |
| `Tests` | Swift Testing suites for the core |
| `docs/PLAN.md` | The original build plan and design decisions |

## Known limits

- Native apps are real separate windows kept in place, not embedded views. Rarely, an app with a minimum window size larger than Atrium's area can't be fitted.
- Web apps use Safari's engine, not Chrome's. A few sites (video calls, screen sharing) can be more limited, and Edge/Chrome saved passwords and extensions aren't available inside them.
- Atrium moves the window by hiding and re-placing apps; Screen Recording permission makes this look seamless.

## Contributing

Fork it, change it, send a pull request. Please keep to the rules in [`CLAUDE.md`](CLAUDE.md): Apple frameworks only, no private APIs, Swift 6 strict concurrency, and every design number in the constants files.

## License

[GNU General Public License v3.0](LICENSE) or later. You are free to use, study, change and share Atrium, **and any version you distribute, modified or not, must stay open source under the same licence.** Copyright © 2026 Alif-B.
