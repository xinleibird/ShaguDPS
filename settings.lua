--[[
    ============================================================================
    ShaguDPS 设置窗口模块
    ============================================================================
    提供图形化配置界面，允许用户修改各种选项（显示、追踪、外观等）。
    配置保存在 SavedVariables 中（按角色或账号）。
    本模块包括：创建设置窗口、生成各配置项控件（复选框、数值选择器、滑块）、
    处理设置变更后的窗口刷新，以及提供 /sdps 斜杠命令的交互逻辑。
    ============================================================================
]]

-- ============================================================================
-- 1. 模块初始化与公共变量引用
-- ============================================================================

local settings = ShaguDPS.settings
local window = ShaguDPS.window
local parser = ShaguDPS.parser

local config = ShaguDPS.config
local textures = ShaguDPS.textures

-- 将当前配置写入 SavedVariables（按 perCharConfig 决定写入角色级还是账号级配置表）。
-- 同步更新两表的 perCharConfig 标志，保证下次登录按正确模式加载：
-- 若只写当前表，另一张表残留旧标志会导致加载判定错位。
local function SaveConfig()
    if config.perCharConfig == 1 then
        ShaguDPS_Config = config
        if ShaguDPS_Config_Account then ShaguDPS_Config_Account.perCharConfig = 1 end
    else
        ShaguDPS_Config_Account = config
        if ShaguDPS_Config then ShaguDPS_Config.perCharConfig = 0 end
    end
end
ShaguDPS.SaveConfig = SaveConfig

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
-- 3. 创建数值选择器（左右箭头控件）
-- ============================================================================

local function CreateSelector(self, values)
    local input = CreateFrame("Frame", nil, self)
    input.values = values

    input:Hide()
    input:SetHeight(18)
    input:SetWidth(values and 112 or 54)
    input:SetPoint("TOPRIGHT", self, "TOPRIGHT", -8, -self.entries*18 - 4)
    input:SetBackdrop(backdrop)
    input:SetBackdropColor(.2,.2,.2,1)
    input:SetBackdropBorderColor(.4,.4,.4,1)
    input:SetScript("OnShow", function() input:change() end)

    -- 材质预览纹理（仅用于 texture 选择器）
    input.texture = input:CreateTexture()
    input.texture:SetPoint("TOPLEFT", input, "TOPLEFT", 13, -3)
    input.texture:SetPoint("BOTTOMRIGHT", input, "BOTTOMRIGHT", -13, 3)
    input.texture:SetVertexColor(.8, .4, .2)

    -- 当前值显示文本
    input.caption = input:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    input.caption:SetFont(STANDARD_TEXT_FONT, 10)
    input.caption:SetText("Select")
    input.caption:SetAllPoints()

    -- 左箭头按钮（减小）
    input.left = CreateFrame("Button", nil, input)
    input.left:SetPoint("LEFT", input, "LEFT", 1, 0)
    input.left:SetWidth(12)
    input.left:SetHeight(16)
    input.left:SetBackdrop(backdrop)
    input.left:SetBackdropColor(.2,.2,.2,1)
    input.left:SetBackdropBorderColor(.4,.4,.4,1)
    input.left:SetScript("OnEnter", function() this:SetBackdropBorderColor(1.0, 0.8, 0.0, 1) end)
    input.left:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.4, 0.4, 0.4, 1) end)
    input.left:SetScript("OnClick", function() input:change(-1) end)
    input.left.caption = input.left:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    input.left.caption:SetFont(STANDARD_TEXT_FONT, 10)
    input.left.caption:SetText("<")
    input.left.caption:SetAllPoints()

    -- 右箭头按钮（增大）
    input.right = CreateFrame("Button", nil, input)
    input.right:SetPoint("RIGHT", input, "RIGHT", -1, 0)
    input.right:SetWidth(12)
    input.right:SetHeight(16)
    input.right:SetBackdrop(backdrop)
    input.right:SetBackdropColor(.2,.2,.2,1)
    input.right:SetBackdropBorderColor(.4,.4,.4,1)
    input.right:SetScript("OnEnter", function() this:SetBackdropBorderColor(1.0, 0.8, 0.0, 1) end)
    input.right:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.4, 0.4, 0.4, 1) end)
    input.right:SetScript("OnClick", function() input:change(1) end)
    input.right.caption = input.right:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    input.right.caption:SetFont(STANDARD_TEXT_FONT, 10)
    input.right.caption:SetText(">")
    input.right.caption:SetAllPoints()

    -- 选择器的核心变更函数：根据方向修改配置值并更新显示
    input.change = function(self, mod)
        local id = config[self.entry] or 1
        if mod and self.values and self.values[id + mod] then
            config[self.entry] = math.ceil(config[self.entry] + mod)
        elseif mod and not self.values then
            local step = self.step or 1
            local newval = config[self.entry] + mod * step
            if self.min then newval = math.max(self.min, newval) end
            if self.max then newval = math.min(self.max, newval) end
            config[self.entry] = newval
        end

        -- 更新显示文本
        if self.values and self.values[config[self.entry]] then
            local _, _, clean = string.find(self.values[config[self.entry]], ".+\\(.+)")
            self.caption:SetText(clean)
        else
            if self.step and self.step < 1 then
                self.caption:SetText(string.format("%.1f", config[self.entry]))
            else
                self.caption:SetText(config[self.entry])
            end
        end

        -- 更新箭头透明度（到达边界时变灰）
        if self.values then
            self.right:SetAlpha(self.values[config[self.entry]+1] and 1 or 0.25)
            self.left:SetAlpha(self.values[config[self.entry]-1] and 1 or 0.25)
        else
            if self.max then
                self.right:SetAlpha(config[self.entry] < self.max and 1 or 0.25)
                self.left:SetAlpha(config[self.entry] > (self.min or -math.huge) and 1 or 0.25)
            else
                self.right:SetAlpha(1)
                self.left:SetAlpha(1)
            end
        end

        SaveConfig()
        window.Refresh(true)

        -- 如果切换的是材质，更新预览纹理
        if self.entry == "texture" then
            local texture = ShaguDPS.textures[config[self.entry]]
            if texture then
                self.texture:SetTexture(texture)
            else
                self.texture:SetTexture()
            end
        end
    end

    return input
