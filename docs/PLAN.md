# Atrium: Build Plan

> This plan is written for the **builder model** (Claude Sonnet). It is self-contained: follow it top to bottom. When the plan is approved, it is copied into the project as `docs/PLAN.md` and a short `CLAUDE.md` is added (§11).

---

## 1. Context

Alif uses Rambox to keep his work apps in one place. Rambox wraps *web* apps. He wants a personal macOS app that gives the same "one hub, one click" experience using the **native apps already installed on his Mac**.

macOS has no API for embedding another app's window inside our own. Screen-mirroring hacks are laggy and fragile. Atrium therefore works like this:

- A slim **Liquid Glass sidebar** sits at the left edge of the screen.
- Clicking an icon launches or activates that app and **snaps its real window** into the rest of the screen, leaving small, even gaps.
- Together, the sidebar and the active app read as **one app window**.

It must look and feel like a first-party Apple product on macOS 26 Tahoe.

### Decisions already made (do not revisit)

| Topic | Decision |
|---|---|
| Model | Docked sidebar + window snapping |
| Apps: native, installed now | **Slack** `com.tinyspeck.slackmacgap` (Electron) · **Claude** `com.anthropic.claudefordesktop` (Electron) · **Notion** `notion.id` (Electron) · **Grok Bot** `com.anysphere.sand` (Electron) · **Outlook** `com.microsoft.Outlook` · **Muse** `com.meta.endo` |
| Apps: web-only | **Gmail, Google Calendar, Messenger, Jira, YouTube Music.** Alif creates each one as a **Safari web app** (Safari ▸ File ▸ Add to Dock…). Each becomes a real standalone `.app` in `~/Applications` with its own process, window and Dock badge; bundle id prefix `com.apple.Safari.WebApp.`. Atrium treats these exactly like native apps. |
| Browser PWAs | Edge/Chrome "installed apps" (prefixes `com.microsoft.edgemac.app.`, `com.google.Chrome.app.`) can't be snapped, because their windows belong to the browser process. The picker shows them with an ⓘ hint: "For best results, create this with Safari ▸ File ▸ Add to Dock." |
| Must-haves | Unread badges · add/remove/reorder apps · launch at login + restore state |
| Out of scope (v1) | Keyboard shortcuts · managing secondary windows · auto-hide · per-display choice UI |
| Layering | The sidebar is part of "the app". It sits at **normal window level**. Other apps' windows (e.g. Safari) cover it naturally, and it comes back to the front whenever a sidebar app is activated. |
| Layout | Floating, with **8pt gaps** around the sidebar and the snapped window |
| Displays | Alif uses the laptop alone *and* docked to external monitors. The sidebar lives on the **primary display** (the one with the menu bar) and must relocate cleanly when displays change. |
| Active-app indicator | **A glass lens that slides.** One lens glides between icons (§7.5). This is Atrium's signature element. |
| App type | A regular app: Dock icon, ⌘-Tab and a standard menu bar. Clicking Atrium in the Dock brings the workspace forward (B10). |
| Name | **Atrium** (one constant, `AppInfo.name`), bundle id `com.alif.atrium` |
| Who builds | The builder model writes all code. Alif tests, gives visual feedback and performs the permission and keychain steps. |

**Effort:** small to medium, 8 milestones. The risk is not the amount of code. It is the macOS quirks: activation rules, Electron apps that create windows late, coordinate systems, and how glass looks in an inactive window. This plan pins down each of them.

---

## 2. Environment facts (verified on Alif's Mac, 2026-10-07)

- macOS **26.6.2** (25G83), Apple Silicon (arm64).
- **Xcode is NOT installed.** Only the Command Line Tools are:
  - Swift **6.4**, with the default SDK **MacOSX 27.0** (MacOSX26.5 is also installed).
  - SwiftPM's default build system is `swiftbuild`.
  - `xcodebuild` and `actool` fail ("requires Xcode").
  - **No** Xcode projects, XcodeGen, asset catalogs or Icon Composer.
  - Available tools: `swift build`, `swift test`, `iconutil`, `codesign`, `security`, `PlistBuddy`, Homebrew.
- **Swift Testing** (`import Testing`) is available. XCTest is **not**.
- There are no code-signing identities yet (§3.3).
- **Liquid Glass APIs**, verified in the SDK interface files and all `macOS 26.0`:
  - `glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape())`. There is **no `isEnabled:` parameter**; to switch glass off, pass `.identity`.
  - `Glass.regular / .clear / .identity`, `.tint(Color?)` and `.interactive(Bool = true)`.
  - `GlassEffectContainer(spacing:content:)`.
  - `glassEffectID(_:in:)` and `glassEffectUnion(id:namespace:)`.
  - `glassEffectTransition(.matchedGeometry | .materialize | .identity)`.
  - `ConcentricRectangle`, plus `.rect(corners: .concentric(minimum:))`.
  - `.buttonStyle(.glass)` and `.buttonStyle(.glassProminent)`.
  - In AppKit, `NSGlassEffectView` (`contentView`, `cornerRadius`, `tintColor`, `style`).
  - `NSGlassEffectView.effectIsInteractive` and SwiftUI `reorderable()` are **macOS 27-only. Do not use them.**
- **Package manifest gotchas** (seen with this toolchain):
  - `.macOS(.v26)` does **not** resolve. Use `.macOS("26.0")`.
  - `.swiftLanguageMode(.v6)` does **not** resolve. Omit it; tools-version 6.0 or later already defaults to Swift 6 mode.

**What's installed.**
- In `/Applications`: Slack, Claude, Notion, Grok Bot, Microsoft Outlook, Muse, Safari, Microsoft Edge.
- `~/Applications/Edge Apps.localized` is empty, and there are no Safari web apps yet.

---

## 3. Build system (SwiftPM, no Xcode)

### 3.1 `Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Atrium",
    platforms: [.macOS("26.0")],
    targets: [
        // Pure logic (Foundation + CoreGraphics only): geometry, badge parsing, model, persistence.
        .target(name: "AtriumCore", path: "Sources/AtriumCore"),
        // The app (AppKit + SwiftUI + AX). Entry point: Sources/Atrium/main.swift
        .executableTarget(name: "Atrium", dependencies: ["AtriumCore"], path: "Sources/Atrium"),
        .testTarget(name: "AtriumCoreTests", dependencies: ["AtriumCore"], path: "Tests/AtriumCoreTests"),
    ]
)
```

- If the manifest fails, try `// swift-tools-version: 6.2`. Don't invent other APIs.
- If `swift test` complains about XCTest, run `swift test --disable-xctest`.

### 3.2 Scripts (all `#!/bin/zsh` with `set -euo pipefail`; each starts with `cd "$(dirname "$0")/.."`)

**`scripts/build.sh`**

```zsh
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Atrium"     # swiftbuild doesn't use .build/release
APP=build/Atrium.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Atrium"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
if security find-identity -p codesigning | grep -q "Atrium Local Signing"; then   # no -v: self-signed certs are "untrusted" but usable
  codesign --force --sign "Atrium Local Signing" "$APP"
else
  print -P "%F{yellow}⚠ Ad-hoc signing: Accessibility permission will reset on every build. See scripts/SIGNING.md%f"
  codesign --force --sign - "$APP"
fi
mkdir -p ~/Applications
rsync -a --delete "$APP/" ~/Applications/Atrium.app/
```

Notes on `build.sh`:
- No `--arch` flag.
- No `--options runtime`; it brings no benefit locally and blocks lldb.
- The app always runs from `~/Applications/Atrium.app`, a stable path. Login items and TCC both depend on that.

**`scripts/run.sh`**

```zsh
pkill -x Atrium || true
while pgrep -x Atrium >/dev/null; do sleep 0.1; done
./scripts/build.sh
open ~/Applications/Atrium.app --args "$@"     # e.g. ./scripts/run.sh --demo
```

**`scripts/test.sh`:** `swift test` (add `--disable-xctest` if needed).

### 3.3 `Resources/Info.plist`

| Key | Value |
|---|---|
| `CFBundleIdentifier` | `com.alif.atrium` |
| `CFBundleName` / `CFBundleDisplayName` | `Atrium` |
| `CFBundleExecutable` | `Atrium` |
| `CFBundlePackageType` | `APPL` |
| `CFBundleShortVersionString` | `0.1.0` |
| `CFBundleVersion` | `1` |
| `CFBundleIconFile` | `AppIcon` |
| `LSMinimumSystemVersion` | `26.0` |
| `NSPrincipalClass` | `NSApplication` |
| `NSHighResolutionCapable` | `true` |
| `LSApplicationCategoryType` | `public.app-category.productivity` |

- **No `LSUIElement`.**
- **No App Sandbox.** Controlling other apps through Accessibility is impossible when sandboxed.

### 3.4 Stable signing identity (USER STEP, once, in M0)

The Accessibility permission (TCC) is tied to the code signature. Ad-hoc signatures change on every build, so the permission would be lost after each rebuild.

The builder writes `scripts/SIGNING.md` with these steps and **asks Alif to do them**. It never touches the keychain itself.

1. Open Keychain Access and choose **Certificate Assistant ▸ Create a Certificate…**
2. Fill in the form:
   - **Name:** `Atrium Local Signing`
   - **Identity Type:** Self Signed Root
   - **Certificate Type:** Code Signing
