# Dragon's Dogma 2 — Martyr's Bolt Recovery Mod

## Project overview

**Game:** Dragon's Dogma 2 (PC)

**Working title:** Martyr's Bolt Recovery

**Preferred implementation:** REFramework + Lua

**Primary goal:** Make the HP sacrificed when using the Magick Archer's Martyr's Bolt skill gradually recover over time, while preserving the game's ordinary Loss Gauge and resting mechanics.

This is **not a general HP regeneration mod**.

The mod must accurately distinguish HP sacrificed through Martyr's Bolt from maximum HP lost through enemy attacks, falls, environmental damage, or other game mechanics.

Only the HP sacrificed through Martyr's Bolt should recover automatically.

The mod must remain lightweight, avoid modifying game saves directly, and preserve vanilla gameplay except for the recovery of Martyr's Bolt's HP sacrifice.

---

## 1. Core gameplay behavior

### 1.1 Martyr's Bolt detection

The mod must detect when the player uses the Magick Archer skill **Martyr's Bolt**.

The skill progressively sacrifices maximum HP while charging, accumulating Loss Gauge before firing.

Requirements:

- Detect the actual activation of Martyr's Bolt, not merely whether Magick Archer is equipped.
- Track the maximum HP sacrificed throughout the charging process.
- Measure the actual HP sacrificed instead of assuming a fixed percentage.
- Add that amount to a recovery pool.
- Do not register ordinary damage received while charging as part of the sacrifice.
- Prevent duplicate registration of the same HP loss.
- Handle interrupted, canceled, and partially charged casts according to the HP actually consumed.
- If the game refunds any HP when canceling, do not count refunded HP as outstanding sacrifice.
- Do not change Martyr's Bolt's damage, charge duration, animation, targeting, or original HP cost.

**Important:** The mod must account for HP loss occurring during the charging animation, not merely compare HP values before and after firing.

### 1.2 Recovery pool

Maintain one variable representing the total outstanding recoverable maximum HP:

```lua
local MaxHPToRecover = 0
```

This pool stores HP points, not percentages.

Whenever Martyr's Bolt consumes maximum HP:

```lua
MaxHPToRecover = MaxHPToRecover + HPActuallySacrificed
```

Whenever the mod successfully restores maximum HP:

```lua
MaxHPToRecover = MaxHPToRecover - HPActuallyRestored
```

The pool must never become negative.

Multiple casts accumulate into the same pool. Individual cast timers or separate recovery queues are unnecessary.

### 1.3 Recovery speed

The recovery rate must be calculated using the character's **original maximum HP**, before Loss Gauge reductions.

The default recovery duration is 300 seconds (five minutes).

Formula:

```lua
RecoveryRate = OriginalMaxHP / 300
RecoveryAmount = RecoveryRate * DeltaTime
```

Each second, the mod should restore approximately 0.333333% of original maximum HP, provided the recovery pool is not empty.

For example, with 2,000 original maximum HP:

| HP sacrificed | Time to recover |
|---|---|
| 100 HP (5%) | 15 seconds |
| 500 HP (25%) | 75 seconds |
| 1,000 HP (50%) | 150 seconds |
| 1,500 HP (75%) | 225 seconds |
| 2,000 HP (100%) | 300 seconds |

These values assume no additional casts, interruptions, or external HP restoration.

Recovery must be **linear and constant**, not proportional to the remaining recovery pool.

In other words, recovering the final 100 HP must be just as fast as recovering the first 100 HP.

### 1.4 Recovery during gameplay

Recovery must:

- Continue during combat.
- Continue when exploring, walking, or standing still.
- Work independently of proximity to enemies.
- Not require dealing damage, using consumables, or performing any actions.
- Be frame-rate independent.
- Pause when gameplay itself is paused.
- Not accumulate additional recovery during loading screens, main menus, or other non-gameplay states.
- Avoid granting large recovery bursts when gameplay resumes after a pause or loading screen.

