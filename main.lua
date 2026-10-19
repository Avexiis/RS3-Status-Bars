-- Status Bars: compact, movable resource bars for RuneScape.

local EVENT_LOGIC = "status-bars-logic"
local EVENT_SETTINGS = "status-bars-settings"
local EVENT_CONTENT = "status-bars-content"
local UPDATE_INTERVAL = 30 -- Match the 600 ms RuneScape server tick.
local MOUNT_INTERVAL = 25 -- Retry while the game interface is loading.
local SAVE_INTERVAL = 50 -- Check the widget position and size once per second.
local GAP = 2 -- Space between adjacent bars.
local BORDER = 1 -- Inset the colored fill inside its outline.
local TENTHS = 10 -- These raw point and energy values are scaled by ten.

local BACKGROUND_COLOUR = 0x00000096
local OUTLINE_COLOUR = 0x000000FF

local settings = { -- Values are loaded from PersistentDB at startup.
    orientation = "vertical",
    enabled = {},
}

-- These references hold UI objects created by the plugin.
local widget
local barHost
local bars = {}
local settingsView
local contentView
local settingsControls = { bars = {} }
local contentControls = { bars = {} }
local lastLayoutKey
local lastGeometry
local lastLegacyCombat

-- Value helpers keep all game-state reads separate from rendering.
local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function playerVarValue(variableID)
    -- Read one value from the VarPlayer table.
    if variableID == nil then return nil end
    local variable = var.VarPlayer.FromID(variableID)
    if variable == nil then return nil end
    return tonumber(variable.value)
end

local function ratio(current, maximum)
    -- Keep the fill ratio between zero and one.
    if current == nil or maximum == nil or maximum <= 0 then return 0 end
    return clamp(current / maximum, 0, 1)
end

local function skillValues(skill, scale)
    -- A scale converts skill levels into their matching point units.
    scale = scale or 1
    return Player.GetLevelGameplay(skill) * scale,
        Player.GetLevelCapped(skill) * scale
end

local function pointValues(variableID, skill)
    -- Convert raw tenths and use ten points for each skill level.
    local current = playerVarValue(variableID)
    if current ~= nil then current = math.floor(current / TENTHS) end
    if current == nil then current = Player.GetLevelGameplay(skill) * TENTHS end
    return current, Player.GetLevelCapped(skill) * TENTHS
end

local function constitutionValues()
    -- Use life point variables because the skill level has less detail.
    local current = playerVarValue(id.VarPlayer.LIFEPOINTS)
    local maximum = playerVarValue(id.VarPlayer.MAXLIFEPOINTS)
    if current ~= nil and maximum ~= nil and maximum > 0 then return current, maximum end
    return skillValues(SkillType.HITPOINTS, 100)
end

local function combatEnergyValues()
    -- SA_ENERGY uses tenths of a percent for both adrenaline and special attack.
    return playerVarValue(id.VarPlayer.SA_ENERGY) or 0, 1000
end

local function wholeValue(value)
    return tostring(math.floor((value or 0) + 0.5))
end

local function percentValue(value)
    return tostring(math.floor((value or 0) / 10))
end

local function constitutionDisplayValue(value)
    -- Legacy shows one tenth of the life point value used by the bar.
    if lastLegacyCombat then value = (value or 0) / TENTHS end
    return wholeValue(value)
end

