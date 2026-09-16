--[[
    ============================================================================
    ShaguDPS 核心模块
    ============================================================================
    负责初始化全局数据表、默认配置、通用工具函数，并检测 Nampower 扩展是否可用。
    所有其他模块（解析器、窗口、设置）都依赖于此模块导出的 ShaguDPS 表。
    此模块在插件加载时最先执行，定义全局命名空间、数据结构、配置默认值、
    缓存加载/保存、公共函数等。
    ============================================================================
]]

-- ============================================================================
-- 1. 全局命名空间与基础变量
-- ============================================================================

ShaguDPS = {}

-- 小怪战斗累计总持续时间（秒），用于光环覆盖率计算时的总时间基准
ShaguDPS.small_fight_total_time = 0

-- 敌对目标跟踪表：用于精确战斗状态判定
ShaguDPS.hostile_targets = ShaguDPS.hostile_targets or {}

-- 创建一个通用的确认/取消对话框模板，用于清空数据等需要用户确认的操作
StaticPopupDialogs["SHAGUMETER_QUESTION"] = {
    button1 = YES,
    button2 = NO,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

-- 可用的状态栏材质列表，用于进度条外观切换
local textures = {
    "Interface\\BUTTONS\\WHITE8X8",
    "Interface\\TargetingFrame\\UI-StatusBar",
    "Interface\\Tooltips\\UI-Tooltip-Background",
    "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar"
}

-- ============================================================================
-- 2. 工具函数
-- ============================================================================

-- 简单的四舍五入函数
-- @param input 要舍入的数值
-- @param places 保留的小数位数，默认为 0
-- @return 舍入后的数值
local function round(input, places)
    if not places then places = 0 end
    if type(input) == "number" and type(places) == "number" then
        local pow = 1
        for i = 1, places do pow = pow * 10 end
        return floor(input * pow + 0.5) / pow
    end
end

-- ============================================================================
-- 2.5 vanilla 1.12 API 兼容层
-- ============================================================================
-- 部分 API 是 TBC+（2.x）才加入的暴雪原生接口，vanilla 1.12 没有：
--   GetUnitGUID     -> 1.12 用 UnitGUID（SuperWoW）或 UnitExists 的第二返回值
--   GetSpellRecField -> 1.12 只有 GetSpellInfo（返回 name/rank/icon 等基础字段）
-- 这里在缺失时提供等价实现，保证香草环境不报错。
-- Nampower 的 GUID 扩展用法（GetUnitGUID("0x...owner")）在 vanilla 无对应能力，
-- 返回 nil，调用方已有降级路径（GetUnitField charm/createdBy 等）。
if not GetUnitGUID then
    -- 三级降级链（与 pfUI.api.GetUnitGUID 一致）：
    --   1. Nampower 3.0+ -> GetUnitGUID(unit)（已在判断不存在，故不重复检查）
    --   2. SuperWoW      -> UnitGUID(unit)
    --   3. 纯 vanilla    -> select(2, UnitExists(unit))（vanilla 1.12 原生返回 GUID）
    -- Nampower 的 GUID 扩展用法（GetUnitGUID("0x...owner")）无对应能力时返回 nil，
    -- 调用方已有降级路径（GetUnitField charm/createdBy 等）。
    GetUnitGUID = function(unit)
        -- Nampower 扩展：petGUID .. "owner" 形式，环境不支持时返回 nil
        if type(unit) == "string" and string.sub(unit, 1, 2) == "0x" then
            return nil
        end
        if UnitGUID then
            local guid = UnitGUID(unit)
            if guid and guid ~= "" and guid ~= "0x0000000000000000" then
                return guid
            end
        end
        -- 纯 vanilla 原生：UnitExists 的第二返回值即 GUID
        if UnitExists then
            return select(2, UnitExists(unit))
        end
        return nil
    end
end

if not GetSpellRecField then
    -- GetSpellInfo 是 vanilla 1.12 核心 API，但为极特殊环境做防护
    local spellInfoApi = GetSpellInfo
    GetSpellRecField = function(spellId, field)
        if not spellInfoApi then
            return nil
        end
        local name = spellInfoApi(spellId)
        if field == "name" then
            return name
        end
        -- dispel/effect 等扩展字段 vanilla 无法获取，返回 nil（调用方已有 nil 防护）
        return nil
    end
end

-- 检测当前客户端版本（香草/TBC/WOTLK），用于不同扩展的兼容处理
-- @return "tbc", "wotlk" 或 "vanilla"
local function expansion()
    local _, _, _, client = GetBuildInfo()
    client = client or 11200

    if client >= 20000 and client <= 20400 then
        return "tbc"
    elseif client >= 30000 and client <= 30300 then
        return "wotlk"
    else
        return "vanilla"
    end
end

-- 检测 Nampower 是否可用且版本 >= 4.5.0（需要驱散事件等高级功能）
local function checkNampower()
    if not GetNampowerVersion then
        return false
    end
    local major, minor, patch = GetNampowerVersion()
    if major and (major > 4 or (major == 4 and minor >= 5)) then
        return true
    end
    return false
end

ShaguDPS.hasNampower = checkNampower()
if not ShaguDPS.hasNampower and GetNampowerVersion then
    -- Nampower 存在但版本过低，提示回退到战斗日志解析模式
    DEFAULT_CHAT_FRAME:AddMessage("|cffff0000ShaguDPS: 需要 Nampower 4.5.0 或更高版本才能使用精确数据采集，已回退到战斗日志解析模式。|r")
end

-- ============================================================================
-- 3. 全局数据存储结构
-- ============================================================================

-- data 表包含所有统计类型（伤害/治疗/死亡/技能施放/命中明细/误伤/驱散/破甲/
-- 承受伤害/能量回复/无效伤害/受到治疗/DOT跳数/复活/光环/打断/敌人承伤等）。
-- 每种统计分两段：[0]=全程, [1]=当前战斗；单位数据以单位名为 key 存子表。
-- invalid_damage 按源玩家名存储，_by_target 映射目标名到子表。
local data = {
    damage = { [0] = {}, [1] = {} },
    heal = { [0] = {}, [1] = {} },
    death = { [0] = {}, [1] = {} },
    spellcast = { [0] = {}, [1] = {} },
    spellcast_details = { [0] = {}, [1] = {} },
    friendly_fire = { [0] = {}, [1] = {} },
    dispel = { [0] = {}, [1] = {} },
    sunder = { [0] = {}, [1] = {} },
    damage_taken = { [0] = {}, [1] = {} },
    enemy_damage_taken = { [0] = {}, [1] = {} },
    energize = { [0] = {}, [1] = {} },
    invalid_damage = { [0] = {}, [1] = {} },
    heal_taken = { [0] = {}, [1] = {} },
    dot_ticks = { [0] = {}, [1] = {} },
    hit_breakdown = { [0] = {}, [1] = {} },
    revive = { [0] = {}, [1] = {} },
    buff_coverage = { [0] = {}, [1] = {} },
    weakness_coverage = { [0] = {}, [1] = {} },
    interrupt = { [0] = {}, [1] = {} },
    enemy_max_health = {},
    classes = {},
    threat = {},
    threat_history = {},
    death_timestamps = {},
    death_replays = {},
    all_death_replays = {},
}

data.combat_start_time = 0
data.last_fight_duration = 0
data.total_combat_time = 0
data.revive_noncombat = data.revive_noncombat or {}

-- 小怪累计统计（累加所有非BOSS战）
data.small_fight = {
    damage = {},
    heal = {},
    death = {},
    spellcast = {},
    spellcast_details = {},
    friendly_fire = {},
    dispel = {},
    sunder = {},
    damage_taken = {},
    enemy_damage_taken = {},
    energize = {},
    invalid_damage = {},
    heal_taken = {},
    dot_ticks = {},
    hit_breakdown = {},
    revive = {},
    buff_coverage = {},
    weakness_coverage = {},
    interrupt = {},
}

-- ============================================================================
-- 4. 用户配置默认值
-- ============================================================================

local config = {
    height = 15,
    spacing = 0,
    track_all_units = 0,
    merge_pets = 1,
    visible = 1,
    backdrop = 1,
    texture = 2,
    pastel = 0,
    lock = 0,
    exclude_critters = 0,
    hide_friendly_damage = 0,
    clamp_damage_to_health = 0,
    heal_only_in_combat = 1,
    show_dps_in_damage = 1,
    show_hps_in_heal = 0,
    show_overkill = 0,
    hide_nondefault_threat_out_of_combat = 0,
    show_only_tank_and_self_in_threat = 0,
    threat_aggro_sound = 0,
    threat_aggro_threshold = 90,
    menu_grow_upwards = 0,
    scale = 1.0,
    report_lines = 10,
    pfuiStyle = 0,
    auto_reset_on_new_group = 1,
    separate_mh_oh_damage = 0,
    use_total_cbt_for_dps = 0,
    show_class_icon = 0,
    chinese_units = 0,
    title_autohide = 0,
    hide_out_of_combat = 0,
    hide_out_of_party = 0,
    export_to_imports = 0,
    perCharConfig = 0,
    enabled_stats = {
        [1]=1, [2]=1, [3]=1, [4]=1, [5]=1, [6]=1, [7]=1, [8]=1,
        [9]=1, [10]=1, [11]=1, [13]=1, [14]=1, [16]=1, [17]=1,
        [18]=1, [19]=1, [20]=1, [21]=1, [22]=1, [24]=1,
        [25]=1,
    },
}

-- 内部特殊字段名集合，用于在遍历技能列表时跳过这些元数据字段
local internals = {
    ["_sum"] = true,
    ["_ctime"] = true,
    ["_tick"] = true,
    ["_esum"] = true,
    ["_effective"] = true,
    ["_total"] = true,
    ["_offensive"] = true,
    ["_defensive"] = true,
    ["_overkill"] = true,
    ["_overkill_by_spell"] = true,
    ["_history"] = true,
    ["_by_type"] = true,
    ["_by_target"] = true,
    ["_total_time"] = true,
    ["_events"] = true,
    ["_deaths"] = true,
    ["_target_deaths"] = true,
}

-- 创建核心组件框架（实际内容在其他文件中填充）
local settings = CreateFrame("Frame", nil, UIParent)
local parser = CreateFrame("Frame")
local window = {}

-- 将内部变量暴露到全局 ShaguDPS 表，供其他模块通过 ShaguDPS.xxx 访问
ShaguDPS.data = data
ShaguDPS.config = config
ShaguDPS.textures = textures
ShaguDPS.window = window
ShaguDPS.settings = settings
ShaguDPS.internals = internals
ShaguDPS.parser = parser
ShaguDPS.round = round
ShaguDPS.expansion = expansion

-- ============================================================================
-- 5. 战斗状态缓存与判断
-- ============================================================================

-- 战斗状态缓存（0.2 秒 TTL）：避免高频事件（每次治疗/每个 aura 事件）重复做几十次 API 扫描
ShaguDPS._combatCacheTime = 0
ShaguDPS._combatCacheValue = nil

-- 判断当前是否处于战斗状态。
-- 注意两个分支行为不同：
--  - 非 Nampower：玩家/宠物/任一队友在战斗即视为战斗（宽松判定，仅用于基础统计）
--  - Nampower：即便玩家/宠物/队友在战斗，也必须有真实敌对目标（hostile_targets）
--    正在被攻击才返回 true，避免队友血性狂怒等"空进战斗"导致误统计
-- @param force 传 true 时强制重新计算（跳过缓存）
function ShaguDPS.Combat(force)
    local now = GetTime()
    if not force and now - ShaguDPS._combatCacheTime < 0.2 then
        return ShaguDPS._combatCacheValue
    end
    local result
    if not ShaguDPS.hasNampower then
        if UnitAffectingCombat("player") or UnitAffectingCombat("pet") then result = true end
        if not result then
            local raid = GetNumRaidMembers()
            local group = GetNumPartyMembers()
            if raid >= 1 then
                for i = 1, raid do
                    if UnitAffectingCombat("raid" .. i) or UnitAffectingCombat("raidpet" .. i) then
                        result = true
                        break
                    end
                end
            else
                for i = 1, group do
                    if UnitAffectingCombat("party" .. i) or UnitAffectingCombat("partypet" .. i) then
                        result = true
                        break
                    end
                end
            end
        end
    else
        local anyGroupInCombat = UnitAffectingCombat("player") or UnitAffectingCombat("pet")
        local raid = GetNumRaidMembers()
        local group = GetNumPartyMembers()
        if raid >= 1 then
            for i = 1, raid do
                if UnitAffectingCombat("raid" .. i) or UnitAffectingCombat("raidpet" .. i) then
                    anyGroupInCombat = true
                    break
                end
            end
        else
            for i = 1, group do
                if UnitAffectingCombat("party" .. i) or UnitAffectingCombat("partypet" .. i) then
                    anyGroupInCombat = true
                    break
                end
            end
        end
        -- 关键闸门：队伍在战斗且存在真实敌对目标时，需逐一验证目标确实在战斗
        if anyGroupInCombat then
            for guid, info in pairs(ShaguDPS.hostile_targets or {}) do
                if type(info) == "table" and not info.dead then
                    if UnitAffectingCombat(guid) then
                        result = true
                        break
                    end
                end
            end
        end
    end
    ShaguDPS._combatCacheTime = now
    ShaguDPS._combatCacheValue = result
    return result
end

-- ============================================================================
-- 6. 统计视图管理
-- ============================================================================

if ShaguDPS.hasNampower then
    ShaguDPS.rightStatViews = {1,2,3,4,5,6,7,8,9,10,11,13,14,16,17,18,19,20,21,22,24}
else
    ShaguDPS.rightStatViews = {1,2,3,4,11}
end

-- 是否启用某统计视图
-- 视图 ID 说明：
--  12 = BOSS战, 15 = BOSS汇总, 23 = 最近战斗 —— 不受右侧开关控制，始终可见
--  11 = 仇恨 —— 无 Nampower 时仍可用
function ShaguDPS.IsStatEnabled(viewId)
    if viewId == 12 or viewId == 15 or viewId == 23 then return true end
    if not ShaguDPS.hasNampower and viewId ~= 11 and viewId > 4 then
        return false
    end
    local enabled_stats = ShaguDPS.config and ShaguDPS.config.enabled_stats
    if not enabled_stats then return true end
    return enabled_stats[viewId] ~= 0
end

function ShaguDPS.GetFirstEnabledStat()
    for _, id in ipairs(ShaguDPS.rightStatViews) do
        if ShaguDPS.IsStatEnabled(id) then
            return id
        end
    end
    return nil
end

function ShaguDPS.IsAnyViewEnabled(ids)
    for _, id in ipairs(ids) do
        if ShaguDPS.IsStatEnabled(id) then return true end
    end
    return false
end

-- ============================================================================
-- 7. 光环与易伤覆盖率活跃状态
-- ============================================================================

ShaguDPS.buff_coverage_active = {}
ShaguDPS.weakness_coverage_active = {}

-- ============================================================================
-- 8. BOSS 战与最近战斗记录
-- ============================================================================

ShaguDPS.boss_fights = ShaguDPS.boss_fights or {}
ShaguDPS.recent_fights = ShaguDPS.recent_fights or {}
ShaguDPS.current_recent_index = nil

function ShaguDPS.ClearBossFights()
    for i = table.getn(ShaguDPS.boss_fights), 1, -1 do
        table.remove(ShaguDPS.boss_fights, i)
    end
    if ShaguDPS_Cache then
        ShaguDPS_Cache.boss_fights = {}
    end
end

-- ============================================================================
-- 9. 缓存管理
-- ============================================================================

ShaguDPS.cached_current_dispel = nil
ShaguDPS.cached_current_damage_taken = nil
ShaguDPS.cached_current_heal_taken = nil
ShaguDPS.cached_current_spellcast_details = nil
ShaguDPS.cached_current_hit_breakdown = nil
ShaguDPS.cached_current_buff_coverage = nil
ShaguDPS.cached_current_weakness_coverage = nil
ShaguDPS.cached_current_death_replays = nil

-- 附近非队伍玩家职业映射（用于职业图标，不参与染色）
ShaguDPS.classIcons = ShaguDPS.classIcons or {}

ShaguDPS_Cache = ShaguDPS_Cache or {}

-- 将当前全部统计数据快照写入 ShaguDPS_Cache（SavedVariables），供下次登录恢复。
-- 命名约定：`xxx0` = 全程段 data[key][0]，`xxx1` = 当前战斗段 data[key][1]。
function ShaguDPS.SaveDataToCache()
    if not ShaguDPS_Cache then ShaguDPS_Cache = {} end

    local dataEmpty = true
    local statKeys = {
        "damage", "heal", "death", "spellcast", "spellcast_details",
        "friendly_fire", "dispel", "sunder", "damage_taken",
        "enemy_damage_taken", "energize", "invalid_damage",
        "heal_taken", "dot_ticks", "hit_breakdown", "revive",
        "buff_coverage", "weakness_coverage", "interrupt",
    }
    for _, key in ipairs(statKeys) do
        local seg = data[key]
        if seg and ((seg[0] and next(seg[0])) or (seg[1] and next(seg[1]))) then
            dataEmpty = false
            break
        end
    end
    if dataEmpty then
        local cacheHasData = false
        for _, key in ipairs(statKeys) do
            local cached = ShaguDPS_Cache[key .. "0"] or ShaguDPS_Cache[key .. "1"]
            if cached and next(cached) then
                cacheHasData = true
                break
            end
        end
        if cacheHasData then
            return
        end
    end

    ShaguDPS_Cache.version = 1
    ShaguDPS_Cache.timestamp = GetTime()
    ShaguDPS_Cache.damage0 = data.damage[0]
    ShaguDPS_Cache.heal0 = data.heal[0]
    ShaguDPS_Cache.death0 = data.death[0]
    ShaguDPS_Cache.spellcast0 = data.spellcast[0]
    ShaguDPS_Cache.spellcast_details0 = data.spellcast_details[0]
    ShaguDPS_Cache.friendly_fire0 = data.friendly_fire[0]
    ShaguDPS_Cache.dispel0 = data.dispel[0]
    ShaguDPS_Cache.sunder0 = data.sunder[0]
    ShaguDPS_Cache.damage_taken0 = data.damage_taken[0]
    ShaguDPS_Cache.enemy_damage_taken0 = data.enemy_damage_taken[0]
    ShaguDPS_Cache.energize0 = data.energize[0]
    ShaguDPS_Cache.invalid_damage0 = data.invalid_damage[0]
    ShaguDPS_Cache.heal_taken0 = data.heal_taken[0]
    ShaguDPS_Cache.dot_ticks0 = data.dot_ticks[0]
    ShaguDPS_Cache.hit_breakdown0 = data.hit_breakdown[0]
    ShaguDPS_Cache.revive0 = data.revive[0]
    ShaguDPS_Cache.buff_coverage0 = data.buff_coverage[0]
    ShaguDPS_Cache.weakness_coverage0 = data.weakness_coverage[0]
    ShaguDPS_Cache.interrupt0 = data.interrupt[0]
    ShaguDPS_Cache.damage1 = data.damage[1]
    ShaguDPS_Cache.heal1 = data.heal[1]
    ShaguDPS_Cache.death1 = data.death[1]
    ShaguDPS_Cache.spellcast1 = data.spellcast[1]
    ShaguDPS_Cache.spellcast_details1 = data.spellcast_details[1]
    ShaguDPS_Cache.friendly_fire1 = data.friendly_fire[1]
    ShaguDPS_Cache.dispel1 = data.dispel[1]
    ShaguDPS_Cache.sunder1 = data.sunder[1]
    ShaguDPS_Cache.damage_taken1 = data.damage_taken[1]
    ShaguDPS_Cache.enemy_damage_taken1 = data.enemy_damage_taken[1]
    ShaguDPS_Cache.energize1 = data.energize[1]
    ShaguDPS_Cache.invalid_damage1 = data.invalid_damage[1]
    ShaguDPS_Cache.heal_taken1 = data.heal_taken[1]
    ShaguDPS_Cache.dot_ticks1 = data.dot_ticks[1]
    ShaguDPS_Cache.hit_breakdown1 = data.hit_breakdown[1]
    ShaguDPS_Cache.revive1 = data.revive[1]
    ShaguDPS_Cache.buff_coverage1 = data.buff_coverage[1]
    ShaguDPS_Cache.weakness_coverage1 = data.weakness_coverage[1]
    ShaguDPS_Cache.interrupt1 = data.interrupt[1]
    ShaguDPS_Cache.cached_current_death_replays = ShaguDPS.cached_current_death_replays
    ShaguDPS_Cache.all_death_replays = data.all_death_replays
    ShaguDPS_Cache.classes = data.classes
    ShaguDPS_Cache.boss_fights = ShaguDPS.boss_fights
    ShaguDPS_Cache.recent_fights = ShaguDPS.recent_fights
    ShaguDPS_Cache.current_recent_index = ShaguDPS.current_recent_index
    ShaguDPS_Cache.death_timestamps = data.death_timestamps
    ShaguDPS_Cache.total_combat_time = data.total_combat_time
    ShaguDPS_Cache.revive_noncombat = data.revive_noncombat
    ShaguDPS_Cache.combat_start_time = data.combat_start_time
    ShaguDPS_Cache.last_fight_duration = data.last_fight_duration
    ShaguDPS_Cache.small_fight = data.small_fight
    ShaguDPS_Cache.small_fight_total_time = ShaguDPS.small_fight_total_time or 0
end

-- 登录时从 ShaguDPS_Cache 恢复统计，必须在 PLAYER_ENTERING_WORLD 中调用
-- （早于此时机调用会因 data 尚未填充而读到空数据，详见 SaveDataToCache 守卫）。
-- @return true 表示缓存存在并成功恢复，false 表示无有效缓存
function ShaguDPS.LoadDataFromCache()
    -- 数据源变更后需让 BOSS 汇总视图的缓存失效
    if ShaguDPS.InvalidateBossSummaryCache then ShaguDPS.InvalidateBossSummaryCache() end
    if not ShaguDPS_Cache or not ShaguDPS_Cache.version then
        return false
    end
    -- 恢复全程数据
    if ShaguDPS_Cache.damage0 then data.damage[0] = ShaguDPS_Cache.damage0 end
    if ShaguDPS_Cache.heal0 then data.heal[0] = ShaguDPS_Cache.heal0 end
    if ShaguDPS_Cache.death0 then data.death[0] = ShaguDPS_Cache.death0 end
    if ShaguDPS_Cache.spellcast0 then data.spellcast[0] = ShaguDPS_Cache.spellcast0 end
    if ShaguDPS_Cache.spellcast_details0 then data.spellcast_details[0] = ShaguDPS_Cache.spellcast_details0 end
    if ShaguDPS_Cache.friendly_fire0 then data.friendly_fire[0] = ShaguDPS_Cache.friendly_fire0 end
    if ShaguDPS_Cache.dispel0 then data.dispel[0] = ShaguDPS_Cache.dispel0 end
    if ShaguDPS_Cache.sunder0 then data.sunder[0] = ShaguDPS_Cache.sunder0 end
    if ShaguDPS_Cache.damage_taken0 then data.damage_taken[0] = ShaguDPS_Cache.damage_taken0 end
    if ShaguDPS_Cache.enemy_damage_taken0 then data.enemy_damage_taken[0] = ShaguDPS_Cache.enemy_damage_taken0 end
    if ShaguDPS_Cache.energize0 then data.energize[0] = ShaguDPS_Cache.energize0 end
    if ShaguDPS_Cache.invalid_damage0 then data.invalid_damage[0] = ShaguDPS_Cache.invalid_damage0 end
    if ShaguDPS_Cache.heal_taken0 then data.heal_taken[0] = ShaguDPS_Cache.heal_taken0 end
    if ShaguDPS_Cache.dot_ticks0 then data.dot_ticks[0] = ShaguDPS_Cache.dot_ticks0 end
    if ShaguDPS_Cache.hit_breakdown0 then data.hit_breakdown[0] = ShaguDPS_Cache.hit_breakdown0 end
    if ShaguDPS_Cache.revive0 then data.revive[0] = ShaguDPS_Cache.revive0 end
    if ShaguDPS_Cache.buff_coverage0 then data.buff_coverage[0] = ShaguDPS_Cache.buff_coverage0 end
    if ShaguDPS_Cache.weakness_coverage0 then data.weakness_coverage[0] = ShaguDPS_Cache.weakness_coverage0 end
    if ShaguDPS_Cache.interrupt0 then data.interrupt[0] = ShaguDPS_Cache.interrupt0 end

    -- 恢复当前战斗缓存（作为"上一场战斗"快照显示）。
    -- 恢复时统一把 data[key][1] 置空，确保新登录后的第一场战斗从空当前段开始，
    -- 避免旧数据被计入新战斗；脱战时再由 resetCurrentSegment() 完成同样的清空。
    if ShaguDPS_Cache.damage1 then
        ShaguDPS.cached_current_damage = ShaguDPS_Cache.damage1
        data.damage[1] = {}
    end
    if ShaguDPS_Cache.heal1 then
        ShaguDPS.cached_current_heal = ShaguDPS_Cache.heal1
        data.heal[1] = {}
    end
    if ShaguDPS_Cache.death1 then
        ShaguDPS.cached_current_death = ShaguDPS_Cache.death1
        data.death[1] = {}
    end
    if ShaguDPS_Cache.spellcast1 then
        ShaguDPS.cached_current_spellcast = ShaguDPS_Cache.spellcast1
        data.spellcast[1] = {}
    end
    if ShaguDPS_Cache.spellcast_details1 then
        ShaguDPS.cached_current_spellcast_details = ShaguDPS_Cache.spellcast_details1
        data.spellcast_details[1] = {}
    end
    if ShaguDPS_Cache.friendly_fire1 then
        ShaguDPS.cached_current_friendly_fire = ShaguDPS_Cache.friendly_fire1
        data.friendly_fire[1] = {}
    end
    if ShaguDPS_Cache.dispel1 then
        ShaguDPS.cached_current_dispel = ShaguDPS_Cache.dispel1
        data.dispel[1] = {}
    end
    if ShaguDPS_Cache.sunder1 then
        ShaguDPS.cached_current_sunder = ShaguDPS_Cache.sunder1
        data.sunder[1] = {}
    end
    if ShaguDPS_Cache.damage_taken1 then
        ShaguDPS.cached_current_damage_taken = ShaguDPS_Cache.damage_taken1
        data.damage_taken[1] = {}
    end
    if ShaguDPS_Cache.enemy_damage_taken1 then
        ShaguDPS.cached_current_enemy_damage_taken = ShaguDPS_Cache.enemy_damage_taken1
        data.enemy_damage_taken[1] = {}
    end
    if ShaguDPS_Cache.energize1 then
        ShaguDPS.cached_current_energize = ShaguDPS_Cache.energize1
        data.energize[1] = {}
    end
    if ShaguDPS_Cache.invalid_damage1 then
        ShaguDPS.cached_current_invalid_damage = ShaguDPS_Cache.invalid_damage1
        data.invalid_damage[1] = {}
    end
    if ShaguDPS_Cache.heal_taken1 then
        ShaguDPS.cached_current_heal_taken = ShaguDPS_Cache.heal_taken1
        data.heal_taken[1] = {}
    end
    if ShaguDPS_Cache.dot_ticks1 then
        ShaguDPS.cached_current_dot_ticks = ShaguDPS_Cache.dot_ticks1
        data.dot_ticks[1] = {}
    end
    if ShaguDPS_Cache.hit_breakdown1 then
        ShaguDPS.cached_current_hit_breakdown = ShaguDPS_Cache.hit_breakdown1
        data.hit_breakdown[1] = {}
    end
    if ShaguDPS_Cache.revive1 then
        ShaguDPS.cached_current_revive = ShaguDPS_Cache.revive1
        data.revive[1] = {}
    end
    if ShaguDPS_Cache.buff_coverage1 then
        ShaguDPS.cached_current_buff_coverage = ShaguDPS_Cache.buff_coverage1
        data.buff_coverage[1] = {}
    end
    if ShaguDPS_Cache.weakness_coverage1 then
        ShaguDPS.cached_current_weakness_coverage = ShaguDPS_Cache.weakness_coverage1
        data.weakness_coverage[1] = {}
    end
    if ShaguDPS_Cache.interrupt1 then
        ShaguDPS.cached_current_interrupt = ShaguDPS_Cache.interrupt1
        data.interrupt[1] = {}
    end
    if ShaguDPS_Cache.cached_current_death_replays then
        ShaguDPS.cached_current_death_replays = ShaguDPS_Cache.cached_current_death_replays
    end
    if ShaguDPS_Cache.all_death_replays then
        data.all_death_replays = ShaguDPS_Cache.all_death_replays
    end
    if ShaguDPS_Cache.classes then data.classes = ShaguDPS_Cache.classes end
    if ShaguDPS_Cache.boss_fights then ShaguDPS.boss_fights = ShaguDPS_Cache.boss_fights end
    if ShaguDPS_Cache.recent_fights then ShaguDPS.recent_fights = ShaguDPS_Cache.recent_fights end
    if ShaguDPS_Cache.current_recent_index then ShaguDPS.current_recent_index = ShaguDPS_Cache.current_recent_index end
    if ShaguDPS_Cache.death_timestamps then data.death_timestamps = ShaguDPS_Cache.death_timestamps end
    if ShaguDPS_Cache.total_combat_time then data.total_combat_time = ShaguDPS_Cache.total_combat_time end
    if ShaguDPS_Cache.revive_noncombat then data.revive_noncombat = ShaguDPS_Cache.revive_noncombat end
    if ShaguDPS_Cache.combat_start_time then data.combat_start_time = ShaguDPS_Cache.combat_start_time end
    if ShaguDPS_Cache.last_fight_duration then data.last_fight_duration = ShaguDPS_Cache.last_fight_duration end
    if ShaguDPS_Cache.small_fight then data.small_fight = ShaguDPS_Cache.small_fight end
    if ShaguDPS_Cache.small_fight_total_time then
        ShaguDPS.small_fight_total_time = ShaguDPS_Cache.small_fight_total_time
    end
    -- 确保 small_fight 结构完整（旧版缓存可能缺失较新的数据段，如 hit_breakdown）
    if data.small_fight then
        local smallSegDefaults = {
            damage = {}, heal = {}, death = {}, spellcast = {},
            spellcast_details = {}, friendly_fire = {}, dispel = {},
            sunder = {}, damage_taken = {}, enemy_damage_taken = {},
            energize = {}, invalid_damage = {}, heal_taken = {},
            dot_ticks = {}, hit_breakdown = {}, revive = {},
            buff_coverage = {}, weakness_coverage = {}, interrupt = {},
        }
        for key, init in pairs(smallSegDefaults) do
            if not data.small_fight[key] then data.small_fight[key] = init end
        end
    end

    -- 修正异常 _ctime
    local function fixCtime(tbl)
        if type(tbl) ~= "table" then return end
        for k, v in pairs(tbl) do
            if type(v) == "table" then
                if v._ctime and v._ctime <= 0 then
                    v._ctime = 1
                end
                fixCtime(v)
            end
        end
    end
    fixCtime(data.damage)
    fixCtime(data.heal)
    fixCtime(data.energize)
    fixCtime(data.invalid_damage)
    if data.small_fight then
        fixCtime(data.small_fight.damage)
        fixCtime(data.small_fight.heal)
        fixCtime(data.small_fight.energize)
        fixCtime(data.small_fight.invalid_damage)
    end
    return true
end

-- 清空全部统计与缓存（用户点"清空数据"时调用）。
-- 注意：本函数只显式重置 sunder/承伤/能量/无效伤害/受疗/DOT/命中/复活/覆盖率/打断等
-- 数据段，以及播放相关数据；damage/heal/death/spellcast/spellcast_details/friendly_fire/dispel
-- 这 6 类主统计段（[0] 与 [1]）不在重置列表中，由 window.lua 的 ResetData 另行清空。
function ShaguDPS.ClearCache()
    if ShaguDPS.InvalidateBossSummaryCache then ShaguDPS.InvalidateBossSummaryCache() end
    ShaguDPS_Cache = {}
    ShaguDPS.cached_current_damage = nil
    ShaguDPS.cached_current_heal = nil
    ShaguDPS.cached_current_death = nil
    ShaguDPS.cached_current_spellcast = nil
    ShaguDPS.cached_current_spellcast_details = nil
    ShaguDPS.cached_current_friendly_fire = nil
    ShaguDPS.cached_current_dispel = nil
    ShaguDPS.cached_current_damage_taken = nil
    ShaguDPS.cached_current_enemy_damage_taken = nil
    ShaguDPS.cached_current_energize = nil
    ShaguDPS.cached_current_invalid_damage = nil
    ShaguDPS.cached_current_heal_taken = nil
    ShaguDPS.cached_current_dot_ticks = nil
    ShaguDPS.cached_current_hit_breakdown = nil
    ShaguDPS.cached_current_revive = nil
    ShaguDPS.cached_current_buff_coverage = nil
    ShaguDPS.cached_current_weakness_coverage = nil
    ShaguDPS.cached_current_interrupt = nil
    ShaguDPS.cached_current_death_replays = nil
    data.death_replays = {}
    data.all_death_replays = {}
    ShaguDPS.boss_fights = {}
    ShaguDPS.recent_fights = {}
    ShaguDPS.current_recent_index = nil
    data.sunder[0] = {}
    data.sunder[1] = {}
    data.damage_taken[0] = {}
    data.damage_taken[1] = {}
    data.enemy_damage_taken[0] = {}
    data.enemy_damage_taken[1] = {}
    data.energize[0] = {}
    data.energize[1] = {}
    data.invalid_damage[0] = {}
    data.invalid_damage[1] = {}
    data.heal_taken[0] = {}
    data.heal_taken[1] = {}
    data.dot_ticks[0] = {}
    data.dot_ticks[1] = {}
    data.hit_breakdown[0] = {}
    data.hit_breakdown[1] = {}
    data.death_timestamps = {}
    data.total_combat_time = 0
    data.combat_start_time = 0
    data.last_fight_duration = 0
    data.revive_noncombat = {}
    data.revive[0] = {}
    data.revive[1] = {}
    data.spellcast_details[0] = {}
    data.spellcast_details[1] = {}
    data.buff_coverage[0] = {}
    data.buff_coverage[1] = {}
    data.weakness_coverage[0] = {}
    data.weakness_coverage[1] = {}
    data.interrupt[0] = {}
    data.interrupt[1] = {}
    ShaguDPS.buff_coverage_active = {}
    data.threat_history = {}
    data.threat = {}
    data.small_fight = {
        damage = {},
        heal = {},
        death = {},
        spellcast = {},
        spellcast_details = {},
        friendly_fire = {},
        dispel = {},
        sunder = {},
        damage_taken = {},
        enemy_damage_taken = {},
        energize = {},
        invalid_damage = {},
        heal_taken = {},
        dot_ticks = {},
        hit_breakdown = {},
        revive = {},
        buff_coverage = {},
        weakness_coverage = {},
        interrupt = {},
    }
    ShaguDPS.small_fight_total_time = 0
    ShaguDPS.hostile_targets = {}
    data.enemy_max_health = {}
end

-- ============================================================================
-- 10.5 数据导出 / 导入（Nampower / SuperWoW 的 ExportFile / ImportFile）
-- ============================================================================
-- 目的：把全部统计数据导出到 <游戏根目录>\Imports\ 下的 txt 文件；导出成功后可清空
-- WTF 里的统计数据，避免数据过大导致登录 132 报错。配置文件不受影响，仍存 WTF。

-- 是否具备文件导入导出能力（装了 Nampower 或 SuperWoW）
function ShaguDPS.IsExportAvailable()
    return type(ExportFile) == "function" and type(ImportFile) == "function"
end

-- 递归序列化 Lua 表为可执行的 Lua 源码片段
-- seen 用于检测循环引用（同一分支内重复出现视为环，输出 nil 避免死循环；
-- 兄弟节点共享同一张表会各自完整序列化，不会丢数据）
local function serializeValue(o, seen)
    local t = type(o)
    if t == "number" then
        if o ~= o then return "0" end
        if o == math.huge or o == -math.huge then return "0" end
        return tostring(o)
    elseif t == "string" then
        return string.format("%q", o)
    elseif t == "boolean" then
        return tostring(o)
    elseif t == "table" then
        if seen[o] then return "nil" end
        seen[o] = true
        local parts = {}
        for k, v in pairs(o) do
            parts[table.getn(parts) + 1] = "[" .. serializeValue(k, seen) .. "]=" .. serializeValue(v, seen)
        end
        seen[o] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "nil"
end

-- 序列化任意表为 "return {...}" 字符串
function ShaguDPS.Serialize(t)
    return "return " .. serializeValue(t, {})
end

-- 导出分片：每个文件最大 512KB（按大小切片，避免单文件过大）
local EXPORT_CHUNK_SIZE = 512 * 1024

-- 分片文件名前缀：最终写到 Imports\shagudps-<角色名>-<序号>.txt
-- 序号 0 为头文件（记录分片数量），1..N 为数据分片
local function exportBaseName()
    return "shagudps-" .. (UnitName("player") or "Unknown")
end

-- 导出全部统计数据（ShaguDPS_Cache）到 Imports（按 512KB 分片）
-- @return true 表示导出成功
function ShaguDPS.ExportDataToImports()
    if not ShaguDPS.IsExportAvailable() then return false end
    local payload = {
        version = 1,
        timestamp = time and time() or 0,
        cache = ShaguDPS_Cache,
    }
    local serialized = ShaguDPS.Serialize(payload)
    local total = string.len(serialized)

    -- 计算分片数量
    local chunkCount = 0
    local pos = 1
    while pos <= total do
        chunkCount = chunkCount + 1
        pos = pos + EXPORT_CHUNK_SIZE
    end

    local base = exportBaseName()
    local ok = pcall(function()
        -- 头文件记录分片数量，导入据此读取，避免读到上次遗留的旧分片
        ExportFile(base .. "-0", tostring(chunkCount))
        for i = 1, chunkCount do
            local piece = string.sub(serialized, (i - 1) * EXPORT_CHUNK_SIZE + 1, i * EXPORT_CHUNK_SIZE)
            ExportFile(base .. "-" .. i, piece)
        end
    end)
    return ok == true
end

-- 从 Imports 读取分片并还原，写回 ShaguDPS_Cache
-- @return true 表示导入成功
function ShaguDPS.ImportDataFromImports()
    if not ShaguDPS.IsExportAvailable() then return false end
    local base = exportBaseName()

    local countStr
    local ok = pcall(function() countStr = ImportFile(base .. "-0") end)
    if not ok or type(countStr) ~= "string" then return false end
    local count = tonumber(countStr)
    if not count or count < 1 then return false end

    local pieces = {}
    for i = 1, count do
        local piece
        local okI = pcall(function() piece = ImportFile(base .. "-" .. i) end)
        if not okI or type(piece) ~= "string" then return false end
        pieces[table.getn(pieces) + 1] = piece
    end

    local content = table.concat(pieces)
    if content == "" then return false end
    local chunk = loadstring(content)
    if not chunk then return false end
    local ok2, payload = pcall(chunk)
    if not ok2 or type(payload) ~= "table" then return false end
    if type(payload.cache) == "table" then ShaguDPS_Cache = payload.cache end
    return true
end

-- 登出时调用：若开启"数据导出到Imports"，导出全部统计数据；成功后清空 WTF 中的数据。
-- 导出失败则保留 WTF 数据（不清空），避免数据丢失。
function ShaguDPS.OnLogoutExport()
    if config.export_to_imports ~= 1 then return end
    if ShaguDPS.ExportDataToImports() then
        ShaguDPS_Cache = {}
    end
end

-- ============================================================================
-- 10. 无效单位名单（造成伤害时不统计入正常伤害，归入“无效伤害”视图）
-- ============================================================================

ShaguDPS.Locale = GetLocale()

-- 无效单位名单按客户端语言分别加载（zhCN 使用中文名，其余使用英文名）
if ShaguDPS.Locale == "zhCN" then
    ShaguDPS.ignoredUnitNames = ShaguDPS.ignoredUnitNames or {
        ["死亡骑士学员"] = true,
        ["势不可挡的地狱火"] = true,
        ["虛空地狱火"] = true,
        ["恶魔之心"] = true,
        ["管理者埃克索图斯"] = true,
        ["熔核怒犬"] = true,
        ["肉用僵尸"] = true,
    }
else
    ShaguDPS.ignoredUnitNames = ShaguDPS.ignoredUnitNames or {
        ["Deathknight Understudy"] = true,
        ["Unstoppable Infernal"] = true,
        ["Nether Infernal"] = true,
        ["Felheart"] = true,
        ["Majordomo Executus"] = true,
        ["Core Rager"] = true,
        ["Zombie chow"] = true,
    }
end

-- ============================================================================
-- 11. 错误驱散监测
-- ============================================================================

-- 不可驱散DEBUFF清单（驱散会导致死亡或严重后果的debuff）
-- type 取值：1=魔法, 2=诅咒, 3=疾病, 4=中毒, 5=激怒
ShaguDPS.badDispelDebuffs = {
    ["不稳定的法力"] = { type = 1 },
    ["外域的恐惧"]   = { type = 2 },
}

-- 驱散技能清单（技能名 -> 可驱散的debuff类型列表）
ShaguDPS.dispelSpells = {
    ["驱散魔法"]      = { types = { 1 } },
    ["驱除疾病"]      = { types = { 3 } },
    ["净化术"]        = { types = { 1 } },
    ["消毒术"]        = { types = { 4 } },
    ["祛病术"]        = { types = { 3 } },
    ["祛病图腾"]      = { types = { 3 } },
    ["清毒图腾"]      = { types = { 4 } },
    ["清洁术"]        = { types = { 3 } },
    ["纯净术"]        = { types = { 1 } },
    ["解除次级诅咒"]  = { types = { 2 } },
    ["驱毒术"]        = { types = { 4 } },
    ["解除诅咒"]      = { types = { 2 } },
    ["宁神射击"]      = { types = { 5 } },
}

-- 当前战斗中，目标身上存在的“不可驱散debuff”标记
ShaguDPS.activeBadDispelDebuffs = {}
-- 错误驱散记录
ShaguDPS.wrongDispels = {}