**Recommended special rule:** Temporarily suspend recovery while actively charging Martyr's Bolt, then resume immediately when charging ends. This prevents the mod from interfering with the skill's HP sacrifice calculation or damage scaling. Combat outside the charging animation must not interrupt recovery.

Recovery should take 300 seconds of eligible gameplay to restore an amount equal to 100% of original maximum HP.

### 1.5 Multiple casts

Each Martyr's Bolt cast adds its actual HP expenditure to the existing pool.

Example:

Original maximum HP: 2,000

1. First cast sacrifices 600 HP.
2. `MaxHPToRecover = 600`.
3. Thirty seconds of recovery restore 200 HP.
4. `MaxHPToRecover = 400`.
5. Second cast sacrifices another 500 HP.
6. `MaxHPToRecover = 900`.
7. Recovery continues at 6.667 HP per second.
8. The remaining recovery takes approximately 135 seconds.

**New casts must not reset the timer, accelerate recovery, or overwrite the existing pool.**

The rate remains constant regardless of how many times the skill is used.

---

## 2. Critical requirement: Preserve ordinary Loss Gauge

This is the most important restriction.

Dragon's Dogma 2 normally reduces maximum HP through damage received during exploration and combat.

This ordinary Loss Gauge should still require resting or using an appropriate vanilla restoration item.

**The mod must never regenerate ordinary Loss Gauge damage.**

Example:

Original maximum HP: 2,000

The player suffers 300 points of ordinary Loss Gauge damage.

The effective maximum HP becomes 1,700.

The player then uses Martyr's Bolt and sacrifices another 1,000 maximum HP.

The effective maximum HP becomes 700.

The recovery pool contains 1,000 HP.

After 150 seconds:

- The mod has restored 500 maximum HP.
- The effective maximum HP is 1,200.
- The recovery pool contains 500 HP.

After another 150 seconds:

- The mod has restored the remaining 500 HP.
- The effective maximum HP is 1,700.
- The recovery pool is empty.
- The original 300 points of ordinary Loss Gauge remain.

**The mod must stop at 1,700 maximum HP, not 2,000.**

### Additional damage during recovery

Suppose the player suffers an additional 200 Loss Gauge damage while recovering from Martyr's Bolt.

That new damage must remain permanent under vanilla rules.

The mod continues restoring its outstanding Martyr's Bolt recovery pool, but it must not add the 200 ordinary damage to that pool.

The same principle applies to environmental damage, falls, status effects, and any unrelated HP-reducing mechanic.

The recovery pool represents an entitlement to restore only HP previously sacrificed through Martyr's Bolt.

---

## 3. Reset behavior

The recovery pool is temporary, runtime-only state.

It must not be serialized into a save file.

### 3.1 Quitting the game

When the player quits the game, the recovery pool is discarded.

Upon restarting the game:

```lua
MaxHPToRecover = 0
```

Any maximum HP still missing in the loaded save remains missing until restored through normal game mechanics.

Quitting must **not** automatically restore HP.

### 3.2 Resting

Successfully resting at an inn, home, or campsite restores HP according to vanilla rules.

When the rest is completed:

```lua
MaxHPToRecover = 0
```

Do not merely reset the pool because the player entered a campsite menu.

The reset should occur after successful rest or confirmed full restoration.

### 3.3 Death

When the Arisen dies:

```lua
MaxHPToRecover = 0
```

The mod must not restore HP as part of this reset.

If the player is revived, vanilla revival mechanics determine their new HP and maximum HP.

The previous recovery pool must not resume.

### 3.4 Full restoration through items

If an Allheal Elixir or another legitimate game mechanic completely restores the maximum HP, clear the remaining recovery pool.

The mod must not continue regenerating an already-restored sacrifice.

For partial external maximum-HP restoration, reconcile the remaining pool conservatively so that the same lost HP cannot be restored twice.

External restoration should consume the outstanding Martyr's Bolt recovery entitlement first for accounting purposes.

### 3.5 Loading a save