end

-- ============================================================================
-- 4. 创建配置项（统一入口）
-- ============================================================================

local function CreateConfig(self, caption, entry, check, options)
    self.entries = self.entries and self.entries + 1 or 1
    local text = self:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    text:SetPoint("TOPLEFT", self, "TOPLEFT", 10, -self.entries*18 - 4)
    text:SetWidth(170)
    text:SetHeight(18)
    text:SetFont(STANDARD_TEXT_FONT, 10, "THINOUTLINE")
    text:SetJustifyH("LEFT")
    text:SetText(caption)

    -- 标题项（不可交互，仅用作分组标题）
    if check == "header" then
        text:SetPoint("TOPLEFT", self, "TOPLEFT", 8, -self.entries*18 - 8)
        text:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
        text:SetTextColor(1, .8, 0)
    end

    -- 布尔值（复选框）
    if check == "boolean" then
        local input = CreateFrame("CheckButton", nil, self, "OptionsCheckButtonTemplate")
        input:Hide()
        input:SetHeight(18)
        input:SetWidth(18)
        input:SetPoint("TOPRIGHT", self, "TOPRIGHT", -8, -self.entries*18 - 8)
        input:SetScript("OnShow", function()
            this:SetChecked(config[entry] == 1)
        end)
        input:SetScript("OnClick", function()
            config[entry] = this:GetChecked() and 1 or 0
            SaveConfig()
            window.Refresh(true)
        end)
        input:Show()
    end

    -- 整数数值选择器（带上下限）
    if check == "number" then
        local input = self:CreateSelector()
        input.entry = entry
        if options then
            input.min = options.min
            input.max = options.max
            input.step = options.step
        end
        input:Show()
    elseif type(check) == "table" then
        -- 离散值选择器（如材质列表）
        local values = check
        local input = self:CreateSelector(values)
        input.entry = entry
        input:Show()
    end

    -- 浮点数滑块（缩放）
    if check == "slider" then
        local input = self:CreateSelector()
        input.entry = entry
        input.step = 0.1
        input.min = 0.5
        input.max = 2.0
        input:Show()
    end

    -- 范围选择器（报告行数）
    if check == "range" then
        local input = self:CreateSelector()
        input.entry = entry
        input.step = 1
        input.min = 1
        input.max = 50
        input:Show()
    end