3. Click **Create**.
4. In Keychain Access, double-click the new certificate. Under **Trust**, set **Code Signing: Always Trust**, then close the window and enter your password.
5. On the first `./scripts/build.sh` after that, macOS asks whether `codesign` may use the key. Click **Always Allow**.

**Verification:** `codesign -d -r- ~/Applications/Atrium.app` must print the **same** `designated =>` line after two rebuilds. Expect roughly `identifier "com.alif.atrium" and certificate leaf = H"…"`. Never change the bundle id, and never sign with `--deep`.

**During development:** `tccutil reset Accessibility com.alif.atrium` resets the permission. Run it only with Alif's OK.

### 3.5 App icon (no `actool`)

`scripts/make-icon.swift` is run as `swift scripts/make-icon.swift`. It:

- Draws the artwork (§7.11) into an `NSBitmapImageRep(pixelsWide:pixelsHigh:…)` at an exact pixel size. Don't use `NSImage.lockFocus`, which renders at 2× on Retina.
- Writes `Resources/AppIcon.iconset/` with exactly these files:
  - `icon_16x16.png`, `icon_16x16@2x.png`
  - `icon_32x32.png`, `icon_32x32@2x.png`
  - `icon_128x128.png`, `icon_128x128@2x.png`
  - `icon_256x256.png`, `icon_256x256@2x.png`
  - `icon_512x512.png`, `icon_512x512@2x.png`
- Runs `iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns`.

The artwork must fill the macOS rounded-square shape exactly. Otherwise Tahoe shrinks it onto a grey background ("icon jail").

---

## 4. Rules for the builder

1. **Read the whole plan before writing code.** Work milestone by milestone (§9). Don't start a milestone until the previous one meets its ✅ criteria.
2. **Git.**
   - Run `git init` in M0.
   - `.gitignore` covers `.build/`, `build/`, `Resources/AppIcon.iconset/` and `.DS_Store`.
   - **Commit after every milestone** (and at stable points within one) so you can roll back.
3. **Apple frameworks only:** SwiftUI, AppKit, ApplicationServices (AX), ServiceManagement, Observation, OSLog, Testing.
   - No third-party packages.
   - No private APIs (nothing from SkyLight, nothing `CGS*`/`_SLPS*`, no `_`-prefixed selectors).
   - No AppleScript or Apple Events.
4. **Swift 6 strict concurrency.**
   - All UI, AX and state types are `@MainActor`. Use §8's patterns as written.
   - `try await Task.sleep(for:)` is fine. Blocking the main thread is not: no `Thread.sleep`, no `usleep`, no busy-waiting.
5. **Deprecated APIs** (the build must stay warning-free). Never use:
   - `activate(ignoringOtherApps:)`
   - `.activateIgnoringOtherApps`
   - `launchApplication(…)`
   - `NSWorkspace.openApplication`'s **completion-handler** variant. Its handler runs off the main actor. Use the `async` variant.
6. **No magic numbers.** Every number lives in `Design/DesignTokens.swift`, `Design/Motion.swift` or `AtriumCore/LayoutConstants.swift`.
7. **Logging.**
   - Use `os.Logger(subsystem: "com.alif.atrium", category: …)` with the categories `switcher`, `snap`, `badges`, `layout`, `store` and `permissions`.
   - Log every activation step and snap decision at `.debug`.
   - Never use `print` in the app.
8. **Stop and hand off to Alif** for:
   - the signing certificate and keychain prompt (M0);
   - granting Accessibility;
   - visual sign-off (end of M1, and again in M8);
   - any `tccutil` command;
   - anything you cannot verify yourself. You can't screenshot the screen, so ask Alif to look.
9. **At the end of each milestone:**
   - Run `./scripts/test.sh` and `./scripts/run.sh`.
   - Post a 3–6 bullet "try this" checklist.
   - Commit.
10. **Keep it native.** SF Pro, semantic colors, standard controls and menus. No custom title bars except where §7 says.

---

## 5. Architecture

### 5.1 File layout (project root = `/Users/alif/Desktop/AI Mission Control`)

```
CLAUDE.md  ·  docs/PLAN.md  ·  Package.swift  ·  .gitignore
Resources/Info.plist, AppIcon.icns
scripts/build.sh, run.sh, test.sh, make-icon.swift, SIGNING.md
Sources/AtriumCore/          (Foundation + CoreGraphics only; no AppKit)
  LayoutConstants.swift      sidebar width, gap, item pitch (shared with UI tokens)
  ScreenLayout.swift         pure geometry + Cocoa→AX conversion
  BadgeText.swift            parse/display of Dock badge strings
  ManagedApp.swift           Codable model (custom init(from:) with decodeIfPresent)
  AppLibrary.swift           array ops (add/dedupe/remove/move) + JSON load/save to a given URL
Sources/Atrium/
  main.swift                 NSApplication bootstrap (§5.3)
  App/      AppDelegate.swift, MainMenu.swift, AppInfo.swift, LaunchOptions.swift
  Model/    AppStore.swift, Preferences.swift, IconCache.swift
  Services/ AX.swift, AXWindowObserver.swift, Launcher.swift, AppSwitcher.swift, WindowSnapper.swift,
            WorkspaceMonitor.swift, BadgeMonitor.swift, PermissionMonitor.swift, LoginItem.swift,
            InstalledAppsCatalog.swift, DisplayMonitor.swift
  Sidebar/  SidebarPanel.swift, SidebarHostingView.swift, SidebarController.swift, SidebarView.swift,
            SidebarItemView.swift, LensFill.swift, BadgeView.swift, HoverLabelPanel.swift, HoverState.swift
  Windows/  HostingWindowController.swift, SettingsWindowController.swift,
            OnboardingWindowController.swift, AddAppsWindowController.swift
  Settings/ GeneralSettingsView.swift, AppsSettingsView.swift, AboutView.swift
  Onboarding/OnboardingView.swift
  Picker/   AddAppsView.swift
  Design/   DesignTokens.swift, Motion.swift
Tests/AtriumCoreTests/ ScreenLayoutTests.swift, BadgeTextTests.swift, AppLibraryTests.swift
```

### 5.2 Data

```swift
public struct ManagedApp: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var bundleIdentifier: String   // unique key
    public var displayName: String        // refreshed from the bundle at launch
    public var lastKnownPath: String      // fallback when the bundle id can't be resolved
    public var snapWindow: Bool = true    // per-app opt-out
    public var openAtLogin: Bool = false  // launched hidden when Atrium starts
    // Custom init(from:) using decodeIfPresent for snapWindow/openAtLogin (synthesized Codable ignores defaults).
}
```

**Storage.** JSON at `~/Library/Application Support/Atrium/apps.json`.
- Create the folder with `withIntermediateDirectories: true`.
- Save atomically on every change.
- **If the JSON is corrupt,** rename it to `apps.corrupt-<timestamp>.json`, log it and start empty.

**Resolving an app's location.**
1. `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`
2. otherwise `lastKnownPath`, if it exists
3. otherwise the app is **missing** (B11).

**`Preferences`** is a `@MainActor @Observable final class`, not `@AppStorage`, because services must react to changes.
- Each property's `didSet` writes to `UserDefaults.standard`.
- Layout-affecting properties also call `@ObservationIgnored var onLayoutChange: (() -> Void)?`.

| Property | Type | Default | UI in v1? |
|---|---|---|---|
| `sidebarEdge` | `.left / .right` | `.left` | No. Testable with `defaults write com.alif.atrium sidebarEdge right` |
| `snapOnSwitch` | Bool | `true` | Yes |
| `showBadges` | Bool | `true` | Yes |
| `restoreLastApp` | Bool | `true` | Yes |
| `lastActiveBundleID` | String? | nil | No |
| `hasCompletedOnboarding` | Bool | `false` | No |

`LaunchOptions` reads `CommandLine.arguments`:
- `--demo`: in-memory store with 7 sample items built from **real installed apps** (they show real icons). Fake running, active and badge states. **Never** writes `apps.json` or registers a login item.
- `--lens-fill-only`: turns off the lens "lift" so Alif can compare it with the default (§7.5).
- `--appkit-glass`: the sidebar background uses `NSGlassEffectView` instead of SwiftUI `.glassEffect` (§7.3).

### 5.3 Lifecycle and composition (AppKit lifecycle, no SwiftUI `App`)

**`main.swift`** (top-level code is `@MainActor` in Swift 6):

```swift
import AppKit
let app = NSApplication.shared
let delegate = AppDelegate()      // global → strongly retained (NSApp.delegate is weak)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
```

**`AppDelegate.applicationDidFinishLaunching`** builds everything in this order, passing dependencies through `init`:

1. `NSApp.mainMenu = MainMenu.build()`.
2. `AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)`. Setting it on the system-wide element makes it **global** for our process (per the header). The Dock reader also sets 0.25 s on the Dock's app element.
3. `prefs = Preferences()`, then `store = AppStore(library:)` (the in-memory library under `--demo`).
4. `permissions = PermissionMonitor(store:)`, `sidebar = SidebarController(store:prefs:actions:)` and `snapper = WindowSnapper(store:)`.
5. `dockItems = DockItems()`, the one shared instance (§8.3). Then:
   - `switcher = AppSwitcher(store:prefs:sidebar:snapper:dockItems:)`
   - `workspace = WorkspaceMonitor(store:prefs:switcher:sidebar:dockItems:)`
   - `badges = BadgeMonitor(store:prefs:dockItems:)`
   - `displays = DisplayMonitor(sidebar:switcher:)`
