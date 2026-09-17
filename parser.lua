--[[
    ============================================================================
    ShaguDPS 事件解析模块（Nampower 模式）
    ============================================================================
    当 Nampower 可用时，监听其自定义事件（如伤害、治疗、驱散等）来更新统计。
    如果 Nampower 不可用，则回退到 parser-vanilla.lua 中的战斗日志解析方式。
    本文件包含所有 Nampower 事件的处理函数，以及战斗状态管理、宠物归属、
    光环覆盖率、护盾吸收转治疗、打断监测、错误驱散检测等核心功能。
    注意：本文件大量依赖 Nampower 4.5+ 的事件参数（详见 Nampower API 说明文档）。
    ============================================================================
]]

-- ============================================================================
-- 1. 模块初始化与公共变量引用
-- ============================================================================

local parser = ShaguDPS.parser
local data = ShaguDPS.data
local config = ShaguDPS.config
local round = ShaguDPS.round

-- 死亡回放延迟队列初始化
parser.deathReplayQueue = {}

-- 危险debuff标记延迟清除表：[guid] = 应清除时间
parser.badDispelClearTimes = {}

-- 刷新回调表（由 window.lua 注册，战斗事件处理后统一触发，刷新显示）
parser.callbacks = { ["refresh"] = {} }

-- 全局事件时间戳：战斗事件触发时设为 GetTime()。
-- 窗口 OnUpdate 0.2s 节流后比较"上次本地 Refresh 时间戳"与本值，
-- 若有更新则 Refresh 并更新本地时间戳（避免脏标志被抢先清零导致多窗口只刷一个）
parser.lastRefreshEventTime = 0

-- 统计启用状态（根据配置动态更新）
parser.enabled = {
    damage = true,
    heal = true,
    death = true,
    spellcast = true,
    friendly_fire = true,
    dispel = true,
    threat = true,
    sunder = true,
    damage_taken = true,
    energize = true,
    invalid_damage = true,
    heal_taken = true,
    revive = true,
    buff_coverage = true,
    interrupt = true,
    enemy_damage_taken = true,
}

function parser:UpdateEnabledStats()
    local E = self.enabled
    E.damage = ShaguDPS.IsAnyViewEnabled({1, 2})
    E.heal = ShaguDPS.IsAnyViewEnabled({3, 4, 5, 6})
    E.death = ShaguDPS.IsStatEnabled(7)
    E.spellcast = ShaguDPS.IsStatEnabled(8) or E.damage or E.heal
    E.friendly_fire = ShaguDPS.IsStatEnabled(9)
    E.dispel = ShaguDPS.IsStatEnabled(10)
    E.sunder = ShaguDPS.IsStatEnabled(13)
    E.damage_taken = ShaguDPS.IsStatEnabled(14) or ShaguDPS.IsStatEnabled(7)
    E.energize = ShaguDPS.IsStatEnabled(16)
    E.invalid_damage = ShaguDPS.IsStatEnabled(17)
    E.heal_taken = ShaguDPS.IsStatEnabled(18)
    E.revive = ShaguDPS.IsStatEnabled(19)
    E.buff_coverage = ShaguDPS.IsStatEnabled(20)
    E.interrupt = ShaguDPS.IsStatEnabled(21)
    E.enemy_damage_taken = ShaguDPS.IsStatEnabled(22)
    if ShaguDPS.hasNampower then
        self:RefreshEventRegistration()
    end
end

function parser:RefreshEventRegistration()
    local E = self.enabled
    local function reg(event, cond)
        if cond then
            self:RegisterEvent(event)
        else
            self:UnregisterEvent(event)
        end
    end
    reg("SPELL_DAMAGE_EVENT_SELF", true)
    reg("SPELL_DAMAGE_EVENT_OTHER", true)
    reg("AUTO_ATTACK_SELF", true)
    reg("AUTO_ATTACK_OTHER", true)
    local missRelated = E.damage or E.enemy_damage_taken or E.invalid_damage
    reg("SPELL_MISS_SELF", missRelated)
    reg("SPELL_MISS_OTHER", missRelated)
    local healRelated = E.heal or E.heal_taken or E.spellcast
    reg("SPELL_HEAL_BY_SELF", healRelated)
    reg("SPELL_HEAL_BY_OTHER", healRelated)
    reg("SPELL_GO_SELF", true)
    reg("SPELL_GO_OTHER", true)
    reg("SPELL_DISPEL_BY_SELF", E.dispel)
    reg("SPELL_DISPEL_BY_OTHER", E.dispel)
    reg("SPELL_ENERGIZE_BY_SELF", E.energize)
    reg("SPELL_ENERGIZE_BY_OTHER", E.energize)
    reg("SPELL_FAILED_OTHER", E.interrupt)
    reg("UNIT_DIED", E.death)
end

-- 用于计算溢出伤害的单位血量缓存
local healthCache = {}

-- ============================================================================
-- 2. 安全工具函数
-- ============================================================================

local function SafeUnitName(guid)
    if not guid or guid == "" or guid == "0x0000000000000000" then
        return nil
    end
    return UnitName(guid)
end

local function deepcopy(original)
    if type(original) ~= "table" then return original end
    local copy = {}
    for k, v in pairs(original) do
        copy[k] = deepcopy(v)
    end
    return copy
end

local function IsFriendly(guid)
    if not guid then return false end
    return UnitCanAssist("player", guid) or UnitIsFriend("player", guid)
end

-- ============================================================================
-- 3. 未知名称延迟处理机制
-- ============================================================================

parser.pendingEvents = {}
parser.nextProcessTime = 0
parser.pendingEventId = 0

local function isUnknownName(name)
    if not name or name == "" then return true end
    if name == "未知目标" or name == "Unknown" then return true end
    return false
end

function parser:ScheduleEvent(func, args, guids)
    local now = GetTime()
    self.pendingEventId = self.pendingEventId + 1
    self.pendingEvents[self.pendingEventId] = {
        id = self.pendingEventId,
        func = func,
        args = args,
        guids = guids,
        createTime = now,
    }
    if self.nextProcessTime == 0 then
        self.nextProcessTime = now + 0.5
    end
end

local function processPendingEvents()
    local now = GetTime()
    local anyRemaining = false
    local processed = true
    while processed do
        processed = false
        for id, event in pairs(parser.pendingEvents) do
            if now - event.createTime > 3 then
                parser.pendingEvents[id] = nil
                processed = true
            else
                local allReady = true
                for _, guid in ipairs(event.guids) do
                    if isUnknownName(SafeUnitName(guid)) then
                        allReady = false
                        break
                    end
                end
                if allReady then
                    event.func(unpack(event.args))
                    parser.pendingEvents[id] = nil
                    processed = true
                else
                    anyRemaining = true
                end
            end
        end
    end
    if anyRemaining then
        parser.nextProcessTime = now + 0.5
    else
        parser.nextProcessTime = 0
    end
end
parser.processPendingEvents = processPendingEvents

-- 帧更新脚本，统一处理三类延迟任务：
--  1) pendingEvents 未知名称延迟解析（第 3 节）
--  2) 死亡回放延迟队列（第 25 节）
--  3) 危险 debuff 标记延迟清除（第 19 节）
parser:SetScript("OnUpdate", function()
    if parser.nextProcessTime ~= 0 and GetTime() >= parser.nextProcessTime then
        processPendingEvents()
    end
    if parser.ProcessDeathReplayQueue and next(parser.deathReplayQueue) then
        parser:ProcessDeathReplayQueue(false)
    end
    if next(parser.badDispelClearTimes) then
        local now = GetTime()
        for guid, clearTime in pairs(parser.badDispelClearTimes) do
            if now >= clearTime then
                if ShaguDPS.activeBadDispelDebuffs then
                    ShaguDPS.activeBadDispelDebuffs[guid] = nil
                end
                parser.badDispelClearTimes[guid] = nil
            end
        end
    end
end)

function parser:FlushPendingEvents()
    for id, _ in pairs(self.pendingEvents) do
        self.pendingEvents[id] = nil
    end
    self.nextProcessTime = 0
end

-- ============================================================================
-- 4. 单位 Token 与宠物归属
-- ============================================================================

local validUnits = { ["player"] = true }
for i = 1, 4 do validUnits["party" .. i] = true end
for i = 1, 40 do validUnits["raid" .. i] = true end

local validPets = { ["pet"] = true }
for i = 1, 4 do validPets["partypet" .. i] = true end
for i = 1, 40 do validPets["raidpet" .. i] = true end

local function GetOwnerInfoFromPetGUID(petGUID)
    if not petGUID then return nil, nil end

    -- 术士等职业临时召唤宠物每次 GUID 都不同，且不同宠物可能复用 GUID，
    -- 缓存会导致归属错误/漏统计。这里不做缓存，每次都实时获取。
    if UnitIsPlayer(petGUID) then
        return nil, nil, nil
    end

    local ownerGUID = GetUnitGUID(petGUID .. "owner")
    if ownerGUID then
        return SafeUnitName(ownerGUID), "pet", ownerGUID
    end
    if ShaguDPS.hasNampower then
        local charm = GetUnitField(petGUID, "charm")
        if charm and charm ~= "0x0000000000000000" then
            if SafeUnitName(charm .. "owner") then
                return SafeUnitName(charm .. "owner"), "charm", charm
            else
                return SafeUnitName(charm), "charm", charm
            end
        end
        local createdBy = GetUnitField(petGUID, "createdBy")
        if createdBy and createdBy ~= "0x0000000000000000" then
            return SafeUnitName(createdBy), "pet", createdBy
        end
    end
    return nil, nil, nil
end

-- ============================================================================
-- 5. 敌对目标追踪
-- ============================================================================

local function IsHostileGuid(guid)
    if not guid or guid == "" or guid == "0x0000000000000000" then
        return false
    end
    if not UnitExists(guid) then
        return false
    end
    if IsFriendly(guid) then
        return false
    end
    return true
end

function ShaguDPS.AddHostileTarget(guid)
    if not ShaguDPS.hasNampower then return end
    if not IsHostileGuid(guid) then return end
    ShaguDPS.hostile_targets = ShaguDPS.hostile_targets or {}
    local info = ShaguDPS.hostile_targets[guid]
    if info then
        info.time = GetTime()
        return
    end
    ShaguDPS.hostile_targets[guid] = {
        time = GetTime(),
        dead = UnitIsDead(guid) == 1,
    }
end

function ShaguDPS.RefreshHostileTargets()
    if not ShaguDPS.hasNampower then return end
    local targets = ShaguDPS.hostile_targets
    if not targets then return end
    local now = GetTime()
    for guid, info in pairs(targets) do
        if type(info) ~= "table" then
            targets[guid] = nil
        elseif info.dead then
            targets[guid] = nil
        elseif UnitExists(guid) and UnitIsDead(guid) then
            targets[guid] = nil
        elseif not UnitExists(guid) and now - info.time > 3 then
            targets[guid] = nil
        elseif not UnitAffectingCombat(guid) and now - info.time > 8 then
            targets[guid] = nil
        end
    end
end

-- ============================================================================
-- 6. 数据段管理与小怪/BOSS 汇总
-- ============================================================================

local combat_start_time = 0
local diedBossesThisFight = {}
local is_boss_encounter = false

local function resetCurrentSegment()
    data["damage"][1] = {}
    data["heal"][1] = {}
    data["death"][1] = {}
    data["spellcast"][1] = {}
    data["spellcast_details"][1] = {}
    data["friendly_fire"][1] = {}
    data["dispel"][1] = {}
    data["sunder"][1] = {}
    data["damage_taken"][1] = {}
    data["energize"][1] = {}
    data["invalid_damage"][1] = {}
    data["heal_taken"][1] = {}
    data["dot_ticks"][1] = {}
    data["hit_breakdown"][1] = {}
    data["revive"][1] = {}
    data["buff_coverage"][1] = {}
    data["weakness_coverage"][1] = {}
    data["interrupt"][1] = {}
    data["enemy_damage_taken"][1] = {}
    data.death_replays = {}
    parser.extraAttacks = {}
    ShaguDPS.activeBadDispelDebuffs = {}
    ShaguDPS.wrongDispels = {}
end

-- 将 source（当前战斗段）的打断统计递归累加进 target（全程/小怪段）：
-- 结构 目标名 → 技能名 → 受害者名 → 打断次数，_total 为汇总字段
local function mergeInterrupts(target, source)
    if not source then return end
    for name, unitdata in pairs(source) do
        if not target[name] then
            target[name] = { ["_total"] = 0 }
        end
        local t = target[name]
        t._total = (t._total or 0) + (unitdata._total or 0)
        for ability, abilityData in pairs(unitdata) do
            if ability ~= "_total" and type(abilityData) == "table" then
                if not t[ability] then
                    t[ability] = { ["_total"] = 0 }
                end
                local abilT = t[ability]
                abilT._total = (abilT._total or 0) + (abilityData._total or 0)
                for victim, spells in pairs(abilityData) do
                    if victim ~= "_total" and type(spells) == "table" then
                        if not abilT[victim] then abilT[victim] = {} end
                        for spellName, count in pairs(spells) do
                            abilT[victim][spellName] = (abilT[victim][spellName] or 0) + count
                        end
                    end
                end
            end
        end
    end
end

-- 将 source 的敌人承伤数据（目标名 → 来源名 → {_sum,_overkill}）累加进 target
local function mergeEnemyDamageTaken(target, source)
    if not source then return end
    for targetName, tdata in pairs(source) do
        if not target[targetName] then
            target[targetName] = { _sum = 0, _overkill = 0 }
        end
        local tt = target[targetName]
        tt._sum = (tt._sum or 0) + (tdata._sum or 0)
        tt._overkill = (tt._overkill or 0) + (tdata._overkill or 0)
        for sourceName, sdata in pairs(tdata) do
            if sourceName ~= "_sum" and sourceName ~= "_overkill" and type(sdata) == "table" then
                if not tt[sourceName] then
                    tt[sourceName] = { _sum = 0, _overkill = 0 }
                end
                tt[sourceName]._sum = (tt[sourceName]._sum or 0) + (sdata._sum or 0)
                tt[sourceName]._overkill = (tt[sourceName]._overkill or 0) + (sdata._overkill or 0)
            end
        end
    end
end

local function mergeCurrentToSmallFight()
    local small = data.small_fight

    -- 合并伤害
    for name, unitdata in pairs(data.damage[1]) do
        if not small.damage[name] then small.damage[name] = {} end
        for k, v in pairs(unitdata) do
            if k == "_ctime" then
                small.damage[name]["_ctime"] = (small.damage[name]["_ctime"] or 0) + v
            elseif k == "_sum" then
                small.damage[name]["_sum"] = (small.damage[name]["_sum"] or 0) + v
            elseif k == "_overkill" then
                small.damage[name]["_overkill"] = (small.damage[name]["_overkill"] or 0) + v
            elseif k == "_overkill_by_spell" then
                if not small.damage[name]["_overkill_by_spell"] then small.damage[name]["_overkill_by_spell"] = {} end
                for spell, val in pairs(v) do
                    small.damage[name]["_overkill_by_spell"][spell] = (small.damage[name]["_overkill_by_spell"][spell] or 0) + val
                end
            elseif k == "_effective" then
                if not small.damage[name]["_effective"] then small.damage[name]["_effective"] = {} end
                for spell, val in pairs(v) do
                    small.damage[name]["_effective"][spell] = (small.damage[name]["_effective"][spell] or 0) + val
                end
            elseif k == "_by_target" then
                if not small.damage[name]["_by_target"] then small.damage[name]["_by_target"] = {} end
                for target, tdata in pairs(v) do
                    if not small.damage[name]["_by_target"][target] then small.damage[name]["_by_target"][target] = {} end
                    for spell, dmg in pairs(tdata) do
                        small.damage[name]["_by_target"][target][spell] = (small.damage[name]["_by_target"][target][spell] or 0) + dmg
                    end
                end
            elseif k ~= "_tick" then
                small.damage[name][k] = (small.damage[name][k] or 0) + v
            end
        end
    end

    -- 合并治疗
    for name, unitdata in pairs(data.heal[1]) do
        if not small.heal[name] then small.heal[name] = {} end
        for k, v in pairs(unitdata) do
            if k == "_ctime" then
                small.heal[name]["_ctime"] = (small.heal[name]["_ctime"] or 0) + v
            elseif k == "_sum" then
                small.heal[name]["_sum"] = (small.heal[name]["_sum"] or 0) + v
            elseif k == "_esum" then
                small.heal[name]["_esum"] = (small.heal[name]["_esum"] or 0) + v
            elseif k == "_effective" then
                if not small.heal[name]["_effective"] then small.heal[name]["_effective"] = {} end
                for spell, val in pairs(v) do
                    small.heal[name]["_effective"][spell] = (small.heal[name]["_effective"][spell] or 0) + val
                end
            elseif k ~= "_tick" then
                small.heal[name][k] = (small.heal[name][k] or 0) + v
            end
        end
    end

    -- 合并死亡
    for name, count in pairs(data.death[1]) do
        small.death[name] = (small.death[name] or 0) + count
    end

    -- 合并施放（扁平）
    for name, unitdata in pairs(data.spellcast[1]) do
        if not small.spellcast[name] then small.spellcast[name] = { ["_total"] = 0 } end
        for k, v in pairs(unitdata) do
            if k == "_total" then
                small.spellcast[name]["_total"] = (small.spellcast[name]["_total"] or 0) + v
            else
                small.spellcast[name][k] = (small.spellcast[name][k] or 0) + v
            end
        end
    end

    -- 合并施放详情
    for name, unitdata in pairs(data.spellcast_details[1]) do
        if not small.spellcast_details[name] then small.spellcast_details[name] = {} end
        for sourceType, sourceData in pairs(unitdata) do
            if sourceType ~= "_total" then
                if not small.spellcast_details[name][sourceType] then small.spellcast_details[name][sourceType] = {} end
                for targetType, targetData in pairs(sourceData) do
                    if not small.spellcast_details[name][sourceType][targetType] then small.spellcast_details[name][sourceType][targetType] = {} end
                    for spell, count in pairs(targetData) do
                        small.spellcast_details[name][sourceType][targetType][spell] = (small.spellcast_details[name][sourceType][targetType][spell] or 0) + count
                    end
                end
            end
        end
        small.spellcast_details[name]["_total"] = (small.spellcast_details[name]["_total"] or 0) + (unitdata["_total"] or 0)
    end

    -- 合并误伤
    for name, unitdata in pairs(data.friendly_fire[1]) do
        if not small.friendly_fire[name] then small.friendly_fire[name] = { ["_total"] = 0 } end
        for k, v in pairs(unitdata) do
            if k == "_total" then
                small.friendly_fire[name]["_total"] = (small.friendly_fire[name]["_total"] or 0) + v
            else
                if not small.friendly_fire[name][k] then small.friendly_fire[name][k] = {} end
                for target, dmg in pairs(v) do
                    small.friendly_fire[name][k][target] = (small.friendly_fire[name][k][target] or 0) + dmg
                end
            end
        end
    end

    -- 合并驱散
    for name, unitdata in pairs(data.dispel[1]) do
        if not small.dispel[name] then
            small.dispel[name] = { ["_total"] = 0, ["_offensive"] = 0, ["_defensive"] = 0 }
        end
        for k, v in pairs(unitdata) do
            if k == "_total" or k == "_offensive" or k == "_defensive" then
                small.dispel[name][k] = (small.dispel[name][k] or 0) + (type(v) == "number" and v or 0)
            else
                if type(v) == "table" then
                    if not small.dispel[name][k] then small.dispel[name][k] = {} end
                    for target, spells in pairs(v) do
                        if type(spells) == "table" then
                            if not small.dispel[name][k][target] then small.dispel[name][k][target] = {} end
                            for spell, count in pairs(spells) do
                                small.dispel[name][k][target][spell] =
                                    (small.dispel[name][k][target][spell] or 0) + (type(count) == "number" and count or 0)
                            end
                        end
                    end
                end
            end
        end
    end

    -- 合并破甲
    for name, unitdata in pairs(data.sunder[1]) do
        if not small.sunder[name] then small.sunder[name] = { ["_total"] = 0 } end
        for k, v in pairs(unitdata) do
            if k == "_total" then
                small.sunder[name]["_total"] = (small.sunder[name]["_total"] or 0) + v
            else
                small.sunder[name][k] = (small.sunder[name][k] or 0) + v
            end
        end
    end

    -- 合并承受伤害
    for name, unitdata in pairs(data.damage_taken[1]) do
        if not small.damage_taken[name] then small.damage_taken[name] = { ["_sum"] = 0, ["_history"] = {} } end
        small.damage_taken[name]["_sum"] = (small.damage_taken[name]["_sum"] or 0) + (unitdata._sum or 0)
        if unitdata._history then
            for _, h in ipairs(unitdata._history) do
                table.insert(small.damage_taken[name]["_history"], h)
            end
        end
    end

    -- 合并敌人承伤
    if not small.enemy_damage_taken then
        small.enemy_damage_taken = {}
    end
    mergeEnemyDamageTaken(small.enemy_damage_taken, data.enemy_damage_taken[1])

    -- 合并能量回复
    for name, unitdata in pairs(data.energize[1]) do
        if not small.energize[name] then small.energize[name] = { ["_sum"] = 0, ["_ctime"] = 1, ["_by_type"] = {} } end
        for k, v in pairs(unitdata) do
            if k == "_sum" then
                small.energize[name]["_sum"] = (small.energize[name]["_sum"] or 0) + v
            elseif k == "_ctime" then
                small.energize[name]["_ctime"] = (small.energize[name]["_ctime"] or 0) + v
            elseif k == "_by_type" then
                for pt, amt in pairs(v) do
                    small.energize[name]["_by_type"][pt] = (small.energize[name]["_by_type"][pt] or 0) + amt
                end
            elseif k ~= "_tick" then
                small.energize[name][k] = (small.energize[name][k] or 0) + v
            end
        end
    end

    -- 合并无效伤害
    for name, unitdata in pairs(data.invalid_damage[1]) do
        if not small.invalid_damage[name] then small.invalid_damage[name] = { ["_sum"] = 0, ["_ctime"] = 1, ["_overkill"] = 0, ["_by_target"] = {} } end
        for k, v in pairs(unitdata) do
            if k == "_sum" then
                small.invalid_damage[name]["_sum"] = (small.invalid_damage[name]["_sum"] or 0) + v
            elseif k == "_ctime" then
                small.invalid_damage[name]["_ctime"] = (small.invalid_damage[name]["_ctime"] or 0) + v
            elseif k == "_overkill" then
                small.invalid_damage[name]["_overkill"] = (small.invalid_damage[name]["_overkill"] or 0) + v
            elseif k == "_by_target" then
                for target, tdata in pairs(v) do
                    if not small.invalid_damage[name]["_by_target"][target] then small.invalid_damage[name]["_by_target"][target] = { ["_sum"] = 0 } end
                    for spell, dmg in pairs(tdata) do
                        if spell == "_sum" then
                            small.invalid_damage[name]["_by_target"][target]["_sum"] = (small.invalid_damage[name]["_by_target"][target]["_sum"] or 0) + dmg
                        else
                            small.invalid_damage[name]["_by_target"][target][spell] = (small.invalid_damage[name]["_by_target"][target][spell] or 0) + dmg
                            local cntKey = "_count_" .. spell
                            small.invalid_damage[name]["_by_target"][target][cntKey] = (small.invalid_damage[name]["_by_target"][target][cntKey] or 0) + (tdata[cntKey] or 0)
                        end
                    end
                end
            elseif k ~= "_tick" then
                small.invalid_damage[name][k] = (small.invalid_damage[name][k] or 0) + v
            end
        end
    end

    -- 合并受到治疗
    for name, unitdata in pairs(data.heal_taken[1]) do
        if not small.heal_taken[name] then small.heal_taken[name] = { ["_sum"] = 0, ["_esum"] = 0 } end
        for k, v in pairs(unitdata) do
            if k == "_sum" then
                small.heal_taken[name]["_sum"] = (small.heal_taken[name]["_sum"] or 0) + v
            elseif k == "_esum" then
                small.heal_taken[name]["_esum"] = (small.heal_taken[name]["_esum"] or 0) + v
            else
                if not small.heal_taken[name][k] then small.heal_taken[name][k] = { ["_sum"] = 0, ["_esum"] = 0 } end
                for subk, subv in pairs(v) do
                    if subk == "_sum" then
                        small.heal_taken[name][k]["_sum"] = (small.heal_taken[name][k]["_sum"] or 0) + subv
                    elseif subk == "_esum" then
                        small.heal_taken[name][k]["_esum"] = (small.heal_taken[name][k]["_esum"] or 0) + subv
                    end
                end
            end
        end
    end

    -- 合并DOT跳数
    for name, unitdata in pairs(data.dot_ticks[1]) do
        if not small.dot_ticks[name] then small.dot_ticks[name] = {} end
        for k, v in pairs(unitdata) do
            small.dot_ticks[name][k] = (small.dot_ticks[name][k] or 0) + v
        end
    end

    -- 合并技能命中明细
    if data.hit_breakdown and data.hit_breakdown[1] then
        if not small.hit_breakdown then small.hit_breakdown = {} end
        for name, unitdata in pairs(data.hit_breakdown[1]) do
            if not small.hit_breakdown[name] then small.hit_breakdown[name] = {} end
            for action, hdata in pairs(unitdata) do
                if type(hdata) == "table" then
                    if not small.hit_breakdown[name][action] then
                        small.hit_breakdown[name][action] = {}
                    end
                    for htype, cnt in pairs(hdata) do
                        small.hit_breakdown[name][action][htype] =
                            (small.hit_breakdown[name][action][htype] or 0) + cnt
                    end
                end
            end
        end
    end

    -- 合并复活
    for name, unitdata in pairs(data.revive[1]) do
        if not small.revive[name] then small.revive[name] = { ["_total"] = 0 } end
        for k, v in pairs(unitdata) do
            if k == "_total" then
                small.revive[name]["_total"] = (small.revive[name]["_total"] or 0) + v
            else
                small.revive[name][k] = (small.revive[name][k] or 0) + v
            end
        end
    end

    -- 合并打断
    mergeInterrupts(small.interrupt, data.interrupt[1])

    -- 合并 buff 覆盖率
    for name, unitdata in pairs(data.buff_coverage[1]) do
        if not small.buff_coverage[name] then
            small.buff_coverage[name] = { ["_total_time"] = 0, ["buff"] = {}, ["debuff"] = {} }
        end
        local target = small.buff_coverage[name]
        target["_total_time"] = (target["_total_time"] or 0) + (unitdata["_total_time"] or 0)
        if unitdata["buff"] then
            if not target["buff"] then target["buff"] = {} end
            for k, v in pairs(unitdata["buff"]) do
                target["buff"][k] = (target["buff"][k] or 0) + v
            end
        end
        if unitdata["debuff"] then
            if not target["debuff"] then target["debuff"] = {} end
            for k, v in pairs(unitdata["debuff"]) do
                target["debuff"][k] = (target["debuff"][k] or 0) + v
            end
        end
    end

    -- 合并易伤覆盖率
    if not small.weakness_coverage then
        small.weakness_coverage = {}
    end
    if not data.weakness_coverage or not data.weakness_coverage[1] then
        data.weakness_coverage[1] = {}
    end
    for targetName, targetData in pairs(data.weakness_coverage[1]) do
        if not small.weakness_coverage[targetName] then
            small.weakness_coverage[targetName] = { ["_total_time"] = 0 }
        end
        local st = small.weakness_coverage[targetName]
        st["_total_time"] = (st["_total_time"] or 0) + (targetData["_total_time"] or 0)
        for k, v in pairs(targetData) do
            if k ~= "_total_time" then
                st[k] = (st[k] or 0) + v
            end
        end
    end

    -- 累加小怪战斗总时间
    ShaguDPS.small_fight_total_time = (ShaguDPS.small_fight_total_time or 0) + data.last_fight_duration