Loading a save should initialize a fresh recovery pool, including when loading a different save without restarting the game.

Do not carry pending recovery from an old save into a newly loaded character state.

Normal area transitions, however, must not reset the pool.

---

## 4. Technical implementation

### 4.1 Preferred framework

Use the Dragon's Dogma 2-compatible version of **REFramework**, with the gameplay implementation written in Lua.

Prefer a standalone Lua script under:

```text
Dragon's Dogma 2/
└── reframework/
    └── autorun/
        └── MartyrsBoltRecovery.lua
```

Avoid requiring additional frameworks unless necessary.

The first development step should be confirming compatibility with the user's installed game and REFramework version.

### 4.2 Known health API reference

A useful, publicly available October 2026 health API snapshot is:

https://github.com/D3athAn63l/DD2_Stuff/blob/main/research/baselines/health/2026-10-11/reference/HEALTH_API_REFERENCE.md

It reports the following character getters:

```lua
character:call("get_Hp()")
character:call("get_OriginalMaxHp()")
character:call("get_ReducedMaxHp()")
```

A reported way to obtain the health controller is:

```lua
local hit = character["<Hit>k__BackingField"]
```

The documented maximum HP setter is:

```lua
hit:set_ReducedMaxHp(value)
```

A documented way to obtain the player character is through:

```lua
sdk.get_managed_singleton("app.CharacterManager")
```

and its `get_ManualPlayer()` method.

These are useful starting points, **not guaranteed-compatible code for every game version**.

Verify that the methods still exist and behave correctly in the actual installed environment before relying on them.

Other relevant references:

- REFramework SDK documentation: https://refdocs.praydog.com/api/sdk.html
- General HP regeneration example: https://www.nexusmods.com/dragonsdogma2/mods/1622
- Another source implementation: https://github.com/D3athAn63l/DD2_Stuff/blob/main/mods/CompleteHealthRestoration/reframework/autorun/CompleteHealthRestoration.lua
- Martyr's Bolt damage-hooking reference: https://www.nexusmods.com/dragonsdogma2/mods/1827

Do not assume these unrelated mods already solve skill-specific HP attribution.

### 4.3 Detecting the actual HP cost

**This is the main reverse-engineering challenge.**

The implementation must find a reliable way to determine whether a Loss Gauge reduction was caused specifically by Martyr's Bolt.

Preferred investigation order:

1. Identify the internal skill or action state used by Martyr's Bolt.
2. Identify which method or gameplay operation applies its maximum-HP sacrifice.
3. Investigate whether REFramework can intercept the relevant operation using `sdk.hook()`.
4. Confirm the actual HP reduction attributable to the skill.
5. Record that reduction only once.
6. Validate the result with enemy damage occurring during the charge.

Potential implementation strategies include hooking a skill-specific HP-cost operation or monitoring the Loss Gauge while an independently verified Martyr's Bolt charging state is active.

**Simply watching for ReducedMaxHp to decrease is insufficient.** It would incorrectly include ordinary damage.

If polling is necessary, carefully account for other sources of Lost Gauge changes and avoid counting the mod's own restoration writes.

If reliable skill-cost attribution cannot be achieved, report that limitation rather than silently producing a general Loss Gauge restoration mod.

### 4.4 Health recovery

On each eligible update:

1. Obtain the player character.
2. Confirm the player is valid and alive.
3. Read original maximum HP.
4. Read current reduced maximum HP.
5. Check whether the recovery pool is greater than zero.
6. Confirm gameplay is active and Martyr's Bolt is not currently charging.
7. Calculate the appropriate recovery amount.
8. Limit recovery to the outstanding pool.
9. Limit recovery to the actual gap between reduced and original maximum HP.
10. Apply the new reduced maximum HP through the verified game API.
11. Read the resulting value back.
12. Subtract only the amount actually restored from the recovery pool.

Illustrative pseudocode:

