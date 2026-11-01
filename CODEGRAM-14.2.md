# CodeGram 14.2 — native settings and bounded optional work

## Changes

- The static status mark is 96 × 22 pt, rendered once, without a custom gradient
  or rim. Existing device offsets and landscape/device visibility are preserved.
- All CodeGram feature settings use the same inset cards, 22–24 pt corners,
  Dynamic Type text, gray system colors, white symbols and no custom borders.
  Ghost, filters, archive, interface, bot exceptions and category pages retain
  their engine settings; the old ItemList screens now route to these pages.
- UIKit Liquid Glass is used for surfaces and search on iOS 26+. Earlier iOS
  uses system material. Low Power Mode, thermal pressure and Reduce Transparency
  replace optional effects with a flat system surface. No continuously running
  custom animation/display link is added.
- Changing voice or export options no longer restarts VPS requests. Only a
  changed server configuration for this account resets the sync manager.
- Automatic archive sync stops when disabled/backgrounded or at serious/critical
  thermal pressure. It resumes on foreground/configuration/pressure changes,
  with one request at a time, at most four pages per batch (one in reduced mode),
  idle polling backoff up to 5/10 minutes and failure backoff up to 15 minutes.
  User sync remains available. The VPS collector is unchanged.
- Additional local background time is capped at 60 seconds, reduced to 15 in
  Low Power Mode or fair thermal pressure; none is added at serious/critical
  pressure. iOS may suspend earlier. The owner's background preference is kept.
- Deleted-message style is decoded once and cached under a lock. Ordinary
  messages allocate no decoration/observer. Unchanged decorations do not rebuild
  their paths. Hidden dashboard pages skip live voice-slider relayouts.

Bundle ID, Keychain service, account data, archive resource IDs and VPS protocol
are unchanged. No server update is required for this release. IPA is unsigned
and must be signed by the owner as before.

## Verification and remaining device acceptance

Local: 11 build/tool and 55 server tests passed; Python/shell syntax passed.
CI must run full release_arm64 compilation, Postbox persistence/architecture,
voice PCM and the new power/thermal scheduling policy harness before delivery.

There is no XcodeBuildMCP/device UI access in the editing environment. Following
CLAUDE.md's absent-tool fallback, runtime, visual and energy measurements are
pending owner device verification; compilation is not visual acceptance.

Expected frames, before capture (AGENTS.md):

1. On island phones the mark stays centered inside the cutout without projecting
   past its edges. Nothing overlaps time, signal or the camera. Landscape hides it.
2. Every CodeGram destination has gray backgrounds, white icons and large rounded
   rows, including Ghost, local archive, filters, interface and bot exceptions.
   No custom border/black gradient remains. Large text wraps without clipping.
3. Search has native material on supported iOS; typing/cancel/back remains usable
   with the keyboard. Light/dark and Reduce Transparency remain readable.
4. Pressed cards scale together to 0.98 for 120 ms, restore in 180 ms without
   overshoot. Reduce Motion/reduced energy uses only a highlight.
5. Change all feature toggles, return/reopen and relaunch: values persist. Verify
   archive quota/marker/clear confirmations, bot overrides and local avatars.
6. With a proxy recording this owner's VPS request counts, voice sliders cause
   zero VPS restarts. Disabled/background sync has no timer requests. Simulate
   thermal states and check pause/resume, backoff and bounded catch-up. Compare
   Energy Log/Time Profiler runs against 14.1 with the same account, media,
   brightness and duration. No claim of universally eliminating heat is made.