-- Definitions also determine bar order in both layouts and in settings.
local BAR_DEFINITIONS = {
    {
        key = "hitpoints", label = "Constitution", default = true,
        colour = 0xE123007D,
        sprite = id.Sprite.RS3_HUD_COMBAT_BAR_ICON_HEALTH,
        values = constitutionValues, format = constitutionDisplayValue,
    },
    {
        key = "prayer", label = "Prayer", default = true,
        colour = 0x32C8C8AF,
        sprite = id.Sprite.RS3_HUD_COMBAT_BAR_ICON_PRAYER,
        values = function()
            return pointValues(id.VarPlayer.PRAYER_POINTS, SkillType.PRAYER)
        end,
    },
    {
        key = "run_energy", label = "Run energy", default = true,
        colour = 0xC7AE00DC,
        sprite = id.Sprite.NAVIGATION_ICON_ENERGY_ON,
        values = function() return Player.GetRunEnergy(), 100 end,
    },
    {
        key = "summoning", label = "Summoning points", default = true,
        colour = 0x6A8F35DC,
        sprite = id.Sprite.RS3_HUD_COMBAT_BAR_ICON_SUMMONING,
        values = function()
            -- LORE_POINTS stores the current Summoning points.
            return pointValues(id.VarPlayer.LORE_POINTS, SkillType.SUMMONING)
        end,
    },
    {
        key = "adrenaline", label = "Adrenaline", default = false,
        colour = 0xD17B00DC,
        sprite = id.Sprite.RS3_HUD_COMBAT_BAR_ICON_ADRENALINE,
        mode = "eoc", values = combatEnergyValues, format = percentValue,
        modeTooltip = "Switch to an EOC combat mode to enable this bar.",
    },
    {
        key = "special_attack", label = "Special attack", default = false,
        colour = 0x039900C3,
        sprite = id.Sprite.RS3_HUD_COMBAT_BAR_ICON_ADRENALINE,
        mode = "legacy", values = combatEnergyValues, format = percentValue,
        modeTooltip = "Switch to Legacy combat mode to enable this bar.",
    },
}

local function loadSettings()
    -- Missing values use the defaults declared in BAR_DEFINITIONS.
    local savedOrientation = PersistentDB:GetString("orientation")
    if savedOrientation == "horizontal" then settings.orientation = savedOrientation end

    for _, definition in ipairs(BAR_DEFINITIONS) do
        local saved = PersistentDB:GetBool("show_" .. definition.key)
        if definition.default then
            settings.enabled[definition.key] = saved ~= false
        else
            settings.enabled[definition.key] = saved == true
        end
    end
end

local function storedInt(key, fallback, minimum, maximum)
    -- Bounds prevent invalid saved geometry from creating an unusable widget.
    local value = tonumber(PersistentDB:GetInt(key))
    if value == nil then return fallback end
    return clamp(math.floor(value), minimum, maximum)
end

local function isLegacyCombat()
    -- Legacy combat is active when this value is true or 1.
    local value = playerVarValue(id.VarPlayer.TOPLEVEL_V2_LEGACY_COMBAT)
    return value == true or value == 1
end

local function modeAvailable(definition, legacy)
    return definition.mode == nil
        or (definition.mode == "legacy" and legacy)
        or (definition.mode == "eoc" and not legacy)
end

local function updateControlModes(controls, legacy)
    -- Mode-specific controls remain visible but explain why they are locked.
    for _, definition in ipairs(BAR_DEFINITIONS) do
        local control = controls.bars[definition.key]
        if control ~= nil then
            local available = modeAvailable(definition, legacy)
            local tooltip
            if not available then tooltip = definition.modeTooltip end
            control:SetDisabled(not available)
            control:SetTooltip(tooltip)
        end
    end
end

local function updateAllControlModes(legacy)
    updateControlModes(settingsControls, legacy)
    updateControlModes(contentControls, legacy)
end

-- PrettyUI moves and resizes the panel that contains these bars.
local function createBar(parent, definition)
    -- Each bar has a background, fill, outline, icon, and horizontal value.
    local root = ui.Layer.new(parent)
    root.clickthrough = true
    root.hidden = true

    local background = ui.Rectangle.new(root)
    background.fill = true
    background.rgba = BACKGROUND_COLOUR
    background.clickthrough = true

    local fill = ui.Rectangle.new(root)
    fill.fill = true
    fill.rgba = definition.colour
    fill.clickthrough = true

    local outline = ui.Rectangle.new(root)
    outline.fill = false
    outline.outlineThickness = 1
    outline.rgba = OUTLINE_COLOUR
    outline.clickthrough = true

    -- Icons sit on the shared host so PrettyUI can position their tooltips.
    local icon = ui.Sprite.new(parent)
    icon.spriteID = definition.sprite
    icon.clickthrough = true

    local valueText = ui.Text.new(root)
    valueText.font = id.Font.MUSEO_SANS_13PT_BOLD
    valueText.rgba = 0xFFFFFFFF
    valueText:AlignTo(ui.AlignMode.CENTRE)
    valueText.clickthrough = true
    valueText.hidden = true

    return {
        definition = definition,
        root = root,
        background = background,
        fill = fill,
        outline = outline,
        icon = icon,
        valueText = valueText,
        tooltip = nil,
    }
