# CodeGram 14.1 — settings redesign

The existing Settings → CodeGram entry now opens the dashboard directly. The
normal launch into Telegram chats is preserved. No extra nested feature hub.

## Layout

- Large CodeGram heading, owner's mark, short subtitle and functional search.
- Ghost and local archive quick switches backed by existing engine settings.
- Two-column Privacy, Messages, Appearance and Voice Studio cards.
- Storage/VPS and Additional rows grouped below; all previous options remain
  reachable through the category pages and search results.
- Rounded antialiased settings-row icon with transparent corners. The opaque
  Home Screen source icon keeps the normal iOS system mask.
- Status capsule with a taller glossy gradient, a light rim, an aspect-correct
  white mark and the CodeGram wordmark. Existing visibility/device rules apply.
- Theme-aware colors, Dynamic Type and a one-column layout on narrow screens or
  at large text sizes. No added imagery or network requests on the dashboard.

The archive switch enables/disables capture of new deleted messages and edits.
Enabling it also enables retention across launches; disabling capture preserves
the current retention preference. VPS capture remains controlled by VPS rules.
The voice card reads the current recorder configuration. The server form and
Keychain identity are retained under Storage/VPS.

## Visual acceptance criteria (before capture)

No simulator-control tools are exposed in this session. The project guide's
XcodeBuildMCP fallback rule hands interactive checks to the device owner; no
recorded-frame or runtime visual verification is claimed by a green build.

When simulator/device capture is available, record light/dark mode, normal and
large text, narrow/large phones, opening/back, search and the quick toggles.

Expected frames:

1. Header, mark, search, switches, tiles and bottom rows stay within their safe
   width. At narrow widths or large text, cards become one column in the same
   reading order. Text and toggles do not overlap. Scrolling reaches all rows.
2. Pressed tiles, illustrations and captions scale together to 0.98 in about
   120 ms and return in about 180 ms, without a spring or overshoot. A reduced
   motion setting uses a simple highlight without scaling.
3. The background gradient follows the card bounds immediately, without a
   delayed fill or exposed corner during first layout or rotation.
4. Typing replaces cards with matching real settings destinations, clearing
   restores the dashboard. Search-result layout changes are immediate; only the
   system search cancel-button transition animates. Keyboard insets keep the
   last result reachable.
5. Switches disable briefly during a settings transaction and show its committed
   state. Changing a setting in a child screen updates the dashboard on return.
6. Rounded menu-icon corners reveal the surrounding row color in both themes;
   the capsule and logo are sharp at each display scale and hide on landscape
   and unsupported devices as before.

## Build and compatibility

Full iPhone build remains the only supported app build. Preserve the existing
toolchain cache, bundle identifier, Keychain service, server protocol and data.
No VPS update is needed for this UI release. The build/IPA validator must match
version 14.1.0 and the actual Actions run number; validate ZIP/digests before
delivery. Device/runtime checks above remain pending until executed.