6. `sidebar.show()`. Then show onboarding if `!prefs.hasCompletedOnboarding`. Otherwise run the startup restore (B9).

**`MainMenu.build()`** contains:

| Menu | Items |
|---|---|
| App | About Atrium · Settings… ⌘, · — · Hide Atrium ⌘H · Hide Others ⌥⌘H · Show All · — · Quit Atrium ⌘Q |
| Edit | Undo ⌘Z · Redo ⇧⌘Z · — · Cut · Copy · Paste · Select All. **Required**, or ⌘V won't work in the search field. |
| Window | Minimize ⌘M · Zoom · — · Close ⌘W |

**Windows** (Onboarding, Add Apps, Settings) each use an `NSWindowController` whose content is an `NSHostingController(rootView: view.environment(store).environment(prefs))`.
- Set `isReleasedWhenClosed = false` and `isRestorable = false`.
- `HostingWindowController` is a small generic helper.
- To open a window: `NSApp.activate()`, then `showWindow(nil)`, then `window.makeKeyAndOrderFront(nil)`.

**Settings** is an `NSTabViewController` with `tabStyle = .toolbar`, giving native preference-style toolbar tabs.
- It has three `NSTabViewItem`s with SF Symbol images (`gearshape`, `square.grid.2x2`, `info.circle`). Each wraps an `NSHostingController` with `sizingOptions = .preferredContentSize`, so the window resizes per tab.
- Set `canPropagateSelectedChildViewControllerTitle = true`, so the window title follows the selected pane.
- **Remember the last pane.** Save `selectedTabViewItemIndex` in UserDefaults and restore it when the window opens.
- **Window style:** `[.titled, .closable]` only. Minimize and zoom stay disabled, per the HIG for Settings windows. Changes apply immediately; there is no Save button.

**Sidebar hosting.** `SidebarController` owns a `SidebarPanel` whose `contentView` is `SidebarHostingView(rootView: SidebarRoot(store:prefs:hover:actions:))`.
- `SidebarRoot` is a named `View` struct, so the hosting view's generic type stays simple.
- `actions` is a small struct of closures: `switchTo(id)`, `showAddApps()`, `showSettings()`, `hide(id)`, `quit(id)`, `remove(id)`, `revealInFinder(id)`, `toggleSnap(id)`, `toggleOpenAtLogin(id)` and `relocate(id)`.

### 5.4 State: `@MainActor @Observable final class AppStore`

- `apps: [ManagedApp]`. Mutations go through `AtriumCore.AppLibrary` and then save.
- `runningBundleIDs: Set<String>`
- `activeBundleID: String?`: the frontmost app, if it's managed.
- `launchingBundleIDs: Set<String>`
- `badges: [String: BadgeText]`, keyed by bundle id.
- `isAXTrusted: Bool`
- `snappedPIDs: Set<pid_t>`: apps Atrium has already snapped this session (B4). Cleared when the app terminates.
- `func resolvedURL(for:) -> URL?` and `func isMissing(_:) -> Bool`.

---

## 6. Behaviors

**B1 — Sidebar panel (`SidebarPanel: NSPanel`, code in §8.4)**

