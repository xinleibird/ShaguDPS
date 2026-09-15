--[[
    ============================================================================
    ShaguDPS 战斗日志解析模块（回退模式）
    ============================================================================
    当 Nampower 不可用时，通过监听聊天消息中的战斗日志事件来解析伤害/治疗。
    使用 Lua 模式（pattern）匹配不同语言版本的战斗日志字符串，并通过
    captures()/cfind() 统一重排不同本地化模式之间的捕获组顺序。
    本模块只在 ShaguDPS.hasNampower 为 false 时生效。
    ============================================================================
]]

-- 如果 Nampower 已启用，则直接退出此文件，不使用旧版聊天解析
if ShaguDPS.hasNampower then
    return
end

-- ============================================================================
-- 1. 模块初始化
-- ============================================================================

local parser = ShaguDPS.parser

-- ============================================================================
-- 2. 战斗日志模式预处理
-- ============================================================================

-- 缓存已转换的模式，避免重复处理
local sanitize_cache = {}

-- 将 WoW 的战斗日志模式字符串转换为 Lua 的 gfind 兼容模式
-- 例如：转义特殊字符，替换 %s 为 .+，替换数字捕获等
local function sanitize(pattern)
    if not sanitize_cache[pattern] then
        local ret = pattern
        -- 转义 Lua 模式特殊字符
        ret = gsub(ret, "([%+%-%*%(%)%?%[%]%^])", "%%%1")
        -- 移除数字美元符号（WoW 的捕获索引标记）
        ret = gsub(ret, "%d%$","")
        -- 将 %a、%d 等替换为对应的捕获组
        ret = gsub(ret, "(%%%a)","%(%1+%)")
        -- 将 %s+ 替换为 .+ （匹配任意字符串）
        ret = gsub(ret, "%%s%+",".+")
        -- 处理可能出现的嵌套捕获
        ret = gsub(ret, "%(.%+%)%(%%d%+%)","%(.-%)%(%%d%+%)")
        sanitize_cache[pattern] = ret
    end
    return sanitize_cache[pattern]
end

-- ============================================================================
-- 3. 捕获索引解析
-- ============================================================================

-- 缓存每个模式的捕获索引
local capture_cache = {}

-- 获取模式的各个捕获组在转换后模式中的位置索引（用于重排捕获顺序）
-- 不同本地化模式中捕获组的排列顺序不同（如施法者/目标/数值的位置可能互换），
-- 此函数通过匹配 "N$" 数字标记提取每个捕获组在原模式中的序号，供 cfind 重排。
-- @return 第1~5号捕获组在原模式中的数字索引 a~e
local function captures(pat)
    local r = capture_cache
    if not r[pat] then
        r[pat] = { nil, nil, nil, nil, nil }
        -- 提取模式中的数字捕获引用
        for a, b, c, d, e in string.gfind(gsub(pat, "%((.+)%)", "%1"), gsub(pat, "%d%$", "%%(.-)$")) do
            r[pat][1] = tonumber(a)
            r[pat][2] = tonumber(b)
            r[pat][3] = tonumber(c)
            r[pat][4] = tonumber(d)
            r[pat][5] = tonumber(e)
        end
    end
    return r[pat][1], r[pat][2], r[pat][3], r[pat][4], r[pat][5]
end

-- ============================================================================
-- 4. 自定义字符串匹配函数 cfind
-- ============================================================================

-- 供 cfind 复用的全局变量（避免每次匹配重复分配）：
-- ra~re 为重排后的捕获结果；a~e 为捕获索引；va~ve 为原始捕获值
local ra, rb, rc, rd, re, a, b, c, d, e, match, num, va, vb, vc, vd, ve

