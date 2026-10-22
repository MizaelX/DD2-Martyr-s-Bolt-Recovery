-- Offline simulation tests for MartyrsBoltRecovery.lua.
-- Runs the real mod source against a stubbed REFramework + fake Arisen. Expects global MOD_SRC.

local results = {pass = 0, fail = 0}
local function check(name, cond, detail)
    if cond then results.pass = results.pass + 1; print("PASS  " .. name)
    else results.fail = results.fail + 1; print("FAIL  " .. name .. "  " .. tostring(detail or "")) end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 0.5) end

local function f32(x) -- emulate float32 storage of ReducedMaxHp
    if string.pack then return (string.unpack("f", string.pack("f", x))) end
    return x
end

local function new_world(saved_config)
    local W = {clock = 0, paused = false, battle = 0, node = "Locomotion.NormalLocomotion", next_addr = 1000}
    local function obj(t, handlers)
        t.call = function(self, name, ...) local h = handlers[name]; if not h then error("no method " .. name) end; return h(self, ...) end
        return t
    end
    function W.new_player(orig)
        W.next_addr = W.next_addr + 1
        local hit = obj({hp = orig, red = orig, orig = orig, addr = W.next_addr}, {
            ["get_Hp()"] = function(s) return s.hp end,
            ["get_ReducedMaxHp()"] = function(s) return s.red end,
            ["get_OriginalMaxHp()"] = function(s) return s.orig end,
            ["set_ReducedMaxHp(System.Single)"] = function(s, v) s.red = f32(math.min(v, s.orig)); W.writes = (W.writes or 0) + 1 end,
        })
        hit.get_address = function(s) return s.addr end
        local ctrl = obj({counter = 0}, {["get_SpritArrowSacrificedHitPoint()"] = function(s) return s.counter end})
        local human = obj({}, {["get_Job08ActionCtrl()"] = function() return ctrl end})
        local fsm = obj({}, {["getCurrentNodeName"] = function() return W.node end})
        local go = obj({}, {["getComponent(System.Type)"] = function() return fsm end})
        local char = obj({}, {
            ["get_Valid()"] = function() return true end,
            ["get_Human()"] = function() return human end,
            ["get_GameObject()"] = function() return go end,
            ["get_Hit()"] = function() return hit end,
        })
        char.get_field = function(_, n) if n == "<Hit>k__BackingField" then return hit end end
        W.char, W.hit, W.ctrl = char, hit, ctrl
        return hit
    end
    local managers = {
        ["app.CharacterManager"] = obj({}, {["get_ManualPlayer()"] = function() return W.char end}),
        ["app.GuiManager"] = obj({}, {["isPausedGUI()"] = function() return W.paused end}),
        ["app.BattleManager"] = obj({}, {["get_BattleMode()"] = function() return W.battle end}),
    }
    _G.sdk = {
        typeof = function(n) return n end,
        get_managed_singleton = function(n) return managers[n] end,
        find_type_definition = function(n)
            if n == "app.Job08SpritArrow" then return {get_method = function(_, m) return m end} end
        end,
        hook = function(m, pre, post) W.pre, W.post = pre, post end,
    }
    local frame_fn
    _G.re = {on_frame = function(f) frame_fn = f end, on_draw_ui = function() end}
    _G.imgui = {}
    _G.json = {load_file = function() return saved_config end, dump_file = function() return true end}
    _G.log = {info = function() end}
    _G.thread = nil
    os.clock = function() return W.clock end
    _G.MBR_TEST = {}
    assert(load(MOD_SRC, "MartyrsBoltRecovery.lua"))()
    W.M = _G.MBR_TEST

    function W.frames(seconds, fps)
        fps = fps or 60
        local n = math.floor(seconds * fps + 0.5)
        for _ = 1, n do W.clock = W.clock + 1 / fps; frame_fn() end
    end
    -- One processSacrifice call on the Arisen.
    function W.sac_tick(x)
        W.pre({})
        local h = W.hit
        local before = h.red
        h.red = f32(math.max(1, h.red - x)); h.hp = math.min(h.hp, h.red)
        W.ctrl.counter = W.ctrl.counter + (before - h.red)
        W.post(nil)
    end
    -- Full charge sacrificing `total` in ~5 HP ticks, with frames in between; optional hit mid-charge.
    function W.charge(total, hit_at, hit_dmg)
        W.node = "Job08.Job08_SkillAttack.Job08_CS12.Job08_ReadySpiritArrow"
        W.ctrl.counter = 0
        local done, step = 0, 5
        while done < total - 1e-9 do
            local x = math.min(step, total - done)
            W.sac_tick(x); done = done + x
            if hit_at and done >= hit_at then W.damage(hit_dmg); hit_at = nil end
            W.clock = W.clock + 1 / 240; frame_fn()
        end
        W.node = "Job08.Job08_SkillAttack.Job08_CS12.Job08_ShootSpiritArrow"; W.frames(0.2)
        W.node = "Locomotion.NormalLocomotion"; W.frames(0.4)
    end
    -- Ordinary damage: 10% of damage becomes Loss Gauge (as measured in game).
    function W.damage(d)
        local h = W.hit
        h.hp = math.max(0, h.hp - d); h.red = f32(h.red - d * 0.1); h.hp = math.min(h.hp, h.red)
    end
    function W.lost() return W.hit.orig - W.hit.red end
    W.new_player(2000)
    W.frames(0.5)
    return W