- **Window setup:**
  - Style mask `[.borderless, .nonactivatingPanel]`: clicks never activate Atrium and never steal focus, so there's no menu-bar flicker.
  - `level = .normal`, `isFloatingPanel = false` and `hidesOnDeactivate = false` (the user's layering choice).
  - `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`.
  - `canBecomeKey = false` and `canBecomeMain = false`.
  - `isOpaque = false`, `backgroundColor = .clear` and `hasShadow = false`, because the glass draws its own edge.
- **Panel frame:** the full **strip** `(visible.minX, visible.minY, 2*gap + sidebarWidth, visible.height)`. The glass is inset by `gap` (8pt) inside it, so the transparent margin is exactly the gap and never overlaps a snapped window.
- **First click:** `SidebarHostingView` overrides `acceptsFirstMouse → true`, so the first click works even though the panel is never key. Set `sizingOptions = []` so SwiftUI never resizes the panel.
- **Hover:**
  - `SidebarHostingView` installs one `NSTrackingArea` with `[.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]`. SwiftUI `.onHover` is unreliable while Atrium is inactive, which is almost always.
  - It converts the mouse location to a top-left-origin point in the sidebar and writes it to `HoverState.point: CGPoint?`, an `@Observable`.
  - `SidebarView` derives the hovered item from that point:
    - `hoveredIndex = Int((y - (gap + sidebarPadding)) / itemPitch)`, the same constants as the layout;
    - valid only when `x` lies inside the glass and `0 ≤ index < apps.count`.
  - The + and gear buttons get their hover from their own frames, using the same point.
- **Bringing it forward:** `orderFrontRegardless()` is called **only** from the `didActivateApplication` handler for a managed app (B4). Before ordering front, if `NSApp.isHidden` (e.g. after another app's "Hide Others"), call `NSApp.unhideWithoutActivation()`.
- **Background clicks:** clicking empty glass (not an icon) brings the last active managed app forward (`switcher.bringWorkspaceForward()`).
- **No `ScrollView`.** When the items don't fit, shrink them: `scale = clamp((available - fixedChrome) / (count * itemPitch), 0.75, 1.0)` applied to `itemSize`, `iconSize` and `itemPitch` (like the Dock). Hover math uses the scaled pitch.

**B2 — Geometry (`AtriumCore.ScreenLayout`; pure and unit-tested)**

`ScreenLayout.compute(visibleFrame:edge:gap:sidebarWidth:) -> (panel: CGRect, glass: CGRect, workspace: CGRect)`, all in Cocoa coordinates. For the **left** edge (mirror for the right):

- `panel = (v.minX, v.minY, 2*gap + sidebarWidth, v.height)`
- `glass = panel.insetBy(dx: gap, dy: gap)`
- `workspace = (panel.maxX, v.minY + gap, v.maxX - gap - panel.maxX, v.height - 2*gap)`

`ScreenLayout.axRect(fromCocoa r: CGRect, primaryScreenFrame p: CGRect) -> CGRect` returns `CGRect(x: r.minX, y: p.maxY - r.maxY, width: r.width, height: r.height)`, where `p = NSScreen.screens[0].frame`.

**Display.** Always the **primary display**, `NSScreen.screens[0]`.

**`DisplayMonitor` recomputes** on:
- `NSApplication.didChangeScreenParametersNotification`, debounced **300 ms** and ignored while `NSScreen.screens.isEmpty`;
- `NSWorkspace.didWakeNotification`;
- `prefs.onLayoutChange`.

**After a recompute,** it moves the panel. If the frontmost app is managed and has `snapWindow` on, it re-snaps it with `force: true`.

**Never cache frames.** Compute them fresh for every snap.

**B3 — Switching (`AppSwitcher.switchTo(_ id:)`, from a sidebar click)**

1. Cancel any in-flight switch or snap task, together with its observer.
2. Set `store.activeBundleID = id` right away so the lens starts moving on this frame. If the app isn't running, add it to `launchingBundleIDs`.
3. Run the activation chain. Log which step succeeded.

   **Background:** since macOS 14, `NSRunningApplication.activate()` from an app that isn't active is only a *request*, and it often fails. A click in our non-activating panel does **not** make Atrium active. Apple's cooperative-activation doc says `NSWorkspace` "automatically handles this for you when opening URLs or applications". So:

   - **a.** `try await Launcher.open(url, activate: true)`. This one call covers launch, reopen and activate. For a running app, Launch Services sends the "reopen" (`rapp`) event, which makes Electron apps (Slack, Claude, Notion, Grok Bot) recreate a closed main window. It needs no Automation permission.
   - **b.** If `store.isAXTrusted`, once the window is known (step 4), perform `kAXRaiseAction` on it and set `kAXMainAttribute = true`.
   - **c.** After 200 ms, if `NSWorkspace.shared.frontmostApplication?.processIdentifier != pid` and AX is trusted, **press the app's Dock tile through AX**: `AXUIElementPerformAction(dockItem, kAXPressAction)` (§8.3). That's a real Dock click, so it launches, activates and reopens. Running apps always have a Dock tile.
   - **d.** If it's still not frontmost: log `activation-failed` and stop. **No private APIs** (the SkyLight `_SLPSSetFrontProcessWithOptions` trick is out of scope).
   - If **a** throws: clear `launching`, mark the app missing if its URL no longer exists, and log. **No alert.**

   **Spike first (start of M3).** Verify step (a) alone from the non-activating panel with Slack, Claude and Outlook, and log the result. A quick manual check: `sleep 3; open -a Slack` in Terminal, then click another app during the sleep.
4. **Snap** if `prefs.snapOnSwitch && app.snapWindow && store.isAXTrusted`: `await snapper.snap(app:, force: true)`.
5. Save `prefs.lastActiveBundleID`.
6. **Reconcile.** After 1 s, set `store.activeBundleID` to whatever app is really frontmost, if it's managed. This fixes any optimistic UI that turned out wrong.
7. **When Atrium itself is active** (B10, or a window of ours just closed): call `NSApp.yieldActivation(to: runningApp)` before step 3a.

`removeFromLaunching(id)` runs on `didLaunchApplication`, or after 10 s.

**`WindowSnapper.snap(app:force:)`**

- **Wait for launch first:** don't query AX until `NSRunningApplication.isFinishedLaunching` is true. Poll 100 ms or observe the property.
- **Pick the window** (`AX.primaryWindow`, §8.1):
  - **Candidates:** `kAXMainWindowAttribute`, `kAXFocusedWindowAttribute` and `kAXWindowsAttribute`, deduplicated with `CFEqual`. `kAXWindowsAttribute` is **filtered to the current Space**; main and focused aren't.
  - **Filter:** keep windows with role `AXWindow` and subrole `AXStandardWindow`.
  - **Choose:** the **largest-area** one that isn't minimized. If all are minimized, take the first and set `AXMinimized = false`.
  - This skips Outlook compose windows, call windows, dialogs and the like.
- **No window yet** (launching, or the reopen hasn't finished):
  - Create an `AXWindowObserver` for `kAXWindowCreatedNotification`, `kAXMainWindowChangedNotification` and `kAXFocusedWindowChangedNotification`.
    - Early in a launch, `AXObserverAddNotification` can return `.cannotComplete`. If **no** notification registered, retry creating the observer on the next poll tick.
  - **Also** poll every 250 ms as a backstop.
  - **Timeouts:** **20 s** for a cold launch, **5 s** for a running app. At that timeout, if AX is trusted, press the Dock tile (B3 c) **once** and wait 5 s more.
  - Then give up silently, with a log.
  - Always `invalidate()` the observer when done.
- **Electron settle:** Electron apps restore their saved bounds asynchronously after showing a window. After the first frame write, re-check the frame at **+300 ms and +1 s** and re-apply if it differs by more than 1pt. At most 2 re-applies, and only within this snap.
- **Skip the snap** if:
  - `AXFullScreen == true`, or
  - the window is already within 1pt of the target frame, or
  - `!force` and the app's pid is in `store.snappedPIDs`.
- **Apply:** `AX.setFrame(window, app:, to: axTarget)` (§8.1). Then insert the pid into `snappedPIDs`.
- Accept whatever frame the app ends up with (minimum and maximum sizes). Apart from the bounded Electron-settle re-applies, **never retry and never enforce continuously.** Users may move windows away.

**B4 — Live state (`WorkspaceMonitor`)**

- **Observers.** Use `NSWorkspace.shared.notificationCenter` observers with `queue: .main`. Inside each closure:
  - extract `let runningApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication` **first**;
  - then call `MainActor.assumeIsolated { … }`.
- **Seed** from `runningApplications` and `frontmostApplication`.

| Event | Action |
|---|---|
| `didLaunchApplication` | Insert the app into `runningBundleIDs`; remove it from `launchingBundleIDs`. |
| `didTerminateApplication` | Remove the app from `runningBundleIDs`; remove its pid from `snappedPIDs`; clear its badge. |
| `didActivateApplication` → **managed** app (from any source: sidebar, ⌘-Tab, Dock, clicking its window) | Set `activeBundleID`. Unhide Atrium if hidden, then `sidebar.orderFront()`. If `snapOnSwitch && snapWindow && pid ∉ snappedPIDs` **and `switcher.inFlightBundleID != id`**, snap with `force: false`. The in-flight check stops a sidebar-initiated switch from snapping twice. Save `lastActiveBundleID`. |
| `didActivateApplication` → **non-managed** app | `activeBundleID = nil`, and the lens fades out. Nothing else; the other app's windows simply cover the sidebar. |
| `didActivateApplication` → **Atrium** | Leave `activeBundleID` unchanged. |

**B5 — Badges (`BadgeMonitor`)**

- **Polling loop:** `Task { @MainActor in while !Task.isCancelled { …; try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(500)) } }`.
  - It only does work while `store.isAXTrusted && prefs.showBadges && !store.runningBundleIDs.isEmpty`.
  - Otherwise it sleeps 5 s.
- **Reading:** through `DockItems` (§8.3), a shared instance also used by B3 step (c).
  - It caches the Dock tile elements and rebuilds them when the Dock relaunches, on `.invalidUIElement`, or when an app launches or quits.
  - Dock items carry `kAXURLAttribute`, which may end in a trailing slash. Map each one to a bundle id with a cached `Bundle(url:)` lookup.
- **Parsing** with `AtriumCore.BadgeText.parse(_:)`:
  - empty or whitespace → `nil`
  - an integer (after trimming; `Int(s)`) → `.count(n)`, where `n ≤ 0` → nil
  - `"."`, `"•"`, `"●"`, `"·"` or `"∙"` → `.dot`
  - any other text of 3 characters or fewer → `.text(s)`, shown as-is
  - longer text (e.g. "unread") → `.dot`
  - `.count(n).display` gives `"99+"` when n > 99.
- **Publishing:** write to `store.badges` **only when it changes**.

**B6 — Accessibility permission and onboarding**

- **Polling.** `PermissionMonitor` polls `AXIsProcessTrusted()` every **0.5 s** while Onboarding or Settings is open, and every **5 s** otherwise. It also polls on `NSApplication.didBecomeActiveNotification`.
- **Confirm before reporting success.** `AXIsProcessTrusted()` can return true while AX calls still fail. Before setting `store.isAXTrusted = true`, confirm with one real AX read: the Dock app element's `kAXChildrenAttribute` must succeed.
- **Without permission** Atrium still switches apps (B3 a). Only snapping, badges and the Dock-tile fallback turn off. An amber dot on the gear and a row in Settings explain why.
- **Onboarding window:** 600×520, transparent titlebar, `.fullSizeContentView`, no title. **Titles are left-aligned**, matching Tahoe's onboarding style. Steps:
  1. **Welcome.** App icon (96pt), "Welcome to Atrium", "All your apps, one calm place." and a **Continue** button.
  2. **Permission.**
     - Text: "Atrium needs Accessibility access to place your apps' windows beside the sidebar and show their unread counts. It never reads what you type or what's on your screen, and nothing leaves your Mac."
     - Button **Open Accessibility Settings**: call `AX.isTrusted(prompt: true)` once, then open `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
     - A live status row: "Waiting for access…" with a small spinner, then "Access granted" with a green `checkmark.circle.fill`, which plays `.symbolEffect(.bounce)`.
     - Once access is granted: `NSApp.activate()`, bring this window to front, and auto-advance after 0.6 s.
     - Secondary link: "Continue Without Window Control" (snapping and badges stay off).
  3. **Add your apps.** The `AddAppsView` content, embedded. Suggested apps are pre-checked.
  4. **Done.** "You're all set." A **visible** toggle, "Open Atrium at login" (on, using `LoginItem`; never enabled silently), and a **Start** button that closes the window, sets `hasCompletedOnboarding` and calls `bringWorkspaceForward()`.

**B7 — Add, remove, reorder**

**Add Apps window** (600×560, transparent titlebar; also embedded in onboarding step 3):

- **Search field.** An in-content field: a `TextField` with `magnifyingglass` in a rounded field, focused on open with `@FocusState`. Don't use `.searchable`, which needs a toolbar.
- **Sections:**
  - **Suggested:** installed apps whose bundle id is in `[com.tinyspeck.slackmacgap, com.anthropic.claudefordesktop, notion.id, com.anysphere.sand, com.microsoft.Outlook, com.meta.endo]`.
  - **Safari Web Apps:** every `com.apple.Safari.WebApp.*`. When there are none, a tip: "Use a web app like Gmail? In Safari choose File ▸ Add to Dock…, then it appears here."
  - **All Apps.**
- **Catalog** (`InstalledAppsCatalog`):
  - Scans `/Applications`, `/Applications/Utilities`, `/System/Applications`, `/System/Applications/Utilities` and `~/Applications`, recursing into non-`.app` subfolders only.
  - Runs in a `Task.detached`.
  - Returns `Sendable` structs `{bundleID, name, path}`.
  - Excludes Atrium itself and dedupes by bundle id.
  - Icons load lazily through `IconCache` (an `NSCache` keyed by path, `NSWorkspace.shared.icon(forFile:)`).
- **Tiles:** clicking toggles membership; added apps show a checkmark.
- **Footer:** **Choose Other…** opens an `NSOpenPanel` with `allowedContentTypes = [.application]`. **Done** closes the window.

**Remove:** sidebar context menu ▸ Remove from Sidebar; Settings ▸ Apps ▸ "−".

**Reorder (v1):** the Settings ▸ Apps `List { ForEach … .onMove }` (built in M2). Drag-to-reorder **inside the sidebar** is an optional stretch goal (M8), time-boxed to one attempt.

**B8 — Menus** (follow the HIG: most-used items first, at most 3 groups, *hide* items that don't apply instead of dimming them, and **no symbols** in the per-app menu, because mixing symbol and non-symbol rows breaks alignment)

**Per-app context menu** (SwiftUI `.contextMenu` on each item):
- **Open**, only when the app isn't running.
- divider
- **Snap Window When Opened** ✓, **Open at Login** ✓, **Show in Finder** and **Remove from Sidebar** (`role: .destructive`).
- divider
- **Hide** and **Quit**, only when the app is running.

**Missing-app menu.** For a missing app, the menu becomes **Locate…** (an `NSOpenPanel` that updates `lastKnownPath`) and **Remove from Sidebar**. Left-clicking a missing app opens the same menu.

**Rail background context menu** (right-click on empty glass): **Add App…** and **Settings…**

**Dock menu** (`applicationDockMenu(_:)`): **Show Sidebar** (calls `bringWorkspaceForward()`) and **Add App…**

**Window menu.** Add **Show Sidebar**. Set the panel's `isExcludedFromWindowsMenu = true`.

**B9 — Launch at login and startup restore**

- **Login item:** `LoginItem` wraps `SMAppService.mainApp`.
  - Show the live `status`.
  - `.requiresApproval` → a note plus a button that calls `SMAppService.openSystemSettingsLoginItems()`.
  - `.notFound` → a note: "Move Atrium to Applications" (it's always in `~/Applications`, so this should never happen).
  - **Never register in `--demo` mode.**
  - Register only when the user flips the toggle. **Don't re-register on every launch**, because that overrides the user's choice in System Settings.
  - If `register()` throws (e.g. a self-signed signature is rejected): show "Couldn't add Atrium automatically. Add it in System Settings ▸ General ▸ Login Items." with a button that calls `openSystemSettingsLoginItems()`.
  - Debug with `sfltool dumpbtm | grep -i atrium`. **Never** run `sfltool resetbtm`, which resets every app's login items.
- **Startup sequence:**
  1. Show the sidebar.
  2. Launch every `openAtLogin` app that isn't running, using `Launcher.open(url, activate: false, hide: true)`.
  3. If `restoreLastApp` and `lastActiveBundleID` is set, wait 1.5 s, then `switchTo(lastActiveBundleID)`. The startup restore always wins over B10.

**B10 — Atrium as "one app"**

- **`bringWorkspaceForward()`:**
  1. `sidebar.orderFront()`.
  2. If the last active managed app exists, `switchTo(it)`. B3 step 7 yields activation first.
- **`applicationShouldHandleReopen`** (Dock icon click): call `bringWorkspaceForward()` and return `false`.
- **`applicationDidBecomeActive`:** call `bringWorkspaceForward()` only if no Atrium window (Settings, Add Apps, Onboarding) is visible **and** more than 2 s have passed since launch.
- **When an Atrium window closes** and no other Atrium window is visible: call `bringWorkspaceForward()`.
- `applicationShouldTerminateAfterLastWindowClosed` → `false`.

**B11 — Edge cases**

| Case | Behavior |
|---|---|
| App uninstalled or moved | Re-resolve by bundle id. Still missing: icon at 40% with a `questionmark.circle.fill` overlay, and the B8 missing-app menu. |
| Native full screen | Activate only; don't snap. |
| No window before the timeout (menu-bar-only state) | Activate only; no error UI. |
| App enforces a minimum or maximum size | Accept the result. |
| Display plugged in or unplugged; Dock moved or resized | B2 recompute; the front managed app re-snaps. |
| App hung | The global 1 s AX timeout keeps Atrium responsive; skip the snap. |
| Same app added twice | Prevented (bundle id is unique). |
| Another app's "Hide Others" hid Atrium | `unhideWithoutActivation()` when a managed app activates (B1). |
| Stage Manager on | Unsupported. Settings footnote: "Atrium works best with Stage Manager off." |
| Edge/Chrome PWA added anyway | Activation works; snapping silently finds no window (logged). |

---

## 7. Design spec

**7.1 Principles**

- **Content first, quiet chrome.** The apps are the content; Atrium is the frame.
- **One glass surface:** the sidebar. Glass can't sample other glass, so nothing else glassy is stacked on it (the lens is drawn *on* it; §7.5).
- **System only:** SF Pro, semantic colors (`labelColor`, `secondaryLabelColor`, `separatorColor`, `controlAccentColor`), SF Symbols. Never hardcode black or white text.
- **Responsive and accessible:** every click gives feedback within one frame. Motion is quick, physical and interruptible. Everything respects Reduce Motion, Reduce Transparency and Increase Contrast. Dark and light mode are automatic.

**7.2 Tokens** (`Design/DesignTokens.swift`; the geometry ones mirror `AtriumCore/LayoutConstants`; all in points)

macOS app icons draw their visible squircle at about 80% of the image frame (an 824 body on a 1024 canvas). So size everything from the squircle.

| Token | Value | Notes |
|---|---|---|
| `sidebarWidth` | 64 | `itemSize` 44 + 2 × `sidebarPadding` 10 |
| `sidebarCornerRadius` | 24 | Continuous. Sits just under Tahoe's ~26pt window radius, so the rail and the snapped window read as one unit. |
| `sidebarPadding` | 10 | Glass edge ↔ tile; also top and bottom |
| `gap` | 8 | Screen edge ↔ glass ↔ snapped window; top and bottom |
| `itemSize` | 44 | Tile = hit target = lens size |
| `itemSpacing` | 4 | `itemPitch` = 48 |
| `iconSize` | 40 | Image frame; the visible squircle ≈ 32. `.interpolation(.high)`. |
| `lensCornerRadius` | 14 | Concentric: 24 − 10. A continuous rounded rect that echoes the app-icon squircle. |
| `runningDotSize` | 4 | Centre 4pt from the glass's screen-side edge, vertically centred on the item |
| `badgeHeight` | 16 | Capsule, min width 16, horizontal padding 4.5; dot badge = 8pt circle |
| `badgeCenter` | squircle top-right inset 2 | Badge **centre** = (iconFrame.maxX − 6, iconFrame.minY + 6), i.e. 2pt inside the visible squircle's corner. Never clips: the max right extent is 59 of 64. |
| `utilityButtonSize` | 28 | The + and gear buttons: 28×28 with a 13pt `.medium` symbol, centred in the rail |
| `hoverLabelHeight` | 26 | Padding 10×5, 13pt medium; 10pt from the glass edge |
| `hairline` | 1 device px | `separatorColor`, inset 14pt each side, 8pt space above and below |

**7.3 Sidebar anatomy (top → bottom, inside the glass)**

- `sidebarPadding`.
- App items (B1 scale-to-fit).
- The **+** button (`plus`), right after the last app.
- A flexible spacer.
- A hairline divider (`hairline` token).
- The **gear** (`gearshape`). It shows a 6pt `systemOrange` dot at its top-trailing corner while Accessibility is off.
- `sidebarPadding`.

**Glass:**
- The whole column is one `.glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))`.
- Don't use `.interactive()`, because it would make the whole bar bounce on every click.
- No borders. Under Increase Contrast only, add a hairline `separatorColor` stroke.
- The + and gear buttons use `PressScaleStyle` (§8.5). They're `.secondary` at rest and `.primary` with a hover plate on hover. No glass buttons inside the glass.

**Known risk (test in M1).** Glass in a **non-key window of an inactive app** renders a flatter "inactive" look, and Atrium is almost always inactive. The builder tries these in order and **Alif picks by eye**:
- **(a)** plain `.glassEffect`;
- **(b)** (a) plus `.environment(\.appearsActive, true)` on the root;
- **(c)** `--appkit-glass`: an `NSGlassEffectView` (`cornerRadius = 24`, style `.regular`) as the panel's content view, with the hosting view as its `contentView`.

Keep the winner and delete the losers' code paths after sign-off. Glass can't be captured by `ImageRenderer` or headless screenshots; only Alif's eyes on the real screen count.

**7.4 Item states**

| State | Visual |
|---|---|
| Not running | Icon at full opacity, no dot. **Never dim** non-running apps; the Dock doesn't, and dimming reads as "disabled". |
| Running | 4pt dot in vibrant `Color.primary.opacity(0.6)`. Never hard-coded black, which disappears on dark glass. |
| Active (frontmost) | **Lens** behind the icon (§7.5); the dot stays |
| Hover | A neutral **hover plate**: the same shape as the lens, `Color.primary.opacity(0.08)`, fading in with `Motion.hoverIn` and out with `Motion.hoverOut`. Not drawn on the active item. **No icon scaling.** Plus the hover label (§7.6). |
| Pressed | Scale 0.94 and brightness −0.2 (`Motion.press`) |
| Launching | The **dot** pulses opacity 0.35 ↔ 1.0 (0.6 s cycle) until `didLaunchApplication`. Never a spinner. |
| Missing | Icon opacity 0.4, with a 12pt `questionmark.circle.fill` (secondary) at bottom-trailing |

**7.5 The lens (signature element): "rests as a fill, lifts into glass while it moves"**

Apple's guidance (WWDC25 session 219) is to avoid glass on glass *at rest*, and that elements can "lift up into Liquid Glass temporarily" during interaction. The iOS 26 tab-bar selection works this way. Atrium's lens does the same.

- **One persistent lens view.** It lives in the item stack's `.background(alignment: .top)` and is positioned with `.offset(y: activeIndex * itemPitch)`.
  - Don't create one lens per item, and don't use `matchedGeometryEffect`.
  - It glides; it never crossfades between items.
- **At rest: `LensFill`** (§8.5). A 44×44 continuous rounded rect, radius 14:
  - fill `Color.primary.opacity(dark ? 0.14 : 0.10)`, or 0.20 under Increase Contrast;
  - a 0.5pt top-lit rim: `strokeBorder(LinearGradient([.white.opacity(0.35), .white.opacity(0)], .top → .bottom))`;
  - no shadow. It reads as a softly raised, glassy plate *on* the glass.
- **On switch: the lift.** When `activeIndex` changes from one item to another:
  1. Set `isLifted = true`. The fill crossfades to the **lifted lens** over 0.1 s: the same rect with `.glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))`, drawn in an `.overlay` above the sidebar with `.allowsHitTesting(false)`, at the same offset.
  2. The offset animates with `Motion.lensSlide`. Meanwhile, a `keyframeAnimator(initialValue: 1.0, trigger: activeIndex)` scales the lens 1.0 → 1.08 (first 40%) → 1.0 (`Motion.lensLift` feel).
  3. When the slide completes (use `withAnimation(_:completionCriteria: .logicallyComplete) { … } completion: { … }`), set `isLifted = false`. The glass crossfades back to the fill over 0.15 s.
- **First activation or fading:**
  - From "no active app" → active: the lens fades in at its spot (`Motion.fade`), with no lift.
  - When no managed app is frontmost: it fades out in place.
- **Reduce Motion:** no lift, no slide and no scale. Fade out at the old spot and fade in at the new one (0.15 s).
- **Reduce Transparency:** the fill only, using `Color(nsColor: .quaternarySystemFill)`. Never lift.
- **M1 visual check:** if the lift looks muddy on Alif's screen, ship the fill-only lens. That's the HIG-sanctioned fallback. **Alif decides.**

**7.6 Hover label** (like Dock labels)

- **A standalone `HoverLabelPanel`:**
  - borderless, `.nonactivatingPanel`, `level = .floating`, `ignoresMouseEvents = true`, `hasShadow = false`, clear background;
  - **not** a child window, because the active app's window would cover it.
- **Content:** the app name in 13pt `.medium`, `.primary`, inside `.glassEffect(.regular, in: .capsule)`. It's a separate surface, so this isn't glass on glass.
- **Position:** vertically centred on the hovered item, with its leading edge 10pt beyond the glass's inner edge. Size it from the hosting view's `fittingSize`.
- **Timing:** appears **immediately** on hover, like Dock labels, not after the slower system tooltip delay. Moving between items moves the label with no fade-out between them.
  - Appear: opacity 0→1 and x offset −4→0 (`Motion.label`).
  - Hide 0.15 s after the pointer leaves the rail (prevents flicker), with a 0.12 s fade.
  - `orderFrontRegardless()` when shown, `orderOut` when hidden.
- **Hidden** while the mouse button is down and during switching.

**7.7 Badges**

Badges only mirror **real** Dock badges. HIG says never to invent badges.

- **Shape:** a `Color(nsColor: .systemRed)` capsule. Height 16, min width 16, horizontal padding 4.5.
- **Text:** white, `.system(size: 11, weight: .semibold).monospacedDigit()`, SF Pro (not Rounded, to match the Dock).
- **Shadow:** black 20%, radius 1, y 0.5.
- **Display rules** (`BadgeText.display`):
  - 1–99 → the number;
  - over 99 → `"99+"`;
  - a non-numeric marker of 3 characters or fewer → shown as-is, except `"•"`, which becomes the **8pt dot** badge;
  - anything longer → the dot.
- **Motion:**
  - Appear: scale 0.5→1 plus opacity with `Motion.badgeIn`.
  - Count change: `.contentTransition(.numericText(value:))` with `Motion.badgeCount`. When the count **increases**, a 1.15× pop.
  - Disappear: `Motion.badgeOut`.
- **Never** shift layout. Badges are overlays.

**7.8 Motion (`Design/Motion.swift`)**

Anchors from Apple:
- Bounce 0.15 is "barely bouncy". Above 0.4 looks exaggerated.
- Keep motion minimal on frequent interactions, and keep it interruptible.
- SwiftUI springs keep their velocity when interrupted.

| Name | Animation | Use |
|---|---|---|
| `lensSlide` | `.snappy(duration: 0.32)` | Lens glide between items |
| `lensLift` | `.bouncy(duration: 0.4, extraBounce: -0.1)` | Lift scale 1.0→1.08→1.0 (keyframes) |
| `hoverIn` / `hoverOut` | `.easeOut(duration: 0.12)` / `.easeIn(duration: 0.10)` | Hover plate |
| `label` | `.smooth(duration: 0.18)` | Hover label appear and move |
| `press` | `.snappy(duration: 0.18)` | Press-down and release |
| `badgeIn` | `.bouncy(duration: 0.35)` | Badge appear |
| `badgeCount` | `.snappy(duration: 0.25)` | Count change |
| `badgeOut` | `.smooth(duration: 0.2)` | Badge disappear |
| `fade` | `.easeOut(duration: 0.2)` | Lens fade in and out |
| `page` | `.smooth(duration: 0.35)` | Onboarding step changes |

`Motion.resolve(_:reduceMotion:)` returns `.easeInOut(duration: 0.15)` when Reduce Motion is on. Under Reduce Motion, callers also swap scale and offset changes for opacity.

**No sound.** **Haptics** (`.alignment`) only during drag-reorder, if it's ever built. Never on hover or click.

**7.9 Atrium's own windows**

**Settings** (toolbar tabs, §5.3). Each tab is `Form { Section { … } }.formStyle(.grouped)`, 520pt wide.

- **General:**
  - *Startup:* "Open Atrium at login" (LoginItem, with status notes); "Reopen last app on launch".
  - *Windows:* "Snap windows beside the sidebar"; "Show unread badges".
  - *Permissions:* "Accessibility" with a trailing status: green `checkmark.circle.fill` "On", or orange "Off" plus an **Open System Settings…** button.
  - *Footnote* (`.footnote`, secondary): "Atrium works best with Stage Manager off."
- **Apps:**
  - A `List` with `.onMove`. Rows: a 28pt icon, the name (13 medium) and the path (11 secondary, middle truncation).
  - Each row has a trailing `Menu` (`ellipsis.circle`, borderless) with Snap Window ✓, Open at Login ✓ and Remove.
  - Below the list: **+** (opens Add Apps) and **−** (removes the selection) as borderless buttons.
- **About:** the 128pt icon, "Atrium" (20 bold), the version (secondary) and "A calm home for your apps."

**Onboarding:**
- Title `.largeTitle.bold()` (26pt), **left-aligned**. Body `.body` (13pt), `.secondary`, at most 3 lines. Content inset 40pt.
- Primary button `.buttonStyle(.glassProminent).controlSize(.large)`. Secondary actions `.buttonStyle(.link)`.
- Steps transition with `.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity))` and `Motion.page`.

**Add Apps:**
- Grid: `LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)])`.
- Tiles are 96×104: a 56pt icon and an 11pt name (2 lines, centred).
- Hover: a `Color.primary.opacity(0.05)` plate, radius 12, continuous corners.
- Added: an accent plate (`.tint.opacity(0.12)`) plus an accent `checkmark.circle.fill` (16pt) at the icon's top-trailing corner.
- Browser PWA: an ⓘ badge with `.help("For best results, create this with Safari ▸ File ▸ Add to Dock.")`.
- Section headers: `.headline`, secondary. **Done** button: `.glassProminent`.

**7.10 Accessibility and polish**

- **VoiceOver for each item:**
  - `accessibilityLabel(name)`;
  - `accessibilityValue` joining "running", "active" and "N unread";
  - `.accessibilityAddTraits(.isSelected)` when active;
  - `accessibilityAction(named: "Remove from Sidebar")`.
- **Cursor:** the arrow everywhere. No pointing hands.
- **Context menus:** right-click works on every sidebar item.
- **No spinners** before 300 ms. No layout shifts. Icons are cached, so they never pop in after first display.

**7.11 App icon art (`make-icon.swift`; 1024 px canvas)**

- **Shape:** a continuous squircle, 824×824 at (100, 100), radius ≈ 185.
- **Background:** a diagonal gradient from `#3B3FD8` (top-left) to `#8B4DFF` (bottom-right), plus a white sheen at 18% → 0% over the top 40%.
- **The motif:**
  - **Sidebar:** a frosted pill at about (190, 232, 120, 560), radius 60, white 85% → 65%, holding three rounded squares (64pt, radius 16) in the gradient colours at 35% alpha.
  - **Workspace:** a pane at about (350, 232, 484, 560), radius 44, white 22%, with a 3 px white-50% inner stroke.
