# Fleet browser log visual system

The Mac-hosted log is a **read-only developer record**, not a control dashboard. A plain white page, compact system typography, and quiet horizontal rules put versions, authenticated boot state, and timestamped results first. Three node rows read as one status listing; the event table follows immediately. There are no decorative grids, cards, colored panels, or animation.

- **Color:** white background, dark `#202930` text, subdued `#4d5a63` secondary text and thin neutral dividers. A single low-saturation blue-gray is reserved for focus and the live connection dot. Valid/offline status is always conveyed in words, not color alone.
- **Type:** Mac system sans for labels and body; tabular monospace only for time and byte measurements. Firmware versions are larger than adjacent text, but not hero graphics.
- **Layout:** Three flat status rows with the same columns on desktop; stacked fields on narrower widths. The event table preserves times, node, event, and observed result, with horizontal scrolling on narrow screens.
- **Behavior:** status reads from controller `/status`; offline snapshots are marked stale, and only observed changes enter the log. Event filters remain keyboard-accessible. No browser action can upload firmware; localhost assets are whitelisted, and dynamic content uses `textContent`.
- **Security wording:** the footer distinguishes authenticated controller→edge transport from plaintext laptop→controller HTTP. This local event file is presentation evidence, not a tamper-proof audit trail.

Offline screenshot checks use temporary synthetic status data only; actual hardware results remain in `NOISE_RUNTIME_TEST.md`. Development screenshots stay ignored under `noise_experiments/ui-review/`.