-- 对字符串 str 执行模式 pat 匹配，并按 captures() 解析出的原始捕获索引
-- 将 string.find 的返回值重新排列为 ra~re（顺序与 combatlog_parser 的期望参数一致）
-- @return match 是否匹配, num 匹配起点, ra~re 重排后的 1~5 号捕获值
local function cfind(str, pat)
    -- 获取模式的捕获索引
    a, b, c, d, e = captures(pat)
    -- 执行匹配
    match, num, va, vb, vc, vd, ve = string.find(str, sanitize(pat))
    -- 根据捕获索引重新排列结果到 ra~re
    ra = e == 1 and ve or d == 1 and vd or c == 1 and vc or b == 1 and vb or va
    rb = e == 2 and ve or d == 2 and vd or c == 2 and vc or a == 2 and va or vb
    rc = e == 3 and ve or d == 3 and vd or a == 3 and va or b == 3 and vb or vc
    rd = e == 4 and ve or a == 4 and va or c == 4 and vc or b == 4 and vb or vd
    re = a == 5 and va or d == 5 and vd or c == 5 and vc or b == 5 and vb or ve
    return match, num, ra, rb, rc, rd, re
end

-- ============================================================================
-- 5. 战斗日志模式分类
-- ============================================================================

-- 每种伤害/治疗类型可能对应多个本地化模式
local combatlog_strings = {
    ["Hit Damage (self vs. other)"] = {
        COMBATHITSELFOTHER, COMBATHITSCHOOLSELFOTHER, COMBATHITCRITSELFOTHER, COMBATHITCRITSCHOOLSELFOTHER
    },
    ["Hit Damage (other vs. self)"] = {
        COMBATHITOTHERSELF, COMBATHITCRITOTHERSELF, COMBATHITSCHOOLOTHERSELF, COMBATHITCRITSCHOOLOTHERSELF
    },
    ["Hit Damage (other vs. other)"] = {
        COMBATHITOTHEROTHER, COMBATHITCRITOTHEROTHER, COMBATHITSCHOOLOTHEROTHER, COMBATHITCRITSCHOOLOTHEROTHER
    },
    ["Spell Damage (self vs. self/other)"] = {
        SPELLLOGSCHOOLSELFSELF, SPELLLOGCRITSCHOOLSELFSELF, SPELLLOGSELFSELF, SPELLLOGCRITSELFSELF,
        SPELLLOGSCHOOLSELFOTHER, SPELLLOGCRITSCHOOLSELFOTHER, SPELLLOGSELFOTHER, SPELLLOGCRITSELFOTHER
    },
    ["Spell Damage (other vs. self)"] = {
        SPELLLOGSCHOOLOTHERSELF, SPELLLOGCRITSCHOOLOTHERSELF, SPELLLOGOTHERSELF, SPELLLOGCRITOTHERSELF
    },
    ["Spell Damage (other vs. other)"] = {
        SPELLLOGSCHOOLOTHEROTHER, SPELLLOGCRITSCHOOLOTHEROTHER, SPELLLOGOTHEROTHER, SPELLLOGCRITOTHEROTHER
    },
    ["Shield Damage (self vs. other)"] = {
        DAMAGESHIELDSELFOTHER
    },
    ["Shield Damage (other vs. self/other)"] = {
        DAMAGESHIELDOTHERSELF, DAMAGESHIELDOTHEROTHER
    },
    ["Periodic Damage (self/other vs. other)"] = {
        PERIODICAURADAMAGESELFOTHER, PERIODICAURADAMAGEOTHEROTHER
    },
    ["Periodic Damage (self/other vs. self)"] = {
        PERIODICAURADAMAGESELFSELF, PERIODICAURADAMAGEOTHERSELF
    },
    ["Heal (self vs. self/other)"] = {
        HEALEDCRITSELFSELF, HEALEDSELFSELF, HEALEDCRITSELFOTHER, HEALEDSELFOTHER
    },
    ["Heal (other vs. self/other)"] = {
        HEALEDCRITOTHERSELF, HEALEDOTHERSELF, HEALEDCRITOTHEROTHER, HEALEDOTHEROTHER
    },
    ["Periodic Heal (self/other vs. other)"] = {
        PERIODICAURAHEALSELFOTHER, PERIODICAURAHEALOTHEROTHER
    },
    ["Periodic Heal (other vs. self/other)"] = {
        PERIODICAURAHEALSELFSELF, PERIODICAURAHEALOTHERSELF
    }
}