- **Shadows:** black 25%, blur 24, y −12.

(Alif can replace this with an Icon Composer icon later if he installs Xcode.)

**7.12 Never do these**

- Tinted or coloured glass, `.clear` glass on the rail, or glass layers at rest (the lens is glass **only while lifted**).
- Symbols on every item of the per-app context menu.
- Turning on launch at login silently.
- A Save button in Settings.
- Borders, or drop shadows on the sidebar.
- Emoji, custom fonts, pointing-hand cursors.
- Bounces longer than 0.45 s.
- `.help()` tooltips on sidebar items. Use the hover label instead.
- Alerts for non-errors, or spinners for quick operations.
- Focus stealing when the sidebar is clicked.
- Fixed colours that break dark mode.

---

## 8. Reference code (intended implementations)

These snippets match the verified SDK signatures but **have not been compiled together**. Compile them in M0–M1 and fix small errors **without changing behaviour**.

**8.1 AX helpers (`Services/AX.swift`)**

```swift
import AppKit
@preconcurrency import ApplicationServices

@MainActor
enum AX {
    /// Literal key: the kAXTrustedCheckOptionPrompt global isn't concurrency-safe in Swift 6.
    static func isTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }
    static func app(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func string(_ el: AXUIElement, _ name: String) -> String? { attribute(el, name) as? String }
    static func bool(_ el: AXUIElement, _ name: String) -> Bool? { (attribute(el, name) as? NSNumber)?.boolValue }
    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] { (attribute(el, name) as? [AXUIElement]) ?? [] }
    @discardableResult static func set(_ el: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, name as CFString, value) == .success
    }

    static func frame(_ window: AXUIElement) -> CGRect? {
        guard let p = attribute(window, kAXPositionAttribute), let s = attribute(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attribute(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(v, to: AXUIElement.self)
    }

    /// Largest non-minimized standard window (skips compose/call/dialog windows).
    /// Main/focused first: kAXWindowsAttribute is filtered to the current Space, they aren't.
    static func primaryWindow(of app: AXUIElement) -> AXUIElement? {
        var all: [AXUIElement] = [element(app, kAXMainWindowAttribute), element(app, kAXFocusedWindowAttribute)].compactMap { $0 }
        for w in elements(app, kAXWindowsAttribute) where !all.contains(where: { CFEqual($0, w) }) { all.append(w) }
        let standard = all.filter { string($0, kAXRoleAttribute) == kAXWindowRole && string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }
        let visible = standard.filter { bool($0, kAXMinimizedAttribute) != true }
        return visible.max { area(frame($0)) < area(frame($1)) } ?? standard.first
    }
    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        set(window, kAXMainAttribute, true as CFBoolean)
    }
    private static func area(_ r: CGRect?) -> CGFloat { (r?.width ?? 0) * (r?.height ?? 0) }

    /// `frame` is in AX coordinates (top-left origin of the primary screen). Order: size → position → size.
    static func setFrame(_ window: AXUIElement, app: AXUIElement, to frame: CGRect) {
        let enhanced = bool(app, "AXEnhancedUserInterface") ?? false
        if enhanced { set(app, "AXEnhancedUserInterface", false as CFBoolean) }   // avoids animated/partial resizes
        defer { if enhanced { set(app, "AXEnhancedUserInterface", true as CFBoolean) } }
        var size = frame.size, origin = frame.origin
        guard let s = AXValueCreate(.cgSize, &size), let p = AXValueCreate(.cgPoint, &origin) else { return }
        set(window, kAXSizeAttribute, s)
        set(window, kAXPositionAttribute, p)
        set(window, kAXSizeAttribute, s)
    }
}
```