end

local function destroyWidget()
    -- Destroy tooltips before PrettyUI removes the panel and its children.
    for _, bar in pairs(bars) do
        if bar.tooltip ~= nil then bar.tooltip:Destroy() end
    end
    if widget ~= nil then widget:Destroy() end
    widget = nil
    barHost = nil
    bars = {}
    lastLayoutKey = nil
    lastGeometry = nil
end

local function createWidget(parent)
    -- Restore saved geometry or use a shape suited to the selected orientation.
    local defaultWidth = settings.orientation == "vertical" and 120 or 260
    local defaultHeight = settings.orientation == "vertical" and 260 or 120
    local width = storedInt("widget_width", defaultWidth, 80, 800)
    local height = storedInt("widget_height", defaultHeight, 80, 800)
    local x = storedInt("widget_x", 24, -4000, 4000)
    local y = storedInt("widget_y", 160, -4000, 4000)

    widget = prettyui.Panel.new(parent, {
        x = x,
        y = y,
        width = width,
        height = height,
        minWidth = 80,
        minHeight = 80,
        maxWidth = 800,
        maxHeight = 800,
        backgroundAlpha = 0,
        resizable = true,
        scrollable = false,
        tooltip = "Hold Alt and drag to move. Drag an edge or corner to resize.",
    })

    barHost = ui.Layer.new(widget.content)
    barHost:SetSize(0, 0, 1, 1)
    barHost.clickthrough = true
    for _, definition in ipairs(BAR_DEFINITIONS) do
        bars[definition.key] = createBar(barHost, definition)
    end
end

local function ensureWidget()
    -- Recreate the panel after login or a full game interface rebuild.
    if widget ~= nil and ui.Interfaces:GetInterface(widget.interfaceID) == nil then
        destroyWidget()
    end
    if widget ~= nil then return end

    local parent = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    if parent ~= nil then createWidget(parent) end
end

local function activeBars(legacy)
    -- Adrenaline is EOC-only and Special attack is Legacy-only.
    local active = {}
    for _, definition in ipairs(BAR_DEFINITIONS) do
        if settings.enabled[definition.key] and modeAvailable(definition, legacy) then
            table.insert(active, bars[definition.key])
        end
    end
    return active
end

-- Vertical bars sit side-by-side; horizontal bars are stacked top-to-bottom.
local function sizeBar(bar, x, y, width, height, vertical)
    bar.root:SetPos(x, y)
    bar.root:SetSize(width, height)
    bar.background:SetSize(0, 0, 1, 1)
    bar.outline:SetSize(0, 0, 1, 1)

    local iconSize = math.min(20, width - 4, height - 4)
    local enoughRoom = iconSize >= 10
    bar.icon.hidden = not enoughRoom
    bar.valueText.hidden = vertical or not enoughRoom
    if enoughRoom then
        if vertical then
            bar.icon:SetPos(x + math.floor((width - iconSize) / 2), y + 4)
        else
            bar.icon:SetPos(x + 4, y + math.floor((height - iconSize) / 2))
            bar.valueText:SetPos(iconSize + 8, 0)
            bar.valueText:SetSize(math.max(1, width - iconSize - 12), height)
        end
        bar.icon:SetSize(iconSize, iconSize)
    end
end

