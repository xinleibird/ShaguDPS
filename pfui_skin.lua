--[[
    ============================================================================
    ShaguDPS pfUI 风格皮肤模块（独立实现，兼容 1.12）
    ============================================================================
    启用后会将所有窗口（主窗口、设置窗口、详情窗口、BOSS菜单等）重绘为
    类似 pfUI 的外观风格（深色背景、细边框、扁平按钮、阴影效果）。
    通过设置面板 "pfUI 风格" 选项控制开关。
    本模块完全独立，无需 pfUI 插件，无外部依赖。
    ============================================================================
]]

-- ============================================================================
-- 1. 原始样式定义（用于还原）
-- ============================================================================

-- 原始设置面板背景（与 settings.lua 一致，用于还原）
local SETTINGS_ORIG_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
}
local SETTINGS_ORIG_BORDER = {
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
}

-- ============================================================================
-- 2. pfUI 风格背景定义
-- ============================================================================

local PFUI_BACKDROP = {
    bgFile   = "Interface\\BUTTONS\\WHITE8X8",
    edgeFile = "Interface\\BUTTONS\\WHITE8X8",
    tile     = false,
    tileSize = 0,
    edgeSize = 1,
    insets   = { left = 0, right = 0, top = 0, bottom = 0 }
}

local PFUI_WIN_BACKDROP = {
    bgFile   = "Interface\\BUTTONS\\WHITE8X8",
    edgeFile = "Interface\\BUTTONS\\WHITE8X8",
    tile     = false,
    tileSize = 0,
    edgeSize = 2,
    insets   = { left = 2, right = 2, top = 2, bottom = 2 }
}

local PFUI_PANEL_BACKDROP = {
    bgFile   = "Interface\\BUTTONS\\WHITE8X8",
    edgeFile = "Interface\\BUTTONS\\WHITE8X8",
    tile     = false,
    tileSize = 0,
    edgeSize = 1,
    insets   = { left = 0, right = 0, top = 0, bottom = 0 }
}

local PFUI_SHADOW_BACKDROP = {
    edgeFile = "Interface\\BUTTONS\\WHITE8X8",
    edgeSize = 2,
}

-- ============================================================================
-- 3. 颜色常量
-- ============================================================================

local BG_COLOR         = {0, 0, 0, 0.4}
local BORDER_COLOR     = {0.4, 0.4, 0.4, 0}
local BTN_BG_COLOR     = {0, 0, 0, 0.75}
local BTN_BORDER       = {0.4, 0.4, 0.4, 1.0}
local BTN_HIGHLIGHT    = {1.0, 0.8, 0.0, 1.0}
local SHADOW_COLOR     = {0, 0, 0, 0.35}

-- ============================================================================
-- 4. 辅助函数：安全拷贝 backdrop 表
-- ============================================================================

local function CopyBackdrop(tbl)
    if not tbl then return nil end
    local copy = {}
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            copy[k] = CopyBackdrop(v)
        else
            copy[k] = v
        end
    end
    return copy
end

-- ============================================================================
-- 5. 按钮原始属性保存与恢复
-- ============================================================================

local function SaveButtonOriginal(btn)
    if not btn then return end
    if not btn._orig then
        local origBackdrop = btn:GetBackdrop()
        btn._orig = {
            backdrop = CopyBackdrop(origBackdrop),
            backdropColor = {btn:GetBackdropColor()},
            backdropBorderColor = {btn:GetBackdropBorderColor()},
            size = {btn:GetWidth(), btn:GetHeight()},
            scripts = {
                OnEnter = btn:GetScript("OnEnter"),
                OnLeave = btn:GetScript("OnLeave"),
            },
        }
    end
end

local function RestoreButton(btn)
    if not btn then return end
    if btn._pfuiStyled and btn._orig then
        local orig = btn._orig
        if orig.backdrop then
            btn:SetBackdrop(orig.backdrop)
        else
            btn:SetBackdrop(nil)
        end
        btn:SetBackdropColor(unpack(orig.backdropColor))
        btn:SetBackdropBorderColor(unpack(orig.backdropBorderColor))
        btn:SetWidth(orig.size[1])
        btn:SetHeight(orig.size[2])
        if orig.scripts.OnEnter then
            btn:SetScript("OnEnter", orig.scripts.OnEnter)
        else
            btn:SetScript("OnEnter", nil)
        end
        if orig.scripts.OnLeave then
            btn:SetScript("OnLeave", orig.scripts.OnLeave)
        else
            btn:SetScript("OnLeave", nil)
        end
        btn._pfuiStyled = false
        btn._orig = nil
    end