end

-- ============================================================================
-- 5. 登录时加载保存的配置
-- ============================================================================

settings:RegisterEvent("PLAYER_ENTERING_WORLD")
settings:SetScript("OnEvent", function()
    -- 根据 perCharConfig 选择配置来源
    local source = nil
    if ShaguDPS_Config_Account and ShaguDPS_Config_Account.perCharConfig == 0 then
        source = ShaguDPS_Config_Account
    else
        source = ShaguDPS_Config
    end
    if source then
        for k, v in pairs(source) do
            config[k] = v
        end
    end
    -- 迁移旧版配置：为新增统计项补充默认启用状态
    if type(config.enabled_stats) ~= "table" then
        config.enabled_stats = {}
    end
    for _, viewId in ipairs(ShaguDPS.rightStatViews) do
        if config.enabled_stats[viewId] == nil then
            config.enabled_stats[viewId] = 1
        end
    end
    if config.perCharConfig == nil then config.perCharConfig = 1 end
    SaveConfig()
    -- 若开启"数据导出到Imports"：先从 Imports 恢复统计数据（因为 WTF 中的数据已被清空）
    if config.export_to_imports == 1 and ShaguDPS.ImportDataFromImports then
        if ShaguDPS.ImportDataFromImports() then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00ShaguDPS: 已从 Imports 导入统计数据。|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff8800ShaguDPS: 未能从 Imports 导入统计数据（文件缺失或解析失败）。|r")
        end
    end
    if ShaguDPS.LoadDataFromCache() then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00ShaguDPS: 已从缓存恢复上次统计的数据。|r")
    end
    window.Refresh(true)
    -- 重新加载所有窗口位置
    if ShaguDPS.LoadWindowPositions then
        ShaguDPS.LoadWindowPositions()
    end
    if ShaguDPS.parser and ShaguDPS.parser.UpdateEnabledStats then
        ShaguDPS.parser:UpdateEnabledStats()
    end
end)

-- ============================================================================
-- 6. 主设置窗口
-- ============================================================================

settings:Hide()
settings:SetPoint("CENTER", UIParent, "CENTER", 0, 32)
settings:SetWidth(400)
settings:SetHeight(595)
settings:SetMovable(true)
settings:EnableMouse(true)
settings:RegisterForDrag("LeftButton")
settings:SetScript("OnDragStart", function() this:StartMoving() end)
settings:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
settings:SetFrameStrata("DIALOG")
settings.CreateConfig = CreateConfig
settings.CreateSelector = CreateSelector

settings:SetBackdrop(backdrop_window)
settings:SetBackdropColor(.5,.5,.5,.9)

settings.border = CreateFrame("Frame", nil, settings)
settings.border:ClearAllPoints()
settings.border:SetPoint("TOPLEFT", settings, "TOPLEFT", -1,1)
settings.border:SetPoint("BOTTOMRIGHT", settings, "BOTTOMRIGHT", 1,-1)
settings.border:SetFrameLevel(100)
settings.border:SetBackdrop(backdrop_border)
settings.border:SetBackdropBorderColor(.7,.7,.7,1)

-- 标题栏背景
settings.title = settings:CreateTexture(nil, "NORMAL")
settings.title:SetTexture(0,0,0,.6)
settings.title:SetHeight(20)
settings.title:SetPoint("TOPLEFT", 2, -2)
settings.title:SetPoint("TOPRIGHT", -2, -2)