end

-- 将当前战斗（伤害/治疗段 1）保存为"最近战斗"快照（最多保留 5 场）。
-- 条件：有伤害或治疗数据，且战斗时长 ≥ 10 秒。
-- 名称取本场战斗血量最高的敌人（近似判断 BOSS 名）。
local function storeRecentFight()
    if not next(data.damage[1]) and not next(data.heal[1]) then
        return
    end
    if not data.last_fight_duration or data.last_fight_duration < 10 then
        return
    end
    local bossName = "未知战斗"
    local maxHealth = 0
    if data.enemy_max_health then
        for name, hp in pairs(data.enemy_max_health) do
            if hp > maxHealth then
                maxHealth = hp
                bossName = name
            end
        end
    end
    local recentFight = {
        name = bossName,
        bossName = bossName,
        timestamp = combat_start_time,
        duration = data.last_fight_duration,
        damage = deepcopy(data.damage[1]),
        heal = deepcopy(data.heal[1]),
        death = deepcopy(data.death[1]),
        spellcast = deepcopy(data.spellcast[1]),
        spellcast_details = deepcopy(data.spellcast_details[1]),
        friendly_fire = deepcopy(data.friendly_fire[1]),
        dispel = deepcopy(data.dispel[1]),
        sunder = deepcopy(data.sunder[1]),
        damage_taken = deepcopy(data.damage_taken[1]),
        enemy_damage_taken = deepcopy(data.enemy_damage_taken[1]),
        energize = deepcopy(data.energize[1]),
        invalid_damage = deepcopy(data.invalid_damage[1]),
        heal_taken = deepcopy(data.heal_taken[1]),
        dot_ticks = deepcopy(data.dot_ticks[1]),
        hit_breakdown = deepcopy(data.hit_breakdown[1]),
        revive = deepcopy(data.revive[1]),
        buff_coverage = deepcopy(data.buff_coverage[1]),
        weakness_coverage = deepcopy(data.weakness_coverage[1]),
        interrupt = deepcopy(data.interrupt[1]),
        death_timestamps = deepcopy(data.death_timestamps),
        death_replays = deepcopy(data.death_replays),
    }
    table.insert(ShaguDPS.recent_fights, recentFight)
    while table.getn(ShaguDPS.recent_fights) > 5 do
        table.remove(ShaguDPS.recent_fights, 1)
    end
    local count = table.getn(ShaguDPS.recent_fights)
    for i = 1, count do
        local idx = count - i + 1
        local fight = ShaguDPS.recent_fights[idx]
        if fight then
            local baseName = fight.bossName or fight.name
            fight.name = i .. ". " .. baseName
        end
    end
    ShaguDPS.current_recent_index = count
end

-- ============================================================================
-- 7. 战斗状态监视框架
-- ============================================================================

ShaguDPS._lastCombatStartTime = 0
parser.combat = CreateFrame("Frame", "ShaguDPSCombatState", UIParent)
parser.combat:RegisterEvent("PLAYER_REGEN_DISABLED")
parser.combat:RegisterEvent("PLAYER_REGEN_ENABLED")
parser.combat:RegisterEvent("PLAYER_UNGHOST")
parser.combat:RegisterEvent("PLAYER_LOGOUT")

function parser.combat:UpdateState(forceNoCombat)
    local state
    if forceNoCombat then
        -- PLAYER_UNGHOST（施放灵魂）：玩家自身真正脱战，强制结算
        state = "NO_COMBAT"
    elseif ShaguDPS.Combat(true) == true then
        -- 任意战斗标记 + 真实怪被攻击/仇恨/受到攻击 → 战斗中
        state = "COMBAT"
    elseif UnitAffectingCombat("player") then
        -- Combat() 为 false（如 P1 打完一波小怪空档），但玩家自身仍在战斗
        -- → 保持战斗中，避免空档误脱战
        state = "COMBAT"
    else
        -- 玩家自身已真正脱战（PLAYER_REGEN_ENABLED 已触发，或通过 OnUpdate 轮询判定）
        state = "NO_COMBAT"
    end
    if not self.oldstate or self.oldstate ~= state then
        self.oldstate = state
        if state == "NO_COMBAT" then
            if data.combat_start_time > 0 then
                data.last_fight_duration = GetTime() - data.combat_start_time
                data.combat_start_time = 0
            else
                data.last_fight_duration = 0
            end
            data.total_combat_time = (data.total_combat_time or 0) + data.last_fight_duration

            if ShaguDPS.hasNampower and parser.finalizeBuffCoverage then
                parser:finalizeBuffCoverage(data.last_fight_duration)
            end
            if ShaguDPS.hasNampower and parser.finalizeWeaknessCoverage then
                parser:finalizeWeaknessCoverage(data.last_fight_duration)
            end

            if not is_boss_encounter then
                mergeCurrentToSmallFight()
            end
            is_boss_encounter = false

            healthCache = {}
            if next(data.damage[1]) then ShaguDPS.cached_current_damage = deepcopy(data.damage[1]) end
            if next(data.heal[1]) then ShaguDPS.cached_current_heal = deepcopy(data.heal[1]) end
            if next(data.death[1]) then ShaguDPS.cached_current_death = deepcopy(data.death[1]) end
            if next(data.spellcast[1]) then ShaguDPS.cached_current_spellcast = deepcopy(data.spellcast[1]) end
            if next(data.spellcast_details[1]) then ShaguDPS.cached_current_spellcast_details = deepcopy(data.spellcast_details[1]) end
            if next(data.friendly_fire[1]) then ShaguDPS.cached_current_friendly_fire = deepcopy(data.friendly_fire[1]) end
            if next(data.dispel[1]) then ShaguDPS.cached_current_dispel = deepcopy(data.dispel[1]) end
            if next(data.sunder[1]) then ShaguDPS.cached_current_sunder = deepcopy(data.sunder[1]) end
            if next(data.damage_taken[1]) then ShaguDPS.cached_current_damage_taken = deepcopy(data.damage_taken[1]) end
            if next(data.enemy_damage_taken[1]) then ShaguDPS.cached_current_enemy_damage_taken = deepcopy(data.enemy_damage_taken[1]) end
            if next(data.energize[1]) then ShaguDPS.cached_current_energize = deepcopy(data.energize[1]) end
            if next(data.invalid_damage[1]) then ShaguDPS.cached_current_invalid_damage = deepcopy(data.invalid_damage[1]) end
            if next(data.heal_taken[1]) then ShaguDPS.cached_current_heal_taken = deepcopy(data.heal_taken[1]) end
            if next(data.dot_ticks[1]) then ShaguDPS.cached_current_dot_ticks = deepcopy(data.dot_ticks[1]) end
            if next(data.hit_breakdown[1]) then ShaguDPS.cached_current_hit_breakdown = deepcopy(data.hit_breakdown[1]) end
            if next(data.revive[1]) then ShaguDPS.cached_current_revive = deepcopy(data.revive[1]) end
            if next(data.buff_coverage[1]) then ShaguDPS.cached_current_buff_coverage = deepcopy(data.buff_coverage[1]) end
            if next(data.weakness_coverage[1]) then ShaguDPS.cached_current_weakness_coverage = deepcopy(data.weakness_coverage[1]) end
            if next(data.interrupt[1]) then ShaguDPS.cached_current_interrupt = deepcopy(data.interrupt[1]) end
            if next(data.death_replays) then ShaguDPS.cached_current_death_replays = deepcopy(data.death_replays) end

            storeRecentFight()

            if table.getn(diedBossesThisFight) > 0 and ShaguDPS.pendingBossRecord then
                local newBosses = diedBossesThisFight
                local fightDeathTimestamps = {}
                if ShaguDPS.battleStartDeathTimestamps then
                    for name, timestamps in pairs(data.death_timestamps) do
                        local initial = ShaguDPS.battleStartDeathTimestamps[name]
                        local initialCount = initial and table.getn(initial) or 0
                        local newTimestamps = {}
                        for i = initialCount + 1, table.getn(timestamps) do
                            table.insert(newTimestamps, timestamps[i])
                        end
                        if table.getn(newTimestamps) > 0 then
                            fightDeathTimestamps[name] = newTimestamps
                        end
                    end
                else
                    fightDeathTimestamps = deepcopy(data.death_timestamps)
                end

                local bossFight = {
                    name = ShaguDPS.pendingBossRecord.name,
                    timestamp = ShaguDPS.pendingBossRecord.timestamp,
                    bosses = newBosses,
                    damage = deepcopy(data.damage[1]),
                    heal = deepcopy(data.heal[1]),
                    death = deepcopy(data.death[1]),
                    spellcast = deepcopy(data.spellcast[1]),
                    spellcast_details = deepcopy(data.spellcast_details[1]),
                    friendly_fire = deepcopy(data.friendly_fire[1]),
                    dispel = deepcopy(data.dispel[1]),
                    sunder = deepcopy(data.sunder[1]),
                    damage_taken = deepcopy(data.damage_taken[1]),
                    enemy_damage_taken = deepcopy(data.enemy_damage_taken[1]),
                    energize = deepcopy(data.energize[1]),
                    invalid_damage = deepcopy(data.invalid_damage[1]),
                    heal_taken = deepcopy(data.heal_taken[1]),
                    dot_ticks = deepcopy(data.dot_ticks[1]),
                    hit_breakdown = deepcopy(data.hit_breakdown[1]),
                    duration = data.last_fight_duration,
                    revive = deepcopy(data.revive[1]),
                    buff_coverage = deepcopy(data.buff_coverage[1]),
                    weakness_coverage = deepcopy(data.weakness_coverage[1]),
                    interrupt = deepcopy(data.interrupt[1]),
                    death_replays = deepcopy(data.death_replays),
                    death_timestamps = fightDeathTimestamps,
                }

                local replaced = false
                for i, fight in ipairs(ShaguDPS.boss_fights) do
                    if fight.bosses then
                        for _, name in ipairs(newBosses) do
                            for _, existingName in ipairs(fight.bosses) do
                                if name == existingName then
                                    ShaguDPS.boss_fights[i] = bossFight
                                    replaced = true
                                    break
                                end
                            end
                            if replaced then break end
                        end
                    end
                    if replaced then break end
                end

                if not replaced then
                    table.insert(ShaguDPS.boss_fights, bossFight)
                    ShaguDPS.current_boss_index = table.getn(ShaguDPS.boss_fights)
                else
                    ShaguDPS.current_boss_index = i
                end

                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[ShaguDPS] 已记录BOSS战: %s|r", bossFight.name))
            end

            ShaguDPS.weaknessScannedTargets = {}
            ShaguDPS.weaknessTrackedTargets = {}
            ShaguDPS.pendingBossRecord = nil
            diedBossesThisFight = {}

            ShaguDPS.SaveDataToCache()
            if parser.ProcessDeathReplayQueue then
                parser:ProcessDeathReplayQueue(true)
            end
            resetCurrentSegment()
            parser:FlushPendingEvents()
            data.threat = {}
            combat_start_time = 0
            ShaguDPS._lastCombatStartTime = 0
            parser.extraAttacks = {}

        elseif state == "COMBAT" then
            healthCache = {}
            data.enemy_max_health = {}
            is_boss_encounter = false
            ShaguDPS.cached_current_damage = nil
            ShaguDPS.cached_current_heal = nil
            ShaguDPS.cached_current_death = nil
            ShaguDPS.cached_current_spellcast = nil
            ShaguDPS.cached_current_spellcast_details = nil
            ShaguDPS.cached_current_friendly_fire = nil
            ShaguDPS.cached_current_dispel = nil
            ShaguDPS.cached_current_sunder = nil
            ShaguDPS.cached_current_damage_taken = nil
            ShaguDPS.cached_current_enemy_damage_taken = nil
            ShaguDPS.cached_current_energize = nil
            ShaguDPS.cached_current_invalid_damage = nil
            ShaguDPS.cached_current_heal_taken = nil
            ShaguDPS.cached_current_dot_ticks = nil
            ShaguDPS.cached_current_hit_breakdown = nil
            ShaguDPS.cached_current_buff_coverage = nil
            ShaguDPS.cached_current_interrupt = nil
            ShaguDPS.cached_current_death_replays = nil
            combat_start_time = GetTime()
            data.combat_start_time = combat_start_time
            ShaguDPS.pendingBossRecord = nil
            diedBossesThisFight = {}
            parser.extraAttacks = {}
            ShaguDPS.battleStartDeathTimestamps = deepcopy(data.death_timestamps)
            if ShaguDPS.hasNampower and parser.initBuffCoverage then
                parser:initBuffCoverage()
            end
            if ShaguDPS.hasNampower and parser.initWeaknessCoverage then
                parser:initWeaknessCoverage()
            end
            ShaguDPS.activeBadDispelDebuffs = {}
            ShaguDPS.wrongDispels = {}
        end
    end
end

parser.combat:SetScript("OnEvent", function()
    if event == "PLAYER_UNGHOST" then
        this:UpdateState(true)
    elseif event == "PLAYER_LOGOUT" then
        ShaguDPS.SaveDataToCache()
        -- 若开启"数据导出到Imports"，在写入 WTF 前把全部统计数据导出到 Imports 并清空 WTF 数据
        if ShaguDPS.OnLogoutExport then ShaguDPS.OnLogoutExport() end
    else
        this:UpdateState()
    end
end)

parser.combat:SetScript("OnUpdate", function()
    local now = GetTime()
    if (this.tick or 1) > now then return else this.tick = now + 0.2 end
    this:UpdateState()
    ShaguDPS.RefreshHostileTargets()
    if ShaguDPS.Combat() and data.combat_start_time > 0 then
        if data.combat_start_time ~= ShaguDPS._lastCombatStartTime then
            ShaguDPS._lastCombatStartTime = data.combat_start_time
            if ShaguDPS.hasNampower and parser.initWeaknessCoverage then
                parser:initWeaknessCoverage()
            end
            if ShaguDPS.hasNampower and parser.initBuffCoverage then
                parser:initBuffCoverage()
            end
        end
    else
        ShaguDPS._lastCombatStartTime = 0
    end
end)

-- ============================================================================
-- 8. 伤害/治疗统计
-- ============================================================================

