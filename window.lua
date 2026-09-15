--[[
    ============================================================================
    ShaguDPS 主窗口模块
    ============================================================================
    负责绘制进度条、处理鼠标交互、切换视图（伤害/DPS/治疗/HPS/驱散/仇恨/
    破甲/承受伤害/BOSS/BOSS汇总/能量回复/无效伤害/复活等）。
    包含窗口创建、数据获取、排序、显示刷新以及向聊天频道报告数据的功能。
    本模块是插件的用户界面核心，所有数据显示逻辑均在此实现。
    ============================================================================
]]

-- ============================================================================
-- 1. 模块初始化与公共变量引用
-- ============================================================================

local tbc = ShaguDPS.expansion() == "tbc" and true or nil

local window = ShaguDPS.window
local parser = ShaguDPS.parser
local data = ShaguDPS.data
local config = ShaguDPS.config
local internals = ShaguDPS.internals
local textures = ShaguDPS.textures
local round = ShaguDPS.round

-- 格式化战斗时间，超过1分钟显示为“xx分xx.x秒”，否则显示“xx.x秒”
local function formatDuration(seconds)
    if not seconds or seconds <= 0 then return nil end
    if seconds >= 60 then
        local mins = math.floor(seconds / 60)
        local secs = math.mod(seconds, 60)
        return string.format("%d分%.1f秒", mins, secs)
    else
        return string.format("%.1f秒", seconds)
    end
end

-- 所有已知的职业（用于职业着色）
local classes = {
    WARRIOR = true, MAGE = true, ROGUE = true, DRUID = true, HUNTER = true,
    SHAMAN = true, PRIEST = true, WARLOCK = true, PALADIN = true,
}

-- 职业图标：classicons.blp 为 256x256 图集（8列x8行网格，每格32px），此处记录各职业的纹理坐标 {left, right, top, bottom}
local classIconTexture = "Interface\\AddOns\\ShaguDPS\\dps\\classicons"
local classIcons = {
    -- 第一排：战士 法师 盗贼 德鲁伊
    WARRIOR = { 0.000, 0.122, 0.000, 0.123 },
    MAGE    = { 0.125, 0.247, 0.000, 0.123 },
    ROGUE   = { 0.250, 0.372, 0.000, 0.123 },
    DRUID   = { 0.375, 0.497, 0.000, 0.123 },
    -- 第二排：猎人 萨满 牧师 术士
    HUNTER  = { 0.000, 0.122, 0.125, 0.248 },
    SHAMAN  = { 0.125, 0.247, 0.125, 0.248 },
    PRIEST  = { 0.250, 0.372, 0.125, 0.248 },
    WARLOCK = { 0.373, 0.504, 0.121, 0.238 },
    -- 第三排：骑士
    PALADIN = { 0.000, 0.122, 0.250, 0.373 },
}

-- 根据单位名解析其职业 token（玩家直接取，宠物取主人职业），无职业返回 nil
local function resolveClassToken(name)
    if not name or not data["classes"] then return nil end
    local cls = data["classes"][name]
    if cls then
        if classes[cls] then
            return cls
        elseif classes[data["classes"][cls]] then
            -- 宠物：cls 为主人名，取主人职业
            return data["classes"][cls]
        end
    end
    -- 附近非队伍玩家：职业只存于 classIcons（仅图标，不染色）
    if ShaguDPS.classIcons then
        local iconCls = ShaguDPS.classIcons[name]
        if iconCls and classes[iconCls] then
            return iconCls
        end
    end
    return nil
end

-- 能量类型名称映射
local POWER_NAMES = {
    [0] = "法力", [1] = "怒气", [2] = "集中值", [3] = "能量",
}

-- 根据法术ID获取法术名称，0表示自动攻击
local function getSpellName(spellId)
    if not spellId or spellId == 0 then return "自动攻击" end
    local name = GetSpellRecField(spellId, "name")
    if name then return name end
    return "技能" .. spellId
end

-- ============================================================================
-- 2. 通用背景样式定义
-- ============================================================================

local backdrop = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 8,
    insets = { left = 2, right = 2, top = 2, bottom = 2 }
}

local backdrop_window = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
}

local backdrop_border = {
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
}

-- ============================================================================
-- 3. 视图模板定义
-- ============================================================================

