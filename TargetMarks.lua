local ADDON_NAME = ...

-- ============================================================
-- Marks, in the display order requested: skull, cross, moon,
-- square, triangle, diamond, circle, star. "index" is Blizzard's
-- own raid target icon numbering (1-8), used by SetRaidTarget /
-- GetRaidTargetIndex.
-- ============================================================
local marks = {
	{ name = "Skull",    index = 8 },
	{ name = "Cross",    index = 7 },
	{ name = "Moon",     index = 5 },
	{ name = "Square",   index = 6 },
	{ name = "Triangle", index = 4 },
	{ name = "Diamond",  index = 3 },
	{ name = "Circle",   index = 2 },
	{ name = "Star",     index = 1 },
}

local ICON_SIZE = 32
local PADDING = 5

local defaults = {
	enabled = true,
	scale = 1.0,
	spacing = 8,
	point = "CENTER",
	x = 0,
	y = 200,
	minimapAngle = 225,
	locked = true,
}

local mainFrame
local moveOverlay
local buttons = {}
local optionsPanel
local minimapButton

-- ============================================================
-- Finding a unit by raid mark, method 1: relation scan.
-- This only sees units you already have some "handle" to (your
-- target, focus, mouseover, group members, or whatever a group
-- member is currently targeting). It is what secure click
-- buttons need to work, and it is combat-safe: updating a
-- secure button's "unit" attribute like this is only allowed
-- while not in combat, but the click itself still fires fine
-- during combat using whatever was last set.
-- ============================================================
local RELATION_UNITS = {}
do
	local base = { "target", "targettarget", "focus", "focustarget", "mouseover" }
	for _, u in ipairs(base) do
		table.insert(RELATION_UNITS, u)
	end
	for i = 1, 4 do
		table.insert(RELATION_UNITS, "party" .. i)
		table.insert(RELATION_UNITS, "partytarget" .. i)
	end
	for i = 1, 40 do
		table.insert(RELATION_UNITS, "raid" .. i)
		table.insert(RELATION_UNITS, "raid" .. i .. "target")
	end
end

local function FindUnitByRelation(markIndex)
	for _, u in ipairs(RELATION_UNITS) do
		if UnitExists(u) and GetRaidTargetIndex(u) == markIndex then
			return u
		end
	end
	return nil
end