end

-- ============================================================================
-- 6. 按钮换肤（通用）
-- ============================================================================

local function SkinButton(btn)
    if not btn then return end
    if btn._pfuiStyled then return end
    btn._pfuiStyled = true

    SaveButtonOriginal(btn)

    -- 移除默认纹理
    btn:SetNormalTexture("")
    btn:SetHighlightTexture("")
    btn:SetPushedTexture("")
    btn:SetDisabledTexture("")

    -- 应用 pfUI 风格背景
    btn:SetBackdrop(PFUI_BACKDROP)
    btn:SetBackdropColor(unpack(BTN_BG_COLOR))
    btn:SetBackdropBorderColor(unpack(BTN_BORDER))

    -- 悬停高亮效果
    local oldEnter = btn:GetScript("OnEnter")
    local oldLeave = btn:GetScript("OnLeave")
    btn:SetScript("OnEnter", function()
        if oldEnter then oldEnter() end
        this:SetBackdropBorderColor(unpack(BTN_HIGHLIGHT))
    end)
    btn:SetScript("OnLeave", function()
        if oldLeave then oldLeave() end
        this:SetBackdropBorderColor(unpack(BTN_BORDER))
    end)

    -- 调整尺寸以适配 pfUI 风格：宽度仅在 16x16 小按钮时收窄，高度统一设为 14
    if btn:GetWidth() == 16 then btn:SetWidth(14) end
    btn:SetHeight(14)
end

-- ============================================================================
-- 7. 复选框换肤（保留原有对勾，只美化背景）
-- ============================================================================

local function SkinCheckButton(checkbox)
    if not checkbox then return end
    if checkbox._pfuiStyled then return end
    checkbox._pfuiStyled = true

    -- 保存原始纹理
    local nt = checkbox:GetNormalTexture()
    if nt then
        checkbox._origNormalTex = nt:GetTexture()
    else
        checkbox._origNormalTex = nil
    end

    -- 移除默认纹理（保留对勾逻辑，但隐藏背景）
    checkbox:SetNormalTexture("")

    -- 应用 pfUI 风格背景
    checkbox:SetBackdrop(PFUI_BACKDROP)
    checkbox:SetBackdropColor(unpack(BTN_BG_COLOR))
    checkbox:SetBackdropBorderColor(unpack(BTN_BORDER))
end

local function RestoreCheckButton(checkbox)
    if not checkbox then return end
    if not checkbox._pfuiStyled then return end

    -- 恢复原始纹理
    if checkbox._origNormalTex then
        checkbox:SetNormalTexture(checkbox._origNormalTex)
    else
        checkbox:SetNormalTexture("")
    end

    -- 移除 pfUI 背景
    checkbox:SetBackdrop(nil)
    checkbox._pfuiStyled = false
    checkbox._origNormalTex = nil
end

-- ============================================================================
-- 8. 选择器（条材质、条高度等带左右箭头的控件）背景美化
-- ============================================================================

local function SkinSelector(frame)
    if not frame then return end
    if frame._pfuiStyled then return end
    frame._pfuiStyled = true

    -- 保存原始背景属性
    local origBackdrop = frame:GetBackdrop()
    if origBackdrop then
        frame._origSelector = {
            backdrop = CopyBackdrop(origBackdrop),
            backdropColor = {frame:GetBackdropColor()},
            backdropBorderColor = {frame:GetBackdropBorderColor()},
        }
    else
        frame._origSelector = { backdrop = nil }
    end

    -- 选择器主体样式：显示边框
    frame:SetBackdrop(PFUI_BACKDROP)
    frame:SetBackdropColor(unpack(BTN_BG_COLOR))
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    -- 处理左右按钮：默认不显示边框，悬停显示
    local function SkinSelectorButton(btn)
        if not btn then return end
        if btn._pfuiStyled then return end
        btn._pfuiStyled = true
        SaveButtonOriginal(btn)

        btn:SetNormalTexture("")
        btn:SetHighlightTexture("")
        btn:SetPushedTexture("")
        btn:SetDisabledTexture("")

        btn:SetBackdrop(PFUI_BACKDROP)
        btn:SetBackdropColor(unpack(BTN_BG_COLOR))
        btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0)  -- 默认透明，不显示边框

        local oldEnter = btn:GetScript("OnEnter")
        local oldLeave = btn:GetScript("OnLeave")
        btn:SetScript("OnEnter", function()
            if oldEnter then oldEnter() end
            this:SetBackdropBorderColor(unpack(BTN_HIGHLIGHT))   -- 悬停显示高亮边框
        end)
        btn:SetScript("OnLeave", function()
            if oldLeave then oldLeave() end
            this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0)        -- 离开恢复透明
        end)
    end

    SkinSelectorButton(frame.left)
    SkinSelectorButton(frame.right)