-- 将聊天事件类型映射到对应的战斗日志模式列表
local combatlog_events = {
    ["CHAT_MSG_COMBAT_SELF_HITS"] = combatlog_strings["Hit Damage (self vs. other)"],
    ["CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS"] = combatlog_strings["Hit Damage (other vs. self)"],
    ["CHAT_MSG_COMBAT_PARTY_HITS"] = combatlog_strings["Hit Damage (other vs. other)"],
    ["CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS"] = combatlog_strings["Hit Damage (other vs. other)"],
    ["CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS"] = combatlog_strings["Hit Damage (other vs. other)"],
    ["CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_HITS"] = combatlog_strings["Hit Damage (other vs. other)"],
    ["CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS"] = combatlog_strings["Hit Damage (other vs. other)"],
    ["CHAT_MSG_COMBAT_PET_HITS"] = combatlog_strings["Hit Damage (other vs. other)"],
    ["CHAT_MSG_SPELL_SELF_DAMAGE"] = combatlog_strings["Spell Damage (self vs. self/other)"],
    ["CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE"] = combatlog_strings["Spell Damage (other vs. self)"],
    ["CHAT_MSG_SPELL_PARTY_DAMAGE"] = combatlog_strings["Spell Damage (other vs. other)"],
    ["CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE"] = combatlog_strings["Spell Damage (other vs. other)"],
    ["CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE"] = combatlog_strings["Spell Damage (other vs. other)"],
    ["CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE"] = combatlog_strings["Spell Damage (other vs. other)"],
    ["CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE"] = combatlog_strings["Spell Damage (other vs. other)"],
    ["CHAT_MSG_SPELL_PET_DAMAGE"] = combatlog_strings["Spell Damage (other vs. other)"],
    ["CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF"] = combatlog_strings["Shield Damage (self vs. other)"],
    ["CHAT_MSG_SPELL_DAMAGESHIELDS_ON_OTHERS"] = combatlog_strings["Shield Damage (other vs. self/other)"],
    ["CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE"] = combatlog_strings["Periodic Damage (self/other vs. other)"],
    ["CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE"] = combatlog_strings["Periodic Damage (self/other vs. other)"],
    ["CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE"] = combatlog_strings["Periodic Damage (self/other vs. other)"],
    ["CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE"] = combatlog_strings["Periodic Damage (self/other vs. other)"],
    ["CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE"] = combatlog_strings["Periodic Damage (self/other vs. self)"],
    ["CHAT_MSG_SPELL_SELF_BUFF"] = combatlog_strings["Heal (self vs. self/other)"],
    ["CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF"] = combatlog_strings["Heal (other vs. self/other)"],
    ["CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF"] = combatlog_strings["Heal (other vs. self/other)"],
    ["CHAT_MSG_SPELL_PARTY_BUFF"] = combatlog_strings["Heal (other vs. self/other)"],
    ["CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS"] = combatlog_strings["Periodic Heal (self/other vs. other)"],
    ["CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS"] = combatlog_strings["Periodic Heal (self/other vs. other)"],
    ["CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_BUFFS"] = combatlog_strings["Periodic Heal (self/other vs. other)"],
    ["CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS"] = combatlog_strings["Periodic Heal (other vs. self/other)"]
}

-- ============================================================================
-- 6. 模式解析函数
-- ============================================================================

