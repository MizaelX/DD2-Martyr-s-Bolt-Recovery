# Changelog

## 1.0.0 (2026-10-22)

- First release.
- Detects the max HP sacrificed by Martyr's Bolt by hooking `app.Job08SpritArrow.processSacrifice`, cross-checked
  against the game's `SpritArrowSacrificedHitPoint` counter.
- Linear recovery of 100% original max HP per 300 s (configurable). Paused while charging, while the game is paused
  and, by default, during battle (option "Recover during combat").
- Pending recovery is cleared on death, full max-HP restoration, save load and disabling. Partial restorations from
  the game use it up first.
- REFramework menu with settings, pending recovery and diagnostics. Optional debug log (capped at 1 MB).