-- 标题文本
settings.caption = settings:CreateFontString(nil, "OVERLAY", "GameFontWhite")
settings.caption:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
settings.caption:SetText("|cffffcc00Shagu|cffffffffDPS |cffffcc00(|cffffcc00 Goubayu|cffffffff Inside|cffffcc00 )")
settings.caption:SetAllPoints(settings.title)

-- 关闭按钮
settings.btnClose = CreateFrame("Button", nil, settings)
settings.btnClose:SetPoint("RIGHT", settings.title, "RIGHT", -4, 0)
settings.btnClose:SetHeight(16)
settings.btnClose:SetWidth(16)
settings.btnClose:SetBackdrop(backdrop)
settings.btnClose:SetBackdropColor(.2,.2,.2,1)
settings.btnClose:SetBackdropBorderColor(.4,.4,.4,1)

settings.btnClose.caption = settings.btnClose:CreateFontString(nil, "OVERLAY", "GameFontWhite")
settings.btnClose.caption:SetFont(STANDARD_TEXT_FONT, 14)
settings.btnClose.caption:SetText("x")
settings.btnClose.caption:SetAllPoints()
settings.btnClose:SetScript("OnEnter", function() this:SetBackdropBorderColor(1.0, 0.8, 0.0, 1) end)
settings.btnClose:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.4, 0.4, 0.4, 1) end)
settings.btnClose:SetScript("OnClick", function() settings:Hide() end)

-- ============================================================================
-- 7. 创建内部双列面板
-- ============================================================================

local function CreateSettingsPanel(parent, caption, width)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetWidth(width)
    panel:SetHeight(565)
    panel:EnableMouse(false)
    panel.isSettingsPanel = true

    panel:SetBackdrop(backdrop_window)
    panel:SetBackdropColor(0,0,0,0.25)
    panel:SetBackdropBorderColor(.6,.6,.6,1)

    panel.border = CreateFrame("Frame", nil, panel)
    panel.border:ClearAllPoints()
    panel.border:SetPoint("TOPLEFT", panel, "TOPLEFT", -1, 1)
    panel.border:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 1, -1)
    panel.border:SetFrameLevel(100)
    panel.border:SetBackdrop(backdrop_border)
    panel.border:SetBackdropBorderColor(.5,.5,.5,1)

    panel.title = panel:CreateTexture(nil, "BACKGROUND")
    panel.title:SetTexture(0,0,0,.4)
    panel.title:SetHeight(18)
    panel.title:SetPoint("TOPLEFT", 1, -1)
    panel.title:SetPoint("TOPRIGHT", -1, -1)

    panel.caption = panel:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    panel.caption:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    panel.caption:SetText(caption)
    panel.caption:SetTextColor(1, .8, 0)
    panel.caption:SetAllPoints(panel.title)

    panel.entries = 0
    panel.CreateConfig = CreateConfig
    panel.CreateSelector = settings.CreateSelector

    return panel
end

-- ============================================================================
-- 6.5 按条目数动态计算面板/窗口高度
-- ============================================================================

-- 根据条目数计算面板高度（每行18px + 顶部间距4 + 标题20 + 底部余量）
local function PanelHeightForEntries(n)
    return 43 + n * 18
end

-- 按条目数重算面板高度
local function ResizePanelToContent(panel)
    panel:SetHeight(PanelHeightForEntries(panel.entries or 0))
end

-- 按两个面板中最高的重算设置窗口高度（标题30 + 面板上边距6 + 底部边距9）
-- 注意：leftPanel/rightPanel 在下方才声明为 local，这里必须用参数传入（否则引用到全局 nil）
local function ResizeSettingsWindow(left, right)
    local lh = PanelHeightForEntries(left and left.entries or 0)
    local rh = PanelHeightForEntries(right and right.entries or 0)
    settings:SetHeight(math.max(lh, rh) + 35)
end

local leftPanel = CreateSettingsPanel(settings, "常规设置", 192)
leftPanel:SetPoint("TOPLEFT", settings, "TOPLEFT", 6, -26)
leftPanel:Show()

local rightPanel = CreateSettingsPanel(settings, "统计项显示设置", 192)
rightPanel:SetPoint("TOPRIGHT", settings, "TOPRIGHT", -6, -26)
rightPanel:Show()