end

-- 1. Ordinary damage is never restored
do
    local W = new_world()
    W.damage(1000) -- 100 Loss Gauge
    W.frames(300)
    check("ordinary damage: no max HP recovery", near(W.hit.red, 1900, 0.01), W.hit.red)
    check("ordinary damage: no current HP healing", W.hit.hp <= 1000 + 1e-6, W.hit.hp)
end

-- 2. Cast at full health: only the sacrifice recovers, at 100%/300 s
do
    local W = new_world()
    W.charge(1000)
    check("cast registers actual sacrifice", near(W.M.state.pool, 1000, 0.01) or W.M.state.pool > 995, W.M.state.pool)
    local red0 = W.hit.red
    W.frames(60)
    check("60 s restores ~400 HP (6.667 HP/s)", near(W.hit.red - red0, 400, 2), W.hit.red - red0)
    W.frames(91)
    check("cast fully recovered after ~150 s", near(W.hit.red, 2000, 0.01), W.hit.red)
    check("pool exactly zero, no residue", W.M.state.pool == 0, W.M.state.pool)
    local hp = W.hit.hp
    W.frames(10)
    check("recovery does not heal current HP", W.hit.hp == hp, W.hit.hp)
end

-- 3. PRIMARY ACCEPTANCE: 300 ordinary + 1000 sacrifice
do
    local W = new_world()
    W.damage(3000)        -- 300 Loss Gauge
    W.hit.hp = W.hit.red  -- player healed current HP with vanilla means
    check("setup: red 1700", near(W.hit.red, 1700, 0.01), W.hit.red)
    W.charge(1000)
    check("setup: red ~700, pool ~1000 (minus 0.4 s post-shot recovery)", near(W.hit.red + W.M.state.pool, 1700, 0.01) and near(W.M.state.pool, 1000, 3),
        W.hit.red .. " / " .. W.M.state.pool)
    W.frames(60)
    check("primary: after 60 s red ~1100", near(W.hit.red, 1100, 3), W.hit.red)
    check("primary: after 60 s pool ~600", near(W.M.state.pool, 600, 3), W.M.state.pool)
    W.frames(91)
    check("primary: after 150 s red ~1700", near(W.hit.red, 1700, 0.01), W.hit.red)
    check("primary: pool = 0", W.M.state.pool == 0, W.M.state.pool)
    W.frames(300)
    check("primary: ordinary 300 Loss Gauge remains", near(W.hit.red, 1700, 0.01), W.hit.red)
end

-- 4. Multiple casts accumulate; no timer reset or acceleration
do
    local W = new_world()
    W.charge(600)
    W.frames(30)
    check("multi: 30 s restored ~200", near(W.M.state.pool, 400, 3), W.M.state.pool)
    W.charge(500)
    check("multi: pool ~900", near(W.M.state.pool, 900, 6), W.M.state.pool)
    W.frames(134)
    check("multi: not done at 134 s", W.M.state.pool > 0, W.M.state.pool)
    W.frames(3)
    check("multi: done by ~137 s", W.M.state.pool == 0 and near(W.hit.red, 2000, 0.01), W.M.state.pool .. " " .. W.hit.red)
