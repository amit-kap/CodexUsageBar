# Codex Usage Bar

Approved September 6, 2026. Updated September 30, 2026.
Project: /Users/amitka/Personal/Projects/CodexUsageBar.

## Goal and current behavior

A native macOS menu bar utility showing the main Codex allowance as a percentage, monochrome capacity meter, and bundled Codex icon. Clicking opens an AppKit `NSMenu` attached to `NSStatusItem.menu`.

- Run as an accessory app with no Dock icon or main window.
- Read usage on launch, every 60 seconds, on wake, and when the menu opens; deduplicate overlapping refreshes.
- Apply `account/rateLimits/updated` notifications on the owned connection, with polling for other clients' activity.
- Use the most consumed readable window in the `codex` bucket for the status indicator. Show each available main window once in the menu, most consumed first, followed by the other window and its reset countdown. Preserve unavailable window details.
- Preserve the last successful reading on failure and mark stale data. Missing usage never implies 0%; reaching a reset deadline waits for a server update.
- Offer native Used/Remaining choices, Other Models submenu, Refresh Now, Open Codex, opt-in Launch at Login, and Quit.
- Meter fill follows the display mode; its monochrome color follows the menu-bar appearance. A dot indicates missing usage; dimming and a diagonal mark indicate stale usage.

## Implementation

- Swift Package targeting macOS 13+, with Foundation/Combine usage models, refresh state, and JSON-RPC transport, plus AppKit UI and ServiceManagement login startup.
- One owned `codex app-server --stdio` subprocess using existing authentication, 20-second request timeouts, teardown, and reconnect after failure. No auth-token parsing or model turns.
- `scripts/build.sh` creates an ad-hoc signed app in `dist`. Personal local distribution; notarization and App Store delivery are out of scope.
- `UsageGaugeIcon.swift` contains an older standalone template meter helper; the current status indicator is drawn in `App.swift`.

## September 30, 2026 maintenance

- Fixed the menu repeating the secondary window when it was most consumed and omitting the primary window.
- Added regression coverage for secondary-first and primary-first ordering, missing percentages, a single window, and tied usage.
- Updated README and this plan to describe the current native menu and monochrome meter.
- Validation: `swift run UsageCoreChecks` passed 15 scenarios / 41 assertions with zero failures. Release packaging succeeded, and `codesign --verify --deep --strict` passed for `dist/Codex Usage Bar.app`.

## Previous validation and remaining checks

September 6 records report 14 scenarios / 35 assertions passing, release build/signature verification, and live read-only usage and 60-second polling checks. Those live checks have not been repeated for this maintenance change.

The original popover and later custom panel were replaced by the native menu. Earlier screenshots and click checks cover the retired panel. Native-menu screenshot/click verification remains outstanding after computer-use timeouts. Launch at login remains opt-in; reboot/login behavior is untested.
