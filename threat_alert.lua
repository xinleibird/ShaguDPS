--[[
    ============================================================================
    ShaguDPS 仇恨警告声模块
    ============================================================================
    监听玩家自身的仇恨百分比，达到配置阈值时播放一次警告声。

    调用方式：parser.lua 在解析 TWTv4 包后调用
              ShaguDPS.threatAlert:Update()

    数据源：ShaguDPS.data.threat[UnitName("player")].perc（由 parser 写入）

    触发条件（必须同时满足）：
      - 配置开关 threat_aggro_sound == 1
      - 当前处于战斗状态
      - 处于小队或团队
      - 包内包含玩家自己（玩家名匹配）
      - perc >= threat_aggro_threshold

    防抖：5 秒冷却，避免仇恨抖动导致连续触发。

    注意：本模块不主动注册事件，纯被动调用；
         配置文件威胁面板位于 settings.lua 的"仇恨"小节。
    ============================================================================
]]

if not ShaguDPS then return end

local SOUND_PATH = "Interface\\AddOns\\ShaguDPS\\sounds\\warn.ogg"
local COOLDOWN_SECONDS = 5

local threatAlert = {}
threatAlert.lastTriggerTime = 0

function threatAlert:Update()
    if not ShaguDPS.config then return end
    if ShaguDPS.config.threat_aggro_sound ~= 1 then return end

    if not ShaguDPS.Combat(true) then return end

    local inGroup = (GetNumPartyMembers() > 0 or GetNumRaidMembers() > 0)
    if not inGroup then return end

    local playerName = UnitName("player")
    if not playerName then return end

    local threatTable = ShaguDPS.data and ShaguDPS.data.threat
    if not threatTable then return end

    local myThreat = threatTable[playerName]
    if not myThreat or not myThreat.perc then return end

    local threshold = ShaguDPS.config.threat_aggro_threshold or 90
    if myThreat.perc < threshold then return end

    local now = GetTime()
    if now - self.lastTriggerTime < COOLDOWN_SECONDS then return end
    self.lastTriggerTime = now

    if PlaySoundFile then
        PlaySoundFile(SOUND_PATH)
    end
end

ShaguDPS.threatAlert = threatAlert