local function layoutBars(active)
    -- Recalculate only when size, orientation, or visible bars change.
    local width = math.max(1, barHost.width)
    local height = math.max(1, barHost.height)
    local keys = {}
    for _, bar in ipairs(active) do table.insert(keys, bar.definition.key) end
    local layoutKey = table.concat({
        settings.orientation, width, height, table.concat(keys, ","),
    }, ":")
    if layoutKey == lastLayoutKey then return end
    lastLayoutKey = layoutKey

    for _, bar in pairs(bars) do
        bar.root.hidden = true
        bar.icon.hidden = true
    end
    local count = #active
    if count == 0 then return end

    if settings.orientation == "vertical" then
        local available = math.max(count, width - GAP * (count - 1))
        local base = math.floor(available / count)
        local remainder = available - base * count
        local x = 0
        for index, bar in ipairs(active) do
            local barWidth = base + (index <= remainder and 1 or 0)
            bar.root.hidden = false
            sizeBar(bar, x, 0, barWidth, height, true)
            x = x + barWidth + GAP
        end
    else
        local available = math.max(count, height - GAP * (count - 1))
        local base = math.floor(available / count)
        local remainder = available - base * count
        local y = 0
        for index, bar in ipairs(active) do
            local barHeight = base + (index <= remainder and 1 or 0)
            bar.root.hidden = false
            sizeBar(bar, 0, y, width, barHeight, false)
            y = y + barHeight + GAP
        end
    end
end

local function updateFill(bar)
    -- Vertical fills grow upward; horizontal fills grow from left to right.
    local current, maximum = bar.definition.values()
    local value = ratio(current, maximum)
    local formatter = bar.definition.format or wholeValue
    local displayValue = formatter(current)
    bar.valueText.content = displayValue

    -- Vertical bars show the value in an icon tooltip instead of bar text.
    if settings.orientation == "vertical" and not bar.icon.hidden then
        local tooltipText = bar.definition.label .. ": " .. displayValue
        if bar.tooltip == nil then
            bar.tooltip = prettyui.Tooltip.attach(bar.icon, widget.content, {
                text = tooltipText,
                placement = "right",
            })
        else
            bar.tooltip:SetText(tooltipText)
        end
    elseif bar.tooltip ~= nil then
        bar.tooltip:Destroy()
        bar.tooltip = nil
    end
    local width = bar.root.width
    local height = bar.root.height
    local innerWidth = math.max(0, width - BORDER * 2)
    local innerHeight = math.max(0, height - BORDER * 2)

    if settings.orientation == "vertical" then
        local filled = math.floor(innerHeight * value + 0.5)
        bar.fill.hidden = filled <= 0
        if filled > 0 then
            bar.fill:SetPos(BORDER, BORDER + innerHeight - filled)
            bar.fill:SetSize(innerWidth, filled)
        end
    else
        local filled = math.floor(innerWidth * value + 0.5)
        bar.fill.hidden = filled <= 0
        if filled > 0 then
            bar.fill:SetPos(BORDER, BORDER)
            bar.fill:SetSize(filled, innerHeight)
        end
    end
end

local function updateWidget()
    -- Player values are unavailable in the lobby and during world transitions.
    if widget == nil then return end
    if not Player.IsAvailable() then
        widget.root.hidden = true
        return
    end

    local legacy = isLegacyCombat()
    if legacy ~= lastLegacyCombat then
        lastLegacyCombat = legacy
        lastLayoutKey = nil
        updateAllControlModes(legacy)
    end

    local active = activeBars(legacy)
    widget.root.hidden = #active == 0
    if #active == 0 then return end

    layoutBars(active)
    for _, bar in ipairs(active) do updateFill(bar) end
end

local function saveGeometry()
    -- Avoid database writes when the panel has not moved or changed size.
    if widget == nil or widget.root == nil then return end
    local geometry = table.concat({
        widget.root.x, widget.root.y, widget.root.width, widget.root.height,
    }, ":")
    if geometry == lastGeometry then return end
    lastGeometry = geometry
    PersistentDB:SetInt("widget_x", widget.root.x)
    PersistentDB:SetInt("widget_y", widget.root.y)
    PersistentDB:SetInt("widget_width", widget.root.width)
    PersistentDB:SetInt("widget_height", widget.root.height)
end