-- ============================================================================
-- 8. 主设置窗口左侧：常规设置
-- ============================================================================

leftPanel:CreateConfig("解析器", nil, "header")
leftPanel:CreateConfig("显示所有附近单位", "track_all_units", "boolean")
leftPanel:CreateConfig("合并宠物与主人数据", "merge_pets", "boolean")
leftPanel:CreateConfig("显示秒伤", "show_dps_in_damage", "boolean")
leftPanel:CreateConfig("显示HPS（治疗视图）", "show_hps_in_heal", "boolean")
leftPanel:CreateConfig("显示职业图标", "show_class_icon", "boolean")
leftPanel:CreateConfig("中文单位（万/亿/兆）", "chinese_units", "boolean")
leftPanel:CreateConfig("使用DPS替代EDPS（默认）统计", "use_total_cbt_for_dps", "boolean")

if ShaguDPS.hasNampower then
    leftPanel:CreateConfig("显示溢出伤害", "show_overkill", "boolean")
    leftPanel:CreateConfig("剔除溢出伤害", "clamp_damage_to_health", "boolean")
    leftPanel:CreateConfig("剔除小动物伤害", "exclude_critters", "boolean")
    leftPanel:CreateConfig("剔除队友误伤", "hide_friendly_damage", "boolean")
    leftPanel:CreateConfig("仅统计战斗治疗", "heal_only_in_combat", "boolean")
    leftPanel:CreateConfig("分开统计主副手伤害", "separate_mh_oh_damage", "boolean")
end

leftPanel:CreateConfig("仇恨", nil, "header")
leftPanel:CreateConfig("仇恨警告阈值", "threat_aggro_threshold", "number", {min=50, max=100, step=5})
leftPanel:CreateConfig("仇恨达阈值时播放警告声", "threat_aggro_sound", "boolean")
leftPanel:CreateConfig("仇恨仅显示坦克和自己", "show_only_tank_and_self_in_threat", "boolean")
leftPanel:CreateConfig("非战斗/非队伍时隐藏仇恨窗口", "hide_nondefault_threat_out_of_combat", "boolean")

leftPanel:CreateConfig("窗口", nil, "header")
leftPanel:CreateConfig("条材质", "texture", ShaguDPS.textures)
leftPanel:CreateConfig("条高度", "height", "number", {min=10})
leftPanel:CreateConfig("条间距", "spacing", "number", {min=0})
leftPanel:CreateConfig("插件缩放", "scale", "slider")
leftPanel:CreateConfig("发送数据条数", "report_lines", "range")
leftPanel:CreateConfig("柔和色调", "pastel", "boolean")
leftPanel:CreateConfig("显示背景", "backdrop", "boolean")
leftPanel:CreateConfig("非战斗时隐藏窗口", "hide_out_of_combat", "boolean")
leftPanel:CreateConfig("非队伍时隐藏窗口", "hide_out_of_party", "boolean")
leftPanel:CreateConfig("锁定窗口", "lock", "boolean")
leftPanel:CreateConfig("标题栏自动隐藏", "title_autohide", "boolean")
leftPanel:CreateConfig("菜单向上生长", "menu_grow_upwards", "boolean")
leftPanel:CreateConfig("pfUI 风格", "pfuiStyle", "boolean")
leftPanel:CreateConfig("进入新队伍时询问清空数据", "auto_reset_on_new_group", "boolean")
leftPanel:CreateConfig("按角色进行配置", "perCharConfig", "boolean")

-- 左面板条目填充完毕：按条目数重算面板高度
ResizePanelToContent(leftPanel)

-- ============================================================================
-- 9. 主设置窗口右侧：统计项显示开关
-- ============================================================================

