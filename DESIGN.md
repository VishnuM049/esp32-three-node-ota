# Fleet browser log visual system

The dashboard is an **operational observation surface** for a projector and a Mac browser, not an update control panel. It uses a visible 32px construction grid as a measurement cue, aligned version numerals, crisp section rules, and unboxed node columns. The three-node version/status matrix is the first proof; the chronological event table is the second. This grid is deliberate subject matter for a device-state instrument, not a decorative backdrop for unrelated pages.

- **Palette:** cool near-white `#f6f8fa`, ink `#142431`, muted blue-gray `#3e5667`; blue `#244fb4` marks structure/selection, green `#176548` a currently confirmed valid state, amber `#8e4c13` unavailable or unconfirmed. Do not show stale state in success green.
- **Typography:** Avenir Next / Helvetica Neue for legible offline system text; tabular monospace only for recorded times, heap, and stack measurements. Oversized `vN` numerals give a distant viewer a version-change cue without inventing charts.
- **Layout:** 3 rails on wide screens, one linear sequence on narrow screens; event table remains horizontally scrollable for long details. Connection error is plain language. Body text and outcomes remain readable without the grid.
- **Interaction:** browser auto-refreshes its Mac-local cache; event filters are the only user controls. No update action, no secret file route, no external dependency. Every dynamic value uses `textContent`; only whitelisted static assets are served.
- **Evidence:** status is observed through the controller. Offline snapshots are labeled stale; a new version or valid boot enters the ledger only when observed, while the one-shot sender records its own acceptance/confirmation separately. Neither source is a cryptographic audit log.

Offline desktop (1440px) and narrow (500px) review fixtures were inspected from **synthetic, temporary status data**, not presented as real device output. The real hardware evidence lives in `NOISE_RUNTIME_TEST.md`. Browser screenshot files remain ignored under `noise_experiments/ui-review/`.