```lua
local RecoveryDuration = 300
local MaxHPToRecover = 0

function RegisterMartyrSacrifice(amount)
    if amount <= 0 then
        return
    end

    MaxHPToRecover = MaxHPToRecover + amount
end

function UpdateRecovery(dt)
    if MaxHPToRecover <= 0 then return end
    if not IsGameplayActive() then return end
    if not IsPlayerAlive() then return end
    if IsMartyrBoltCharging() then return end

    local original = GetOriginalMaxHP()
    local reduced = GetReducedMaxHP()

    if not original or not reduced then return end
    if original <= 0 then return end

    local missing = math.max(0, original - reduced)

    local desired = math.min(
        MaxHPToRecover,
        missing,
        (original / RecoveryDuration) * dt
    )

    if desired <= 0 then return end

    -- Must use the actual verified game setter.
    SetReducedMaxHP(reduced + desired)

    local updated = GetReducedMaxHP()

    if not updated then return end

    local actualRestored = math.max(
        0,
        math.min(updated - reduced, desired)
    )

    MaxHPToRecover = math.max(
        0,
        MaxHPToRecover - actualRestored
    )
end
```

This is architectural pseudocode, not a complete working mod.

The game-specific helper functions must be implemented and verified.

### 4.5 HP versus maximum HP

The mod must restore **ReducedMaxHp**, not ordinary current HP.

Increasing maximum HP must not independently provide normal healing.

The player should still have to heal their actual HP through vanilla mechanics.

If modifying ReducedMaxHp indirectly changes current HP due to engine behavior, investigate and document that interaction.

Do not introduce unrelated healing as an intentional feature.

### 4.6 Timing and performance

The implementation should:

- Use elapsed time rather than a fixed amount per frame.
- Behave consistently at 30, 60, 120, 144, or higher FPS.
- Avoid integer rounding that causes excessively slow recovery or permanently stranded fractions.
- Handle temporary frame drops without enormous recovery jumps.
- Avoid excessive method calls or repeated reflection lookups.
- Cache stable type or method references where safe.
- Revalidate character objects after loading screens or scene transitions.
- Avoid creating memory leaks or continuously accumulating diagnostic data.

A roughly 0.1-second update interval is acceptable if recovery remains smooth and accurate.

### 4.7 Character stat changes

The recovery rate should be based on the currently valid original maximum HP.

If equipment, buffs, debuffs, or leveling change original maximum HP while a recovery pool exists:

- Do not treat the stat change as a Martyr's Bolt sacrifice.
- Do not automatically convert the change into additional recoverable HP.
- Preserve legitimate outstanding recovery as far as possible.
- Clamp restoration to valid engine limits.
- Recalculate the recovery rate using the new original maximum HP.

Store the recovery pool in absolute HP points to avoid misinterpreting percentage values after stat changes.

### 4.8 Recovery accounting and external changes

Because other effects may alter ReducedMaxHp while the mod is operating, recovery accounting must prevent double restoration.

The code should differentiate, as reliably as possible, between:

- HP sacrificed through Martyr's Bolt.
- Loss Gauge created by enemy or environmental damage.
- Maximum HP restored by this mod.
- Maximum HP restored through vanilla game mechanics.
- Changes to original maximum HP.

If another mechanic restores part or all of the missing maximum HP, reduce the outstanding recovery entitlement appropriately.

Never allow stale recovery debt to restore unrelated Loss Gauge damage later.

### 4.9 Mod compatibility

Only affect the player-controlled Arisen.

Do not modify pawn HP or regeneration.

Avoid conflicts with other REFramework mods where possible.

In particular, warn about mods that independently regenerate the Loss Gauge or continuously overwrite ReducedMaxHp.

Do not directly modify save files.

Do not change unrelated damage calculations or skill behavior.

---

## 5. Configuration and interface

The initial version should prioritize functionality over elaborate UI.

Suggested default configuration:

```lua
local Config = {
    Enabled = true,
    RecoveryDuration = 300,
    RecoverDuringCombat = true,
    RecoverWhileCharging = false,
    DebugLogging = false
}
```