end

-- 5. Damage during recovery stays lost
do
    local W = new_world()
    W.charge(1000)
    W.frames(30)
    W.hit.hp = W.hit.red
    W.damage(500) -- 50 Loss Gauge mid-recovery
    W.frames(300)
    check("damage during recovery remains", near(W.hit.red, 1950, 0.01), W.hit.red)
end

-- 6. Damage while charging is not counted as sacrifice
do
    local W = new_world()
    W.charge(800, 400, 500) -- hit for 500 (50 Loss Gauge) halfway through the charge
    check("hit while charging: pool only counts sacrifice", near(W.M.state.pool, 800, 3), W.M.state.pool)
    W.frames(400)
    check("hit while charging: its 50 Loss Gauge remains", near(W.hit.red, 1950, 0.01), W.hit.red)
end

-- 7. A ReducedMaxHp drop during processSacrifice that the game counter does not confirm (concurrent damage) is ignored
do
    local W = new_world()
    W.pre({}); W.damage(500); W.post(nil)
    check("unconfirmed drop / concurrent damage ignored", W.M.state.pool == 0, W.M.state.pool)
end

-- 8. Pause and long frame gaps grant nothing
do
    local W = new_world()
    W.charge(1000)
    local red0 = W.hit.red
    W.paused = true; W.frames(60); W.paused = false
    check("pause: no recovery while paused", W.hit.red == red0, W.hit.red - red0)
    W.frames(1)
    check("pause: no burst after unpause", W.hit.red - red0 < 8, W.hit.red - red0)
    local r1 = W.hit.red
    W.clock = W.clock + 30; W.frames(0.02)  -- 30 s loading hitch
    check("loading gap: no burst", W.hit.red - r1 < 1, W.hit.red - r1)
end

-- 9. Charging suspends recovery
do
    local W = new_world()
    W.charge(1000)
    W.frames(10)
    W.node = "Job08.Job08_SkillAttack.Job08_CS12.Job08_ReadySpiritArrow"
    local r0 = W.hit.red
    W.frames(5)
    check("charging: recovery suspended", W.hit.red == r0, W.hit.red - r0)
    W.node = "Locomotion.NormalLocomotion"
    W.frames(1)
    check("charging: resumes after", W.hit.red > r0, W.hit.red - r0)
end

-- 10. Rest / full restore clears the pool
do
    local W = new_world()
    W.charge(1000)
    W.hit.red = 2000; W.hit.hp = 2000 -- rest
    W.frames(0.2)
    check("rest: pool cleared", W.M.state.pool == 0, W.M.state.pool)
    W.damage(1000)
    W.frames(300)
    check("rest: later ordinary damage not restored", near(W.hit.red, 1900, 0.01), W.hit.red)
end

-- 11. Death clears the pool; revive restores nothing extra
do
    local W = new_world()
    W.charge(1000)
    W.hit.hp = 0; W.frames(1)
    check("death: pool cleared", W.M.state.pool == 0, W.M.state.pool)
    W.hit.hp = 500; W.hit.red = 1200 -- hypothetical partial revive
    W.frames(300)
    check("death: nothing restored after revive", near(W.hit.red, 1200, 0.01), W.hit.red)
end

-- 12. Partial external restoration consumes entitlement first
do
    local W = new_world()
    W.damage(1000); W.hit.hp = W.hit.red -- 100 ordinary
    W.charge(1000)          -- pool ~1000, red ~900
    local p_before = W.M.state.pool
    W.hit.red = W.hit.red + 300 -- item restores 300 max HP
    W.frames(0.1)
    check("partial restore: pool reduced by 300", near(p_before - W.M.state.pool, 300, 1.0), p_before - W.M.state.pool)
    W.frames(400)
    check("partial restore: ordinary 100 still lost", near(W.hit.red, 1900, 0.01), W.hit.red)
end