local function updateStats(source, action, target, value, school, datatype, effectiveValue, petType, ownerName, overkill)
    if type(source) ~= "string" or not tonumber(value) then return end
    if datatype == "damage" and source == target then return end
    if datatype == "damage" and not parser.enabled.damage then return end
    if datatype == "heal" and not parser.enabled.heal then return end
    if datatype == "heal" and config.heal_only_in_combat == 1 and not ShaguDPS.Combat() then return end

    if ownerName and config.merge_pets == 1 then
        if not data["classes"][ownerName] then parser:ScanName(ownerName) end
    end

    local effective = 0
    if datatype == "heal" then effective = effectiveValue or tonumber(value) end
    local over = overkill or 0

    local finalSource, finalAction
    if ownerName and config.merge_pets == 1 then
        finalSource = ownerName
        finalAction = source .. " - " .. action
        for segment = 0, 1 do
            local entry = data[datatype][segment]
            if not entry[finalSource] then
                entry[finalSource] = { ["_sum"] = 0, ["_ctime"] = 1, ["_overkill"] = 0 }
            end
        end
    else
        finalSource = source
        finalAction = action
        if ownerName and config.merge_pets == 0 then
            if not data["classes"][source] then
                data["classes"][source] = data["classes"][ownerName] or "__other__"
            end
        end
    end

    local now = GetTime()
    for segment = 0, 1 do
        local entry = data[datatype][segment]
        if not entry[finalSource] then
            local type = parser:ScanName(finalSource)
            if type == "PET" then
                local owner = data["classes"][finalSource]
                if not entry[owner] and parser:ScanName(owner) then
                    entry[owner] = { ["_sum"] = 0, ["_ctime"] = 1, ["_overkill"] = 0 }
                end
            elseif not type then
                if data["classes"][finalSource] then
                    entry[finalSource] = { ["_sum"] = 0, ["_ctime"] = 1, ["_overkill"] = 0 }
                else
                    break
                end
            else
                entry[finalSource] = { ["_sum"] = 0, ["_ctime"] = 1, ["_overkill"] = 0 }
            end
        end

        if entry[finalSource] then
            entry[finalSource][finalAction] = (entry[finalSource][finalAction] or 0) + tonumber(value)
            entry[finalSource]["_sum"] = (entry[finalSource]["_sum"] or 0) + tonumber(value)
            if datatype == "damage" then
                entry[finalSource]["_overkill"] = (entry[finalSource]["_overkill"] or 0) + over
                if not entry[finalSource]["_overkill_by_spell"] then
                    entry[finalSource]["_overkill_by_spell"] = {}
                end
                entry[finalSource]["_overkill_by_spell"][finalAction] = (entry[finalSource]["_overkill_by_spell"][finalAction] or 0) + over
            end
            if datatype == "heal" then
                entry[finalSource]["_esum"] = (entry[finalSource]["_esum"] or 0) + effective
                entry[finalSource]["_effective"] = entry[finalSource]["_effective"] or {}
                entry[finalSource]["_effective"][finalAction] = (entry[finalSource]["_effective"][finalAction] or 0) + effective
            end
            -- 活跃时间累加（_ctime）：两次事件间隔超过 5 秒视为脱战，只累加 5 秒封顶，
            -- 避免战斗中不连续出手时把发呆时间计入 DPS 分母
            entry[finalSource]["_tick"] = entry[finalSource]["_tick"] or now
            local diff = now - entry[finalSource]["_tick"]
            if diff > 0 then
                if entry[finalSource]["_tick"] + 5 < now then
                    entry[finalSource]["_ctime"] = entry[finalSource]["_ctime"] + 5
                else
                    entry[finalSource]["_ctime"] = entry[finalSource]["_ctime"] + diff
                end
                entry[finalSource]["_tick"] = now
            else
                entry[finalSource]["_tick"] = now
            end
        end
    end

    parser.lastRefreshEventTime = GetTime()
end

parser.AddData = function(self, source, action, target, value, school, datatype)
    updateStats(source, action, target, value, school, datatype)
end

-- ============================================================================
-- 9. 单位名 ↔ Token 解析（ScanName）
-- ============================================================================

parser.ScanName = function(self, name)
    if not name then return end
    for unit, _ in pairs(validUnits) do
        if UnitExists(unit) and SafeUnitName(unit) == name then
            if UnitIsPlayer(unit) then
                local _, class = UnitClass(unit)
                data["classes"][name] = class
                return "PLAYER"
            end
        end
    end

    local match, _, owner = string.find(name, "%((.*)%)", 1)
    if match and owner then
        if self:ScanName(owner) == "PLAYER" then
            data["classes"][name] = owner
            return "PET"
        end
    end

    for unit, _ in pairs(validPets) do
        if UnitExists(unit) and SafeUnitName(unit) == name then
            if strsub(unit, 0, 3) == "pet" then
                data["classes"][name] = SafeUnitName("player")
            elseif strsub(unit, 0, 8) == "partypet" then
                data["classes"][name] = SafeUnitName("party" .. strsub(unit, 9))
            elseif strsub(unit, 0, 7) == "raidpet" then
                data["classes"][name] = SafeUnitName("raid" .. strsub(unit, 8))
            end
            return "PET"
        end
    end

    if config.track_all_units == 1 then
        data["classes"][name] = data["classes"][name] or "__other__"
        return "OTHER"
    else
        return nil
    end
end

-- ============================================================================
-- 10. 额外攻击检测模块
-- ============================================================================

local extraAttackAbilities = {}
if ShaguDPS.Locale == "zhCN" then
    extraAttackAbilities = {
        ["风怒武器"] = 1, ["风怒图腾"] = 1, ["铸铁之怒"] = 1,
        ["正义之手"] = 1, ["风暴战斧"] = 1, ["永恒打击"] = 1,
        ["劈斩"] = 1, ["剑类武器专精"] = 1, ["癫狂打击"] = 1,
    }
else
    extraAttackAbilities = {
        ["Windfury Weapon"] = 1, ["Windfury Totem"] = 1, ["Fury of Forgewright"] = 1,
        ["Hand of Justice"] = 1, ["Flurry Axe"] = 1, ["Eternal Strike"] = 1,
        ["Hack and Slash"] = 1, ["Sword Specialization"] = 1, ["Maddened Strikes Passive"] = 1,
    }
end

parser.extraAttacks = parser.extraAttacks or {}

-- ============================================================================
-- 11. 辅助定义：破甲、易伤、打断等
-- ============================================================================

local sunderSpellIds = {
    [7386] = true, [7405] = true, [8380] = true, [11596] = true, [11597] = true,
    [8647] = true, [8649] = true, [8650] = true, [11197] = true, [11198] = true,
}

local vulnerabilitySpellIds = {
    [16928] = true, [3396] = true, [15235] = true,
}
local vulnerabilitySpellNames = {
    ["破甲"] = true, ["破甲攻击"] = true, ["鲁莽诅咒"] = true,
    ["精灵之火"] = true, ["精灵之火（野性）"] = true, ["精灵之火（熊）"] = true,
    ["腐烂血肉"] = true, ["哈卡盛宴"] = true, ["破甲斩"] = true,
    ["破碎铠甲"] = true, ["神圣破甲"] = true, ["暗影诅咒"] = true,
    ["元素诅咒"] = true, ["火焰易伤"] = true, ["暗影之波"] = true,
    ["暗影易伤"] = true, ["霜寒"] = true, ["破碎现实"] = true,
    ["艾林寄生"] = true, ["猎人印记"] = true, ["智慧审判"] = true,
    ["法术易伤"] = true, ["阿尔萨斯的礼物"] = true, ["烈焰打击"] = true,
    ["艾露恩的黄昏"] = true, ["艾露恩的恩赐"] = true, ["艾露恩的愤怒"] = true,
    ["艾露恩之怒"] = true, ["月神镰刀"] = true, ["十字军审判"] = true,
    ["勾爪"] = true, ["吸血鬼的拥抱"] = true,
}

local interruptSpellNames
if ShaguDPS.Locale == "zhCN" then
    interruptSpellNames = {
        ["脚踢"] = true, ["法术反制"] = true, ["拳击"] = true,
        ["盾击"] = true, ["大地震击"] = true, ["法术封锁"] = true,
        ["沉默"] = true,
    }
else
    interruptSpellNames = {
        ["Kick"] = true, ["Counterspell"] = true, ["Pummel"] = true,
        ["Shield Bash"] = true, ["Earth Shock"] = true, ["Spell Lock"] = true,
        ["Silence"] = true,
    }
end

-- ============================================================================
-- 12. 护盾吸收转治疗核心模块
-- ============================================================================

local shieldData = {
    ["真言术：盾"] = 0, ["寒冰护体"] = 0, ["持续护盾"] = 0,
    ["大地障壁"] = 0, ["法力护盾"] = 1,
    ["防护冰霜结界"] = 2, ["防护火焰结界"] = 3, ["防护暗影结界"] = 5,
    ["防护神圣结界"] = 7,
    ["火焰防护"] = 3, ["奥术防护"] = 6, ["防护冰霜"] = 2,
    ["防护火焰"] = 3, ["防护自然"] = 4, ["防护暗影"] = 5,
    ["防护神圣"] = 7, ["红月"] = 6, ["蓝月"] = 5,
}

local shieldMaxAbsorb = {
    ["真言术：盾"] = 1083, ["寒冰护体"] = 848, ["持续护盾"] = 500,
    ["大地障壁"] = 250, ["法力护盾"] = 570,
    ["防护冰霜结界"] = 920, ["防护火焰结界"] = 920, ["防护暗影结界"] = 920,
    ["防护神圣结界"] = 200,
    ["火焰防护"] = 3250, ["奥术防护"] = 3250, ["防护冰霜"] = 3250,
    ["防护火焰"] = 3250, ["防护自然"] = 3250, ["防护暗影"] = 3250,
    ["防护神圣"] = 3250, ["红月"] = 100000, ["蓝月"] = 100000,
}

local activeShields = {}
local recordHealTaken

local function processAbsorb(targetGuid, spellSchool, absorbAmount)
    if absorbAmount <= 0 or not activeShields[targetGuid] then
        return
    end
    -- 用户禁用治疗统计时不消耗 shield 数据（避免写被禁用的 data.heal/heal_taken 段）
    if not (parser.enabled.heal or parser.enabled.heal_taken) then
        -- 仅清理已耗尽的 shield（避免 activeShields 累积；新 shield 不会再被构造，
        -- 因为 onBuffAdded 现在受 heal/heal_taken 守卫）
        local shields = activeShields[targetGuid]
        for i = table.getn(shields), 1, -1 do
            if shields[i].maxAbsorb - shields[i].absorbed <= 0 then
                table.remove(shields, i)
            end
        end
        if table.getn(shields) == 0 then
            activeShields[targetGuid] = nil
        end
        return
    end

    local shields = activeShields[targetGuid]
    local remainingAbsorb = absorbAmount

    for i = table.getn(shields), 1, -1 do
        local shield = shields[i]
        local remaining = shield.maxAbsorb - shield.absorbed
        if remaining <= 0 then
            table.remove(shields, i)
        end
    end

    for i = table.getn(shields), 1, -1 do
        local shield = shields[i]
        local remaining = shield.maxAbsorb - shield.absorbed
        if remaining > 0 then
            local portion = math.min(remainingAbsorb, remaining)
            if portion > 0 then
                local shieldSpellName = GetSpellNameAndRankForId(shield.spellId)
                if shieldSpellName and shieldSpellName ~= "红月" and shieldSpellName ~= "蓝月" then
                    local casterName = SafeUnitName(shield.casterGuid)
                    local targetName = SafeUnitName(targetGuid)
                    if casterName and targetName then
                        updateStats(casterName, shieldSpellName, targetName, portion, 0, "heal", portion)
                        recordHealTaken(targetGuid, casterName, shieldSpellName, portion, portion)
                    end
                end
                shield.absorbed = shield.absorbed + portion
                remainingAbsorb = remainingAbsorb - portion
                if remainingAbsorb <= 0 then
                    break
                end
                if shield.absorbed >= shield.maxAbsorb then
                    table.remove(shields, i)
                end
            end
        else
            table.remove(shields, i)
        end
    end

    if table.getn(shields) == 0 then
        activeShields[targetGuid] = nil
    end
end

local function recordDotTick(source, action, ownerName)
    local finalSource, finalAction
    if ownerName and config.merge_pets == 1 then
        finalSource = ownerName
        finalAction = source .. " - " .. action
    else
        finalSource = source
        finalAction = action
        if ownerName and config.merge_pets == 0 then
            if not data["classes"][source] then
                data["classes"][source] = data["classes"][ownerName] or "__other__"
            end
        end
    end
    for segment = 0, 1 do
        local entry = data.dot_ticks[segment]
        if not entry[finalSource] then entry[finalSource] = {} end
        entry[finalSource][finalAction] = (entry[finalSource][finalAction] or 0) + 1
    end
    parser.lastRefreshEventTime = GetTime()
end

-- ============================================================================
-- 13. 技能命中明细记录
-- ============================================================================

local function recordHitBreakdown(finalName, finalAction, htype)
    if not finalName or not finalAction then return end
    if not htype then htype = "normal" end
    if not parser.enabled.damage then return end
    for segment = 0, 1 do
        local seg = data.hit_breakdown[segment]
        if not seg[finalName] then seg[finalName] = {} end
        if not seg[finalName][finalAction] then
            seg[finalName][finalAction] = {
                crit = 0, glancing = 0, dodge = 0, parry = 0, block = 0,
                resist = 0, miss = 0, normal = 0, crushing = 0,
            }
        end
        local h = seg[finalName][finalAction]
        h[htype] = (h[htype] or 0) + 1
    end
end

-- 从 Nampower 平砍 hitInfo/victimState 推导命中类型
-- @return "crit"/"glancing"/"crushing"/"block"/"dodge"/"parry"/"miss"/"resist"/"normal"
local function GetSwingHitType(hitInfo, victimState, totalDamage)
    if bit.band(hitInfo, 32768) ~= 0 then return "crushing" end
    if victimState == 2 then return "dodge" end
    if victimState == 3 then return "parry" end
    if victimState == 5 then return "block" end
    if victimState == 6 or victimState == 7 or victimState == 8 then return "miss" end
    if bit.band(hitInfo, 16) ~= 0 then return "miss" end
    if bit.band(hitInfo, 64) ~= 0 and totalDamage == 0 then return "resist" end
    if bit.band(hitInfo, 128) ~= 0 then return "crit" end
    if bit.band(hitInfo, 16384) ~= 0 then return "glancing" end
    return "normal"
end

-- ============================================================================
-- 14. 环境伤害类型表（处理函数见第 28 节）
-- ============================================================================

local envDmgSchool = {
    [3] = 2, [4] = 3, [5] = 2,
}
local ENV_DMG_NAMES = {
    [0] = "疲劳", [1] = "溺水", [2] = "坠落",
    [3] = "熔岩", [4] = "软泥", [5] = "火焰", [6] = "虚空",
}

-- ============================================================================
-- 15. 能量回复统计专用函数
-- ============================================================================

local POWER_NAMES = {
    [0] = "法力", [1] = "怒气", [2] = "集中值", [3] = "能量",
}

local function updateEnergizeStats(source, action, target, amount, powerType, ownerName)
    if type(source) ~= "string" or not tonumber(amount) then return end
    if not POWER_NAMES[powerType] then return end
    if powerType == 1 then
        amount = amount / 10
    end

    local finalSource, finalAction
    if ownerName then
        finalSource = ownerName .. " - " .. source
        if not data["classes"][finalSource] then
            data["classes"][finalSource] = data["classes"][ownerName] or "__other__"
        end
        finalAction = action .. " (" .. POWER_NAMES[powerType] .. ")"
    else
        finalSource = source
        finalAction = action .. " (" .. POWER_NAMES[powerType] .. ")"
    end

    for segment = 0, 1 do
        local entry = data.energize[segment]
        if not entry[finalSource] then
            local type = parser:ScanName(finalSource)
            if type == "PET" then
                local owner = data["classes"][finalSource]
                if not entry[owner] and parser:ScanName(owner) then
                    entry[owner] = { ["_sum"] = 0, ["_ctime"] = 1, ["_by_type"] = {} }
                end
            elseif not type then
                if data["classes"][finalSource] then
                    entry[finalSource] = { ["_sum"] = 0, ["_ctime"] = 1, ["_by_type"] = {} }
                else
                    break
                end
            else
                entry[finalSource] = { ["_sum"] = 0, ["_ctime"] = 1, ["_by_type"] = {} }
            end
        end

        if entry[finalSource] then
            local rec = entry[finalSource]
            rec[finalAction] = (rec[finalAction] or 0) + amount
            rec["_sum"] = (rec["_sum"] or 0) + amount
            rec["_by_type"] = rec["_by_type"] or {}
            rec["_by_type"][powerType] = (rec["_by_type"][powerType] or 0) + amount

            rec["_ctime"] = rec["_ctime"] or 1
            local now = GetTime()
            rec["_tick"] = rec["_tick"] or now
            local diff = now - rec["_tick"]
            if diff > 0 then
                if rec["_tick"] + 5 < now then
                    rec["_ctime"] = rec["_ctime"] + 5
                else
                    rec["_ctime"] = rec["_ctime"] + diff
                end
                rec["_tick"] = now
            else
                rec["_tick"] = now
            end
        end
    end

    parser.lastRefreshEventTime = GetTime()
end

-- ============================================================================
-- 16. 无效伤害记录
-- ============================================================================

local function addInvalidDamage(source, action, target, value, school, overkill)
    if type(source) ~= "string" or not tonumber(value) then return end
    if source == target then return end

    local finalSource = source
    local finalAction = action

    for segment = 0, 1 do
        local entry = data.invalid_damage[segment]
        if not entry[finalSource] then
            if not data["classes"][finalSource] then
                parser:ScanName(finalSource)
            end
            entry[finalSource] = { _sum = 0, _ctime = 1, _overkill = 0, _by_target = {} }
        end
        local rec = entry[finalSource]
        rec._sum = (rec._sum or 0) + tonumber(value)
        rec._overkill = (rec._overkill or 0) + (overkill or 0)

        if not rec._by_target[target] then
            rec._by_target[target] = { _sum = 0 }
        end
        local tgtEntry = rec._by_target[target]
        tgtEntry._sum = tgtEntry._sum + tonumber(value)
        tgtEntry[finalAction] = (tgtEntry[finalAction] or 0) + tonumber(value)
        tgtEntry["_count_"..finalAction] = (tgtEntry["_count_"..finalAction] or 0) + 1

        rec._ctime = rec._ctime or 1
        local now = GetTime()
        rec._tick = rec._tick or now
        local diff = now - rec._tick
        if diff > 0 then
            if rec._tick + 5 < now then
                rec._tick = now
                rec._ctime = rec._ctime + 5
            else
                rec._ctime = rec._ctime + diff
            end
            rec._tick = now
        else
            rec._tick = now
        end
    end

    parser.lastRefreshEventTime = GetTime()
end

-- ============================================================================
-- 17. 单位判断工具函数
-- ============================================================================

local function isNameIgnored(name)
    if not name then return false end
    return ShaguDPS.ignoredUnitNames[name] == true
end

local playerGroupGUIDs = {}
local function rebuildPlayerGroupGUIDs()
    local group = {}
    for i = 1, 4 do
        local g = GetUnitGUID("party" .. i)
        if g then group[g] = true end
    end
    for i = 1, 40 do
        local g = GetUnitGUID("raid" .. i)
        if g then group[g] = true end
    end
    playerGroupGUIDs = group
end
-- 仅 Nampower 模式需要追踪队伍 GUID（vanilla 模式由 parser-vanilla 全权接管）
if ShaguDPS.hasNampower then
    local unitGUIDCacheFrame = CreateFrame("Frame")
    unitGUIDCacheFrame:RegisterEvent("PLAYER_LOGIN")
    unitGUIDCacheFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    unitGUIDCacheFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
    unitGUIDCacheFrame:RegisterEvent("RAID_ROSTER_UPDATE")
    unitGUIDCacheFrame:SetScript("OnEvent", function() rebuildPlayerGroupGUIDs() end)
    rebuildPlayerGroupGUIDs()
end

local function isPlayerOrGroupMember(guid)
    if not guid then return false end
    if guid == GetUnitGUID("player") then return true end
    if guid == GetUnitGUID("pet") then return true end
    if playerGroupGUIDs[guid] then return true end
    for i = 1, 4 do
        if GetUnitGUID("partypet" .. i) == guid then return true end
    end
    for i = 1, 40 do
        if GetUnitGUID("raidpet" .. i) == guid then return true end
    end
    return false
end

-- 判断单位是否为世界 BOSS（用于 BOSS 战/小怪划分）
local function IsWorldBoss(guid)
    if not guid then return false end
    return UnitClassification(guid) == "worldboss"
end

local function checkBossInvolvement(casterGuid, targetGuid)
    if not IsWorldBoss(casterGuid) and not IsWorldBoss(targetGuid) then return end
    if IsInInstance() then
        is_boss_encounter = true
        return
    end
    if IsWorldBoss(casterGuid) and isPlayerOrGroupMember(targetGuid) then
        is_boss_encounter = true
    end
    if IsWorldBoss(targetGuid) and isPlayerOrGroupMember(casterGuid) then
        is_boss_encounter = true
    end
end

local function IsCritter(guid)
    if not guid then return false end
    local creatureType = UnitCreatureType(guid)
    if not creatureType then return false end
    return creatureType == "小动物" or creatureType == "Critter"
end

