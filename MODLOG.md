# MODLOG — Martyr's Bolt Recovery (DD2)

Spec: `Dragon's Dogma 2 Mod Martyr's Bolt.txt` (this folder).

## Environment (2026-10-21)
- Game: Steam, `C:\Program Files (x86)\Steam\steamapps\common\Dragons Dogma 2`, appid 2054970, buildid 25920212, DD2.exe mtime 2026-10-16.
- Saves: `C:\Program Files (x86)\Steam\userdata\<steam-user-id>\2054970\remote\win64_save`
- Backup: `backups/saves-20261021-221115/` (whole 2054970 userdata dir + game config.ini).
  Restore: copy `remote/win64_save/*` back with game closed (and Steam Cloud aware).
- REFramework: nightly-01433 (d4611aef, published 2026-10-21), monolithic REFramework.zip, only `dinput8.dll` installed
  (sha256 cb1acc11be71184be1eb5c29ccea2db156a55eee861686b71bbc522865d2c98a). Uninstall = delete dinput8.dll + reframework/.
- No other mods present before we started.
- `um` CLI unavailable (no Python on machine) — recon done by hand.

## Route
REFramework Lua (single autorun script). Data-only can't do runtime HP accounting; Lua has sdk.hook + HitController setters.

## Known API (from D3athAn63l snapshot 2026-10-11, TDB 83 — to be re-verified on this build)
- `sdk.get_managed_singleton("app.CharacterManager"):get_ManualPlayer()` → app.Character
- Character: get_Hp(), get_OriginalMaxHp(), get_ReducedMaxHp(), get_Valid(), get_Human(), get_Hit()
- `character["<Hit>k__BackingField"]` → app.HitController; set_ReducedMaxHp(System.Single), setHpValue(Single, Boolean)
- app.GuiManager:isPausedGUI(); app.BattleManager:get_BattleMode()

## Open problem
Attribution of ReducedMaxHp drops to Martyr's Bolt. No public skill-ID / hook info found (Nexus 1827 page 403 to scripts).

## Phase 1 plan
`src/MartyrsBoltProbe.lua` (read-only): dumps candidate type/enum members, hooks HitController
mutators and logs any that change player Hp/ReducedMaxHp, polls ReducedMaxHp + motion/job state.
Output: `reframework/data/MartyrsBoltProbe/*.log`.

## Findings (probe v1 run, logs/run1/)
- REFramework nightly-01433 works on this build. Health getters from the snapshot all work. `get_JobContext().CurrentJob` = 8 for Magick Archer.
- Martyr's Bolt = `app.HumanCustomSkillID.Job08_SpiritArrow` (91). Behavior-tree action class `app.Job08SpritArrow`
  (parent app.UseHumanAction): methods start(ActionArg), update(ActionArg), processSacrifice().
- FSM (via.motion.MotionFsm2:getCurrentNodeName(0)): charging = `Job08.Job08_SkillAttack.Job08_CS12.Job08_ReadySpiritArrow`,
  release = `...Job08_ShootSpiritArrow`. (`Job08_PrepareSpiritArrow` also exists as a name.)
- `app.Human:get_Job08ActionCtrl()` → app.Job08ActionController: get/set_SpritArrowSacrificedHitPoint() (game's own counter, semantics TBD).
- `app.Job08Parameter.SpiritArrowParameter.MaxHpDamageRateByFrame` = drain rate.
- Drain: ~18-22 ReducedMaxHp per 0.05 s (~1%/frame-chunk of 1804 orig). Drains ReducedMaxHp; Hp is clamped down to it.
  If Hp < ReducedMaxHp, only the gauge drains until they meet. Full charge took ~1439 of 1804.
- Ordinary hit: 78 HP damage → 7.79 ReducedMaxHp (≈10%). Hit during charge: the gauge part is buried in drain ticks → polling
  cannot attribute; need the processSacrifice hook.
- Two full restores (+1438.88, +1501.61) after anim 0/200→201→203 + FSM `Locomotion.WaitEndJack` — likely item use (ask user).
- HitController mutators (from dump): setReducedMaxHp, setReducedMaxHpValue, set_ReducedMaxHp, recoverMaxHp,
  recoverHpAndMaxHpCompletely, recoverHp, updateReductionMaxHPDamage, updateDamageHp, setMinRateMaxHp, set_MinRatioReducedMaxHp.
- Gotcha: Lua patterns have no `|` alternation — v1 filters matched nothing, 0 hooks installed.
- il2cpp_dump.json (1.16 GB) is in the game folder (Dump SDK; game crashed afterwards but JSON is complete).

## Findings (probe v2 run, logs/run2/) — attribution PROVEN
- Skill drain = Hit.setReducedMaxHp called INSIDE Job08SpritArrow.processSacrifice. Enemy damage = Hit.updateDamageHp →
  setReducedMaxHp OUTSIDE it (~10% of damage). Hit-while-charging cast: 33.5 outside vs 312 inside, cleanly split.
- Job08ActionController.SpritArrowSacrificedHitPoint == our in-sacrifice measurement (1647.25 vs 1647.25); resets to 0
  between casts; at lethal casts it overshoots slightly (gauge clamps at 1).
- Bolt kills: gauge drains to 1.00, then updateDamageHp(1.00) → hp 0, FSM Damage.Damage_Root.DieCollapse.
- Wakestone: FSM Damage.HumanDamage_Root.ReviveFromWakestone → recoverHpAndMaxHpCompletely(true).
- Rest at camp: setReducedMaxHp(orig) outside.  Grab (Caught_Standing) interrupts a cast, no refund. No manual cancel found.
- set_ReducedMaxHp(System.Single) write works and persists; does NOT change current Hp.
- Save load → new HitController address.

## Mod v1.0.0 (src/MartyrsBoltRecovery.lua)
- Registration per processSacrifice call = min(player ReducedMaxHp drop, player counter advance) → excludes concurrent damage.
  (Magick Archer is Arisen-only, so pawns never run this action.)
- In-game verified 2026-10-21/22 (user playtest + debug log): accumulation, ~6.05 HP/s at 1804.1 orig, death/rest/reload resets.
- Pool resets: hp<=0, red>=orig, new HitController address, disable. External red increase (orig unchanged) consumes pool.
- Offline sim: tests/run.js + tests/sim.lua (fengari 0.1.4 via NODE_PATH) — 40/40 pass (simulated, not in-game).

## Log
- 2026-10-21: recon, backup, REFramework installed, probe v1 written.
- 2026-10-21: probe v1 run analysed; probe v2 deployed (hooks Job08SpritArrow + HitController, test-write button).