-- 视图模板 (1-25) 定义：名称、排序方式、进度条最大值/值来源、聊天/进度条格式化字符串
local view_templates = {
    [1] = { name = "伤害量", sort = "normal", bar_max = "best", bar_val = "value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "(%s)  %s (%.1f%%)", bar_string = "(%s)  %s (%.1f%%)", bar_string_params = { "value_persecond", "value", "percent" } },
    [2] = { name = "DPS", sort = "per_second", bar_max = "persecond_best", bar_val = "value_persecond", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%s (%.1f%%)", bar_string = "%s (%.1f%%)", bar_string_params = { "value_persecond", "percent_persecond" } },
    [3] = { name = "治疗量", sort = "heal_total", bar_max = "best", bar_val = "effective_value", bar_lower_max = "best", bar_lower_val = "value",
        chat_string = "[+%s] %s (%.1f%%)", bar_string = "|cffcc8888+%s|r %s (%.1f%%)", bar_string_params = { "uneffective_value", "effective_value", "total_heal_percent" } },
    [4] = { name = "HPS", sort = "heal_hps", bar_max = "persecond_best", bar_val = "effective_value_persecond", bar_lower_max = "persecond_best", bar_lower_val = "value_persecond",
        chat_string = "[+%s] %s (%.1f%%)", bar_string = "|cffcc8888+%s|r %s (%.1f%%)", bar_string_params = { "uneffective_value_persecond", "effective_value_persecond", "total_hps_percent" } },
    [5] = { name = "有效治疗", sort = "effective_total", bar_max = "effective_best", bar_val = "effective_value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%s (%.1f%%)", bar_string = "%s (%.1f%%)", bar_string_params = { "effective_value", "total_effective_percent" } },
    [6] = { name = "过量治疗", sort = "overheal_total", bar_max = "uneffective_best", bar_val = "uneffective_value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%s (%.1f%%)", bar_string = "%s (%.1f%%)", bar_string_params = { "uneffective_value", "total_uneffective_percent" } },
    [7] = { name = "死亡次数", sort = "death_total", bar_max = "death_best", bar_val = "death_value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%s", bar_string = "%s", bar_string_params = { "death_value" } },
    [8] = { name = "技能施放", sort = "spellcast_total", bar_max = "spellcast_best", bar_val = "spellcast_total", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%s", bar_string = "%s", bar_string_params = { "spellcast_total" } },
    [9] = { name = "队友误伤", sort = "friendly_fire_total", bar_max = "friendly_fire_best", bar_val = "friendly_fire_total", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%s", bar_string = "%s", bar_string_params = { "friendly_fire_total" } },
    [10] = { name = "驱散", sort = "dispel_total", bar_max = "dispel_best", bar_val = "dispel_total", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%s (进攻:%s 防御:%s)", bar_string = "%s (攻:%s 防:%s)", bar_string_params = { "dispel_total", "dispel_offensive", "dispel_defensive" } },
    [11] = { name = "仇恨", sort = "threat_total", bar_max = "threat_best", bar_val = "threat_value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "(%s) %s (%.1f%%)", bar_string = "(%s) %s (%.1f%%)", bar_string_params = { "tps_str", "threat_value_str", "perc" } },
    [12] = { name = "BOSS", sort = "normal", bar_max = "best", bar_val = "value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "(%s)  %s (%.1f%%)", bar_string = "(%s)  %s (%.1f%%)", bar_string_params = { "value_persecond", "value", "percent" } },
    [13] = { name = "破甲", sort = "sunder_total", bar_max = "sunder_best", bar_val = "sunder_value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%s", bar_string = "%s", bar_string_params = { "sunder_value" } },
    [14] = { name = "承受伤害", sort = "damage_taken_total", bar_max = "damage_taken_best", bar_val = "damage_taken_value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%s (%.1f%%)", bar_string = "%s (%.1f%%)", bar_string_params = { "damage_taken_value", "damage_taken_percent" } },
    [15] = { name = "BOSS汇总", sort = "normal", bar_max = "best", bar_val = "value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "(%s)  %s (%.1f%%)", bar_string = "(%s)  %s (%.1f%%)", bar_string_params = { "value_persecond", "value", "percent" } },
    [16] = { name = "能量回复", sort = "energize_total", bar_max = "best", bar_val = "value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%s (%.1f%%)", bar_string = "%s (%.1f%%)", bar_string_params = { "value", "percent" } },
    [17] = { name = "无效伤害", sort = "invalid_total", bar_max = "best", bar_val = "value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "(%s)  %s (%.1f%%)", bar_string = "(%s)  %s (%.1f%%)", bar_string_params = { "value_persecond", "value", "percent" } },
    [18] = { name = "受到治疗", sort = "heal_taken_total", bar_max = "best", bar_val = "effective_value", bar_lower_max = "best", bar_lower_val = "value",
        chat_string = "[+%s] %s (%.1f%%)", bar_string = "|cffcc8888+%s|r %s (%.1f%%)", bar_string_params = { "uneffective_value", "effective_value", "total_heal_percent" } },
    [19] = { name = "复活", sort = "revive_total", bar_max = "revive_best", bar_val = "revive_value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%s (%.1f%%)", bar_string = "%s (%.1f%%)", bar_string_params = { "revive_value", "percent" } },
    [20] = { name = "光环覆盖", sort = "buff_coverage", bar_max = "buff_count_max", bar_val = "total_count", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "buff:%d debuff:%d total:%d |cff00ff00Buff均值:%.1f%%|r |cffff4444Debuff均值:%.1f%%|r", bar_string = "buff:%d;debuff:%d;total:%d", bar_string_params = { "buff_count", "debuff_count", "total_count", "buff_avg_cov", "debuff_avg_cov" } },
    [21] = { name = "打断", sort = "interrupt_total", bar_max = "interrupt_best", bar_val = "interrupt_value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%s (%.1f%%)", bar_string = "%s (%.1f%%)", bar_string_params = { "interrupt_value", "interrupt_percent" } },
    [22] = { name = "敌人承伤", sort = "enemy_taken", bar_max = "enemy_taken_best", bar_val = "enemy_taken_value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%s (%.1f%%)", bar_string = "%s (%.1f%%)", bar_string_params = { "enemy_taken_value", "enemy_taken_percent" } },
    [23] = { name = "最近战斗", sort = "normal", bar_max = "best", bar_val = "value", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%s", bar_string = "%s", bar_string_params = { "value" } },
    [24] = { name = "易伤覆盖", sort = "vuln_coverage", bar_max = "vuln_count_max", bar_val = "total_count", bar_lower_max = nil, bar_lower_val = nil,
        chat_string = "%d (%.1f%%)", bar_string = "%d (%.1f%%)", bar_string_params = { "total_count", "avg_cov" } },
}

-- 普通视图ID <-> BOSS内部统计索引 的映射
local viewToBossStat = {}
local bossStatToView = {}
do
    local mapping = {
        [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 6,
        [7] = 7, [8] = 8, [9] = 9, [10] = 10, [13] = 11, [14] = 12,
        [16] = 13, [17] = 14, [18] = 15, [19] = 16, [20] = 17,
        [21] = 18, [22] = 19, [24] = 20,
    }
    for viewId, bossIdx in pairs(mapping) do
        viewToBossStat[viewId] = bossIdx
        bossStatToView[bossIdx] = viewId
    end
end

-- BOSS内部统计索引(1-20) → 右侧统计视图ID(1-24) 映射常量
local bossStatMapFull = {
    [1]=1, [2]=2, [3]=3, [4]=4, [5]=5, [6]=6,
    [7]=7, [8]=8, [9]=9, [10]=10,
    [11]=13, [12]=14, [13]=16, [14]=17,
    [15]=18, [16]=19, [17]=20, [18]=21, [19]=22,
    [20]=24,
}

-- 菜单按钮定义（左侧菜单包括 Current、Overall、Small；右侧为各种统计类型）
local menubuttons = {
    ["Current"]  = { 0, 1, -25.5, "当前", "|cffffffff显示当前战斗的数据",      "segment" },
    ["Overall"]  = { 1, 0, -25.5, "全程", "|cffffffff显示全程的总数据",         "segment" },
    ["Small"]    = { 2, 2, -25.5, "小怪", "|cffffffff显示小怪战斗的累计数据",  "segment" },
    ["Damage"]   = { 0, 1, 25.5,  "伤害量",     "|cffffffff显示伤害量",        "view" },
    ["DPS"]      = { 1, 2, 25.5,  "DPS",   "|cffffffff显示每秒伤害",      "view" },
    ["Heal"]     = { 2, 3, 25.5,  "治疗量",     "|cffffffff显示治疗量",        "view" },
    ["HPS"]      = { 3, 4, 25.5,  "HPS",   "|cffffffff显示每秒治疗",      "view" },
    ["Threat"]   = { 10, 11, 25.5,  "仇恨",   "|cffffffff显示当前目标仇恨",  "view" },
}
if ShaguDPS.hasNampower then
    menubuttons["BossMenu"] = { 3, 12, -25.5, "BOSS", "|cffffffff查看BOSS战记录", "segment" }
    menubuttons["BossSummaryMenu"] = { 4, 15, -25.5, "BOSS汇总", "|cffffffff查看所有BOSS战汇总数据", "segment" }
    menubuttons["RecentFights"] = { 5, 23, -25.5, "最近战斗", "|cffffffff查看最近5场战斗记录", "segment" }
    menubuttons["EffHeal"]  = { 4, 5, 25.5,  "有效治疗",   "|cffffffff显示有效治疗量",    "view" }
    menubuttons["OverHeal"] = { 5, 6, 25.5,  "过量治疗",   "|cffffffff显示过量治疗量",    "view" }
    menubuttons["Death"] = { 6, 7, 25.5,  "死亡",   "|cffffffff显示死亡次数",    "view" }
    menubuttons["Spellcast"] = { 7, 8, 25.5,  "技能施放",   "|cffffffff显示技能施放次数",    "view" }
    menubuttons["FriendlyFire"] = { 8, 9, 25.5,  "误伤",   "|cffffffff显示队友误伤",    "view" }
    menubuttons["Dispel"] = { 9, 10, 25.5,  "驱散",   "|cffffffff显示驱散统计",    "view" }
    menubuttons["Sunder"] = { 11, 13, 25.5, "破甲", "|cffffffff显示破甲次数", "view" }
    menubuttons["DamageTaken"] = { 12, 14, 25.5, "承受伤害", "|cffffffff显示承受伤害", "view" }
    menubuttons["Energize"] = { 13, 16, 25.5, "能量回复", "|cffffffff显示能量回复量（法力/怒气/能量/集中）", "view" }
    menubuttons["InvalidDamage"] = { 14, 17, 25.5, "无效伤害", "|cffffffff显示忽略单位的伤害统计", "view" }
    menubuttons["HealTaken"] = { 15, 18, 25.5, "受到治疗", "|cffffffff显示单位受到的治疗量", "view" }
    menubuttons["Revive"] = { 16, 19, 25.5, "复活", "|cffffffff显示复活次数", "view" }
    menubuttons["BuffCov"] = { 17, 20, 25.5, "光环覆盖", "|cffffffff显示光环覆盖率", "view" }
    menubuttons["Interrupt"] = { 18, 21, 25.5, "打断", "|cffffffff显示打断统计", "view" }
    menubuttons["EnemyTaken"] = { 19, 22, 25.5, "敌人承伤", "|cffffffff显示被追踪单位攻击的目标承受的伤害", "view" }
    menubuttons["VulnCov"] = { 20, 24, 25.5, "易伤覆盖", "|cffffffff显示敌人目标身上易伤debuff的覆盖率", "view" }
end

-- 右侧视图ID到按钮名称的映射（用于按开关显示/隐藏）
local rightViewButton = {
    [1] = "btnDamage", [2] = "btnDPS", [3] = "btnHeal", [4] = "btnHPS",
    [5] = "btnEffHeal", [6] = "btnOverHeal", [7] = "btnDeath",
    [8] = "btnSpellcast", [9] = "btnFriendlyFire", [10] = "btnDispel",
    [11] = "btnThreat", [13] = "btnSunder", [14] = "btnDamageTaken",
    [16] = "btnEnergize", [17] = "btnInvalidDamage", [18] = "btnHealTaken",
    [19] = "btnRevive", [20] = "btnBuffCov", [21] = "btnInterrupt",
    [22] = "btnEnemyTaken", [24] = "btnVulnCov",
}

-- 聊天频道颜色映射
local chatcolors = {
    ["SAY"] = "|cffFFFFFF",
    ["EMOTE"] = "|cffFF7E40",
    ["YELL"] = "|cffFF3F40",
    ["PARTY"] = "|cffAAABFE",
    ["GUILD"] = "|cff3CE13F",
    ["OFFICER"] = "|cff40BC40",
    ["RAID"] = "|cffFF7D01",
    ["RAID_WARNING"] = "|cffFF4700",
    ["BATTLEGROUND"] = "|cffFF7D01",
    ["WHISPER"] = "|cffFF7EFF",
    ["CHANNEL"] = "|cffFEC1C0"
}

-- ============================================================================
-- 4. 光环覆盖率详情获取函数
-- ============================================================================

local function GetBuffCoverageDetails(unitData, playerName, segmentType, totalTimeOverride)
    local details = {
        totalTime = 1,
        buffList = {},
        debuffList = {},
        buffCount = 0,
        debuffCount = 0,
        totalCount = 0,
        buffTotalCov = 0,
        debuffTotalCov = 0,
        totalCov = 0,
        avgCov = 0,
    }
    if not unitData then return details end

    local totalTime
    if totalTimeOverride and totalTimeOverride > 0 then
        totalTime = totalTimeOverride
    else
        local isCombat = ShaguDPS.Combat()
        if segmentType == 1 and isCombat and data.combat_start_time > 0 then
            totalTime = GetTime() - data.combat_start_time
        else
            totalTime = unitData["_total_time"] or 1
        end
    end
    if totalTime <= 0 then totalTime = 1 end
    details.totalTime = totalTime

    local function collectAuras(targetTable, activeAuras, outputTable)
        local totalCov = 0
        if targetTable then
            for k, v in pairs(targetTable) do
                outputTable[k] = (outputTable[k] or 0) + v
                totalCov = totalCov + v
            end
        end
        if activeAuras then
            for spellId, startTime in pairs(activeAuras) do
                if startTime and startTime > 0 then
                    local duration = GetTime() - startTime
                    if duration > 0 then
                        outputTable[spellId] = (outputTable[spellId] or 0) + duration
                        totalCov = totalCov + duration
                    end
                end
            end
        end
        return totalCov
    end

    local active = nil
    if segmentType == 1 and ShaguDPS.Combat() then
        active = ShaguDPS.buff_coverage_active[playerName]
    end

    local buffTemp = {}
    local buffTotalCov = collectAuras(unitData["buff"], active and active["buff"], buffTemp)
    details.buffTotalCov = buffTotalCov
    details.totalCov = details.totalCov + buffTotalCov

    for spellId, covTime in pairs(buffTemp) do
        local pct = covTime / totalTime * 100
        local spellName = getSpellName(spellId)
        table.insert(details.buffList, { id = spellId, name = spellName, time = covTime, pct = pct })
        details.buffCount = details.buffCount + 1
    end

    local debuffTemp = {}
    local debuffTotalCov = collectAuras(unitData["debuff"], active and active["debuff"], debuffTemp)
    details.debuffTotalCov = debuffTotalCov
    details.totalCov = details.totalCov + debuffTotalCov

    for spellId, covTime in pairs(debuffTemp) do
        local pct = covTime / totalTime * 100
        local spellName = getSpellName(spellId)
        table.insert(details.debuffList, { id = spellId, name = spellName, time = covTime, pct = pct })
        details.debuffCount = details.debuffCount + 1
    end

    details.totalCount = details.buffCount + details.debuffCount

    if details.totalCount > 0 then
        details.avgCov = (details.totalCov / details.totalCount / totalTime * 100)
    else
        details.avgCov = 0
    end

    if details.buffCount > 0 then
        details.buffAvgCov = details.buffTotalCov / details.buffCount / totalTime * 100
    else
        details.buffAvgCov = 0
    end
    if details.debuffCount > 0 then
        details.debuffAvgCov = details.debuffTotalCov / details.debuffCount / totalTime * 100
    else
        details.debuffAvgCov = 0
    end
    return details
end

-- ============================================================================
-- 5. 易伤覆盖率详情获取函数
-- ============================================================================

local function GetVulnerabilityCoverageDetails(targetData, totalTimeOverride, segmentType, targetName)
    local details = {
        totalTime = 1,
        spellList = {},
        totalCount = 0,
        avgCov = 0,
    }
    if not targetData then return details end

    local totalTime
    if totalTimeOverride and totalTimeOverride > 0 then
        totalTime = totalTimeOverride
    else
        if targetData["_total_time"] and targetData["_total_time"] > 0 then
            totalTime = targetData["_total_time"]
        else
            local isCombat = ShaguDPS.Combat()
            if (segmentType or 1) == 1 and isCombat and data.combat_start_time > 0 then
                totalTime = GetTime() - data.combat_start_time
            else
                totalTime = data.last_fight_duration or 1
            end
        end
    end
    if totalTime <= 0 then totalTime = 1 end
    details.totalTime = totalTime

    local totalCov = 0
    for spellId, covTime in pairs(targetData) do
        if spellId ~= "_total_time" and covTime > 0 then
            if covTime > totalTime then covTime = totalTime end
            local spellName = getSpellName(spellId)
            local pct = covTime / totalTime * 100
            if pct > 100 then pct = 100 end
            table.insert(details.spellList, { id = spellId, name = spellName, time = covTime, pct = pct })
            totalCov = totalCov + covTime
            details.totalCount = details.totalCount + 1
        end
    end

    if (segmentType or 1) == 1 and ShaguDPS.Combat() and targetName then
        local active = ShaguDPS.weakness_coverage_active[targetName]
        if active then
            local now = GetTime()
            for spellId, startTime in pairs(active) do
                if startTime and startTime > 0 then
                    local effectiveStart = startTime
                    if data.combat_start_time > 0 and effectiveStart < data.combat_start_time then
                        effectiveStart = data.combat_start_time
                    end
                    local duration = now - effectiveStart
                    if duration > 0 then
                        if duration > totalTime then duration = totalTime end
                        local found = false
                        for _, entry in ipairs(details.spellList) do
                            if entry.id == spellId then
                                entry.time = entry.time + duration
                                if entry.time > totalTime then entry.time = totalTime end
                                local pct = entry.time / totalTime * 100
                                if pct > 100 then pct = 100 end
                                entry.pct = pct
                                totalCov = totalCov + duration
                                found = true
                                break
                            end
                        end
                        if not found then
                            local spellName = getSpellName(spellId)
                            local safeDuration = duration
                            if safeDuration > totalTime then safeDuration = totalTime end
                            local pct = safeDuration / totalTime * 100
                            if pct > 100 then pct = 100 end
                            table.insert(details.spellList, { id = spellId, name = spellName, time = safeDuration, pct = pct })
                            totalCov = totalCov + safeDuration
                            details.totalCount = details.totalCount + 1
                        end
                    end
                end
            end
        end
    end

    table.sort(details.spellList, function(a,b) return a.pct > b.pct end)
    if details.totalCount > 0 then
        details.avgCov = totalCov / details.totalCount / totalTime * 100
        if details.avgCov > 100 then details.avgCov = 100 end
    end
    return details
end

-- ============================================================================
-- 6. BOSS汇总逻辑：全程 - 小怪
-- ============================================================================

-- 深度递归减法，用于计算 BOSS 汇总，并过滤掉 0 值和空表
local function deepSubtract(t1, t2)
    if t1 == nil then t1 = 0 end
    if t2 == nil then t2 = 0 end
    if type(t1) ~= "table" or type(t2) ~= "table" then
        return t1 - t2
    end
    local result = {}
    local skipKeys = {
        ["_history"] = true,
        ["_detail_history"] = true,
        ["_detail_heal_history"] = true,
        ["_tick"] = true,
    }
    for k, v in pairs(t1) do
        if skipKeys[k] then
            -- 跳过这些字段
        else
            local diff
            if t2[k] ~= nil then
                if type(v) == "table" and type(t2[k]) == "table" then
                    diff = deepSubtract(v, t2[k])
                else
                    diff = (v or 0) - (t2[k] or 0)
                end
            else
                diff = v
            end
            if type(diff) == "table" then
                if next(diff) ~= nil then
                    result[k] = diff
                end
            elseif diff ~= 0 then
                result[k] = diff
            end
        end
    end
    return result
end

local function GetBossSummaryDataRaw(statType)
    local small = data.small_fight
    local full = data
    local sourceType
    if statType == 1 or statType == 2 then
        sourceType = "damage"
    elseif statType == 3 or statType == 4 or statType == 5 or statType == 6 then
        sourceType = "heal"
    elseif statType == 7 then
        sourceType = "death"
    elseif statType == 8 then
        sourceType = "spellcast"
    elseif statType == 9 then
        sourceType = "friendly_fire"
    elseif statType == 10 then
        sourceType = "dispel"
    elseif statType == 11 then
        sourceType = "sunder"
    elseif statType == 12 then
        sourceType = "damage_taken"
    elseif statType == 13 then
        sourceType = "energize"
    elseif statType == 14 then
        sourceType = "invalid_damage"
    elseif statType == 15 then
        sourceType = "heal_taken"
    elseif statType == 16 then
        sourceType = "revive"
    elseif statType == 17 then
        sourceType = "buff_coverage"
    elseif statType == 18 then
        sourceType = "interrupt"
    elseif statType == 19 then
        sourceType = "enemy_damage_taken"
    elseif statType == 20 then
        sourceType = "weakness_coverage"
    else
        return {}
    end

    if statType == 16 then
        local bossRevive = deepSubtract(full.revive[0], small.revive or {})
        bossRevive = deepSubtract(bossRevive, full.revive_noncombat or {})
        for name, data in pairs(bossRevive) do
            if type(data) == "table" then
                local hasValue = false
                for k, v in pairs(data) do
                    if v ~= 0 then
                        hasValue = true
                        break
                    end
                end
                if not hasValue then
                    bossRevive[name] = nil
                end
            end
        end
        return bossRevive
    end

    local result = deepSubtract(full[sourceType][0], small[sourceType] or {})
    for name, data in pairs(result) do
        if type(data) == "table" then
            local hasValue = false
            for k, v in pairs(data) do
                if k ~= "_ctime" and k ~= "_tick" and k ~= "_by_type" and k ~= "_total_time" then
                    if type(v) == "number" and v ~= 0 then
                        hasValue = true
                        break
                    elseif type(v) == "table" and next(v) ~= nil then
                        local subHas = false
                        for sk, sv in pairs(v) do
                            if type(sv) == "number" and sv ~= 0 then
                                subHas = true
                                break
                            elseif type(sv) == "table" and next(sv) ~= nil then
                                subHas = true
                                break
                            end
                        end
                        if subHas then
                            hasValue = true
                            break
                        end
                    end
                elseif k == "_by_type" then
                    for _, amt in pairs(v) do
                        if amt ~= 0 then
                            hasValue = true
                            break
                        end
                    end
                    if hasValue then break end
                end
            end
            if not hasValue then
                result[name] = nil
            end
        end
    end
    return result
end

-- BOSS汇总数据缓存
local bossSummaryCache = {}
local bossSummaryLastInCombat = nil
ShaguDPS.InvalidateBossSummaryCache = function()
    bossSummaryCache = {}
end
local function GetBossSummaryData(statType)
    local inCombat = ShaguDPS.Combat() == true
    if bossSummaryLastInCombat ~= inCombat then
        bossSummaryCache = {}
        bossSummaryLastInCombat = inCombat
    end
    if inCombat then
        return GetBossSummaryDataRaw(statType)
    end
    if not bossSummaryCache[statType] then
        bossSummaryCache[statType] = GetBossSummaryDataRaw(statType)
    end
    return bossSummaryCache[statType]
end

local function GetBossSummaryDataForType(dataType)
    local small = data.small_fight
    local full = data
    if dataType == "dot_ticks" or dataType == "hit_breakdown" then
        local result = deepSubtract(full[dataType][0], small[dataType])
        for name, data in pairs(result) do
            if type(data) == "table" then
                local hasValue = false
                if dataType == "hit_breakdown" then
                    for _, actionData in pairs(data) do
                        if type(actionData) == "table" then
                            for _, cnt in pairs(actionData) do
                                if type(cnt) == "number" and cnt ~= 0 then
                                    hasValue = true
                                    break
                                end
                            end
                        end
                        if hasValue then break end
                    end
                else
                    for _, v in pairs(data) do
                        if type(v) == "number" and v ~= 0 then
                            hasValue = true
                            break
                        end
                    end
                end
                if not hasValue then
                    result[name] = nil
                end
            end
        end
        return result
    end
    return nil
end

-- ============================================================================
-- 7. 排序算法
-- ============================================================================

local sort_algorithms = {
    normal = function(t,a,b)
        if t[a]["_esum"] and t[b]["_esum"] and t[a]["_esum"] ~= t[b]["_esum"] then
            return t[b]["_esum"] < t[a]["_esum"]
        else
            return t[b]["_sum"] < t[a]["_sum"]
        end
    end,
    per_second = function(t,a,b,totalTime)
        local ea = (type(t[a]) == "table" and t[a]["_esum"]) or 0
        local eb = (type(t[b]) == "table" and t[b]["_esum"]) or 0
        local useCBT = totalTime and totalTime > 0
        local dpa, dpb
        if useCBT then
            dpa = ea / totalTime
            dpb = eb / totalTime
        else
            local cta = (type(t[a]) == "table" and t[a]["_ctime"]) or 1
            local ctb = (type(t[b]) == "table" and t[b]["_ctime"]) or 1
            if cta <= 0 then cta = 1 end
            if ctb <= 0 then ctb = 1 end
            dpa = ea / cta
            dpb = eb / ctb
        end
        if dpa ~= dpb then return dpb < dpa end
        local sa = (type(t[a]) == "table" and t[a]["_sum"]) or 0
        local sb = (type(t[b]) == "table" and t[b]["_sum"]) or 0
        if useCBT then
            return sb / totalTime < sa / totalTime
        end
        local cta = (type(t[a]) == "table" and t[a]["_ctime"]) or 1
        local ctb = (type(t[b]) == "table" and t[b]["_ctime"]) or 1
        if cta <= 0 then cta = 1 end
        if ctb <= 0 then ctb = 1 end
        return sb / ctb < sa / cta
    end,
    heal_total = function(t,a,b)
        local sa = (type(t[a]) == "table" and t[a]["_sum"]) or 0
        local sb = (type(t[b]) == "table" and t[b]["_sum"]) or 0
        return sb < sa
    end,
    heal_hps = function(t,a,b,totalTime)
        local sa = (type(t[a]) == "table" and t[a]["_sum"]) or 0
        local sb = (type(t[b]) == "table" and t[b]["_sum"]) or 0
        if totalTime and totalTime > 0 then
            return sb / totalTime < sa / totalTime
        end
        local cta = (type(t[a]) == "table" and t[a]["_ctime"]) or 1
        local ctb = (type(t[b]) == "table" and t[b]["_ctime"]) or 1
        if cta <= 0 then cta = 1 end
        if ctb <= 0 then ctb = 1 end
        return sb / ctb < sa / cta
    end,
    effective_total = function(t,a,b)
        local ea = (type(t[a]) == "table" and t[a]["_esum"]) or 0
        local eb = (type(t[b]) == "table" and t[b]["_esum"]) or 0
        if ea ~= eb then
            return eb < ea
        end
        local sa = (type(t[a]) == "table" and t[a]["_sum"]) or 0
        local sb = (type(t[b]) == "table" and t[b]["_sum"]) or 0
        return sb < sa
    end,
    overheal_total = function(t,a,b)
        local over_a = t[a]["_sum"] - (t[a]["_esum"] or 0)
        local over_b = t[b]["_sum"] - (t[b]["_esum"] or 0)
        return over_b < over_a
    end,
    death_total = function(t,a,b) return t[b] < t[a] end,
    spellcast_total = function(t,a,b)
        local total_a = t[a]["_total"] or 0
        local total_b = t[b]["_total"] or 0
        return total_b < total_a
    end,
    friendly_fire_total = function(t,a,b)
        local total_a = t[a]["_total"] or 0
        local total_b = t[b]["_total"] or 0
        return total_b < total_a
    end,
    dispel_total = function(t,a,b) return (t[b]._total or 0) < (t[a]._total or 0) end,
    threat_total = function(t,a,b) return (t[b].perc or 0) < (t[a].perc or 0) end,
    sunder_total = function(t,a,b) return (t[b]._total or 0) < (t[a]._total or 0) end,
    single_spell = function(t,a,b)
        if t["_effective"] and t["_effective"][a] and t["_effective"][b] and t["_effective"][a] ~= t["_effective"][b] then
            return t["_effective"][b] < t["_effective"][a]
        else
            if tonumber(t[b]) and tonumber(t[a]) then return t[b] < t[a] end
        end
    end,
    damage_taken_total = function(t,a,b) return (t[b]._sum or 0) < (t[a]._sum or 0) end,
    energize_total = function(t,a,b) return (t[b]._sum or 0) < (t[a]._sum or 0) end,
    invalid_total = function(t,a,b) return (t[b]._sum or 0) < (t[a]._sum or 0) end,
    heal_taken_total = function(t,a,b) return (t[b]._sum or 0) < (t[a]._sum or 0) end,
    revive_total = function(t,a,b) return (t[b]._total or 0) < (t[a]._total or 0) end,
    buff_coverage = function(t,a,b)
        local function getCount(playerData)
            if not playerData then return 0 end
            local count = 0
            if playerData["buff"] then
                for _ in pairs(playerData["buff"]) do count = count + 1 end
            end
            if playerData["debuff"] then
                for _ in pairs(playerData["debuff"]) do count = count + 1 end
            end
            return count
        end
        local function getAvg(playerData)
            if not playerData then return 0 end
            local totalTime = playerData["_total_time"] or 1
            if totalTime <= 0 then totalTime = 1 end
            local totalCov = 0
            local count = 0
            if playerData["buff"] then
                for _, v in pairs(playerData["buff"]) do totalCov = totalCov + v count = count + 1 end
            end
            if playerData["debuff"] then
                for _, v in pairs(playerData["debuff"]) do totalCov = totalCov + v count = count + 1 end
            end
            if count == 0 then return 0 end
            return (totalCov / count / totalTime * 100)
        end
        local count_a = getCount(t[a])
        local count_b = getCount(t[b])
        if count_a ~= count_b then
            return count_b < count_a
        end
        local avg_a = getAvg(t[a])
        local avg_b = getAvg(t[b])
        return avg_b < avg_a
    end,
    interrupt_total = function(t,a,b)
        return (t[b]._total or 0) < (t[a]._total or 0)
    end,
    enemy_taken = function(t,a,b)
        local sa = t[a] and (t[a]._sum or 0) or 0
        local sb = t[b] and (t[b]._sum or 0) or 0
        return sb < sa
    end,
    vuln_coverage = function(t,a,b)
        local function getCount(targetData, name)
            local seen = {}
            if targetData then
                for k, _ in pairs(targetData) do
                    if k ~= "_total_time" then seen[k] = true end
                end
            end
            local active = ShaguDPS.weakness_coverage_active and ShaguDPS.weakness_coverage_active[name]
            if active then
                for k, _ in pairs(active) do seen[k] = true end
            end
            local count = 0
            for _ in pairs(seen) do count = count + 1 end
            return count
        end
        local count_a = getCount(t[a], a)
        local count_b = getCount(t[b], b)
        if count_a ~= count_b then
            return count_b < count_a
        end
        return a < b
    end,
}

-- ============================================================================
-- 8. 颜色哈希与排序工具
-- ============================================================================

-- 字符串 → RGB 颜色（确定性哈希，用于对单位名/技能名生成稳定的颜色）
local rgbcache = {}
local function str2rgb(text)
    if not text then return 1, 1, 1 end
    if rgbcache[text] then return unpack(rgbcache[text]) end
    local counter = 1
    local l = string.len(text)
    for i = 1, l, 3 do
        counter = mod(counter*8161, 4294967279) +
            (string.byte(text,i)*16776193) +
            ((string.byte(text,i+1) or (l-i+256))*8372226) +
            ((string.byte(text,i+2) or (l-i+256))*3932164)
    end
    local hash = mod(mod(counter, 4294967291),16777216)
    local r = (hash - (mod(hash,65536))) / 65536
    local g = ((hash - r*65536) - ( mod((hash - r*65536),256)) ) / 256
    local b = hash - r*65536 - g*256
    rgbcache[text] = { r / 255, g / 255, b / 255 }
    return unpack(rgbcache[text])
end

-- 自定义 pairs 排序
local function spairs(t, order, totalTime)
    if type(t) ~= "table" then return function() end end
    local keys = {}
    for k in pairs(t) do keys[table.getn(keys)+1] = k end
    if order then table.sort(keys, function(a,b) return order(t, a, b, totalTime) end) else table.sort(keys) end
    local i = 0
    return function() i = i + 1; if keys[i] then return keys[i], t[keys[i]] end end
end

-- ============================================================================
-- 9. 获取死亡回放行（用于详情窗口）
-- ============================================================================

-- 死亡回放命中类型中文标签（nil/normal 不显示）
local hitTypeLabels = {
    crit = "|cffff5533暴击|r",
    crushing = "|cffff8800碾压|r",
    glancing = "|cff88ccff偏斜|r",
    block = "|cff88ccff格挡|r",
    dodge = "|cffaaaaaa躲闪|r",
    parry = "|cffaaaaaa招架|r",
    miss = "|cffaaaaaa未命中|r",
    resist = "|cffaaaaaa抵抗|r",
}

local function GetDeathReplayLines(unitName, segType, bossFight)
    local replayList = nil
    if bossFight then
        if bossFight.death_replays and bossFight.death_replays[unitName] then
            replayList = bossFight.death_replays[unitName]
        else
            local currentReplays = ShaguDPS.cached_current_death_replays or data.death_replays
            if currentReplays and currentReplays[unitName] then
                replayList = currentReplays[unitName]
            end
        end
    else
        if data.all_death_replays and data.all_death_replays[unitName] then
            replayList = data.all_death_replays[unitName]
        else
            local currentReplays = ShaguDPS.cached_current_death_replays or data.death_replays
            if currentReplays and currentReplays[unitName] then
                replayList = currentReplays[unitName]
            end
        end
    end

    if not replayList or table.getn(replayList) == 0 then
        return nil
    end

    local defaultBossName = "未知战斗"
    if bossFight and bossFight.name then
        defaultBossName = bossFight.name
    end

    local lines = {}
    for idx = table.getn(replayList), 1, -1 do
        local replay = replayList[idx]
        if replay then
            local fightName = replay.bossName or defaultBossName
            table.insert(lines, string.format("|cffffff00第%d次死亡 (战斗: %s)|r", idx, fightName))
            local deathTime = replay.deathTime or 0
            local events = {}

            if replay.damageEvents then
                for _, h in ipairs(replay.damageEvents) do
                    if h.time and h.time >= deathTime - 10 and h.time <= deathTime + 2 then
                        table.insert(events, { type = "damage", source = h.source, spell = h.spell, amount = h.damage, hitType = h.hitType, time = h.time })
                    end
                end
            end
            if replay.healEvents then
                for _, h in ipairs(replay.healEvents) do
                    if h.time and h.time >= deathTime - 10 and h.time <= deathTime + 2 then
                        table.insert(events, { type = "heal", source = h.source, spell = h.spell, amount = h.amount, time = h.time })
                    end
                end
            end

            if table.getn(events) > 0 then
                table.sort(events, function(a,b) return a.time > b.time end)
                for i = 1, math.min(table.getn(events), 50) do
                    local e = events[i]
                    local color = e.type == "damage" and "|cffff0000" or "|cff00ff00"
                    local prefix = e.type == "damage" and "-" or "+"
                    local rel = deathTime - e.time
                    if rel < 0 then rel = 0 end
                    local hitStr = ""
                    if e.type == "damage" and e.hitType and hitTypeLabels[e.hitType] then
                        hitStr = " " .. hitTypeLabels[e.hitType]
                    end
                    table.insert(lines, string.format("  %s - %s  %s%s%s%s (死亡前%.1f秒)", e.source, e.spell, color, prefix, e.amount, hitStr, rel))
                end
            else
                table.insert(lines, "  无死亡前10秒事件")
            end
            table.insert(lines, " ")
        end
    end
    return lines
end

-- 将单位名转换为带职业颜色的显示串（返回带 |c 前缀的完整颜色串）
local function classColorString(classToken, name)
    if classToken and classes[classToken] and RAID_CLASS_COLORS[classToken] then
        local c = RAID_CLASS_COLORS[classToken]
        local hex = string.format("%02x%02x%02x", math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255))
        return "|cff" .. hex .. name .. "|r"
    end
    return name
end

-- ============================================================================
-- 11. 进度条鼠标悬停显示详细数据（工具提示）
-- ============================================================================
-- 11. 进度条鼠标悬停显示详细数据（工具提示）
-- ============================================================================

-- 计算单位秒伤（每秒伤害/治疗），根据配置 use_total_cbt_for_dps 决定用总战斗时间(DPS)还是活跃时间(EDPS)。
-- @return persec, epersec, overpersec, isDPS（true=DPS用总战斗时间，false=EDPS用活跃时间）
local function getPersecData(unitData, wid, effectiveViewId)
    local value = unitData._sum or 0
    local ctime = unitData._ctime or 1
    -- 计算总战斗时间：仅当勾选"用DPS替代EDPS"且为伤害类视图（1伤害/2DPS/9误伤/17无效伤害）时使用
    local isDPS = false
    local duration = 0
    if config.use_total_cbt_for_dps == 1
        and (effectiveViewId == 1 or effectiveViewId == 2 or effectiveViewId == 9 or effectiveViewId == 17) then
        local segType = config[wid].segment or 1
        local curView = config[wid].view
        if curView == 12 then
            local fights = ShaguDPS.boss_fights
            local idx = ShaguDPS.current_boss_index
            if fights and idx and fights[idx] then
                duration = fights[idx].duration or 0
            elseif ShaguDPS.pendingBossRecord then
                duration = data.last_fight_duration or 0
            end
        elseif curView == 15 then
            duration = (data.total_combat_time or 0) - (ShaguDPS.small_fight_total_time or 0)
        elseif curView == 23 then
            local fights = ShaguDPS.recent_fights
            local idx = config[wid].recent_fight_index or ShaguDPS.current_recent_index
            if fights and idx and fights[idx] then
                duration = fights[idx].duration or 0
            end
        else
            if segType == 0 then
                duration = data.total_combat_time or 0
            elseif segType == 2 then
                duration = ShaguDPS.small_fight_total_time or 0
            else
                if ShaguDPS.Combat() and data.combat_start_time > 0 then
                    duration = GetTime() - data.combat_start_time
                else
                    duration = data.last_fight_duration or 0
                end
            end
        end
        if duration and duration > 0 then
            isDPS = true
        end
    end
    local denom = isDPS and duration or ctime
    if denom <= 0 then denom = 1 end
    local persec = round(value / denom, 1)
    local epersec = 0
    local overpersec = 0
    if unitData._esum then
        local evalue = unitData._esum or 0
        epersec = round(evalue / denom, 1)
        local over = value - evalue
        overpersec = round(over / denom, 1)
    end
    return persec, epersec, overpersec, isDPS
end

local function barTooltipShow()
    local MAX_TOOLTIP_LINES = 30
    local lineCount = 0
    local hintAdded = false
    local function TooltipAddLine(text, r, g, b)
        if lineCount >= MAX_TOOLTIP_LINES - 1 then
            if not hintAdded then
                GameTooltip:AddLine("|cffff4040！！详情请点击查看！！|r")
                hintAdded = true
            end
            lineCount = lineCount + 1
            return
        end
        lineCount = lineCount + 1
        return GameTooltip:AddLine(text, r, g, b)
    end
    local function TooltipAddDoubleLine(left, right, r, g, b)
        if lineCount >= MAX_TOOLTIP_LINES - 1 then
            if not hintAdded then
                GameTooltip:AddLine("|cffff4040！！详情请点击查看！！|r")
                hintAdded = true
            end
            lineCount = lineCount + 1
            return
        end
        lineCount = lineCount + 1
        return GameTooltip:AddDoubleLine(left, right, r, g, b)
    end

    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    local segment = this.parent.segment
    local wid = this.parent:GetID()
    local unitData = segment[this.unit]
    if not unitData then return end

    -- 光环覆盖率视图
    if this.parent.isBuffCoverageView then
        local segType = config[wid] and config[wid].segment or 1
        local totalTimeOverride = nil
        if config[wid].view == 15 then
            local totalBossTime = (data.total_combat_time or 0) - (ShaguDPS.small_fight_total_time or 0)
            totalTimeOverride = totalBossTime > 0 and totalBossTime or 1
        elseif segType == 2 then
            totalTimeOverride = ShaguDPS.small_fight_total_time or 1
        end
        local details = GetBuffCoverageDetails(unitData, this.unit, segType, totalTimeOverride)
        TooltipAddLine(this.title .. ":")
        TooltipAddDoubleLine("|cffffffff总战斗时间", string.format("|cffffffff%.1f秒", details.totalTime))
        TooltipAddDoubleLine("|cffffffffBuff数量", "|cffffffff" .. details.buffCount)
        TooltipAddDoubleLine("|cffffffffDebuff数量", "|cffffffff" .. details.debuffCount)
        TooltipAddDoubleLine("|cffffffff总光环数量", "|cffffffff" .. details.totalCount)
        TooltipAddLine(string.format("|cffffffff平均覆盖率: |cff00ff00Buff - %.1f%%|r |cffff4444Debuff - %.1f%%|r", details.buffAvgCov, details.debuffAvgCov))
        TooltipAddLine(" ")

        if details.buffCount > 0 then
            TooltipAddLine("|cff88ccffBuff 覆盖率详情|r")
            table.sort(details.buffList, function(a,b) return a.pct > b.pct end)
            for _, buff in ipairs(details.buffList) do
                local timeStr = string.format("%.1fs", buff.time)
                local pctStr = string.format("%.1f%%", buff.pct)
                TooltipAddDoubleLine("|cffffffff" .. buff.name, string.format("|cffffffff%s (%s)", pctStr, timeStr))
            end
            TooltipAddLine(" ")
        end

        if details.debuffCount > 0 then
            TooltipAddLine("|cffff8888Debuff 覆盖率详情|r")
            table.sort(details.debuffList, function(a,b) return a.pct > b.pct end)
            for _, debuff in ipairs(details.debuffList) do
                local timeStr = string.format("%.1fs", debuff.time)
                local pctStr = string.format("%.1f%%", debuff.pct)
                TooltipAddDoubleLine("|cffffffff" .. debuff.name, string.format("|cffffffff%s (%s)", pctStr, timeStr))
            end
        end

        GameTooltip:Show()
        return
    end

    -- 易伤覆盖率视图
    if this.parent.isVulnCoverageView then
        local segType = config[wid] and config[wid].segment or 1
        local totalTimeOverride = nil
        if config[wid].view == 15 then
            local totalBossTime = (data.total_combat_time or 0) - (ShaguDPS.small_fight_total_time or 0)
            totalTimeOverride = totalBossTime > 0 and totalBossTime or 1
        elseif segType == 2 then
            totalTimeOverride = ShaguDPS.small_fight_total_time or 1
        end
        local details = GetVulnerabilityCoverageDetails(unitData, totalTimeOverride, segType, this.unit)
        TooltipAddLine(this.title .. ":")
        TooltipAddDoubleLine("|cffffffff总战斗时间", string.format("|cffffffff%.1f秒", details.totalTime))
        TooltipAddDoubleLine("|cffffffff易伤数量", "|cffffffff" .. details.totalCount)
        TooltipAddDoubleLine("|cffffffff平均覆盖率", "|cffffff00" .. string.format("%.1f%%", details.avgCov))
        TooltipAddLine(" ")
        if details.totalCount > 0 then
            TooltipAddLine("|cff88ccff易伤覆盖率详情|r")
            for _, spell in ipairs(details.spellList) do
                TooltipAddDoubleLine("|cffffffff" .. spell.name, string.format("|cffffffff%.1f%% (%.1fs)", spell.pct, spell.time))
            end
        end
        GameTooltip:Show()
        return
    end

    -- 能量回复特殊提示
    if this.parent.isEnergizeView then
        TooltipAddLine(this.title .. ":")
        local total = unitData._sum or 0
        local persec = round(total / (unitData._ctime or 1), 1)
        TooltipAddDoubleLine("|cffffffff总回复量", "|cffffffff" .. total)
        TooltipAddDoubleLine("|cffffffff每秒回复", "|cffffffff" .. persec)
        TooltipAddLine(" ")
        if unitData._by_type then
            TooltipAddLine("能量类型细分:")
            for pt, amt in pairs(unitData._by_type) do
                local pname = POWER_NAMES[pt] or "未知"
                TooltipAddDoubleLine("|cffffffff" .. pname, "|cffffffff" .. amt)
            end
        end
        TooltipAddLine(" ")
        TooltipAddLine("技能详情:")
        for attack, amount in spairs(unitData, sort_algorithms.single_spell) do
            if attack and not internals[attack] and attack ~= "_by_type" then
                local percent = amount == 0 and 0 or round(amount / total * 100, 1)
                TooltipAddDoubleLine("|cffffffff" .. attack, string.format("|cffffffff %s (%.1f%%)", amount, percent))
            end
        end
        GameTooltip:Show()
        return
    end

    -- 受到治疗
    if this.parent.isHealTakenView then
        TooltipAddLine("|cffffcc00" .. this.title .. "|r:")
        TooltipAddDoubleLine("总受到治疗", "|cffffffff" .. (unitData._sum or 0))
        TooltipAddDoubleLine("有效治疗", "|cff00ff00" .. (unitData._esum or 0))
        TooltipAddDoubleLine("过量治疗", "|cffcc8888" .. (unitData._sum - unitData._esum))
        TooltipAddLine(" ")
        TooltipAddLine("治疗来源 (按总量降序):")
        local sources = {}
        for k, v in pairs(unitData) do
            if type(v) == "table" and k ~= "_sum" and k ~= "_esum" and k ~= "_history" then
                table.insert(sources, { name = k, total = v._sum or 0, effective = v._esum or 0 })
            end
        end
        table.sort(sources, function(a,b) return a.total > b.total end)
        for _, src in ipairs(sources) do
            TooltipAddDoubleLine(src.name, string.format("|cffffffff总:%s|r |cff00ff00有效:%s|r", src.total, src.effective))
        end
        GameTooltip:Show()
        return
    end

    -- 死亡次数
    if type(unitData) == "number" then
        TooltipAddLine(this.title .. ":")
        TooltipAddDoubleLine("|cffffffff死亡次数", "|cffffffff" .. unitData)
        TooltipAddLine(" ")
        local segType = config[wid] and config[wid].segment or 1
        local bossFight = nil
        if config[wid].view == 12 or config[wid].view == 23 then
            if config[wid].view == 12 then
                local fights = ShaguDPS.boss_fights
                local idx = ShaguDPS.current_boss_index
                if fights and idx and fights[idx] then
                    bossFight = fights[idx]
                elseif ShaguDPS.pendingBossRecord then
                    bossFight = { name = ShaguDPS.pendingBossRecord.name, death_replays = data.death_replays }
                end
            elseif config[wid].view == 23 then
                local fights = ShaguDPS.recent_fights
                local idx = config[wid].recent_fight_index or ShaguDPS.current_recent_index
                if fights and idx and fights[idx] then
                    bossFight = fights[idx]
                end
            end
        end
        local replayLines = GetDeathReplayLines(this.unit, segType, bossFight)
        if replayLines and table.getn(replayLines) > 0 then
            for _, line in ipairs(replayLines) do
                TooltipAddLine(line)
            end
        else
            TooltipAddLine("|cffff8888无死亡回放记录|r")
        end
        GameTooltip:Show()
        return
    end

    -- 打断视图
    if this.parent.isInterruptView then
        TooltipAddLine(this.title .. " (打断):")
        TooltipAddDoubleLine("|cffffffff总打断次数", "|cffffffff" .. (unitData._total or 0))
        TooltipAddLine(" ")
        TooltipAddLine("打断详情:")
        for ability, abilityData in pairs(unitData) do
            if ability ~= "_total" and type(abilityData) == "table" then
                TooltipAddLine("|cff00ffff" .. ability .. "|r (总计 " .. (abilityData._total or 0) .. "):")
                for victimName, interruptedSpells in pairs(abilityData) do
                    if victimName ~= "_total" then
                        for interruptedSpell, count in pairs(interruptedSpells) do
                            TooltipAddDoubleLine("  " .. victimName .. " - " .. interruptedSpell, "|cffffffff" .. count)
                        end
                    end
                end
            end
        end
        GameTooltip:Show()
        return
    end

    -- 敌人承伤
    if this.parent.isEnemyTakenView then
        TooltipAddLine(this.title .. ":")
        TooltipAddDoubleLine("|cffffffff总有效承伤", "|cffffffff" .. (unitData._sum or 0))
        TooltipAddDoubleLine("|cffcc8888溢出伤害", "|cffffffff" .. (unitData._overkill or 0))
        TooltipAddLine(" ")
        TooltipAddLine("伤害来源（按有效伤害排序）:")
        local sources = {}
        for source, sdata in pairs(unitData) do
            if source ~= "_sum" and source ~= "_overkill" and type(sdata) == "table" then
                table.insert(sources, {
                    name = source,
                    sum = sdata._sum or 0,
                    over = sdata._overkill or 0,
                })
            end
        end
        table.sort(sources, function(a,b) return a.sum > b.sum end)
        for _, src in ipairs(sources) do
            local line = string.format("|cffffffff%s|cffffffff %s", src.name, src.sum)
            if src.over > 0 then
                line = line .. string.format(" |cffff8888(+%s)|r", src.over)
            end
            TooltipAddLine(line)
        end
        GameTooltip:Show()
        return
    end

    -- 无效伤害
    if unitData._by_target then
        TooltipAddLine(this.title .. " (无效伤害):")
        TooltipAddDoubleLine("|cffffffff总伤害", "|cffffffff" .. (unitData._sum or 0))
        TooltipAddLine(" ")
        TooltipAddLine("对每个目标的伤害:")
        for target, tdata in pairs(unitData._by_target) do
            TooltipAddLine("|cff00ffff" .. target .. "|r:")
            for spell, amount in pairs(tdata) do
                if spell ~= "_sum" and string.sub(spell, 1, 1) ~= "_" then
                    local dmg = tdata[spell]
                    local cnt = tdata["_count_"..spell] or 0
                    local suffix = "施法"
                    if string.find(spell, "%(DoT%)") then
                        suffix = "跳"
                    end
                    TooltipAddDoubleLine("  "..spell, string.format("%s |cffaaaaaa(×%d%s)|r", dmg, cnt, suffix))
                end
            end
        end
        GameTooltip:Show()
        return
    end

    -- 仇恨
    if unitData.threat then
        TooltipAddLine(this.title .. ":")
        TooltipAddDoubleLine("|cffffffff威胁值", "|cffffffff" .. (unitData.threat or 0))
        TooltipAddDoubleLine("|cffffffffTPS", "|cffffffff" .. (unitData.tps or 0))
        TooltipAddDoubleLine("|cffffffff百分比", "|cffffffff" .. (unitData.perc or 0) .. "%")
        if unitData.tank then TooltipAddLine("|cff00ff00坦克", 1, 1, 1) end
        GameTooltip:Show()
        return
    end

    -- 承受伤害
    if unitData._history then
        TooltipAddLine(this.title .. ":")
        TooltipAddDoubleLine("|cffffffff总承受伤害", "|cffffffff" .. (unitData._sum or 0))
        TooltipAddLine(" ")
        TooltipAddLine("伤害详情 (按时间倒序):")
        local sorted = {}
        for _, h in ipairs(unitData._history) do table.insert(sorted, h) end
        table.sort(sorted, function(a, b) return a.time > b.time end)
        for _, h in ipairs(sorted) do
            TooltipAddDoubleLine("|cffffffff" .. h.source .. " - " .. h.spell, string.format("|cffffffff 合计 %s (最近 %s)", h.total, h.last))
        end
        GameTooltip:Show()
        return
    end

    -- 技能施放（包含分层显示）
    if unitData._total then
        local currentView = config[wid] and config[wid].view

        -- 驱散
        if unitData._offensive ~= nil then
            TooltipAddLine(this.title .. ":")
            TooltipAddDoubleLine("|cffffffff总驱散", "|cffffffff" .. (unitData._total or 0))
            TooltipAddDoubleLine("|cff88ff88进攻驱散", "|cffffffff" .. (unitData._offensive or 0))
            TooltipAddDoubleLine("|cff88aaff防御驱散", "|cffffffff" .. (unitData._defensive or 0))
            local wrongTotal = 0
            for targetName, spells in pairs(unitData) do
                if targetName == "错误驱散" and type(spells) == "table" then
                    for tgt, debuffs in pairs(spells) do
                        for _, count in pairs(debuffs) do
                            wrongTotal = wrongTotal + count
                        end
                    end
                end
            end
            if wrongTotal > 0 then
                TooltipAddDoubleLine("|cffff4444错误驱散", "|cffff4444" .. wrongTotal)
            end
            TooltipAddLine(" ")
            TooltipAddLine("详情:")
            if unitData["错误驱散"] and type(unitData["错误驱散"]) == "table" then
                for tgt, debuffs in pairs(unitData["错误驱散"]) do
                    TooltipAddLine("|cffff4444错误驱散 " .. tgt .. "|r:")
                    for debuffName, count in pairs(debuffs) do
                        TooltipAddDoubleLine("  " .. debuffName, "|cffffffff" .. count)
                    end
                end
            end
            for targetName, spells in pairs(unitData) do
                if type(spells) == "table" and targetName ~= "_total" and targetName ~= "_offensive" and targetName ~= "_defensive" and targetName ~= "错误驱散" then
                    for spellName, count in pairs(spells) do
                        TooltipAddDoubleLine("|cffffffff" .. targetName .. " - " .. spellName, "|cffffffff" .. count)
                    end
                end
            end
            GameTooltip:Show()
            return
        end

        -- 复活
        if this.parent.isReviveView then
            TooltipAddLine(this.title .. ":")
            TooltipAddDoubleLine("|cffffffff总复活次数", "|cffffffff" .. unitData._total)
            TooltipAddLine(" ")
            TooltipAddLine("复活目标:")
            local targets = {}
            for target, count in pairs(unitData) do
                if target ~= "_total" then
                    table.insert(targets, {name=target, count=count})
                end
            end
            table.sort(targets, function(a,b) return a.count > b.count end)
            for _, t in ipairs(targets) do
                TooltipAddDoubleLine("|cffffffff" .. t.name, "|cffffffff" .. t.count)
            end
            GameTooltip:Show()
            return
        end

        -- 误伤
        local isFriendlyFire = false
        for k, v in pairs(unitData) do
            if k ~= "_total" and type(v) == "table" then
                isFriendlyFire = true
                break
            end
        end
        if isFriendlyFire then
            TooltipAddLine(this.title .. ":")
            TooltipAddDoubleLine("|cffffffff总误伤", "|cffffffff" .. unitData._total)
            TooltipAddLine(" ")
            TooltipAddLine("详情:")
            for targetName, spells in pairs(unitData) do
                if targetName ~= "_total" and type(spells) == "table" then
                    local targetTotal = 0
                    for _, dmg in pairs(spells) do targetTotal = targetTotal + dmg end
                    TooltipAddDoubleLine("|cffffffff" .. targetName, "|cffffffff" .. targetTotal)
                    for spellName, damage in pairs(spells) do
                        TooltipAddDoubleLine("  " .. spellName, damage)
                    end
                end
            end
            GameTooltip:Show()
            return
        end

        -- 技能施放视图 (view == 8) 优先使用分层详情
        if currentView == 8 then
            local seg = config[wid].segment
            local detailsData
            if seg == 0 then
                detailsData = data.spellcast_details[0]
            elseif seg == 2 then
                detailsData = data.small_fight.spellcast_details
            else
                detailsData = ShaguDPS.cached_current_spellcast_details or data.spellcast_details[1]
            end
            local unitDetails = detailsData and detailsData[this.unit]
            if unitDetails and unitDetails._total then
                TooltipAddLine(this.title .. ":")
                TooltipAddDoubleLine("|cffffffff总施放次数", "|cffffffff" .. unitDetails._total)

                local sourceTypes = { "player", "pet", "item" }
                local sourceLabels = { player = "来自角色", pet = "来自宠物/召唤物", item = "来自道具" }
                local targetTypes = { "enemy", "friendly", "self", "none" }
                local targetLabels = { enemy = "目标：敌对", friendly = "目标：友方", self = "目标：自身", none = "无目标" }

                for _, st in ipairs(sourceTypes) do
                    local sourceData = unitDetails[st]
                    if sourceData and next(sourceData) then
                        TooltipAddLine(" ")
                        TooltipAddLine("|cff88ccff" .. sourceLabels[st] .. "|r")
                        for _, tt in ipairs(targetTypes) do
                            local targetData = sourceData[tt]
                            if targetData and next(targetData) then
                                TooltipAddLine("  |cffffffff" .. targetLabels[tt] .. "|r")
                                local spells = {}
                                for spell, count in pairs(targetData) do
                                    table.insert(spells, {name=spell, count=count})
                                end
                                table.sort(spells, function(a,b) return a.count > b.count end)
                                for _, spell in ipairs(spells) do
                                    TooltipAddDoubleLine("    " .. spell.name, "|cffffffff" .. spell.count)
                                end
                            end
                        end
                    end
                end
                GameTooltip:Show()
                return
            end
        end

        -- 回退：扁平显示
        TooltipAddLine(this.title .. ":")
        TooltipAddDoubleLine("|cffffffff总计", "|cffffffff" .. unitData._total)
        TooltipAddLine(" ")
        TooltipAddLine("详情:")
        local spells = {}
        for spellName, count in pairs(unitData) do
            if spellName ~= "_total" then table.insert(spells, {name=spellName, count=count}) end
        end
        table.sort(spells, function(a,b) return a.count > b.count end)
        for _, spell in ipairs(spells) do
            TooltipAddDoubleLine("|cffffffff" .. spell.name, "|cffffffff" .. spell.count)
        end
        GameTooltip:Show()
        return
    end

    -- 伤害/治疗
    if unitData._sum then
        local value = unitData._sum
        -- 确定当前有效视图（BOSS/汇总/近期战斗时映射到具体统计类型）
        local wid = this.parent:GetID()
        local segType = config[wid].segment or 1
        local curView = config[wid].view
        local effectiveViewId = curView
        if curView == 12 or curView == 15 or curView == 23 then
            local bossStatMap = bossStatMapFull
            local st = config[wid].boss_stat_view or 1
            effectiveViewId = bossStatMap[st] or 1
        end
        -- 秒伤按配置切换 DPS(总战斗时间) / EDPS(活跃时间)
        local persec, epersec, overpersec, isDPS = getPersecData(unitData, wid, effectiveViewId)
        local evalue, over
        if unitData._esum then
            evalue = unitData._esum
            over = value - evalue
        end
        TooltipAddLine(this.title .. ":")

        -- 战斗时间显示（针对伤害/DPS/治疗/HPS/有效治疗/过量治疗）
        if effectiveViewId >= 1 and effectiveViewId <= 6 then
            local duration = nil
            if curView == 12 then
                local fights = ShaguDPS.boss_fights
                local idx = ShaguDPS.current_boss_index
                if fights and idx and fights[idx] then
                    duration = fights[idx].duration
                elseif ShaguDPS.pendingBossRecord then
                    duration = data.last_fight_duration or 0
                end
            elseif curView == 15 then
                duration = (data.total_combat_time or 0) - (ShaguDPS.small_fight_total_time or 0)
            elseif curView == 23 then
                local fights = ShaguDPS.recent_fights
                local idx = config[wid].recent_fight_index or ShaguDPS.current_recent_index
                if fights and idx and fights[idx] then
                    duration = fights[idx].duration
                end
            else
                if segType == 0 then
                    duration = data.total_combat_time or 0
                elseif segType == 2 then
                    duration = ShaguDPS.small_fight_total_time or 0
                else
                    if ShaguDPS.Combat() and data.combat_start_time > 0 then
                        duration = GetTime() - data.combat_start_time
                    else
                        duration = data.last_fight_duration or 0
                    end
                end
            end
            if duration and duration > 0 then
                local durStr = formatDuration(duration)
                if durStr then
                    TooltipAddDoubleLine("|cffffffff战斗时间", "|cffffffff" .. durStr)
                end
            end
        end

        local rateLabel = isDPS and "DPS" or "EDPS"
        local isHealView = effectiveViewId >= 3 and effectiveViewId <= 6
        TooltipAddDoubleLine("|cffffffff总量", "|cffffffff" .. value)
        TooltipAddDoubleLine("|cffffffff" .. rateLabel, "|cffffffff" .. persec)
        if unitData._esum then
            TooltipAddDoubleLine("|cffffffff有效", "|cffffffff" .. evalue)
            TooltipAddDoubleLine("|cffcc8888过量", "|cffffffff" .. over)
            if not isHealView then
                TooltipAddDoubleLine("|cffffffff有效/" .. rateLabel, "|cffffffff" .. epersec)
                TooltipAddDoubleLine("|cffcc8888过量/" .. rateLabel, "|cffffffff" .. overpersec)
            end
        end
        TooltipAddLine(" ")
        TooltipAddLine("详情:")

        local view = config[wid].view
        local dotticksSeg = nil
        local hitBreakdownSeg = nil

        if view == 12 then
            local fights = ShaguDPS.boss_fights
            local idx = ShaguDPS.current_boss_index
            if fights and idx and fights[idx] then
                dotticksSeg = fights[idx].dot_ticks
                hitBreakdownSeg = fights[idx].hit_breakdown
            elseif ShaguDPS.pendingBossRecord then
                dotticksSeg = data.dot_ticks[1]
                hitBreakdownSeg = data.hit_breakdown[1]
            end
        elseif view == 15 then
            local bossDotTicks = GetBossSummaryDataForType("dot_ticks")
            local bossHitBreakdown = GetBossSummaryDataForType("hit_breakdown")
            if bossDotTicks then
                dotticksSeg = bossDotTicks
            end
            if bossHitBreakdown then
                hitBreakdownSeg = bossHitBreakdown
            end
        elseif view == 23 then
            local fights = ShaguDPS.recent_fights or {}
            local idx = config[wid].recent_fight_index or ShaguDPS.current_recent_index
            if fights and idx and fights[idx] then
                dotticksSeg = fights[idx].dot_ticks
                hitBreakdownSeg = fights[idx].hit_breakdown
            end
        else
            local seg = config[wid].segment
            if seg == 0 then
                dotticksSeg = data.dot_ticks[0]
                hitBreakdownSeg = data.hit_breakdown[0]
            elseif seg == 2 then
                dotticksSeg = data.small_fight.dot_ticks
                hitBreakdownSeg = data.small_fight.hit_breakdown or {}
            else
                dotticksSeg = ShaguDPS.cached_current_dot_ticks or data.dot_ticks[1]
                hitBreakdownSeg = ShaguDPS.cached_current_hit_breakdown or data.hit_breakdown[1]
            end
        end

        local dotticks = dotticksSeg and dotticksSeg[this.unit]
        local hitBreakdowns = hitBreakdownSeg and hitBreakdownSeg[this.unit]

        for attack, damage in spairs(unitData, sort_algorithms.single_spell) do
            if attack and not internals[attack] then
                local percent = (damage == 0 or unitData._sum == 0) and 0 or round(damage / unitData._sum * 100, 1)
                local isDoT = string.find(attack, "%(DoT%)") ~= nil
                local baseAttack = attack
                if isDoT then
                    baseAttack = string.gsub(attack, " %(DoT%)", "")
                end
                local suppressCast = false
                if isDoT and unitData[baseAttack] ~= nil then
                    suppressCast = true
                end
                local countStr = ""
                if not suppressCast then
                    local hb = hitBreakdowns and (hitBreakdowns[attack] or hitBreakdowns[baseAttack])
                    local count = hb and (
                        (hb.crit or 0) + (hb.glancing or 0) + (hb.dodge or 0) + (hb.parry or 0)
                        + (hb.block or 0) + (hb.resist or 0) + (hb.miss or 0)
                        + (hb.normal or 0) + (hb.crushing or 0)
                    ) or 0
                    if count > 0 then
                        countStr = " |cffaaaaaa(×" .. count .. "施放)|r"
                    end
                end
                local ticks = dotticks and dotticks[attack] or 0
                local tickStr = ticks > 0 and (" |cffaaaaaa(×" .. ticks .. "跳)|r") or ""
                local suffix = isDoT and (tickStr .. countStr) or (countStr .. tickStr)
                if unitData._effective and unitData._effective[attack] then
                    local effective = unitData._effective[attack]
                    local str = string.format("|cffcc8888+%s|cffffffff %s (%.1f%%)", damage - effective, effective, (unitData._esum == 0 or effective == 0) and 0 or round(effective / unitData._esum * 100, 1))
                    TooltipAddDoubleLine("|cffffffff" .. attack, str .. suffix)
                else
                    local overkill = unitData._overkill_by_spell and unitData._overkill_by_spell[attack] or 0
                    local str
                    if overkill > 0 then
                        str = string.format("|cffffffff%s|cffff8888 (+%s)|r (%.1f%%)", damage, overkill, percent)
                    else
                        str = string.format("|cffffffff %s (%.1f%%)", damage, percent)
                    end
                    TooltipAddDoubleLine("|cffffffff" .. attack, str .. suffix)
                end
            end
        end

        -- 对每个目标的伤害量
        local isDamageStat = false
        if view == 12 or view == 15 or view == 23 then
            local bossStatMap = bossStatMapFull
            local s = config[wid].boss_stat_view or 1
            local mapped = bossStatMap[s] or 1
            if mapped == 1 or mapped == 2 then
                isDamageStat = true
            end
        else
            if view == 1 or view == 2 then
                isDamageStat = true
            end
        end
        if isDamageStat then
            local enemyTakenData = nil
            if view == 12 then
                local fights = ShaguDPS.boss_fights
                local idx = ShaguDPS.current_boss_index
                if fights and idx and fights[idx] then
                    enemyTakenData = fights[idx].enemy_damage_taken
                elseif ShaguDPS.pendingBossRecord then
                    enemyTakenData = data.enemy_damage_taken[1]
                end
            elseif view == 15 then
                enemyTakenData = GetBossSummaryData(19)
            elseif view == 23 then
                local fights = ShaguDPS.recent_fights or {}
                local idx = config[wid].recent_fight_index or ShaguDPS.current_recent_index
                if fights and idx and fights[idx] then
                    enemyTakenData = fights[idx].enemy_damage_taken
                end
            else
                local segType = config[wid].segment or 1
                if segType == 0 then
                    enemyTakenData = data.enemy_damage_taken[0]
                elseif segType == 2 then
                    enemyTakenData = data.small_fight.enemy_damage_taken
                else
                    enemyTakenData = ShaguDPS.cached_current_enemy_damage_taken or data.enemy_damage_taken[1]
                end
            end
            if enemyTakenData then
                local targetDetails = {}
                for targetName, targetData in pairs(enemyTakenData) do
                    if type(targetData) == "table" then
                        local srcData = targetData[this.unit]
                        if srcData and type(srcData) == "table" then
                            local effective = srcData._sum or 0
                            local overkill = srcData._overkill or 0
                            local total = effective + overkill
                            if total > 0 then
                                table.insert(targetDetails, {
                                    name = targetName,
                                    total = total,
                                    effective = effective,
                                    overkill = overkill,
                                })
                            end
                        end
                    end
                end
                if table.getn(targetDetails) > 0 then
                    TooltipAddLine(" ")
                    TooltipAddLine("|cff88ccff对每个目标的伤害量|r")
                    table.sort(targetDetails, function(a, b) return a.total > b.total end)
                    for idx, tInfo in ipairs(targetDetails) do
                        if tInfo.overkill > 0 then
                            TooltipAddDoubleLine(
                                "|cffffffff" .. idx .. ". " .. tInfo.name,
                                string.format("|cffffffff%s|r |cffff8888(+%s)|r", tInfo.effective, tInfo.overkill)
                            )
                        else
                            TooltipAddDoubleLine(
                                "|cffffffff" .. idx .. ". " .. tInfo.name,
                                "|cffffffff" .. tInfo.effective
                            )
                        end
                    end
                end
            end
        end

        -- 对每个目标的治疗量
        local segType = config[wid].segment or 1
        local currentView = config[wid].view
        local isHealStat = false
        if currentView == 12 or currentView == 15 or currentView == 23 then
            local bossStatMap = bossStatMapFull
            local s = config[wid].boss_stat_view or 1
            local mapped = bossStatMap[s] or 1
            if mapped == 3 or mapped == 4 or mapped == 5 or mapped == 6 then
                isHealStat = true
            end
        else
            if currentView == 3 or currentView == 4 or currentView == 5 or currentView == 6 then
                isHealStat = true
            end
        end
        if isHealStat then
            local healTakenData = nil
            if currentView == 12 then
                local fights = ShaguDPS.boss_fights
                local idx = ShaguDPS.current_boss_index
                if fights and idx and fights[idx] then
                    healTakenData = fights[idx].heal_taken
                elseif ShaguDPS.pendingBossRecord then
                    healTakenData = data.heal_taken[1]
                end
            elseif currentView == 15 then
                healTakenData = GetBossSummaryData(15)
            elseif currentView == 23 then
                local fights = ShaguDPS.recent_fights or {}
                local idx = config[wid].recent_fight_index or ShaguDPS.current_recent_index
                if fights and idx and fights[idx] then
                    healTakenData = fights[idx].heal_taken
                end
            else
                if segType == 0 then
                    healTakenData = data.heal_taken[0]
                elseif segType == 2 then
                    healTakenData = data.small_fight.heal_taken
                else
                    healTakenData = ShaguDPS.cached_current_heal_taken or data.heal_taken[1]
                end
            end
            if healTakenData then
                local targetDetails = {}
                for victimName, victimData in pairs(healTakenData) do
                    if type(victimData) == "table" then
                        local srcData = victimData[this.unit]
                        if srcData and type(srcData) == "table" then
                            local total = srcData._sum or 0
                            local effective = srcData._esum or 0
                            local overheal = total - effective
                            if total > 0 then
                                table.insert(targetDetails, {
                                    name = victimName,
                                    total = total,
                                    effective = effective,
                                    overheal = overheal,
                                })
                            end
                        end
                    end
                end
                if table.getn(targetDetails) > 0 then
                    TooltipAddLine(" ")
                    TooltipAddLine("|cff88ccff对每个目标的治疗量|r")
                    table.sort(targetDetails, function(a, b) return a.total > b.total end)
                    for idx, tInfo in ipairs(targetDetails) do
                        if unitData._esum and unitData._esum > 0 then
                            TooltipAddDoubleLine(
                                "|cffffffff" .. idx .. ". " .. tInfo.name,
                                string.format("|cffffffff总:%s|r |cff00ff00有效:%s|r |cffff4444过量:%s|r", tInfo.total, tInfo.effective, tInfo.overheal)
                            )
                        else
                            TooltipAddDoubleLine(
                                "|cffffffff" .. idx .. ". " .. tInfo.name,
                                "|cffffffff总:" .. tInfo.total
                            )
                        end
                    end
                end
            end
        end

        GameTooltip:Show()
        return
    end

    -- 破甲数据在"回退：扁平显示"分支处理（含 _total 的条目已被上方各分支吞掉）

    TooltipAddLine(this.title .. ":")
    TooltipAddLine("无法显示数据")
    GameTooltip:Show()
end

local function barTooltipHide() GameTooltip:Hide() end

-- ============================================================================
-- 12. 获取进度条的详细数据行（用于详情窗口）
-- ============================================================================

local function GetBarDetailLines(bar)
    local lines = {}
    local segment = bar.parent.segment
    local wid = bar.parent:GetID()
    local unitData = segment[bar.unit]
    if not unitData then
        lines = { "无数据" }
        return lines
    end

    -- 光环覆盖率视图
    if bar.parent.isBuffCoverageView then
        local segType = config[wid] and config[wid].segment or 1
        local totalTimeOverride = nil
        if config[wid].view == 15 then
            local totalBossTime = (data.total_combat_time or 0) - (ShaguDPS.small_fight_total_time or 0)
            totalTimeOverride = totalBossTime > 0 and totalBossTime or 1
        elseif segType == 2 then
            totalTimeOverride = ShaguDPS.small_fight_total_time or 1
        end
        local details = GetBuffCoverageDetails(unitData, bar.unit, segType, totalTimeOverride)
        table.insert(lines, bar.title .. ":")
        table.insert(lines, "|cffffffff总战斗时间: |cffffffff" .. string.format("%.1f秒", details.totalTime))
        table.insert(lines, "|cffffffffBuff数量: |cffffffff" .. details.buffCount)
        table.insert(lines, "|cffffffffDebuff数量: |cffffffff" .. details.debuffCount)
        table.insert(lines, "|cffffffff总光环数量: |cffffffff" .. details.totalCount)
        table.insert(lines, string.format("|cffffffff平均覆盖率: |cff00ff00Buff - %.1f%%|r |cffff4444Debuff - %.1f%%|r", details.buffAvgCov, details.debuffAvgCov))
        table.insert(lines, " ")

        if details.buffCount > 0 then
            table.insert(lines, "|cff88ccffBuff 覆盖率详情|r")
            table.sort(details.buffList, function(a,b) return a.pct > b.pct end)
            for _, buff in ipairs(details.buffList) do
                local timeStr = string.format("%.1fs", buff.time)
                local pctStr = string.format("%.1f%%", buff.pct)
                table.insert(lines, "|cffffffff" .. buff.name .. "  " .. pctStr .. " (" .. timeStr .. ")")
            end
            table.insert(lines, " ")
        end

        if details.debuffCount > 0 then
            table.insert(lines, "|cffff8888Debuff 覆盖率详情|r")
            table.sort(details.debuffList, function(a,b) return a.pct > b.pct end)
            for _, debuff in ipairs(details.debuffList) do
                local timeStr = string.format("%.1fs", debuff.time)
                local pctStr = string.format("%.1f%%", debuff.pct)
                table.insert(lines, "|cffffffff" .. debuff.name .. "  " .. pctStr .. " (" .. timeStr .. ")")
            end
        end

        return lines
    end

    -- 易伤覆盖率视图
    if bar.parent.isVulnCoverageView then
        local segType = config[wid] and config[wid].segment or 1
        local totalTimeOverride = nil
        if config[wid].view == 15 then
            local totalBossTime = (data.total_combat_time or 0) - (ShaguDPS.small_fight_total_time or 0)
            totalTimeOverride = totalBossTime > 0 and totalBossTime or 1
        elseif segType == 2 then
            totalTimeOverride = ShaguDPS.small_fight_total_time or 1
        end
        local details = GetVulnerabilityCoverageDetails(unitData, totalTimeOverride, segType, bar.unit)
        table.insert(lines, bar.title .. ":")
        table.insert(lines, "|cffffffff总战斗时间: |cffffffff" .. string.format("%.1f秒", details.totalTime))
        table.insert(lines, "|cffffffff易伤数量: |cffffffff" .. details.totalCount)
        table.insert(lines, "|cffffffff平均覆盖率: |cffffff00" .. string.format("%.1f%%", details.avgCov))
        table.insert(lines, " ")
        if details.totalCount > 0 then
            table.insert(lines, "|cff88ccff易伤覆盖率详情|r")
            for _, spell in ipairs(details.spellList) do
                table.insert(lines, "|cffffffff" .. spell.name .. "  " .. string.format("%.1f%% (%.1fs)", spell.pct, spell.time))
            end
        end
        return lines
    end

    -- 能量回复
    if bar.parent.isEnergizeView then
        table.insert(lines, bar.title .. ":")
        local total = unitData._sum or 0
        local persec = round(total / (unitData._ctime or 1), 1)
        table.insert(lines, "|cffffffff总回复量: |cffffffff" .. total)
        table.insert(lines, "|cffffffff每秒回复: |cffffffff" .. persec)
        table.insert(lines, " ")
        if unitData._by_type then
            table.insert(lines, "能量类型细分:")
            for pt, amt in pairs(unitData._by_type) do
                local pname = POWER_NAMES[pt] or "未知"
                table.insert(lines, "|cffffffff" .. pname .. ": |cffffffff" .. amt)
            end
        end
        table.insert(lines, " ")
        table.insert(lines, "技能详情:")
        for attack, amount in spairs(unitData, sort_algorithms.single_spell) do
            if attack and not internals[attack] and attack ~= "_by_type" then
                local percent = amount == 0 and 0 or round(amount / total * 100, 1)
                table.insert(lines, "|cffffffff" .. attack .. "  |cffffffff" .. amount .. " (" .. percent .. "%)")
            end
        end
        return lines
    end

    -- 受到治疗
    if bar.parent.isHealTakenView then
        table.insert(lines, "|cffffcc00" .. bar.title .. "|r:")
        table.insert(lines, "总受到治疗: |cffffffff" .. (unitData._sum or 0))
        table.insert(lines, "有效治疗: |cff00ff00" .. (unitData._esum or 0))
        table.insert(lines, "过量治疗: |cffcc8888" .. (unitData._sum - unitData._esum))
        table.insert(lines, " ")
        table.insert(lines, "治疗来源 (按总量降序):")
        local sources = {}
        for k, v in pairs(unitData) do
            if type(v) == "table" and k ~= "_sum" and k ~= "_esum" and k ~= "_history" then
                table.insert(sources, { name = k, total = v._sum or 0, effective = v._esum or 0 })
            end
        end
        table.sort(sources, function(a,b) return a.total > b.total end)
        for _, src in ipairs(sources) do
            table.insert(lines, "|cffffffff" .. src.name .. "  总:" .. src.total .. "  有效:" .. src.effective)
        end
        return lines
    end

    -- 死亡次数
    if type(unitData) == "number" then
        table.insert(lines, bar.title .. ":")
        table.insert(lines, "|cffffffff死亡次数: |cffffffff" .. unitData)
        table.insert(lines, " ")
        local segType = config[wid] and config[wid].segment or 1
        local bossFight = nil
        if config[wid].view == 12 or config[wid].view == 23 then
            if config[wid].view == 12 then
                local fights = ShaguDPS.boss_fights
                local idx = ShaguDPS.current_boss_index
                if fights and idx and fights[idx] then
                    bossFight = fights[idx]
                elseif ShaguDPS.pendingBossRecord then
                    bossFight = { name = ShaguDPS.pendingBossRecord.name, death_replays = data.death_replays }
                end
            elseif config[wid].view == 23 then
                local fights = ShaguDPS.recent_fights
                local idx = config[wid].recent_fight_index or ShaguDPS.current_recent_index
                if fights and idx and fights[idx] then
                    bossFight = fights[idx]
                end
            end
        end
        local replayLines = GetDeathReplayLines(bar.unit, segType, bossFight)
        if replayLines and table.getn(replayLines) > 0 then
            for _, line in ipairs(replayLines) do
                table.insert(lines, line)
            end
        else
            table.insert(lines, "|cffff8888无死亡回放记录|r")
        end
        return lines
    end

    -- 打断视图
    if bar.parent.isInterruptView then
        table.insert(lines, bar.title .. " (打断):")
        table.insert(lines, "|cffffffff总打断次数: |cffffffff" .. (unitData._total or 0))
        table.insert(lines, " ")
        table.insert(lines, "打断详情:")
        for ability, abilityData in pairs(unitData) do
            if ability ~= "_total" and type(abilityData) == "table" then
                table.insert(lines, "|cff00ffff" .. ability .. "|r (总计 " .. (abilityData._total or 0) .. "):")
                for victimName, interruptedSpells in pairs(abilityData) do
                    if victimName ~= "_total" then
                        for interruptedSpell, count in pairs(interruptedSpells) do
                            table.insert(lines, "  " .. victimName .. " - " .. interruptedSpell .. ": |cffffffff" .. count)
                        end
                    end
                end
            end
        end
        return lines
    end

    -- 敌人承伤
    if bar.parent.isEnemyTakenView then
        table.insert(lines, bar.title .. ":")
        table.insert(lines, "|cffffffff总有效承伤: |cffffffff" .. (unitData._sum or 0))
        table.insert(lines, "|cffcc8888溢出伤害: |cffffffff" .. (unitData._overkill or 0))
        table.insert(lines, " ")
        table.insert(lines, "伤害来源（按有效伤害排序）:")
        local sources = {}
        for source, sdata in pairs(unitData) do
            if source ~= "_sum" and source ~= "_overkill" and type(sdata) == "table" then
                table.insert(sources, {
                    name = source,
                    sum = sdata._sum or 0,
                    over = sdata._overkill or 0,
                })
            end
        end
        table.sort(sources, function(a,b) return a.sum > b.sum end)
        for _, src in ipairs(sources) do
            local line = string.format("|cffffffff%s|cffffffff %s", src.name, src.sum)
            if src.over > 0 then
                line = line .. string.format(" |cffff8888(+%s)|r", src.over)
            end
            table.insert(lines, line)
        end
        return lines
    end

    -- 无效伤害
    if unitData._by_target then
        table.insert(lines, bar.title .. " (无效伤害):")
        table.insert(lines, "|cffffffff总伤害: |cffffffff" .. (unitData._sum or 0))
        table.insert(lines, " ")
        table.insert(lines, "对每个目标的伤害:")
        for target, tdata in pairs(unitData._by_target) do
            table.insert(lines, "|cff00ffff" .. target .. "|r:")
            for spell, amount in pairs(tdata) do
                if spell ~= "_sum" and string.sub(spell, 1, 1) ~= "_" then
                    local dmg = tdata[spell]
                    local cnt = tdata["_count_"..spell] or 0
                    local suffix = "施法"
                    if string.find(spell, "%(DoT%)") then
                        suffix = "跳"
                    end
                    table.insert(lines, "  " .. spell .. "  " .. dmg .. " |cffaaaaaa(×" .. cnt .. suffix .. ")|r")
                end
            end
        end
        return lines
    end

    -- 仇恨
    if unitData.threat then
        table.insert(lines, bar.title .. ":")
        table.insert(lines, "|cffffffff威胁值: |cffffffff" .. (unitData.threat or 0))
        table.insert(lines, "|cffffffffTPS: |cffffffff" .. (unitData.tps or 0))
        table.insert(lines, "|cffffffff百分比: |cffffffff" .. (unitData.perc or 0) .. "%")
        if unitData.tank then table.insert(lines, "|cff00ff00坦克|r") end
        return lines
    end

    -- 承受伤害
    if unitData._history then
        table.insert(lines, bar.title .. ":")
        table.insert(lines, "|cffffffff总承受伤害: |cffffffff" .. (unitData._sum or 0))
        table.insert(lines, " ")
        table.insert(lines, "伤害详情 (按时间倒序):")
        local sorted = {}
        for _, h in ipairs(unitData._history) do table.insert(sorted, h) end
        table.sort(sorted, function(a, b) return a.time > b.time end)
        for _, h in ipairs(sorted) do
            table.insert(lines, "|cffffffff" .. h.source .. " - " .. h.spell .. "  合计: " .. h.total .. " (最近: " .. h.last .. ")")
        end
        return lines
    end

    -- 技能施放（包含分层）
    if unitData._total then
        local currentView = config[wid] and config[wid].view

        -- 驱散
        if unitData._offensive ~= nil then
            table.insert(lines, bar.title .. ":")
            table.insert(lines, "|cffffffff总驱散: |cffffffff" .. (unitData._total or 0))
            table.insert(lines, "|cff88ff88进攻驱散: |cffffffff" .. (unitData._offensive or 0))
            table.insert(lines, "|cff88aaff防御驱散: |cffffffff" .. (unitData._defensive or 0))
            table.insert(lines, " ")
            table.insert(lines, "详情:")
            if unitData["错误驱散"] and type(unitData["错误驱散"]) == "table" then
                table.insert(lines, "|cffff4444错误驱散|r:")
                for tgt, debuffs in pairs(unitData["错误驱散"]) do
                    if type(debuffs) == "table" then
                        table.insert(lines, "  |cffffffff" .. tgt .. "|r:")
                        for debuffName, count in pairs(debuffs) do
                            if type(count) == "number" then
                                table.insert(lines, "    " .. debuffName .. ": |cffffffff" .. count)
                            end
                        end
                    end
                end
            end
            for targetName, spells in pairs(unitData) do
                if type(spells) == "table" and targetName ~= "_total" and targetName ~= "_offensive" and targetName ~= "_defensive" and targetName ~= "错误驱散" then
                    for spellName, count in pairs(spells) do
                        if type(count) == "number" then
                            table.insert(lines, "|cffffffff" .. targetName .. " - " .. spellName .. ": |cffffffff" .. count)
                        end
                    end
                end
            end
            return lines
        end

        -- 复活
        if bar.parent.isReviveView then
            table.insert(lines, bar.title .. ":")
            table.insert(lines, "|cffffffff总复活次数: |cffffffff" .. unitData._total)
            table.insert(lines, " ")
            table.insert(lines, "复活目标:")
            local targets = {}
            for target, count in pairs(unitData) do
                if target ~= "_total" then
                    table.insert(targets, {name=target, count=count})
                end
            end
            table.sort(targets, function(a,b) return a.count > b.count end)
            for _, t in ipairs(targets) do
                table.insert(lines, "|cffffffff" .. t.name .. ": |cffffffff" .. t.count)
            end
            return lines
        end

        -- 误伤
        local isFriendlyFire = false
        for k, v in pairs(unitData) do
            if k ~= "_total" and type(v) == "table" then
                isFriendlyFire = true
                break
            end
        end
        if isFriendlyFire then
            table.insert(lines, bar.title .. ":")
            table.insert(lines, "|cffffffff总误伤: |cffffffff" .. unitData._total)
            table.insert(lines, " ")
            table.insert(lines, "详情:")
            for targetName, spells in pairs(unitData) do
                if targetName ~= "_total" and type(spells) == "table" then
                    local targetTotal = 0
                    for _, dmg in pairs(spells) do targetTotal = targetTotal + dmg end
                    table.insert(lines, "|cffffffff" .. targetName .. "  总计: " .. targetTotal)
                    for spellName, damage in pairs(spells) do
                        table.insert(lines, "  " .. spellName .. ": " .. damage)
                    end
                end
            end
            return lines
        end

        -- 技能施放视图 (view == 8) 优先使用分层详情
        if currentView == 8 then
            local seg = config[wid].segment
            local detailsData
            if seg == 0 then
                detailsData = data.spellcast_details[0]
            elseif seg == 2 then
                detailsData = data.small_fight.spellcast_details
            else
                detailsData = ShaguDPS.cached_current_spellcast_details or data.spellcast_details[1]
            end
            local unitDetails = detailsData and detailsData[bar.unit]
            if unitDetails and unitDetails._total then
                table.insert(lines, bar.title .. ":")
                table.insert(lines, "|cffffffff总施放次数: |cffffffff" .. unitDetails._total)

                local sourceTypes = { "player", "pet", "item" }
                local sourceLabels = { player = "来自角色", pet = "来自宠物/召唤物", item = "来自道具" }
                local targetTypes = { "enemy", "friendly", "self", "none" }
                local targetLabels = { enemy = "目标：敌对", friendly = "目标：友方", self = "目标：自身", none = "无目标" }

                for _, st in ipairs(sourceTypes) do
                    local sourceData = unitDetails[st]
                    if sourceData and next(sourceData) then
                        table.insert(lines, " ")
                        table.insert(lines, "|cff88ccff" .. sourceLabels[st] .. "|r")
                        for _, tt in ipairs(targetTypes) do
                            local targetData = sourceData[tt]
                            if targetData and next(targetData) then
                                table.insert(lines, "  |cffffffff" .. targetLabels[tt] .. "|r")
                                local spells = {}
                                for spell, count in pairs(targetData) do
                                    table.insert(spells, {name=spell, count=count})
                                end
                                table.sort(spells, function(a,b) return a.count > b.count end)
                                for _, spell in ipairs(spells) do
                                    table.insert(lines, "    " .. spell.name .. ": |cffffffff" .. spell.count)
                                end
                            end
                        end
                    end
                end
                return lines
            end
        end

        -- 扁平显示
        table.insert(lines, bar.title .. ":")
        table.insert(lines, "|cffffffff总计: |cffffffff" .. unitData._total)
        table.insert(lines, " ")
        table.insert(lines, "详情:")
        local spells = {}
        for spellName, count in pairs(unitData) do
            if spellName ~= "_total" then table.insert(spells, {name=spellName, count=count}) end
        end
        table.sort(spells, function(a,b) return a.count > b.count end)
        for _, spell in ipairs(spells) do
            table.insert(lines, "|cffffffff" .. spell.name .. ": |cffffffff" .. spell.count)
        end
        return lines
    end

    -- 伤害/治疗
    if unitData._sum then
        local value = unitData._sum
        -- 确定当前有效视图（BOSS/汇总/近期战斗时映射到具体统计类型）
        local curView = config[wid].view
        local effectiveViewId = curView
        if curView == 12 or curView == 15 or curView == 23 then
            local bossStatMap = bossStatMapFull
            local st = config[wid].boss_stat_view or 1
            effectiveViewId = bossStatMap[st] or 1
        end
        -- 秒伤按配置切换 DPS(总战斗时间) / EDPS(活跃时间)
        local persec, epersec, overpersec, isDPS = getPersecData(unitData, wid, effectiveViewId)
        local evalue, over
        if unitData._esum then
            evalue = unitData._esum
            over = value - evalue
        end
        local rateLabel = isDPS and "DPS" or "EDPS"
        local isHealView = effectiveViewId >= 3 and effectiveViewId <= 6
        table.insert(lines, bar.title .. ":")
        table.insert(lines, "  |cffffcc00总量|r   |cffffffff" .. value)
        table.insert(lines, "  |cffffcc00" .. rateLabel .. "|r   |cffffffff" .. persec)
        if unitData._esum then
            table.insert(lines, "  |cffffcc00有效|r   |cff00ff00" .. evalue)
            table.insert(lines, "  |cffcc8888过量|r   |cffffffff" .. over)
            if not isHealView then
                table.insert(lines, "  |cffffcc00有效/" .. rateLabel .. "|r |cff00ff00" .. epersec)
                table.insert(lines, "  |cffcc8888过量/" .. rateLabel .. "|r |cffffffff" .. overpersec)
            end
        end
        table.insert(lines, " ")
        table.insert(lines, "|cffffcc00技能详情|r")

        local view = config[wid].view
        local dotticksSeg = nil
        local hitBreakdownSeg = nil

        if view == 12 then
            local fights = ShaguDPS.boss_fights
            local idx = ShaguDPS.current_boss_index
            if fights and idx and fights[idx] then
                dotticksSeg = fights[idx].dot_ticks
                hitBreakdownSeg = fights[idx].hit_breakdown
            elseif ShaguDPS.pendingBossRecord then
                dotticksSeg = data.dot_ticks[1]
                hitBreakdownSeg = data.hit_breakdown[1]
            end
        elseif view == 15 then
            local bossDotTicks = GetBossSummaryDataForType("dot_ticks")
            local bossHitBreakdown = GetBossSummaryDataForType("hit_breakdown")
            if bossDotTicks then dotticksSeg = bossDotTicks end
            if bossHitBreakdown then hitBreakdownSeg = bossHitBreakdown end
        elseif view == 23 then
            local fights = ShaguDPS.recent_fights or {}
            local idx = config[wid].recent_fight_index or ShaguDPS.current_recent_index
            if fights and idx and fights[idx] then
                dotticksSeg = fights[idx].dot_ticks
                hitBreakdownSeg = fights[idx].hit_breakdown
            end
        else
            local seg = config[wid].segment
            if seg == 0 then
                dotticksSeg = data.dot_ticks[0]
                hitBreakdownSeg = data.hit_breakdown[0]
            elseif seg == 2 then
                dotticksSeg = data.small_fight.dot_ticks
                hitBreakdownSeg = data.small_fight.hit_breakdown or {}
            else
                dotticksSeg = ShaguDPS.cached_current_dot_ticks or data.dot_ticks[1]
                hitBreakdownSeg = ShaguDPS.cached_current_hit_breakdown or data.hit_breakdown[1]
            end
        end

        local dotticks = dotticksSeg and dotticksSeg[bar.unit]
        local hitBreakdowns = hitBreakdownSeg and hitBreakdownSeg[bar.unit]

        local isDamageRowView = (view == 1 or view == 2)
        if view == 12 or view == 15 or view == 23 then
            local bossStatMap = bossStatMapFull
            local mapped = bossStatMap[config[wid].boss_stat_view or 1] or 1
            isDamageRowView = (mapped == 1 or mapped == 2)
        end

        for attack, damage in spairs(unitData, sort_algorithms.single_spell) do
            if attack and not internals[attack] then
                local percent = (damage == 0 or unitData._sum == 0) and 0 or round(damage / unitData._sum * 100, 1)
                local isDoT = string.find(attack, "%(DoT%)") ~= nil
                local baseAttack = attack
                if isDoT then
                    baseAttack = string.gsub(attack, " %(DoT%)", "")
                end
                local suppressCast = false
                if isDoT and unitData[baseAttack] ~= nil then
                    suppressCast = true
                end
                local hb = hitBreakdowns and (hitBreakdowns[attack] or hitBreakdowns[baseAttack])
                local crit = hb and (hb.crit or 0) or 0
                local glancing = hb and (hb.glancing or 0) or 0
                local dodge = hb and (hb.dodge or 0) or 0
                local parry = hb and (hb.parry or 0) or 0
                local block = hb and (hb.block or 0) or 0
                local resist = hb and (hb.resist or 0) or 0
                local miss = hb and (hb.miss or 0) or 0
                local normal = hb and (hb.normal or 0) or 0
                local count = hb and (crit + glancing + dodge + parry + block + resist + miss + normal + (hb.crushing or 0)) or 0
                local ticks = dotticks and dotticks[attack] or 0

                local countPart, tickPart = "", ""
                if not suppressCast and count > 0 then countPart = "|cffaaaaaa×" .. count .. "施放|r" end
                if ticks > 0 then tickPart = "|cffaaaaaa×" .. ticks .. "跳|r" end
                local order = {}
                if isDoT then
                    if tickPart ~= "" then table.insert(order, tickPart) end
                    if countPart ~= "" then table.insert(order, countPart) end
                else
                    if countPart ~= "" then table.insert(order, countPart) end
                    if tickPart ~= "" then table.insert(order, tickPart) end
                end
                local countLine = ""
                if table.getn(order) > 0 then countLine = "  " .. table.concat(order, "  ") end

                if unitData._effective and unitData._effective[attack] then
                    local effective = unitData._effective[attack]
                    local str = string.format("|cff00ff00%s|r |cffcc8888(+%s)|r (%.1f%%)", effective, damage - effective, (unitData._esum == 0 or effective == 0) and 0 or round(effective / unitData._esum * 100, 1))
                    table.insert(lines, "  |cff88ccff" .. attack .. "|r  " .. str .. countLine)
                else
                    local overkill = unitData._overkill_by_spell and unitData._overkill_by_spell[attack] or 0
                    local str
                    if overkill > 0 then
                        str = string.format("|cffffffff%s|cffff8888(+%s)|r (%.1f%%)", damage, overkill, percent)
                    else
                        str = string.format("|cffffffff%s (%.1f%%)", damage, percent)
                    end
                    table.insert(lines, "  |cff88ccff" .. attack .. "|r  " .. str .. countLine)
                end

                if isDamageRowView and not suppressCast and count > 0 then
                    local function pct(n)
                        if count > 0 then return round(n / count * 100, 1) else return 0 end
                    end
                    local detailItems = {
                        {"暴击", crit}, {"偏斜", glancing}, {"闪避", dodge},
                        {"招架", parry}, {"格挡", block}, {"抵抗", resist},
                        {"未命中", miss}, {"普通", normal},
                    }
                    local lineParts = {}
                    for di = 1, table.getn(detailItems) do
                        local item = detailItems[di]
                        table.insert(lineParts, item[1] .. " " .. item[2] .. "(" .. pct(item[2]) .. "%)")
                        if math.mod(di, 3) == 0 then
                            table.insert(lines, "      |cffaaaaaa" .. table.concat(lineParts, "  ") .. "|r")
                            lineParts = {}
                        end
                    end
                    if table.getn(lineParts) > 0 then
                        table.insert(lines, "      |cffaaaaaa" .. table.concat(lineParts, "  ") .. "|r")
                    end
                end
            end
        end

        -- 对每个目标的伤害量
        local isDamageStat = false
        if view == 12 or view == 15 or view == 23 then
            local bossStatMap = bossStatMapFull
            local s = config[wid].boss_stat_view or 1
            local mapped = bossStatMap[s] or 1
            if mapped == 1 or mapped == 2 then
                isDamageStat = true
            end
        else
            if view == 1 or view == 2 then
                isDamageStat = true
            end
        end
        if isDamageStat then
            local enemyTakenData = nil
            if view == 12 then
                local fights = ShaguDPS.boss_fights
                local idx = ShaguDPS.current_boss_index
                if fights and idx and fights[idx] then
                    enemyTakenData = fights[idx].enemy_damage_taken
                elseif ShaguDPS.pendingBossRecord then
                    enemyTakenData = data.enemy_damage_taken[1]
                end
            elseif view == 15 then
                enemyTakenData = GetBossSummaryData(19)
            elseif view == 23 then
                local fights = ShaguDPS.recent_fights or {}
                local idx = config[wid].recent_fight_index or ShaguDPS.current_recent_index
                if fights and idx and fights[idx] then
                    enemyTakenData = fights[idx].enemy_damage_taken
                end
            else
                local segType = config[wid].segment or 1
                if segType == 0 then
                    enemyTakenData = data.enemy_damage_taken[0]
                elseif segType == 2 then
                    enemyTakenData = data.small_fight.enemy_damage_taken
                else
                    enemyTakenData = ShaguDPS.cached_current_enemy_damage_taken or data.enemy_damage_taken[1]
                end
            end
            if enemyTakenData then
                local targetDetails = {}
                for targetName, targetData in pairs(enemyTakenData) do
                    if type(targetData) == "table" then
                        local srcData = targetData[bar.unit]
                        if srcData and type(srcData) == "table" then
                            local effective = srcData._sum or 0
                            local overkill = srcData._overkill or 0
                            local total = effective + overkill
                            if total > 0 then
                                table.insert(targetDetails, {
                                    name = targetName,
                                    total = total,
                                    effective = effective,
                                    overkill = overkill,
                                })
                            end
                        end
                    end
                end
                if table.getn(targetDetails) > 0 then
                    table.insert(lines, " ")
                    table.insert(lines, "|cffffcc00对每个目标的伤害量|r")
                    table.sort(targetDetails, function(a, b) return a.total > b.total end)
                    for idx, tInfo in ipairs(targetDetails) do
                        if tInfo.overkill > 0 then
                            table.insert(lines, string.format(
                                "  |cff88ccff%d. %s|r  |cffffffff%s|r |cffff8888(+%s)|r",
                                idx, tInfo.name, tInfo.effective, tInfo.overkill
                            ))
                        else
                            table.insert(lines, string.format(
                                "  |cff88ccff%d. %s|r  |cffffffff%s|r",
                                idx, tInfo.name, tInfo.effective
                            ))
                        end
                    end
                end
            end
        end

        -- 对每个目标的治疗量
        local isHealStat = false
        if view == 12 or view == 15 or view == 23 then
            local bossStatMap = bossStatMapFull
            local s = config[wid].boss_stat_view or 1
            local mapped = bossStatMap[s] or 1
            if mapped == 3 or mapped == 4 or mapped == 5 or mapped == 6 then
                isHealStat = true
            end
        else
            if view == 3 or view == 4 or view == 5 or view == 6 then
                isHealStat = true
            end
        end
        if isHealStat then
            local healTakenData = nil
            local seg = config[wid].segment or 1
            if view == 12 then
                local fights = ShaguDPS.boss_fights
                local idx = ShaguDPS.current_boss_index
                if fights and idx and fights[idx] then
                    healTakenData = fights[idx].heal_taken
                elseif ShaguDPS.pendingBossRecord then
                    healTakenData = data.heal_taken[1]
                end
            elseif view == 15 then
                healTakenData = GetBossSummaryData(15)
            elseif view == 23 then
                local fights = ShaguDPS.recent_fights or {}
                local idx = config[wid].recent_fight_index or ShaguDPS.current_recent_index
                if fights and idx and fights[idx] then
                    healTakenData = fights[idx].heal_taken
                end
            else
                if seg == 0 then
                    healTakenData = data.heal_taken[0]
                elseif seg == 2 then
                    healTakenData = data.small_fight.heal_taken
                else
                    healTakenData = ShaguDPS.cached_current_heal_taken or data.heal_taken[1]
                end
            end
            if healTakenData then
                local targetDetails = {}
                for victimName, victimData in pairs(healTakenData) do
                    if type(victimData) == "table" then
                        local srcData = victimData[bar.unit]
                        if srcData and type(srcData) == "table" then
                            local total = srcData._sum or 0
                            local effective = srcData._esum or 0
                            local overheal = total - effective
                            if total > 0 then
                                table.insert(targetDetails, {
                                    name = victimName,
                                    total = total,
                                    effective = effective,
                                    overheal = overheal,
                                })
                            end
                        end
                    end
                end
                if table.getn(targetDetails) > 0 then
                    table.insert(lines, " ")
                    table.insert(lines, "|cffffcc00对每个目标的治疗量|r")
                    table.sort(targetDetails, function(a, b) return a.total > b.total end)
                    for idx, tInfo in ipairs(targetDetails) do
                        if unitData._esum and unitData._esum > 0 then
                            table.insert(lines, string.format(
                                "  |cff88ccff%d. %s|r  |cffffffff总:%s|r |cff00ff00有效:%s|r |cffff4444过量:%s|r",
                                idx, tInfo.name, tInfo.total, tInfo.effective, tInfo.overheal
                            ))
                        else
                            table.insert(lines, string.format(
                                "  |cff88ccff%d. %s|r  |cffffffff总:%s|r",
                                idx, tInfo.name, tInfo.total
                            ))
                        end
                    end
                end
            end
        end

        return lines
    end

    -- 破甲数据在"扁平显示"分支处理（含 _total 的条目已被上方各分支吞掉）
    table.insert(lines, bar.title .. ":")
    table.insert(lines, "无法显示数据")
    return lines
end

-- ============================================================================
-- 13. 鼠标滚轮事件
-- ============================================================================

local function barScrollWheel()
    this.scroll = arg1 > 0 and this.scroll - 1 or this.scroll
    this.scroll = arg1 < 0 and this.scroll + 1 or this.scroll
    local count = 0
    for k,v in pairs(this.segment) do count = count + 1 end
    this.scroll = math.min(this.scroll, count + 1 - config[this:GetID()].bars)
    this.scroll = math.max(this.scroll, 0)
    this:Refresh()
end

-- ============================================================================
-- 14. 清空所有数据
-- ============================================================================

local function ResetData()
    if ShaguDPS.InvalidateBossSummaryCache then ShaguDPS.InvalidateBossSummaryCache() end
    for k, v in pairs(data.damage[0]) do data.damage[0][k] = nil end
    for k, v in pairs(data.damage[1]) do data.damage[1][k] = nil end
    for k, v in pairs(data.heal[0]) do data.heal[0][k] = nil end
    for k, v in pairs(data.heal[1]) do data.heal[1][k] = nil end
    for k, v in pairs(data.death[0]) do data.death[0][k] = nil end
    for k, v in pairs(data.death[1]) do data.death[1][k] = nil end
    for k, v in pairs(data.spellcast[0]) do data.spellcast[0][k] = nil end
    for k, v in pairs(data.spellcast[1]) do data.spellcast[1][k] = nil end
    for k, v in pairs(data.spellcast_details[0]) do data.spellcast_details[0][k] = nil end
    for k, v in pairs(data.spellcast_details[1]) do data.spellcast_details[1][k] = nil end
    for k, v in pairs(data.friendly_fire[0]) do data.friendly_fire[0][k] = nil end
    for k, v in pairs(data.friendly_fire[1]) do data.friendly_fire[1][k] = nil end
    for k, v in pairs(data.dispel[0]) do data.dispel[0][k] = nil end
    for k, v in pairs(data.dispel[1]) do data.dispel[1][k] = nil end
    for k, v in pairs(data.sunder[0]) do data.sunder[0][k] = nil end
    for k, v in pairs(data.sunder[1]) do data.sunder[1][k] = nil end
    for k, v in pairs(data.damage_taken[0]) do data.damage_taken[0][k] = nil end
    for k, v in pairs(data.damage_taken[1]) do data.damage_taken[1][k] = nil end
    for k, v in pairs(data.energize[0]) do data.energize[0][k] = nil end
    for k, v in pairs(data.energize[1]) do data.energize[1][k] = nil end
    for k, v in pairs(data.invalid_damage[0]) do data.invalid_damage[0][k] = nil end
    for k, v in pairs(data.invalid_damage[1]) do data.invalid_damage[1][k] = nil end
    for k, v in pairs(data.heal_taken[0]) do data.heal_taken[0][k] = nil end
    for k, v in pairs(data.heal_taken[1]) do data.heal_taken[1][k] = nil end
    for k, v in pairs(data.dot_ticks[0]) do data.dot_ticks[0][k] = nil end
    for k, v in pairs(data.dot_ticks[1]) do data.dot_ticks[1][k] = nil end
    for k, v in pairs(data.hit_breakdown[0]) do data.hit_breakdown[0][k] = nil end
    for k, v in pairs(data.hit_breakdown[1]) do data.hit_breakdown[1][k] = nil end
    for k, v in pairs(data.revive[0]) do data.revive[0][k] = nil end
    for k, v in pairs(data.revive[1]) do data.revive[1][k] = nil end
    for k, v in pairs(data.buff_coverage[0]) do data.buff_coverage[0][k] = nil end
    for k, v in pairs(data.buff_coverage[1]) do data.buff_coverage[1][k] = nil end
    for k, v in pairs(data.interrupt[0]) do data.interrupt[0][k] = nil end
    for k, v in pairs(data.interrupt[1]) do data.interrupt[1][k] = nil end
    for k, v in pairs(data.enemy_damage_taken[0]) do data.enemy_damage_taken[0][k] = nil end
    for k, v in pairs(data.enemy_damage_taken[1]) do data.enemy_damage_taken[1][k] = nil end
    ShaguDPS.cached_current_enemy_damage_taken = nil
    ShaguDPS.cached_current_interrupt = nil
    ShaguDPS.cached_current_buff_coverage = nil
    ShaguDPS.buff_coverage_active = {}
    ShaguDPS.weakness_coverage_active = {}
    ShaguDPS.cached_current_damage = nil
    ShaguDPS.cached_current_heal = nil
    ShaguDPS.cached_current_death = nil
    ShaguDPS.cached_current_spellcast = nil
    ShaguDPS.cached_current_spellcast_details = nil
    ShaguDPS.cached_current_friendly_fire = nil
    ShaguDPS.cached_current_dispel = nil
    ShaguDPS.cached_current_sunder = nil
    ShaguDPS.cached_current_damage_taken = nil
    ShaguDPS.cached_current_energize = nil
    ShaguDPS.cached_current_invalid_damage = nil
    ShaguDPS.cached_current_heal_taken = nil
    ShaguDPS.cached_current_dot_ticks = nil
    ShaguDPS.cached_current_hit_breakdown = nil
    ShaguDPS.cached_current_revive = nil
    ShaguDPS.cached_current_death_replays = nil
    data.death_replays = {}

    ShaguDPS.ClearCache()
    if ShaguDPS.Combat() then
        data.combat_start_time = GetTime()
    else
        data.combat_start_time = 0
    end
    data.last_fight_duration = 0
    data.total_combat_time = 0
    data.death_timestamps = {}
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
    data.revive_noncombat = {}

    ShaguDPS.small_fight_total_time = 0
    ShaguDPS.hostile_targets = {}
    ShaguDPS.current_boss_index = nil
    data.threat = {}
    data.enemy_max_health = {}
    for i=1,10 do if window[i] then window[i].scroll = 0 end end
    window.Refresh(true)
end

local startReport

-- ============================================================================
-- 15. 可滚动详情窗口
-- ============================================================================

ShaguDPS.detailWindow = nil
ShaguDPS.detailWindowData = nil

local function estimateTextWidth(text)
    local charCount = 0
    for _ in string.gfind(text, "([%z\1-\127\194-\244][\128-\191]*)") do
        charCount = charCount + 1
    end
    local avgWidth = 7
    return charCount * avgWidth
end

-- 去除颜色代码，用于关键字匹配
local function stripDetailColor(text)
    if type(text) ~= "string" then text = tostring(text) end
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    return text
end

-- 按过滤条件（关键字 + 起始/结束行号）从完整详情行中筛选，
-- 返回 { num = 原始行号, text = 行内容 } 的列表
local function ApplyDetailFilter(fullLines, fl)
    local kw = fl and fl.keyword or ""
    local lowKw = string.lower(kw or "")
    local total = table.getn(fullLines)
    local startL = tonumber(fl and fl.startLine) or 1
    local endL = tonumber(fl and fl.endLine) or total
    if startL < 1 then startL = 1 end
    if endL > total then endL = total end
    if endL < 1 then endL = total end
    if startL > endL then startL, endL = 1, total end
    local out = {}
    for i = startL, endL do
        local txt = fullLines[i]
        if txt then
            if lowKw == "" then
                table.insert(out, { num = i, text = txt })
            else
                local clean = string.lower(stripDetailColor(txt))
                if string.find(clean, lowKw, 1, true) then
                    table.insert(out, { num = i, text = txt })
                end
            end
        end
    end
    return out
end

local function CreateDetailWindow(title, lines, barData)
    if not lines or table.getn(lines) == 0 then
        lines = { "无数据" }
    end

    if ShaguDPS.detailWindow then
        ShaguDPS.detailWindow:Hide()
        ShaguDPS.detailWindow = nil
        ShaguDPS.detailWindowData = nil
    end

    -- 常规详情过滤：关键字搜索 + 起始/结束行号
    local showLineNumbers = true
    local entries = nil
    if barData then
        if not barData._fullLines then
            barData._fullLines = lines
            barData._filter = { keyword = "", startLine = 1, endLine = table.getn(lines) }
        end
        entries = ApplyDetailFilter(barData._fullLines, barData._filter)
    else
        entries = {}
        for i, txt in ipairs(lines) do
            entries[i] = { num = i, text = txt }
        end
    end

    -- 计算宽度
    local maxContentWidth = 0
    for _, entry in ipairs(entries) do
        local t = entry.text
        if showLineNumbers then t = string.format("%02d. ", entry.num) .. t end
        local w = estimateTextWidth(t)
        if w > maxContentWidth then maxContentWidth = w end
    end
    local titleWidth = estimateTextWidth(title) * 1.1
    if titleWidth > maxContentWidth then maxContentWidth = titleWidth end

    local padding = 20
    local borderOffset = 4
    local extraBuffer = 10
    local windowWidth = maxContentWidth + padding + borderOffset + extraBuffer
    if windowWidth < 200 then windowWidth = 200 end
    if windowWidth > 1000 then windowWidth = 1000 end

    local lineHeight = 20
    local numLines = table.getn(entries)
    local contentHeight = numLines * lineHeight + 10

    local screenHeight = GetScreenHeight()
    local fixedHeight = math.min(450, screenHeight * 0.6)
    if fixedHeight < 200 then fixedHeight = 200 end

    local titleHeight = 30
    local bottomPadding = -10
    local windowHeight = fixedHeight
    local filterHeight = 0
    if barData then
        filterHeight = 40
    end
    local visibleHeight = windowHeight - titleHeight - bottomPadding - 10 - filterHeight

    local isPfui = (ShaguDPS.config.pfuiStyle == 1)

    -- 创建主窗口
    local f = CreateFrame("Frame", "ShaguDPSDetailWindow", UIParent)
    f:SetWidth(windowWidth)
    f:SetHeight(windowHeight)
    f:SetPoint("CENTER", UIParent, "CENTER")

    if isPfui then
        f:SetBackdrop({
            bgFile   = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            tile     = false,
            tileSize = 0,
            edgeSize = 2,
            insets   = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        f:SetBackdropColor(0, 0, 0, 0.4)
        f:SetBackdropBorderColor(0.4, 0.4, 0.4, 0)

        f._pfuiShadow = CreateFrame("Frame", nil, f)
        f._pfuiShadow:SetFrameStrata("BACKGROUND")
        f._pfuiShadow:SetFrameLevel(1)
        f._pfuiShadow:SetPoint("TOPLEFT", f, "TOPLEFT", -2, 2)
        f._pfuiShadow:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 2, -2)
        f._pfuiShadow:SetBackdrop({
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeSize = 2,
        })
        f._pfuiShadow:SetBackdropBorderColor(0, 0, 0, 0.35)
        f._pfuiShadow:Show()
        f.border = nil
    else
        f:SetBackdrop(backdrop_window)
        f:SetBackdropColor(.5, .5, .5, .9)

        f.border = CreateFrame("Frame", nil, f)
        f.border:ClearAllPoints()
        f.border:SetPoint("TOPLEFT", f, "TOPLEFT", -1, 1)
        f.border:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 1, -1)
        f.border:SetFrameLevel(100)
        f.border:SetBackdrop(backdrop_border)
        f.border:SetBackdropBorderColor(.7, .7, .7, 1)
    end

    f:SetMovable(true)
    f:EnableMouse(true)
    f:EnableMouseWheel(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")

    -- 标题栏
    f.title = f:CreateTexture(nil, "NORMAL")
    f.title:SetTexture(0, 0, 0, .6)
    f.title:SetHeight(20)
    f.title:SetPoint("TOPLEFT", 2, -2)
    f.title:SetPoint("TOPRIGHT", -2, -2)

    local titleText = f:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    titleText:SetPoint("CENTER", f.title, "CENTER", 0, 0)
    titleText:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
    titleText:SetText(title or "详情")

    -- 关闭按钮
    local closeBtn = CreateFrame("Button", nil, f)
    closeBtn:SetPoint("RIGHT", f.title, "RIGHT", -4, 0)
    closeBtn:SetHeight(16)
    closeBtn:SetWidth(16)

    if isPfui then
        closeBtn:SetNormalTexture("")
        closeBtn:SetHighlightTexture("")
        closeBtn:SetPushedTexture("")
        closeBtn:SetDisabledTexture("")
        closeBtn:SetBackdrop({
            bgFile   = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            tile     = false,
            tileSize = 0,
            edgeSize = 1,
            insets   = { left = 0, right = 0, top = 0, bottom = 0 }
        })
        closeBtn:SetBackdropColor(0, 0, 0, 0.75)
        closeBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        closeBtn:SetScript("OnEnter", function() this:SetBackdropBorderColor(1, 0.8, 0, 1) end)
        closeBtn:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.4, 0.4, 0.4, 1) end)
    else
        closeBtn:SetBackdrop(backdrop)
        closeBtn:SetBackdropColor(.2, .2, .2, 1)
        closeBtn:SetBackdropBorderColor(.4, .4, .4, 1)
        closeBtn:SetScript("OnEnter", function() this:SetBackdropBorderColor(1, .8, 0, 1) end)
        closeBtn:SetScript("OnLeave", function() this:SetBackdropBorderColor(.4, .4, .4, 1) end)
    end

    closeBtn:SetScript("OnClick", function()
        f:Hide()
        ShaguDPS.detailWindow = nil
        ShaguDPS.detailWindowData = nil
    end)
    local closeLabel = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    closeLabel:SetFont(STANDARD_TEXT_FONT, 14)
    closeLabel:SetText("x")
    closeLabel:SetAllPoints()

    -- 发送到聊天按钮（左上角）
    local sendBtn = CreateFrame("Button", nil, f)
    sendBtn:SetPoint("LEFT", f.title, "LEFT", 2, 0)
    sendBtn:SetHeight(16)
    sendBtn:SetWidth(16)
    if isPfui then
        sendBtn:SetNormalTexture("")
        sendBtn:SetHighlightTexture("")
        sendBtn:SetPushedTexture("")
        sendBtn:SetDisabledTexture("")
        sendBtn:SetBackdrop({
            bgFile   = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            tile     = false,
            tileSize = 0,
            edgeSize = 1,
            insets   = { left = 0, right = 0, top = 0, bottom = 0 }
        })
        sendBtn:SetBackdropColor(0, 0, 0, 0.75)
        sendBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    else
        sendBtn:SetBackdrop(backdrop)
        sendBtn:SetBackdropColor(.2, .2, .2, 1)
        sendBtn:SetBackdropBorderColor(.4, .4, .4, 1)
    end
    sendBtn.tex = sendBtn:CreateTexture()
    sendBtn.tex:SetWidth(10)
    sendBtn.tex:SetHeight(10)
    sendBtn.tex:SetPoint("CENTER", 0, 0)
    sendBtn.tex:SetTexture("Interface\\AddOns\\ShaguDPS" .. (tbc and "-tbc" or "") .. "\\img\\announce")

    sendBtn.tooltip = {
        "发送到聊天",
        { "|cffffffff点击", "|cffaaaaaa询问发送数据" },
        { "|cffffffffShift+点击", "|cffaaaaaa直接发送数据" }
    }

    sendBtn:SetScript("OnEnter", function()
        if this.tooltip then
            GameTooltip_SetDefaultAnchor(GameTooltip, this)
            for i, data in pairs(this.tooltip) do
                if type(data) == "string" then
                    GameTooltip:AddLine(data)
                elseif type(data) == "table" then
                    GameTooltip:AddDoubleLine(data[1], data[2])
                end
            end
            GameTooltip:Show()
        end
        this:SetBackdropBorderColor(1, 0.8, 0, 1)
    end)
    sendBtn:SetScript("OnLeave", function()
        if this.tooltip then GameTooltip:Hide() end
        this:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end)

    local function doSend()
        local function stripColorCodes(text)
            if type(text) ~= "string" then
                text = tostring(text)
            end
            text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
            text = string.gsub(text, "|r", "")
            return text
        end
        local reportLines = {}
        if title and title ~= "" then
            table.insert(reportLines, "ShaguDPS - " .. stripColorCodes(title))
        else
            table.insert(reportLines, "ShaguDPS - 详情")
        end
        for _, entry in ipairs(entries) do
            local cleanLine = stripColorCodes(entry.text)
            if string.find(cleanLine, "%S") then
                if showLineNumbers then
                    table.insert(reportLines, string.format("%02d. ", entry.num) .. cleanLine)
                else
                    table.insert(reportLines, cleanLine)
                end
            end
        end
        startReport(reportLines)
    end

    sendBtn:SetScript("OnClick", function()
        if IsShiftKeyDown() then
            doSend()
        else
            local dialog = StaticPopupDialogs["SHAGUMETER_QUESTION"]
            dialog.text = "发送当前详情数据到聊天？"
            dialog.OnAccept = doSend
            StaticPopup_Show("SHAGUMETER_QUESTION")
        end
    end)

    -- 常规详情过滤面板：关键字搜索 + 起始/结束行号
    if barData then
        local fl = barData._filter
        local panelWidth = math.max(windowWidth, 300)
        f:SetWidth(panelWidth)

        local function rebuildDetailFilter()
            if ShaguDPS.detailWindow and barData then
                ShaguDPS.detailWindow:Hide()
                ShaguDPS.detailWindow = nil
                ShaguDPS.detailWindowData = nil
                CreateDetailWindow(title, nil, barData)
            end
        end

        filterPanel = CreateFrame("Frame", nil, f)
        filterPanel:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -2)
        filterPanel:SetPoint("TOPRIGHT", f.title, "BOTTOMRIGHT", 0, -2)
        filterPanel:SetHeight(filterHeight)
        filterPanel:SetFrameStrata("DIALOG")

        -- 第一行：关键字搜索
        local searchLabel = filterPanel:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        searchLabel:SetPoint("TOPLEFT", filterPanel, "TOPLEFT", 4, -8)
        searchLabel:SetFont(STANDARD_TEXT_FONT, 11)
        searchLabel:SetText("搜索:")
        local searchBox = CreateFrame("EditBox", nil, filterPanel)
        searchBox:SetPoint("TOPLEFT", filterPanel, "TOPLEFT", 42, -6)
        searchBox:SetWidth(panelWidth - 56)
        searchBox:SetHeight(16)
        searchBox:SetAutoFocus(false)
        searchBox:SetFont(STANDARD_TEXT_FONT, 11)
        searchBox:SetTextInsets(2, 2, 0, 0)
        if isPfui then
            searchBox:SetBackdrop({
                bgFile   = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = "Interface\\BUTTONS\\WHITE8X8",
                tile     = false,
                tileSize = 0,
                edgeSize = 1,
                insets   = { left = 0, right = 0, top = 0, bottom = 0 }
            })
            searchBox:SetBackdropColor(0, 0, 0, 0.4)
            searchBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        else
            searchBox:SetBackdrop(backdrop)
            searchBox:SetBackdropColor(0, 0, 0, 0.5)
        end
        searchBox:SetText(fl.keyword or "")

        -- 第二行：起始/结束行号（默认第一行与最后一行，重新打开后恢复默认）
        local startLabel = filterPanel:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        startLabel:SetPoint("TOPLEFT", filterPanel, "TOPLEFT", 4, -30)
        startLabel:SetFont(STANDARD_TEXT_FONT, 11)
        startLabel:SetText("起始行:")
        local startBox = CreateFrame("EditBox", nil, filterPanel)
        startBox:SetPoint("TOPLEFT", filterPanel, "TOPLEFT", 52, -28)
        startBox:SetWidth(52)
        startBox:SetHeight(16)
        startBox:SetAutoFocus(false)
        startBox:SetFont(STANDARD_TEXT_FONT, 11)
        startBox:SetTextInsets(2, 2, 0, 0)
        if isPfui then
            startBox:SetBackdrop({
                bgFile   = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = "Interface\\BUTTONS\\WHITE8X8",
                tile     = false,
                tileSize = 0,
                edgeSize = 1,
                insets   = { left = 0, right = 0, top = 0, bottom = 0 }
            })
            startBox:SetBackdropColor(0, 0, 0, 0.4)
            startBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        else
            startBox:SetBackdrop(backdrop)
            startBox:SetBackdropColor(0, 0, 0, 0.5)
        end
        startBox:SetText(tostring(fl.startLine or 1))

        local endLabel = filterPanel:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        endLabel:SetPoint("TOPLEFT", filterPanel, "TOPLEFT", 112, -30)
        endLabel:SetFont(STANDARD_TEXT_FONT, 11)
        endLabel:SetText("结束行:")
        local endBox = CreateFrame("EditBox", nil, filterPanel)
        endBox:SetPoint("TOPLEFT", filterPanel, "TOPLEFT", 160, -28)
        endBox:SetWidth(52)
        endBox:SetHeight(16)
        endBox:SetAutoFocus(false)
        endBox:SetFont(STANDARD_TEXT_FONT, 11)
        endBox:SetTextInsets(2, 2, 0, 0)
        if isPfui then
            endBox:SetBackdrop({
                bgFile   = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = "Interface\\BUTTONS\\WHITE8X8",
                tile     = false,
                tileSize = 0,
                edgeSize = 1,
                insets   = { left = 0, right = 0, top = 0, bottom = 0 }
            })
            endBox:SetBackdropColor(0, 0, 0, 0.4)
            endBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        else
            endBox:SetBackdrop(backdrop)
            endBox:SetBackdropColor(0, 0, 0, 0.5)
        end
        endBox:SetText(tostring(fl.endLine or table.getn(barData._fullLines)))

        -- 输入时仅更新过滤值；回车或失焦时延迟重建，避免点关闭时误重建
        searchBox:SetScript("OnTextChanged", function()
            fl.keyword = this:GetText() or ""
        end)
        startBox:SetScript("OnTextChanged", function()
            local t = tonumber(this:GetText() or "")
            fl.startLine = t or 1
        end)
        endBox:SetScript("OnTextChanged", function()
            local t = tonumber(this:GetText() or "")
            fl.endLine = t or table.getn(barData._fullLines)
        end)
        local function applyDetailFilter()
            local changed = false
            if (fl.keyword or "") ~= (fl._lastKeyword or "") then fl._lastKeyword = fl.keyword changed = true end
            if (fl.startLine or 1) ~= (fl._lastStartLine or 1) then fl._lastStartLine = fl.startLine changed = true end
            if (fl.endLine or table.getn(barData._fullLines)) ~= (fl._lastEndLine or table.getn(barData._fullLines)) then fl._lastEndLine = fl.endLine changed = true end
            if changed then rebuildDetailFilter() end
        end
        searchBox:SetScript("OnEnterPressed", applyDetailFilter)
        startBox:SetScript("OnEnterPressed", applyDetailFilter)
        endBox:SetScript("OnEnterPressed", applyDetailFilter)
        searchBox:SetScript("OnEditFocusLost", function()
            filterPanel.needsRebuild = true
        end)
        startBox:SetScript("OnEditFocusLost", function()
            filterPanel.needsRebuild = true
        end)
        endBox:SetScript("OnEditFocusLost", function()
            filterPanel.needsRebuild = true
        end)
        filterPanel:SetScript("OnUpdate", function()
            if not this.needsRebuild then return end
            this.needsRebuild = nil
            if not ShaguDPS.detailWindow then return end
            applyDetailFilter()
        end)
    end

    -- 滚动框架（右侧留出滑块空间）
    local scrollFrame = CreateFrame("ScrollFrame", nil, f)
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -30 - filterHeight)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -22, -bottomPadding)
    scrollFrame:SetFrameLevel(1)
    if scrollFrame.GetScrollBar then
        local builtinScrollBar = scrollFrame:GetScrollBar()
        if builtinScrollBar then builtinScrollBar:Hide() end
    end
    scrollFrame:SetVerticalScroll(0)

    local container = CreateFrame("Frame", nil, scrollFrame)
    container:SetWidth(windowWidth - 32)
    container:SetHeight(contentHeight)
    container:SetPoint("TOPLEFT", 0, 0)
    scrollFrame:SetScrollChild(container)

    local scrollOffset = 0
    local maxScrollOffset = math.max(0, contentHeight - visibleHeight)

    -- 垂直滑块（黑白灰配色，与 ShaguDPS 整体风格一致）
    local scrollAreaHeight = windowHeight - (30 + filterHeight) - (-bottomPadding)
    local scrollBar = CreateFrame("Slider", nil, f)
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetWidth(10)
    scrollBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -30 - filterHeight)
    scrollBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, -bottomPadding)
    scrollBar:SetValueStep(1)
    scrollBar:SetMinMaxValues(0, maxScrollOffset)
    scrollBar:SetFrameLevel(scrollFrame:GetFrameLevel() + 5)
    scrollBar:SetAlpha(0)
    local scrollBarTrack = scrollBar:CreateTexture(nil, "BACKGROUND")
    scrollBarTrack:SetTexture("Interface\\Buttons\\WHITE8X8")
    scrollBarTrack:SetAllPoints()
    scrollBarTrack:SetVertexColor(0.08, 0.08, 0.08, 0.7)
    scrollBar:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    local scrollBarThumb = scrollBar:GetThumbTexture()
    if scrollBarThumb then
        local thumbHeight = math.max(22, math.min(scrollAreaHeight, scrollAreaHeight * scrollAreaHeight / math.max(1, contentHeight)))
        scrollBarThumb:SetWidth(8)
        scrollBarThumb:SetHeight(thumbHeight)
        scrollBarThumb:SetVertexColor(0.78, 0.78, 0.78, 0.95)
    end

    local updatingScroll = false
    local function UpdateScroll()
        if not scrollFrame or not container then return end
        if scrollOffset < 0 then scrollOffset = 0 end
        if scrollOffset > maxScrollOffset then scrollOffset = maxScrollOffset end
        scrollFrame:SetVerticalScroll(scrollOffset)
        if maxScrollOffset <= 0 then
            scrollBar:SetAlpha(0)
        else
            scrollBar:SetAlpha(1)
        end
        if not updatingScroll then
            updatingScroll = true
            scrollBar:SetValue(scrollOffset)
            updatingScroll = false
        end
    end

    scrollBar:SetScript("OnValueChanged", function()
        if updatingScroll then return end
        updatingScroll = true
        scrollOffset = arg1
        UpdateScroll()
        updatingScroll = false
    end)

    f:SetScript("OnMouseWheel", function()
        local delta = arg1
        if delta == nil then return end
        local step = 20
        if delta > 0 then
            scrollOffset = scrollOffset - step
        else
            scrollOffset = scrollOffset + step
        end
        UpdateScroll()
    end)

    -- 创建文本行
    for i, entry in ipairs(entries) do
        local txt = entry.text
        local level = 1
        local indent = 0
        local _, _, prefix = string.find(txt, "^(%s*)")
        if prefix then
            indent = string.len(prefix)
            if indent >= 4 then
                level = 3
            elseif indent >= 2 then
                level = 2
            else
                level = 1
            end
        end

        local fontSize = 10
        local fontFlag = ""
        if level == 1 then
            fontSize = 12
            fontFlag = "OUTLINE"
        elseif level == 2 then
            fontSize = 11
            fontFlag = ""
        else
            fontSize = 10
            fontFlag = ""
        end

        local displayText = txt
        if showLineNumbers then
            displayText = string.format("%02d. ", entry.num) .. txt
        end
        if i == 1 then
            displayText = "|cffffcc00" .. displayText .. "|r"
            fontSize = 12
            fontFlag = "OUTLINE"
        end

        local line = container:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        line:SetFont(STANDARD_TEXT_FONT, fontSize, fontFlag)
        line:SetJustifyH("LEFT")
        line:SetPoint("TOPLEFT", container, "TOPLEFT", 6, -( (i-1) * lineHeight + 4 ))
        line:SetText(displayText)
    end

    scrollOffset = 0
    UpdateScroll()

    ShaguDPS.detailWindow = f
    ShaguDPS.detailWindowData = barData

    f:Show()
    return f
end

-- ============================================================================
-- 16. 创建单个进度条
-- ============================================================================

local function CreateBar(parent, i)
    local totalHeight = config.height + config.spacing
    local yOffset = totalHeight * (i-1) + 22
    parent.bars[i] = parent.bars[i] or CreateFrame("StatusBar", "ShaguDPSBar" .. i, parent)
    parent.bars[i].parent = parent
    parent.bars[i]:SetStatusBarTexture(textures[config.texture] or textures[1])
    parent.bars[i]:SetPoint("TOPLEFT", parent, "TOPLEFT", 2, -yOffset)
    parent.bars[i]:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -2, -yOffset)
    parent.bars[i]:SetHeight(config.height)
    parent.bars[i]:SetFrameLevel(4)
    parent.bars[i].lowerBar = parent.bars[i].lowerBar or CreateFrame("StatusBar", "ShaguDPSLowerBar" .. i, parent)
    parent.bars[i].lowerBar:SetStatusBarTexture(textures[config.texture] or textures[1])
    parent.bars[i].lowerBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 2, -yOffset)
    parent.bars[i].lowerBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -2, -yOffset)
    parent.bars[i].lowerBar:SetStatusBarColor(1, 1, 1, .4)
    parent.bars[i].lowerBar:SetHeight(config.height)
    parent.bars[i].lowerBar:SetFrameLevel(2)

    -- 职业图标（进度条最左侧）：尺寸随条高缩放，文字左边距相应后移
    local iconSize = config.height - 2
    if iconSize < 8 then iconSize = 8 end
    local showIcon = config.show_class_icon ~= 0
    local iconPad = showIcon and (iconSize + 5) or 5

    -- 图标背景框（半透明暗色，轻微遮挡进度条填充，图标保持清晰）
    parent.bars[i].iconBg = parent.bars[i].iconBg or CreateFrame("Frame", nil, parent.bars[i])
    parent.bars[i].iconBg:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        tile = false, tileSize = 0, edgeSize = 0,
    })
    parent.bars[i].iconBg:SetBackdropColor(0, 0, 0, 0.35)
    parent.bars[i].iconBg:SetWidth(iconSize + 2)
    parent.bars[i].iconBg:SetHeight(iconSize + 2)
    parent.bars[i].iconBg:ClearAllPoints()
    parent.bars[i].iconBg:SetPoint("LEFT", parent.bars[i], "LEFT", 0, 0)
    parent.bars[i].iconBg:SetFrameLevel(parent.bars[i]:GetFrameLevel() + 1)

    -- 图标贴图（作为 iconBg 子贴图，绘制在背景之上）
    parent.bars[i].classIcon = parent.bars[i].classIcon or parent.bars[i].iconBg:CreateTexture(nil, "OVERLAY")
    parent.bars[i].classIcon:SetParent(parent.bars[i].iconBg)
    parent.bars[i].classIcon:SetWidth(iconSize)
    parent.bars[i].classIcon:SetHeight(iconSize)
    parent.bars[i].classIcon:ClearAllPoints()
    parent.bars[i].classIcon:SetPoint("CENTER", parent.bars[i].iconBg, "CENTER", 0, 0)
    parent.bars[i].classIcon:SetTexture(nil)
    if showIcon then
        parent.bars[i].iconBg:Show()
        parent.bars[i].classIcon:Show()
    else
        parent.bars[i].iconBg:Hide()
        parent.bars[i].classIcon:Hide()
    end

    parent.bars[i].textLeft = parent.bars[i].textLeft or parent.bars[i]:CreateFontString("Status", "OVERLAY", "GameFontNormal")
    parent.bars[i].textLeft:SetFont(STANDARD_TEXT_FONT, 10, "THINOUTLINE")
    parent.bars[i].textLeft:SetJustifyH("LEFT")
    parent.bars[i].textLeft:SetFontObject(GameFontWhite)
    parent.bars[i].textLeft:SetParent(parent.bars[i])
    parent.bars[i].textLeft:ClearAllPoints()
    parent.bars[i].textLeft:SetPoint("TOPLEFT", parent.bars[i], "TOPLEFT", iconPad, 1)
    parent.bars[i].textLeft:SetPoint("BOTTOMRIGHT", parent.bars[i], "BOTTOMRIGHT", -5, 0)
    parent.bars[i].textRight = parent.bars[i].textRight or parent.bars[i]:CreateFontString("Status", "OVERLAY", "GameFontNormal")
    parent.bars[i].textRight:SetFont(STANDARD_TEXT_FONT, 10, "THINOUTLINE")
    parent.bars[i].textRight:SetJustifyH("RIGHT")
    parent.bars[i].textRight:SetFontObject(GameFontWhite)
    parent.bars[i].textRight:SetParent(parent.bars[i])
    parent.bars[i].textRight:ClearAllPoints()
    parent.bars[i].textRight:SetPoint("TOPLEFT", parent.bars[i], "TOPLEFT", 5, 1)
    parent.bars[i].textRight:SetPoint("BOTTOMRIGHT", parent.bars[i], "BOTTOMRIGHT", -5, 0)
    parent.bars[i]:EnableMouse(true)
    parent.bars[i]:SetScript("OnEnter", barTooltipShow)
    parent.bars[i]:SetScript("OnLeave", barTooltipHide)

    -- 点击进度条打开详情窗口
    parent.bars[i]:SetScript("OnMouseUp", function(button)
        local unit = this.unit
        local parent = this.parent
        local wid = parent:GetID()
        local segment = parent.segment
        if not unit or not segment or not segment[unit] then
            return
        end

        local segType = config[wid].segment or 1
        local segName = ""
        if segType == 0 then
            segName = "全程"
        elseif segType == 2 then
            segName = "小怪"
        else
            segName = "当前"
        end

        local viewId = config[wid].view
        local viewName = ""
        local bossStatMap = bossStatMapFull
        if viewId == 12 then
            local fights = ShaguDPS.boss_fights
            local idx = ShaguDPS.current_boss_index
            if fights and idx and fights[idx] then
                segName = fights[idx].name
            else
                segName = "BOSS"
            end
            local st = config[wid].boss_stat_view or 1
            local tplIdx = bossStatMap[st] or 1
            viewName = view_templates[tplIdx].name
        elseif viewId == 15 then
            segName = "BOSS汇总"
            local st = config[wid].boss_stat_view or 1
            if st == 21 then st = 1 end
            local tplIdx = bossStatMap[st] or 1
            viewName = view_templates[tplIdx].name
        elseif viewId == 23 then
            local fights = ShaguDPS.recent_fights
            local idx = config[wid].recent_fight_index or ShaguDPS.current_recent_index
            if fights and idx and fights[idx] then
                segName = fights[idx].name
            else
                segName = "最近战斗"
            end
            local st = config[wid].boss_stat_view or 1
            local tplIdx = bossStatMap[st] or 1
            viewName = view_templates[tplIdx].name
        else
            viewName = view_templates[viewId].name
        end

        local title = segName .. " - " .. viewName .. " - " .. (this.title or unit)
        local lines = GetBarDetailLines(this)

        local barData = {
            unit = unit,
            wid = wid,
            segType = segType,
            viewId = viewId,
        }

        if ShaguDPS.detailWindow and ShaguDPS.detailWindowData then
            if ShaguDPS.detailWindowData.unit == unit and
               ShaguDPS.detailWindowData.wid == wid and
               ShaguDPS.detailWindowData.segType == segType and
               ShaguDPS.detailWindowData.viewId == viewId then
                ShaguDPS.detailWindow:Hide()
                ShaguDPS.detailWindow = nil
                ShaguDPS.detailWindowData = nil
                return
            end
        end

        CreateDetailWindow(title, lines, barData)
    end)

    return parent.bars[i]