local function CalculateOverkill(targetGuid, rawDamage)
    if not targetGuid or not rawDamage or rawDamage <= 0 then return 0 end
    local health = GetUnitField(targetGuid, "health")
    if health and health > 0 then
        local over = rawDamage - health
        if over > 0 then
            healthCache[targetGuid] = nil
            return over
        else
            healthCache[targetGuid] = health - rawDamage
            return 0
        end
    end
    healthCache[targetGuid] = nil
    return rawDamage
end

local function TrackCombatant(casterGuid, targetGuid)
    if not casterGuid or not targetGuid then return end
    if casterGuid == "0x0000000000000000" or targetGuid == "0x0000000000000000" then return end
    -- 勾选“显示附近所有单位”时，识别附近玩家/宠物的职业用于图标
    -- 团队/小队/玩家自身：写入 data["classes"]（参与职业染色 + 图标）
    -- 附近非队伍玩家：只写入 ShaguDPS.classIcons（仅职业图标，不改变染色）
    -- 用 pcall 包裹 UnitClass，避免个别环境不支持 GUID 传入导致报错
    if ShaguDPS.hasNampower and config.track_all_units == 1 then
        local function unitClassSafe(guid)
            local ok, _, cls = pcall(UnitClass, guid)
            if ok then return cls end
            return nil
        end
        local function tryClass(guid)
            if not guid then return end
            if UnitIsPlayer(guid) then
                local cn = SafeUnitName(guid)
                if cn and not isUnknownName(cn) then
                    local cls = unitClassSafe(guid)
                    if cls and RAID_CLASS_COLORS[cls] then
                        if playerGroupGUIDs[guid] then
                            -- 团队/小队/玩家自身：参与染色
                            data["classes"][cn] = cls
                        else
                            -- 附近非队伍玩家：仅图标
                            if not ShaguDPS.classIcons then ShaguDPS.classIcons = {} end
                            ShaguDPS.classIcons[cn] = cls
                        end
                    end
                end
            else
                -- 宠物：沿用主人职业（含 merge_pets=0 的“主人 - 宠物”条目）
                local ownerName, _, og = GetOwnerInfoFromPetGUID(guid)
                if ownerName and og then
                    if data["classes"][ownerName] == nil or data["classes"][ownerName] == "__other__" then
                        local cls = unitClassSafe(og)
                        if cls and RAID_CLASS_COLORS[cls] then
                            data["classes"][ownerName] = cls
                        end
                    end
                    local pn = SafeUnitName(guid)
                    if pn and not isUnknownName(pn) then
                        if data["classes"][pn] == nil or data["classes"][pn] == "__other__" then
                            data["classes"][pn] = ownerName
                        end
                        if config.merge_pets == 0 then
                            local merged = ownerName .. " - " .. pn
                            if not data["classes"][merged] then
                                data["classes"][merged] = data["classes"][ownerName] or "__other__"
                            end
                        end
                    end
                end
            end
        end
        tryClass(casterGuid)
        tryClass(targetGuid)
    end
    local isCasterGroup = isPlayerOrGroupMember(casterGuid)
    if not isCasterGroup then
        local _, _, ownerGUID = GetOwnerInfoFromPetGUID(casterGuid)
        if ownerGUID and isPlayerOrGroupMember(ownerGUID) then
            isCasterGroup = true
        end
    end
    if isCasterGroup then
        ShaguDPS.AddHostileTarget(targetGuid)
    elseif isPlayerOrGroupMember(targetGuid) then
        ShaguDPS.AddHostileTarget(casterGuid)
    end
end

-- ============================================================================
-- 18. 法术名称缓存与通用函数
-- ============================================================================

local spellNameCache = {}

local function getSpellName(spellId)
    if not spellId or spellId == 0 then return "自动攻击" end
    local cached = spellNameCache[spellId]
    if cached then return cached end
    local name = GetSpellRecField(spellId, "name")
    if not name then name = "技能" .. spellId end
    spellNameCache[spellId] = name
    return name
end

local function isVulnerabilitySpell(spellId)
    if not spellId or spellId == 0 then return false end
    local name = getSpellName(spellId)
    if vulnerabilitySpellIds[spellId] then return true end
    if vulnerabilitySpellNames[name] then return true end
    return false
end

local function GetDispelTypeFromSpellId(spellId)
    if not spellId then return nil end
    local dispel = GetSpellRecField(spellId, "dispel")
    if dispel and dispel > 0 then
        return dispel
    end
    return nil
end

local function hasDirectDamageEffect(spellId)
    if not spellId or spellId == 0 then return false end
    local effects = GetSpellRecField(spellId, "effect")
    if effects then
        for i = 1, table.getn(effects) do
            if effects[i] == 2 then return true end
        end
    end
    return false
end

-- ============================================================================
-- 19. 错误驱散监测函数
-- ============================================================================

local function RecordWrongDispel(casterName, targetName, debuffName, spellName)
    if not casterName or not targetName or not debuffName or not spellName then return end
    ShaguDPS.wrongDispels = ShaguDPS.wrongDispels or {}
    if not ShaguDPS.wrongDispels[casterName] then
        ShaguDPS.wrongDispels[casterName] = {}
    end
    if not ShaguDPS.wrongDispels[casterName][targetName] then
        ShaguDPS.wrongDispels[casterName][targetName] = {}
    end
    ShaguDPS.wrongDispels[casterName][targetName][debuffName] =
        (ShaguDPS.wrongDispels[casterName][targetName][debuffName] or 0) + 1

    for segment = 0, 1 do
        local entry = data.dispel[segment]
        if not entry[casterName] then
            entry[casterName] = { _total = 0, _offensive = 0, _defensive = 0 }
        end
        local p = entry[casterName]
        p._total = (p._total or 0) + 1
        if not p["错误驱散"] then p["错误驱散"] = {} end
        if not p["错误驱散"][targetName] then p["错误驱散"][targetName] = {} end
        p["错误驱散"][targetName][debuffName] =
            (p["错误驱散"][targetName][debuffName] or 0) + 1
    end

    parser.lastRefreshEventTime = GetTime()
end

local function CheckWrongDispelOnSpellGo(spellName, casterGuid, targetGuid, finalName)
    if not spellName or not casterGuid or not targetGuid then return end
    if targetGuid == "0x0000000000000000" then return end
    if not ShaguDPS.dispelSpells[spellName] then return end
    local activeBads = ShaguDPS.activeBadDispelDebuffs[targetGuid]
    if not activeBads then return end
    local casterName = finalName or SafeUnitName(casterGuid)
    local targetName = SafeUnitName(targetGuid)
    if not casterName or not targetName then return end
    if isUnknownName(casterName) or isUnknownName(targetName) then return end
    local spellTypes = ShaguDPS.dispelSpells[spellName].types or {}
    for spellId, debuffInfo in pairs(activeBads) do
        for _, dt in ipairs(spellTypes) do
            if dt == debuffInfo.dispelType then
                RecordWrongDispel(casterName, targetName, debuffInfo.name, spellName)
                break
            end
        end
    end
end

local function MarkBadDispelDebuff(targetGuid, spellId)
    if not targetGuid or not spellId then return end
    local spellName = getSpellName(spellId)
    local badInfo = ShaguDPS.badDispelDebuffs[spellName]
    if badInfo then
        local dispelType = GetDispelTypeFromSpellId(spellId) or badInfo.type
        if dispelType then
            ShaguDPS.activeBadDispelDebuffs[targetGuid] =
                ShaguDPS.activeBadDispelDebuffs[targetGuid] or {}
            ShaguDPS.activeBadDispelDebuffs[targetGuid][spellId] = {
                name = spellName,
                dispelType = dispelType,
            }
        end
    end
end

local function UnmarkBadDispelDebuff(targetGuid, spellId)
    if not targetGuid or not ShaguDPS.activeBadDispelDebuffs[targetGuid] then return end
    ShaguDPS.activeBadDispelDebuffs[targetGuid][spellId] = nil
    local hasAny = false
    for _ in pairs(ShaguDPS.activeBadDispelDebuffs[targetGuid]) do
        hasAny = true
        break
    end
    if not hasAny then
        ShaguDPS.activeBadDispelDebuffs[targetGuid] = nil
    end
end

-- ============================================================================
-- 20. 光环覆盖率统计（buff/debuff 生效时间占比）
--     进入战斗时 initBuffCoverage 记录战前已存在的 aura 起始时间；
--     战斗中被移除的 aura 在 handleBuffRemove 结算覆盖时长；
--     脱战时 finalizeBuffCoverage 结算剩余 aura 并写入 data.buff_coverage。
-- ============================================================================

-- 该单位是否应纳入统计：track_all_units=1 时全部计入，否则仅玩家自身与小/团队成员
local function isUnitTracked(guid)
    if not guid then return false end
    if config.track_all_units == 1 then return true end
    if guid == GetUnitGUID("player") then return true end
    return playerGroupGUIDs[guid] == true
end

local function isPlayerUnit(guid)
    if not guid then return false end
    return UnitIsPlayer(guid)
end

local function getPlayerAuraList(guid)
    local buffAuras = {}
    local debuffAuras = {}
    if not guid then return buffAuras, debuffAuras end
    if not isPlayerUnit(guid) then return buffAuras, debuffAuras end
    local auraTable = GetUnitField(guid, "aura")
    if not auraTable then return buffAuras, debuffAuras end
    for i = 1, table.getn(auraTable) do
        local spellId = auraTable[i]
        if spellId and spellId ~= 0 then
            if i <= 32 then
                buffAuras[spellId] = true
            else
                debuffAuras[spellId] = true
            end
        end
    end
    return buffAuras, debuffAuras
end

function parser:initBuffCoverage()
    data.buff_coverage[1] = {}
    ShaguDPS.buff_coverage_active = {}
    local now = GetTime()
    for unit, _ in pairs(validUnits) do
        local guid = GetUnitGUID(unit)
        if guid and isPlayerUnit(guid) and isUnitTracked(guid) then
            local name = SafeUnitName(unit)
            if name and not isUnknownName(name) then
                data.buff_coverage[1][name] = {
                    ["_total_time"] = 0,
                    ["buff"] = {},
                    ["debuff"] = {},
                }
                local buffAuras, debuffAuras = getPlayerAuraList(guid)
                local active = { buff = {}, debuff = {} }
                if buffAuras then
                    for spellId, _ in pairs(buffAuras) do
                        active.buff[spellId] = now
                    end
                end
                if debuffAuras then
                    for spellId, _ in pairs(debuffAuras) do
                        active.debuff[spellId] = now
                    end
                end
                ShaguDPS.buff_coverage_active[name] = active
            end
        end
    end
end

function parser:handleBuffAdd(guid, spellId, state, auraType)
    if not ShaguDPS.Combat() then return end
    if not guid or not spellId or spellId == 0 then return end
    if not isPlayerUnit(guid) then return end
    if not isUnitTracked(guid) then return end
    local name = SafeUnitName(guid)
    if not name or isUnknownName(name) then return end
    if not data.buff_coverage[1][name] then
        data.buff_coverage[1][name] = { ["_total_time"] = 0, ["buff"] = {}, ["debuff"] = {} }
    end
    if not ShaguDPS.buff_coverage_active[name] then
        ShaguDPS.buff_coverage_active[name] = { buff = {}, debuff = {} }
    end
    if not ShaguDPS.buff_coverage_active[name][auraType] then
        ShaguDPS.buff_coverage_active[name][auraType] = {}
    end
    if state == 2 and ShaguDPS.buff_coverage_active[name][auraType][spellId] then
        return
    end
    if not ShaguDPS.buff_coverage_active[name][auraType][spellId] then
        ShaguDPS.buff_coverage_active[name][auraType][spellId] = GetTime()
    end
end

function parser:handleBuffRemove(guid, spellId, state, auraType)
    if not ShaguDPS.Combat() then return end
    if not guid or not spellId or spellId == 0 then return end
    if not isPlayerUnit(guid) then return end
    if not isUnitTracked(guid) then return end
    if state == 2 then return end
    local name = SafeUnitName(guid)
    if not name or isUnknownName(name) then return end
    local active = ShaguDPS.buff_coverage_active[name]
    if active and active[auraType] and active[auraType][spellId] then
        local startTime = active[auraType][spellId]
        local duration = GetTime() - startTime
        if duration > 0 then
            local playerData = data.buff_coverage[1][name]
            if not playerData then
                playerData = { ["_total_time"] = 0, ["buff"] = {}, ["debuff"] = {} }
                data.buff_coverage[1][name] = playerData
            end
            if not playerData[auraType] then
                playerData[auraType] = {}
            end
            playerData[auraType][spellId] = (playerData[auraType][spellId] or 0) + duration
        end
        active[auraType][spellId] = nil
    end
end

function parser:finalizeBuffCoverage(fightDuration)
    if not fightDuration or fightDuration <= 0 then return end
    local now = GetTime()

    for name, playerData in pairs(data.buff_coverage[1]) do
        playerData["_total_time"] = fightDuration
    end

    for name, active in pairs(ShaguDPS.buff_coverage_active) do
        if active then
            local playerData = data.buff_coverage[1][name]
            if not playerData then
                playerData = { ["_total_time"] = fightDuration, ["buff"] = {}, ["debuff"] = {} }
                data.buff_coverage[1][name] = playerData
            end
            if active.buff then
                for spellId, startTime in pairs(active.buff) do
                    if startTime and startTime > 0 then
                        local duration = now - startTime
                        if duration > 0 then
                            if not playerData["buff"] then playerData["buff"] = {} end
                            playerData["buff"][spellId] = (playerData["buff"][spellId] or 0) + duration
                        end
                    end
                end
            end
            if active.debuff then
                for spellId, startTime in pairs(active.debuff) do
                    if startTime and startTime > 0 then
                        local duration = now - startTime
                        if duration > 0 then
                            if not playerData["debuff"] then playerData["debuff"] = {} end
                            playerData["debuff"][spellId] = (playerData["debuff"][spellId] or 0) + duration
                        end
                    end
                end
            end
        end
    end
    ShaguDPS.buff_coverage_active = {}

    for name, playerData in pairs(data.buff_coverage[1]) do
        if not data.buff_coverage[0][name] then
            data.buff_coverage[0][name] = { ["_total_time"] = 0, ["buff"] = {}, ["debuff"] = {} }
        end
        local target = data.buff_coverage[0][name]
        target["_total_time"] = (target["_total_time"] or 0) + (playerData["_total_time"] or 0)
        if playerData["buff"] then
            if not target["buff"] then target["buff"] = {} end
            for k, v in pairs(playerData["buff"]) do
                target["buff"][k] = (target["buff"][k] or 0) + v
            end
        end
        if playerData["debuff"] then
            if not target["debuff"] then target["debuff"] = {} end
            for k, v in pairs(playerData["debuff"]) do
                target["debuff"][k] = (target["debuff"][k] or 0) + v
            end
        end
    end
end

function parser:resetBuffCoverage()
    data.buff_coverage[0] = {}
    data.buff_coverage[1] = {}
    ShaguDPS.buff_coverage_active = {}
    ShaguDPS.cached_current_buff_coverage = nil
    data.small_fight.buff_coverage = {}
end
ShaguDPS.resetBuffCoverage = parser.resetBuffCoverage

-- ============================================================================
-- 21. 易伤覆盖率统计（敌人目标身上的易伤 debuff 覆盖率）
--     initWeaknessCoverage 在进战初始化；Aura 回调实时记录每个目标的易伤
--     debuff 起始时间；目标死亡或脱战时结算覆盖率并写入 data.weakness_coverage。
-- ============================================================================

-- 本场战斗已扫描过的目标 GUID 表（用于防重复扫描）
ShaguDPS.weaknessScannedTargets = {}

function parser:initWeaknessCoverage()
    data.weakness_coverage[1] = {}
    ShaguDPS.weakness_coverage_active = {}
    ShaguDPS.weaknessScannedTargets = {}
    ShaguDPS.weaknessTrackedTargets = {}
end

function parser:HandleWeaknessTargetDeath(guid, name, deathTime)
    -- 用户禁用易伤覆盖率时不写入 data.weakness_coverage
    -- （active 表的清理推迟到 NO_COMBAT 时的 finalizeWeaknessCoverage）
    if not parser.enabled.weakness_coverage then return end
    if not name or isUnknownName(name) then return end
    if not data.weakness_coverage or not data.weakness_coverage[1] then
        data.weakness_coverage[1] = {}
    end
    local isTracked = ShaguDPS.weaknessTrackedTargets and ShaguDPS.weaknessTrackedTargets[guid]
    local targetData = data.weakness_coverage[1][name]
    if not isTracked and not targetData then
        return
    end
    if not targetData then
        targetData = { ["_total_time"] = 0 }
        data.weakness_coverage[1][name] = targetData
    end
    local startTime = data.combat_start_time
    if startTime <= 0 then
        startTime = combat_start_time
    end
    if startTime <= 0 then
        startTime = deathTime - (data.last_fight_duration or 0)
    end
    local effectiveTime = deathTime - startTime
    if effectiveTime < 0 then effectiveTime = 0 end
    local existing = targetData["_total_time"] or 0
    if existing <= 0 or effectiveTime < existing then
        targetData["_total_time"] = effectiveTime
    end
    local active = ShaguDPS.weakness_coverage_active[name]
    if active then
        for spellId, start in pairs(active) do
            if start and start > 0 and start < deathTime then
                local duration = deathTime - start
                if duration > 0 then
                    targetData[spellId] = (targetData[spellId] or 0) + duration
                end
            end
            active[spellId] = nil
        end
    end
end

function parser:ScanWeaknessOnTarget(targetGuid)
    if not targetGuid or targetGuid == "0x0000000000000000" then return end
    if ShaguDPS.weaknessScannedTargets[targetGuid] then return end
    local targetName = SafeUnitName(targetGuid)
    if not targetName or isUnknownName(targetName) then return end
    if IsFriendly(targetGuid) then return end
    if config.track_all_units ~= 1 then
        if not (ShaguDPS.weaknessTrackedTargets and ShaguDPS.weaknessTrackedTargets[targetGuid]) then
            return
        end
    end

    if not data.weakness_coverage or not data.weakness_coverage[1] then
        data.weakness_coverage[1] = {}
    end
    if not data.weakness_coverage[1][targetName] then
        data.weakness_coverage[1][targetName] = { ["_total_time"] = 0 }
    end
    local auraTable = GetUnitField(targetGuid, "aura")
    if not auraTable then
        ShaguDPS.weaknessScannedTargets[targetGuid] = true
        return
    end

    local startTime = data.combat_start_time
    if startTime <= 0 then startTime = GetTime() end
    for i = 1, table.getn(auraTable) do
        local spellId = auraTable[i]
        if spellId and spellId ~= 0 and isVulnerabilitySpell(spellId) then
            if not data.weakness_coverage[1][targetName][spellId] then
                data.weakness_coverage[1][targetName][spellId] = 0
            end
            if not ShaguDPS.weakness_coverage_active[targetName] then
                ShaguDPS.weakness_coverage_active[targetName] = {}
            end
            local existingStart = ShaguDPS.weakness_coverage_active[targetName][spellId]
            if existingStart then
                if data.combat_start_time > 0 and existingStart < data.combat_start_time then
                    ShaguDPS.weakness_coverage_active[targetName][spellId] = data.combat_start_time
                end
            else
                local effectiveStart = data.combat_start_time > 0 and data.combat_start_time or GetTime()
                ShaguDPS.weakness_coverage_active[targetName][spellId] = effectiveStart
            end
        end
    end
    ShaguDPS.weaknessScannedTargets[targetGuid] = true
end

function parser:handleWeaknessAuraAdd(guid, spellId, state, auraType)
    if not guid or not spellId or spellId == 0 then return end
    if not isVulnerabilitySpell(spellId) then return end
    if not ShaguDPS.weaknessScannedTargets or not ShaguDPS.weaknessScannedTargets[guid] then
        return
    end
    local targetName = SafeUnitName(guid)
    if not targetName or isUnknownName(targetName) then return end
    if state == 2 and ShaguDPS.weakness_coverage_active[targetName] and ShaguDPS.weakness_coverage_active[targetName][spellId] then return end

    if data.weakness_coverage and data.weakness_coverage[1] and data.weakness_coverage[1][targetName] then
        local td = data.weakness_coverage[1][targetName]
        if td["_total_time"] and td["_total_time"] > 0 then
            return
        end
    end

    if not IsFriendly(guid) then
        if not data.weakness_coverage or not data.weakness_coverage[1] then
            data.weakness_coverage[1] = {}
        end
        if not data.weakness_coverage[1][targetName] then
            data.weakness_coverage[1][targetName] = { ["_total_time"] = 0 }
        end
        if not ShaguDPS.weakness_coverage_active[targetName] then
            ShaguDPS.weakness_coverage_active[targetName] = {}
        end
        local existingStart = ShaguDPS.weakness_coverage_active[targetName][spellId]
        if existingStart then
            if data.combat_start_time > 0 and existingStart < data.combat_start_time then
                ShaguDPS.weakness_coverage_active[targetName][spellId] = data.combat_start_time
            end
        else
            local start = GetTime()
            if data.combat_start_time > 0 and start < data.combat_start_time then
                start = data.combat_start_time
            end
            ShaguDPS.weakness_coverage_active[targetName][spellId] = start
        end
    end
end

