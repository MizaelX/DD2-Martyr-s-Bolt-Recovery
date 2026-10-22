-- Martyr's Bolt Recovery v1.0.0 (Dragon's Dogma 2 / REFramework)
-- Gradually restores ONLY the maximum HP (Loss Gauge) sacrificed by the Magick Archer's Martyr's Bolt.
-- Ordinary Loss Gauge damage is never restored. The recovery pool is runtime-only and never saved.
--
-- Detection: app.Job08SpritArrow.processSacrifice() is the routine that drains max HP while charging
-- Martyr's Bolt (HumanCustomSkillID.Job08_SpiritArrow). Each call is measured as
--   min(drop of the Arisen's ReducedMaxHp during the call,
--       increase of the game's own Job08ActionController.SpritArrowSacrificedHitPoint during the call)
-- so enemy damage and anything else outside that routine are never counted.

local sdk, re, imgui, json, log, thread = sdk, re, imgui, json, log, thread

local VERSION = "1.0.0"
local CONFIG_FILE = "MartyrsBoltRecovery.json"     -- reframework/data/
local LOG_FILE = "MartyrsBoltRecovery.log"         -- reframework/data/, only when DebugLogging
local EPS = 1e-3

---------------------------------------------------------------------------
-- Configuration (persisted; the recovery pool is NOT part of it)
---------------------------------------------------------------------------
local DEFAULTS = {
    Enabled = true,
    RecoveryDuration = 300,      -- seconds to restore 100% of original max HP
    RecoverDuringCombat = false,
    RecoverWhileCharging = false,
    DebugLogging = false,
}
local Config = {}

local function load_config()
    local ok, data = pcall(json.load_file, CONFIG_FILE)
    if not ok or type(data) ~= "table" then data = {} end
    for k, v in pairs(DEFAULTS) do
        if type(data[k]) == type(v) then Config[k] = data[k] else Config[k] = v end
    end
    if Config.RecoveryDuration ~= Config.RecoveryDuration then
        Config.RecoveryDuration = DEFAULTS.RecoveryDuration
    end
    -- Same range as the menu, so a hand-edited file cannot make recovery near-instant.
    Config.RecoveryDuration = math.max(10, math.min(3600, Config.RecoveryDuration))
end

local function save_config()
    pcall(json.dump_file, CONFIG_FILE, Config, 4)
end

load_config()

---------------------------------------------------------------------------
-- Diagnostics
---------------------------------------------------------------------------
local MAX_LOG_BYTES = 1024 * 1024
local log_file = nil
local function try_size(f)
    local ok, size = pcall(function() return f:seek("end") end)
    if ok then return size end
    return nil
end
local function dlog(msg)
    if not Config.DebugLogging then return end
    local line = string.format("[%s] %s", os.date("%H:%M:%S"), msg)
    if not log_file then
        local ok, f = pcall(io.open, LOG_FILE, "a")
        if ok and f then
            -- Start a fresh file once the previous sessions' log exceeds 1 MB.
            local size = try_size(f)
            if size and size > MAX_LOG_BYTES then
                pcall(function() f:close() end)
                ok, f = pcall(io.open, LOG_FILE, "w")
            end
            if ok and f then log_file = f end
        end
    end
    if log_file then pcall(function() log_file:write(line, "\n"); log_file:flush() end) end
    pcall(log.info, "[MartyrsBoltRecovery] " .. line)
end

---------------------------------------------------------------------------
-- Core accounting (pure; operates on numbers only)
---------------------------------------------------------------------------
local Core = {}

function Core.new_state()
    return {
        pool = 0,               -- MaxHPToRecover, in HP points
        last_red = nil,         -- ReducedMaxHp after our last observation/write
        last_orig = nil,
        registered_total = 0, restored_total = 0, external_total = 0,
        last_reset = "none", resets = 0,
    }
end

function Core.reset(st, reason)
    if st.pool > 0 then dlog(string.format("RESET (%s): discarded %.2f HP of pending recovery", reason, st.pool)) end
    st.pool = 0
    st.last_reset = reason
    st.resets = st.resets + 1
end

function Core.register(st, amount)
    if type(amount) ~= "number" or amount ~= amount or amount <= 0 then return 0 end
    st.pool = st.pool + amount
    st.registered_total = st.registered_total + amount
    return amount
end

-- Reconcile the pool with the current health state before recovering.
-- snap = {valid, hp, red, orig}
function Core.observe(st, snap)
    if not snap.valid then return end
    local hp, red, orig = snap.hp, snap.red, snap.orig
    if hp <= 0 then
        if st.pool > 0 then Core.reset(st, "death") end
        st.last_red, st.last_orig = red, orig
        return
    end
    local gap = math.max(0, orig - red)
    if gap <= EPS and st.pool > 0 then
        Core.reset(st, "maximum HP fully restored (rest / item / revive)")
    end
    -- Any increase we did not write is an external restoration; it consumes the entitlement first.
    -- Skipped when original max HP itself changed (equipment, buffs, level), which can rescale the gauge.
    if st.pool > 0 and st.last_red and red > st.last_red + EPS and st.last_orig and math.abs(orig - st.last_orig) <= EPS then
        local inc = red - st.last_red
        local used = math.min(inc, st.pool)
        st.pool = st.pool - used
        st.external_total = st.external_total + used
        dlog(string.format("EXTERNAL restoration +%.2f max HP; pool reduced by %.2f -> %.2f", inc, used, st.pool))
    end
    -- The entitlement can never exceed the HP actually missing.
    if st.pool > gap then st.pool = gap end
    if st.pool < EPS then st.pool = 0 end
    st.last_red, st.last_orig = red, orig
end

-- Returns target ReducedMaxHp and the planned amount, or nil when nothing should be written.
-- snap = {valid, hp, red, orig, paused, charging, in_battle}
function Core.plan(st, cfg, snap, dt)
    if st.pool <= 0 or not cfg.Enabled or not snap.valid then return nil end
    if snap.paused or snap.hp <= 0 or dt <= 0 then return nil end
    if snap.charging and not cfg.RecoverWhileCharging then return nil end
    if snap.in_battle and not cfg.RecoverDuringCombat then return nil end
    if snap.orig <= 0 then return nil end
    local gap = snap.orig - snap.red
    local amount = math.min(st.pool, gap, snap.orig / cfg.RecoveryDuration * dt)
    if amount <= 0 then return nil end
    return snap.red + amount, amount
end

-- Account for what a write actually achieved (read back from the game).
-- The exact readback delta is charged to the pool, so float32 rounding of ReducedMaxHp never
-- accumulates: the recovery ceiling (red + pool) stays fixed and the last write lands on it.
function Core.applied(st, before_red, after_red, planned)
    local actual = math.max(0, after_red - before_red)
    st.pool = math.max(0, st.pool - actual)
    if st.pool < 0.01 then st.pool = 0 end
    st.restored_total = st.restored_total + actual
    st.last_red = after_red
    return actual
end

---------------------------------------------------------------------------
-- Game access
---------------------------------------------------------------------------
local function try(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end

local function call(obj, name, ...)
    if obj == nil then return nil end
    local args = {...}
    return try(function() return obj:call(name, table.unpack(args)) end)
end

local function num(v)
    if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then return v end
    return nil
end

local fsm_typeof = try(sdk.typeof, "via.motion.MotionFsm2")

local P = {          -- current Arisen handles, refreshed every frame
    char = nil, hit = nil, addr = nil, human = nil, fsm = nil,
    known_addr = nil, -- last health controller seen; survives brief loss of the handle (area loads)
}

local state = Core.new_state()
local runtime = {
    hook_ok = false, hook_error = nil,
    last_sacrifice_clock = -100,
    cast_total = 0, last_cast = 0, casts = 0,
    charging = false, counter_seen = false, counter_missing = 0,
    writes = 0, write_failures = 0,
}

local function read_health()
    local hit = P.hit
    if not hit then return nil end
    local hp, red, orig = num(call(hit, "get_Hp()")), num(call(hit, "get_ReducedMaxHp()")), num(call(hit, "get_OriginalMaxHp()"))
    if not hp or not red or not orig then return nil end
    return hp, red, orig
end

local function read_counter()
    local ctrl = call(P.human, "get_Job08ActionCtrl()")
    return num(call(ctrl, "get_SpritArrowSacrificedHitPoint()"))
end

local function refresh_player()
    local cm = try(sdk.get_managed_singleton, "app.CharacterManager")
    local char = call(cm, "get_ManualPlayer()")
    if char ~= nil and call(char, "get_Valid()") == false then char = nil end
    if char == nil then
        P.char, P.hit, P.addr, P.human, P.fsm = nil, nil, nil, nil, nil
        return false
    end
    local hit = try(function() return char:get_field("<Hit>k__BackingField") end) or call(char, "get_Hit()")
    local addr = hit and try(function() return hit:get_address() end) or nil
    if addr ~= P.addr then P.fsm = nil end
    if addr ~= nil and addr ~= P.known_addr then
        if P.known_addr ~= nil then
            -- A different Arisen health controller means a save was loaded (or the character rebuilt).
            Core.reset(state, "character reloaded")
            state.last_red, state.last_orig = nil, nil
        end
        P.known_addr = addr
    end
    P.char, P.hit, P.addr = char, hit, addr
    P.human = call(char, "get_Human()")
    if P.fsm == nil and fsm_typeof then
        P.fsm = call(call(char, "get_GameObject()"), "getComponent(System.Type)", fsm_typeof)
    end
    return hit ~= nil
end

local function is_charging(now)
    if now - runtime.last_sacrifice_clock < 0.3 then return true end
    local node = call(P.fsm, "getCurrentNodeName", 0)
    return type(node) == "string" and node:find("SpiritArrow", 1, true) ~= nil
end

local function is_paused()
    return call(try(sdk.get_managed_singleton, "app.GuiManager"), "isPausedGUI()") == true
end

local function in_battle()
    local mode = call(try(sdk.get_managed_singleton, "app.BattleManager"), "get_BattleMode()")
    if type(mode) == "number" then return mode ~= 0 end
    return mode == true
end

local function write_reduced_max(target)
    local ok = pcall(function() P.hit:call("set_ReducedMaxHp(System.Single)", target) end)
    if not ok then ok = pcall(function() P.hit:set_ReducedMaxHp(target) end) end
    return ok
end

---------------------------------------------------------------------------
-- Martyr's Bolt sacrifice hook
---------------------------------------------------------------------------
local fallback_pre = {}
local function store_pre(v)
    local st = thread and thread.get_hook_storage and try(thread.get_hook_storage)
    if st then st.mbr_pre = v else fallback_pre[#fallback_pre + 1] = v end
end
local function take_pre()
    local st = thread and thread.get_hook_storage and try(thread.get_hook_storage)
    if st then local v = st.mbr_pre; st.mbr_pre = nil; return v end
    return table.remove(fallback_pre)
end

local function on_sacrifice_pre(args)
    if not Config.Enabled or not P.hit then store_pre(false); return end
    local _, red = read_health()
    store_pre({red = red, counter = read_counter()})
end

local function on_sacrifice_post(retval)
    local pre = take_pre()
    if not pre or not pre.red then return retval end
    local _, red = read_health()
    if not red then return retval end
    local drop = pre.red - red
    if drop <= EPS then return retval end
    local amount = drop
    local counter = read_counter()
    if counter and pre.counter then
        runtime.counter_seen = true
        -- The counter restarts at 0 for each cast, so a decrease means "restarted, then advanced to counter".
        local advanced = counter >= pre.counter and (counter - pre.counter) or counter
        if advanced <= EPS then return retval end   -- the drop was not the skill's (e.g. concurrent damage)
        amount = math.min(drop, advanced)
    else
        runtime.counter_missing = runtime.counter_missing + 1
    end
    Core.register(state, amount)
    state.last_red = red
    runtime.cast_total = runtime.cast_total + amount
    runtime.last_sacrifice_clock = os.clock()
    return retval
end

do
    local td = sdk.find_type_definition("app.Job08SpritArrow")
    local m = td and try(function() return td:get_method("processSacrifice") end)
    if m then
        local ok, err = pcall(sdk.hook, m, on_sacrifice_pre, on_sacrifice_post)
        runtime.hook_ok = ok
        if not ok then runtime.hook_error = tostring(err) end
    else
        runtime.hook_error = "app.Job08SpritArrow.processSacrifice not found (game update?)"
    end
    if not runtime.hook_ok then
        pcall(log.info, "[MartyrsBoltRecovery] Detection hook FAILED: " .. tostring(runtime.hook_error))
    end
end

---------------------------------------------------------------------------
-- Update loop
---------------------------------------------------------------------------
local UPDATE_INTERVAL = 0.1
local MAX_FRAME_GAP = 1.0      -- longer gaps (loading, alt-tab hitches) grant nothing
local prev_clock = os.clock()
local accum = 0
local last_status_log = 0

local function update()
    local now = os.clock()
    local frame_dt = now - prev_clock
    prev_clock = now
    if not refresh_player() then accum = 0; return end

    local hp, red, orig = read_health()
    if not hp then accum = 0; return end

    local charging = is_charging(now)
    if runtime.charging and not charging then
        runtime.casts = runtime.casts + 1
        runtime.last_cast = runtime.cast_total
        dlog(string.format("CAST finished: sacrificed %.2f max HP; pool now %.2f (red %.2f / orig %.2f)",
            runtime.cast_total, state.pool, red, orig))
        runtime.cast_total = 0
    end
    runtime.charging = charging

    local paused = is_paused()
    if frame_dt <= 0 or frame_dt > MAX_FRAME_GAP or paused then
        accum = 0
    else
        accum = accum + frame_dt
    end

    local snap = {valid = true, hp = hp, red = red, orig = orig, paused = paused, charging = charging, in_battle = false}
    Core.observe(state, snap)

    if not Config.Enabled then
        if state.pool > 0 then Core.reset(state, "mod disabled") end
        accum = 0
        return
    end
    if accum < UPDATE_INTERVAL then return end
    local dt = math.min(accum, 0.25)
    accum = 0
    if state.pool <= 0 then return end

    if not Config.RecoverDuringCombat then snap.in_battle = in_battle() end
    local target, planned = Core.plan(state, Config, snap, dt)
    if not target then return end
    if write_reduced_max(target) then
        runtime.writes = runtime.writes + 1
        local _, after = read_health()
        Core.applied(state, red, after or red, planned)
    else
        runtime.write_failures = runtime.write_failures + 1
        if runtime.write_failures == 1 then dlog("WRITE FAILED: set_ReducedMaxHp unavailable") end
    end

    if Config.DebugLogging and now - last_status_log > 5 then
        last_status_log = now
        local _, r2 = read_health()
        dlog(string.format("STATUS pool %.2f red %.2f orig %.2f restored_total %.2f", state.pool, r2 or -1, orig, state.restored_total))
    end
end

re.on_frame(function()
    local ok, err = pcall(update)
    if not ok and Config.DebugLogging then dlog("update error: " .. tostring(err)) end
end)

---------------------------------------------------------------------------
-- REFramework menu
---------------------------------------------------------------------------
re.on_draw_ui(function()
    if not imgui.tree_node("Martyr's Bolt Recovery v" .. VERSION) then return end
    local dirty, changed, v = false, false, nil

    changed, v = imgui.checkbox("Enabled", Config.Enabled); if changed then Config.Enabled = v; dirty = true end
    changed, v = imgui.drag_float("Recovery duration (s for 100% max HP)", Config.RecoveryDuration, 1, 10, 3600, "%.0f")
    if changed then Config.RecoveryDuration = math.max(10, math.min(3600, v)); dirty = true end
    changed, v = imgui.checkbox("Recover during combat", Config.RecoverDuringCombat); if changed then Config.RecoverDuringCombat = v; dirty = true end
    changed, v = imgui.checkbox("Recover while charging Martyr's Bolt", Config.RecoverWhileCharging); if changed then Config.RecoverWhileCharging = v; dirty = true end
    changed, v = imgui.checkbox("Debug logging (reframework/data/" .. LOG_FILE .. ")", Config.DebugLogging); if changed then Config.DebugLogging = v; dirty = true end
    if dirty then save_config() end

    imgui.spacing()
    local _, red, orig = read_health()
    imgui.text(string.format("Pending recovery: %.1f HP", state.pool))
    if orig and orig > 0 then
        local rate = orig / Config.RecoveryDuration
        imgui.text(string.format("  = %.1f%% of original max HP, ~%.0f s remaining", state.pool / orig * 100, state.pool / rate))
        imgui.text(string.format("Max HP: %.1f / %.1f", red or 0, orig))
    end
    if runtime.hook_ok then
        imgui.text("Detection: active" .. (runtime.charging and " (charging Martyr's Bolt)" or ""))
    else
        imgui.text("Detection: FAILED - " .. tostring(runtime.hook_error))
    end
    if imgui.tree_node("Diagnostics") then
        imgui.text(string.format("Last cast sacrificed: %.1f HP (casts this session: %d)", runtime.last_cast, runtime.casts))
        imgui.text(string.format("Registered %.1f / restored by mod %.1f / consumed by game restores %.1f",
            state.registered_total, state.restored_total, state.external_total))
        imgui.text("Last reset: " .. tostring(state.last_reset) .. " (" .. state.resets .. ")")
        imgui.text(string.format("Writes %d, write failures %d", runtime.writes, runtime.write_failures))
        imgui.text("Game sacrifice counter: " .. (runtime.counter_seen and "used" or "not seen yet")
            .. (runtime.counter_missing > 0 and (", missing " .. runtime.counter_missing .. "x") or ""))
        if imgui.button("Clear pending recovery") then Core.reset(state, "cleared from menu") end
        imgui.tree_pop()
    end
    imgui.tree_pop()
end)

-- Exposed for the offline test harness only.
if _G.MBR_TEST then _G.MBR_TEST.Core, _G.MBR_TEST.state, _G.MBR_TEST.Config, _G.MBR_TEST.update = Core, state, Config, update end
