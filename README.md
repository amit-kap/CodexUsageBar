# Codex Usage Bar

A personal native macOS menu bar utility for your Codex account allowance. The menu bar shows the percentage, a monochrome capacity meter, and the Codex icon from left to right. Click for usage windows, reset countdowns, refresh status, and controls.

## Build and run

Requires macOS 13+, Swift 5.9+ / Apple Command Line Tools, and Codex signed in with a ChatGPT account. No external Swift packages or API key required.

```sh
cd /Users/amitka/Personal/Projects/CodexUsageBar
./scripts/build.sh
open "dist/Codex Usage Bar.app"
```

The app runs without a Dock icon. Quit from its dropdown before replacing a running build. Keep the app at a stable location if enabling **Launch at login**. That setting is off by default; macOS may ask you to allow it in Login Items.

## Behavior

- Reads usage immediately on launch, every 60 seconds, on system wake, and when opening the dropdown.
- Applies `account/rateLimits/updated` notifications received by its own connection. Cross-client notification delivery is not assumed; polling also catches usage in other Codex sessions.
- **Refresh now** (⌘R while the dropdown is open) makes an immediate request. Overlapping refresh requests are coalesced.
- Displays **used** percentage by default. **Display → Used / Remaining** switches the menu bar and detailed percentages together; remaining is `100 − used`.
- Uses the most consumed available window in the `codex` bucket. The menu lists each available main window once, with the most consumed readable window first; unavailable percentages remain visible as unavailable. Other models appear separately. An absent main bucket displays `—`; missing fields are not interpreted as zero.
- The capacity meter follows Used / Remaining mode. Missing usage shows a dot; stale usage dims the meter and adds a diagonal mark.
- Keeps the last successful reading if a refresh fails. `!` in the menu bar and an explanatory dropdown message mark stale data. A reset deadline never fabricates a new allowance; the app waits for the server's next reading.
- The dropdown is an actual AppKit `NSMenu` assigned to `NSStatusItem.menu`. macOS handles placement under the menu bar item, styling, highlighting, keyboard navigation, and dismissal. There is no custom panel or arrow.
- Other model limits are available in the native Other Models submenu.
- Launch at Login is opt-in. Open Codex and Quit are native menu items.

## How it connects

`UsageCore/CodexClient.swift` starts one owned `codex app-server --stdio` process, performs `initialize` / `initialized`, and reads `account/rateLimits/read`. It uses existing Codex authentication without reading or copying auth tokens. It never sends a model prompt, consumes a reset, or changes account limits. The subprocess may maintain normal Codex runtime state.

Executable discovery checks Codex and ChatGPT application bundles, user Applications, Homebrew locations, and PATH. Each request has a 20-second timeout. A failed connection is discarded and retried on the next refresh. The child process is stopped when the app quits. Stderr is discarded so credentials or backend diagnostic details are not logged by this utility.

Official protocol reference: https://learn.chatgpt.com/docs/app-server

## Validation

```sh
swift run UsageCoreChecks
./scripts/build.sh
"dist/Codex Usage Bar.app/Contents/MacOS/CodexUsageBar" --check
"dist/Codex Usage Bar.app/Contents/MacOS/CodexUsageBar" --watch-check
```

`UsageCoreChecks` is a standalone assertion runner that works with Command Line Tools, without XCTest or a full Xcode installation. It covers multi-window selection and menu ordering (including secondary-first, ties, and missing values), absent data, legacy payloads, clamping, notification merges, reset boundaries, fragmented JSON-RPC lines, failed-refresh recovery, request deduplication, automatic polling and stopping, timeouts, and exited subprocesses.

`--check` reads live account limits once and exits. `--watch-check` observes the real 60-second automatic refresh for 70 seconds and requires at least two successful reads. Neither starts a model turn. `--show` opens the dropdown at launch for visual review.

## Project structure

- `Sources/UsageCore`: quota models, protocol transport, and observable refresh state.
- `Sources/CodexUsageBar`: AppKit menu bar integration, native NSMenu controller, preferences.
- `Tests/UsageCoreTests`: executable validation scenarios.
- `scripts/build.sh`: builds and ad-hoc signs a local `.app` in `dist`.
- `PLAN.md`: agreed scope and progress.

This is a personal local build, not an official OpenAI application. The menu bar uses bundled Codex artwork copied from the installed application for this user's local utility. The app is ad-hoc signed, not notarized for distribution. Launch-at-login behavior depends on macOS approval and a stable app location.

## Current validation — September 30, 2026

The main-window menu regression is covered by the standalone checks. All 15 scenarios / 41 assertions pass. Release packaging and strict code-signature verification passed. Details are recorded in `PLAN.md`.

Native-menu screenshot/click verification remains incomplete. Earlier visual checks covered a retired custom panel. Launch-at-login behavior across reboot/login has not been tested.