function parser:handleWeaknessAuraRemove(guid, spellId, state, auraType)
    if not guid or not spellId or spellId == 0 then return end
    if not ShaguDPS.weaknessScannedTargets or not ShaguDPS.weaknessScannedTargets[guid] then
        return
    end
    if state == 2 then return end
    local targetName = SafeUnitName(guid)
    if not targetName or isUnknownName(targetName) then return end
    local active = ShaguDPS.weakness_coverage_active[targetName]
    if active and active[spellId] then
        local startTime = active[spellId]
        local duration = GetTime() - startTime
        if duration > 0 then
            if not data.weakness_coverage or not data.weakness_coverage[1] then
                data.weakness_coverage[1] = {}
            end
            local targetData = data.weakness_coverage[1][targetName]
            if not targetData then
                targetData = { ["_total_time"] = 0 }
                data.weakness_coverage[1][targetName] = targetData
            end
            targetData[spellId] = (targetData[spellId] or 0) + duration
        end
        active[spellId] = nil
    end
end

function parser:finalizeWeaknessCoverage(fightDuration)
    if not fightDuration or fightDuration <= 0 then
        fightDuration = data.last_fight_duration or 0
    end
    if fightDuration <= 0 then return end

    if not data.weakness_coverage or not data.weakness_coverage[1] then
        data.weakness_coverage[1] = {}
        return
    end

    local now = GetTime()
    for targetName, targetData in pairs(data.weakness_coverage[1]) do
        if not targetData then
            targetData = { ["_total_time"] = fightDuration }
            data.weakness_coverage[1][targetName] = targetData
        else
            if not targetData["_total_time"] or targetData["_total_time"] <= 0 then
                targetData["_total_time"] = fightDuration
            else
                targetData["_total_time"] = math.min(targetData["_total_time"], fightDuration)
            end
        end
    end
    for targetName, active in pairs(ShaguDPS.weakness_coverage_active) do
        if active then
            local targetData = data.weakness_coverage[1][targetName]
            if not targetData then
                targetData = { ["_total_time"] = fightDuration }
                data.weakness_coverage[1][targetName] = targetData
            end
            local maxTime = targetData["_total_time"] or fightDuration
            for spellId, startTime in pairs(active) do
                if startTime and startTime > 0 then
                    local duration = now - startTime
                    if duration > 0 then
                        if duration > maxTime then
                            duration = maxTime
                        end
                        targetData[spellId] = (targetData[spellId] or 0) + duration
                    end
                end
            end
        end
    end

    ShaguDPS.weakness_coverage_active = {}

    for targetName, targetData in pairs(data.weakness_coverage[1]) do
        if not data.weakness_coverage[0][targetName] then
            data.weakness_coverage[0][targetName] = { ["_total_time"] = 0 }
        end
        local full = data.weakness_coverage[0][targetName]
        full["_total_time"] = (full["_total_time"] or 0) + (targetData["_total_time"] or 0)
        for k, v in pairs(targetData) do
            if k ~= "_total_time" then
                full[k] = (full[k] or 0) + v
            end
        end
    end
end

-- ============================================================================
-- 22. 护盾生命周期与 DoT/易伤标记（Aura 事件）
-- ============================================================================

local recentDotApply = {}

local function onAuraCast(spellId, casterGuid, targetGuid, effect, effectAuraName, effectAmplitude, effectMiscValue, durationMs, auraCapStatus)
    local spellName = getSpellName(spellId)

    if effectAuraName == 3 or effectAuraName == 89 then
        if not hasDirectDamageEffect(spellId) then
            local dotKey = (casterGuid or "") .. "|" .. (spellId or 0) .. "|" .. (targetGuid or "")
            local now = GetTime()
            local lastApply = recentDotApply[dotKey]
            if not (lastApply and (now - lastApply) < 1.0) then
                recentDotApply[dotKey] = now
                local casterName = SafeUnitName(casterGuid)
                if casterName and not isUnknownName(casterName) then
                    local ownerName, _ = GetOwnerInfoFromPetGUID(casterGuid)
                    local finalName, finalAction
                    if ownerName then
                        if config.merge_pets == 1 then
                            finalName = ownerName
                            finalAction = casterName .. " - " .. spellName
                        else
                            finalName = ownerName .. " - " .. casterName
                            finalAction = spellName
                        end
                    else
                        finalName = casterName
                        finalAction = spellName
                    end
                    -- 剔除误伤：对友方目标施加 DoT 的命中明细不计入
                    if not (config.hide_friendly_damage == 1 and targetGuid and targetGuid ~= "0x0000000000000000" and IsFriendly(targetGuid)) then
                        recordHitBreakdown(finalName, finalAction, "normal")
                    end
                end
            end
        end
    end

    if ShaguDPS.Combat() and targetGuid and targetGuid ~= "0x0000000000000000" and not IsFriendly(targetGuid) then
        parser:ScanWeaknessOnTarget(targetGuid)
    end

    if shieldData[spellName] then
        local schoolFlag = shieldData[spellName] or 0
        if not activeShields[targetGuid] then
            activeShields[targetGuid] = {}
        end

        local existing = nil
        for i, s in ipairs(activeShields[targetGuid]) do
            if s.spellId == spellId then
                existing = s
                break
            end
        end

        if existing then
            existing.casterGuid = casterGuid
            existing.school = schoolFlag
            existing.maxAbsorb = shieldMaxAbsorb[spellName] or math.huge
            existing.absorbed = 0
        else
            local maxAbsorb = shieldMaxAbsorb[spellName] or math.huge
            table.insert(activeShields[targetGuid], {
                casterGuid = casterGuid,
                spellId = spellId,
                school = schoolFlag,
                absorbed = 0,
                maxAbsorb = maxAbsorb
            })
        end
    end
end

local function onBuffRemoved(guid, luaSlot, spellId, stacks, auraLevel, auraSlot, state)
    if state == 1 and activeShields[guid] then
        for i = table.getn(activeShields[guid]), 1, -1 do
            if activeShields[guid][i].spellId == spellId then
                table.remove(activeShields[guid], i)
            end
        end
        if table.getn(activeShields[guid]) == 0 then
            activeShields[guid] = nil
        end
    end
end

local function onBuffAdded(guid, luaSlot, spellId, stacks, auraLevel, auraSlot, state)
    if ShaguDPS.Combat() and not IsFriendly(guid) then
        parser:ScanWeaknessOnTarget(guid)
    end

    if state ~= 0 then return end
    local spellName = getSpellName(spellId)
    if spellName == "红月" or spellName == "蓝月" then
        return
    end
    if not shieldData[spellName] then return end

    local schoolFlag = shieldData[spellName] or 0
    if not activeShields[guid] then activeShields[guid] = {} end

    local existing = nil
    for i, s in ipairs(activeShields[guid]) do
        if s.spellId == spellId then
            existing = s
            break
        end
    end

    if existing then
        if existing.casterGuid == nil then
            return
        end
    else
        local maxAbsorb = shieldMaxAbsorb[spellName] or math.huge
        table.insert(activeShields[guid], {
            casterGuid = guid,
            spellId = spellId,
            school = schoolFlag,
            absorbed = 0,
            maxAbsorb = maxAbsorb
        })
    end
end

-- ============================================================================
-- 23. 敌人承伤统计
-- ============================================================================

local function recordEnemyDamageTaken(target, source, amount, overkill)
    if not target or not source or type(amount) ~= "number" then return end

    local effective = amount
    if config.clamp_damage_to_health ~= 1 then
        effective = amount - (overkill or 0)
    end
    if effective < 0 then effective = 0 end
    if effective <= 0 and (overkill or 0) <= 0 then return end
    for segment = 0, 1 do
        local seg = data.enemy_damage_taken[segment]
        if not seg[target] then
            seg[target] = { _sum = 0, _overkill = 0 }
        end
        local tgt = seg[target]
        tgt._sum = (tgt._sum or 0) + effective
        tgt._overkill = (tgt._overkill or 0) + (overkill or 0)
        if not tgt[source] then
            tgt[source] = { _sum = 0, _overkill = 0 }
        end
        local src = tgt[source]
        src._sum = (src._sum or 0) + effective
        src._overkill = (src._overkill or 0) + (overkill or 0)
    end
end

local function queueEnemyDamageTaken(targetGuid, source, amount, overkill)
    if ShaguDPS.hasNampower then
        ShaguDPS.weaknessTrackedTargets = ShaguDPS.weaknessTrackedTargets or {}
        ShaguDPS.weaknessTrackedTargets[targetGuid] = true
        if parser.ScanWeaknessOnTarget then
            parser:ScanWeaknessOnTarget(targetGuid)
        end
    end

    local function recordMaxHealth(target)
        if not target then return end
        local maxHealth = GetUnitField(targetGuid, "maxHealth")
        if maxHealth and maxHealth > 0 then
            data.enemy_max_health = data.enemy_max_health or {}
            local cur = data.enemy_max_health[target]
            if not cur or maxHealth > cur then
                data.enemy_max_health[target] = maxHealth
            end
        end
    end
    local target = SafeUnitName(targetGuid)
    if target and not isUnknownName(target) then
        recordMaxHealth(target)
        recordEnemyDamageTaken(target, source, amount, overkill)
    else
        parser:ScheduleEvent(function()
            local resolved = SafeUnitName(targetGuid)
            if resolved then
                recordMaxHealth(resolved)
                recordEnemyDamageTaken(resolved, source, amount, overkill)
            end
        end, {}, { targetGuid })
    end
end

-- ============================================================================
-- 24. 承受伤害与受到治疗统计
-- ============================================================================

local MAX_DAMAGE_TAKEN_HISTORY = 200

local function updateDamageTaken(victimName, sourceName, spellName, damage, hitType)
    if not victimName or type(damage) ~= "number" then return end
    local now = GetTime()
    for segment = 0, 1 do
        local entry = data.damage_taken[segment]
        if not entry[victimName] then
            entry[victimName] = { _sum = 0, _history = {} }
        end
        local rec = entry[victimName]
        rec._sum = rec._sum + damage

        local existing = nil
        for _, h in ipairs(rec._history) do
            if h.source == sourceName and h.spell == spellName then
                existing = h
                break
            end
        end

        if existing then
            existing.total = existing.total + damage
            existing.last = damage
            existing.time = now
        else
            table.insert(rec._history, {
                source = sourceName,
                spell = spellName,
                total = damage,
                last = damage,
                time = now
            })
            if table.getn(rec._history) > MAX_DAMAGE_TAKEN_HISTORY then
                table.remove(rec._history, 1)
            end
        end

        if not rec._detail_history then
            rec._detail_history = {}
        end
        table.insert(rec._detail_history, {
            source = sourceName,
            spell = spellName,
            damage = damage,
            hitType = hitType,
            time = now
        })
        local maxDetail = 200
        while table.getn(rec._detail_history) > maxDetail do
            table.remove(rec._detail_history, 1)
        end
        while table.getn(rec._detail_history) > 0 and rec._detail_history[1].time < now - 15 do
            table.remove(rec._detail_history, 1)
        end
    end
end

local function updateHealTaken(victimName, sourceName, amount, effectiveAmount)
    if not victimName or not sourceName or type(amount) ~= "number" then return end
    local effective = effectiveAmount or amount
    for segment = 0, 1 do
        local entry = data.heal_taken[segment]
        if not entry[victimName] then
            entry[victimName] = { _sum = 0, _esum = 0 }
        end
        local vRec = entry[victimName]
        vRec._sum = vRec._sum + amount
        vRec._esum = vRec._esum + effective
        if not vRec[sourceName] then
            vRec[sourceName] = { _sum = 0, _esum = 0 }
        end
        vRec[sourceName]._sum = vRec[sourceName]._sum + amount
        vRec[sourceName]._esum = vRec[sourceName]._esum + effective
    end
    parser.lastRefreshEventTime = GetTime()
end

local function recordDamageTaken(targetGuid, sourceName, spellName, damage, hitType)
    if not damage or damage <= 0 then return end

    local victimName = SafeUnitName(targetGuid)
    if not victimName then return end

    if isUnknownName(victimName) then
        parser:ScheduleEvent(recordDamageTaken, {targetGuid, sourceName, spellName, damage}, {targetGuid})
        return
    end

    if not isUnitTracked(targetGuid) then
        local _, _, ownerGUID = GetOwnerInfoFromPetGUID(targetGuid)
        if not ownerGUID or not isUnitTracked(ownerGUID) then
            return
        end
        if config.merge_pets == 1 then
            victimName = SafeUnitName(ownerGUID)
        else
            victimName = SafeUnitName(ownerGUID) .. " - " .. victimName
        end
    end

    updateDamageTaken(victimName, sourceName, spellName, damage, hitType)
end

recordHealTaken = function(targetGuid, sourceName, spellName, amount, effectiveAmount)
    if not amount or amount <= 0 then return end

    local victimName = SafeUnitName(targetGuid)
    if not victimName then return end

    if isUnknownName(victimName) then
        parser:ScheduleEvent(recordHealTaken, {targetGuid, sourceName, spellName, amount, effectiveAmount}, {targetGuid})
        return
    end

    local _, petType, ownerGUID = GetOwnerInfoFromPetGUID(targetGuid)
    local isPet = (petType ~= nil)
    if isPet then
        if not ownerGUID or (not isUnitTracked(ownerGUID) and config.track_all_units ~= 1) then
            return
        end
        local ownerName = SafeUnitName(ownerGUID)
        if ownerName then
            victimName = ownerName .. " - " .. victimName
            parser:ScanName(ownerName)
            if data["classes"][ownerName] then
                data["classes"][victimName] = data["classes"][ownerName]
            end
        end
    else
        if config.track_all_units ~= 1 and not isUnitTracked(targetGuid) then
            return
        end
    end
    local now = GetTime()
    for segment = 0, 1 do
        local entry = data.damage_taken[segment]
        if not entry[victimName] then
            entry[victimName] = { _sum = 0, _history = {} }
        end
        local rec = entry[victimName]
        if not rec._detail_heal_history then
            rec._detail_heal_history = {}
        end
        table.insert(rec._detail_heal_history, {
            source = sourceName,
            spell = spellName,
            amount = amount,
            time = now
        })
        local maxHealHistory = 200
        while table.getn(rec._detail_heal_history) > maxHealHistory do
            table.remove(rec._detail_heal_history, 1)
        end
        while table.getn(rec._detail_heal_history) > 0 and rec._detail_heal_history[1].time < now - 15 do
            table.remove(rec._detail_heal_history, 1)
        end
    end
    updateHealTaken(victimName, sourceName, amount, effectiveAmount)
end

-- ============================================================================
-- 25. 死亡统计与死亡回放（UNIT_DIED 事件处理）
-- ============================================================================

-- 生成一次死亡回放记录：从该单位的承伤/受疗历史中取出死亡前 10 秒 ~ 死亡后 2 秒的事件，
-- 连同死亡时间与所在战斗 BOSS 名一起写入 data.death_replays（当前战）与 data.all_death_replays（跨战斗累计）
function parser:GenerateDeathReplay(entry)
    local name = entry.name
    local deathTime = entry.deathTime
    local fightBossName = entry.bossName or "未知战斗"

    local victimData = data.damage_taken[1] and data.damage_taken[1][name]
    local damageEvents = {}
    local healEvents = {}

    if victimData then
        if victimData._detail_history then
            for _, h in ipairs(victimData._detail_history) do
                if h.time and h.time >= deathTime - 10 and h.time <= deathTime + 2 then
                    table.insert(damageEvents, deepcopy(h))
                end
            end
        end
        if victimData._detail_heal_history then
            for _, h in ipairs(victimData._detail_heal_history) do
                if h.time and h.time >= deathTime - 10 and h.time <= deathTime + 2 then
                    table.insert(healEvents, deepcopy(h))
                end
            end
        end
    end

    if not data.death_replays[name] then
        data.death_replays[name] = {}
    end
    table.insert(data.death_replays[name], {
        deathTime = deathTime,
        damageEvents = damageEvents,
        healEvents = healEvents,
        bossName = fightBossName,
    })

    if not data.all_death_replays[name] then
        data.all_death_replays[name] = {}
    end
    table.insert(data.all_death_replays[name], {
        deathTime = deathTime,
        damageEvents = damageEvents,
        healEvents = healEvents,
        bossName = fightBossName,
    })
end

function parser:ProcessDeathReplayQueue(force)
    local now = GetTime()
    if not self.deathReplayQueue then return end

    for i = table.getn(self.deathReplayQueue), 1, -1 do
        local entry = self.deathReplayQueue[i]
        if force or (now - entry.queuedTime > 0.5) then
            self:GenerateDeathReplay(entry)
            table.remove(self.deathReplayQueue, i)
        end
    end
end

local function shouldTrackDeath(guid) return isUnitTracked(guid) end

local function onUnitDied(guid)
    if ShaguDPS.activeBadDispelDebuffs and ShaguDPS.activeBadDispelDebuffs[guid] then
        parser.badDispelClearTimes[guid] = GetTime() + 1.0
    end

    if ShaguDPS.hostile_targets then
        ShaguDPS.hostile_targets[guid] = nil
    end

    local name = SafeUnitName(guid)
    if name and ShaguDPS.hasNampower and parser.HandleWeaknessTargetDeath then
        parser:HandleWeaknessTargetDeath(guid, name, GetTime())
    end

    if not parser.enabled.death then return end
    healthCache[guid] = nil

    if parser.processPendingEvents then
        parser.processPendingEvents()
    end

    if ShaguDPS.Combat() then
        -- 记录本场死亡的 BOSS（供脱战结算 boss_fights），并缓存血量最高的 BOSS 作为主首领
        if UnitClassification(guid) == "worldboss" then
            local bossName = SafeUnitName(guid)
            if bossName and not isUnknownName(bossName) then
                local found = false
                for _, name in ipairs(diedBossesThisFight) do
                    if name == bossName then found = true break end
                end
                if not found then
                    table.insert(diedBossesThisFight, bossName)
                end

                local maxHealth = GetUnitField(guid, "maxHealth") or 0
                if not ShaguDPS.pendingBossRecord or maxHealth > (ShaguDPS.pendingBossRecord.maxHealth or 0) then
                    ShaguDPS.pendingBossRecord = {
                        name = bossName,
                        timestamp = combat_start_time,
                        maxHealth = maxHealth,
                    }
                end
            end
        end
    end

    if not shouldTrackDeath(guid) then return end
    if not name then return end

    for segment = 0, 1 do
        data.death[segment][name] = (data.death[segment][name] or 0) + 1
    end

    local deathTime = GetTime()
    if not data.death_timestamps[name] then data.death_timestamps[name] = {} end
    table.insert(data.death_timestamps[name], deathTime)

    local fightBossName = "未知战斗"
    local maxHP = 0
    if data.enemy_max_health then
        for mobName, hp in pairs(data.enemy_max_health) do
            if hp > maxHP then
                maxHP = hp
                fightBossName = mobName
            end
        end
    end

    table.insert(parser.deathReplayQueue, {
        name = name,
        guid = guid,
        deathTime = deathTime,
        bossName = fightBossName,
        queuedTime = GetTime(),
    })

    parser.lastRefreshEventTime = GetTime()
end

-- ============================================================================
-- 26. 复活技能列表与更新
-- ============================================================================

local reviveSpellNames = {
    ["复活术"] = true, ["Resurrection"] = true, ["救赎"] = true,
    ["Redemption"] = true, ["先祖之魂"] = true, ["Ancestral Spirit"] = true,
    ["复生"] = true, ["Rebirth"] = true, ["电击"] = true,
    ["Defibrillate"] = true, ["强力嗅盐"] = true, ["Powerful Smelling Salts"] = true,
}

local function updateReviveStats(source, target, ownerName)
    if type(source) ~= "string" or type(target) ~= "string" then return end
    if source == target then return end
    if ShaguDPS.InvalidateBossSummaryCache then ShaguDPS.InvalidateBossSummaryCache() end
    local finalSource
    if ownerName and config.merge_pets == 1 then
        finalSource = ownerName
    elseif ownerName then
        finalSource = ownerName .. " - " .. source
        if not data["classes"][finalSource] then
            data["classes"][finalSource] = data["classes"][ownerName] or "__other__"
        end
    else
        finalSource = source
    end
    if not data["classes"][finalSource] then
        parser:ScanName(finalSource)
    end
    local inCombat = ShaguDPS.Combat() == true

    local entry0 = data.revive[0]
    if not entry0[finalSource] then
        entry0[finalSource] = { ["_total"] = 0 }
    end
    local playerRec = entry0[finalSource]
    playerRec._total = (playerRec._total or 0) + 1
    playerRec[target] = (playerRec[target] or 0) + 1

    if not inCombat then
        data.revive_noncombat = data.revive_noncombat or {}
        local ncEntry = data.revive_noncombat
        if not ncEntry[finalSource] then
            ncEntry[finalSource] = { ["_total"] = 0 }
        end
        local ncRec = ncEntry[finalSource]
        ncRec._total = (ncRec._total or 0) + 1
        ncRec[target] = (ncRec[target] or 0) + 1
    else
        local entry1 = data.revive[1]
        if not entry1[finalSource] then
            entry1[finalSource] = { ["_total"] = 0 }
        end
        local currRec = entry1[finalSource]
        currRec._total = (currRec._total or 0) + 1
        currRec[target] = (currRec[target] or 0) + 1
    end
    parser.lastRefreshEventTime = GetTime()
end