-- 每个具体模式对应的解析函数，从捕获结果中提取 施法者、技能、目标、数值、学派、类型
local combatlog_parser = {
    [SPELLLOGSCHOOLSELFSELF] = function(d, attack, value, school)
        return d.source, attack, d.target, value, school, "damage"
    end,
    [SPELLLOGCRITSCHOOLSELFSELF] = function(d, attack, value, school)
        return d.source, attack, d.target, value, school, "damage"
    end,
    [SPELLLOGSELFSELF] = function(d, attack, value)
        return d.source, attack, d.target, value, d.school, "damage"
    end,
    [SPELLLOGCRITSELFSELF] = function(d, attack, value)
        return d.source, attack, d.target, value, d.school, "damage"
    end,
    [PERIODICAURADAMAGESELFSELF] = function(d, value, school, attack)
        return d.source, attack, d.target, value, school, "damage"
    end,
    [SPELLLOGSCHOOLSELFOTHER] = function(d, attack, target, value, school)
        return d.source, attack, target, value, school, "damage"
    end,
    [SPELLLOGCRITSCHOOLSELFOTHER] = function(d, attack, target, value, school)
        return d.source, attack, target, value, school, "damage"
    end,
    [SPELLLOGSELFOTHER] = function(d, attack, target, value)
        return d.source, attack, target, value, d.school, "damage"
    end,
    [SPELLLOGCRITSELFOTHER] = function(d, attack, target, value)
        return d.source, attack, target, value, d.school, "damage"
    end,
    [PERIODICAURADAMAGESELFOTHER] = function(d, target, value, school, attack)
        return d.source, attack, target, value, school, "damage"
    end,
    [COMBATHITSELFOTHER] = function(d, target, value)
        return d.source, d.attack, target, value, d.school, "damage"
    end,
    [COMBATHITCRITSELFOTHER] = function(d, target, value)
        return d.source, d.attack, target, value, d.school, "damage"
    end,
    [COMBATHITSCHOOLSELFOTHER] = function(d, target, value, school)
        return d.source, d.attack, target, value, school, "damage"
    end,
    [COMBATHITCRITSCHOOLSELFOTHER] = function(d, target, value, school)
        return d.source, d.attack, target, value, school, "damage"
    end,
    [DAMAGESHIELDSELFOTHER] = function(d, value, school, target)
        return d.source, "Reflect ("..school..")", target, value, school, "damage"
    end,
    [SPELLLOGSCHOOLOTHERSELF] = function(d, source, attack, value, school)
        return source, attack, d.target, value, school, "damage"
    end,
    [SPELLLOGCRITSCHOOLOTHERSELF] = function(d, source, attack, value, school)
        return source, attack, d.target, value, school, "damage"
    end,
    [SPELLLOGOTHERSELF] = function(d, source, attack, value)
        return source, attack, d.target, value, d.school, "damage"
    end,
    [SPELLLOGCRITOTHERSELF] = function(d, source, attack, value)
        return source, attack, d.target, value, d.school, "damage"
    end,
    [PERIODICAURADAMAGEOTHERSELF] = function(d, value, school, source, attack)
        return source, attack, d.target, value, school, "damage"
    end,
    [COMBATHITOTHERSELF] = function(d, source, value)
        return source, d.attack, d.target, value, d.school, "damage"
    end,
    [COMBATHITCRITOTHERSELF] = function(d, source, value)
        return source, d.attack, d.target, value, d.school, "damage"
    end,
    [COMBATHITSCHOOLOTHERSELF] = function(d, source, value, school)
        return source, d.attack, d.target, value, school, "damage"
    end,
    [COMBATHITCRITSCHOOLOTHERSELF] = function(d, source, value, school)
        return source, d.attack, d.target, value, school, "damage"
    end,
    [SPELLLOGSCHOOLOTHEROTHER] = function(d, source, attack, target, value, school)
        return source, attack, target, value, school, "damage"
    end,
    [SPELLLOGCRITSCHOOLOTHEROTHER] = function(d, source, attack, target, value, school)
        return source, attack, target, value, school, "damage"
    end,
    [SPELLLOGOTHEROTHER] = function(d, source, attack, target, value)
        return source, attack, target, value, d.school, "damage"
    end,
    [SPELLLOGCRITOTHEROTHER] = function(d, source, attack, target, value, school)
        return source, attack, target, value, school, "damage"
    end,
    [PERIODICAURADAMAGEOTHEROTHER] = function(d, target, value, school, source, attack)
        return source, attack, target, value, school, "damage"
    end,
    [COMBATHITOTHEROTHER] = function(d, source, target, value)
        return source, d.attack, target, value, d.school, "damage"
    end,
    [COMBATHITCRITOTHEROTHER] = function(d, source, target, value)
        return source, d.attack, target, value, d.school, "damage"
    end,
    [COMBATHITSCHOOLOTHEROTHER] = function(d, source, target, value, school)
        return source, d.attack, target, value, school, "damage"
    end,
    [COMBATHITCRITSCHOOLOTHEROTHER] = function(d, source, target, value, school)
        return source, d.attack, target, value, school, "damage"
    end,
    [DAMAGESHIELDOTHERSELF] = function(d, source, value, school)
        return source, "Reflect ("..school..")", d.target, value, school, "damage"
    end,
    [DAMAGESHIELDOTHEROTHER] = function(d, source, value, school, target)
        return source, "Reflect ("..school..")", target, value, school, "damage"
    end,
    [HEALEDCRITOTHERSELF] = function(d, source, spell, value)
        return source, spell, d.target, value, d.school, "heal"
    end,
    [HEALEDOTHERSELF] = function(d, source, spell, value)
        return source, spell, d.target, value, d.school, "heal"
    end,
    [PERIODICAURAHEALOTHERSELF] = function(d, value, source, spell)
        return source, spell, d.target, value, d.school, "heal"
    end,
    [HEALEDCRITSELFSELF] = function(d, spell, value)
        return d.source, spell, d.target, value, d.school, "heal"
    end,
    [HEALEDSELFSELF] = function(d, spell, value)
        return d.source, spell, d.target, value, d.school, "heal"
    end,
    [PERIODICAURAHEALSELFSELF] = function(d, value, spell)
        return d.source, spell, d.target, value, d.school, "heal"
    end,
    [HEALEDCRITSELFOTHER] = function(d, spell, target, value)
        return d.source, spell, target, value, d.school, "heal"
    end,
    [HEALEDSELFOTHER] = function(d, spell, target, value)
        return d.source, spell, target, value, d.school, "heal"
    end,
    [PERIODICAURAHEALSELFOTHER] = function(d, target, value, spell)
        return d.source, spell, target, value, d.school, "heal"
    end,
    [HEALEDCRITOTHEROTHER] = function(d, source, spell, target, value)
        return source, spell, target, value, d.school, "heal"
    end,
    [HEALEDOTHEROTHER] = function(d, source, spell, target, value)
        return source, spell, target, value, d.school, "heal"
    end,
    [PERIODICAURAHEALOTHEROTHER] = function(d, target, value, source, spell)
        return source, spell, target, value, d.school, "heal"
    end,
}