end

-- ============================================================================
-- 17. 按钮悬停效果
-- ============================================================================

local function btnEnter()
    if this.tooltip then
        GameTooltip_SetDefaultAnchor(GameTooltip, this)
        for i, data in pairs(this.tooltip) do
            if type(data) == "string" then GameTooltip:AddLine(data)
            elseif type(data) == "table" then GameTooltip:AddDoubleLine(data[1], data[2]) end
        end
        GameTooltip:Show()
    end
    this:SetBackdropBorderColor(1,.8,0,1)
end

local function btnLeave()
    if this.tooltip then GameTooltip:Hide() end
    this:SetBackdropBorderColor(.4,.4,.4,1)
end

-- ============================================================================
-- 18. BOSS 选择二级菜单
-- ============================================================================

local function ShowBossSubMenu(parent, bossModeBtn)
    local fights = ShaguDPS.boss_fights
    local numFights = table.getn(fights or {})
    if bossModeBtn._bossMenu then
        bossModeBtn._bossMenu:Hide()
        bossModeBtn._bossMenu = nil
    end
    bossModeBtn._bossMenuLeaveTime = nil

    if numFights == 0 then
        local tip = CreateFrame("Frame", nil, parent)
        tip:SetBackdrop(backdrop_window)
        tip:SetBackdropColor(.2,.2,.2,.9)
        tip:SetBackdropBorderColor(.4,.4,.4,1)
        tip:SetFrameStrata("DIALOG")
        tip:SetWidth(120)
        tip:SetHeight(20)
        local txt = tip:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        txt:SetFont(STANDARD_TEXT_FONT, 9)
        txt:SetText("暂无BOSS记录")
        txt:SetAllPoints()
        tip:SetPoint("LEFT", bossModeBtn, "RIGHT", 5, 0)
        tip:Show()
        tip.isTip = true
        bossModeBtn._bossMenu = tip
        return
    end

    local menu = CreateFrame("Frame", nil, parent)
    menu:SetBackdrop(backdrop_window)
    menu:SetBackdropColor(.2,.2,.2,.9)
    menu:SetBackdropBorderColor(.4,.4,.4,1)
    menu:SetFrameStrata("DIALOG")
    local itemHeight = 16
    local maxShow = math.min(numFights, 15)
    local menuWidth = 75
    local totalHeight = maxShow * itemHeight + 4
    menu:SetWidth(menuWidth)
    menu:SetHeight(totalHeight)
    if ShaguDPS.config.menu_grow_upwards == 1 then
        menu:SetPoint("BOTTOMLEFT", bossModeBtn, "BOTTOMRIGHT", 0, 0)
    else
        menu:SetPoint("TOPLEFT", bossModeBtn, "TOPRIGHT", 0, 0)
    end

    for i = 1, maxShow do
        local idx = i
        local fight = fights[idx]
        local btn = CreateFrame("Button", nil, menu)
        btn:SetPoint("TOPLEFT", 2, -2 - (idx-1)*itemHeight)
        btn:SetWidth(menuWidth - 4)
        btn:SetHeight(itemHeight)
        btn:SetBackdrop(backdrop)
        btn:SetBackdropColor(.2,.2,.2,1)
        btn:SetBackdropBorderColor(.4,.4,.4,1)
        local cap = btn:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        cap:SetFont(STANDARD_TEXT_FONT, 9)
        local displayName = fight.name
        if string.len(displayName) > 18 then
            displayName = string.sub(displayName, 1, 12) .. "..."
        end
        cap:SetText(displayName)
        cap:SetAllPoints()
        btn:SetScript("OnEnter", function() this:SetBackdropBorderColor(1,.8,0,1) end)
        btn:SetScript("OnLeave", function() this:SetBackdropBorderColor(.4,.4,.4,1) end)
        btn:SetScript("OnClick", function()
            ShaguDPS.current_boss_index = idx
            parent:Refresh(true)
            menu:Hide()
            bossModeBtn._bossMenu = nil
        end)
    end

    menu:SetScript("OnUpdate", function()
        local now = GetTime()
        if MouseIsOver(menu) or MouseIsOver(bossModeBtn) then
            bossModeBtn._bossMenuLeaveTime = nil
        else
            if not bossModeBtn._bossMenuLeaveTime then
                bossModeBtn._bossMenuLeaveTime = now + 2
            end
            if now >= bossModeBtn._bossMenuLeaveTime then
                menu:Hide()
                bossModeBtn._bossMenu = nil
                bossModeBtn._bossMenuLeaveTime = nil
            end
        end
    end)

    menu:Show()
    if ShaguDPS.config.pfuiStyle == 1 then
        ShaguDPS.ApplyPfuiToBossMenu(menu)
    end
    bossModeBtn._bossMenu = menu
