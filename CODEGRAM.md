# CodeGram 14.0.0

## Compiled release — 2026-10-31

- CodeGram **14.0.0 (21)**, arm64 iPhone, iOS 15.0 or later, unsigned for the owner's signer.
- Source: `5bf622693653c90ce9799ff38b6dfb5f9eb1cd79`.
- Successful full build: https://github.com/vaysenko7882/Nikita-iOS/actions/runs/41210799767
- IPA SHA256: `3f4484e701572de90927b6e014d917f80104b2b7aa92486d8cc15934627e2883` (72,258,097 bytes).
- ZIP SHA256: `923ff42c2d22312cb90fab96fee239e766cbbc8a6374a7675eb1f75fa99a7872` (72,001,169 bytes).
- CI passed: 11 build/tool tests, 55 server tests, 47 Swift syntax checks, the Postbox architecture guard, the production Postbox persistence regression harness and advanced/legacy voice PCM checks.
- Full compile: **2018.210 seconds**; **6698 disk-cache hits / 9529 actions**, 1650 internal, 501 local, 680 worker. New cache saved under the existing toolchain key and this source SHA.
- Compiler output, artifact digest, IPA sidecar/digest and both ZIP CRCs checked. Bundle ID and Keychain service preserved.
- **Not runtime-tested:** no iPhone/simulator launch or interactive UI/animation verification was performed. Device acceptance checks below remain pending.

Personal iPhone client, based on the existing Nikita/MadGram fork. The bundle ID
`personal.nikita.messenger`, Keychain service and archive protocol/resource IDs
are deliberately preserved so an update can retain the existing account/data.
GPL/upstream notices and source attribution remain intact.

## Changes

- Owner-supplied black/white logo: app icon, settings hero and native status capsule.
- Voice studio: pitch, tone, robot amount/frequency, echo amount/delay, gain,
  wet/dry mix, compression and soft gate. Built-in and up to 24 custom presets.
  Immutable settings per recording, including pause/resume. Calls are unaffected.
- Deleted-message opacity, black overlay, dashed outline, width/color/radius,
  live preview and immediate style notifications for reused message nodes.
- VPS v4 policy: private dialogs on; groups, channels and archived peers off.
  Always/never exceptions override both category and archive folder. Policy is
  account-bound, revisioned and saved on the server; existing data is retained.
  Unknown peers fail closed until folder/type lookup succeeds. Download workers
  also check policy between chunks and can resume paused files.
- Archive storage: per-category unique media, partial downloads, database/WAL,
  deleted subset, queue, reserve/free disk; local iPhone archive shown separately.
- Opt-in copy/save for already received protected content; saving accessible
  stories through the existing native export; opt-in retention of received
  view-once media. No retrieval of inaccessible, consumed or expired media.
- Opt-in hiding of client restriction banners. Telegram server access checks,
  membership, verification requirements and unavailable channels still apply.
- Device-local names and avatar overrides for channels/groups/bots. The original
  names remain in Postbox/FlatBuffers encoders, copies and server merges; no
  Telegram profile-update RPC is invoked. Avatar files are local and bounded.

## Verification

Local: 55 server tests, 8 build/artifact tests, Python compile and shell parse.
CI: changed Swift syntax; production Postbox persistence regression harness;
advanced/legacy PCM, callback invariance and preset persistence checks; full
unsigned arm64 iPhone build and Mach-O/version/branding validation.

No simulator/device control tools are exposed in this session. A compiled IPA
is not evidence of on-device execution or visual QA. Device checks are pending:

1. Install over the previous app with the same signer; launch twice, keeping login.
2. Open CodeGram settings in light/dark mode; no overlapping text at normal and
   large text sizes. Header logo and status capsule stay centered and do not
   overlap status items; capsule hides on landscape as before. No new animation
   is introduced, controls use native navigation and table transitions.
3. Change deleted style: preview and an already visible deleted text, sticker,
   animated sticker and round video update; normal reused cells stay opaque.
4. Record/play/continue a voice with each DSP group and a saved preset; a paused
   voice retains its initial settings. Check loud input for unwanted distortion.
5. Upgrade VPS with --reuse-session. Save rules, restart app/service and confirm
   persistence; exclude a group and an archived dialog, then allow one archived
   exception. Only the exception should collect subsequent messages/media.
6. Compare storage to a known downloaded/deleted attachment; deleted bytes are a
   subset and partial downloads do not count as completed media.
7. Rename/change avatar of a bot/channel locally; another Telegram client must
   retain the original. Reset locally, reconnect and confirm original returns.
8. Test opt-in exports on received content, and confirm inaccessible stories or
   server-blocked channels produce their normal access/error state.

## Build cache

Preserve existing toolchain-keyed Bazel CAS and repository archives. App version
and real CI build number do not invalidate global compilation defines; only the
Info.plist build-number target is stamped. Expanded repository contents caching
stays disabled (Bazel 9 must not restore incomplete directory trees). Logo sizes
and shared Swift image data are reproducibly generated from the original PNG.

See server/README.md for the single-command VPS update, rules and protocol.