An optional REFramework menu may display:

- Mod enabled/disabled.
- Recovery duration.
- Outstanding Martyr's Bolt recovery pool, in HP.
- Outstanding recovery as a percentage of original maximum HP.
- Estimated remaining recovery time.
- Current Martyr's Bolt detection state.
- Diagnostic information when debugging is enabled.

Recovery duration should default to 300 seconds.

Any saved configuration must be kept separate from the temporary recovery pool.

**Do not persist `MaxHPToRecover` across game sessions.**

No custom HUD, icons, sounds, notifications, or visual effects are required for version 1.0.

The vanilla HP bar should remain unchanged.

---

## 6. Edge cases

The mod should correctly handle the following situations.

**A. Player takes damage during recovery**

Ordinary Loss Gauge damage accumulates normally and is not added to the recovery pool.

**B. Player takes damage while charging Martyr's Bolt**

Only the actual HP sacrificed by the skill is registered. Damage from enemies must be excluded.

**C. Multiple Martyr's Bolt casts**

New expenditures accumulate in the existing recovery pool.

**D. Partial or canceled cast**

Register only the net amount of maximum HP actually sacrificed and retained.

**E. Player has almost no effective maximum HP remaining**

Do not prevent the original consequences of overusing Martyr's Bolt. Never increase the recovery rate to rescue the player.

**F. Player dies while recovery is pending**

Clear the pool and leave revival behavior to the game.

**G. Player rests**

Clear the pool after successful restoration.

**H. Player quits or reloads**

Discard pending recovery without refunding it.

**I. Player changes vocation**

Stop detecting new Martyr's Bolt costs, but continue recovering already accumulated debt during eligible gameplay.

**J. Maximum HP is completely restored externally**

Clear the remaining pool.

**K. Game is paused or loading**

Do not advance recovery and do not accumulate a large delayed update.

**L. Equipment or buffs modify maximum HP**

Do not register those changes as Martyr's Bolt sacrifices.

**M. Recovery pool reaches zero**

Stop writing to the health controller until new Martyr's Bolt expenditure occurs.

**N. REFramework temporarily cannot obtain a valid character or health controller**

Skip updates safely without crashing the game.

**O. The mod is disabled or reloaded mid-session**

Do not perform unwanted health restoration. Clearing the temporary pool on a script reload is acceptable.

---

## 7. Acceptance tests

Do not consider the mod functional merely because it loads without throwing errors.

Test actual gameplay behavior.

| Test | Expected result |
|---|---|
| Take ordinary damage without using Martyr's Bolt | No automatic maximum HP recovery |
| Use Martyr's Bolt at full health | Only the sacrificed maximum HP gradually recovers |
| Start with ordinary Loss Gauge, then cast Martyr's Bolt | Recovery stops when the original ordinary Loss Gauge remains |
| Cast Martyr's Bolt twice | Recovery pool accumulates both expenditures |
| Take damage during recovery | New ordinary Loss Gauge remains |
| Take damage during Martyr's Bolt charging | Damage is not incorrectly registered as skill sacrifice |
| Cancel or interrupt charging | Only net actual sacrifice is counted |
| Remain in combat | Recovery continues, except while actively charging |
| Pause the game for one minute | Recovery does not advance during the pause |
| Rest at a campsite | Outstanding pool resets |
| Use a full maximum-HP restoration item | Outstanding pool resets |
| Die during recovery | Outstanding pool resets |
| Quit and reload | Recovery does not resume |
| Change vocation | Existing debt still recovers, no new unrelated debt is registered |
| Change equipment affecting original maximum HP | No false Martyr's Bolt detection |
| Play at different FPS values | Equivalent recovery rate per active gameplay second |
| Recover the final small fraction of HP | Pool reaches zero without rounding-related permanent residue |

### Primary mathematical acceptance test

Assume:

```text
OriginalMaxHP = 2000

Initial ordinary Loss Gauge = 300
Martyr's Bolt sacrifice = 1000

MaxHPToRecover = 1000
ReducedMaxHP = 700
```