end

-- ============================================================================
-- 19. 最近战斗选择二级菜单
-- ============================================================================

local function ShowRecentFightsSubMenu(parent, recentBtn)
    local fights = ShaguDPS.recent_fights or {}
    local numFights = table.getn(fights)
    if recentBtn._bossMenu then
        recentBtn._bossMenu:Hide()
        recentBtn._bossMenu = nil
    end
    recentBtn._bossMenuLeaveTime = nil

    if numFights == 0 then
        local tip = CreateFrame("Frame", nil, parent)
        tip:SetBackdrop(backdrop_window)
        tip:SetBackdropColor(.2,.2,.2,.9)
        tip:SetBackdropBorderColor(.4,.4,.4,1)
        tip:SetFrameStrata("DIALOG")
        tip:SetWidth(120)
        tip:SetHeight(20)
        local txt = tip:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        txt:SetFont(STANDARD_TEXT_FONT, 9)
        txt:SetText("暂无战斗记录")
        txt:SetAllPoints()
        tip:SetPoint("LEFT", recentBtn, "RIGHT", 5, 0)
        tip:Show()
        tip.isTip = true
        recentBtn._bossMenu = tip
        return
    end

    local menu = CreateFrame("Frame", nil, parent)
    menu:SetBackdrop(backdrop_window)
    menu:SetBackdropColor(.2,.2,.2,.9)
    menu:SetBackdropBorderColor(.4,.4,.4,1)
    menu:SetFrameStrata("DIALOG")
    local itemHeight = 16
    local maxShow = math.min(numFights, 5)
    local menuWidth = 100
    local totalHeight = maxShow * itemHeight + 4
    menu:SetWidth(menuWidth)
    menu:SetHeight(totalHeight)
    if ShaguDPS.config.menu_grow_upwards == 1 then
        menu:SetPoint("BOTTOMLEFT", recentBtn, "BOTTOMRIGHT", 0, 0)
    else
        menu:SetPoint("TOPLEFT", recentBtn, "TOPRIGHT", 0, 0)
    end

    for i = 1, maxShow do
        local idx = numFights - i + 1
        local fight = fights[idx]
        local btn = CreateFrame("Button", nil, menu)
        btn:SetPoint("TOPLEFT", 2, -2 - (i-1)*itemHeight)
        btn:SetWidth(menuWidth - 4)
        btn:SetHeight(itemHeight)
        btn:SetBackdrop(backdrop)
        btn:SetBackdropColor(.2,.2,.2,1)
        btn:SetBackdropBorderColor(.4,.4,.4,1)
        local cap = btn:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        cap:SetFont(STANDARD_TEXT_FONT, 9)
        local displayName = fight.name or ("战斗 " .. idx)
        if string.len(displayName) > 20 then
            displayName = string.sub(displayName, 1, 15) .. "..."
        end
        cap:SetText(displayName)
        cap:SetAllPoints()
        btn:SetScript("OnEnter", function() this:SetBackdropBorderColor(1,.8,0,1) end)
        btn:SetScript("OnLeave", function() this:SetBackdropBorderColor(.4,.4,.4,1) end)
        btn:SetScript("OnClick", function()
            local wid = parent:GetID()
            if not config[wid] then config[wid] = {} end
            config[wid].recent_fight_index = idx
            ShaguDPS.current_recent_index = idx
            if config[wid].view ~= 12 and config[wid].view ~= 15 and config[wid].view ~= 23 then
                config[wid].boss_stat_view = viewToBossStat[config[wid].view] or 1
            end
            config[wid].view = 23
            parent:Refresh(true)
            menu:Hide()
            recentBtn._bossMenu = nil
        end)
    end

    menu:SetScript("OnUpdate", function()
        local now = GetTime()
        if MouseIsOver(menu) or MouseIsOver(recentBtn) then
            recentBtn._bossMenuLeaveTime = nil
        else
            if not recentBtn._bossMenuLeaveTime then
                recentBtn._bossMenuLeaveTime = now + 2
            end
            if now >= recentBtn._bossMenuLeaveTime then
                menu:Hide()
                recentBtn._bossMenu = nil
                recentBtn._bossMenuLeaveTime = nil
            end
        end
    end)

    menu:Show()
    if ShaguDPS.config.pfuiStyle == 1 then
        ShaguDPS.ApplyPfuiToBossMenu(menu)
    end
    recentBtn._bossMenu = menu