end

local function RestoreSelector(frame)
    if not frame then return end
    if not frame._pfuiStyled then return end
    local orig = frame._origSelector
    if orig then
        if orig.backdrop then
            frame:SetBackdrop(orig.backdrop)
        else
            frame:SetBackdrop(nil)
        end
        if orig.backdropColor then
            frame:SetBackdropColor(unpack(orig.backdropColor))
        end
        if orig.backdropBorderColor then
            frame:SetBackdropBorderColor(unpack(orig.backdropBorderColor))
        end
        frame._origSelector = nil
    end
    -- 还原左右按钮
    if frame.left then RestoreButton(frame.left) end
    if frame.right then RestoreButton(frame.right) end
    frame._pfuiStyled = false
end

-- ============================================================================
-- 9. 递归应用皮肤到设置面板所有子控件
-- ============================================================================

local function ApplySkinToChildren(frame)
    if not frame then return end
    for _, child in ipairs({frame:GetChildren()}) do
        local objType = child:GetObjectType()
        if objType == "Button" then
            SkinButton(child)
        elseif objType == "CheckButton" then
            SkinCheckButton(child)
        elseif objType == "Frame" and child.left and child.right and child.caption and not child.isSettingsPanel then
            -- 通过"存在 left/right 箭头与 caption"识别数值选择器；设置面板本体排除在外
            SkinSelector(child)
        end
        ApplySkinToChildren(child)
    end
end

local function RestoreSkinFromChildren(frame)
    if not frame then return end
    for _, child in ipairs({frame:GetChildren()}) do
        if child._pfuiStyled then
            if child:GetObjectType() == "Button" then
                RestoreButton(child)
            elseif child:GetObjectType() == "CheckButton" then
                RestoreCheckButton(child)
            elseif child:GetObjectType() == "Frame" and child.left and child.right and child.caption and not child.isSettingsPanel then
                RestoreSelector(child)
            end
        end
        RestoreSkinFromChildren(child)
    end
end

-- ============================================================================
-- 10. 数据窗口皮肤
-- ============================================================================

local function ApplyPfuiSkinToWindow(win)
    if not win then return end

    -- 应用窗口背景（遵循用户 backdrop 开关：关闭时去掉底色/边框/阴影）
    local showBg = ShaguDPS.config.backdrop == 1
    if showBg then
        win:SetBackdrop(PFUI_WIN_BACKDROP)
        win:SetBackdropColor(unpack(BG_COLOR))
        win:SetBackdropBorderColor(unpack(BORDER_COLOR))
    else
        win:SetBackdrop(nil)
    end
    if win.border then win.border:Hide() end

    -- 添加阴影效果（背景关闭时同步隐藏阴影）
    if not win._pfuiShadow then
        local shadow = CreateFrame("Frame", nil, win)
        shadow:SetFrameStrata("BACKGROUND")
        shadow:SetFrameLevel(1)
        shadow:SetPoint("TOPLEFT", win, "TOPLEFT", -2, 2)
        shadow:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", 2, -2)
        shadow:SetBackdrop(PFUI_SHADOW_BACKDROP)
        shadow:SetBackdropBorderColor(unpack(SHADOW_COLOR))
        win._pfuiShadow = shadow
    end
    if showBg then
        win._pfuiShadow:Show()
    else
        win._pfuiShadow:Hide()
    end

    -- 收集所有需要美化的按钮
    local buttons = {
        win.btnAnnounce, win.btnReset, win.btnSegment, win.btnMode,
        win.btnDamage, win.btnDPS, win.btnHeal, win.btnHPS,
        win.btnCurrent, win.btnOverall, win.btnSmall, win.btnWindow, win.btnSettings,
    }
    table.insert(buttons, win.btnThreat)

    if ShaguDPS.hasNampower then
        table.insert(buttons, win.btnEffHeal)
        table.insert(buttons, win.btnOverHeal)
        table.insert(buttons, win.btnDeath)
        table.insert(buttons, win.btnSpellcast)
        table.insert(buttons, win.btnFriendlyFire)
        table.insert(buttons, win.btnDispel)
        table.insert(buttons, win.btnSunder)
        table.insert(buttons, win.btnDamageTaken)
        table.insert(buttons, win.btnEnergize)
        table.insert(buttons, win.btnInvalidDamage)
        table.insert(buttons, win.btnHealTaken)
        table.insert(buttons, win.btnRevive)
        table.insert(buttons, win.btnBuffCov)
        table.insert(buttons, win.btnInterrupt)
        table.insert(buttons, win.btnEnemyTaken)
        table.insert(buttons, win.btnVulnCov)
        if win.btnBossPrev then table.insert(buttons, win.btnBossPrev) end
        if win.btnBossNext then table.insert(buttons, win.btnBossNext) end
        if win.btnBossMenu then table.insert(buttons, win.btnBossMenu) end
        if win.btnBossSummaryMenu then table.insert(buttons, win.btnBossSummaryMenu) end
        if win.btnRecentFights then table.insert(buttons, win.btnRecentFights) end
    end

    for _, btn in ipairs(buttons) do
        SkinButton(btn)
    end