-- 统计视图 ID → 显示名称映射（用于右侧开关面板的标签）。
-- 注意：此表与 core.lua 的 rightStatViews / enabled_stats 需保持同步
local statLabelMap = {
    [1] = "伤害量", [2] = "DPS", [3] = "治疗量", [4] = "HPS",
    [5] = "有效治疗", [6] = "过量治疗", [7] = "死亡", [8] = "技能施放",
    [9] = "误伤", [10] = "驱散", [11] = "仇恨", [13] = "破甲",
    [14] = "承受伤害", [16] = "能量回复", [17] = "无效伤害",
    [18] = "受到治疗", [19] = "复活", [20] = "光环覆盖", [21] = "打断",
    [22] = "敌人承伤",[24] = "易伤覆盖",
}

-- 在右侧面板底部添加警告信息（仅当没有 Nampower 时）
if not ShaguDPS.hasNampower then
    local warn = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    warn:SetFont(STANDARD_TEXT_FONT, 10, "THINOUTLINE")
    warn:SetText("|cffff0000全功能需Nampower 4.5及以上版本|r")
    warn:SetPoint("BOTTOMLEFT", rightPanel, "BOTTOMLEFT", 10, 10)
    warn:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", -10, 10)
    warn:SetJustifyH("CENTER")
end

rightPanel.entries = 0
rightPanel:CreateConfig("统计项", nil, "header")
for _, viewId in ipairs(ShaguDPS.rightStatViews) do
    local vid = viewId
    rightPanel.entries = rightPanel.entries + 1
    local label = statLabelMap[viewId] or ("视图" .. viewId)

    local text = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    text:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 10, -rightPanel.entries*18 - 4)
    text:SetWidth(120)
    text:SetHeight(18)
    text:SetFont(STANDARD_TEXT_FONT, 10, "THINOUTLINE")
    text:SetJustifyH("LEFT")
    text:SetText(label)

    local check = CreateFrame("CheckButton", nil, rightPanel, "OptionsCheckButtonTemplate")
    check:SetPoint("TOPRIGHT", rightPanel, "TOPRIGHT", -8, -rightPanel.entries*18 - 8)
    check:SetHeight(18)
    check:SetWidth(18)
    check:SetScript("OnShow", function()
        if not ShaguDPS.config.enabled_stats then
            ShaguDPS.config.enabled_stats = {}
        end
        this:SetChecked(ShaguDPS.config.enabled_stats[vid] == 1)
    end)
    check:SetScript("OnClick", function()
        if not ShaguDPS.config.enabled_stats then
            ShaguDPS.config.enabled_stats = {}
        end
        ShaguDPS.config.enabled_stats[vid] = this:GetChecked() and 1 or 0
        SaveConfig()
        -- 切换统计开关后需重建所有窗口（销毁旧 Frame 释放资源）
        for i = 1, 10 do
            if ShaguDPS.window[i] then
                ShaguDPS.window[i]:Hide()
                ShaguDPS.window[i]:SetParent(nil)
                ShaguDPS.window[i] = nil
            end
        end
        ShaguDPS.window.Refresh(true)
        if ShaguDPS.parser and ShaguDPS.parser.UpdateEnabledStats then
            ShaguDPS.parser:UpdateEnabledStats()
        end
    end)
end

-- 右面板条目填充完毕：重算面板高度，并按两面板中最高的重设设置窗口高度
-- 数据导出（与"统计项"并列的大标题 + 一个复选框；仅在客户端支持 ExportFile/ImportFile 时显示）
if ShaguDPS.IsExportAvailable and ShaguDPS.IsExportAvailable() then
    rightPanel:CreateConfig("数据导出", nil, "header")
    rightPanel:CreateConfig("数据导出到Imports", "export_to_imports", "boolean")
end
ResizePanelToContent(rightPanel)
ResizeSettingsWindow(leftPanel, rightPanel)

-- ============================================================================
-- 10. 切换设置窗口显示
-- ============================================================================

-- 切换设置窗口的显示状态；若启用了 pfUI 风格则在显示时应用皮肤
function ShaguDPS.ToggleSettingsWindows()
    if settings:IsShown() then
        settings:Hide()
    else
        settings:Show()
    end

    if ShaguDPS.config.pfuiStyle == 1 then
        ShaguDPS.ApplyPfuiToSettingsWindow(settings)
    end
end