-- ============================================================
-- Finding a unit by raid mark, method 1b: nameplateN unit tokens.
-- Officially a Legion+ feature, NOT part of retail 3.3.5 - but
-- confirmed via /tmnp that this server's custom core has backported
-- it (nameplate1 resolved to a live unit with a real name). This is
-- a REAL unit token, exactly like "target" or "party1", so it's
-- just as combat-safe and gives EXACT per-plate resolution - no
-- name-matching ambiguity, solves the duplicate-name case (e.g.
-- Garr's identically-named adds) that the fallback methods below
-- cannot.
-- ============================================================
local NAMEPLATE_UNITS = {}
for i = 1, 40 do
	table.insert(NAMEPLATE_UNITS, "nameplate" .. i)
end

local function FindUnitByNameplate(markIndex)
	for _, u in ipairs(NAMEPLATE_UNITS) do
		if UnitExists(u) and GetRaidTargetIndex(u) == markIndex then
			return u
		end
	end
	return nil
end

-- ============================================================
-- Finding a unit by raid mark, method 2: nameplate scan.
-- This server runs ElvUI, which replaces Blizzard's default
-- nameplates with its own frames named "ElvUI_NamePlateN",
-- parented two levels below WorldFrame (WorldFrame/anchor/
-- ElvUI_NamePlateN). This can find ANY marked unit with a
-- visible nameplate, even one you have no relation to at all
-- (e.g. an untargeted add, or an NPC nobody in your group is
-- looking at).
--
-- Two ways to resolve a plate to a unit, tried in order:
--
-- 1. ElvUI plates carry a plain ".unit" field with the actual
--    Blizzard unit token (confirmed via /tmplate - e.g. "target").
--    If present and valid, we use it directly - this is just as
--    safe/combat-compatible as the relation scan above, since we
--    feed it into the same secure "unit" attribute mechanism, no
--    insecure action call involved.
--
-- 2. Fallback: read the raid-icon texture ElvUI draws directly on
--    the plate (Interface\TargetingFrame\UI-RaidTargetingIcons,
--    a shared 4x2 sheet - each mark occupies a distinct UV
--    coordinate) and click the plate frame directly, the same way
--    a real mouse click on it would work.
--
-- IMPORTANT CAVEAT on method 2 only: this works reliably OUT OF
-- COMBAT. Calling :Click() on the plate from addon Lua during
-- combat may be blocked by Blizzard's protected-function
-- restrictions the same way a raw TargetUnit() call would be -
-- untested on this server. If blocked, it just does nothing (no
-- error), and methods 1/relation-scan remain the reliable
-- combat-safe paths.
-- ============================================================
local RAID_TARGET_UV = {
	[1] = { 0,    0 },    -- star
	[2] = { 0.25, 0 },    -- circle
	[3] = { 0.5,  0 },    -- diamond
	[4] = { 0.75, 0 },    -- triangle
	[5] = { 0,    0.25 }, -- moon
	[6] = { 0.25, 0.25 }, -- square
	[7] = { 0.5,  0.25 }, -- cross
	[8] = { 0.75, 0.25 }, -- skull
}

local function CloseEnough(a, b)
	return a ~= nil and b ~= nil and math.abs(a - b) < 0.01
end

local function GetPlateMarkIndex(plate)
	local regions = { plate:GetRegions() }
	for _, region in ipairs(regions) do
		if region.GetObjectType and region:GetObjectType() == "Texture" and region:IsShown() then
			local texPath = region:GetTexture()
			if texPath and string.find(tostring(texPath), "UI%-RaidTargetingIcons") then
				local u, v = region:GetTexCoord()
				if u then
					for markIndex, uv in pairs(RAID_TARGET_UV) do
						if CloseEnough(u, uv[1]) and CloseEnough(v, uv[2]) then
							return markIndex
						end
					end
				end
			end
		end
	end
	return nil
end

-- Finds nameplate frames regardless of which nameplate implementation is
-- active, since this has changed once already this session (ElvUI vs
-- Blizzard default) and may change again:
--   - ElvUI: named "ElvUI_NamePlateN", nested 2 levels under WorldFrame.
--   - Blizzard default: unnamed, DIRECT children of WorldFrame, identified
--     by carrying the nameplate border/raid-icon texture directly on
--     themselves (confirmed via /tmscan + /tmplate).
local function FindNamePlates()
	local plates = {}
	for _, child in ipairs({ WorldFrame:GetChildren() }) do
		if child.IsVisible and child:IsVisible() then
			if child.GetChildren then
				local ok, grandkids = pcall(function() return { child:GetChildren() } end)
				if ok then
					for _, grandchild in ipairs(grandkids) do
						local name = grandchild.GetName and grandchild:GetName()
						if name and string.find(name, "^ElvUI_NamePlate%d+$") then
							table.insert(plates, grandchild)
						end
					end
				end
			end
			if child.GetRegions then
				local ok2, regions = pcall(function() return { child:GetRegions() } end)
				if ok2 then
					for _, region in ipairs(regions) do
						if region.GetObjectType and region:GetObjectType() == "Texture" then
							local texPath = tostring(region:GetTexture())
							if string.find(texPath, "Nameplate%-Border") or string.find(texPath, "UI%-RaidTargetingIcons") then
								table.insert(plates, child)
								break
							end
						end
					end
				end
			end
		end
	end
	return plates
end

-- Reads the mob's name off the plate. The name/level FontStrings
-- are NOT direct regions of the ElvUI_NamePlateN frame itself -
-- confirmed via /tmplate: they live on its child "...HealthBar"
-- frame (e.g. ElvUI_NamePlate2HealthBar) one level down. So this
-- recurses into children (a couple levels, to be safe) instead of
-- only checking the plate's own regions.
-- Strips embedded color/texture escape codes (|cffRRGGBB...|r,
-- |Tpath:size|t) some UIs bake directly into FontString text - these
-- render invisibly in chat/tooltips but are real characters that
-- would break an exact "/target <name>" match.
local function StripEscapeCodes(text)
	text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
	text = text:gsub("|r", "")
	text = text:gsub("|T.-|t", "")
	return text
end

local function GetPlateName(plate)
	local function scan(frame, depth)
		if depth > 2 then
			return nil
		end
		local ok, regions = pcall(function() return { frame:GetRegions() } end)
		if ok then
			for _, region in ipairs(regions) do
				if region.GetObjectType and region:GetObjectType() == "FontString" then
					local text = region:GetText()
					if text and text ~= "" and not tonumber(text) then
						return StripEscapeCodes(text)
					end
				end
			end
		end
		local ok2, children = pcall(function() return { frame:GetChildren() } end)
		if ok2 then
			for _, child in ipairs(children) do
				local found = scan(child, depth + 1)
				if found then
					return found
				end
			end
		end
		return nil
	end
	return scan(plate, 0)
end

-- Returns unit, plate, name. "unit" is set only when a real secure
-- unit token was found (method 1). Otherwise "plate" is set so the
-- caller can either securely click-delegate to it (type="click" +
-- clickbutton=plate, combat-safe, resolves the EXACT instance - only
-- possible if plate is a real clickable Button, not a plain Frame)
-- or fall back to "name" (a "/target <name>" macro, fuzzy: can
-- select the wrong unit if multiple share the same name).
local function FindUnitByMark(markIndex)
	for _, plate in ipairs(FindNamePlates()) do
		-- Method 1: plain .unit field, safe, no click needed.
		if plate.unit and UnitExists(plate.unit) and GetRaidTargetIndex(plate.unit) == markIndex then
			return plate.unit, nil, nil
		end
	end
	for _, plate in ipairs(FindNamePlates()) do
		-- Method 2: read the raid-icon texture, then either click-delegate
		-- or fall back to a name-macro.
		local ok, found = pcall(GetPlateMarkIndex, plate)
		if ok and found == markIndex then
			return nil, plate, GetPlateName(plate)
		end
	end
	return nil, nil, nil
end

-- ============================================================
-- UI
-- ============================================================
local function InitDB()
	TargetMarksDB = TargetMarksDB or {}
	for k, v in pairs(defaults) do
		if TargetMarksDB[k] == nil then
			TargetMarksDB[k] = v
		end
	end
end

local function Reposition()
	local spacing = TargetMarksDB.spacing
	local prev
	for i, mark in ipairs(marks) do
		local btn = buttons[mark.name]
		btn:ClearAllPoints()
		if i == 1 then
			btn:SetPoint("LEFT", mainFrame, "LEFT", PADDING, 0)
		else
			btn:SetPoint("LEFT", prev, "RIGHT", spacing, 0)
		end
		prev = btn
	end
	local totalWidth = (#marks * ICON_SIZE) + ((#marks - 1) * spacing) + (PADDING * 2)
	mainFrame:SetWidth(totalWidth)
	mainFrame:SetHeight(ICON_SIZE + (PADDING * 2))
end

local function CreateMainFrame()
	mainFrame = CreateFrame("Frame", "TargetMarksFrame", UIParent)
	mainFrame:SetPoint(TargetMarksDB.point, UIParent, TargetMarksDB.point, TargetMarksDB.x, TargetMarksDB.y)
	mainFrame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	mainFrame:SetBackdropColor(0, 0, 0, 0.6)
	mainFrame:SetBackdropBorderColor(1, 1, 1, 0.8)
	mainFrame:SetMovable(true)

	-- Full-coverage overlay used only while unlocked, so you can drag
	-- from anywhere on the bar (including over the icon buttons)
	-- instead of hunting for a thin edge. While locked, this overlay
	-- is hidden and the icon buttons underneath receive clicks normally.
	moveOverlay = CreateFrame("Frame", "TargetMarksMoveOverlay", mainFrame)
	moveOverlay:SetAllPoints(mainFrame)
	moveOverlay:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
	moveOverlay:EnableMouse(true)
	moveOverlay:RegisterForDrag("LeftButton")
	moveOverlay:Hide()

	local highlight = moveOverlay:CreateTexture(nil, "OVERLAY")
	highlight:SetAllPoints()
	highlight:SetTexture(1, 1, 0, 0.25)

	moveOverlay:SetScript("OnDragStart", function()
		mainFrame:StartMoving()
	end)
	moveOverlay:SetScript("OnDragStop", function()
		mainFrame:StopMovingOrSizing()
		local point, _, _, x, y = mainFrame:GetPoint()
		TargetMarksDB.point = point
		TargetMarksDB.x = x
		TargetMarksDB.y = y
	end)
end

local function SetLocked(locked)
	TargetMarksDB.locked = locked
	if locked then
		moveOverlay:Hide()
	else
		moveOverlay:Show()
	end
end

-- Sets up btn's secure attributes so its next click targets
-- whatever currently has mark.index. Only allowed to run outside
-- combat (secure attribute changes are blocked in combat), but the
-- click itself still fires fine using whatever was last set.
-- Tries, in order:
--   1. relation scan (real unit token, exact)
--   2. nameplateN token scan (real unit token, exact - confirmed via
--      /tmnp this core backported it; solves duplicate-name cases
--      like Garr's adds that nothing below this can)
--   3. plate .unit field (real unit token, exact)
--   4. secure click-delegation (type="click" + clickbutton=plate) -
--      combat-safe AND resolves the exact plate instance, but only
--      works if the plate is a genuine clickable Button (ElvUI's
--      plates on this server are plain Frames and fail this; testing
--      whether Blizzard's default nameplates support it)
--   5. name-based /target macro (fuzzy: can select the wrong unit if
--      multiple share the same name)
local function UpdateButtonAttributes(btn, mark)
	local unit = FindUnitByRelation(mark.index)
	if not unit then
		unit = FindUnitByNameplate(mark.index)
	end
	if unit then
		btn:SetAttribute("type", "target")
		btn:SetAttribute("unit", unit)
		btn:SetAttribute("clickbutton", nil)
		btn:SetAttribute("macrotext", nil)
		return true
	end
	local elvUnit, plate, name = FindUnitByMark(mark.index)
	if elvUnit then
		btn:SetAttribute("type", "target")
		btn:SetAttribute("unit", elvUnit)
		btn:SetAttribute("clickbutton", nil)
		btn:SetAttribute("macrotext", nil)
		return true
	end
	if plate and plate.Click then
		btn:SetAttribute("type", "click")
		btn:SetAttribute("clickbutton", plate)
		btn:SetAttribute("unit", nil)
		btn:SetAttribute("macrotext", nil)
		return true
	end
	if name then
		btn:SetAttribute("type", "macro")
		btn:SetAttribute("unit", nil)
		btn:SetAttribute("clickbutton", nil)
		btn:SetAttribute("macrotext", "/target " .. name)
		return true
	end
	return false
end

local function CreateButtons()
	for _, mark in ipairs(marks) do
		local btn = CreateFrame("Button", "TargetMarksButton" .. mark.name, mainFrame, "SecureActionButtonTemplate")
		btn:SetSize(ICON_SIZE, ICON_SIZE)
		btn:SetAttribute("type", "target")
		btn:RegisterForClicks("LeftButtonUp")

		local tex = btn:CreateTexture(nil, "ARTWORK")
		tex:SetAllPoints()
		tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. mark.index)
		btn.texture = tex

		btn:SetScript("PreClick", function(self)
			if InCombatLockdown() then
				return
			end
			UpdateButtonAttributes(self, mark)
		end)

		btn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText("Target " .. mark.name)
			GameTooltip:Show()
		end)
		btn:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)

		buttons[mark.name] = btn
	end
end

-- ============================================================
-- Background relation-scan refresh, so secure buttons already
-- have their best-known unit cached before combat starts.
-- ============================================================
local scanTimer = 0
local function OnUpdate(self, elapsed)
	scanTimer = scanTimer + elapsed
	if scanTimer < 0.5 then
		return
	end
	scanTimer = 0
	if InCombatLockdown() or not TargetMarksDB.enabled then
		return
	end
	for _, mark in ipairs(marks) do
		local btn = buttons[mark.name]
		if btn then
			UpdateButtonAttributes(btn, mark)
		end
	end
end

-- ============================================================
-- Options panel
-- ============================================================
local function CreateOptionsPanel()
	local panel = CreateFrame("Frame", "TargetMarksOptionsPanel", UIParent)
	panel.name = "Target Marks"
	panel:Hide()

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Target Marks")

	local enableCheck = CreateFrame("CheckButton", "TargetMarksEnableCheck", panel, "UICheckButtonTemplate")
	enableCheck:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
	_G[enableCheck:GetName() .. "Text"]:SetText("Enable")
	enableCheck:SetScript("OnClick", function(self)
		TargetMarksDB.enabled = self:GetChecked() and true or false
		if TargetMarksDB.enabled then
			mainFrame:Show()
		else
			mainFrame:Hide()
		end
	end)

	local scaleSlider = CreateFrame("Slider", "TargetMarksScaleSlider", panel, "OptionsSliderTemplate")
	scaleSlider:SetPoint("TOPLEFT", enableCheck, "BOTTOMLEFT", 4, -28)
	scaleSlider:SetWidth(200)
	scaleSlider:SetMinMaxValues(0.5, 2.0)
	scaleSlider:SetValueStep(0.05)
	_G[scaleSlider:GetName() .. "Low"]:SetText("0.5")
	_G[scaleSlider:GetName() .. "High"]:SetText("2.0")
	_G[scaleSlider:GetName() .. "Text"]:SetText("Scale")
	scaleSlider:SetScript("OnValueChanged", function(self, value)
		value = math.floor(value * 20 + 0.5) / 20
		TargetMarksDB.scale = value
		mainFrame:SetScale(value)
	end)

	local spacingSlider = CreateFrame("Slider", "TargetMarksSpacingSlider", panel, "OptionsSliderTemplate")
	spacingSlider:SetPoint("TOPLEFT", scaleSlider, "BOTTOMLEFT", 0, -40)
	spacingSlider:SetWidth(200)
	spacingSlider:SetMinMaxValues(0, 40)
	spacingSlider:SetValueStep(1)
	_G[spacingSlider:GetName() .. "Low"]:SetText("0")
	_G[spacingSlider:GetName() .. "High"]:SetText("40")
	_G[spacingSlider:GetName() .. "Text"]:SetText("Icon Spacing")
	spacingSlider:SetScript("OnValueChanged", function(self, value)
		value = math.floor(value + 0.5)
		TargetMarksDB.spacing = value
		Reposition()
	end)

	local unlockCheck = CreateFrame("CheckButton", "TargetMarksUnlockCheck", panel, "UICheckButtonTemplate")
	unlockCheck:SetPoint("TOPLEFT", spacingSlider, "BOTTOMLEFT", -4, -32)
	_G[unlockCheck:GetName() .. "Text"]:SetText("Unlock to move (drag the bar anywhere)")
	unlockCheck:SetScript("OnClick", function(self)
		SetLocked(not (self:GetChecked() and true or false))
	end)

	panel:SetScript("OnShow", function()
		enableCheck:SetChecked(TargetMarksDB.enabled)
		scaleSlider:SetValue(TargetMarksDB.scale)
		spacingSlider:SetValue(TargetMarksDB.spacing)
		unlockCheck:SetChecked(not TargetMarksDB.locked)
	end)

	InterfaceOptions_AddCategory(panel)
	optionsPanel = panel
end

-- ============================================================
-- Minimap button (hand-rolled, no external libraries)
-- ============================================================
local function UpdateMinimapPos()
	local angle = math.rad(TargetMarksDB.minimapAngle)
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

local function CreateMinimapButton()
	minimapButton = CreateFrame("Button", "TargetMarksMinimapButton", Minimap)
	minimapButton:SetSize(31, 31)
	minimapButton:SetFrameStrata("MEDIUM")
	minimapButton:SetFrameLevel(8)
	minimapButton:RegisterForClicks("LeftButtonUp")
	minimapButton:RegisterForDrag("LeftButton")

	local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetPoint("CENTER", 0, 1)
	icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")

	local border = minimapButton:CreateTexture(nil, "OVERLAY")
	border:SetSize(54, 54)
	border:SetPoint("TOPLEFT")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	minimapButton:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			px, py = px / scale, py / scale
			local angle = math.atan2(py - my, px - mx)
			TargetMarksDB.minimapAngle = math.deg(angle)
			UpdateMinimapPos()
		end)
	end)
	minimapButton:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)

	minimapButton:SetScript("OnClick", function()
		InterfaceOptionsFrame_OpenToCategory(optionsPanel)
		InterfaceOptionsFrame_OpenToCategory(optionsPanel)
	end)

	minimapButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Target Marks")
		GameTooltip:AddLine("Click to open settings", 1, 1, 1)
		GameTooltip:Show()
	end)
	minimapButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	UpdateMinimapPos()
end

-- ============================================================
-- Load
-- ============================================================
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
		InitDB()
		CreateMainFrame()
		CreateButtons()
		Reposition()
		mainFrame:SetScale(TargetMarksDB.scale)
		if not TargetMarksDB.enabled then
			mainFrame:Hide()
		end
		CreateOptionsPanel()
		CreateMinimapButton()
		SetLocked(TargetMarksDB.locked)
		self:SetScript("OnUpdate", OnUpdate)
		self:UnregisterEvent("ADDON_LOADED")
	end
end)