end

local function ForceHideBossSubMenu(bossModeBtn)
    if bossModeBtn._bossMenu then
        bossModeBtn._bossMenu:Hide()
        bossModeBtn._bossMenu = nil
    end
    bossModeBtn._bossMenuLeaveTime = nil
end

-- ============================================================================
-- 20. 发送聊天消息
-- ============================================================================

local function announce(text)
    local chatType = tbc and ChatFrameEditBox:GetAttribute("chatType") or ChatFrameEditBox.chatType
    local language = tbc and ChatFrameEditBox:GetAttribute("language") or ChatFrameEditBox.language
    local channel = tbc and ChatFrameEditBox:GetAttribute("channelTarget") or ChatFrameEditBox.channelTarget
    local target = tbc and ChatFrameEditBox:GetAttribute("tellTarget") or ChatFrameEditBox.tellTarget
    if chatType == "WHISPER" then SendChatMessage(text, chatType, language, target)
    elseif chatType == "CHANNEL" then SendChatMessage(text, chatType, language, channel);
    else SendChatMessage(text, chatType, language); end
end

local function formatThreatNumber(n)
    if n < 0 then n = 0 end
    -- 中文单位：万(10^4) / 亿(10^8) / 兆(10^12，即万亿)
    if config.chinese_units == 1 then
        if n < 1e4 then return round(n) end
        if n < 1e8 then return string.format("%.2f万", n / 1e4) end
        if n < 1e12 then return string.format("%.2f亿", n / 1e8) end
        return string.format("%.2f兆", n / 1e12)
    end
    if n < 1000 then return round(n) end
    -- 接近 100 万时按 K/M 四舍五入取整，避免出现 "1000K"
    if n < 999500 then return round(n / 10) / 100 .. "K" end
    return round(n / 10000) / 100 .. "M"
end

-- ============================================================================
-- 21. 逐条发送报告帧
-- ============================================================================

local reportFrame = CreateFrame("Frame")
reportFrame:Hide()
reportFrame.reportQueue = {}
reportFrame.reportIndex = 0
reportFrame.reportTimer = 0

reportFrame:SetScript("OnUpdate", function()
    if not reportFrame:IsShown() then return end
    local now = GetTime()
    local elapsed = now - reportFrame.reportTimer
    if elapsed >= 0.5 and reportFrame.reportIndex <= table.getn(reportFrame.reportQueue) then
        announce(reportFrame.reportQueue[reportFrame.reportIndex])
        reportFrame.reportIndex = reportFrame.reportIndex + 1
        reportFrame.reportTimer = now
    end
    if reportFrame.reportIndex > table.getn(reportFrame.reportQueue) then
        reportFrame:Hide()
        reportFrame.reportQueue = {}
        reportFrame.reportIndex = 0
    end
end)

startReport = function(dataTable)
    reportFrame.reportQueue = dataTable
    reportFrame.reportIndex = 1
    reportFrame.reportTimer = 0
    reportFrame:Show()
end

-- ============================================================================
-- 22. 计算当前视图下的最大值和全团总量
-- ============================================================================

local function GetCaps(view, values, isHealTaken, isBuffCoverage, segmentType, totalTimeForDPS, useTotalCBT, viewId, isVulnCoverage)
    local values = values or {}
    values.best = 0
    values.all = 0
    values.persecond_best = 0
    values.persecond_all = 0
    values.effective_best = 0
    values.effective_all = 0
    values.effective_persecond_best = 0
    values.effective_persecond_all = 0
    values.uneffective_best = 0
    values.uneffective_all = 0
    values.uneffective_persecond_best = 0
    values.uneffective_persecond_all = 0
    values.death_best = 0
    values.spellcast_best = 0
    values.friendly_fire_best = 0
    values.dispel_best = 0
    values.threat_best = 0
    values.perc_best = 0
    values.sunder_best = 0
    values.damage_taken_best = 0
    values.damage_taken_all = 0
    values.enemy_taken_best = 0
    values.enemy_taken_all = 0
    values.total_heal_all = 0
    values.total_heal_hps_all = 0
    values.total_effective_all = 0
    values.total_uneffective_all = 0
    values.heal_taken_best = 0
    values.heal_taken_all = 0
    values.revive_best = 0
    values.revive_all = 0
    values.best_avg_cov = 0
    values.buff_count_max = 0
    values.vuln_best = 0
    values.vuln_count_max = 0

    for name, data in pairs(view) do
        if type(data) == "table" then
            if isVulnCoverage then
                local details = GetVulnerabilityCoverageDetails(data, nil, segmentType, name)
                local avgCov = details.avgCov
                local totalCount = details.totalCount
                if avgCov > values.vuln_best then values.vuln_best = avgCov end
                if totalCount > values.vuln_count_max then values.vuln_count_max = totalCount end
            elseif isBuffCoverage then
                local details = GetBuffCoverageDetails(data, name, segmentType)
                local totalCount = details.totalCount
                local avgCov = details.avgCov
                if avgCov > values.best_avg_cov then values.best_avg_cov = avgCov end
                if totalCount > values.buff_count_max then values.buff_count_max = totalCount end
            elseif isHealTaken then
                local sum = data._sum or 0
                values.all = values.all + sum
                if sum > values.best then values.best = sum end
                local esum = data._esum or 0
                values.effective_all = values.effective_all + esum
                if esum > values.effective_best then values.effective_best = esum end
                local uneff = sum - esum
                values.uneffective_all = values.uneffective_all + uneff
                if uneff > values.uneffective_best then values.uneffective_best = uneff end
                values.total_heal_all = values.total_heal_all + sum
                values.total_effective_all = values.total_effective_all + esum
                values.total_uneffective_all = values.total_uneffective_all + uneff
            elseif data.threat then
                if data.threat > values.threat_best then values.threat_best = data.threat end
                if data.perc > values.perc_best then values.perc_best = data.perc end
            elseif data._by_target then
                local sum = data._sum or 0
                local ctime = data._ctime or 1
                if ctime <= 0 then ctime = 1 end
                local perSec = sum / ctime
                if useTotalCBT and totalTimeForDPS and totalTimeForDPS > 0 then
                    perSec = sum / totalTimeForDPS
                end
                values.all = values.all + sum
                if sum > values.best then values.best = sum end
                values.persecond_all = values.persecond_all + perSec
                if perSec > values.persecond_best then values.persecond_best = perSec end
                values.total_heal_all = values.total_heal_all + sum
                values.total_heal_hps_all = values.total_heal_hps_all + perSec
            elseif data._overkill and not data._ctime and not data._by_target and not data._history then
                local sum = data._sum or 0
                values.enemy_taken_all = values.enemy_taken_all + sum
                if sum > values.enemy_taken_best then
                    values.enemy_taken_best = sum
                end
            elseif data._history then
                local sum = data._sum or 0
                if isHealTaken then
                    values.heal_taken_all = (values.heal_taken_all or 0) + sum
                    if sum > (values.heal_taken_best or 0) then values.heal_taken_best = sum end
                else
                    values.damage_taken_all = values.damage_taken_all + sum
                    if sum > values.damage_taken_best then values.damage_taken_best = sum end
                end
            elseif data["_sum"] and data["_ctime"] then
                local useCBT = not isHealTaken and useTotalCBT and totalTimeForDPS and totalTimeForDPS > 0
                local perSec = 0
                if useCBT then
                    perSec = data["_sum"] / totalTimeForDPS
                else
                    perSec = data["_sum"] / data["_ctime"]
                end
                values.all = values.all + data["_sum"]
                if data["_sum"] > values.best then values.best = data["_sum"] end
                values.persecond_all = values.persecond_all + perSec
                if perSec > values.persecond_best then values.persecond_best = perSec end
                values.total_heal_all = values.total_heal_all + data["_sum"]
                values.total_heal_hps_all = values.total_heal_hps_all + perSec
            end
            if data["_esum"] and data["_ctime"] and not isHealTaken then
                values.effective_all = values.effective_all + data["_esum"]
                if data["_esum"] > values.effective_best then values.effective_best = data["_esum"] end
                values.effective_persecond_all = values.effective_persecond_all + data["_esum"] / data["_ctime"]
                if data["_esum"] / data["_ctime"] > values.effective_persecond_best then values.effective_persecond_best = data["_esum"] / data["_ctime"] end
                local uneffective = data["_sum"] - data["_esum"]
                values.uneffective_all = values.uneffective_all + uneffective
                if uneffective > values.uneffective_best then values.uneffective_best = uneffective end
                values.uneffective_persecond_all = values.uneffective_persecond_all + uneffective / data["_ctime"]
                if uneffective / data["_ctime"] > values.uneffective_persecond_best then values.uneffective_persecond_best = uneffective / data["_ctime"] end
                values.total_effective_all = values.total_effective_all + data["_esum"]
                values.total_uneffective_all = values.total_uneffective_all + uneffective
            end
            if data["_total"] and type(data["_total"]) == "number" then
                local total = data["_total"]
                if total > values.spellcast_best then values.spellcast_best = total end
                if total > values.sunder_best then values.sunder_best = total end
                if not data["_offensive"] and not data["_sum"] and not data["_history"] then
                    local isRevive = false
                    for k, v in pairs(data) do
                        if k ~= "_total" and type(v) == "number" then
                            isRevive = true
                            break
                        end
                    end
                    if isRevive and (viewId == 19) then
                        values.revive_all = (values.revive_all or 0) + total
                        if total > values.revive_best then values.revive_best = total end
                    end
                end
            end
            if data["_total"] and type(data["_total"]) == "number" and (data["_total"] > values.friendly_fire_best) then
                values.friendly_fire_best = data["_total"]
            end
            if data._total and data._total > values.dispel_best then
                values.dispel_best = data._total
            end
        else
            if data > values.death_best then values.death_best = data end
        end
    end
    return values