-- Settings are shared by the ribbon page and Plugin Hub settings layer.
local function eachControl(callback)
    for _, controls in ipairs({ settingsControls, contentControls }) do
        callback(controls)
    end
end

local function setBarEnabled(key, selected)
    settings.enabled[key] = selected
    PersistentDB:SetBool("show_" .. key, selected)
    eachControl(function(controls)
        local control = controls.bars[key]
        if control ~= nil then control:SetSelected(key, selected, false) end
    end)
    lastLayoutKey = nil
    updateWidget()
end

local function setOrientation(value)
    if value ~= "vertical" and value ~= "horizontal" then return end
    if settings.orientation == value then return end
    settings.orientation = value
    PersistentDB:SetString("orientation", value)
    eachControl(function(controls)
        if controls.orientation ~= nil then
            controls.orientation:SetSelectedValue(value, false)
        end
    end)
    lastLayoutKey = nil

    -- Swap width and height when the orientation changes.
    if widget ~= nil then widget:SetSize(widget.height, widget.width) end
    updateWidget()
end

local function createOptionsView(parent)
    -- The settings and ribbon pages use the same option list.
    local controls = { bars = {} }
    local view = prettyui.SimpleView.new(parent, {
        width = parent.width,
        height = parent.height,
    })

    view:AddTitle("STATUS BARS")
    view:AddText("Choose the resources to display. Changes are saved immediately.")

    local legacy = isLegacyCombat()
    for _, definition in ipairs(BAR_DEFINITIONS) do
        local available = modeAvailable(definition, legacy)
        local tooltip
        if not available then tooltip = definition.modeTooltip end
        controls.bars[definition.key] = view:AddCheckboxButton({
            {
                text = definition.label,
                value = definition.key,
                selected = settings.enabled[definition.key],
            },
        }, {
            disabled = not available,
            tooltip = tooltip,
            onChange = function(_, _, key, selected)
                setBarEnabled(key, selected)
            end,
        })
    end

    view:AddTitle("LAYOUT")
    controls.orientation = view:AddRadioButton({
        { text = "Vertical", value = "vertical" },
        { text = "Horizontal", value = "horizontal" },
    }, {
        selectedValue = settings.orientation,
        onChange = function(_, value) setOrientation(value) end,
    })
    view:AddText("Hold Alt and drag the widget to move it.")
    return view, controls
end

local function showSettings(event)
    -- RuneScape clears this layer before sending SettingsLayerReady.
    if settingsView ~= nil then settingsView:Destroy() end
    local parent = event.component
    settingsView, settingsControls = createOptionsView(parent)
end

local function showContent(event)
    -- The ribbon page provides direct access to the same options.
    if contentView ~= nil then contentView:Destroy() end
    contentView, contentControls = createOptionsView(event.component)
end

local function onLogic(event)
    -- Run each task at its own interval on the 50 Hz logic event.
    local tick = event.logicTick
    if tick % MOUNT_INTERVAL == 0 then ensureWidget() end
    if tick % UPDATE_INTERVAL == 0 then updateWidget() end
    if tick % SAVE_INTERVAL == 0 then saveGeometry() end
end

loadSettings()
ensureWidget()
updateWidget()
Event.Logic.Subscribe(EVENT_LOGIC, onLogic)
Event.SettingsLayerReady.Subscribe(EVENT_SETTINGS, showSettings)
Event.ContentLayerReady.Subscribe(EVENT_CONTENT, showContent)

function PluginShutdown()
    -- Remove callbacks and dynamic UI when the plugin is disabled or reloaded.
    Event.Logic.Unsubscribe(EVENT_LOGIC)
    Event.SettingsLayerReady.Unsubscribe(EVENT_SETTINGS)
    Event.ContentLayerReady.Unsubscribe(EVENT_CONTENT)
    saveGeometry()
    if settingsView ~= nil then settingsView:Destroy(); settingsView = nil end
    if contentView ~= nil then contentView:Destroy(); contentView = nil end
    settingsControls = { bars = {} }
    contentControls = { bars = {} }
    destroyWidget()
end
