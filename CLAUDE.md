# Atrium

A native macOS 26 app: a Liquid Glass sidebar that switches between Alif's installed apps and snaps their real windows beside it.

**Before writing any code, read `docs/PLAN.md` in full.** Build milestone by milestone (§9), starting at M0. Don't start a milestone until the previous one's ✅ criteria pass.

## Commands
- Build, package, sign and install to `~/Applications`: `./scripts/build.sh`
- Build and relaunch: `./scripts/run.sh` (add `--demo` for sample data)
- Tests (Swift Testing; there is no XCTest here): `./scripts/test.sh`
- Logs: `log stream --predicate 'subsystem == "com.alif.atrium"' --level debug`

## Rules (condensed from PLAN.md §4)
- **No Xcode on this Mac.** Use SwiftPM and the shell scripts only: no `.xcodeproj`, asset catalogs or `actool`.
- **Apple frameworks only.** No third-party packages, no private APIs (SkyLight/CGS/`_`-prefixed), no AppleScript.
- **Swift 6 strict concurrency.** UI, AX and state code is `@MainActor`. `Task.sleep` is fine; never block the main thread. Use the async `openApplication`, never its completion handler.
- **Constants.** Every design number lives in `Design/DesignTokens.swift`, `Design/Motion.swift` or `AtriumCore/LayoutConstants.swift`.
- **Logging and warnings.** Log with `os.Logger` (subsystem `com.alif.atrium`); no `print`. The build must have no warnings and use no deprecated activation APIs.
- **Git.** Commit after every milestone.

## Stop and ask Alif
- Creating the signing certificate, and the keychain "Always Allow" prompt (M0).
- Granting Accessibility, and any `tccutil` command.
- Visual sign-off (end of M1, and M8). You can't see the screen, and glass can't be screenshotted headlessly.
- Creating the Safari web apps (M7).
- Anything you can't verify yourself.

## Toolchain quirk (already handled)
This Mac's Command Line Tools have a stale `PackageDescription` interface, so a bare `swift build` fails with a manifest link error. `scripts/env.sh` (sourced by every script) builds a patched copy in `.toolchain-fix/` and sets `SWIFTPM_CUSTOM_LIBS_DIR`. Always use the scripts, or `source scripts/env.sh` first. Don't edit the system Command Line Tools.