**8.2 AX observer (`Services/AXWindowObserver.swift`)**

```swift
@MainActor
final class AXWindowObserver {
    private var observer: AXObserver?
    private let appElement: AXUIElement
    private let notifications: [String]
    private let handler: @MainActor (String) -> Void

    init?(pid: pid_t, notifications: [String], handler: @escaping @MainActor (String) -> Void) {
        self.appElement = AXUIElementCreateApplication(pid)
        self.notifications = notifications
        self.handler = handler
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let name = notification as String
            let me = Unmanaged<AXWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.handler(name) }   // source is on the main run loop
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return nil }
        observer = created
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in notifications { AXObserverAddNotification(created, appElement, n as CFString, refcon) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    /// Call before releasing (refcon is unretained). Never call from inside the handler; defer with Task { @MainActor in … }.
    func invalidate() {
        guard let observer else { return }
        for n in notifications { AXObserverRemoveNotification(observer, appElement, n as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }
}
```

**8.3 Dock badge reader**

This is the same technique AltTab, DockDoor/WindowKit and OmniWM use on macOS 26. There is **no** reliable "badge changed" AX notification, so it has to poll.

```swift
@MainActor
final class DockItems {
    private var dockPID: pid_t = 0
    private var items: [String: AXUIElement] = [:]          // bundle id → Dock tile element
    private var bundleIDForURL: [URL: String] = [:]

    /// Rebuild when the Dock pid changes (Dock relaunch), on .invalidUIElement errors, and on app launch/quit.
    func refreshIfNeeded(force: Bool = false) {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { items = [:]; return }
        guard force || dock.processIdentifier != dockPID || items.isEmpty else { return }
        dockPID = dock.processIdentifier
        let dockEl = AX.app(dockPID)
        AXUIElementSetMessagingTimeout(dockEl, 0.25)
        var map: [String: AXUIElement] = [:]
        for list in AX.elements(dockEl, kAXChildrenAttribute) where AX.string(list, kAXRoleAttribute) == kAXListRole {
            for item in AX.elements(list, kAXChildrenAttribute) where AX.string(item, kAXSubroleAttribute) == "AXApplicationDockItem" {
                guard let url = (AX.attribute(item, kAXURLAttribute) as? NSURL) as URL? else { continue }   // may have a trailing slash
                let id = bundleIDForURL[url] ?? Bundle(url: url)?.bundleIdentifier
                guard let id else { continue }
                bundleIDForURL[url] = id
                map[id] = item
            }
        }
        items = map
    }

    /// Raw badge strings keyed by bundle id (only non-empty ones).
    func badges() -> [String: String] {
        refreshIfNeeded()
        var result: [String: String] = [:]
        for (id, item) in items {
            if let label = AX.string(item, "AXStatusLabel"), !label.trimmingCharacters(in: .whitespaces).isEmpty { result[id] = label }
        }
        return result
    }

    /// Real Dock click: launches/activates/reopens. Public AX, no private API.
    @discardableResult func pressTile(bundleID: String) -> Bool {
        refreshIfNeeded()
        guard let item = items[bundleID] else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }
}
```

