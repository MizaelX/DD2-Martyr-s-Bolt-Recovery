-- MartyrsBoltProbe v2 (DD2 / REFramework) — diagnostics for the Martyr's Bolt Recovery mod.
-- Read-only except for the explicit "TEST write" button in the menu.
-- Logs to reframework/data/MartyrsBoltProbe_v2.log and re2_framework_log.txt.
--   * Hooks app.Job08SpritArrow (Martyr's Bolt action: start/update/processSacrifice) and
--     app.HitController max-HP mutators; tags every player ReducedMaxHp change with whether it
--     happened inside processSacrifice (skill cost) or elsewhere (damage, items, rest...).
--   * Polls player Hp / ReducedMaxHp / OriginalMaxHp, FSM node and the game's own
--     Job08ActionController.SpritArrowSacrificedHitPoint.
-- v1 findings: Martyr's Bolt = HumanCustomSkillID.Job08_SpiritArrow (91); charging FSM node
-- "Job08.Job08_SkillAttack.Job08_CS12.Job08_ReadySpiritArrow", release "...Job08_ShootSpiritArrow".

local sdk, imgui, re, log, thread = sdk, imgui, re, log, thread

local TAG = "[MBProbe2] "
local t0 = os.clock()
local file = nil
do
    local ok, f = pcall(io.open, "MartyrsBoltProbe_v2.log", "a")
    if ok and f then file = f end
end

local lines_written = 0
local function out(msg)
    local line = string.format("%9.3f %s", os.clock() - t0, msg)
    if file then pcall(function() file:write(line, "\n"); file:flush() end) end
    pcall(log.info, TAG .. line)
    lines_written = lines_written + 1
end

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

local function fmt(n) return type(n) == "number" and string.format("%.2f", n) or tostring(n) end

out("==== probe v2 loaded ====")

---------------------------------------------------------------------------
-- Player access
---------------------------------------------------------------------------
local player, player_hit, player_hit_addr, player_human = nil, nil, nil, nil

local function refresh_player()
    local cm = try(sdk.get_managed_singleton, "app.CharacterManager")
    local p = call(cm, "get_ManualPlayer()")
    if p == nil then player, player_hit, player_hit_addr, player_human = nil, nil, nil, nil; return end
    local hit = try(function() return p:get_field("<Hit>k__BackingField") end) or call(p, "get_Hit()")
    player, player_hit, player_human = p, hit, call(p, "get_Human()")
    player_hit_addr = hit and try(function() return hit:get_address() end) or nil
end

local function hp_state()
    if not player_hit then return nil end
    return call(player_hit, "get_Hp()"), call(player_hit, "get_ReducedMaxHp()"), call(player_hit, "get_OriginalMaxHp()")
end

local function sacrificed_hp()
    local ctrl = call(player_human, "get_Job08ActionCtrl()")
    return call(ctrl, "get_SpritArrowSacrificedHitPoint()")
end

local fsm_type = try(sdk.typeof, "via.motion.MotionFsm2")
local function fsm_node()
    local go = call(player, "get_GameObject()")
    if not go or not fsm_type then return nil end
    return call(call(go, "getComponent(System.Type)", fsm_type), "getCurrentNodeName", 0)
end

local function job_id()
    local job = call(player_human, "get_JobContext()")
    return try(function() return job:get_field("CurrentJob") end)
end

---------------------------------------------------------------------------
-- Hook helpers
---------------------------------------------------------------------------
-- Per-thread pre->post storage when available (hooks may fire on worker threads).
local fallback_stacks = {}
local function push(label, v)
    local st = thread and thread.get_hook_storage and try(thread.get_hook_storage)
    if st then st[label] = v; return end
    local s = fallback_stacks[label] or {}; fallback_stacks[label] = s; s[#s + 1] = v
end
local function pop(label)
    local st = thread and thread.get_hook_storage and try(thread.get_hook_storage)
    if st then local v = st[label]; st[label] = nil; return v end
    local s = fallback_stacks[label]; if s then return table.remove(s) end
    return nil
end

local function describe_arg(ptype, raw)
    if raw == nil then return "nil" end
    local tn = try(function() return ptype:get_full_name() end) or "?"
    if tn == "System.Single" then return fmt(sdk.to_float(raw)) end
    if tn == "System.Boolean" then return tostring((sdk.to_int64(raw) & 1) == 1) end
    if try(function() return ptype:is_value_type() end) then return tn .. ":" .. tostring(sdk.to_int64(raw) & 0xFFFFFFFF) end
    local obj = try(sdk.to_managed_object, raw)
    if obj then return (try(function() return obj:get_type_definition():get_full_name() end) or tn) .. "@obj" end
    return tn
end

local function find_methods(td, name)
    local found = {}
    for _, m in ipairs(try(function() return td:get_methods() end) or {}) do
        if try(function() return m:get_name() end) == name then found[#found + 1] = m end
    end
    return found
end

local stats = {}
local function stat(label) local s = stats[label]; if not s then s = {calls = 0, changes = 0, total = 0}; stats[label] = s end; return s end

---------------------------------------------------------------------------
-- Martyr's Bolt action hooks (app.Job08SpritArrow)
---------------------------------------------------------------------------
local sacrifice_depth = 0          -- >0 while inside Job08SpritArrow.processSacrifice
local cast = nil                   -- per-cast accounting {start, measured, ticks}

local function begin_cast(source)
    if cast then return end
    local hp, red = hp_state()
    cast = {start_red = red, start_hp = hp, measured = 0, ticks = 0, other = 0, start_sac = sacrificed_hp()}
    out(string.format("CAST begin (%s) hp %s red %s gameSac %s", source, fmt(hp), fmt(red), fmt(cast.start_sac)))
end

local function end_cast(reason)
    if not cast then return end
    local hp, red = hp_state()
    out(string.format("CAST end (%s) measuredInSacrifice=%s ticks=%d otherRedChanges=%s netRed=%s gameSac %s->%s hp %s red %s",
        reason, fmt(cast.measured), cast.ticks, fmt(cast.other),
        (type(red) == "number" and type(cast.start_red) == "number") and fmt(red - cast.start_red) or "?",
        fmt(cast.start_sac), fmt(sacrificed_hp()), fmt(hp), fmt(red)))
    cast = nil
end

local function install_action_hooks()
    local td = sdk.find_type_definition("app.Job08SpritArrow")
    if not td then out("HOOK: app.Job08SpritArrow missing"); return 0 end
    local n = 0
    for _, name in ipairs({"processSacrifice", "start", "update"}) do
        for _, m in ipairs(find_methods(td, name)) do
            local label = "Job08SpritArrow." .. name
            local ok, err = pcall(sdk.hook, m,
                function(args)
                    local _, red = hp_state()
                    push(label, {red = red, this = try(sdk.to_int64, args[2])})
                    if name == "processSacrifice" then sacrifice_depth = sacrifice_depth + 1 end
                end,
                function(retval)
                    local pre = pop(label)
                    if name == "processSacrifice" then sacrifice_depth = math.max(0, sacrifice_depth - 1) end
                    if not pre then return retval end
                    local hp, red = hp_state()
                    local s = stat(label); s.calls = s.calls + 1
                    local d = (type(red) == "number" and type(pre.red) == "number") and (red - pre.red) or 0
                    -- update() wraps processSacrifice(), so its delta would double count; only count calls.
                    if name ~= "update" and math.abs(d) > 1e-4 then
                        -- Only the player's ReducedMaxHp is read, so a change here belongs to the player's cast.
                        s.changes = s.changes + 1; s.total = s.total + d
                        if name == "processSacrifice" then
                            begin_cast("processSacrifice")
                            cast.measured = cast.measured + (-d); cast.ticks = cast.ticks + 1
                            if cast.ticks <= 3 or cast.ticks % 20 == 0 then
                                out(string.format("SAC tick %d d=%s red %s hp %s gameSac %s this=%s",
                                    cast.ticks, fmt(d), fmt(red), fmt(hp), fmt(sacrificed_hp()), tostring(pre.this)))
                            end
                        else
                            out(string.format("ACT %s changed red by %s (outside processSacrifice) this=%s", label, fmt(d), tostring(pre.this)))
                        end
                    end
                    if name == "start" and s.calls <= 20 then out("ACT " .. label .. " this=" .. tostring(pre.this)) end
                    return retval
                end)
            if ok then n = n + 1 else out("HOOK FAIL " .. label .. ": " .. tostring(err)) end
        end
    end
    return n
end

---------------------------------------------------------------------------
-- HitController hooks
---------------------------------------------------------------------------
local HIT_METHODS = {
    "setReducedMaxHp", "setReducedMaxHpValue", "set_ReducedMaxHp", "recoverMaxHp",
    "recoverHpAndMaxHpCompletely", "recoverHp", "updateReductionMaxHPDamage", "updateDamageHp",
    "setMinRateMaxHp", "set_MinRatioReducedMaxHp", "setHp", "setHpValue",
}

local function install_hit_hooks()
    local td = sdk.find_type_definition("app.HitController")
    if not td then out("HOOK: app.HitController missing"); return 0 end
    local n = 0
    for _, name in ipairs(HIT_METHODS) do
        for _, m in ipairs(find_methods(td, name)) do
            local ptypes = try(function() return m:get_param_types() end) or {}
            local label = "Hit." .. name .. "/" .. #ptypes
            local ok, err = pcall(sdk.hook, m,
                function(args)
                    local this_addr = try(sdk.to_int64, args[2])
                    if player_hit_addr == nil or this_addr ~= player_hit_addr then push(label, false); return end
                    local hp, red = hp_state()
                    local desc = {}
                    for i, p in ipairs(ptypes) do desc[#desc + 1] = describe_arg(p, args[i + 2]) end
                    push(label, {hp = hp, red = red, args = table.concat(desc, ", "), insac = sacrifice_depth > 0})
                end,
                function(retval)
                    local pre = pop(label)
                    if not pre then return retval end
                    local hp, red, orig = hp_state()
                    local s = stat(label); s.calls = s.calls + 1
                    local dhp = (type(hp) == "number" and type(pre.hp) == "number") and (hp - pre.hp) or 0
                    local dred = (type(red) == "number" and type(pre.red) == "number") and (red - pre.red) or 0
                    local changed = math.abs(dhp) > 1e-4 or math.abs(dred) > 1e-4
                    if changed then s.changes = s.changes + 1; s.total = s.total + dred end
                    if cast and not pre.insac and math.abs(dred) > 1e-4 then cast.other = cast.other + dred end
                    -- Inside processSacrifice, log only a few to keep the file small.
                    local quiet = pre.insac and cast and cast.ticks > 3
                    if (changed and not quiet) or s.calls <= 2 then
                        out(string.format("HIT %s(%s) %s hp %s->%s red %s->%s orig %s | fsm=%s%s",
                            label, pre.args, pre.insac and "[IN processSacrifice]" or "[outside]",
                            fmt(pre.hp), fmt(hp), fmt(pre.red), fmt(red), fmt(orig), tostring(fsm_node()),
                            changed and "" or " [nochange]"))
                    end
                    return retval
                end)
            if ok then n = n + 1 else out("HOOK FAIL " .. label .. ": " .. tostring(err)) end
        end
    end
    return n
end

refresh_player()
out("HOOK installed " .. tostring(try(install_action_hooks)) .. " Job08SpritArrow hooks, "
    .. tostring(try(install_hit_hooks)) .. " HitController hooks")

---------------------------------------------------------------------------
-- Polling
---------------------------------------------------------------------------
local last = {}
local last_node, last_sac = nil, nil
local accum, prev_clock = 0, os.clock()

local function poll()
    local now = os.clock()
    accum = accum + (now - prev_clock); prev_clock = now
    if accum < 0.05 then return end
    accum = 0
    local prev_addr = player_hit_addr
    refresh_player()
    if player_hit_addr ~= prev_addr then out("PLAYER hit controller -> " .. tostring(player_hit_addr)) end
    local hp, red, orig = hp_state()
    local node = fsm_node()
    local sac = sacrificed_hp()
    local charging = type(node) == "string" and node:find("SpiritArrow", 1, true) ~= nil
    if node ~= last_node then
        out(string.format("FSM %s | hp %s red %s orig %s gameSac %s job %s", tostring(node), fmt(hp), fmt(red), fmt(orig), fmt(sac), tostring(job_id())))
        if cast and not charging then end_cast("fsm left SpiritArrow -> " .. tostring(node)) end
        last_node = node
    end
    if sac ~= last_sac then
        out("GAMESAC " .. fmt(last_sac) .. " -> " .. fmt(sac) .. " | red " .. fmt(red) .. " fsm " .. tostring(node))
        last_sac = sac
    end
    if not charging and red ~= last.red and type(red) == "number" and type(last.red) == "number" then
        out(string.format("POLL red %s -> %s (d=%s) hp %s orig %s fsm %s", fmt(last.red), fmt(red), fmt(red - last.red), fmt(hp), fmt(orig), tostring(node)))
    end
    last.hp, last.red, last.orig = hp, red, orig
end

re.on_frame(function() pcall(poll) end)

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------
local marks = {"Start test", "Full charge", "Released bolt", "Cancel attempt", "Hit while charging",
    "Ordinary damage", "Used elixir/item", "Rested", "Died", "Loaded save", "End test"}

re.on_draw_ui(function()
    if not imgui.tree_node("Martyr's Bolt Probe v2") then return end
    local hp, red, orig = hp_state()
    imgui.text("Player HP " .. fmt(hp) .. "  ReducedMax " .. fmt(red) .. "  OriginalMax " .. fmt(orig))
    imgui.text("Game SpritArrowSacrificedHitPoint: " .. fmt(sacrificed_hp()))
    imgui.text("FSM: " .. tostring(last_node))
    imgui.text("Lines logged: " .. lines_written .. (file and " (file OK)" or " (file FAILED, see re2_framework_log.txt)"))
    for i, m in ipairs(marks) do
        if imgui.button(m) then out("MARK ===== " .. m .. " =====") end
        if i % 3 ~= 0 then imgui.same_line() end
    end
    imgui.new_line()
    if imgui.button("TEST write: restore 10 max HP") then
        local h0, r0, o0 = hp_state()
        if type(r0) == "number" and type(o0) == "number" and r0 < o0 then
            local target = math.min(o0, r0 + 10)
            local ok = pcall(function() player_hit:call("set_ReducedMaxHp(System.Single)", target) end)
            local h1, r1 = hp_state()
            out(string.format("TESTWRITE ok=%s red %s -> %s (target %s) hp %s -> %s", tostring(ok), fmt(r0), fmt(r1), fmt(target), fmt(h0), fmt(h1)))
        else
            out("TESTWRITE skipped: no missing max HP (red " .. fmt(r0) .. " orig " .. fmt(o0) .. ")")
        end
    end
    imgui.same_line()
    if imgui.button("Dump hook stats") then
        for k, s in pairs(stats) do
            out(string.format("STAT %s calls=%d changes=%d totalRedDelta=%s", k, s.calls, s.changes, fmt(s.total)))
        end
    end
    imgui.tree_pop()
end)