-- ============================================================================
-- 11. 斜杠命令处理
-- ============================================================================

SLASH_SHAGUMETER1, SLASH_SHAGUMETER2, SLASH_SHAGUMETER3 = "/shagudps", "/sdps", "/sd"
SlashCmdList["SHAGUMETER"] = function(msg, editbox)
    -- 局部打印函数：向默认聊天框输出一条消息
    local function p(msg)
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end

    -- 无参数时打印帮助信息
    if (msg == "" or msg == nil) then
        p("|cffffcc00Shagu|cffffffffDPS:")
        p("  /sdps visible " .. config.visible .. " |cffcccccc- 显示主窗口")
        p("  /sdps height " .. config.height .. " |cffcccccc- 条高度")
        p("  /sdps spacing " .. config.spacing .. " |cffcccccc- 条间距")
        p("  /sdps trackall " .. config.track_all_units .. " |cffcccccc- 显示所有附近单位")
        p("  /sdps mergepet " .. config.merge_pets .. " |cffcccccc- 合并宠物与主人数据")
        p("  /sdps texture " .. config.texture .. " |cffcccccc- 设置状态栏材质")
        p("  /sdps pastel " .. config.pastel .. " |cffcccccc- 使用柔和色调")
        p("  /sdps icon " .. config.show_class_icon .. " |cffcccccc- 显示职业图标（进度条左侧）")
        p("  /sdps cunits " .. config.chinese_units .. " |cffcccccc- 中文单位显示（0=K/M，1=万/亿/兆）")
        p("  /sdps titlehide " .. config.title_autohide .. " |cffcccccc- 标题栏自动隐藏（悬停显示）")
        p("  /sdps backdrop " .. config.backdrop .. " |cffcccccc- 显示窗口背景和边框")
        p("  /sdps lock " .. config.lock .. " |cffcccccc- 锁定窗口")
        p("  /sdps toggle |cffcccccc- 切换窗口显示")
        p("  /sdps cache reset |cffcccccc- 清除战斗日志缓存")
        p("  /sdps autoreset " .. config.auto_reset_on_new_group .. " |cffcccccc- 加入新队伍时是否询问清空（0=否，1=是）")
        return
    end

    -- 解析命令字与参数：cmd = 命令字，args = 剩余参数
    local _, _, cmd, args = string.find(msg, "%s?(%w+)%s?(.*)")
    cmd = cmd or ""
    args = args or ""

    -- 各子命令均遵循"设置配置 → 保存 → 刷新窗口 → 反馈结果"的流程

    if strlower(cmd) == "visible" then
        if tonumber(args) and (tonumber(args) == 1 or tonumber(args) == 0) then
            config.visible = tonumber(args)
            SaveConfig()
            window.Refresh(true)
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc Visible: " .. config.visible)
        else
            p("|cffffcc00Shagu|cffffffffDPS:|cffff5511 Valid Options are 0-1")
        end
    elseif strlower(cmd) == "lock" then
        if tonumber(args) and (tonumber(args) == 1 or tonumber(args) == 0) then
            config.lock = tonumber(args)
            SaveConfig()
            window.Refresh(true)
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc Lock: " .. config.lock)
        else
            p("|cffffcc00Shagu|cffffffffDPS:|cffff5511 Valid Options are 0-1")
        end
    elseif strlower(cmd) == "toggle" then
        config.visible = config.visible == 1 and 0 or 1
        SaveConfig()
        window.Refresh(true)
        p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc Visible: " .. config.visible)
    elseif strlower(cmd) == "height" then
        if tonumber(args) then
            config.height = tonumber(args)
            SaveConfig()
            window.Refresh(true)
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc Bar height: " .. config.height)
        else
            p("|cffffcc00Shagu|cffffffffDPS:|cffff5511 Valid Options are 1-999")
        end
    elseif strlower(cmd) == "spacing" then
        if tonumber(args) then
            config.spacing = tonumber(args)
            SaveConfig()
            window.Refresh(true)
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc Bar spacing: " .. config.spacing)
        else
            p("|cffffcc00Shagu|cffffffffDPS:|cffff5511 Valid Options are 0-" .. config.height)
        end
    elseif strlower(cmd) == "trackall" then
        if tonumber(args) and (tonumber(args) == 1 or tonumber(args) == 0) then
            config.track_all_units = tonumber(args)
            SaveConfig()
            window.Refresh(true)
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc Track all units: " .. config.track_all_units)
        else
            p("|cffffcc00Shagu|cffffffffDPS:|cffff5511 Valid Options are 0-1")
        end
    elseif strlower(cmd) == "mergepet" then
        if tonumber(args) and (tonumber(args) == 1 or tonumber(args) == 0) then
            config.merge_pets = tonumber(args)
            SaveConfig()
            window.Refresh(true)
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc Merge pet: " .. config.merge_pets)
        else
            p("|cffffcc00Shagu|cffffffffDPS:|cffff5511 Valid Options are 0-1")
        end
    elseif strlower(cmd) == "texture" then
        if tonumber(args) and textures[tonumber(args)] then
            config.texture = tonumber(args)
            SaveConfig()
            window.Refresh(true)
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc Texture: " .. config.texture)
        else
            p("|cffffcc00Shagu|cffffffffDPS:|cffff5511 Valid Options are 1-" .. table.getn(textures))
        end
    elseif strlower(cmd) == "pastel" then
        if tonumber(args) and (tonumber(args) == 1 or tonumber(args) == 0) then
            config.pastel = tonumber(args)
            SaveConfig()
            window.Refresh(true)
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc Use pastel colors: " .. config.pastel)
        else
            p("|cffffcc00Shagu|cffffffffDPS:|cffff5511 Valid Options are 0-1")
        end
    elseif strlower(cmd) == "icon" then
        if tonumber(args) and (tonumber(args) == 1 or tonumber(args) == 0) then
            config.show_class_icon = tonumber(args)
            SaveConfig()
            window.Refresh(true)
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc Show class icons: " .. config.show_class_icon)
        else
            p("|cffffcc00Shagu|cffffffffDPS:|cffff5511 Valid Options are 0-1")
        end
    elseif strlower(cmd) == "titlehide" then
        if tonumber(args) and (tonumber(args) == 1 or tonumber(args) == 0) then
            config.title_autohide = tonumber(args)
            SaveConfig()
            window.Refresh(true)
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc Title bar autohide: " .. config.title_autohide)
        else
            p("|cffffcc00Shagu|cffffffffDPS:|cffff5511 Valid Options are 0-1")
        end
    elseif strlower(cmd) == "backdrop" then
        if tonumber(args) and (tonumber(args) == 1 or tonumber(args) == 0) then
            config.backdrop = tonumber(args)
            SaveConfig()
            window.Refresh(true)
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc Show window backdrop: " .. config.backdrop)
        else
            p("|cffffcc00Shagu|cffffffffDPS:|cffff5511 Valid Options are 0-1")
        end
    elseif strlower(cmd) == "cache" then
        if strlower(args) == "reset" then
            ShaguDPS.ClearCache()
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc 缓存已清除。")
        else
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc 用法: /sdps cache reset")
        end
    elseif strlower(cmd) == "autoreset" then
        if tonumber(args) and (tonumber(args) == 1 or tonumber(args) == 0) then
            config.auto_reset_on_new_group = tonumber(args)
            SaveConfig()
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc 新队伍清空询问: " .. config.auto_reset_on_new_group)
        else
            p("|cffffcc00Shagu|cffffffffDPS:|cffff5511 Valid Options are 0-1")
        end
    elseif strlower(cmd) == "cunits" then
        if tonumber(args) and (tonumber(args) == 1 or tonumber(args) == 0) then
            config.chinese_units = tonumber(args)
            SaveConfig()
            window.Refresh(true)
            p("|cffffcc00Shagu|cffffffffDPS:|cffffddcc 中文单位: " .. config.chinese_units)
        else
            p("|cffffcc00Shagu|cffffffffDPS:|cffff5511 Valid Options are 0-1")
        end
    end
end