**8.4 Launcher, panel and hosting view**

```swift
@MainActor
enum Launcher {
    /// Launches if needed; for a running app, activates it and sends "reopen" (creates a window if none).
    static func open(_ url: URL, activate: Bool = true, hide: Bool = false) async throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        config.hides = hide
        return try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}

final class SidebarPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .normal
        isFloatingPanel = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class SidebarHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((CGPoint?) -> Void)?           // top-left-origin point inside the view, nil on exit
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }
    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    private func report(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onHover?(CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y))
    }
}
// host.sizingOptions = []; panel.contentView = host
```

**8.5 Lens and press style**

```swift
/// Resting lens: a softly raised plate drawn ON the rail's glass (no glass of its own).
struct LensFill: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let shape = RoundedRectangle(cornerRadius: DesignTokens.lensCornerRadius, style: .continuous)
    var body: some View {
        if reduceTransparency {
            shape.fill(Color(nsColor: .quaternarySystemFill))
        } else {
            shape
                .fill(Color.primary.opacity(contrast == .increased ? 0.20 : (scheme == .dark ? 0.14 : 0.10)))
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                }
        }
    }
}

// In SidebarView (sketch). `store.activeIndex` = index of activeBundleID in apps, or nil.
@State private var lensIndex: Int?          // where the lens is drawn
@State private var lensVisible = false
@State private var isLifted = false
private var liftEnabled: Bool { !LaunchOptions.lensFillOnly && !reduceMotion && !reduceTransparency }

// itemsStack = VStack(spacing: DesignTokens.itemSpacing) { ForEach(store.apps) { SidebarItemView(...) } }
itemsStack
    .background(alignment: .top) {
        if let i = lensIndex {
            LensFill()
                .frame(width: DesignTokens.itemSize, height: DesignTokens.itemSize)
                .opacity(lensVisible && !isLifted ? 1 : 0)
                .offset(y: CGFloat(i) * DesignTokens.itemPitch)
        }
    }
    .overlay(alignment: .top) {
        if let i = lensIndex, liftEnabled {
            Color.clear
                .frame(width: DesignTokens.itemSize, height: DesignTokens.itemSize)
                .glassEffect(isLifted ? .regular : .identity,      // .identity = no glass; animates materialize
                             in: .rect(cornerRadius: DesignTokens.lensCornerRadius, style: .continuous))
                .keyframeAnimator(initialValue: 1.0, trigger: lensIndex) { content, scale in
                    content.scaleEffect(scale)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(1.08, duration: 0.13)
                        SpringKeyframe(1.0, duration: 0.19)
                    }
                }
                .offset(y: CGFloat(i) * DesignTokens.itemPitch)
                .allowsHitTesting(false)
        }
    }
    .onChange(of: store.activeIndex) { old, new in
        guard let new else { withAnimation(Motion.fade) { lensVisible = false }; return }
        if old == nil || lensIndex == nil || !lensVisible {            // first appearance: fade in at destination
            withTransaction(Transaction(animation: nil)) { lensIndex = new }
            withAnimation(Motion.fade) { lensVisible = true }
        } else if reduceMotion || !liftEnabled && reduceMotion {      // crossfade, no movement
            withAnimation(.easeOut(duration: 0.075)) { lensVisible = false } completion: {
                withTransaction(Transaction(animation: nil)) { lensIndex = new }
                withAnimation(.easeIn(duration: 0.075)) { lensVisible = true }
            }
        } else {
            if liftEnabled { withAnimation(.easeOut(duration: 0.1)) { isLifted = true } }
            withAnimation(Motion.lensSlide, completionCriteria: .logicallyComplete) {
                lensIndex = new
            } completion: {
                withAnimation(.easeIn(duration: 0.15)) { isLifted = false }
            }
        }
    }

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.2 : 0)
            .animation(Motion.press, value: configuration.isPressed)
    }
}
```