end

-- ============================================================================
-- 23. 获取单个单位的数据
-- ============================================================================

local function GetData(unitdata, values, isHealTaken, view, isBuffCoverage, segmentType, totalTimeOverride, isVulnCoverage)
    local values = values or {}
    if type(unitdata) == "table" then
        if isBuffCoverage or isVulnCoverage then
            local details
            if isBuffCoverage then
                details = GetBuffCoverageDetails(unitdata, values.name, segmentType, totalTimeOverride)
            else
                details = GetVulnerabilityCoverageDetails(unitdata, totalTimeOverride, segmentType, values.name)
            end
            values.total_count = details.totalCount
            values.avg_cov = details.avgCov
            values.avg_cov_percent = details.avgCov
            values.value = details.avgCov
            values.percent = details.avgCov
            values.buff_count = details.buffCount
            values.debuff_count = details.debuffCount
            values.buff_avg_cov = details.buffAvgCov
            values.debuff_avg_cov = details.debuffAvgCov
            -- 宠物判定：data["classes"][name] 存在且非职业token且非"__other__"才视为宠物；
            -- 为 nil（无职业记录，如敌方目标/历史存档中已退队角色）时不按宠物处理
            local clsVal = data["classes"] and data["classes"][values.name]
            local pet = clsVal ~= nil and clsVal ~= "__other__" and not classes[clsVal]
            local unit = pet and clsVal or values.name
            if config.merge_pets == 0 then
                values.name = pet and unit .. " - " .. values.name or unit
            else
                values.name = unit
            end
            local r, g, b = str2rgb(values.name)
            values.color = values.color or {}
            values.color.r = r / 4 + .4
            values.color.g = g / 4 + .4
            values.color.b = b / 4 + .4
            if classes[data["classes"][unit]] then
                values.color.r = RAID_CLASS_COLORS[data["classes"][unit]].r
                values.color.g = RAID_CLASS_COLORS[data["classes"][unit]].g
                values.color.b = RAID_CLASS_COLORS[data["classes"][unit]].b
                if config.pastel == 1 then
                    values.color.r = (values.color.r + .5) * .5
                    values.color.g = (values.color.g + .5) * .5
                    values.color.b = (values.color.b + .5) * .5
                end
            end
            return values
        elseif isHealTaken then
            local sum = unitdata._sum or 0
            local esum = unitdata._esum or 0
            values.value = sum
            values.effective_value = esum
            values.uneffective_value = sum - esum
            values.total_heal_percent = values.total_heal_all > 0 and round(sum / values.total_heal_all * 100, 1) or 0
            values.total_effective_percent = values.total_effective_all > 0 and round(esum / values.total_effective_all * 100, 1) or 0
            values.total_uneffective_percent = values.total_uneffective_all > 0 and round((sum - esum) / values.total_uneffective_all * 100, 1) or 0
        elseif unitdata.threat then
            values.threat_value = unitdata.threat or 0
            values.threat_value_str = formatThreatNumber(values.threat_value)
            values.perc = unitdata.perc or 0
            values.tps = unitdata.tps or 0
            values.tps_str = formatThreatNumber(values.tps)
            values.value = values.threat_value
            if unitdata.class then
                data.classes[values.name] = unitdata.class
            end
        elseif unitdata._by_target then
            values.value = unitdata._sum or 0
            values.value_persecond = round(values.value / (unitdata._ctime or 1), 1)
            values.percent = values.all > 0 and round(values.value / values.all * 100, 1) or 0
            values.percent_persecond = values.persecond_all > 0 and round(values.value_persecond / values.persecond_all * 100, 1) or 0
            values.overkill = unitdata._overkill or 0
            values._by_target = unitdata._by_target
        elseif unitdata._overkill and not unitdata._ctime and not unitdata._by_target and not unitdata._history then
            values.enemy_taken_value = unitdata._sum or 0
            values.enemy_taken_overkill = unitdata._overkill or 0
            values.enemy_taken_percent = values.enemy_taken_all > 0 and round(values.enemy_taken_value / values.enemy_taken_all * 100, 1) or 0
            values.value = values.enemy_taken_value
            values.overkill = values.enemy_taken_overkill
            values.percent = values.enemy_taken_percent
        elseif unitdata._history then
            values.damage_taken_value = unitdata._sum or 0
            values.damage_taken_percent = values.damage_taken_all > 0 and round(unitdata._sum / values.damage_taken_all * 100, 1) or 0
            values.value = unitdata._sum or 0
        elseif unitdata["_sum"] ~= nil then
            values.value = unitdata["_sum"]
            local ctime = unitdata["_ctime"]
            if not ctime or ctime <= 0 then ctime = 1 end
            values.value_persecond = round(values.value / ctime, 1)
            values.percent = (values.value == 0 or values.all == 0) and 0 or round(values.value / values.all * 100, 1)
            values.percent_persecond = (values.value_persecond == 0 or values.persecond_all == 0) and 0 or round(values.value_persecond / values.persecond_all * 100, 1)
            values.overkill = unitdata["_overkill"] or 0

            if unitdata["_esum"] then
                values.effective_value = unitdata["_esum"]
                values.effective_value_persecond = round(values.effective_value / ctime, 1)
                values.total_heal_percent = (values.value == 0 or values.total_heal_all == 0) and 0 or round(values.value / values.total_heal_all * 100, 1)
                values.total_hps_percent = (values.value_persecond == 0 or values.total_heal_hps_all == 0) and 0 or round(values.value_persecond / values.total_heal_hps_all * 100, 1)
                values.total_effective_percent = (values.effective_value == 0 or values.total_effective_all == 0) and 0 or round(values.effective_value / values.total_effective_all * 100, 1)

                values.uneffective_value = values.value - values.effective_value
                values.uneffective_value_persecond = values.value_persecond - values.effective_value_persecond
                values.total_uneffective_percent = (values.uneffective_value == 0 or values.total_uneffective_all == 0) and 0 or round(values.uneffective_value / values.total_uneffective_all * 100, 1)

                values.effective_percent = values.total_heal_percent
                values.uneffective_percent = values.total_uneffective_percent
            else
                values.effective_value = 0
                values.effective_value_persecond = 0
                values.effective_percent = 0
                values.effective_percent_persecond = 0
                values.uneffective_value = 0
                values.uneffective_value_persecond = 0
                values.uneffective_percent = 0
                values.total_heal_percent = 0
                values.total_hps_percent = 0
                values.total_effective_percent = 0
                values.total_uneffective_percent = 0
            end
        elseif unitdata["_total"] ~= nil and unitdata["_offensive"] ~= nil then
            values.dispel_total = unitdata._total
            values.dispel_offensive = unitdata._offensive
            values.dispel_defensive = unitdata._defensive
            values.value = unitdata._total
            local dispelWrong = 0
            if unitdata["错误驱散"] then
                for _, tdata in pairs(unitdata["错误驱散"]) do
                    if type(tdata) == "table" then
                        for _, cnt in pairs(tdata) do
                            if type(cnt) == "number" then
                                dispelWrong = dispelWrong + cnt
                            end
                        end
                    end
                end
            end
            values.dispel_wrong = dispelWrong
        elseif unitdata["_total"] ~= nil then
            if view == 8 then
                values.spellcast_total = unitdata._total
                values.value = unitdata._total
            elseif view == 9 then
                values.friendly_fire_total = unitdata._total
                values.value = unitdata._total
            elseif view == 13 then
                values.sunder_value = unitdata._total
                values.value = unitdata._total
            elseif view == 19 then
                values.revive_value = unitdata._total
                values.percent = (values.revive_all or 0) > 0 and round(unitdata._total / values.revive_all * 100, 1) or 0
                values.value = unitdata._total
            elseif view == 21 then
                values.interrupt_value = unitdata._total
                values.interrupt_percent = (values.interrupt_all or 0) > 0 and round(unitdata._total / values.interrupt_all * 100, 1) or 0
                values.value = unitdata._total
            end
        end
    else
        values.death_value = unitdata
        values.value = unitdata
    end

    -- 宠物判定：data["classes"][name] 存在且非职业token且非"__other__"才视为宠物；
    -- 为 nil（无职业记录，如敌方目标/历史存档中已退队角色）时不按宠物处理
    local clsVal = data["classes"] and data["classes"][values.name]
    local pet = clsVal ~= nil and clsVal ~= "__other__" and not classes[clsVal]
    local unit = pet and clsVal or values.name
    if type(unitdata) ~= "number" then
        if config.merge_pets == 0 then
            values.name = pet and unit .. " - " .. values.name or unit
        else
            values.name = unit
        end
    end

    local r, g, b = str2rgb(values.name)
    values.color = values.color or {}
    values.color.r = r / 4 + .4
    values.color.g = g / 4 + .4
    values.color.b = b / 4 + .4

    if unitdata and type(unitdata) == "table" and unitdata.threat and values.name == UnitName("player") then
        values.color.r = 1.0
        values.color.g = 0.2
        values.color.b = 0.2
    elseif classes[data["classes"][unit]] then
        values.color.r = RAID_CLASS_COLORS[data["classes"][unit]].r
        values.color.g = RAID_CLASS_COLORS[data["classes"][unit]].g
        values.color.b = RAID_CLASS_COLORS[data["classes"][unit]].b
        if config.pastel == 1 then
            values.color.r = (values.color.r + .5) * .5
            values.color.g = (values.color.g + .5) * .5
            values.color.b = (values.color.b + .5) * .5
        end
    end
    return values
end

-- ============================================================================
-- 24. 格式化数字显示
-- ============================================================================

local function formatBarNumber(num)
    if type(num) ~= "number" then return num end
    -- 中文单位：万(10^4) / 亿(10^8) / 兆(10^12，即万亿)
    if config.chinese_units == 1 then
        if num >= 1e12 then
            return string.format("%.2f兆", num / 1e12)
        elseif num >= 1e8 then
            return string.format("%.2f亿", num / 1e8)
        elseif num >= 1e4 then
            return string.format("%.1f万", num / 1e4)
        else
            return num
        end
    end
    if num >= 1e6 then
        return string.format("%.2fM", num / 1e6)
    elseif num >= 1e4 then
        return string.format("%.1fK", num / 1e3)
    else
        return num
    end
end

-- ============================================================================
-- 25. 刷新窗口内容（核心函数）
-- ============================================================================

