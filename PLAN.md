# Codex Usage Bar

Approved September 6, 2026. Project: /Users/amitka/Personal/Projects/CodexUsageBar.

## Goal
A native macOS menu bar utility displaying the installed Codex app icon and percentage of the main Codex quota used. Clicking opens a compact native popover with per-window usage, reset countdowns, connection/freshness status, and manual refresh.

## Interaction contract
- Launch as an accessory app with no Dock icon or main window.
- Fetch usage at launch, every 60 seconds, on waking, and whenever the popover opens.
- Subscribe to account/rateLimits/updated on the app-server connection; use polling to cover usage from other Codex clients.
- Refresh now fetches immediately. Deduplicate overlapping requests and show loading feedback.
- Main indicator uses the most consumed available window in the main codex bucket, never an average of unrelated model buckets. Label the chosen window in the popover.
- Preserve last successful data on failure, clearly marked stale. Missing data displays an em dash, never 0%.
- Offer used/remaining display, Open Codex, launch at login, and Quit.

## Implementation
1. Verify the installed Codex CLI handshake and read-only usage endpoint.
2. Build a Swift Package: testable Foundation models/JSON-RPC client plus AppKit status item and SwiftUI popover. Minimum macOS 13.
3. Use an owned stdio app-server subprocess, existing Codex authentication, request timeouts, safe teardown, and reconnect after failure. Never read or copy auth tokens.
4. Package an ad-hoc signed .app with reproducible build script and documentation. Login startup is opt-in using ServiceManagement.
5. Test payload variants, selection, missing values, notifications, timeouts, and live refresh; inspect the running UI.

## Validation and delivery
- Swift tests and release build.
- Read-only live integration smoke test without starting model turns.
- Verify launch, dropdown, manual refresh, automatic refresh, and error handling where practical.
- Save source, PLAN.md, README.md, and the runnable app in this project. Personal local build; App Store distribution/notarization is out of scope.

## Progress
- [x] Confirmed scope and destination.
- [x] Verified Swift toolchain and existing ChatGPT login.
- [x] Live app-server transport verified.
- [x] Application implemented and packaged.
- [x] Automated checks and live automatic-refresh validation complete.
- [x] Running dropdown inspected through native accessibility.
- [ ] Screenshot review and automated button-click verification (computer-use service timed out).

## Delivery notes — September 6, 2026

- Source and runnable app saved in the confirmed project folder.
- `swift run UsageCoreChecks`: 14 scenarios, 35 assertions, 0 failures.
- Release build and strict code-signature verification passed.
- `--check`: live Codex weekly usage read successfully (6% at validation time).
- `--watch-check`: one successful read at 4 seconds, two by 69 seconds, no errors; validates the actual 60-second refresh cycle.
- Native accessibility inspection confirmed the live headline, per-window progress indicators, reset times, refresh action, display mode, login checkbox, Open Codex, and Quit. Screenshots and subsequent clicks could not be verified because the computer-use service repeatedly timed out.
- Launch at login remains opt-in; reboot/login behavior was not tested.
- The menu bar and header reuse the actual installed Codex artwork. No network asset dependency.
- No model prompts, quota reset consumption, or account changes were performed.

## Requested refinement — September 6, 2026

- [x] Anchor dropdown to menu bar button in global screen coordinates.
- [x] Remove top arrow by replacing NSPopover with an arrowless NSPanel.
- [x] Compact native menu material, flat rows, and collapsed secondary model details.
- [x] Percentage left, Codex icon right in menu bar.
- [x] Used / Remaining segmented toggle applies to every displayed quota.
- [x] Release build, signature, and existing 14 scenarios / 35 assertions pass.
- [x] Native UI screenshot review, toggle, expansion, refresh, and Escape dismissal checked successfully in this refinement.

## Native-menu correction — September 6, 2026

- [x] Delegate the bounded menu controller to GPT-5.6 Terra; parent retains integration/review.
- [x] Replace custom NSPanel/SwiftUI dropdown with NSStatusItem.menu and native NSMenuItems.
- [x] Native Used/Remaining checkmarked choices, Other Models submenu, refresh and lifecycle actions.
- [x] Review primary/secondary window display and accessibility titles.
- [x] Release build, signature and 14 validation scenarios / 35 assertions passed.
- [ ] Visual review of the native menu: blocked by computer-use tool timeouts/stall. Earlier screenshots cover the retired panel.

## Battery-like gauge — September 6, 2026

- [x] Add a vector capsule capacity gauge beside the menu-bar percentage.
- [x] Fill follows Used or Remaining display mode; colour follows remaining capacity.
- [x] Represent unavailable and stale usage without implying a valid empty value.
- [x] Build, standalone checks, local signature verification, and relaunch completed.