end

-- ============================================================================
-- 11. 设置子面板皮肤与整窗还原
-- ============================================================================

local function ApplyPfuiToSettingsPanel(panel)
    if not panel then return end
    if panel._pfuiStyled then return end
    panel._pfuiStyled = true
    -- 保存原始样式
    panel._orig = {
        backdrop = CopyBackdrop(panel:GetBackdrop()),
        backdropColor = {panel:GetBackdropColor()},
        backdropBorderColor = {panel:GetBackdropBorderColor()},
    }
    -- 应用 pfUI 背景
    panel:SetBackdrop(PFUI_PANEL_BACKDROP)
    panel:SetBackdropColor(unpack(BG_COLOR))
    panel:SetBackdropBorderColor(unpack(BORDER_COLOR))
    -- 隐藏原始边框
    if panel.border then panel.border:Hide() end
    -- 递归美化内部控件
    ApplySkinToChildren(panel)
end

local function RestoreSettingsPanel(panel)
    if not panel then return end
    if not panel._pfuiStyled then return end
    -- 恢复内部控件
    RestoreSkinFromChildren(panel)
    -- 恢复原始背景
    local orig = panel._orig
    if orig then
        if orig.backdrop then
            panel:SetBackdrop(orig.backdrop)
        else
            panel:SetBackdrop(nil)
        end
        if orig.backdropColor then panel:SetBackdropColor(unpack(orig.backdropColor)) end
        if orig.backdropBorderColor then panel:SetBackdropBorderColor(unpack(orig.backdropBorderColor)) end
        panel._orig = nil
    end
    -- 恢复边框显示
    if panel.border then panel.border:Show() end
    panel._pfuiStyled = false
end

local function RestoreSettings()
    local settings = ShaguDPS.settings
    if not settings then return end
    -- 恢复主窗口背景
    settings:SetBackdrop(SETTINGS_ORIG_BACKDROP)
    settings:SetBackdropColor(.5,.5,.5,.9)
    settings:SetBackdropBorderColor(.7,.7,.7,1)
    if settings.border then
        settings.border:SetBackdrop(SETTINGS_ORIG_BORDER)
        settings.border:SetBackdropBorderColor(.7,.7,.7,1)
        settings.border:Show()
    end
    -- 隐藏并销毁阴影 Frame，避免风格反复开关时泄漏
    if settings._pfuiShadow then
        settings._pfuiShadow:Hide()
        settings._pfuiShadow:SetParent(nil)
        settings._pfuiShadow = nil
    end
    -- 恢复关闭按钮
    if settings.btnClose then RestoreButton(settings.btnClose) end
    -- 恢复内部面板
    for _, child in ipairs({settings:GetChildren()}) do
        if child.isSettingsPanel then
            RestoreSettingsPanel(child)
        end
    end
    settings._pfuiStyled = nil
end

-- ============================================================================
-- 12. Hook Refresh 函数，处理 pfUI 风格开关
-- ============================================================================

-- 保存用户切换 pfUI 风格前的 backdrop 设置，关闭风格时恢复原值，
-- 避免启用 pfUI 风格（内部强制 backdrop=1）覆盖用户的原始设置
local savedUserBackdrop = nil
local originalRefresh = ShaguDPS.window.Refresh
local lastPfuiStyle = ShaguDPS.config.pfuiStyle