local function Refresh(self, force, report)
    if not self or type(self) == "boolean" then return end
    self:SetScale(config.scale)
    local values, buttons = self.values, self.buttons
    local wid = self:GetID()

    -- 无 Nampower 时仅支持基础视图及仇恨(11)，其他强制回到伤害视图
    if not ShaguDPS.hasNampower and (config[wid].view >= 5) and config[wid].view ~= 11 then
        config[wid].view = 1
    end

    -- 如果当前视图被禁用，自动切换到第一个启用的视图
    local currentView = config[wid].view
    if currentView ~= 12 and currentView ~= 15 and not ShaguDPS.IsStatEnabled(currentView) then
        local first = ShaguDPS.GetFirstEnabledStat()
        if first then
            config[wid].view = first
            currentView = first
        else
            self.segment = {}
        end
    end
    if currentView == 25 then
        local first = ShaguDPS.GetFirstEnabledStat()
        if first then
            config[wid].view = first
            currentView = first
        else
            config[wid].view = 1
            currentView = 1
        end
    end
    -- BOSS/BOSS汇总 视图内的统计类型也检查开关
    if (currentView == 12 or currentView == 15 or currentView == 23) then
        local bossStatToView = {
            [1]=1, [2]=2, [3]=3, [4]=4, [5]=5, [6]=6,
            [7]=7, [8]=8, [9]=9, [10]=10, [11]=13,
            [12]=14, [13]=16, [14]=17, [15]=18,
            [16]=19, [17]=20, [18]=21, [19]=22,
            [20]=24,
        }
        local sv = config[wid].boss_stat_view or 1
        -- 兼容旧配置：旧版 boss_stat_view 21 = 动作回放，现已删除，自动回退到 1
        if sv == 21 or not bossStatToView[sv] then
            sv = 1
            config[wid].boss_stat_view = 1
        end
        if bossStatToView[sv] and not ShaguDPS.IsStatEnabled(bossStatToView[sv]) then
            for _, id in ipairs(ShaguDPS.rightStatViews) do
                if ShaguDPS.IsStatEnabled(id) then
                    for k, v in pairs(bossStatToView) do
                        if v == id then
                            config[wid].boss_stat_view = k
                            break
                        end
                    end
                    break
                end
            end
        end
    end

    local isThreatView = (config[wid].view == 11)
    local isBossView = (config[wid].view == 12)
    local isBossSummaryView = (config[wid].view == 15)
    local isRecentFightView = (config[wid].view == 23)
    local isSunderView = (config[wid].view == 13)
    local isDamageTakenView = (config[wid].view == 14)
    local isEnergizeView = (config[wid].view == 16) or ((isBossView or isBossSummaryView or isRecentFightView) and config[wid].boss_stat_view == 13)
    local isInvalidDamageView = (config[wid].view == 17) or ((isBossView or isBossSummaryView or isRecentFightView) and config[wid].boss_stat_view == 14)
    local isHealTakenView = (config[wid].view == 18) or ((isBossView or isRecentFightView) and config[wid].boss_stat_view == 15) or (isBossSummaryView and config[wid].boss_stat_view == 15)
    local isReviveView = (config[wid].view == 19) or ((isBossView or isBossSummaryView or isRecentFightView) and config[wid].boss_stat_view == 16)
    local isBuffCoverageView = (config[wid].view == 20) or ((isBossView or isRecentFightView) and config[wid].boss_stat_view == 17) or (isBossSummaryView and config[wid].boss_stat_view == 17)
    local isInterruptView = (config[wid].view == 21) or ((isBossView or isBossSummaryView or isRecentFightView) and config[wid].boss_stat_view == 18)
    local isEnemyTakenView = (config[wid].view == 22) or ((isBossView or isBossSummaryView or isRecentFightView) and config[wid].boss_stat_view == 19)
    local isVulnCoverageView = (config[wid].view == 24) or ((isBossView or isBossSummaryView or isRecentFightView) and config[wid].boss_stat_view == 20)

    self.isHealTakenView = isHealTakenView
    self.isEnergizeView = isEnergizeView
    self.isReviveView = isReviveView
    self.isBuffCoverageView = isBuffCoverageView
    self.isEnemyTakenView = isEnemyTakenView
    self.isVulnCoverageView = isVulnCoverageView
    self.isInterruptView = isInterruptView

    local segmentType = config[wid].segment or 1
    local isSmallFight = (segmentType == 2)

    local currentBossFight = nil
    if isBossView then
        local fights = ShaguDPS.boss_fights
        if fights and table.getn(fights) > 0 then
            local idx = ShaguDPS.current_boss_index
            if not idx or idx < 1 or idx > table.getn(fights) then
                idx = table.getn(fights)
                ShaguDPS.current_boss_index = idx
            end
            currentBossFight = fights[idx]
        elseif ShaguDPS.pendingBossRecord then
            currentBossFight = {
                name = ShaguDPS.pendingBossRecord.name,
                damage = data.damage[1],
                heal = data.heal[1],
                death = data.death[1],
                spellcast = data.spellcast[1],
                spellcast_details = data.spellcast_details[1],
                friendly_fire = data.friendly_fire[1],
                dispel = data.dispel[1],
                sunder = data.sunder[1],
                damage_taken = data.damage_taken[1],
                enemy_damage_taken = data.enemy_damage_taken[1],
                energize = data.energize[1],
                invalid_damage = data.invalid_damage[1],
                heal_taken = data.heal_taken[1],
                dot_ticks = data.dot_ticks[1],
                hit_breakdown = data.hit_breakdown[1],
                revive = data.revive[1],
                buff_coverage = data.buff_coverage[1],
                duration = math.max(GetTime() - data.combat_start_time, 1),
            }
        end
    end

    local currentRecentFight = nil
    if isRecentFightView then
        if ShaguDPS.recent_fights and table.getn(ShaguDPS.recent_fights) > 0 then
            local idx = config[wid].recent_fight_index or ShaguDPS.current_recent_index
            if not idx or idx < 1 or idx > table.getn(ShaguDPS.recent_fights) then
                idx = table.getn(ShaguDPS.recent_fights)
                ShaguDPS.current_recent_index = idx
            end
            config[wid].recent_fight_index = idx
            currentRecentFight = ShaguDPS.recent_fights[idx]
        end
    end

    if config.visible == 1 then self:Show() else self:Hide() end
    if ShaguDPS.config.pfuiStyle ~= 1 then
        if config.backdrop == 1 then
            self:SetBackdrop(backdrop_window)
            self:SetBackdropColor(.5,.5,.5,.5)
            self.border:SetBackdrop(backdrop_border)
            self.border:SetBackdropBorderColor(.7,.7,.7,1)
        else
            self:SetBackdrop(nil)
            self.border:SetBackdrop(nil)
        end
    end

    for _, button in pairs(buttons) do button.caption:SetTextColor(1,1,1,1) end

    -- 更新左侧分段/视图选择按钮的标题及交互
    if isBossView then
        if currentBossFight then
            self.btnSegment.caption:SetText(currentBossFight.name)
        else
            self.btnSegment.caption:SetText("无记录")
        end
        self.btnSegment.tooltip = { "BOSS战记录", "|cffffffff点击可切换分段，悬停可切换BOSS" }
        self.btnSegment:SetScript("OnEnter", function()
            btnEnter()
            ShowBossSubMenu(self, this)
        end)
        self.btnSegment:SetScript("OnLeave", function()
            btnLeave()
            if this._bossMenu and this._bossMenu.isTip then
                this._bossMenu:Hide()
                this._bossMenu = nil
            else
                this._bossMenuLeaveTime = GetTime()
            end
        end)
    elseif isRecentFightView then
        if currentRecentFight then
            self.btnSegment.caption:SetText(currentRecentFight.name)
        else
            self.btnSegment.caption:SetText("无记录")
        end
        self.btnSegment.tooltip = { "最近战斗", "|cffffffff点击可切换分段，悬停可切换最近战斗" }
        self.btnSegment:SetScript("OnEnter", function()
            btnEnter()
            ShowRecentFightsSubMenu(self, this)
        end)
        self.btnSegment:SetScript("OnLeave", function()
            btnLeave()
            if this._bossMenu and this._bossMenu.isTip then
                this._bossMenu:Hide()
                this._bossMenu = nil
            else
                this._bossMenuLeaveTime = GetTime()
            end
        end)
    elseif isBossSummaryView then
        self.btnSegment.caption:SetText("BOSS汇总")
        self.btnSegment.tooltip = { "选择时间段/视图", "|cffffffff当前, 全程, 小怪, BOSS, BOSS汇总" }
        self.btnSegment:SetScript("OnEnter", btnEnter)
        self.btnSegment:SetScript("OnLeave", btnLeave)
        ForceHideBossSubMenu(self.btnSegment)
    elseif isSmallFight then
        self.btnSegment.caption:SetText("小怪")
        self.btnSegment.tooltip = { "选择时间段/视图", "|cffffffff当前, 全程, 小怪, BOSS, BOSS汇总" }
        self.btnSegment:SetScript("OnEnter", btnEnter)
        self.btnSegment:SetScript("OnLeave", btnLeave)
        ForceHideBossSubMenu(self.btnSegment)
    else
        self.btnSegment.caption:SetText(segmentType == 0 and "全程" or "当前")
        self.btnSegment.tooltip = { "选择时间段/视图", "|cffffffff当前, 全程, 小怪, BOSS, BOSS汇总" }
        self.btnSegment:SetScript("OnEnter", btnEnter)
        self.btnSegment:SetScript("OnLeave", btnLeave)
        ForceHideBossSubMenu(self.btnSegment)
    end

    -- 更新右侧模式标题
    if isBossView or isBossSummaryView or isRecentFightView then
        local bossStatMap = bossStatMapFull
        local st = config[wid].boss_stat_view or 1
        local tplIdx = bossStatMap[st] or 1
        if ShaguDPS.IsStatEnabled(tplIdx) then
            self.btnMode.caption:SetText(view_templates[tplIdx].name)
        else
            self.btnMode.caption:SetText("禁用统计")
        end
    else
        local viewId = config[wid].view
        if ShaguDPS.IsStatEnabled(viewId) then
            self.btnMode.caption:SetText(view_templates[viewId].name)
        else
            self.btnMode.caption:SetText("禁用统计")
        end
    end
    -- 生成统计类型提示
    local modeTooltipLines = { "选择统计类型" }
    local modeLine = ""
    local modeCount = 0
    for _, viewId in ipairs(ShaguDPS.rightStatViews) do
        if ShaguDPS.IsStatEnabled(viewId) and view_templates[viewId] then
            local name = view_templates[viewId].name
            if modeCount == 0 then
                modeLine = name
            else
                modeLine = modeLine .. ", " .. name
            end
            modeCount = modeCount + 1
            if modeCount == 4 then
                table.insert(modeTooltipLines, "|cffffffff" .. modeLine .. "|r")
                modeLine = ""
                modeCount = 0
            end
        end
    end
    if modeCount > 0 then
        table.insert(modeTooltipLines, "|cffffffff" .. modeLine .. "|r")
    end
    self.btnMode.tooltip = modeTooltipLines
    self.btnMode:SetScript("OnEnter", btnEnter)
    self.btnMode:SetScript("OnLeave", btnLeave)

    -- 设置左侧菜单控件显示/隐藏
    if isThreatView then
        self.btnSegment:Hide()
    else
        self.btnSegment:Show()
        self.btnSegment:SetAlpha(1)
    end

    if isThreatView then
        self.btnOverall:Hide()
        self.btnCurrent:Hide()
        self.btnSmall:Hide()
        if self.btnBossMenu then self.btnBossMenu:Hide() end
        if self.btnBossSummaryMenu then self.btnBossSummaryMenu:Hide() end
        if self.btnRecentFights then self.btnRecentFights:Hide() end
    end

    if ShaguDPS.hasNampower and self.btnBossPrev and self.btnBossNext then
        if isBossView then
            local fights = ShaguDPS.boss_fights
            if fights and table.getn(fights) > 1 then
                self.btnBossPrev:Show()
                self.btnBossNext:Show()
            else
                self.btnBossPrev:Hide()
                self.btnBossNext:Hide()
            end
        elseif isRecentFightView then
            local fights = ShaguDPS.recent_fights or {}
            if table.getn(fights) > 1 then
                self.btnBossPrev:Show()
                self.btnBossNext:Show()
            else
                self.btnBossPrev:Hide()
                self.btnBossNext:Hide()
            end
        else
            self.btnBossPrev:Hide()
            self.btnBossNext:Hide()
        end
    end

    if self.btnBossPrev and self.btnBossNext then
        if isRecentFightView then
            self.btnBossPrev.tooltip = { "上一场战斗", "|cffffffff切换到上一个最近战斗记录" }
            self.btnBossNext.tooltip = { "下一场战斗", "|cffffffff切换到下一个最近战斗记录" }
        elseif isBossView then
            self.btnBossPrev.tooltip = { "上一场BOSS战", "|cffffffff切换到上一个BOSS战记录" }
            self.btnBossNext.tooltip = { "下一场BOSS战", "|cffffffff切换到下一个BOSS战记录" }
        end
    end

    if isBossView or isRecentFightView then
        self.btnReset:Hide()
        self.btnWindow:Hide()
    else
        self.btnReset:Show()
        self.btnWindow:Show()
    end

    -- 高亮右侧视图按钮
    local highlightView
    if isBossView or isBossSummaryView or isRecentFightView then
        local bossStatMap = bossStatMapFull
        highlightView = bossStatMap[config[wid].boss_stat_view or 1] or 1
    else
        highlightView = config[wid].view
    end

    -- 重置所有右侧按钮颜色
    self.btnDamage.caption:SetTextColor(1,1,1,1)
    self.btnDPS.caption:SetTextColor(1,1,1,1)
    self.btnHeal.caption:SetTextColor(1,1,1,1)
    self.btnHPS.caption:SetTextColor(1,1,1,1)
    self.btnThreat.caption:SetTextColor(1,1,1,1)
    if ShaguDPS.hasNampower then
        self.btnEffHeal.caption:SetTextColor(1,1,1,1)
        self.btnOverHeal.caption:SetTextColor(1,1,1,1)
        self.btnDeath.caption:SetTextColor(1,1,1,1)
        self.btnSpellcast.caption:SetTextColor(1,1,1,1)
        self.btnFriendlyFire.caption:SetTextColor(1,1,1,1)
        self.btnDispel.caption:SetTextColor(1,1,1,1)
        self.btnSunder.caption:SetTextColor(1,1,1,1)
        self.btnDamageTaken.caption:SetTextColor(1,1,1,1)
        self.btnEnergize.caption:SetTextColor(1,1,1,1)
        self.btnInvalidDamage.caption:SetTextColor(1,1,1,1)
        self.btnHealTaken.caption:SetTextColor(1,1,1,1)
        self.btnRevive.caption:SetTextColor(1,1,1,1)
        self.btnBuffCov.caption:SetTextColor(1,1,1,1)
        self.btnVulnCov.caption:SetTextColor(1,1,1,1)
        self.btnInterrupt.caption:SetTextColor(1,1,1,1)
        self.btnEnemyTaken.caption:SetTextColor(1,1,1,1)
    end

    -- 重置左侧菜单按钮颜色
    self.btnOverall.caption:SetTextColor(1,1,1,1)
    self.btnCurrent.caption:SetTextColor(1,1,1,1)
    self.btnSmall.caption:SetTextColor(1,1,1,1)
    if ShaguDPS.hasNampower then
        self.btnBossMenu.caption:SetTextColor(1,1,1,1)
        self.btnBossSummaryMenu.caption:SetTextColor(1,1,1,1)
    end

    -- 高亮当前选中的左侧菜单按钮
    if isBossView then
        self.btnBossMenu.caption:SetTextColor(1,.9,0,1)
    elseif isBossSummaryView then
        self.btnBossSummaryMenu.caption:SetTextColor(1,.9,0,1)
    elseif isRecentFightView then
        self.btnRecentFights.caption:SetTextColor(1,.9,0,1)
    elseif isSmallFight then
        self.btnSmall.caption:SetTextColor(1,.9,0,1)
    else
        if segmentType == 0 then
            self.btnOverall.caption:SetTextColor(1,.9,0,1)
        else
            self.btnCurrent.caption:SetTextColor(1,.9,0,1)
        end
    end

    -- 根据 highlightView 设置对应按钮高亮
    local viewToButton = {
        [1] = "btnDamage", [2] = "btnDPS", [3] = "btnHeal", [4] = "btnHPS",
        [5] = "btnEffHeal", [6] = "btnOverHeal", [7] = "btnDeath",
        [8] = "btnSpellcast", [9] = "btnFriendlyFire", [10] = "btnDispel",
        [11] = "btnThreat", [13] = "btnSunder", [14] = "btnDamageTaken",
        [16] = "btnEnergize", [17] = "btnInvalidDamage", [18] = "btnHealTaken",
        [19] = "btnRevive", [20] = "btnBuffCov", [21] = "btnInterrupt",
        [22] = "btnEnemyTaken", [24] = "btnVulnCov",
    }
    if viewToButton[highlightView] then
        self[viewToButton[highlightView]].caption:SetTextColor(1,.9,0,1)
    end

    self:SetWidth((config[wid].width or 177))
    local barsCount = config[wid].bars or 8
    local totalHeight = config.height + config.spacing
    local winHeight
    if barsCount == 0 then
        winHeight = 22 + (config[wid].bars == 0 and 2 or 3)
    else
        winHeight = totalHeight * barsCount + 22 + 3
    end
    if barsCount > 0 then
        self:SetHeight(winHeight)
    end

    for id, bar in pairs(self.bars) do
        bar.lowerBar:Hide()
        bar:Hide()
    end

    -- 根据右侧菜单开/关状态显示/隐藏按钮
    local rightMenuShouldShow = self.rightMenuVisible == true
    if rightMenuShouldShow then
        self:ArrangeRightMenu()
    else
        for name, template in pairs(menubuttons) do
            if template[6] == "view" then
                local button = self["btn"..name]
                if button then button:Hide() end
            end
        end
    end

    -- 更新左侧按钮位置
    local leftButtons = {}
    for name, template in pairs(menubuttons) do
        if template[6] == "segment" then
            table.insert(leftButtons, { name = name, idx = template[1] })
        end
    end
    table.sort(leftButtons, function(a,b) return a.idx < b.idx end)
    for _, entry in ipairs(leftButtons) do
        local button = self["btn"..entry.name]
        if button then
            local yOffset = (config.menu_grow_upwards == 1) and (17 + entry.idx * 14) or (-17 - entry.idx * 14)
            button:SetPoint("CENTER", self.title, "CENTER", -25.5, yOffset)
        end
    end

    local isHealView = (config[wid].view == 3 or config[wid].view == 4 or config[wid].view == 5 or config[wid].view == 6)
    local isDeathView = (config[wid].view == 7)
    local isSpellcastView = (config[wid].view == 8)
    local isFriendlyFireView = (config[wid].view == 9)
    local isDispelView = (config[wid].view == 10)

    -- 选择数据源
    if isThreatView then
        self.segment = data.threat or {}
        if config.show_only_tank_and_self_in_threat == 1 then
            local filtered = {}
            local playerName = UnitName("player")
            for name, uData in pairs(self.segment) do
                if uData.tank == true or name == playerName then
                    filtered[name] = uData
                end
            end
            self.segment = filtered
        end
    elseif isRecentFightView then
        if currentRecentFight then
            local statType = config[wid].boss_stat_view or 1
            if statType == 1 then self.segment = currentRecentFight.damage
            elseif statType == 2 then self.segment = currentRecentFight.damage
            elseif statType == 3 then self.segment = currentRecentFight.heal
            elseif statType == 4 then self.segment = currentRecentFight.heal
            elseif statType == 5 then self.segment = currentRecentFight.heal
            elseif statType == 6 then self.segment = currentRecentFight.heal
            elseif statType == 7 then self.segment = currentRecentFight.death
            elseif statType == 8 then self.segment = currentRecentFight.spellcast
            elseif statType == 9 then self.segment = currentRecentFight.friendly_fire
            elseif statType == 10 then self.segment = currentRecentFight.dispel
            elseif statType == 11 then self.segment = currentRecentFight.sunder
            elseif statType == 12 then self.segment = currentRecentFight.damage_taken
            elseif statType == 13 then self.segment = currentRecentFight.energize
            elseif statType == 14 then self.segment = currentRecentFight.invalid_damage
            elseif statType == 15 then self.segment = currentRecentFight.heal_taken
            elseif statType == 16 then self.segment = currentRecentFight.revive
            elseif statType == 17 then self.segment = currentRecentFight.buff_coverage
            elseif statType == 18 then self.segment = currentRecentFight.interrupt
            elseif statType == 19 then self.segment = currentRecentFight.enemy_damage_taken
            elseif statType == 20 then self.segment = currentRecentFight.weakness_coverage
            else self.segment = currentRecentFight.damage end
        else
            self.segment = {}
        end
    elseif isBossView then
        if currentBossFight then
            local statType = config[wid].boss_stat_view or 1
            if statType == 1 then self.segment = currentBossFight.damage
            elseif statType == 2 then self.segment = currentBossFight.damage
            elseif statType == 3 then self.segment = currentBossFight.heal
            elseif statType == 4 then self.segment = currentBossFight.heal
            elseif statType == 5 then self.segment = currentBossFight.heal
            elseif statType == 6 then self.segment = currentBossFight.heal
            elseif statType == 7 then self.segment = currentBossFight.death
            elseif statType == 8 then self.segment = currentBossFight.spellcast
            elseif statType == 9 then self.segment = currentBossFight.friendly_fire
            elseif statType == 10 then self.segment = currentBossFight.dispel
            elseif statType == 11 then self.segment = currentBossFight.sunder
            elseif statType == 12 then self.segment = currentBossFight.damage_taken
            elseif statType == 13 then self.segment = currentBossFight.energize
            elseif statType == 14 then self.segment = currentBossFight.invalid_damage
            elseif statType == 15 then self.segment = currentBossFight.heal_taken
            elseif statType == 16 then self.segment = currentBossFight.revive
            elseif statType == 17 then self.segment = currentBossFight.buff_coverage
            elseif statType == 18 then self.segment = currentBossFight.interrupt
            elseif statType == 19 then self.segment = currentBossFight.enemy_damage_taken
            elseif statType == 20 then self.segment = currentBossFight.weakness_coverage
            else self.segment = currentBossFight.damage end
        else
            self.segment = {}
        end
    elseif isBossSummaryView then
        local statType = config[wid].boss_stat_view or 1
        self.segment = GetBossSummaryData(statType)
    elseif isSunderView then
        if segmentType == 0 then self.segment = data.sunder[0]
        elseif segmentType == 2 then self.segment = data.small_fight.sunder
        else self.segment = ShaguDPS.cached_current_sunder or data.sunder[1] end
    elseif isDamageTakenView then
        if segmentType == 0 then self.segment = data.damage_taken[0]
        elseif segmentType == 2 then self.segment = data.small_fight.damage_taken
        else self.segment = ShaguDPS.cached_current_damage_taken or data.damage_taken[1] end
    elseif isEnergizeView then
        if segmentType == 0 then self.segment = data.energize[0]
        elseif segmentType == 2 then self.segment = data.small_fight.energize
        else self.segment = ShaguDPS.cached_current_energize or data.energize[1] end
    elseif isInvalidDamageView then
        if segmentType == 0 then self.segment = data.invalid_damage[0]
        elseif segmentType == 2 then self.segment = data.small_fight.invalid_damage
        else self.segment = ShaguDPS.cached_current_invalid_damage or data.invalid_damage[1] end
    elseif isHealTakenView then
        if segmentType == 0 then self.segment = data.heal_taken[0]
        elseif segmentType == 2 then self.segment = data.small_fight.heal_taken
        else self.segment = ShaguDPS.cached_current_heal_taken or data.heal_taken[1] end
    elseif isReviveView then
        if segmentType == 0 then self.segment = data.revive[0]
        elseif segmentType == 2 then self.segment = data.small_fight.revive
        else self.segment = ShaguDPS.cached_current_revive or data.revive[1] end
    elseif isBuffCoverageView then
        if segmentType == 0 then self.segment = data.buff_coverage[0]
        elseif segmentType == 2 then self.segment = data.small_fight.buff_coverage
        else self.segment = ShaguDPS.cached_current_buff_coverage or data.buff_coverage[1] end
    elseif isInterruptView then
        if segmentType == 0 then self.segment = data.interrupt[0]
        elseif segmentType == 2 then self.segment = data.small_fight.interrupt
        else self.segment = ShaguDPS.cached_current_interrupt or data.interrupt[1] end
    elseif isEnemyTakenView then
        if segmentType == 0 then self.segment = data.enemy_damage_taken[0]
        elseif segmentType == 2 then self.segment = data.small_fight.enemy_damage_taken or {}
        else self.segment = ShaguDPS.cached_current_enemy_damage_taken or data.enemy_damage_taken[1] end
    elseif isVulnCoverageView then
        if segmentType == 0 then self.segment = data.weakness_coverage[0]
        elseif segmentType == 2 then self.segment = data.small_fight.weakness_coverage or {}
        else self.segment = ShaguDPS.cached_current_weakness_coverage or data.weakness_coverage[1] end
    else
        -- 普通视图
        local dataSource
        if segmentType == 0 then
            if isHealView then
                dataSource = data.heal[0]
            elseif isDeathView then
                dataSource = data.death[0]
            elseif isSpellcastView then
                dataSource = data.spellcast[0]
            elseif isFriendlyFireView then
                dataSource = data.friendly_fire[0]
            elseif isDispelView then
                dataSource = data.dispel[0]
            else
                dataSource = data.damage[0]
            end
        elseif segmentType == 2 then
            if isHealView then
                dataSource = data.small_fight.heal
            elseif isDeathView then
                dataSource = data.small_fight.death
            elseif isSpellcastView then
                dataSource = data.small_fight.spellcast
            elseif isFriendlyFireView then
                dataSource = data.small_fight.friendly_fire
            elseif isDispelView then
                dataSource = data.small_fight.dispel
            else
                dataSource = data.small_fight.damage
            end
        else
            if isHealView then
                dataSource = ShaguDPS.cached_current_heal or data.heal[1]
            elseif isDeathView then
                dataSource = ShaguDPS.cached_current_death or data.death[1]
            elseif isSpellcastView then
                dataSource = ShaguDPS.cached_current_spellcast or data.spellcast[1]
            elseif isFriendlyFireView then
                dataSource = ShaguDPS.cached_current_friendly_fire or data.friendly_fire[1]
            elseif isDispelView then
                dataSource = ShaguDPS.cached_current_dispel or data.dispel[1]
            else
                dataSource = ShaguDPS.cached_current_damage or data.damage[1]
            end
        end
        self.segment = dataSource
    end

    local template
    if isBossView or isBossSummaryView or isRecentFightView then
        local statType = config[wid].boss_stat_view or 1
        local viewMap = {
            [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5,
            [6] = 6, [7] = 7, [8] = 8, [9] = 9, [10] = 10,
            [11] = 13, [12] = 14, [13] = 16, [14] = 17,
            [15] = 18, [16] = 19, [17] = 20, [18] = 21, [19] = 22,
            [20] = 24, [21] = 25,
        }
        local tplIdx = viewMap[statType] or 1
        template = view_templates[tplIdx]
    else
        template = view_templates[config[wid].view]
    end
    local sort = sort_algorithms[template.sort]

    local reportTitle = nil
    local reportData = {}
    if report then
        local name = template.name
        local seg = segmentType == 0 and "全程" or (segmentType == 2 and "小怪" or "当前")
        if isThreatView then seg = "当前目标" end
        if isBossView then
            if currentBossFight then name = currentBossFight.name else name = "无记录" end
            seg = "BOSS"
        end
        if isBossSummaryView then name = "BOSS汇总"; seg = "" end
        if isSunderView then name = "破甲"; seg = segmentType == 0 and "全程" or (segmentType == 2 and "小怪" or "当前") end
        if isDamageTakenView then name = "承受伤害"; seg = segmentType == 0 and "全程" or (segmentType == 2 and "小怪" or "当前") end
        if isEnergizeView then name = "能量回复"; seg = segmentType == 0 and "全程" or (segmentType == 2 and "小怪" or "当前") end
        if isInvalidDamageView then name = "无效伤害"; seg = segmentType == 0 and "全程" or (segmentType == 2 and "小怪" or "当前") end
        if isHealTakenView then name = "受到治疗"; seg = segmentType == 0 and "全程" or (segmentType == 2 and "小怪" or "当前") end
        if isReviveView then name = "复活"; seg = segmentType == 0 and "全程" or (segmentType == 2 and "小怪" or "当前") end
        reportTitle = "ShaguDPS - " .. seg .. " " .. name .. ":"
    end

    -- 计算 DPS 分母
    local dpsTotalTime = 1
    if isBossView then
        if currentBossFight and currentBossFight.duration then
            dpsTotalTime = currentBossFight.duration
        end
    elseif isBossSummaryView then
        dpsTotalTime = (data.total_combat_time or 0) - (ShaguDPS.small_fight_total_time or 0)
    elseif segmentType == 0 then
        dpsTotalTime = data.total_combat_time or 0
        if ShaguDPS.Combat() and data.combat_start_time > 0 then
            dpsTotalTime = dpsTotalTime + (GetTime() - data.combat_start_time)
        end
    elseif segmentType == 2 then
        dpsTotalTime = ShaguDPS.small_fight_total_time or 0
    else
        if ShaguDPS.Combat() and data.combat_start_time > 0 then
            dpsTotalTime = GetTime() - data.combat_start_time
        else
            dpsTotalTime = data.last_fight_duration or 0
        end
    end

    local useEDPSFallback = false
    if dpsTotalTime < 1 then
        useEDPSFallback = true
        dpsTotalTime = 1
    end

    local effectiveViewId = config[wid].view
    if isBossView or isBossSummaryView or isRecentFightView then
        local bossStatMap = bossStatMapFull
        effectiveViewId = bossStatMap[config[wid].boss_stat_view or 1] or 1
    end
    self.values = self.GetCaps(self.segment, self.values, isHealTakenView, isBuffCoverageView, segmentType, dpsTotalTime, not useEDPSFallback and ShaguDPS.config.use_total_cbt_for_dps == 1, effectiveViewId, isVulnCoverageView)

    if isInterruptView then
        self.values.interrupt_best = 0
        self.values.interrupt_all = 0
        for _, u in pairs(self.segment) do
            local total = u and u._total or 0
            if total > self.values.interrupt_best then
                self.values.interrupt_best = total
            end
            self.values.interrupt_all = self.values.interrupt_all + total
        end
    end
    local i = 1
    local sortTotalTime = nil
    if config.use_total_cbt_for_dps == 1
        and (effectiveViewId == 1 or effectiveViewId == 2 or effectiveViewId == 9 or effectiveViewId == 17)
        and dpsTotalTime > 0 then
        sortTotalTime = dpsTotalTime
    end
    for name, unitdata in spairs(self.segment, sort, sortTotalTime) do
        self.values.name = name
        local totalTimeOverride = nil
        if isBuffCoverageView or isVulnCoverageView then
            if config[wid].view == 15 then
                local totalBossTime = (data.total_combat_time or 0) - (ShaguDPS.small_fight_total_time or 0)
                if totalBossTime > 0 then
                    totalTimeOverride = totalBossTime
                else
                    totalTimeOverride = 1
                end
            elseif segmentType == 2 then
                totalTimeOverride = ShaguDPS.small_fight_total_time or 1
            end
        end

        self.values = self.GetData(unitdata, self.values, isHealTakenView, effectiveViewId, isBuffCoverageView, segmentType, totalTimeOverride, isVulnCoverageView)

        local applyTotalCBT = config.use_total_cbt_for_dps == 1
            and (effectiveViewId == 1 or effectiveViewId == 2 or effectiveViewId == 9 or effectiveViewId == 17)

        if applyTotalCBT then
            if useEDPSFallback or dpsTotalTime <= 0 then
                local ctime = unitdata._ctime or 1
                self.values.value_persecond = round(self.values.value / ctime, 1)
            else
                self.values.value_persecond = round(self.values.value / dpsTotalTime, 1)
            end
        end

        local bar = i - self.scroll
        if bar >= 1 and bar <= (config[wid].bars or 8) then
            self.bars[bar] = not force and self.bars[bar] or CreateBar(self, bar)
            self.bars[bar].title = self.values.name
            self.bars[bar].unit = name

            -- 设置职业图标：有职业则显示对应图标，否则隐藏贴图（保留文字对齐）
            if self.bars[bar].classIcon then
                local classToken = resolveClassToken(name)
                if classToken and classIcons[classToken] and config.show_class_icon ~= 0 then
                    self.bars[bar].classIcon:SetTexture(classIconTexture)
                    self.bars[bar].classIcon:SetTexCoord(unpack(classIcons[classToken]))
                    self.bars[bar].classIcon:Show()
                    if self.bars[bar].iconBg then self.bars[bar].iconBg:Show() end
                else
                    self.bars[bar].classIcon:SetTexture(nil)
                    self.bars[bar].classIcon:Hide()
                    if self.bars[bar].iconBg then self.bars[bar].iconBg:Hide() end
                end
            end

            if isThreatView then
                local maxPerc = self.values.perc_best or 100
                if maxPerc < 100 then maxPerc = 100 end
                self.bars[bar]:SetMinMaxValues(0, maxPerc)
                self.bars[bar]:SetValue(self.values.perc)
            elseif isDamageTakenView then
                self.bars[bar]:SetMinMaxValues(0, self.values.damage_taken_best > 0 and self.values.damage_taken_best or 1)
            elseif isHealTakenView then
                self.bars[bar]:SetMinMaxValues(0, self.values.best > 0 and self.values.best or 1)
            elseif isReviveView then
                self.bars[bar]:SetMinMaxValues(0, self.values.revive_best > 0 and self.values.revive_best or 1)
            else
                local barMax = self.values[template.bar_max]
                if type(barMax) ~= "number" or barMax <= 0 then barMax = 1 end
                self.bars[bar]:SetMinMaxValues(0, barMax)
            end
            if not isThreatView then
                if not isDamageTakenView then
                    self.bars[bar]:SetValue(self.values[template.bar_val])
                else
                    self.bars[bar]:SetValue(self.values.damage_taken_value)
                end
            end
            if template.bar_lower_max and template.bar_lower_val then
                self.bars[bar].lowerBar:SetMinMaxValues(0, self.values[template.bar_lower_max])
                self.bars[bar].lowerBar:SetValue(self.values[template.bar_lower_val])
                self.bars[bar].lowerBar:Show()
            else
                self.bars[bar].lowerBar:Hide()
            end
            self.bars[bar]:SetStatusBarColor(self.values.color.r, self.values.color.g, self.values.color.b)
            if self.bars[bar].lowerBar:IsShown() then
                self.bars[bar].lowerBar:SetStatusBarColor(self.values.color.r, self.values.color.g, self.values.color.b, 0.7)
            end
            self.bars[bar].textLeft:SetText(i .. ". " .. self.values.name)

            local a = template.bar_string_params
            local bar_string = template.bar_string
            local bar_params = a

            if config[wid].view == 1 or ((isBossView or isBossSummaryView or isRecentFightView) and (config[wid].boss_stat_view or 1) == 1) then
                local showDps = config.show_dps_in_damage == 1
                local showOverkill = config.show_overkill == 1
                local overkill = self.values.overkill or 0
                if showOverkill and overkill > 0 then
                    if showDps then
                        bar_string = "|cffff8888+%s|r (%s)  %s (%.1f%%)"
                        bar_params = { "overkill", "value_persecond", "value", "percent" }
                    else
                        bar_string = "|cffff8888+%s|r %s (%.1f%%)"
                        bar_params = { "overkill", "value", "percent" }
                    end
                else
                    if showDps then
                        bar_string = "(%s)  %s (%.1f%%)"
                        bar_params = { "value_persecond", "value", "percent" }
                    else
                        bar_string = "%s (%.1f%%)"
                        bar_params = { "value", "percent" }
                    end
                end
            end

            local actualView = config[wid].view
            if isBossView or isBossSummaryView or isRecentFightView then
                local bossStatMap = bossStatMapFull
                actualView = bossStatMap[config[wid].boss_stat_view or 1] or 1
            end

            if isEnemyTakenView then
                if config.show_overkill == 1 and (self.values.enemy_taken_overkill or 0) > 0 then
                    bar_string = "|cffff8888+%s|r %s (%.1f%%)"
                    bar_params = { "enemy_taken_overkill", "enemy_taken_value", "enemy_taken_percent" }
                else
                    bar_string = "%s (%.1f%%)"
                    bar_params = { "enemy_taken_value", "enemy_taken_percent" }
                end
            end

            if actualView == 10 and (self.values.dispel_wrong or 0) > 0 then
                bar_string = "|cffff8888(+%s)|r " .. bar_string
                local dispelParams = { "dispel_wrong" }
                for _, p in ipairs(bar_params) do
                    table.insert(dispelParams, p)
                end
                bar_params = dispelParams
            end

            if config.show_hps_in_heal == 1 then
                if actualView == 3 then
                    bar_string = "|cffcc8888+%s|r (%s) %s (%.1f%%)"
                    bar_params = { "uneffective_value", "value_persecond", "effective_value", "total_heal_percent" }
                elseif actualView == 5 then
                    bar_string = "(%s) %s (%.1f%%)"
                    bar_params = { "effective_value_persecond", "effective_value", "total_effective_percent" }
                elseif actualView == 6 then
                    bar_string = "(%s) %s (%.1f%%)"
                    bar_params = { "uneffective_value_persecond", "uneffective_value", "total_uneffective_percent" }
                end
            end

            if isSunderView then
                bar_string = "%s"
                bar_params = { "sunder_value" }
            end

            if isReviveView then
                bar_string = "%s (%.1f%%)"
                bar_params = { "revive_value", "percent" }
            end

            if isBuffCoverageView then
                bar_string = "Buff: %d - Debuff: %d ( Total: %d )"
                bar_params = { "buff_count", "debuff_count", "total_count" }
            end

            if isVulnCoverageView then
                bar_string = "%d (%.1f%%)"
                bar_params = { "total_count", "avg_cov" }
            end

            local params = {}
            for _, param in ipairs(bar_params) do
                local val = self.values[param]
                if type(val) == "number" and (
                    param == "value" or
                    param == "value_persecond" or
                    param == "effective_value" or
                    param == "effective_value_persecond" or
                    param == "uneffective_value" or
                    param == "uneffective_value_persecond" or
                    param == "threat_value" or
                    param == "enemy_taken_value" or
                    param == "enemy_taken_overkill" or
                    param == "damage_taken_value" or
                    param == "overkill"
                ) then
                    val = formatBarNumber(val)
                end
                table.insert(params, val)
            end
            local line = string.format(bar_string, unpack(params))
            self.bars[bar].textRight:SetText(line)

            self.bars[bar]:Show()
            if report and i <= config.report_lines then
                local chat = string.format(template.chat_string,
                    self.values[a[1]], self.values[a[2]], self.values[a[3]], self.values[a[4]], self.values[a[5]])
                table.insert(reportData, i .. ". " .. self.values.name .. " " .. chat)
            end
        end
        i = i + 1
    end

    if report then
        if reportTitle then table.insert(reportData, 1, reportTitle) end
        if table.getn(reportData) > 0 then startReport(reportData) end
    end

    if not isBossView and not isRecentFightView then
        ForceHideBossSubMenu(self.btnSegment)
    end

    self:ApplyVisibilityOverride()
end

-- ============================================================================
-- 26. 窗口大小调整
-- ============================================================================

local function Resize(self)
    local wid = self:GetID()
    local width = self:GetWidth()
    local height = self:GetTop() - self:GetBottom()
    local bars = (height - 22) / (config.height + config.spacing)
    bars = math.floor(bars)
    if bars < 0 then bars = 0 end
    config[wid].width = width
    if config[wid].bars ~= bars then
        config[wid].bars = bars
        self:Refresh()
    end
end

-- ============================================================================
-- 27. 创建单个主窗口
-- ============================================================================

local function CreateWindow(wid)
    config[wid] = config[wid] or {}
    config[wid].bars = config[wid].bars or 8
    config[wid].width = config[wid].width or 177
    config[wid].segment = config[wid].segment or 1
    config[wid].view = config[wid].view or 1
    config[wid].boss_stat_view = config[wid].boss_stat_view or 1

    local frame = CreateFrame("Frame", "ShaguDPSWindow" .. (wid == 1 and "" or wid), UIParent)
    frame.scroll = 0
    frame.rightMenuVisible = false
    frame.GetCaps = GetCaps
    frame.GetData = GetData
    frame.Refresh = Refresh
    frame.Resize = Resize

    frame.LoadPosition = function()
        local pos = config[frame:GetID()] and config[frame:GetID()].pos
        if pos and type(pos) == "table" and tonumber(pos[1]) and tonumber(pos[2]) then
            local x, y
            if pos.rel then
                x = pos[1] * GetScreenWidth()
                y = pos[2] * GetScreenHeight()
            else
                x, y = pos[1], pos[2]
                local sw, sh = GetScreenWidth(), GetScreenHeight()
                config[frame:GetID()].pos = { x / sw, y / sh, rel = true }
                if ShaguDPS.SaveConfig then ShaguDPS.SaveConfig() end
            end
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
        else
            frame:ClearAllPoints()
            frame:SetPoint("RIGHT", UIParent, "RIGHT", -100, -100)
        end
    end

    frame.ApplyVisibilityOverride = function(self)
        if not self then return end
        local wid = self:GetID()
        if config.visible ~= 1 then return end
        -- 非战斗情况隐藏窗口
        if config.hide_out_of_combat == 1 and not ShaguDPS.Combat(true) then
            self:Hide()
            return
        end
        -- 非队伍情况隐藏窗口（队伍包含团队和小队）
        if config.hide_out_of_party == 1 then
            local inPartyOrRaid = (GetNumPartyMembers() > 0 or GetNumRaidMembers() > 0)
            if not inPartyOrRaid then
                self:Hide()
                return
            end
        end
        local condition = config.hide_nondefault_threat_out_of_combat == 1
        if condition and wid ~= 1 and config[wid] and config[wid].view == 11 then
            local inPartyOrRaid = (GetNumPartyMembers() > 0 or GetNumRaidMembers() > 0)
            local inCombat = ShaguDPS.Combat(true)
            if not inPartyOrRaid or not inCombat then
                self:Hide()
                return
            end
        end
        self:Show()
    end

    frame:SetID(wid)
    frame:EnableMouse(true)
    frame:EnableMouseWheel(1)
    frame:SetResizable(true)
    frame:SetMinResize(177, 22)
    frame:RegisterForDrag("LeftButton")
    frame:SetMovable(true)
    frame:SetScript("OnDragStart", function()
        if config.lock == 0 then frame:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        if not config[frame:GetID()] then config[frame:GetID()] = {} end
        local x, y = frame:GetCenter()
        local sw, sh = GetScreenWidth(), GetScreenHeight()
        config[frame:GetID()].pos = { x / sw, y / sh, rel = true }
        if ShaguDPS.SaveConfig then ShaguDPS.SaveConfig() end
    end)

    frame:SetScript("OnMouseWheel", barScrollWheel)
    frame:SetClampedToScreen(true)

    frame:SetScript("OnUpdate", function()
        if this.sizing then this:Resize() end
        local now = GetTime()
        if ( this.tick or 1) > now then return else this.tick = now + .2 end
        if config.lock == 0 and MouseIsOver(this) then
            this.btnResize:SetAlpha(.5)
        else
            this.btnResize:SetAlpha(0)
        end
        -- 标题栏自动隐藏：悬停标题区/标题按钮时显示，菜单打开时保持显示
        if this.SetTitleShown then
            if config.title_autohide == 1 then
                local menuOpen = this.rightMenuVisible or (this.btnCurrent and this.btnCurrent:IsShown())
                local over = MouseIsOver(this.titleHotzone)
                if not over then
                    for _, btn in ipairs(this.titleButtons) do
                        if btn:IsShown() and MouseIsOver(btn) then
                            over = true
                            break
                        end
                    end
                end
                if menuOpen then over = true end
                this:SetTitleShown(over)
            else
                this:SetTitleShown(true)
            end
        end
        if this.needs_refresh then
            this.needs_refresh = nil
            this:Refresh()
        end
    end)

    frame:RegisterEvent("PLAYER_LOGIN")
    frame:SetScript("OnEvent", frame.LoadPosition)
    frame.LoadPosition()

    frame.title = frame:CreateTexture(nil, "NORMAL")
    frame.title:SetTexture(0,0,0,.6)
    frame.title:SetHeight(20)
    frame.title:SetPoint("TOPLEFT", 2, -2)
    frame.title:SetPoint("TOPRIGHT", -2, -2)

    -- 左侧分段/视图选择按钮
    frame.btnSegment = CreateFrame("Button", "ShaguDPSDamage", frame)
    frame.btnSegment:SetPoint("RIGHT", frame.title, "CENTER", -.5, 0)
    frame.btnSegment:SetFrameStrata("MEDIUM")
    frame.btnSegment:SetHeight(16)
    frame.btnSegment:SetWidth(50)
    frame.btnSegment:SetBackdrop(backdrop)
    frame.btnSegment:SetBackdropColor(.2,.2,.2,1)
    frame.btnSegment:SetBackdropBorderColor(.4,.4,.4,1)
    frame.btnSegment.caption = frame.btnSegment:CreateFontString("ShaguDPSTitle", "OVERLAY", "GameFontWhite")
    frame.btnSegment.caption:SetFont(STANDARD_TEXT_FONT, 9)
    frame.btnSegment.caption:SetText("当前")
    frame.btnSegment.caption:SetAllPoints()
    frame.btnSegment.tooltip = { "选择时间段/视图", "|cffffffff当前, 全程, 小怪, BOSS, BOSS汇总" }
    frame.btnSegment:SetScript("OnEnter", btnEnter)
    frame.btnSegment:SetScript("OnLeave", btnLeave)
    frame.btnSegment:SetScript("OnClick", function()
        frame.rightMenuVisible = false
        for bname, btntmpl in pairs(menubuttons) do
            if btntmpl[6] == "view" then
                frame["btn"..bname]:Hide()
            end
        end
        if frame.btnOverall:IsShown() then
            frame.btnOverall:Hide()
            frame.btnCurrent:Hide()
            frame.btnSmall:Hide()
            if frame.btnBossMenu then frame.btnBossMenu:Hide() end
            if frame.btnBossSummaryMenu then frame.btnBossSummaryMenu:Hide() end
            if frame.btnRecentFights then frame.btnRecentFights:Hide() end
        else
            frame.btnOverall:Show()
            frame.btnCurrent:Show()
            frame.btnSmall:Show()
            if ShaguDPS.hasNampower then
                frame.btnBossMenu:Show()
                frame.btnBossSummaryMenu:Show()
                frame.btnRecentFights:Show()
            end
        end
    end)

    -- 左侧菜单项：全程
    frame.btnOverall = CreateFrame("Button", "ShaguDPSOverall", frame)
    local yOffsetOverall = -17 - 1 * 14
    if config.menu_grow_upwards == 1 then
        yOffsetOverall = 17 + 1 * 14
    end
    frame.btnOverall:SetPoint("CENTER", frame.title, "CENTER", -25.5, yOffsetOverall)
    frame.btnOverall:SetFrameStrata("HIGH")
    frame.btnOverall:SetHeight(16)
    frame.btnOverall:SetWidth(50)
    frame.btnOverall:SetBackdrop(backdrop)
    frame.btnOverall:SetBackdropColor(.2,.2,.2,1)
    frame.btnOverall:SetBackdropBorderColor(.4,.4,.4,1)
    frame.btnOverall:Hide()
    frame.btnOverall.caption = frame.btnOverall:CreateFontString("ShaguDPSOverallTitle", "OVERLAY", "GameFontWhite")
    frame.btnOverall.caption:SetFont(STANDARD_TEXT_FONT, 9)
    frame.btnOverall.caption:SetText("全程")
    frame.btnOverall.caption:SetAllPoints()
    frame.btnOverall.tooltip = { "全程数据", "|cffffffff显示全程的总数据" }
    frame.btnOverall:SetScript("OnEnter", btnEnter)
    frame.btnOverall:SetScript("OnLeave", btnLeave)
    frame.btnOverall:SetScript("OnClick", function()
        local wid = frame:GetID()
        if config[wid].view == 12 or config[wid].view == 15 or config[wid].view == 23 then
            config[wid].view = bossStatToView[config[wid].boss_stat_view or 1] or 1
        end
        config[wid].segment = 0
        frame.scroll = 0
        frame:Refresh(true)
        frame.btnOverall:Hide()
        frame.btnCurrent:Hide()
        frame.btnSmall:Hide()
        if ShaguDPS.hasNampower then
            frame.btnBossMenu:Hide()
            frame.btnBossSummaryMenu:Hide()
            frame.btnRecentFights:Hide()
        end
    end)

    -- 左侧菜单项：当前
    frame.btnCurrent = CreateFrame("Button", "ShaguDPSCurrent", frame)
    local yOffsetCurrent = -17 - 0 * 14
    if config.menu_grow_upwards == 1 then
        yOffsetCurrent = 17 + 0 * 14
    end
    frame.btnCurrent:SetPoint("CENTER", frame.title, "CENTER", -25.5, yOffsetCurrent)
    frame.btnCurrent:SetFrameStrata("HIGH")
    frame.btnCurrent:SetHeight(16)
    frame.btnCurrent:SetWidth(50)
    frame.btnCurrent:SetBackdrop(backdrop)
    frame.btnCurrent:SetBackdropColor(.2,.2,.2,1)
    frame.btnCurrent:SetBackdropBorderColor(.4,.4,.4,1)
    frame.btnCurrent:Hide()
    frame.btnCurrent.caption = frame.btnCurrent:CreateFontString("ShaguDPSCurrentTitle", "OVERLAY", "GameFontWhite")
    frame.btnCurrent.caption:SetFont(STANDARD_TEXT_FONT, 9)
    frame.btnCurrent.caption:SetText("当前")
    frame.btnCurrent.caption:SetAllPoints()
    frame.btnCurrent.tooltip = { "当前战斗数据", "|cffffffff显示当前战斗的数据" }
    frame.btnCurrent:SetScript("OnEnter", btnEnter)
    frame.btnCurrent:SetScript("OnLeave", btnLeave)
    frame.btnCurrent:SetScript("OnClick", function()
        local wid = frame:GetID()
        if config[wid].view == 12 or config[wid].view == 15 or config[wid].view == 23 then
            config[wid].view = bossStatToView[config[wid].boss_stat_view or 1] or 1
        end
        config[wid].segment = 1
        frame.scroll = 0
        frame:Refresh(true)
        frame.btnOverall:Hide()
        frame.btnCurrent:Hide()
        frame.btnSmall:Hide()
        if ShaguDPS.hasNampower then
            frame.btnBossMenu:Hide()
            frame.btnBossSummaryMenu:Hide()
            frame.btnRecentFights:Hide()
        end
    end)

    -- 左侧菜单项：小怪
    frame.btnSmall = CreateFrame("Button", "ShaguDPSSmall", frame)
    local yOffsetSmall = -17 - 2 * 14
    if config.menu_grow_upwards == 1 then
        yOffsetSmall = 17 + 2 * 14
    end
    frame.btnSmall:SetPoint("CENTER", frame.title, "CENTER", -25.5, yOffsetSmall)
    frame.btnSmall:SetFrameStrata("HIGH")
    frame.btnSmall:SetHeight(16)
    frame.btnSmall:SetWidth(50)
    frame.btnSmall:SetBackdrop(backdrop)
    frame.btnSmall:SetBackdropColor(.2,.2,.2,1)
    frame.btnSmall:SetBackdropBorderColor(.4,.4,.4,1)
    frame.btnSmall:Hide()
    frame.btnSmall.caption = frame.btnSmall:CreateFontString("ShaguDPSSmallTitle", "OVERLAY", "GameFontWhite")
    frame.btnSmall.caption:SetFont(STANDARD_TEXT_FONT, 9)
    frame.btnSmall.caption:SetText("小怪")
    frame.btnSmall.caption:SetAllPoints()
    frame.btnSmall.tooltip = { "小怪战斗累计", "|cffffffff显示小怪战斗的累计数据" }
    frame.btnSmall:SetScript("OnEnter", btnEnter)
    frame.btnSmall:SetScript("OnLeave", btnLeave)
    frame.btnSmall:SetScript("OnClick", function()
        local wid = frame:GetID()
        if config[wid].view == 12 or config[wid].view == 15 or config[wid].view == 23 then
            config[wid].view = bossStatToView[config[wid].boss_stat_view or 1] or 1
        end
        config[wid].segment = 2
        frame.scroll = 0
        frame:Refresh(true)
        frame.btnOverall:Hide()
        frame.btnCurrent:Hide()
        frame.btnSmall:Hide()
        if ShaguDPS.hasNampower then
            frame.btnBossMenu:Hide()
            frame.btnBossSummaryMenu:Hide()
            frame.btnRecentFights:Hide()
        end
    end)

    if ShaguDPS.hasNampower then
        -- 左侧菜单项：BOSS
        frame.btnBossMenu = CreateFrame("Button", "ShaguDPSBossMenu", frame)
        local yOffsetBoss = -17 - 3 * 14
        if config.menu_grow_upwards == 1 then
            yOffsetBoss = 17 + 3 * 14
        end
        frame.btnBossMenu:SetPoint("CENTER", frame.title, "CENTER", -25.5, yOffsetBoss)
        frame.btnBossMenu:SetFrameStrata("HIGH")
        frame.btnBossMenu:SetHeight(16)
        frame.btnBossMenu:SetWidth(50)
        frame.btnBossMenu:SetBackdrop(backdrop)
        frame.btnBossMenu:SetBackdropColor(.2,.2,.2,1)
        frame.btnBossMenu:SetBackdropBorderColor(.4,.4,.4,1)
        frame.btnBossMenu:Hide()
        frame.btnBossMenu.caption = frame.btnBossMenu:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        frame.btnBossMenu.caption:SetFont(STANDARD_TEXT_FONT, 9)
        frame.btnBossMenu.caption:SetText("BOSS")
        frame.btnBossMenu.caption:SetAllPoints()
        frame.btnBossMenu.tooltip = { "BOSS战记录", "|cffffffff查看BOSS战记录" }
        frame.btnBossMenu:SetScript("OnEnter", btnEnter)
        frame.btnBossMenu:SetScript("OnLeave", btnLeave)
        frame.btnBossMenu:SetScript("OnClick", function()
            local wid = frame:GetID()
            if config[wid].view ~= 12 and config[wid].view ~= 15 and config[wid].view ~= 23 then
                config[wid].boss_stat_view = viewToBossStat[config[wid].view] or 1
            end
            config[wid].view = 12
            ShaguDPS.current_boss_index = nil
            frame.scroll = 0
            frame:Refresh(true)
            frame.btnOverall:Hide()
            frame.btnCurrent:Hide()
            frame.btnSmall:Hide()
            if ShaguDPS.hasNampower then
                frame.btnBossMenu:Hide()
                frame.btnBossSummaryMenu:Hide()
                frame.btnRecentFights:Hide()
            end
        end)

        -- 左侧菜单项：BOSS汇总
        frame.btnBossSummaryMenu = CreateFrame("Button", "ShaguDPSBossSummaryMenu", frame)
        local yOffsetBossSum = -17 - 4 * 14
        if config.menu_grow_upwards == 1 then
            yOffsetBossSum = 17 + 4 * 14
        end
        frame.btnBossSummaryMenu:SetPoint("CENTER", frame.title, "CENTER", -25.5, yOffsetBossSum)
        frame.btnBossSummaryMenu:SetFrameStrata("HIGH")
        frame.btnBossSummaryMenu:SetHeight(16)
        frame.btnBossSummaryMenu:SetWidth(50)
        frame.btnBossSummaryMenu:SetBackdrop(backdrop)
        frame.btnBossSummaryMenu:SetBackdropColor(.2,.2,.2,1)
        frame.btnBossSummaryMenu:SetBackdropBorderColor(.4,.4,.4,1)
        frame.btnBossSummaryMenu:Hide()
        frame.btnBossSummaryMenu.caption = frame.btnBossSummaryMenu:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        frame.btnBossSummaryMenu.caption:SetFont(STANDARD_TEXT_FONT, 9)
        frame.btnBossSummaryMenu.caption:SetText("BOSS汇总")
        frame.btnBossSummaryMenu.caption:SetAllPoints()
        frame.btnBossSummaryMenu.tooltip = { "BOSS汇总", "|cffffffff查看所有BOSS战汇总数据" }
        frame.btnBossSummaryMenu:SetScript("OnEnter", btnEnter)
        frame.btnBossSummaryMenu:SetScript("OnLeave", btnLeave)
        frame.btnBossSummaryMenu:SetScript("OnClick", function()
            local wid = frame:GetID()
            if config[wid].view ~= 12 and config[wid].view ~= 15 and config[wid].view ~= 23 then
                config[wid].boss_stat_view = viewToBossStat[config[wid].view] or 1
            end
            config[wid].view = 15
            frame.scroll = 0
            frame:Refresh(true)
            frame.btnOverall:Hide()
            frame.btnCurrent:Hide()
            frame.btnSmall:Hide()
            if ShaguDPS.hasNampower then
                frame.btnBossMenu:Hide()
                frame.btnBossSummaryMenu:Hide()
                frame.btnRecentFights:Hide()
            end
            for bname in pairs(menubuttons) do
                if bname ~= "Current" and bname ~= "Overall" and bname ~= "Small" then
                    frame["btn"..bname]:Hide()
                end
            end
        end)

        -- 左侧菜单项：最近战斗
        frame.btnRecentFights = CreateFrame("Button", "ShaguDPSRecentFights", frame)
        local yOffsetRecent = -17 - 5 * 14
        if config.menu_grow_upwards == 1 then
            yOffsetRecent = 17 + 5 * 14
        end
        frame.btnRecentFights:SetPoint("CENTER", frame.title, "CENTER", -25.5, yOffsetRecent)
        frame.btnRecentFights:SetFrameStrata("HIGH")
        frame.btnRecentFights:SetHeight(16)
        frame.btnRecentFights:SetWidth(50)
        frame.btnRecentFights:SetBackdrop(backdrop)
        frame.btnRecentFights:SetBackdropColor(.2,.2,.2,1)
        frame.btnRecentFights:SetBackdropBorderColor(.4,.4,.4,1)
        frame.btnRecentFights:Hide()
        frame.btnRecentFights.caption = frame.btnRecentFights:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        frame.btnRecentFights.caption:SetFont(STANDARD_TEXT_FONT, 9)
        frame.btnRecentFights.caption:SetText("最近战斗")
        frame.btnRecentFights.caption:SetAllPoints()
        frame.btnRecentFights.tooltip = { "最近战斗", "|cffffffff查看最近5场战斗记录" }
        frame.btnRecentFights:SetScript("OnEnter", btnEnter)
        frame.btnRecentFights:SetScript("OnLeave", btnLeave)
        frame.btnRecentFights:SetScript("OnClick", function()
            frame.rightMenuVisible = false
            local wid = frame:GetID()
            if config[wid].view ~= 12 and config[wid].view ~= 15 and config[wid].view ~= 23 then
                config[wid].boss_stat_view = viewToBossStat[config[wid].view] or 1
            end
            config[wid].view = 23
            if ShaguDPS.recent_fights and table.getn(ShaguDPS.recent_fights) > 0 then
                local idx = config[wid].recent_fight_index or ShaguDPS.current_recent_index
                if not idx or idx < 1 or idx > table.getn(ShaguDPS.recent_fights) then
                    idx = table.getn(ShaguDPS.recent_fights)
                end
                config[wid].recent_fight_index = idx
                ShaguDPS.current_recent_index = idx
            end
            frame.scroll = 0
            frame:Refresh(true)
            frame.btnOverall:Hide()
            frame.btnCurrent:Hide()
            frame.btnSmall:Hide()
            if ShaguDPS.hasNampower then
                frame.btnBossMenu:Hide()
                frame.btnBossSummaryMenu:Hide()
                frame.btnRecentFights:Hide()
            end
        end)
    end

    -- 定义 ArrangeRightMenu 方法
    frame.ArrangeRightMenu = function(self)
        local enabledViews = {}
        local wid = self:GetID()
        local segType = config[wid] and config[wid].segment or 1
        local curView = config[wid] and config[wid].view or 1
        for _, viewId in ipairs(ShaguDPS.rightStatViews) do
            if ShaguDPS.IsStatEnabled(viewId) then
                table.insert(enabledViews, viewId)
            end
        end

        local menuGrow = config.menu_grow_upwards == 1

        local same = self._arrangedViews ~= nil and self._arrangedMenuGrow == menuGrow
        if same then
            if table.getn(enabledViews) ~= table.getn(self._arrangedViews) then
                same = false
            else
                for i, v in ipairs(enabledViews) do
                    if self._arrangedViews[i] ~= v then
                        same = false
                        break
                    end
                end
            end
        end

        if not same then
            self._arrangedViews = {}
            for i, v in ipairs(enabledViews) do
                self._arrangedViews[i] = v
            end
            self._arrangedMenuGrow = menuGrow

            for bname, btntmpl in pairs(menubuttons) do
                if btntmpl[6] == "view" then
                    local btn = self["btn"..bname]
                    if btn then btn:Hide() end
                end
            end

            local baseX = 25.5
            local startYOffset = menuGrow and 17 or -17
            local direction = menuGrow and 1 or -1
            local step = 14

            for idx, viewId in ipairs(enabledViews) do
                local btnName = rightViewButton[viewId]
                if btnName and self[btnName] then
                    local button = self[btnName]
                    local yOffset = startYOffset + (idx - 1) * step * direction
                    button:ClearAllPoints()
                    button:SetPoint("CENTER", self.title, "CENTER", baseX, yOffset)
                    button:Show()
                end
            end
        else
            local shown = {}
            for _, viewId in ipairs(enabledViews) do
                shown[viewId] = true
                local btnName = rightViewButton[viewId]
                local button = btnName and self[btnName]
                if button and not button:IsShown() then
                    button:Show()
                end
            end
            for bname, btntmpl in pairs(menubuttons) do
                if btntmpl[6] == "view" then
                    local btn = self["btn"..bname]
                    if btn and not shown[btntmpl[2]] then
                        btn:Hide()
                    end
                end
            end
        end
    end

    -- 右侧模式按钮
    frame.btnMode = CreateFrame("Button", "ShaguDPSDamage", frame)
    frame.btnMode:SetPoint("LEFT", frame.title, "CENTER", .5, 0)
    frame.btnMode:SetFrameStrata("MEDIUM")
    frame.btnMode:SetHeight(16)
    frame.btnMode:SetWidth(50)
    frame.btnMode:SetBackdrop(backdrop)
    frame.btnMode:SetBackdropColor(.2,.2,.2,1)
    frame.btnMode:SetBackdropBorderColor(.4,.4,.4,1)
    frame.btnMode.caption = frame.btnMode:CreateFontString("ShaguDPSTitle", "OVERLAY", "GameFontWhite")
    frame.btnMode.caption:SetFont(STANDARD_TEXT_FONT, 9)
    frame.btnMode.caption:SetText("伤害量")
    frame.btnMode.caption:SetAllPoints()
    frame.btnMode.tooltip = { "选择统计类型", "|cffffffff伤害量, DPS, 治疗量, HPS, 仇恨" .. (ShaguDPS.hasNampower and ", 有效治疗, 过量治疗, 死亡, 技能施放, 误伤, 驱散, 破甲, 承受伤害, 能量回复, 无效伤害, 受到治疗, 复活, 光环覆盖, 打断, 敌人承伤, 易伤覆盖" or "") }
    frame.btnMode:SetScript("OnEnter", btnEnter)
    frame.btnMode:SetScript("OnLeave", btnLeave)
    frame.btnMode:SetScript("OnClick", function()
        if frame.rightMenuVisible then
            frame.rightMenuVisible = false
            for bname, btntmpl in pairs(menubuttons) do
                if btntmpl[6] == "view" then
                    local btn = frame["btn"..bname]
                    if btn then btn:Hide() end
                end
            end
            frame.btnOverall:Hide()
            frame.btnCurrent:Hide()
            frame.btnSmall:Hide()
            if ShaguDPS.hasNampower then
                frame.btnBossMenu:Hide()
                frame.btnBossSummaryMenu:Hide()
                frame.btnRecentFights:Hide()
            end
        else
            frame.rightMenuVisible = true
            frame:ArrangeRightMenu()
            frame.btnOverall:Hide()
            frame.btnCurrent:Hide()
            frame.btnSmall:Hide()
            if ShaguDPS.hasNampower then
                frame.btnBossMenu:Hide()
                frame.btnBossSummaryMenu:Hide()
                frame.btnRecentFights:Hide()
            end
        end
    end)

    -- BOSS 翻页按钮
    if ShaguDPS.hasNampower then
        frame.btnBossPrev = CreateFrame("Button", nil, frame)
        frame.btnBossPrev:SetPoint("LEFT", frame.btnMode, "RIGHT", 2, 0)
        frame.btnBossPrev:SetWidth(16); frame.btnBossPrev:SetHeight(16)
        frame.btnBossPrev:SetBackdrop(backdrop); frame.btnBossPrev:SetBackdropColor(.2,.2,.2,1); frame.btnBossPrev:SetBackdropBorderColor(.4,.4,.4,1)
        frame.btnBossPrev.caption = frame.btnBossPrev:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        frame.btnBossPrev.caption:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE"); frame.btnBossPrev.caption:SetText("<"); frame.btnBossPrev.caption:SetAllPoints()
        frame.btnBossPrev.tooltip = { "上一场BOSS战", "|cffffffff切换到上一个BOSS战记录" }
        frame.btnBossPrev:SetScript("OnClick", function()
            local wid = frame:GetID()
            local curView = config[wid].view
            if curView == 23 then
                local fights = ShaguDPS.recent_fights or {}
                if table.getn(fights) == 0 then return end
                local idx = (config[wid].recent_fight_index or ShaguDPS.current_recent_index or 1) - 1
                if idx < 1 then idx = table.getn(fights) end
                config[wid].recent_fight_index = idx
                ShaguDPS.current_recent_index = idx
                frame:Refresh(true)
            else
                local fights = ShaguDPS.boss_fights
                if table.getn(fights) == 0 then return end
                local idx = (ShaguDPS.current_boss_index or 1) - 1
                if idx < 1 then idx = table.getn(fights) end
                ShaguDPS.current_boss_index = idx
                config[wid].view = 12
                frame:Refresh(true)
            end
        end)
        frame.btnBossNext = CreateFrame("Button", nil, frame)
        frame.btnBossNext:SetPoint("LEFT", frame.btnBossPrev, "RIGHT", 2, 0)
        frame.btnBossNext:SetWidth(16); frame.btnBossNext:SetHeight(16)
        frame.btnBossNext:SetBackdrop(backdrop); frame.btnBossNext:SetBackdropColor(.2,.2,.2,1); frame.btnBossNext:SetBackdropBorderColor(.4,.4,.4,1)
        frame.btnBossNext.caption = frame.btnBossNext:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        frame.btnBossNext.caption:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE"); frame.btnBossNext.caption:SetText(">"); frame.btnBossNext.caption:SetAllPoints()
        frame.btnBossNext.tooltip = { "下一场BOSS战", "|cffffffff切换到下一个BOSS战记录" }
        frame.btnBossNext:SetScript("OnClick", function()
            local wid = frame:GetID()
            local curView = config[wid].view
            if curView == 23 then
                local fights = ShaguDPS.recent_fights or {}
                if table.getn(fights) == 0 then return end
                local idx = (config[wid].recent_fight_index or ShaguDPS.current_recent_index or 1) + 1
                if idx > table.getn(fights) then idx = 1 end
                config[wid].recent_fight_index = idx
                ShaguDPS.current_recent_index = idx
                frame:Refresh(true)
            else
                local fights = ShaguDPS.boss_fights
                if table.getn(fights) == 0 then return end
                local idx = (ShaguDPS.current_boss_index or 1) + 1
                if idx > table.getn(fights) then idx = 1 end
                ShaguDPS.current_boss_index = idx
                config[wid].view = 12
                frame:Refresh(true)
            end
        end)
        frame.btnBossPrev:SetScript("OnEnter", btnEnter); frame.btnBossPrev:SetScript("OnLeave", btnLeave)
        frame.btnBossNext:SetScript("OnEnter", btnEnter); frame.btnBossNext:SetScript("OnLeave", btnLeave)
        frame.btnBossPrev:Hide(); frame.btnBossNext:Hide()
    end

    -- 创建右侧视图按钮
    for name, tmpl in pairs(menubuttons) do
        if tmpl[6] == "view" then
            local template = tmpl
            frame["btn"..name] = CreateFrame("Button", "ShaguDPS" .. name, frame)
            local button = frame["btn"..name]
            local yOffset = -17 - template[1] * 14
            if config.menu_grow_upwards == 1 then
                yOffset = 17 + template[1] * 14
            end
            button:SetPoint("CENTER", frame.title, "CENTER", template[3], yOffset)
            button:SetFrameStrata("HIGH"); button:SetHeight(16); button:SetWidth(50)
            button:SetBackdrop(backdrop); button:SetBackdropColor(.2,.2,.2,1); button:SetBackdropBorderColor(.4,.4,.4,1)
            button:Hide()
            button.caption = button:CreateFontString("ShaguDPS"..name.."Title", "OVERLAY", "GameFontWhite")
            button.caption:SetFont(STANDARD_TEXT_FONT, 9); button.caption:SetText(template[4]); button.caption:SetAllPoints()
            button.tooltip = { template[4], template[5] }
            button:SetScript("OnEnter", btnEnter); button:SetScript("OnLeave", btnLeave)
            button:SetScript("OnClick", function()
                local wid = frame:GetID()
                local curView = config[wid].view
                if (curView == 12 or curView == 15 or curView == 23) and template[6] == "view" then
                    local statMap = {
                        [1]=1, [2]=2, [3]=3, [4]=4, [5]=5,
                        [6]=6, [7]=7, [8]=8, [9]=9,
                        [10]=10, [13]=11, [14]=12, [16]=13, [17]=14, [18]=15, [19]=16, [20]=17, [21]=18, [22]=19, [24]=20, [25]=21,
                    }
                    local sv = statMap[template[2]]
                    if sv then config[wid].boss_stat_view = sv end
                else
                    config[wid][template[6]] = template[2]
                end
                frame.rightMenuVisible = false
                frame.scroll = 0
                frame:Refresh(true)
                for bname, btntmpl in pairs(menubuttons) do
                    if btntmpl[6] == "view" then
                        frame["btn"..bname]:Hide()
                    end
                end
            end)
        end
    end

    -- 发送、设置、重置、窗口增减按钮
    frame.btnAnnounce = CreateFrame("Button", "ShaguDPSReset", frame)
    frame.btnAnnounce:SetPoint("LEFT", frame.title, "LEFT", 2, 0)
    frame.btnAnnounce:SetFrameStrata("MEDIUM"); frame.btnAnnounce:SetHeight(16); frame.btnAnnounce:SetWidth(16)
    frame.btnAnnounce:SetBackdrop(backdrop); frame.btnAnnounce:SetBackdropColor(.2,.2,.2,1); frame.btnAnnounce:SetBackdropBorderColor(.4,.4,.4,1)
    frame.btnAnnounce.tooltip = { "发送到聊天", { "|cffffffff点击", "|cffaaaaaa询问发送数据"}, { "|cffffffffShift+点击", "|cffaaaaaa直接发送数据"} }
    frame.btnAnnounce.tex = frame.btnAnnounce:CreateTexture(); frame.btnAnnounce.tex:SetWidth(10); frame.btnAnnounce.tex:SetHeight(10); frame.btnAnnounce.tex:SetPoint("CENTER", 0, 0)
    frame.btnAnnounce.tex:SetTexture("Interface\\AddOns\\ShaguDPS" .. (tbc and "-tbc" or "") .. "\\img\\announce")
    frame.btnAnnounce:SetScript("OnEnter", btnEnter); frame.btnAnnounce:SetScript("OnLeave", btnLeave)
    frame.btnAnnounce:SetScript("OnClick", function()
        if IsShiftKeyDown() then
            frame:Refresh(nil, true)
        else
            local ctype = tbc and ChatFrameEditBox:GetAttribute("chatType") or ChatFrameEditBox.chatType
            local color = chatcolors[ctype] or "|cff00FAF6"
            local wid = frame:GetID()
            local curView = config[wid].view
            local statViewId = curView
            if curView == 12 or curView == 15 or curView == 23 then
                local bossStatMap = bossStatMapFull
                statViewId = bossStatMap[config[wid].boss_stat_view or 1] or 1
            end
            local name = view_templates[statViewId].name
            local text = "发送 |cffffdd00" .. name .. "|r 数据到 /" .. color..string.lower(ctype) .. "|r?"
            local dialog = StaticPopupDialogs["SHAGUMETER_QUESTION"]
            dialog.text = text
            dialog.OnAccept = function() frame:Refresh(nil, true) end
            StaticPopup_Show("SHAGUMETER_QUESTION")
        end
    end)

    frame.btnSettings = CreateFrame("Button", "ShaguDPSReset", frame)
    frame.btnSettings:SetPoint("LEFT", frame.btnAnnounce, "RIGHT", 1, 0)
    frame.btnSettings:SetFrameStrata("MEDIUM"); frame.btnSettings:SetHeight(16); frame.btnSettings:SetWidth(16)
    frame.btnSettings:SetBackdrop(backdrop); frame.btnSettings:SetBackdropColor(.2,.2,.2,1); frame.btnSettings:SetBackdropBorderColor(.4,.4,.4,1)
    frame.btnSettings.tooltip = { "设置", "|cffffffff显示设置窗口" }
    frame.btnSettings.tex = frame.btnSettings:CreateTexture(); frame.btnSettings.tex:SetWidth(10); frame.btnSettings.tex:SetHeight(10); frame.btnSettings.tex:SetPoint("CENTER", 0, 0)
    frame.btnSettings.tex:SetTexture("Interface\\AddOns\\ShaguDPS" .. (tbc and "-tbc" or "") .. "\\img\\settings")
    frame.btnSettings:SetScript("OnEnter", btnEnter); frame.btnSettings:SetScript("OnLeave", btnLeave)
    frame.btnSettings:SetScript("OnClick", function()
        ShaguDPS.ToggleSettingsWindows()
    end)

    frame.btnReset = CreateFrame("Button", "ShaguDPSReset", frame)
    frame.btnReset:SetPoint("RIGHT", frame.title, "RIGHT", -2, 0)
    frame.btnReset:SetFrameStrata("MEDIUM"); frame.btnReset:SetHeight(16); frame.btnReset:SetWidth(16)
    frame.btnReset:SetBackdrop(backdrop); frame.btnReset:SetBackdropColor(.2,.2,.2,1); frame.btnReset:SetBackdropBorderColor(.4,.4,.4,1)
    frame.btnReset.tooltip = { "清空数据", { "|cffffffff点击", "|cffaaaaaa询问清空数据"}, { "|cffffffffShift+点击", "|cffaaaaaa直接清空数据"} }
    frame.btnReset.tex = frame.btnReset:CreateTexture(); frame.btnReset.tex:SetWidth(10); frame.btnReset.tex:SetHeight(10); frame.btnReset.tex:SetPoint("CENTER", 0, 0)
    frame.btnReset.tex:SetTexture("Interface\\AddOns\\ShaguDPS" .. (tbc and "-tbc" or "") .. "\\img\\reset")
    frame.btnReset:SetScript("OnEnter", btnEnter); frame.btnReset:SetScript("OnLeave", btnLeave)
    frame.btnReset:SetScript("OnClick", function()
        if IsShiftKeyDown() then ResetData()
        else
            local dialog = StaticPopupDialogs["SHAGUMETER_QUESTION"]
            dialog.text = "你确认需要清空数据吗？"
            dialog.OnAccept = ResetData
            StaticPopup_Show("SHAGUMETER_QUESTION")
        end
    end)

    frame.btnWindow = CreateFrame("Button", "ShaguDPSReset", frame)
    frame.btnWindow:SetPoint("RIGHT", frame.btnReset, "LEFT", -1, 0)
    frame.btnWindow:SetFrameStrata("MEDIUM"); frame.btnWindow:SetHeight(16); frame.btnWindow:SetWidth(16)
    frame.btnWindow:SetBackdrop(backdrop); frame.btnWindow:SetBackdropColor(.2,.2,.2,1); frame.btnWindow:SetBackdropBorderColor(.4,.4,.4,1)
    frame.btnWindow.tex = frame.btnWindow:CreateTexture(); frame.btnWindow.tex:SetWidth(10); frame.btnWindow.tex:SetHeight(10); frame.btnWindow.tex:SetPoint("CENTER", 0, 0)
    if frame:GetID() == 1 then
        frame.btnWindow.tex:SetTexture("Interface\\AddOns\\ShaguDPS" .. (tbc and "-tbc" or "") .. "\\img\\plus")
        frame.btnWindow.tooltip = { "新增窗口", "|cffffffff创建一个新窗口" }
        frame.btnWindow:SetScript("OnClick", function()
            for i=1,10 do if not ShaguDPS.window[i] then ShaguDPS.window[i] = CreateWindow(i) ShaguDPS.window.Refresh(true) return end end
        end)
    else
        frame.btnWindow.tex:SetTexture("Interface\\AddOns\\ShaguDPS" .. (tbc and "-tbc" or "") .. "\\img\\minus")
        frame.btnWindow.tooltip = { "删除窗口", "|cffffffff删除这个窗口" }
        frame.btnWindow:SetScript("OnClick", function()
            local wid = frame:GetID()
            window[wid]:Hide(); window[wid] = nil; config[wid] = nil
            window.Refresh(true)
        end)
    end
    frame.btnWindow:SetScript("OnEnter", btnEnter); frame.btnWindow:SetScript("OnLeave", btnLeave)

    -- ============================================================================
    -- 标题栏自动隐藏：把标题栏元素挂到容器下，悬停标题区时显示
    -- ============================================================================
    frame.titleBar = CreateFrame("Frame", nil, frame)
    frame.titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    frame.titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    frame.titleBar:SetHeight(22)

    frame.titleButtons = {
        frame.btnSegment, frame.btnMode, frame.btnAnnounce,
        frame.btnSettings, frame.btnReset, frame.btnWindow,
    }
    if ShaguDPS.hasNampower and frame.btnBossPrev and frame.btnBossNext then
        table.insert(frame.titleButtons, frame.btnBossPrev)
        table.insert(frame.titleButtons, frame.btnBossNext)
    end

    -- 重新挂到容器下，便于整体显隐（按钮均为显式锚点，位置不变；title 纹理相对容器位置与原相同）
    frame.title:SetParent(frame.titleBar)
    for _, btn in ipairs(frame.titleButtons) do
        btn:SetParent(frame.titleBar)
    end

    -- 标题栏热区：自动隐藏时检测鼠标悬停（位于按钮下层，不遮挡按钮点击）
    frame.titleHotzone = CreateFrame("Frame", nil, frame)
    frame.titleHotzone:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    frame.titleHotzone:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    frame.titleHotzone:SetHeight(22)
    frame.titleHotzone:SetFrameStrata("LOW")
    frame.titleHotzone:EnableMouse(true)
    -- 热区转发拖动，保证标题栏隐藏后仍可从顶部拖动窗口
    frame.titleHotzone:SetScript("OnMouseDown", function()
        if config.lock == 0 then frame:StartMoving() end
    end)
    frame.titleHotzone:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        if not config[frame:GetID()] then config[frame:GetID()] = {} end
        local x, y = frame:GetCenter()
        local sw, sh = GetScreenWidth(), GetScreenHeight()
        config[frame:GetID()].pos = { x / sw, y / sh, rel = true }
        if ShaguDPS.SaveConfig then ShaguDPS.SaveConfig() end
    end)

    frame.titleShown = true
    frame.SetTitleShown = function(self, shown)
        if shown == self.titleShown then return end
        self.titleShown = shown
        if shown then
            self.titleBar:Show()
        else
            self.titleBar:Hide()
        end
    end

    frame.btnResize = CreateFrame("Frame", nil, frame)
    frame.btnResize:SetPoint("BOTTOMRIGHT", -3, 3); frame.btnResize:SetWidth(12); frame.btnResize:SetHeight(12); frame.btnResize:EnableMouse(1)
    frame.btnResize.tex = frame.btnResize:CreateTexture(nil, "BACKGROUND"); frame.btnResize.tex:SetAllPoints()
    frame.btnResize.tex:SetTexture("Interface\\AddOns\\ShaguDPS" .. (tbc and "-tbc" or "") .. "\\img\\resize")
    frame.btnResize:SetFrameLevel(50)
    frame.btnResize:SetScript("OnMouseDown", function()
        if not this:GetParent().sizing and config.lock == 0 then
            this:GetParent().sizing = true
            this:GetParent():StartSizing()
        end
    end)
    frame.btnResize:SetScript("OnMouseUp", function()
        this:GetParent().sizing = nil
        this:GetParent():StopMovingOrSizing()
        this:GetParent():Refresh(true)
    end)

    frame.border = CreateFrame("Frame", "ShaguDPSBorder", frame)
    frame.border:ClearAllPoints()
    frame.border:SetPoint("TOPLEFT", frame, "TOPLEFT", -1,1)
    frame.border:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 1,-1)
    frame.border:SetFrameLevel(100)

    frame.bars = {}
    frame.values = {}
    frame.buttons = { frame.btnDamage, frame.btnDPS, frame.btnHeal, frame.btnHPS, frame.btnOverall, frame.btnCurrent, frame.btnSmall }
    table.insert(frame.buttons, frame.btnThreat)
    if ShaguDPS.hasNampower then
        table.insert(frame.buttons, frame.btnBossMenu)
        table.insert(frame.buttons, frame.btnBossSummaryMenu)
        table.insert(frame.buttons, frame.btnRecentFights)
        table.insert(frame.buttons, frame.btnEffHeal); table.insert(frame.buttons, frame.btnOverHeal)
        table.insert(frame.buttons, frame.btnDeath); table.insert(frame.buttons, frame.btnSpellcast)
        table.insert(frame.buttons, frame.btnFriendlyFire); table.insert(frame.buttons, frame.btnDispel)
        table.insert(frame.buttons, frame.btnSunder)
        table.insert(frame.buttons, frame.btnDamageTaken)
        table.insert(frame.buttons, frame.btnEnergize)
        table.insert(frame.buttons, frame.btnInvalidDamage)
        table.insert(frame.buttons, frame.btnHealTaken)
        table.insert(frame.buttons, frame.btnRevive)
        table.insert(frame.buttons, frame.btnBuffCov)
        table.insert(frame.buttons, frame.btnVulnCov)
        table.insert(frame.buttons, frame.btnInterrupt)
        table.insert(frame.buttons, frame.btnEnemyTaken)
    end

    table.insert(parser.callbacks.refresh, function()
        frame.needs_refresh = true
    end)

    return frame