-- ============================================================================
-- 27. 打断统计辅助
-- ============================================================================

local recentInterrupts = {}
local pendingFailures = {}

local function trimRecentInterrupts()
    local now = GetTime()
    for i = table.getn(recentInterrupts), 1, -1 do
        if now - recentInterrupts[i].time > 1.0 then
            table.remove(recentInterrupts, i)
        end
    end
end

local function trimPendingFailures()
    local now = GetTime()
    for i = table.getn(pendingFailures), 1, -1 do
        if now - pendingFailures[i].time > 1.0 then
            table.remove(pendingFailures, i)
        end
    end
end

local function addInterrupt(interrupterName, interruptSpellName, victimName, victimSpellName)
    if not interrupterName or not interruptSpellName or not victimName or not victimSpellName then return end
    if isUnknownName(interrupterName) or isUnknownName(victimName) then return end

    for segment = 0, 1 do
        local entry = data.interrupt[segment]
        if not entry[interrupterName] then
            entry[interrupterName] = { ["_total"] = 0 }
        end
        local p = entry[interrupterName]
        p._total = (p._total or 0) + 1

        if not p[interruptSpellName] then
            p[interruptSpellName] = { ["_total"] = 0 }
        end
        local abil = p[interruptSpellName]
        abil._total = (abil._total or 0) + 1

        if not abil[victimName] then
            abil[victimName] = {}
        end
        local v = abil[victimName]
        v[victimSpellName] = (v[victimSpellName] or 0) + 1
    end

    parser.lastRefreshEventTime = GetTime()
end

local function TryMatchFailure(fail)
    local bestRec = nil
    local bestDiff = nil

    for i = table.getn(recentInterrupts), 1, -1 do
        local rec = recentInterrupts[i]
        if rec.targetGuid == fail.victimCasterGuid then
            local diff = fail.time - rec.time
            if diff >= 0 and (not bestDiff or diff < bestDiff) then
                bestDiff = diff
                bestRec = rec
            end
        end
    end

    if bestRec then
        local victimName = fail.victimName
        if not victimName then
            victimName = SafeUnitName(fail.victimCasterGuid)
        end
        if victimName and not isUnknownName(victimName) then
            addInterrupt(bestRec.sourceName, bestRec.spellName, victimName, fail.victimSpellName)
        end
        return true
    end

    return false
end

local function AddRecentInterrupt(rec)
    table.insert(recentInterrupts, rec)
    trimRecentInterrupts()
    trimPendingFailures()
    for i = table.getn(pendingFailures), 1, -1 do
        if pendingFailures[i].victimCasterGuid == rec.targetGuid then
            if TryMatchFailure(pendingFailures[i]) then
                table.remove(pendingFailures, i)
            end
        end
    end
end

local function onSpellFailedOther(casterGuid, spellId)
    if not parser.enabled.interrupt then return end
    if not casterGuid or not spellId then return end
    if casterGuid == "0x0000000000000000" then return end

    local fail = {
        time = GetTime(),
        victimCasterGuid = casterGuid,
        victimSpellName = getSpellName(spellId),
        victimName = SafeUnitName(casterGuid),
    }

    trimPendingFailures()
    table.insert(pendingFailures, fail)

    if TryMatchFailure(fail) then
        for i = table.getn(pendingFailures), 1, -1 do
            if pendingFailures[i] == fail then
                table.remove(pendingFailures, i)
                break
            end
        end
    end
end

-- ============================================================================
-- 28. Nampower 事件处理与注册（hasNampower 分支）
--     前半部分定义全部事件回调函数；本分支末尾为事件注册与 OnEvent 分发器
-- ============================================================================