-- 兼容性刷新：优先调用原始 Refresh；若窗口级刷新不存在（非 Nampower 早期结构），
-- 则逐窗口回退刷新
local function SafeRefresh(force, report)
    if type(originalRefresh) == "function" then
        originalRefresh(force, report)
    else
        for wid = 1, 10 do
            local win = ShaguDPS.window and ShaguDPS.window[wid]
            if win and win.Refresh then
                win:Refresh(force, report)
            end
        end
    end
end

-- 重写 Refresh 函数以支持 pfUI 风格切换
ShaguDPS.window.Refresh = function(force, report)
    local pfuiStyle = ShaguDPS.config.pfuiStyle

    -- 当 pfUI 风格设置变化时，重建所有窗口：
    -- 启用风格时先记住用户原 backdrop，禁用时还原，并在重建前销毁旧窗口
    if pfuiStyle ~= lastPfuiStyle then
        if pfuiStyle == 1 and savedUserBackdrop == nil then
            savedUserBackdrop = ShaguDPS.config.backdrop
        elseif pfuiStyle == 0 and savedUserBackdrop ~= nil then
            ShaguDPS.config.backdrop = savedUserBackdrop
            savedUserBackdrop = nil
        end
        lastPfuiStyle = pfuiStyle
        if type(originalRefresh) == "function" then
            for wid = 1, 10 do
                local win = ShaguDPS.window[wid]
                if win then
                    win:Hide()
                    win:SetParent(nil)
                    ShaguDPS.window[wid] = nil
                end
            end
        end
    end

    SafeRefresh(force, report)

    -- 对所有窗口应用 pfUI 皮肤
    if pfuiStyle == 1 then
        for wid = 1, 10 do
            local win = ShaguDPS.window[wid]
            if win then
                ApplyPfuiSkinToWindow(win)
            end
        end
    end

    -- 对设置面板应用或移除 pfUI 皮肤
    if pfuiStyle == 1 then
        ShaguDPS.ApplyPfuiToSettingsWindow()
    else
        RestoreSettings()
    end
end

-- ============================================================================
-- 13. BOSS 二级菜单 PfUI 美化
-- ============================================================================

function ShaguDPS.ApplyPfuiToBossMenu(menu)
    if not menu then return end
    if menu.isTip then return end

    -- 设置菜单容器背景
    menu:SetBackdrop(PFUI_WIN_BACKDROP)
    menu:SetBackdropColor(unpack(BG_COLOR))
    menu:SetBackdropBorderColor(unpack(BORDER_COLOR))

    -- 逐个美化按钮
    for _, child in ipairs({menu:GetChildren()}) do
        if child:GetObjectType() == "Button" then
            SkinButton(child)
        end
    end
end

-- ============================================================================
-- 14. 设置窗口皮肤（主设置和统计窗口通用，实际生效入口）
-- ============================================================================

-- 应用 pfUI 皮肤到设置窗口（主设置和统计窗口通用）
function ShaguDPS.ApplyPfuiToSettingsWindow(win)
    local win = win or ShaguDPS.settings
    if not win then return end
    if win._pfuiStyled then return end
    win._pfuiStyled = true
    win:SetBackdrop(PFUI_WIN_BACKDROP)
    win:SetBackdropColor(unpack(BG_COLOR))
    win:SetBackdropBorderColor(unpack(BORDER_COLOR))
    if win.border then win.border:Hide() end
    -- 添加阴影
    if not win._pfuiShadow then
        local shadow = CreateFrame("Frame", nil, win)
        shadow:SetFrameStrata("BACKGROUND")
        shadow:SetFrameLevel(1)
        shadow:SetPoint("TOPLEFT", win, "TOPLEFT", -2, 2)
        shadow:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", 2, -2)
        shadow:SetBackdrop(PFUI_SHADOW_BACKDROP)
        shadow:SetBackdropBorderColor(unpack(SHADOW_COLOR))
        win._pfuiShadow = shadow
    end
    win._pfuiShadow:Show()
    -- 美化关闭按钮
    if win.btnClose then SkinButton(win.btnClose) end
    -- 美化内部面板
    for _, child in ipairs({win:GetChildren()}) do
        if child.isSettingsPanel then
            ApplyPfuiToSettingsPanel(child)
        end
    end
end