**8.6 Login item**

```swift
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static func setEnabled(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
```

---

## 9. Milestones

Each milestone ends with the §4 rule 9 routine: tests, run, checklist, commit.

**M0 — Foundation** *(Alif needed: certificate and keychain prompt)*

Build:
- `git init` and `.gitignore`.
- `CLAUDE.md` and `docs/PLAN.md` (§11).
- `Package.swift` with all three targets, and the scripts.
- `Info.plist`.
- `main.swift`, `AppDelegate`, `MainMenu` and `AppInfo`.
- One trivial `AtriumCore` test.
- `scripts/SIGNING.md`. Then ask Alif to do §3.4 and rebuild.

✅ **Accept when:**
- `~/Applications/Atrium.app` launches with a Dock icon and a full menu bar.
- ⌘Q quits.
- `codesign -dv ~/Applications/Atrium.app 2>&1 | grep Authority` shows `Atrium Local Signing`.
- `codesign -d -r- ~/Applications/Atrium.app` prints an **identical** `designated =>` line after two rebuilds.
- `./scripts/test.sh` passes.

**M1 — Sidebar shell and visual design** *(Alif signs off on the look)*

Build:
- `ScreenLayout` with its tests, `SidebarPanel`, `SidebarHostingView`, `SidebarController`, `HoverState`, `SidebarView`, `SidebarItemView`, `LensFill` and the lens layer, `BadgeView`, `HoverLabelPanel`, `DesignTokens` and `Motion`.
- `--demo` data.
- `make-icon.swift`, producing `AppIcon.icns`.
- The §7.3 glass test (a, b, c) and the lens lift versus `--lens-fill-only`.
- Temporarily, in demo mode, clicking an item just moves the lens. There's no activation yet.

✅ **Accept when:**
- Running `./scripts/run.sh --demo` shows the sidebar on the primary display with 8pt gaps.
- Hover labels appear beside the items even while another app is active.
- Clicks work on the first click without stealing focus.
- The lens glides with no visible stutter.
- Badges don't clip.
- It looks right in light, dark, Reduce Motion, Reduce Transparency and Increase Contrast.
- **Alif picks the glass variant and the lens variant**, and the losing code paths are removed.

**M2 — App library**

Build:
- `ManagedApp`, `AppLibrary` with its tests, `AppStore`, `IconCache` and `InstalledAppsCatalog`.
- The Add Apps window.
- The Settings window with only the **Apps** tab working (list, reorder, remove, row menu).
- The sidebar context menu: Remove and Show in Finder work; the others are disabled.
- The missing-app state.

✅ **Accept when:**
- Alif adds his 6 native apps.
- He reorders them in Settings ▸ Apps.
- He removes one.
- After relaunching, the order and contents persist.
- `AppLibraryTests` pass: add, dedupe, remove, move, round-trip, corrupt file.

**M3 — Switching and live state**

Build:
- `AX` helpers, `PermissionMonitor` and `DockItems` (needed for activation fallback c).
- `Launcher`, `AppSwitcher` (B3 without the snap step) and `WorkspaceMonitor` (B4 without the snap).
- Running dots, the launching pulse, the lens following ⌘-Tab, and the lens fading out for other apps.
- Hide and Quit.
- Sidebar ordering and unhide (B1), and B10.

✅ **Accept when:**
- Clicking each of Alif's apps activates it without focus flicker. Logs show which activation step succeeded.
- A quit app shows the launching pulse and then the dot.
- ⌘-Tab to Slack moves the lens.
- Activating Safari covers the sidebar; clicking Slack's window brings it back.
- Clicking Atrium in the Dock brings the last app and the sidebar forward.

**M4 — Accessibility, onboarding and snapping**

Build:
- `OnboardingView` (B6) and `LoginItem` (needed by onboarding step 4).
- `AXWindowObserver` and `WindowSnapper` (B3 step 4, B4 snap rule).
- `DisplayMonitor` (B2).
- The gear's amber dot.

✅ **Accept when:**
- The onboarding permission step auto-advances once access is granted.
- Every one of Alif's apps snaps into the workspace frame. That's about 300 ms after the click if it's running, or once its first window appears if it's launching.
- Slack and Notion with their main window closed reopen and snap.
- An Outlook compose window stays unsnapped while the main window snaps.
- A full-screen app isn't resized.
- Plugging in or unplugging the external display relocates the sidebar and re-snaps the front app.
- With Accessibility revoked, switching still works and the amber dot appears.

**M5 — Badges**

Build: `BadgeText` with its tests, `BadgeMonitor`, the badge animations and the `showBadges` preference.

✅ **Accept when:** an unread Slack DM shows a red count within about 2 s and clears after reading; the badge tests pass.

**M6 — Settings complete, login and restore**

Build:
- The **General** and **About** tabs.
- Per-app Open at Login and Snap Window toggles.
- The B9 startup sequence.

✅ **Accept when:** after logging out and back in, Atrium starts, the chosen apps launch hidden, and the last app is restored and snapped.

**M7 — Safari web apps** *(Alif creates them)*

Alif creates Gmail, Google Calendar, Messenger, Jira and YouTube Music via Safari ▸ File ▸ Add to Dock…

✅ **Accept when:**
- They appear under "Safari Web Apps" in the picker.
- They can be added.
- They switch and snap like native apps.
- Badges show for those that set Dock badges.

**M8 — Polish and QA** *(Alif signs off)*

- Run all of §10.
- Check VoiceOver labels, keyboard focus in Settings and Add Apps, and that the build has no warnings.
- Idle CPU should be about 0%; the badge loop only does work when needed.
- Memory stays under 150 MB with no growth over an hour.

Optional, only if Alif asks:
- respect the Dock's "Show indicators for open applications" (`UserDefaults(suiteName: "com.apple.dock")`, key `show-process-indicators`);
- drag-to-reorder in the sidebar (one time-boxed attempt; keep only if it's solid in the non-activating panel);
- haptics on reorder.

---

## 10. Verification

**Automated (`./scripts/test.sh`, Swift Testing, `AtriumCoreTests`):**

- **`ScreenLayoutTests`:**
  - panel, glass and workspace frames for the left and right edges;
  - a Dock on the left and on the bottom (`visibleFrame` offsets);
  - Cocoa→AX conversion for a secondary display above (y > primary height), below (negative y), left (negative x) and right of the primary.
- **`BadgeTextTests`:**
  - `""` and `"  "` → nil;
  - `"3"` → `.count(3)`;
  - `parse("120") == .count(120)` and `.count(120).display == "99+"`;
  - `"•"`, `"●"` and `"."` → `.dot`;
  - `"!"` → `.text("!")`;
  - `"unread"` → `.dot`;
  - `"0"` → nil.
- **`AppLibraryTests`:**
  - add, then dedupe by bundle id;
  - remove and move;
  - save → load round-trip in a temp directory;
  - a corrupt file is renamed and the library loads empty;
  - decoding an old JSON without `snapWindow` gets the default `true`.

**Manual QA script (Alif, after M4 and again in M8):**

1. **Fresh start.** Quit Atrium, delete `~/Library/Application Support/Atrium`, run `tccutil reset Accessibility com.alif.atrium`, then `defaults delete com.alif.atrium`. Launch and go through onboarding; granting access auto-advances.
2. **Add apps.** Add Slack, Claude, Notion, Grok Bot, Outlook, Muse (and the Safari web apps after M7).
3. **Switch through every app.** Each one comes to the front and fills the area right of the sidebar with an even 8pt gap. The lens glides to it.
4. **⌘Q Slack, then click it.** You see the launching pulse, then the window appears and snaps.
5. **⌘W Notion's window** (the app keeps running), then click it. The window reappears and snaps.
6. **Open Safari over everything.** It covers the sidebar like a normal window. ⌘-Tab to Claude: the sidebar returns and the lens moves.
7. **Resize Claude by hand**, ⌘-Tab away and back. It is **not** re-snapped. Clicking Claude in the sidebar re-snaps it.
8. **Click Atrium in the Dock.** The last app and the sidebar come forward.
9. **Put Outlook in native full screen** and click it. It activates and isn't resized.
10. **Connect or disconnect the external display.** The sidebar relocates within about 1 s and the front app re-snaps.
11. **Badges.** Send yourself a Slack DM: the badge animates in. Read it: it clears.
12. **Restart.** Enable "Open at login", then log out and back in. Atrium, the hidden apps and the last app are all restored.
13. **Accessibility settings.** Turn on Reduce Motion, Reduce Transparency and Increase Contrast, and try dark and light mode. Everything stays legible, and motion becomes crossfades.
14. **Revoke Accessibility.** Switching still works, there are no crashes, and the amber dot and Settings row explain.

**Debugging:** `log stream --predicate 'subsystem == "com.alif.atrium"' --level debug`

---

## 11. After this plan is approved

1. Create `docs/PLAN.md` in `/Users/alif/Desktop/AI Mission Control` (a copy of this file).
2. Create `CLAUDE.md` (about 20 lines) with:
   - the instruction "Read docs/PLAN.md fully before coding; work milestone by milestone";
   - the build, run, test and log commands;
   - the §4 rules, condensed;
   - the "stop and ask Alif" list.
3. Alif starts a Sonnet session in that folder with: *"Build Atrium following docs/PLAN.md, starting at M0."*