-- ============================================================================
-- 7. 注册所有战斗日志事件
-- ============================================================================

for event in pairs(combatlog_events) do
    parser:RegisterEvent(event)
end

-- 预编译所有模式以加速匹配
for pattern in pairs(combatlog_parser) do
    sanitize(pattern)
end

-- ============================================================================
-- 8. 默认值与辅助变量
-- ============================================================================

-- 解析参数默认值表：每次事件处理前重置，缺省字段（如学派、目标）由具体
-- 模式解析函数按需取用；匹配失败时字段保持默认值（如自动攻击/物理学派）
local defaults = {}

-- 预先转换"吸收/抵抗"后缀模式，供事件处理器剥离战斗日志里的后缀文字
local absorb = sanitize(ABSORB_TRAILER)
local resist = sanitize(RESIST_TRAILER)

-- cfind 返回值缓存与缺省常量
local _, num, pattern, result, a1, a2, a3, a4, a5
local empty, physical, autohit = "", "physical", "Auto Hit"
local player = UnitName("player")

-- ============================================================================
-- 9. 事件处理函数
-- ============================================================================

parser:SetScript("OnEvent", function()
    if not arg1 then return end

    -- 玩家名可能因加载时机尚未可用，事件触发时再补取
    if not player then player = UnitName("player") end

    -- 移除吸收和抵抗后缀，避免干扰伤害数值的捕获
    arg1 = string.gsub(arg1, absorb, empty)
    arg1 = string.gsub(arg1, resist, empty)

    -- 设置默认值：施法者为玩家自己，目标为玩家自己，学派为物理，攻击类型为自动攻击
    defaults.source = player
    defaults.target = player
    defaults.school = physical
    defaults.attack = autohit

    -- 遍历当前事件对应的所有可能模式
    for _, pattern in pairs(combatlog_events[event]) do
        -- 使用自定义的 cfind 进行匹配，并自动重排捕获顺序
        result, num, a1, a2, a3, a4, a5 = cfind(arg1, pattern)
        if result then
            -- 匹配成功，调用对应解析函数并传递给核心数据更新函数
            return parser:AddData(combatlog_parser[pattern](defaults, a1, a2, a3, a4, a5))
        end
    end
end)