end

-- ============================================================================
-- 28. 初始化第一个窗口
-- ============================================================================

window[1] = window[1] or CreateWindow(1)

window.Refresh = function(force, report)
    for i=1,10 do
        if config[i] then
            window[i] = window[i] or CreateWindow(i)
            window[i]:Refresh(force, report)
        end
    end
end

window.Refresh(true)

-- ============================================================================
-- 29. 重新加载所有窗口的位置
-- ============================================================================

function ShaguDPS.LoadWindowPositions()
    for i = 1, 10 do
        local win = window[i]
        if win and win.LoadPosition then
            win:LoadPosition()
        end
    end
end

-- ============================================================================
-- 30. 监听战斗状态和队伍变化，用于威胁窗口可见性控制
-- ============================================================================

local threatVisibilityFrame = CreateFrame("Frame")
threatVisibilityFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
threatVisibilityFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
threatVisibilityFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
threatVisibilityFrame:RegisterEvent("RAID_ROSTER_UPDATE")
threatVisibilityFrame:SetScript("OnEvent", function()
    for i = 1, 10 do
        if window[i] then
            window[i]:ApplyVisibilityOverride()
        end
    end
end)

-- ============================================================================
-- 31. 自动清空数据提示（加入新队伍时询问）
-- ============================================================================

local autoResetFrame = CreateFrame("Frame")
autoResetFrame.inPartyRaid = false

autoResetFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
autoResetFrame:RegisterEvent("RAID_ROSTER_UPDATE")
autoResetFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

autoResetFrame:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
        local inGroup = (GetNumPartyMembers() > 0 or GetNumRaidMembers() > 0)
        this.inPartyRaid = inGroup
        return
    end

    local inGroup = (GetNumPartyMembers() > 0 or GetNumRaidMembers() > 0)
    if inGroup and not this.inPartyRaid then
        this.inPartyRaid = true
        if ShaguDPS.config.auto_reset_on_new_group ~= 0 then
            local dialog = StaticPopupDialogs["SHAGUMETER_QUESTION"]
            dialog.text = "你已加入新的队伍/团队，是否清空历史数据？"
            dialog.OnAccept = function()
                ResetData()
            end
            StaticPopup_Show("SHAGUMETER_QUESTION")
        end
    elseif not inGroup then
        this.inPartyRaid = false
    end
end)