After 60 seconds:

```text
Restored by mod ≈ 400 HP

MaxHPToRecover ≈ 600
ReducedMaxHP ≈ 1100
```

After 150 seconds total:

```text
Restored by mod ≈ 1000 HP

MaxHPToRecover = 0
ReducedMaxHP ≈ 1700
```

The mod must not restore the remaining 300 HP.

This scenario is a mandatory acceptance test.

---

## 8. Development strategy

Prioritize a small and reliable implementation. Avoid spending excessive time building optional features before confirming the core mechanic is technically possible.

### Phase 1 — Feasibility investigation

Investigate whether REFramework can:

1. Reliably identify the Martyr's Bolt charging state.
2. Identify or isolate its maximum HP cost.
3. Read and modify the Arisen's ReducedMaxHp.
4. Distinguish skill sacrifice from damage received during charging.

Build a diagnostic proof of concept that logs skill activation and observed HP changes.

Do not implement the complete regeneration system until reliable attribution is demonstrated.

If specific identification cannot be achieved, explain the technical obstacle and possible alternatives.

### Phase 2 — Minimum viable mod

Implement:

- Martyr's Bolt cost detection.
- The single recovery pool.
- Fixed 300-second full-maximum-HP recovery rate.
- Ordinary Loss Gauge preservation.
- Basic runtime resets.

No custom interface is required.

### Phase 3 — Reliability

Implement and test:

- Multiple casts.
- Interrupted charging.
- Ordinary damage during charging.
- Partial and full external restorations.
- Rest, death, quitting, and reloading.
- Frame-rate independence.
- Character and scene transitions.

### Phase 4 — Optional polish

Only after the core mechanics are verified:

- REFramework settings menu.
- Debug logging toggle.
- Recovery statistics.
- Configuration persistence.
- Simple installation package.

---

## 9. Expected deliverables

Provide:

1. A functional REFramework Lua mod implementing these mechanics.
2. The exact installation instructions.
3. The required dependencies and compatible versions.
4. A brief technical explanation of the Martyr's Bolt detection method.
5. A changelog or documentation of known limitations.
6. Instructions for safely uninstalling the mod.
7. Diagnostic logging that can be enabled when troubleshooting.
8. An account of which acceptance tests have actually been performed in-game versus simulated.

Keep the distribution as simple as possible, preferably a standalone Lua file with optional configuration support.

Do not claim in-game verification based solely on static code inspection or simulated tests.

---

## 10. Explicit exclusions

The mod must **not**:

- Regenerate all Loss Gauge damage.
- Regenerate ordinary current HP.
- Automatically heal pawns.
- Remove Martyr's Bolt's initial HP cost.
- Increase Martyr's Bolt's damage.
- Change Martyr's Bolt's cooldown or charge speed.
- Require killing or damaging enemies to regenerate.
- Restore HP merely because the player quits.
- Make death or resting grant additional recovery beyond vanilla behavior.
- Introduce unnecessary HUD elements or effects.
- Persist recovery debt into a save file.
- Modify unrelated player statistics.
- Use approximate skill detection that silently classifies ordinary damage as recoverable.

---

## 11. Definition of done

The project is complete when the player can use Martyr's Bolt, suffer its full original HP penalty, and have **only that skill's sacrificed maximum HP** gradually restored at a rate of 100% original maximum HP per 300 seconds.

The recovery must remain accurate across multiple casts and ordinary damage events.

Any maximum HP lost through normal gameplay must remain lost until restored through normal game mechanics.

The result should preserve Martyr's Bolt as an extremely powerful, high-risk skill while eliminating the requirement to rest immediately after every use.

**Design philosophy:** Martyr's Bolt should create a serious temporary vulnerability, not an effectively permanent penalty that forces the player to abandon their expedition.

Prioritize correct HP attribution, stability, minimal complexity, and preservation of vanilla mechanics over additional features.