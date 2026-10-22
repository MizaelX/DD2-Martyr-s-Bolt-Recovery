# Martyr's Bolt Recovery (Dragon's Dogma 2)

A small REFramework Lua mod that slowly gives back the maximum HP you sacrifice with the Magick Archer's
**Martyr's Bolt**, so one big shot doesn't force you to head back to camp.

It restores **only** the HP Martyr's Bolt took. Loss Gauge damage from enemies, falls and anything else
still needs a rest or a curative, as in vanilla.

- Recovery is linear: 100% of your original max HP every 300 seconds (configurable), so 1/300 of it per second.
- It restores max HP (the Loss Gauge), not current HP. You still heal normally.
- The skill itself is unchanged: same damage, charge time, animation and HP cost.
- Nothing is saved. Pending recovery is discarded when you rest, die, fully restore max HP, load a save or quit.

## Requirements

| | Version |
|---|---|
| Dragon's Dogma 2 (Steam) | build 25920212 (Oct 2026 update) |
| [REFramework](https://github.com/praydog/REFramework-nightly/releases) | nightly-01433 or newer (`REFramework.zip`, `dinput8.dll` only) |

No other dependencies.

## Installation

1. Install REFramework: extract **only** `dinput8.dll` from `REFramework.zip` into the game folder
   (`...\steamapps\common\Dragons Dogma 2\`).
2. Copy `src/MartyrsBoltRecovery.lua` to `Dragons Dogma 2\reframework\autorun\`.
3. Start the game. Press **Insert** for the REFramework menu. The mod is under
   **Script Generated UI → Martyr's Bolt Recovery**.

## Settings

Saved to `reframework/data/MartyrsBoltRecovery.json` (the recovery pool itself is never saved).

| Setting | Default | |
|---|---|---|
| Enabled | on | Turning it off also discards pending recovery. |
| Recovery duration | 300 s | Time to restore 100% of original max HP. |
| Recover during combat | off | Recovery pauses while the game considers you in battle and resumes afterwards. |
| Recover while charging Martyr's Bolt | off | Recovery pauses while charging and resumes right after. |
| Debug logging | off | Writes events to `reframework/data/MartyrsBoltRecovery.log`. |

The menu also shows pending recovery (HP, % and time remaining), the detection status and diagnostics.

## How it works

Martyr's Bolt is `HumanCustomSkillID.Job08_SpiritArrow`. While it charges, the game's behavior-tree action
`app.Job08SpritArrow` calls `processSacrifice()` every frame, and that call lowers the Arisen's
`ReducedMaxHp`. Enemy damage lowers it through a different path (`HitController.updateDamageHp`), outside that call.

The mod hooks `processSacrifice()` and registers, for each call:

```
min(drop of the Arisen's ReducedMaxHp during the call,
    increase of the game's own Job08ActionController.SpritArrowSacrificedHitPoint during the call)
```

Both signals have to agree, so a hit landing at the same moment can't be counted as sacrifice. Whatever the
skill really took goes into one pool (`MaxHPToRecover`, in HP points). About 10 times a second the mod raises
`ReducedMaxHp` by `OriginalMaxHp / RecoveryDuration × elapsed`. Each step is capped by the pool and by the
missing max HP, and the value is read back so only what was actually restored leaves the pool.

Accounting rules:

- **Death** (HP 0), **full max-HP restoration** (rest, Wakestone, items), **save load** (a new health controller)
  and **disabling the mod** clear the pool. Nothing is refunded.
- A **partial** max-HP restoration from the game uses up pending recovery first, so the same HP is never
  restored twice.
- Changes to **original** max HP (equipment, buffs, level) are never registered as sacrifice. The rate follows
  the new value.
- Elapsed time stops while the game is paused (`GuiManager.isPausedGUI`) and, by default, during battle (`BattleManager.get_BattleMode`). Frame gaps over 1 s (loading) grant nothing.

## Testing

**In game** (user playtest, 2026-10-21/22, with the debug log reviewed):

- Casts registered their real cost (e.g. 880.12, 240.19 + 217.27 → pool 449.16 across two casts).
- Measured recovery about 6.05 HP/s for 1804.1 original max HP (expected 6.01).
- Ordinary damage was not restored. A starting Loss Gauge stayed after recovery finished.
- Death, rest and save load each cleared the pool.
- Pause, fast travel and combat were reported working by the user.

**Simulated:** `tests/sim.lua` runs the real mod file against a stubbed REFramework and a fake Arisen
(48 checks), including the spec's primary acceptance test (300 ordinary + 1000 sacrificed → ends at exactly 1700).

```
npm install fengari@0.1.4
node tests/run.js
```

## Known limitations

- Martyr's Bolt has no manual cancel. Interrupted casts (grabs, staggers) count what was actually drained;
  the game gives no refund.
- A full charge can kill you (vanilla behavior). Pending recovery is discarded on death.
- Time is real elapsed time with pause detection. In-game slow-motion effects still count as normal time.
- Other mods that keep rewriting `ReducedMaxHp` (general Loss Gauge regeneration mods) are conceptually incompatible:
  their restorations use up this mod's pending recovery.
- A game update may rename internals. If so, the menu shows **Detection: FAILED** and the mod does nothing.

## Uninstall

Delete `reframework\autorun\MartyrsBoltRecovery.lua` (and optionally `reframework\data\MartyrsBoltRecovery.*`).
The mod never touches save files. To remove REFramework too, delete `dinput8.dll` and the `reframework` folder.

## Repository layout

| Path | |
|---|---|
| `src/MartyrsBoltRecovery.lua` | The mod. |
| `tools/MartyrsBoltProbe.lua` | Diagnostic probe used to find the skill internals. Optional, for research after game updates. |
| `tests/` | Offline simulation tests. |
| `docs/SPEC.md` | Original design specification. |
| `MODLOG.md` | Development notes and reverse-engineering findings. |

## Credits

- [REFramework](https://github.com/praydog/REFramework) by praydog.
- Health API reference by [D3athAn63l](https://github.com/D3athAn63l/DD2_Stuff).

## License

MIT. See [LICENSE](LICENSE).