if ShaguDPS.hasNampower then
    SetCVar("NP_EnableAutoAttackEvents", "1")
    SetCVar("NP_EnableSpellHealEvents", "1")
    SetCVar("NP_EnableSpellEnergizeEvents", "1")
    SetCVar("NP_EnableSpellGoEvents", "1")
    SetCVar("NP_EnableAuraCastEvents", "1")

    -- 与 enabled 开关无关、必须始终监听的事件（威胁清空、护盾生命周期、
    -- buff/debuff/易伤 扫描、环境伤害、错误驱散标记 等）。
    -- 启用与否的精细控制由 OnEvent 分发器中针对各 handler 的 enabled 守卫负责。
    local function registerAlwaysOnEvents()
        local ev = {
                "DAMAGE_SHIELD_SELF", "DAMAGE_SHIELD_OTHER",
                "AURA_CAST_ON_SELF", "AURA_CAST_ON_OTHER",
                "BUFF_ADDED_SELF", "BUFF_ADDED_OTHER",
                "BUFF_REMOVED_SELF", "BUFF_REMOVED_OTHER",
                "DEBUFF_ADDED_SELF", "DEBUFF_ADDED_OTHER",
                "DEBUFF_REMOVED_SELF", "DEBUFF_REMOVED_OTHER",
                "ENVIRONMENTAL_DMG_SELF", "ENVIRONMENTAL_DMG_OTHER",
                "PLAYER_TARGET_CHANGED", "PLAYER_ENTERING_WORLD",
            }
        for _, name in ipairs(ev) do parser:RegisterEvent(name) end
    end
    registerAlwaysOnEvents()

    -- 误伤统计辅助
    local function recordFriendlyFire(casterGuid, sourceName, targetName, action, damage)
        if not isUnitTracked(casterGuid) then return end
        for segment = 0, 1 do
            local entry = data.friendly_fire[segment]
            if not entry[sourceName] then entry[sourceName] = { ["_total"] = 0 } end
            entry[sourceName]["_total"] = (entry[sourceName]["_total"] or 0) + damage
            if not entry[sourceName][targetName] then entry[sourceName][targetName] = {} end
            entry[sourceName][targetName][action] = (entry[sourceName][targetName][action] or 0) + damage
        end
    end

    -- NAXX 瘟疫区一号：玩家中 debuff 未驱散后对友方造成的 DOT 伤害，全部计为误伤。
    -- 目标可识别则记录目标，识别不到也计入（用占位名）。勾选"剔除误伤"时，该伤害
    -- 在伤害量/DPS 等正常伤害视图中一并剔除（当前/全程/小怪/BOSS/BOSS汇总/近期战斗一致）。
    local bossDebuffFriendlyFire = {
        ["瘟疫使者之怒"] = true,
        ["Wrath of the Plaguebringer"] = true,
    }
    -- 命中该技能：按误伤记录（来源=施法者/中debuff玩家），并返回 true（调用方不再走正常伤害流程）
    local function recordBossDebuffFriendlyFire(casterGuid, targetGuid, action, amount, spellSchool)
        if not bossDebuffFriendlyFire[action] then return false end
        local src = SafeUnitName(casterGuid)
        local tgt = SafeUnitName(targetGuid)
        if not tgt or isUnknownName(tgt) then tgt = "未知目标" end
        if isUnitTracked(casterGuid) and src then
            recordFriendlyFire(casterGuid, src, tgt, action, amount)
        end
        if isUnitTracked(targetGuid) and src then
            recordDamageTaken(targetGuid, src, action, amount)
        end
        -- 剔除误伤未开启时计入正常伤害（写 data.damage[0]/[1]，各分段随之同步）；开启则剔除
        if config.hide_friendly_damage ~= 1 and src then
            updateStats(src, action, tgt, amount, spellSchool, "damage", nil, nil, nil, 0)
        end
        return true
    end

    -- 伤害事件（自身施放）
    local function onSpellDamageSelf(targetGuid, casterGuid, spellId, amount, mitigationStr, hitInfo, spellSchool, effectAuraStr)
        checkBossInvolvement(casterGuid, targetGuid)
        TrackCombatant(casterGuid, targetGuid)
        if not parser.enabled.damage and not parser.enabled.enemy_damage_taken and not parser.enabled.invalid_damage and not parser.enabled.friendly_fire and not parser.enabled.damage_taken then return end
        local targetName = SafeUnitName(targetGuid)
        local action = getSpellName(spellId)
        if recordBossDebuffFriendlyFire(casterGuid, targetGuid, action, amount, spellSchool) then return end
        local isDotTick = false
        if effectAuraStr and effectAuraStr ~= "" then
            local auraType = tonumber((string.match(effectAuraStr, "[^,]+,[^,]+,[^,]+,([^,]+)")))
            if auraType == 3 or auraType == 89 then
                action = action .. " (DoT)"
                isDotTick = true
            end
        end

        if isNameIgnored(targetName) then
            addInvalidDamage(SafeUnitName("player"), action, targetName, amount, spellSchool, 0)
            return
        end

        local absorb = 0
        if mitigationStr and mitigationStr ~= "" then
            absorb = tonumber((string.match(mitigationStr, "[^,]+"))) or 0
        end
        if absorb > 0 then processAbsorb(targetGuid, spellSchool, absorb) end

        local isFriendlyTarget = IsFriendly(targetGuid)
        if isFriendlyTarget then
            local sourceName = SafeUnitName("player")
            local targetNameF = SafeUnitName(targetGuid)
            recordFriendlyFire(GetUnitGUID("player"), sourceName, targetNameF, action, amount)
            if isUnitTracked(targetGuid) then
                recordDamageTaken(targetGuid, sourceName, action, amount, hitInfo == 2 and "crit" or "normal")
            end
        end
        -- 剔除误伤：对友方目标的命中明细不计入，避免详情里出现"施放"计数但无对应伤害
        if config.hide_friendly_damage == 1 and isFriendlyTarget then return end
        if config.exclude_critters == 1 and IsCritter(targetGuid) then return end

        if not isDotTick then
            recordHitBreakdown(SafeUnitName("player"), getSpellName(spellId), hitInfo == 2 and "crit" or "normal")
        end

        local rawDamage = amount
        local overkill = CalculateOverkill(targetGuid, rawDamage)
        local finalDamage = (config.clamp_damage_to_health ~= 1) and rawDamage or (rawDamage - overkill)
        if not isFriendlyTarget then
            recordDamageTaken(targetGuid, SafeUnitName("player"), action, amount, hitInfo == 2 and "crit" or "normal")
            queueEnemyDamageTaken(targetGuid, SafeUnitName("player"), finalDamage, overkill)
        end
        updateStats(SafeUnitName("player"), action, targetName, finalDamage, spellSchool, "damage", nil, nil, nil, overkill)

        if action and string.find(action, "DoT") then
            recordDotTick(SafeUnitName("player"), action, nil)
        end
    end

    -- 伤害事件（其他施放）
    local function onSpellDamageOther(targetGuid, casterGuid, spellId, amount, mitigationStr, hitInfo, spellSchool, effectAuraStr)
        checkBossInvolvement(casterGuid, targetGuid)
        TrackCombatant(casterGuid, targetGuid)
        if not parser.enabled.damage and not parser.enabled.enemy_damage_taken and not parser.enabled.invalid_damage and not parser.enabled.friendly_fire and not parser.enabled.damage_taken then return end
        local targetName = SafeUnitName(targetGuid)
        local action = getSpellName(spellId)
        if recordBossDebuffFriendlyFire(casterGuid, targetGuid, action, amount, spellSchool) then return end
        local isDotTick = false
        if effectAuraStr and effectAuraStr ~= "" then
            local auraType = tonumber((string.match(effectAuraStr, "[^,]+,[^,]+,[^,]+,([^,]+)")))
            if auraType == 3 or auraType == 89 then
                action = action .. " (DoT)"
                isDotTick = true
            end
        end

        if isNameIgnored(targetName) then
            if not isUnitTracked(casterGuid) then
                local _, _, ownerGUID = GetOwnerInfoFromPetGUID(casterGuid)
                if not ownerGUID or not isUnitTracked(ownerGUID) then
                    return
                end
            end
            local casterName = SafeUnitName(casterGuid)
            local ownerName, _ = GetOwnerInfoFromPetGUID(casterGuid)
            if ownerName and config.merge_pets == 1 then
                addInvalidDamage(ownerName, casterName .. " - " .. action, targetName, amount, spellSchool, 0)
            else
                addInvalidDamage(casterName, action, targetName, amount, spellSchool, 0)
            end
            return
        end

        local absorb = 0
        if mitigationStr and mitigationStr ~= "" then
            absorb = tonumber((string.match(mitigationStr, "[^,]+"))) or 0
        end
        if absorb > 0 then processAbsorb(targetGuid, spellSchool, absorb) end

        local isFriendlyTarget = IsFriendly(targetGuid)
        if isFriendlyTarget then
            local casterName = SafeUnitName(casterGuid)
            if casterName then
                local targetNameF = SafeUnitName(targetGuid)
                recordFriendlyFire(casterGuid, casterName, targetNameF, action, amount)
                if isUnitTracked(targetGuid) then
                    recordDamageTaken(targetGuid, casterName, action, amount, hitInfo == 2 and "crit" or "normal")
                end
            end
        end
        if config.hide_friendly_damage == 1 and isFriendlyTarget then return end
        if config.exclude_critters == 1 and IsCritter(targetGuid) then return end

        local rawDamage = amount
        local overkill = CalculateOverkill(targetGuid, rawDamage)
        local finalDamage = (config.clamp_damage_to_health ~= 1) and rawDamage or (rawDamage - overkill)

        if casterGuid == "0x0000000000000000" or targetGuid == "0x0000000000000000" then return end
        local casterName = SafeUnitName(casterGuid)
        local targetNameLocal = SafeUnitName(targetGuid)
        if isUnknownName(casterName) or isUnknownName(targetNameLocal) then
            local args = {targetGuid, casterGuid, spellId, amount, mitigationStr, hitInfo, spellSchool, effectAuraStr}
            parser:ScheduleEvent(onSpellDamageOther, args, {casterGuid, targetGuid})
            return
        end

        local ownerName, _ = GetOwnerInfoFromPetGUID(casterGuid)
        local finalSourceName = casterName

        if ownerName then
            if config.merge_pets == 1 then
                finalSourceName = ownerName
            else
                finalSourceName = ownerName .. " - " .. casterName
            end
        end

        if not isUnitTracked(casterGuid) then
            local _, _, ownerGUID = GetOwnerInfoFromPetGUID(casterGuid)
            if not ownerGUID or not isUnitTracked(ownerGUID) then
                return
            end
        end

        if not isDotTick then
            local hitType = hitInfo == 2 and "crit" or "normal"
            if ownerName then
                if config.merge_pets == 1 then
                    recordHitBreakdown(ownerName, casterName .. " - " .. action, hitType)
                else
                    recordHitBreakdown(ownerName .. " - " .. casterName, action, hitType)
                end
            elseif UnitIsPlayer(casterGuid) then
                recordHitBreakdown(casterName, action, hitType)
            end
        end

        if not isFriendlyTarget then
            recordDamageTaken(targetGuid, casterName, action, amount, hitInfo == 2 and "crit" or "normal")
            queueEnemyDamageTaken(targetGuid, finalSourceName, finalDamage, overkill)
        end

        if ownerName then
            local petName = casterName
            if config.merge_pets == 1 then
                updateStats(petName, action, targetNameLocal, finalDamage, spellSchool, "damage", nil, nil, ownerName, overkill)
                if action and string.find(action, "DoT") then
                    recordDotTick(petName, action, ownerName)
                end
            else
                local displayName = ownerName .. " - " .. petName
                if not data["classes"][displayName] then data["classes"][displayName] = data["classes"][ownerName] or "__other__" end
                updateStats(displayName, action, targetNameLocal, finalDamage, spellSchool, "damage", nil, nil, ownerName, overkill)
                if action and string.find(action, "DoT") then
                    recordDotTick(petName, action, ownerName)
                end
            end
        else
            if UnitIsPlayer(casterGuid) then
                updateStats(casterName, action, targetNameLocal, finalDamage, spellSchool, "damage", nil, nil, nil, overkill)
                if action and string.find(action, "DoT") then
                    recordDotTick(casterName, action, nil)
                end
            end
        end
    end

    -- 自动攻击（自身）
    local function onAutoAttackSelf(attackerGuid, targetGuid, totalDamage, hitInfo, victimState, subDamageCount, blockedAmount, totalAbsorb, totalResist)
        checkBossInvolvement(attackerGuid, targetGuid)
        TrackCombatant(attackerGuid, targetGuid)
        if not parser.enabled.damage and not parser.enabled.enemy_damage_taken and not parser.enabled.invalid_damage and not parser.enabled.friendly_fire and not parser.enabled.damage_taken then return end
        local targetName = SafeUnitName(targetGuid)
        local attackerName = SafeUnitName("player")
        local extraList = parser.extraAttacks[attackerGuid]
        local extra = nil
        if extraList and table.getn(extraList) > 0 then
            extra = extraList[1]
        end
        local action = "自动攻击"
        if extra then
            action = extra.ability
            if config.separate_mh_oh_damage == 1 and bit.band(hitInfo, 4) ~= 0 then
                action = action .. "(副手)"
            end
            extra.count = extra.count - 1
            if extra.count <= 0 then
                table.remove(extraList, 1)
                if table.getn(extraList) == 0 then
                    parser.extraAttacks[attackerGuid] = nil
                end
            end
        elseif config.separate_mh_oh_damage == 1 and bit.band(hitInfo, 4) ~= 0 then
            action = "自动攻击(副手)"
        end

        if isNameIgnored(targetName) then
            addInvalidDamage(SafeUnitName("player"), action, targetName, totalDamage, 0, 0)
            return
        end

        if totalAbsorb and totalAbsorb > 0 then
            processAbsorb(targetGuid, 0, totalAbsorb)
        end
        local isFriendlyTarget = IsFriendly(targetGuid)
        if isFriendlyTarget then
            local sourceName = SafeUnitName("player")
            local targetNameF = SafeUnitName(targetGuid)
            recordFriendlyFire(GetUnitGUID("player"), sourceName, targetNameF, action, totalDamage)
            if isUnitTracked(targetGuid) then
                recordDamageTaken(targetGuid, sourceName, action, totalDamage, GetSwingHitType(hitInfo, victimState, totalDamage))
            end
        end
        if config.hide_friendly_damage == 1 and isFriendlyTarget then return end
        if config.exclude_critters == 1 and IsCritter(targetGuid) then return end

        local swingHtype = nil
        if bit.band(hitInfo, 32768) ~= 0 then
            swingHtype = "crushing"
        elseif victimState == 2 then
            swingHtype = "dodge"
        elseif victimState == 3 then
            swingHtype = "parry"
        elseif victimState == 5 then
            swingHtype = "block"
        elseif victimState == 6 or victimState == 7 or victimState == 8 then
            swingHtype = "miss"
        elseif bit.band(hitInfo, 16) ~= 0 then
            swingHtype = "miss"
        elseif bit.band(hitInfo, 64) ~= 0 and totalDamage == 0 then
            swingHtype = "resist"
        elseif bit.band(hitInfo, 128) ~= 0 then
            swingHtype = "crit"
        elseif bit.band(hitInfo, 16384) ~= 0 then
            swingHtype = "glancing"
        end
        recordHitBreakdown(SafeUnitName("player"), action, swingHtype)

        for segment = 0, 1 do
            local entry = data.spellcast[segment]
            if not entry[attackerName] then entry[attackerName] = { ["_total"] = 0 } end
            entry[attackerName]["_total"] = (entry[attackerName]["_total"] or 0) + 1
            entry[attackerName][action] = (entry[attackerName][action] or 0) + 1
        end

        if victimState ~= 1 then return end

        local rawDamage = totalDamage
        local overkill = 0
        local health = GetUnitField(targetGuid, "health")
        if health == 0 then
            if healthCache[targetGuid] then
                overkill = rawDamage - healthCache[targetGuid]
                healthCache[targetGuid] = nil
            else
                local healthmax = GetUnitField(targetGuid, "maxHealth")
                if healthmax < rawDamage then
                    overkill = rawDamage - healthmax
                else
                    overkill = rawDamage
                end
                healthCache[targetGuid] = nil
            end
        end
        local finalDamage = (config.clamp_damage_to_health ~= 1) and rawDamage or (rawDamage - overkill)

        if not isFriendlyTarget then
            recordDamageTaken(targetGuid, SafeUnitName("player"), action, totalDamage, GetSwingHitType(hitInfo, victimState, totalDamage))
            queueEnemyDamageTaken(targetGuid, SafeUnitName("player"), finalDamage, overkill)
        end

        updateStats(SafeUnitName("player"), action, SafeUnitName(targetGuid), finalDamage, 0, "damage", nil, nil, nil, overkill)
    end

    -- 自动攻击（其他）
    local function onAutoAttackOther(attackerGuid, targetGuid, totalDamage, hitInfo, victimState, subDamageCount, blockedAmount, totalAbsorb, totalResist)
        checkBossInvolvement(attackerGuid, targetGuid)
        TrackCombatant(attackerGuid, targetGuid)
        if not parser.enabled.damage and not parser.enabled.enemy_damage_taken and not parser.enabled.invalid_damage and not parser.enabled.friendly_fire and not parser.enabled.damage_taken then return end
        local targetName = SafeUnitName(targetGuid)
        local attackerName = SafeUnitName(attackerGuid)

        local extraList = parser.extraAttacks[attackerGuid]
        local extra = nil
        if extraList and table.getn(extraList) > 0 then
            extra = extraList[1]
        end
        local action = "自动攻击"
        if extra then
            action = extra.ability
            if config.separate_mh_oh_damage == 1 and bit.band(hitInfo, 4) ~= 0 then
                action = action .. "(副手)"
            end
            extra.count = extra.count - 1
            if extra.count <= 0 then
                table.remove(extraList, 1)
                if table.getn(extraList) == 0 then
                    parser.extraAttacks[attackerGuid] = nil
                end
            end
        elseif config.separate_mh_oh_damage == 1 and bit.band(hitInfo, 4) ~= 0 then
            action = "自动攻击(副手)"
        end

        if isNameIgnored(targetName) then
            if not isUnitTracked(attackerGuid) then
                local _, _, ownerGUID = GetOwnerInfoFromPetGUID(attackerGuid)
                if not ownerGUID or not isUnitTracked(ownerGUID) then
                    return
                end
            end
            local ownerName, _ = GetOwnerInfoFromPetGUID(attackerGuid)
            if ownerName and config.merge_pets == 1 then
                addInvalidDamage(ownerName, attackerName .. " - " .. action, targetName, totalDamage, 0, 0)
            else
                addInvalidDamage(attackerName, action, targetName, totalDamage, 0, 0)
            end
            return
        end

        if totalAbsorb and totalAbsorb > 0 then
            processAbsorb(targetGuid, 0, totalAbsorb)
        end
        local isFriendlyTarget = IsFriendly(targetGuid)
        if isFriendlyTarget then
            if attackerName then
                local targetNameF = SafeUnitName(targetGuid)
                recordFriendlyFire(attackerGuid, attackerName, targetNameF, action, totalDamage)
                if isUnitTracked(targetGuid) then
                    recordDamageTaken(targetGuid, attackerName, action, totalDamage, GetSwingHitType(hitInfo, victimState, totalDamage))
                end
            end
        end
        if config.hide_friendly_damage == 1 and isFriendlyTarget then return end
        if config.exclude_critters == 1 and IsCritter(targetGuid) then return end

        if attackerGuid == "0x0000000000000000" or targetGuid == "0x0000000000000000" then return end
        local targetNameLocal = SafeUnitName(targetGuid)
        if isUnknownName(attackerName) or isUnknownName(targetNameLocal) then
            local args = {attackerGuid, targetGuid, totalDamage, hitInfo, victimState, subDamageCount, blockedAmount, totalAbsorb, totalResist}
            parser:ScheduleEvent(onAutoAttackOther, args, {attackerGuid, targetGuid})
            return
        end

        if not isUnitTracked(attackerGuid) then
            local _, _, ownerGUID = GetOwnerInfoFromPetGUID(attackerGuid)
            if not ownerGUID or not isUnitTracked(ownerGUID) then
                return
            end
        end

        local swingOwnerName, _ = GetOwnerInfoFromPetGUID(attackerGuid)
        local swingFinalName = attackerName
        local swingFinalAction = action
        if swingOwnerName then
            if config.merge_pets == 1 then
                swingFinalName = swingOwnerName
                swingFinalAction = attackerName .. " - " .. action
            else
                swingFinalName = swingOwnerName .. " - " .. attackerName
                if not data["classes"][swingFinalName] then
                    data["classes"][swingFinalName] = data["classes"][swingOwnerName] or "__other__"
                end
            end
        end

        local swingHtype = nil
        if bit.band(hitInfo, 32768) ~= 0 then
            swingHtype = "crushing"
        elseif victimState == 2 then
            swingHtype = "dodge"
        elseif victimState == 3 then
            swingHtype = "parry"
        elseif victimState == 5 then
            swingHtype = "block"
        elseif victimState == 6 or victimState == 7 or victimState == 8 then
            swingHtype = "miss"
        elseif bit.band(hitInfo, 16) ~= 0 then
            swingHtype = "miss"
        elseif bit.band(hitInfo, 64) ~= 0 and totalDamage == 0 then
            swingHtype = "resist"
        elseif bit.band(hitInfo, 128) ~= 0 then
            swingHtype = "crit"
        elseif bit.band(hitInfo, 16384) ~= 0 then
            swingHtype = "glancing"
        end
        recordHitBreakdown(swingFinalName, swingFinalAction, swingHtype)

        for segment = 0, 1 do
            local entry = data.spellcast[segment]
            if not entry[swingFinalName] then entry[swingFinalName] = { ["_total"] = 0 } end
            entry[swingFinalName]["_total"] = (entry[swingFinalName]["_total"] or 0) + 1
            entry[swingFinalName][swingFinalAction] = (entry[swingFinalName][swingFinalAction] or 0) + 1
        end

        if victimState ~= 1 then return end

        local rawDamage = totalDamage
        local overkill = 0
        local health = GetUnitField(targetGuid, "health")
        if health == 0 then
            if healthCache[targetGuid] then
                overkill = rawDamage - healthCache[targetGuid]
                healthCache[targetGuid] = nil
            else
                local healthmax = GetUnitField(targetGuid, "maxHealth")
                if healthmax < rawDamage then
                    overkill = rawDamage - healthmax
                else
                    overkill = rawDamage
                end
                healthCache[targetGuid] = nil
            end
        end
        local finalDamage = (config.clamp_damage_to_health ~= 1) and rawDamage or (rawDamage - overkill)

        local ownerName, _ = GetOwnerInfoFromPetGUID(attackerGuid)
        local finalSourceName = attackerName

        if ownerName then
            if config.merge_pets == 1 then
                finalSourceName = ownerName
            else
                finalSourceName = ownerName .. " - " .. attackerName
            end
        end

        if not isFriendlyTarget then
            recordDamageTaken(targetGuid, attackerName, action, totalDamage, GetSwingHitType(hitInfo, victimState, totalDamage))
            queueEnemyDamageTaken(targetGuid, finalSourceName, finalDamage, overkill)
        end

        if ownerName then
            local petName = attackerName
            if config.merge_pets == 1 then
                updateStats(petName, action, targetNameLocal, finalDamage, 0, "damage", nil, nil, ownerName, overkill)
            else
                local displayName = ownerName .. " - " .. petName
                if not data["classes"][displayName] then data["classes"][displayName] = data["classes"][ownerName] or "__other__" end
                updateStats(displayName, action, targetNameLocal, finalDamage, 0, "damage", nil, nil, ownerName, overkill)
            end
        else
            if UnitIsPlayer(attackerGuid) then
                updateStats(attackerName, action, targetNameLocal, finalDamage, 0, "damage", nil, nil, nil, overkill)
            end
        end
    end

    -- 治疗事件（自身施放）
    local function onSpellHealBySelf(targetGuid, casterGuid, spellId, amount, critical, periodic)
        if not parser.enabled.heal and not parser.enabled.heal_taken and not parser.enabled.spellcast then return end
        if not UnitCanAssist(targetGuid, casterGuid) then return end
        local sourceName = SafeUnitName("player")
        local targetName = SafeUnitName(targetGuid)
        local action = getSpellName(spellId)
        if periodic == 1 then action = action .. " (HoT)" end

        local health = GetUnitField(targetGuid, "health")
        local maxHealth = GetUnitField(targetGuid, "maxHealth")
        local effectiveHeal = amount
        if health and maxHealth then
            local missing = maxHealth - health
            if missing < 0 then missing = 0 end
            effectiveHeal = math.min(amount, missing)
        end
        recordHealTaken(targetGuid, sourceName, action, amount, effectiveHeal)
        updateStats(sourceName, action, targetName, amount, 0, "heal", effectiveHeal)

        if periodic == 1 then
            recordDotTick(sourceName, action, nil)
        else
            recordHitBreakdown(sourceName, action, critical == 1 and "crit" or "normal")
            local finalName = sourceName
            local finalSpellName = action
            for segment = 0, 1 do
                local entry = data.spellcast[segment]
                if not entry[finalName] then entry[finalName] = { ["_total"] = 0 } end
                entry[finalName]["_total"] = (entry[finalName]["_total"] or 0) + 1
                entry[finalName][finalSpellName] = (entry[finalName][finalSpellName] or 0) + 1
            end
        end
    end

    -- 治疗事件（其他施放）
    local function onSpellHealByOther(targetGuid, casterGuid, spellId, amount, critical, periodic)
        if not parser.enabled.heal and not parser.enabled.heal_taken and not parser.enabled.spellcast then return end
        if not UnitCanAssist(targetGuid, casterGuid) then return end
        if not isUnitTracked(casterGuid) then
            local _, _, ownerGUID = GetOwnerInfoFromPetGUID(casterGuid)
            if not ownerGUID or not isUnitTracked(ownerGUID) then return end
        end

        if casterGuid == "0x0000000000000000" or targetGuid == "0x0000000000000000" then return end
        local casterName = SafeUnitName(casterGuid)
        local targetName = SafeUnitName(targetGuid)

        if isUnknownName(casterName) or isUnknownName(targetName) then
            local args = {targetGuid, casterGuid, spellId, amount, critical, periodic}
            parser:ScheduleEvent(onSpellHealByOther, args, {casterGuid, targetGuid})
            return
        end

        local action = getSpellName(spellId)
        if periodic == 1 then action = action .. " (HoT)" end

        local health = GetUnitField(targetGuid, "health")
        local maxHealth = GetUnitField(targetGuid, "maxHealth")
        local effectiveHeal = amount
        if health and maxHealth then
            local missing = maxHealth - health
            if missing < 0 then missing = 0 end
            effectiveHeal = math.min(amount, missing)
        end

        local ownerName, _ = GetOwnerInfoFromPetGUID(casterGuid)
        local finalCasterName = casterName
        if ownerName then
            if config.merge_pets == 1 then
                finalCasterName = ownerName
            else
                finalCasterName = ownerName .. " - " .. casterName
            end
        end
        recordHealTaken(targetGuid, finalCasterName, action, amount, effectiveHeal)

        if ownerName then
            local petName = casterName
            if config.merge_pets == 1 then
                updateStats(petName, action, targetName, amount, 0, "heal", effectiveHeal, nil, ownerName)
            else
                local displayName = ownerName .. " - " .. petName
                if not data["classes"][displayName] then
                    data["classes"][displayName] = data["classes"][ownerName] or "__other__"
                end
                updateStats(displayName, action, targetName, amount, 0, "heal", effectiveHeal, nil, ownerName)
            end

            if periodic == 1 then
                recordDotTick(petName, action, ownerName)
            else
                local hitFinalName, hitFinalSpell
                if config.merge_pets == 1 then
                    hitFinalName = ownerName
                    hitFinalSpell = petName .. " - " .. action
                else
                    hitFinalName = ownerName .. " - " .. petName
                    hitFinalSpell = action
                end
                recordHitBreakdown(hitFinalName, hitFinalSpell, critical == 1 and "crit" or "normal")
                local finalName, finalSpellName
                if config.merge_pets == 1 then
                    finalName = ownerName
                    finalSpellName = petName .. " - " .. action
                else
                    finalName = ownerName .. " - " .. petName
                    finalSpellName = action
                    if not data["classes"][finalName] then
                        data["classes"][finalName] = data["classes"][ownerName] or "__other__"
                    end
                end
                for segment = 0, 1 do
                    local entry = data.spellcast[segment]
                    if not entry[finalName] then entry[finalName] = { ["_total"] = 0 } end
                    entry[finalName]["_total"] = (entry[finalName]["_total"] or 0) + 1
                    entry[finalName][finalSpellName] = (entry[finalName][finalSpellName] or 0) + 1
                end
            end
            return
        end

        if UnitIsPlayer(casterGuid) then
            updateStats(casterName, action, targetName, amount, 0, "heal", effectiveHeal)
            if periodic == 1 then
                recordDotTick(casterName, action, nil)
            else
                recordHitBreakdown(casterName, action, critical == 1 and "crit" or "normal")
                local finalName = casterName
                local finalSpellName = action
                for segment = 0, 1 do
                    local entry = data.spellcast[segment]
                    if not entry[finalName] then entry[finalName] = { ["_total"] = 0 } end
                    entry[finalName]["_total"] = (entry[finalName]["_total"] or 0) + 1
                    entry[finalName][finalSpellName] = (entry[finalName][finalSpellName] or 0) + 1
                end
            end
        end
    end

    -- 盾反伤害（自身）
    local function onDamageShieldSelf(unitGuid, targetGuid, damage, spellSchool)
        checkBossInvolvement(unitGuid, targetGuid)
        TrackCombatant(unitGuid, targetGuid)
        local targetName = SafeUnitName(targetGuid)
        if isNameIgnored(targetName) then
            addInvalidDamage(SafeUnitName("player"), "反射", targetName, damage, spellSchool, 0)
            return
        end

        local isFriendlyTarget = IsFriendly(targetGuid)
        if isFriendlyTarget then
            local sourceName = SafeUnitName("player")
            local targetNameF = SafeUnitName(targetGuid)
            recordFriendlyFire(GetUnitGUID("player"), sourceName, targetNameF, "反射", damage)
            if isUnitTracked(targetGuid) then
                recordDamageTaken(targetGuid, sourceName, "反射", damage)
            end
        end
        if config.hide_friendly_damage == 1 and isFriendlyTarget then return end
        if config.exclude_critters == 1 and IsCritter(targetGuid) then return end

        local rawDamage = damage
        local overkill = CalculateOverkill(targetGuid, rawDamage)
        local finalDamage = (config.clamp_damage_to_health ~= 1) and rawDamage or (rawDamage - overkill)

        if not isFriendlyTarget then
            recordDamageTaken(targetGuid, SafeUnitName("player"), "反射", damage)
            queueEnemyDamageTaken(targetGuid, SafeUnitName("player"), finalDamage, overkill)
        end

        updateStats(SafeUnitName("player"), "反射", targetName, finalDamage, spellSchool, "damage", nil, nil, nil, overkill)
    end

    -- 盾反伤害（其他）
    local function onDamageShieldOther(unitGuid, targetGuid, damage, spellSchool)
        checkBossInvolvement(unitGuid, targetGuid)
        TrackCombatant(unitGuid, targetGuid)
        local targetName = SafeUnitName(targetGuid)
        if isNameIgnored(targetName) then
            if not isUnitTracked(unitGuid) then
                local _, _, ownerGUID = GetOwnerInfoFromPetGUID(unitGuid)
                if not ownerGUID or not isUnitTracked(ownerGUID) then
                    return
                end
            end
            local unitName = SafeUnitName(unitGuid)
            local ownerName, _ = GetOwnerInfoFromPetGUID(unitGuid)
            if ownerName and config.merge_pets == 1 then
                addInvalidDamage(ownerName, unitName .. " - 反射", targetName, damage, spellSchool, 0)
            else
                addInvalidDamage(unitName, "反射", targetName, damage, spellSchool, 0)
            end
            return
        end

        local isFriendlyTarget = IsFriendly(targetGuid)
        if isFriendlyTarget then
            local unitName = SafeUnitName(unitGuid)
            if unitName then
                local targetNameF = SafeUnitName(targetGuid)
                recordFriendlyFire(unitGuid, unitName, targetNameF, "反射", damage)
                if isUnitTracked(targetGuid) then
                    recordDamageTaken(targetGuid, unitName, "反射", damage)
                end
            end
        end
        if config.hide_friendly_damage == 1 and isFriendlyTarget then return end
        if config.exclude_critters == 1 and IsCritter(targetGuid) then return end

        local rawDamage = damage
        local overkill = CalculateOverkill(targetGuid, rawDamage)
        local finalDamage = (config.clamp_damage_to_health ~= 1) and rawDamage or (rawDamage - overkill)

        if unitGuid == "0x0000000000000000" or targetGuid == "0x0000000000000000" then return end
        local unitName = SafeUnitName(unitGuid)
        local targetNameLocal = SafeUnitName(targetGuid)

        if isUnknownName(unitName) or isUnknownName(targetNameLocal) then
            local args = {unitGuid, targetGuid, damage, spellSchool}
            parser:ScheduleEvent(onDamageShieldOther, args, {unitGuid, targetGuid})
            return
        end

        local ownerName, _ = GetOwnerInfoFromPetGUID(unitGuid)
        local finalSourceName = unitName

        if ownerName then
            if config.merge_pets == 1 then
                finalSourceName = ownerName
            else
                finalSourceName = ownerName .. " - " .. unitName
            end
        end

        if not isUnitTracked(unitGuid) then
            local _, _, ownerGUID = GetOwnerInfoFromPetGUID(unitGuid)
            if not ownerGUID or not isUnitTracked(ownerGUID) then
                return
            end
        end

        if not isFriendlyTarget then
            recordDamageTaken(targetGuid, unitName, "反射", damage)
            queueEnemyDamageTaken(targetGuid, finalSourceName, finalDamage, overkill)
        end

        if ownerName then
            local petName = unitName
            if config.merge_pets == 1 then
                updateStats(petName, "反射", targetNameLocal, finalDamage, spellSchool, "damage", nil, nil, ownerName, overkill)
            else
                local displayName = ownerName .. " - " .. petName
                if not data["classes"][displayName] then
                    data["classes"][displayName] = data["classes"][ownerName] or "__other__"
                end
                updateStats(displayName, "反射", targetNameLocal, finalDamage, spellSchool, "damage", nil, nil, ownerName, overkill)
            end
        else
            if UnitIsPlayer(unitGuid) then
                updateStats(unitName, "反射", targetNameLocal, finalDamage, spellSchool, "damage", nil, nil, nil, overkill)
            end
        end
    end

    -- 法术未命中/抵抗
    local function onSpellMiss(casterGuid, targetGuid, spellId, missInfo)
        if not parser.enabled.damage then return end
        if not casterGuid or not spellId or spellId == 0 then return end
        if casterGuid == "0x0000000000000000" then return end
        if not isUnitTracked(casterGuid) then
            local _, _, ownerGUID = GetOwnerInfoFromPetGUID(casterGuid)
            if not ownerGUID or not isUnitTracked(ownerGUID) then
                return
            end
        end
        local name = SafeUnitName(casterGuid)
        if isUnknownName(name) then
            parser:ScheduleEvent(onSpellMiss, {casterGuid, targetGuid, spellId, missInfo}, {casterGuid})
            return
        end
        local htype
        if missInfo == 1 then htype = "miss"
        elseif missInfo == 2 then htype = "resist"
        elseif missInfo == 3 then htype = "dodge"
        elseif missInfo == 4 then htype = "parry"
        elseif missInfo == 5 then htype = "block"
        else htype = "miss" end
        local ownerName, _ = GetOwnerInfoFromPetGUID(casterGuid)
        local finalName, finalAction
        if ownerName then
            if config.merge_pets == 1 then
                finalName = ownerName
                finalAction = name .. " - " .. getSpellName(spellId)
            else
                finalName = ownerName .. " - " .. name
                finalAction = getSpellName(spellId)
                if not data["classes"][finalName] then
                    data["classes"][finalName] = data["classes"][ownerName] or "__other__"
                end
            end
        else
            finalName = name
            finalAction = getSpellName(spellId)
        end
        -- 剔除误伤：对友方目标的未命中/抵抗不计入命中明细
        if not (config.hide_friendly_damage == 1 and targetGuid and targetGuid ~= "0x0000000000000000" and IsFriendly(targetGuid)) then
            recordHitBreakdown(finalName, finalAction, htype)
        end
    end

    -- 环境伤害
    local function onEnvironmentalDmgSelf(victimGuid, dmgType, damage, absorb, resist)
        if (dmgType == 3 or dmgType == 4 or dmgType == 5) and absorb > 0 then
            processAbsorb(victimGuid, envDmgSchool[dmgType] or 0, absorb)
        end
        local sourceName = "环境(" .. (ENV_DMG_NAMES[dmgType] or "未知") .. ")"
        recordDamageTaken(victimGuid, sourceName, sourceName, damage)
    end

    local function onEnvironmentalDmgOther(victimGuid, dmgType, damage, absorb, resist)
        if (dmgType == 3 or dmgType == 4 or dmgType == 5) and absorb > 0 and activeShields[victimGuid] then
            processAbsorb(victimGuid, envDmgSchool[dmgType] or 0, absorb)
        end
        local sourceName = "环境(" .. (ENV_DMG_NAMES[dmgType] or "未知") .. ")"
        recordDamageTaken(victimGuid, sourceName, sourceName, damage)
    end

    -- 驱散事件
    local function onDispel(casterGuid, targetGuid, spellId)
        if not parser.enabled.dispel then return end
        if not casterGuid or not targetGuid or not spellId then return end

        if not isUnitTracked(casterGuid) then
            local _, _, ownerGUID = GetOwnerInfoFromPetGUID(casterGuid)
            if not ownerGUID or not isUnitTracked(ownerGUID) then
                return
            end
        end

        local casterName = SafeUnitName(casterGuid)
        local targetName = SafeUnitName(targetGuid)

        if isUnknownName(casterName) or isUnknownName(targetName) then
            local args = {casterGuid, targetGuid, spellId}
            parser:ScheduleEvent(onDispel, args, {casterGuid, targetGuid})
            return
        end

        local ownerName, _ = GetOwnerInfoFromPetGUID(casterGuid)
        local finalName = casterName
        if ownerName then
            if config.merge_pets == 1 then
                finalName = ownerName
            else
                finalName = ownerName .. " - " .. casterName
                if not data["classes"][finalName] then
                    data["classes"][finalName] = data["classes"][ownerName] or "__other__"
                end
            end
        end

        local dispelledSpellName = getSpellName(spellId)
        local isFriendly = IsFriendly(targetGuid)
        local dispelType = isFriendly and "defensive" or "offensive"

        for segment = 0, 1 do
            local entry = data.dispel[segment]
            if not entry[finalName] then
                entry[finalName] = { _total = 0, _offensive = 0, _defensive = 0 }
            end
            local playerEntry = entry[finalName]
            playerEntry._total = playerEntry._total + 1
            if dispelType == "offensive" then
                playerEntry._offensive = playerEntry._offensive + 1
            else
                playerEntry._defensive = playerEntry._defensive + 1
            end
            if not playerEntry[targetName] then playerEntry[targetName] = {} end
            local targetTable = playerEntry[targetName]
            targetTable[dispelledSpellName] = (targetTable[dispelledSpellName] or 0) + 1
        end
    end

    -- 能量回复事件
    local function onSpellEnergizeBySelf(targetGuid, casterGuid, spellId, powerType, amount, periodic)
        if not parser.enabled.energize then return end
        if not isUnitTracked(casterGuid) then
            local _, _, ownerGUID = GetOwnerInfoFromPetGUID(casterGuid)
            if not ownerGUID or not isUnitTracked(ownerGUID) then return end
        end

        local casterName = SafeUnitName("player")
        local action = getSpellName(spellId)
        local ownerName, _ = GetOwnerInfoFromPetGUID(casterGuid)

        if ownerName then
            updateEnergizeStats(SafeUnitName(casterGuid), action, SafeUnitName(targetGuid), amount, powerType, ownerName)
        else
            updateEnergizeStats(casterName, action, SafeUnitName(targetGuid), amount, powerType)
        end
    end

    local function onSpellEnergizeByOther(targetGuid, casterGuid, spellId, powerType, amount, periodic)
        if not parser.enabled.energize then return end
        if not isUnitTracked(casterGuid) then
            local _, _, ownerGUID = GetOwnerInfoFromPetGUID(casterGuid)
            if not ownerGUID or not isUnitTracked(ownerGUID) then return end
        end

        if casterGuid == "0x0000000000000000" then return end
        local casterName = SafeUnitName(casterGuid)
        local targetName = SafeUnitName(targetGuid)

        if isUnknownName(casterName) or isUnknownName(targetName) then
            parser:ScheduleEvent(onSpellEnergizeByOther, {targetGuid, casterGuid, spellId, powerType, amount, periodic}, {casterGuid, targetGuid})
            return
        end

        local ownerName, _ = GetOwnerInfoFromPetGUID(casterGuid)
        local action = getSpellName(spellId)

        if ownerName then
            updateEnergizeStats(SafeUnitName(casterGuid), action, targetName, amount, powerType, ownerName)
        else
            if UnitIsPlayer(casterGuid) then
                updateEnergizeStats(casterName, action, targetName, amount, powerType)
            end
        end
    end

    -- 施放事件（SPELL_GO）
    local function onSpellGo(itemId, spellId, casterGuid, targetGuid, castFlags, numTargetsHit, numTargetsMissed, corpseOwnerGuid)
        -- 额外攻击检测：必须在最开头识别（可能由装备/天赋触发，casterGuid 不在 tracked 列表，
        -- 且可能为空；按 targetGuid 判定谁获得了额外攻击）。
        -- 使用队列存储：同一目标可能同时触发多个额外攻击（如风怒+对戒），避免覆盖丢失。
        -- 队列在脱战（NO_COMBAT 结算）、进战、resetCurrentSegment 时统一清空，跨战斗不会残留；
        -- 同一场战斗内若触发后平砍被中断（目标死亡/眩晕/施法打断），队列条目会等到
        -- 下一次对该目标的平砍才被消费（乌龟服无超时机制，属已知可接受行为）。
        if spellId and spellId ~= 0 and targetGuid and targetGuid ~= "0x0000000000000000" then
            local eaSpell = getSpellName(spellId)
            local eaCount = extraAttackAbilities[eaSpell]
            if eaCount then
                if not parser.extraAttacks[targetGuid] then
                    parser.extraAttacks[targetGuid] = {}
                end
                table.insert(parser.extraAttacks[targetGuid], { count = eaCount, ability = eaSpell })
            end
        end
        if not isUnitTracked(casterGuid) then
            local _, _, ownerGUID = GetOwnerInfoFromPetGUID(casterGuid)
            if not ownerGUID or not isUnitTracked(ownerGUID) then
                return
            end
        end
        TrackCombatant(casterGuid, targetGuid)
        if not parser.enabled.spellcast and not parser.enabled.sunder and not parser.enabled.revive and not parser.enabled.interrupt then return end
        local name = SafeUnitName(casterGuid)
        if isUnknownName(name) then
            local args = {itemId, spellId, casterGuid, targetGuid, castFlags, numTargetsHit, numTargetsMissed, corpseOwnerGuid}
            parser:ScheduleEvent(onSpellGo, args, {casterGuid})
            return
        end
        local spellName = getSpellName(spellId)
        local ownerName, _ = GetOwnerInfoFromPetGUID(casterGuid)

        local finalName, finalSpellName
        if ownerName then
            if config.merge_pets == 1 then
                finalName = ownerName
                finalSpellName = name .. " - " .. spellName
            else
                finalName = ownerName .. " - " .. name
                finalSpellName = spellName
                if not data["classes"][finalName] then
                    data["classes"][finalName] = data["classes"][ownerName] or "__other__"
                end
            end
        else
            finalName = name
            finalSpellName = spellName
        end

        if interruptSpellNames[spellName] and targetGuid and targetGuid ~= "0x0000000000000000" and finalName then
            if ownerName or UnitIsPlayer(casterGuid) then
                AddRecentInterrupt({
                    time = GetTime(),
                    targetGuid = targetGuid,
                    spellName = finalSpellName,
                    sourceName = finalName,
                })
            end
        end

        for segment = 0, 1 do
            local entry = data.spellcast[segment]
            if not entry[finalName] then entry[finalName] = { ["_total"] = 0 } end
            entry[finalName]["_total"] = (entry[finalName]["_total"] or 0) + 1
            entry[finalName][finalSpellName] = (entry[finalName][finalSpellName] or 0) + 1
        end

        local sourceType
        local sourceDisplayName
        local itemName = nil
        if itemId and itemId ~= 0 then
            if ShaguDPS.hasNampower then
                itemName = GetItemStatsField(itemId, "displayName")
            end
            if not itemName then
                local info = GetItemInfo(itemId)
                if info then itemName = info end
            end
            if itemName then
                sourceType = "item"
                sourceDisplayName = itemName
            end
        end
        if not sourceType then
            if ownerName then
                sourceType = "pet"
                sourceDisplayName = name
            else
                sourceType = "player"
                sourceDisplayName = nil
            end
        end

        local targetType = "none"
        if targetGuid and targetGuid ~= "0x0000000000000000" then
            if targetGuid == casterGuid then
                targetType = "self"
            elseif IsFriendly(targetGuid) then
                targetType = "friendly"
            else
                targetType = "enemy"
            end
        end

        local displaySpellName
        if sourceType == "player" then
            displaySpellName = spellName
        else
            displaySpellName = sourceDisplayName .. " - " .. spellName
        end

        for segment = 0, 1 do
            if not data.spellcast_details[segment][finalName] then
                data.spellcast_details[segment][finalName] = {}
            end
            local details = data.spellcast_details[segment][finalName]
            details["_total"] = (details["_total"] or 0) + 1

            if not details[sourceType] then
                details[sourceType] = {}
            end
            if not details[sourceType][targetType] then
                details[sourceType][targetType] = {}
            end
            local targetCounts = details[sourceType][targetType]
            targetCounts[displaySpellName] = (targetCounts[displaySpellName] or 0) + 1
        end

        if sunderSpellIds[spellId] then
            local sunderCaster = finalName
            local targetNameSunder = SafeUnitName(targetGuid)
            if targetNameSunder and not isUnknownName(targetNameSunder) then
                for segment = 0, 1 do
                    local entry = data.sunder[segment]
                    if not entry[sunderCaster] then entry[sunderCaster] = { ["_total"] = 0 } end
                    entry[sunderCaster]["_total"] = (entry[sunderCaster]["_total"] or 0) + 1
                    entry[sunderCaster][targetNameSunder] = (entry[sunderCaster][targetNameSunder] or 0) + 1
                end
            end
        end

        if reviveSpellNames[spellName] then
            local targetName = SafeUnitName(targetGuid)
            if targetName and not isUnknownName(targetName) then
                local casterName = SafeUnitName(casterGuid)
                if casterName and not isUnknownName(casterName) then
                    if targetGuid ~= casterGuid then
                        local ownerName, _ = GetOwnerInfoFromPetGUID(casterGuid)
                        updateReviveStats(casterName, targetName, ownerName)
                    end
                end
            end
        end

        parser.lastRefreshEventTime = GetTime()
    end

    -- ----------------------------------------------------------------------------
    -- 28.1 事件注册与 OnEvent 分发（第 28 节子块）
    -- ----------------------------------------------------------------------------
    -- 注意：事件注册已拆分为两部分，避免与 RefreshEventRegistration 重复：
    --   1) 与 enabled 开关有关的事件 → 由 parser:RefreshEventRegistration() 管理
    --      （见上方第 1 节 UpdateEnabledStats → RefreshEventRegistration）。
    --   2) 与 enabled 开关无关的事件 → 由 registerAlwaysOnEvents() 在 hasNampower
    --      块开头一次性注册。
    -- 此处不再重复 RegisterEvent。

    local currentTargetGUID = nil

    parser:SetScript("OnEvent", function()
        if event == "SPELL_DAMAGE_EVENT_SELF" then
            onSpellDamageSelf(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
        elseif event == "SPELL_DAMAGE_EVENT_OTHER" then
            onSpellDamageOther(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
        elseif event == "AUTO_ATTACK_SELF" then
            onAutoAttackSelf(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
        elseif event == "AUTO_ATTACK_OTHER" then
            onAutoAttackOther(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
        elseif event == "SPELL_MISS_SELF" or event == "SPELL_MISS_OTHER" then
            onSpellMiss(arg1, arg2, arg3, arg4)
        elseif event == "SPELL_HEAL_BY_SELF" then
            onSpellHealBySelf(arg1, arg2, arg3, arg4, arg5, arg6)
        elseif event == "SPELL_HEAL_BY_OTHER" then
            onSpellHealByOther(arg1, arg2, arg3, arg4, arg5, arg6)
        elseif event == "DAMAGE_SHIELD_SELF" then
            -- onDamageShieldSelf 写入 damage/friendly_fire/damage_taken/
            -- enemy_damage_taken/invalid_damage/heal/heal_taken；任一启用才处理
            if parser.enabled.damage or parser.enabled.friendly_fire
                    or parser.enabled.damage_taken or parser.enabled.enemy_damage_taken
                    or parser.enabled.invalid_damage
                    or parser.enabled.heal or parser.enabled.heal_taken then
                onDamageShieldSelf(arg1, arg2, arg3, arg4)
            end
        elseif event == "DAMAGE_SHIELD_OTHER" then
            if parser.enabled.damage or parser.enabled.friendly_fire
                    or parser.enabled.damage_taken or parser.enabled.enemy_damage_taken
                    or parser.enabled.invalid_damage
                    or parser.enabled.heal or parser.enabled.heal_taken then
                onDamageShieldOther(arg1, arg2, arg3, arg4)
            end
        elseif event == "UNIT_DIED" then
            onUnitDied(arg1)
            if arg1 == "target" or (currentTargetGUID and arg1 == currentTargetGUID) then
                data.threat = {}
                currentTargetGUID = nil
            end
        elseif event == "SPELL_GO_SELF" then
            onSpellGo(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
            if parser.enabled.dispel then
                local spellName = getSpellName(arg2)
                local casterName = SafeUnitName("player")
                CheckWrongDispelOnSpellGo(spellName, "player", arg4, casterName)
            end
        elseif event == "SPELL_GO_OTHER" then
            onSpellGo(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
            if parser.enabled.dispel then
                local spellName = getSpellName(arg2)
                local casterName = SafeUnitName(arg3)
                CheckWrongDispelOnSpellGo(spellName, arg3, arg4, casterName)
            end
        elseif event == "SPELL_DISPEL_BY_SELF" or event == "SPELL_DISPEL_BY_OTHER" then
            onDispel(arg1, arg2, arg3)
        elseif event == "PLAYER_TARGET_CHANGED" then
            currentTargetGUID = nil
            if UnitExists("target") and not UnitIsPlayer("target") then
                currentTargetGUID = GetUnitGUID("target")
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            -- 进入世界/换地图/传送时无需额外操作（数据段管理由 combat 状态机负责）
        elseif event == "AURA_CAST_ON_SELF" or event == "AURA_CAST_ON_OTHER" then
            -- AURA_CAST 同时支撑命中明细(E.damage/invalid_damage)、易伤扫描(E.weakness_coverage)、
            -- 护盾生命周期(E.heal/heal_taken)；任一启用时才需要处理
            if parser.enabled.damage or parser.enabled.invalid_damage
                    or parser.enabled.weakness_coverage
                    or parser.enabled.heal or parser.enabled.heal_taken then
                onAuraCast(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
            end
        elseif event == "BUFF_REMOVED_SELF" or event == "BUFF_REMOVED_OTHER" or event == "DEBUFF_REMOVED_SELF" or event == "DEBUFF_REMOVED_OTHER" then
            -- 多 handler 共用：onBuffRemoved(护盾,需heal/heal_taken)+handleBuffRemove(buff_coverage)
            -- +UnmarkBadDispelDebuff(dispel)+handleWeaknessAuraRemove(weakness_coverage)
            if parser.enabled.heal or parser.enabled.heal_taken
                    or parser.enabled.buff_coverage or parser.enabled.weakness_coverage
                    or parser.enabled.dispel then
                -- 仅 heal/heal_taken 启用时才走 onBuffRemoved（其内部 shieldData 处理
                -- 会构造 activeShields 对象，若禁用 heal/heal_taken 时仍构造，
                -- 会因 DAMAGE_SHIELD 被守卫跳过而 processAbsorb 不调用，造成内存累积）
                if parser.enabled.heal or parser.enabled.heal_taken then
                    onBuffRemoved(arg1, arg2, arg3, arg4, arg5, arg6, arg7)
                end
                local auraType = string.find(event, "DEBUFF") and "debuff" or "buff"
                if parser.enabled.buff_coverage then
                    parser:handleBuffRemove(arg1, arg3, arg7, auraType)
                end
                if parser.enabled.dispel and ShaguDPS.badDispelDebuffs[getSpellName(arg3)] then
                    UnmarkBadDispelDebuff(arg1, arg3)
                end
                if parser.enabled.weakness_coverage then
                    parser:handleWeaknessAuraRemove(arg1, arg3, arg7, auraType)
                end
            end
        elseif event == "DEBUFF_ADDED_SELF" or event == "DEBUFF_ADDED_OTHER" then
            if parser.enabled.heal or parser.enabled.heal_taken
                    or parser.enabled.buff_coverage or parser.enabled.weakness_coverage
                    or parser.enabled.dispel then
                if parser.enabled.heal or parser.enabled.heal_taken then
                    onBuffAdded(arg1, arg2, arg3, arg4, arg5, arg6, arg7)
                end
                if parser.enabled.buff_coverage then
                    parser:handleBuffAdd(arg1, arg3, arg7, "debuff")
                end
                if parser.enabled.dispel then
                    MarkBadDispelDebuff(arg1, arg3)
                end
                if parser.enabled.weakness_coverage then
                    parser:handleWeaknessAuraAdd(arg1, arg3, arg7, "debuff")
                end
            end
        elseif event == "BUFF_ADDED_SELF" or event == "BUFF_ADDED_OTHER" then
            if parser.enabled.heal or parser.enabled.heal_taken
                    or parser.enabled.buff_coverage or parser.enabled.weakness_coverage then
                if parser.enabled.heal or parser.enabled.heal_taken then
                    onBuffAdded(arg1, arg2, arg3, arg4, arg5, arg6, arg7)
                end
                if parser.enabled.buff_coverage then
                    parser:handleBuffAdd(arg1, arg3, arg7, "buff")
                end
                if parser.enabled.weakness_coverage then
                    parser:handleWeaknessAuraAdd(arg1, arg3, arg7, "buff")
                end
            end
        elseif event == "ENVIRONMENTAL_DMG_SELF" then
            if parser.enabled.damage_taken then
                onEnvironmentalDmgSelf(arg1, arg2, arg3, arg4, arg5)
            end
        elseif event == "ENVIRONMENTAL_DMG_OTHER" then
            if parser.enabled.damage_taken then
                onEnvironmentalDmgOther(arg1, arg2, arg3, arg4, arg5)
            end
        elseif event == "SPELL_ENERGIZE_BY_SELF" then
            onSpellEnergizeBySelf(arg1, arg2, arg3, arg4, arg5, arg6)
        elseif event == "SPELL_ENERGIZE_BY_OTHER" then
            onSpellEnergizeByOther(arg1, arg2, arg3, arg4, arg5, arg6)
        elseif event == "SPELL_FAILED_OTHER" then
            onSpellFailedOther(arg1, arg2)
        end
        parser.lastRefreshEventTime = GetTime()
    end)

    parser:UpdateEnabledStats()
end

-- ============================================================================
-- 29. 仇恨统计模块（不依赖 Nampower）
-- ============================================================================

-- 计算单位当前 TPS（每秒威胁值）：
-- 维护按秒采样的威胁历史（仅保留最近 10 秒），取最近 10 个秒级增量求平均
local function calcTPS(name, currentThreat)
    if not data.threat_history then data.threat_history = {} end
    local history = data.threat_history[name]
    if not history then
        history = {}
        data.threat_history[name] = history
    end
    local now = time()
    history[now] = currentThreat
    for t, _ in pairs(history) do
        if now - t > 10 then history[t] = nil end
    end
    local tps = 0
    local count = 0
    for i = 0, 9 do
        local cur = history[now - i]
        local prev = history[now - i - 1]
        if cur and prev then
            tps = tps + (cur - prev)
            count = count + 1
        end
    end
    if count > 0 and tps > 0 then return round(tps / count) end
    return 0
end

-- 解析敌方插件广播的仇恨数据包（TWTv4 协议）：
-- 格式 "TWTv4=玩家名:tank标志:威胁值:百分比:...;..."，字段以冒号分隔、玩家以分号分隔
local function parseThreatPacket(msg)
    local prefix = "TWTv4="
    local start = string.find(msg, prefix, 1, true)
    if not start then return end
    local content = string.sub(msg, start + string.len(prefix))
    if not content or content == "" then return end
    data.threat = {}
    for playerData in string.gfind(content, "[^;]+") do
        local parts = {}
        for p in string.gfind(playerData, "[^:]+") do
            table.insert(parts, p)
        end
        if table.getn(parts) >= 5 then
            local name = parts[1]
            local tank = parts[2] == "1"
            local threat = tonumber(parts[3]) or 0
            local perc = tonumber(parts[4]) or 0
            local class = data.classes[name]
            data.threat[name] = {
                threat = threat,
                tank = tank,
                perc = perc,
                tps = calcTPS(name, threat),
                class = class,
            }
        end
    end
    parser.lastRefreshEventTime = GetTime()

    if ShaguDPS.threatAlert and ShaguDPS.threatAlert.Update then
        ShaguDPS.threatAlert:Update()
    end

    -- 收到仇恨数据时，若处于战斗且存在隐藏的仇恨视图窗口，则显示
    if ShaguDPS.window and ShaguDPS.Combat() then
        for i = 1, 10 do
            local win = ShaguDPS.window[i]
            if win and win.ApplyVisibilityOverride and not win:IsShown() then
                local wid = win:GetID()
                if config[wid] and config[wid].view == 11 then
                    win:ApplyVisibilityOverride()
                end
            end
        end
    end
end

-- 监听仇恨广播（CHAT_MSG_ADDON）与目标切换，更新/清空仇恨表
local threatEventFrame = CreateFrame("Frame")
threatEventFrame:RegisterEvent("CHAT_MSG_ADDON")
threatEventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
threatEventFrame:SetScript("OnEvent", function()
    if event == "CHAT_MSG_ADDON" then
        if arg1 and string.find(arg1, "TWT") and arg2 and string.find(arg2, "TWTv4=") then
            parseThreatPacket(arg2)
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        data.threat = {}
        parser.lastRefreshEventTime = GetTime()
    end
end)

-- 定时向队友请求仇恨数据（每 0.5 秒一次；仅战斗中对非玩家、未死亡的目标发起）
local threatRequestFrame = CreateFrame("Frame")
threatRequestFrame:SetScript("OnUpdate", function()
    if not this.lastUpdate then this.lastUpdate = 0 end
    local now = GetTime()
    if now - this.lastUpdate < 0.5 then return end
    this.lastUpdate = now
    if not ShaguDPS.Combat() then return end
    if not UnitExists("target") or UnitIsPlayer("target") or UnitIsDead("target") then return end
    local channel = (GetNumRaidMembers() > 0) and "RAID" or "PARTY"
    if GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0 then return end
    SendAddonMessage("TWT", "TWT_UDTSv4_limit=" .. 10, channel)
end)