-- 13. Loading a save (new health controller) resets; same object returning keeps the pool
do
    local W = new_world()
    W.charge(1000)
    local keep = W.M.state.pool
    local saved_char = W.char
    W.char = nil; W.frames(2)      -- area load: handle temporarily unavailable
    W.char = saved_char; W.frames(0.1)
    check("area transition (same character): pool kept", W.M.state.pool > keep - 10 and W.M.state.pool > 0, W.M.state.pool)
    W.char = nil; W.frames(2)
    W.new_player(2000); W.hit.red = 1000; W.hit.hp = 1000 -- loaded save missing 1000 max HP
    W.frames(300)
    check("save load: pool reset, loaded loss stays", W.M.state.pool == 0 and near(W.hit.red, 1000, 0.01), W.M.state.pool .. " " .. W.hit.red)
end

-- 14. Original max HP change is not a sacrifice; pool preserved, rate follows new max
do
    local W = new_world()
    W.charge(600)
    local p0 = W.M.state.pool
    W.hit.orig = 2300 -- equipment +300 original max HP
    W.frames(0.1)
    check("stat change: no new debt registered", W.M.state.pool <= p0 + 1e-6, W.M.state.pool - p0)
    W.frames(60)
    check("stat change: pool preserved and recovering at new rate (~7.67 HP/s)",
        near(p0 - W.M.state.pool, 2300 / 300 * 60, 5), p0 - W.M.state.pool)
end

-- 15. Frame-rate independence
do
    local res = {}
    for _, fps in ipairs({30, 60, 144, 240}) do
        local W = new_world()
        W.charge(1500)
        local r0 = W.hit.red
        W.frames(60, fps)
        res[#res + 1] = W.hit.red - r0
    end
    local lo, hi = math.min(table.unpack(res)), math.max(table.unpack(res))
    check("fps independence 30/60/144/240 within 1%", (hi - lo) / hi < 0.01, table.concat(res, ", "))
end

-- 16. Disabled mod does nothing
do
    local W = new_world()
    W.M.Config.Enabled = false
    W.charge(1000)
    W.frames(300)
    check("disabled: no registration or recovery", W.M.state.pool == 0 and near(W.hit.red, 1000, 0.01), W.hit.red)
end

-- 17. Bolt that kills: drains to 1, dies
do
    local W = new_world()
    W.charge(1999)
    W.hit.hp = 0; W.frames(1)
    check("lethal cast: pool reset on death", W.M.state.pool == 0, W.M.state.pool)
end

-- 18. Combat: no recovery in battle by default; the option re-enables it
do
    local W = new_world()
    check("default: RecoverDuringCombat off", W.M.Config.RecoverDuringCombat == false, W.M.Config.RecoverDuringCombat)
    W.charge(1000)
    W.battle = 1
    local r0 = W.hit.red
    W.frames(30)
    check("combat (default): recovery paused in battle", W.hit.red == r0, W.hit.red - r0)
    W.battle = 0
    W.frames(1)
    check("combat (default): resumes after battle", W.hit.red > r0, W.hit.red - r0)
    W.M.Config.RecoverDuringCombat = true
    W.battle = 1
    local r1 = W.hit.red
    W.frames(10)
    check("combat (option on): recovers in battle", near(W.hit.red - r1, 2000 / 300 * 10, 1), W.hit.red - r1)
end

-- 19. Saved settings are honored; out-of-range duration is clamped to the menu range
do
    local W = new_world({RecoverDuringCombat = true, RecoveryDuration = 600, DebugLogging = false})
    check("saved settings: combat option kept", W.M.Config.RecoverDuringCombat == true, W.M.Config.RecoverDuringCombat)
    check("saved settings: duration kept", W.M.Config.RecoveryDuration == 600, W.M.Config.RecoveryDuration)
    W = new_world({RecoveryDuration = 1})
    check("saved settings: duration 1 clamped to 10", W.M.Config.RecoveryDuration == 10, W.M.Config.RecoveryDuration)
    W = new_world({RecoveryDuration = "fast", Enabled = 5})
    check("saved settings: wrong types fall back to defaults",
        W.M.Config.RecoveryDuration == 300 and W.M.Config.Enabled == true, tostring(W.M.Config.RecoveryDuration))
end

print(string.format("\n%d passed, %d failed", results.pass, results.fail))
RESULT_FAIL = results.fail
