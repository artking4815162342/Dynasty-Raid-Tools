local DRT = CreateFrame("Frame", "DRTEventFrame")
_G.DRT = DRT

local PREFIX = "DRT2"
local VERSION = "2.0.0"
local CHUNK_SIZE = 170
local LINK_WRAP_START = "<<<<<<<<<<<<<<<<<<<<<<<<<"
local LINK_WRAP_END = ">>>>>>>>>>>>>>>>>>>>>>>>>"
local NOTE_WINDOW_DEFAULT_WIDTH = 300
local NOTE_WINDOW_DEFAULT_HEIGHT = 150
local NOTE_WINDOW_MIN_WIDTH = 80
local NOTE_WINDOW_MIN_HEIGHT = 42
local MINIMAP_ICON_TEXTURE = "Interface\\AddOns\\DRT\\media\\GuildCrest.tga"

local SendAddonMessage = C_ChatInfo and C_ChatInfo.SendAddonMessage or SendAddonMessage
local RegisterAddonMessagePrefix = C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix or RegisterAddonMessagePrefix
local SendChatMessage = C_ChatInfo and C_ChatInfo.SendChatMessage or SendChatMessage

local floor = math.floor
local ceil = math.ceil
local min = math.min
local max = math.max
local abs = math.abs
local tinsert = table.insert
local tremove = table.remove
local sort = table.sort

DRT.notesList = {}
DRT.noteButtons = {}
DRT.playerButtons = {}
DRT.markerButtons = {}
DRT.incomingChunks = {}
DRT.outgoingQueue = {}
DRT.outgoingScheduled = false
DRT.selectedKey = nil
DRT.playerFullName = nil
DRT.realmName = nil

local RAID_MARKERS = {
	{ token = "{rt1}", texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1", name = "Звезда" },
	{ token = "{rt2}", texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_2", name = "Круг" },
	{ token = "{rt3}", texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3", name = "Ромб" },
	{ token = "{rt4}", texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_4", name = "Треугольник" },
	{ token = "{rt5}", texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_5", name = "Луна" },
	{ token = "{rt6}", texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_6", name = "Квадрат" },
	{ token = "{rt7}", texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_7", name = "Крест" },
	{ token = "{rt8}", texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8", name = "Череп" },
}

local ENGLISH_RAID_MARKER_TOKENS = {
	"{star}",
	"{circle}",
	"{diamond}",
	"{triangle}",
	"{moon}",
	"{square}",
	"{cross}",
	"{skull}",
}

local CHAT_RAID_MARKER_TOKENS = {}
for i = 1, #RAID_MARKERS do
	local localizedName = _G["RAID_TARGET_" .. i]
	CHAT_RAID_MARKER_TOKENS[i] = localizedName and ("{" .. localizedName:lower() .. "}") or ENGLISH_RAID_MARKER_TOKENS[i]
	RAID_MARKERS[i].token = CHAT_RAID_MARKER_TOKENS[i] or RAID_MARKERS[i].token
end

local function Print(message)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66d9efDRT:|r " .. tostring(message))
end

local function Trim(value)
	value = tostring(value or "")
	value = value:gsub("^%s+", "")
	value = value:gsub("%s+$", "")
	return value
end

local function EscapePattern(value)
	return tostring(value or ""):gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

local function NormalizeRealm(realm)
	realm = realm or GetRealmName() or ""
	realm = realm:gsub("%s+", "")
	return realm
end

local function NormalizeFullName(name, realm)
	return DRTNotes.NormalizeName(name, realm and realm ~= "" and realm or DRT.realmName or GetRealmName())
end

local function UnitFullNameSafe(unit)
	local name, realm = UnitFullName(unit)
	return NormalizeFullName(name, realm)
end

local function ShortName(fullName)
	if not fullName then
		return ""
	end
	if Ambiguate then
		return Ambiguate(fullName, "short")
	end
	return (fullName:gsub("%-.+$", ""))
end

local function CurrentMillis()
	return (time() * 1000) + floor((GetTime() * 1000) % 1000)
end

local function EnsureDB()
	DRTDB = type(DRTDB) == "table" and DRTDB or {}
	DRTDB.minimap = type(DRTDB.minimap) == "table" and DRTDB.minimap or {}
	DRTDB.minimap.angle = tonumber(DRTDB.minimap.angle) or 225
	DRTDB.wrapLinkedNote = DRTDB.wrapLinkedNote and true or false
end

local function IsOwnNote(note)
	return DRT.store and DRT.store:Own(note) or false
end

local function IsSamePlayerName(a, b)
	return a ~= nil and b ~= nil and NormalizeFullName(a) == NormalizeFullName(b)
end

local function IsCurrentGroupMember(fullName)
	if not fullName then
		return false
	end
	if IsSamePlayerName(fullName, DRT.playerFullName) then
		return true
	end
	if not IsInGroup() then
		return false
	end

	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			if IsSamePlayerName(fullName, UnitFullNameSafe("raid" .. i)) then
				return true
			end
		end
	else
		if IsSamePlayerName(fullName, UnitFullNameSafe("player")) then
			return true
		end
		for i = 1, 4 do
			if IsSamePlayerName(fullName, UnitFullNameSafe("party" .. i)) then
				return true
			end
		end
	end

	return false
end

local function CompareNotes(a, b)
	if IsOwnNote(a) ~= IsOwnNote(b) then return IsOwnNote(a) end

	local ownerA = ShortName(a.owner):lower()
	local ownerB = ShortName(b.owner):lower()
	if ownerA ~= ownerB then
		return ownerA < ownerB
	end

	local titleA = (a.title or ""):lower()
	local titleB = (b.title or ""):lower()
	if titleA ~= titleB then
		return titleA < titleB
	end

	return tostring(a.id or "") < tostring(b.id or "")
end

function DRT:RebuildNotesList()
	self.notesList = self.store:List()
	for _, note in ipairs(self.notesList) do note.key = self.store:Key(note) end
	sort(self.notesList, CompareNotes)
end

function DRT:PruneForeignNotes()
	if not self.store then return end
	self.store:Prune(IsCurrentGroupMember)
	self:UpdateNoteWindow()
end

local function CreateFont(parent, template, text, justify)
	local font = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
	font:SetText(text or "")
	font:SetJustifyH(justify or "LEFT")
	return font
end

local function SetBackdrop(frame, r, g, b, a)
	if not frame.SetBackdrop then
		return
	end
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true,
		tileSize = 32,
		edgeSize = 24,
		insets = { left = 6, right = 6, top = 6, bottom = 6 },
	})
	frame:SetBackdropColor(r or 0, g or 0, b or 0, a or 0.95)
end

local function SetPanelBackdrop(frame)
	if not frame.SetBackdrop then
		return
	end
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = false,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0.01, 0.015, 0.02, 0.72)
	frame:SetBackdropBorderColor(0.32, 0.36, 0.40, 0.95)
end

local function SetPanelBorder(frame, focused, disabled)
	if not frame or not frame.SetBackdropBorderColor then
		return
	end
	if disabled then
		frame:SetBackdropBorderColor(0.22, 0.22, 0.22, 0.75)
	elseif focused then
		frame:SetBackdropBorderColor(0.38, 0.68, 0.92, 1)
	else
		frame:SetBackdropBorderColor(0.32, 0.36, 0.40, 0.95)
	end
end

local function CreateButton(parent, text, width, height)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width or 90, height or 22)
	button:SetText(text or "")
	return button
end

local function CreateCheckButton(parent, name, text)
	local check = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
	check:SetSize(24, 24)
	check.label = CreateFont(parent, "GameFontNormalSmall", text or "", "LEFT")
	check.label:SetPoint("LEFT", check, "RIGHT", 0, 0)
	return check
end

local function SetFrameShown(frame, shown)
	if not frame then
		return
	end
	if shown then
		frame:Show()
	else
		frame:Hide()
	end
end

local function SetButtonEnabled(button, enabled)
	if not button then
		return
	end
	if enabled then
		button:Enable()
	else
		button:Disable()
	end
end

local function SetEditBoxEnabled(editBox, enabled)
	if not editBox then
		return
	end

	editBox.drtEnabled = enabled and true or false
	if enabled then
		if editBox.Enable then
			editBox:Enable()
		end
	else
		if editBox.ClearFocus then
			editBox:ClearFocus()
		end
		if editBox.Disable then
			editBox:Disable()
		end
	end
end

local function FormatTextForDisplay(text)
	text = tostring(text or "")
	text = text:gsub("{[Rr][Tt]([1-8])}", function(index)
		index = tonumber(index)
		local marker = RAID_MARKERS[index]
		if marker and marker.texture then
			return "|T" .. marker.texture .. ":14:14:0:0|t"
		end
		return "{rt" .. tostring(index or "") .. "}"
	end)

	for i = 1, #RAID_MARKERS do
		local marker = RAID_MARKERS[i]
		local token = CHAT_RAID_MARKER_TOKENS[i]
		if marker and marker.texture and token and token ~= "" then
			text = text:gsub(EscapePattern(token), "|T" .. marker.texture .. ":14:14:0:0|t")
		end
	end

	return text
end

function DRT:UpdateNoteWindowText()
	local frame = self.noteWindow
	if not frame or not frame.content then
		return
	end

	local note = self.store:Get(DRTDB.noteWindow.key)
	local text = FormatTextForDisplay(note and note.body or "")
	if Trim(text) == "" then
		text = " "
	end

	frame.content:SetWidth(max(1, frame.scroll:GetWidth()))
	frame.text:SetText(text)
	local textHeight = frame.text:GetStringHeight() or 0
	frame.content:SetHeight(max(frame.scroll:GetHeight(), textHeight + 12))
	frame.scroll:SetVerticalScroll(min(frame.scroll:GetVerticalScroll(), max(0, frame.content:GetHeight() - frame.scroll:GetHeight())))
end

function DRT:SaveNoteWindowPosition()
	local frame = self.noteWindow
	if not frame or not DRTDB or not DRTDB.noteWindow then
		return
	end
	DRTDB.noteWindow.left = frame:GetLeft()
	DRTDB.noteWindow.top = frame:GetTop()
end

function DRT:CreateNoteWindow()
	if self.noteWindow then
		return
	end

	local frame = CreateFrame("Frame", "DRTNoteWindow", UIParent, BackdropTemplateMixin and "BackdropTemplate")
	self.noteWindow = frame
	frame:SetSize(DRTDB.noteWindow.width or NOTE_WINDOW_DEFAULT_WIDTH, DRTDB.noteWindow.height or NOTE_WINDOW_DEFAULT_HEIGHT)
	if DRTDB.noteWindow.left and DRTDB.noteWindow.top then
		frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", DRTDB.noteWindow.left, DRTDB.noteWindow.top)
	else
		frame:SetPoint("TOPLEFT", UIParent, "CENTER", -150, 180)
	end
	frame:SetFrameStrata("HIGH")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:SetResizable(true)
	frame:RegisterForDrag("LeftButton")
	frame:EnableMouse(true)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(NOTE_WINDOW_MIN_WIDTH, NOTE_WINDOW_MIN_HEIGHT, 800, 600)
	elseif frame.SetMinResize then
		frame:SetMinResize(NOTE_WINDOW_MIN_WIDTH, NOTE_WINDOW_MIN_HEIGHT)
	end
	frame:Hide()
	SetPanelBackdrop(frame)
	if frame.SetBackdropColor then
		frame:SetBackdropColor(0, 0, 0, 0.88)
	end

	frame:SetScript("OnDragStart", function(self)
		if self:IsMovable() then
			self:StartMoving()
		end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		DRT:SaveNoteWindowPosition()
	end)
	frame:SetScript("OnSizeChanged", function(self, width, height)
		if DRTDB and DRTDB.noteWindow then
			DRTDB.noteWindow.width = width
			DRTDB.noteWindow.height = height
		end
		DRT:UpdateNoteWindowText()
	end)

	local scroll = CreateFrame("ScrollFrame", nil, frame)
	scroll:SetPoint("TOPLEFT", 8, -8)
	scroll:SetPoint("BOTTOMRIGHT", -8, 16)
	scroll:EnableMouseWheel(true)
	frame.scroll = scroll

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(NOTE_WINDOW_DEFAULT_WIDTH - 16, NOTE_WINDOW_DEFAULT_HEIGHT - 24)
	scroll:SetScrollChild(content)
	frame.content = content

	local text = CreateFont(content, "GameFontHighlightSmall", "", "LEFT")
	text:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
	text:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
	text:SetJustifyV("TOP")
	if text.SetNonSpaceWrap then
		text:SetNonSpaceWrap(true)
	end
	frame.text = text

	scroll:SetScript("OnMouseWheel", function(self, delta)
		local maxScroll = max(0, content:GetHeight() - self:GetHeight())
		local nextScroll = self:GetVerticalScroll() - (delta * 22)
		nextScroll = min(max(nextScroll, 0), maxScroll)
		self:SetVerticalScroll(nextScroll)
	end)

	local title = CreateFont(frame, "GameFontNormalSmall", "DRT", "RIGHT")
	title:SetPoint("BOTTOMRIGHT", -20, 5)
	title:SetTextColor(0.62, 0.66, 0.70, 1)
	frame.title = title

	local resize = CreateFrame("Button", nil, frame)
	resize:SetSize(16, 16)
	resize:SetPoint("BOTTOMRIGHT", -1, 1)
	resize:SetNormalTexture("Interface\\CHATFRAME\\UI-ChatIM-SizeGrabber-Up")
	resize:SetPushedTexture("Interface\\CHATFRAME\\UI-ChatIM-SizeGrabber-Down")
	resize:SetHighlightTexture("Interface\\CHATFRAME\\UI-ChatIM-SizeGrabber-Highlight")
	resize:SetScript("OnMouseDown", function()
		if not DRTDB.noteWindow.locked then
			frame:StartSizing()
		end
	end)
	resize:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		DRT:SaveNoteWindowPosition()
	end)
	frame.resizeButton = resize
end

function DRT:RefreshNoteControls()
	if not self.noteWindowShowCheck then return end
	local note = self:GetSelectedNote()
	self.noteWindowShowCheck:SetChecked(note and DRTDB.noteWindow.enabled and DRTDB.noteWindow.key == self.selectedKey)
	self.noteWindowLockCheck:SetChecked(DRTDB.noteWindow.locked)
	SetButtonEnabled(self.noteWindowShowCheck, note ~= nil)
	SetButtonEnabled(self.noteWindowLockCheck, DRTDB.noteWindow.enabled)
end

function DRT:UpdateNoteWindow()
	if not DRTDB or not DRTDB.noteWindow then
		return
	end

	self:CreateNoteWindow()
	self:UpdateNoteWindowText()

	local frame = self.noteWindow
	local locked = DRTDB.noteWindow.locked and true or false
	frame:SetMovable(not locked)
	frame:EnableMouse(not locked)
	if frame.SetResizable then
		frame:SetResizable(not locked)
	end
	frame.scroll:EnableMouseWheel(not locked)
	SetFrameShown(frame.resizeButton, not locked)

	if DRTDB.noteWindow.enabled and self.store:Get(DRTDB.noteWindow.key) then
		frame:Show()
	else
		frame:Hide()
	end

	self:RefreshNoteControls()
end

function DRT:GetSelectedNote()
	return self.store and self.store:Get(self.selectedKey)
end

function DRT:CaptureDraft()
	if self.loadingEditor or not self.titleEdit or not self.store then return end
	local note = self.store:Get(self.editorKey)
	if not IsOwnNote(note) then return end
	self.store.drafts[self.editorKey] = { title = self.titleEdit:GetText(), body = self.bodyEdit:GetText() }
end

function DRT:SelectNote(key)
	self:CaptureDraft()
	self.selectedKey = key
	self:RefreshUI()
end

local function GetNoteDisplayTitle(note)
	local title = Trim(note.title)
	if title == "" then
		title = "Без названия"
	end

	local owner = ShortName(note.owner)
	if IsOwnNote(note) then
		return "|cff91ff91" .. title .. "|r |cff888888(моя" .. (note.shared and "" or ", приватная") .. ")|r"
	end
	return title .. " |cff888888(" .. owner .. ")|r"
end

function DRT:RefreshNotesList()
	if not self.frame then
		return
	end

	self:RebuildNotesList()

	local lineHeight = 28
	local width = 214
	for i = 1, #self.notesList do
		local button = self.noteButtons[i]
		if not button then
			button = CreateFrame("Button", nil, self.notesListContent)
			button:SetSize(width, lineHeight)
			button.text = CreateFont(button, "GameFontHighlightSmall", "", "LEFT")
			button.text:SetPoint("LEFT", 8, 0)
			button.text:SetPoint("RIGHT", -8, 0)
			button.text:SetWordWrap(false)
			button.bg = button:CreateTexture(nil, "BACKGROUND")
			button.bg:SetAllPoints()
			button.line = button:CreateTexture(nil, "ARTWORK")
			button.line:SetPoint("BOTTOMLEFT", 6, 0)
			button.line:SetPoint("BOTTOMRIGHT", -6, 0)
			button.line:SetHeight(1)
			button.line:SetColorTexture(1, 1, 1, 0.08)
			button:SetScript("OnClick", function(self)
				DRT:SelectNote(self.noteKey)
			end)
			button:SetScript("OnEnter", function(self)
				local note = self.note
				if not note then
					return
				end
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine(note.title ~= "" and note.title or "Без названия")
				if note.owner and note.owner ~= "" then
					GameTooltip:AddLine("Владелец: " .. note.owner, 0.8, 0.8, 0.8)
				end
				if note.updated and note.updated > 0 then
					GameTooltip:AddLine(date("%d.%m.%Y %H:%M", floor(note.updated / 1000)), 0.8, 0.8, 0.8)
				end
				GameTooltip:Show()
			end)
			button:SetScript("OnLeave", GameTooltip_Hide)
			self.noteButtons[i] = button
		end

		local note = self.notesList[i]
		button.noteKey = note.key
		button.note = note
		button:SetPoint("TOPLEFT", 0, -((i - 1) * lineHeight))
		button.text:SetText(GetNoteDisplayTitle(note))
		if note.key == self.selectedKey then
			button.bg:SetColorTexture(0.18, 0.38, 0.42, 0.75)
		elseif i % 2 == 0 then
			button.bg:SetColorTexture(1, 1, 1, 0.04)
		else
			button.bg:SetColorTexture(0, 0, 0, 0)
		end
		button:Show()
	end

	for i = #self.notesList + 1, #self.noteButtons do
		self.noteButtons[i]:Hide()
	end

	self.notesListContent:SetSize(width, max(1, #self.notesList * lineHeight))
end

function DRT:SetEditorEnabled(enabled)
	SetEditBoxEnabled(self.titleEdit, enabled)
	SetEditBoxEnabled(self.bodyEdit, enabled)
	SetPanelBorder(self.titlePanel, false, not (enabled))
	SetPanelBorder(self.bodyPanel, false, not enabled)

	if enabled then
		self.bodyEdit:SetTextColor(1, 1, 1, 1)
	else
		self.bodyEdit:SetTextColor(0.72, 0.72, 0.72, 1)
	end
end

function DRT:RefreshEditor()
	if not self.frame then return end
	local note = self:GetSelectedNote()
	local canEdit = IsOwnNote(note)
	local draft = self.store.drafts[self.selectedKey]
	self.loadingEditor = true
	self.editorKey = self.selectedKey
	self.titleEdit:SetText(draft and draft.title or (note and note.title or ""))
	self.bodyEdit:SetText(draft and draft.body or (note and note.body or ""))
	self.loadingEditor = false
	self.ownerText:SetText(note and ("Владелец: " .. note.owner .. (canEdit and " (моя заметка)" or " (расшаренная)")) or "")
	if note and note.updated and note.updated > 0 then
		self.updatedText:SetText("Обновлено: " .. date("%d.%m.%Y %H:%M:%S", floor(note.updated / 1000)))
	else
		self.updatedText:SetText("")
	end
	self:SetEditorEnabled(canEdit)
	SetButtonEnabled(self.saveButton, canEdit)
	SetButtonEnabled(self.deleteButton, canEdit)
	SetButtonEnabled(self.linkButton, note ~= nil)
	SetButtonEnabled(self.shareCheck, canEdit)
	SetFrameShown(self.shareCheck, canEdit)
	SetFrameShown(self.shareCheck.label, canEdit)
	self.shareCheck:SetChecked(note and note.shared)
	self:RefreshNoteControls()
end

function DRT:RefreshUI()
	if not self.frame or not self.store then return end
	self:CaptureDraft()
	self:RebuildNotesList()
	if not self:GetSelectedNote() then
		self.selectedKey = self.notesList[1] and self.notesList[1].key or nil
	end
	self:RefreshNotesList()
	self:RefreshEditor()
	self:RefreshPlayerButtons()
end

function DRT:RefreshRemoteUI()
	self:UpdateNoteWindow()
	if not self.frame or not self.frame:IsShown() then return end
	-- Network/roster events must not reset text, focus or caret in a local editor.
	if IsOwnNote(self:GetSelectedNote()) then
		self:RefreshNotesList()
	else
		self:RefreshUI()
	end
end

function DRT:InsertText(text)
	if not self.bodyEdit or not self.bodyEdit.drtEnabled then
		return
	end
	self.bodyEdit:SetFocus()
	self.bodyEdit:Insert(text)
end

local function AddRosterEntry(list, unit)
	if not UnitExists(unit) then
		return
	end
	local fullName = UnitFullNameSafe(unit)
	if not fullName then
		return
	end
	local _, class = UnitClass(unit)
	local subgroup = 1
	if unit:find("^raid") then
		subgroup = select(3, GetRaidRosterInfo(tonumber(unit:match("%d+")) or 0)) or 1
	elseif unit == "player" then
		subgroup = 1
	end
	list[#list + 1] = {
		name = fullName,
		shortName = ShortName(fullName),
		class = class,
		subgroup = subgroup,
	}
end

function DRT:GetRoster()
	local roster = {}
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			AddRosterEntry(roster, "raid" .. i)
		end
	elseif IsInGroup() then
		AddRosterEntry(roster, "player")
		for i = 1, 4 do
			AddRosterEntry(roster, "party" .. i)
		end
	else
		AddRosterEntry(roster, "player")
	end

	sort(roster, function(a, b)
		if a.subgroup ~= b.subgroup then
			return a.subgroup < b.subgroup
		end
		return a.shortName < b.shortName
	end)

	return roster
end

function DRT:RefreshPlayerButtons()
	if not self.playersContent then
		return
	end

	local roster = self:GetRoster()
	local buttonWidth = 104
	local buttonHeight = 18
	local columns = 5

	for i = 1, #roster do
		local data = roster[i]
		local button = self.playerButtons[i]
		if not button then
			button = CreateFrame("Button", nil, self.playersContent)
			button:SetSize(buttonWidth, buttonHeight)
			button.text = CreateFont(button, "GameFontHighlightSmall", "", "LEFT")
			button.text:SetPoint("LEFT", 4, 0)
			button.text:SetPoint("RIGHT", -4, 0)
			button.text:SetWordWrap(false)
			button.bg = button:CreateTexture(nil, "BACKGROUND")
			button.bg:SetAllPoints()
			button:SetScript("OnClick", function(self)
				if IsShiftKeyDown() then
					DRT:InsertText(self.shortName)
				else
					DRT:InsertText(self.shortName .. " ")
				end
			end)
			button:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine(self.fullName or "")
				GameTooltip:AddLine("ЛКМ: вставить имя", 0.8, 0.8, 0.8)
				GameTooltip:AddLine("Shift+ЛКМ: без пробела", 0.8, 0.8, 0.8)
				GameTooltip:Show()
			end)
			button:SetScript("OnLeave", GameTooltip_Hide)
			self.playerButtons[i] = button
		end

		local column = (i - 1) % columns
		local row = floor((i - 1) / columns)
		button:SetPoint("TOPLEFT", column * (buttonWidth + 4), -(row * (buttonHeight + 3)))
		button.shortName = data.shortName
		button.fullName = data.name
		button.text:SetText(data.shortName)

		local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[data.class]
		if color then
			button.text:SetTextColor(color.r, color.g, color.b, 1)
			button.bg:SetColorTexture(color.r, color.g, color.b, 0.12)
		else
			button.text:SetTextColor(1, 1, 1, 1)
			button.bg:SetColorTexture(1, 1, 1, 0.06)
		end
		button:Show()
	end

	for i = #roster + 1, #self.playerButtons do
		self.playerButtons[i]:Hide()
	end

	local rows = ceil(max(1, #roster) / columns)
	self.playersContent:SetSize((buttonWidth + 4) * columns, rows * (buttonHeight + 3))
end

function DRT:CreateMarkerButtons(parent)
	for i = 1, #RAID_MARKERS do
		local data = RAID_MARKERS[i]
		local button = CreateFrame("Button", nil, parent)
		button:SetSize(28, 28)
		button:SetPoint("LEFT", parent, "LEFT", (i - 1) * 32, 0)
		button.texture = button:CreateTexture(nil, "ARTWORK")
		button.texture:SetAllPoints()
		button.texture:SetTexture(data.texture)
		button.token = data.token
		button:SetScript("OnClick", function(self)
			DRT:InsertText(self.token .. " ")
		end)
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine(data.name)
			GameTooltip:AddLine(data.token, 0.8, 0.8, 0.8)
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", GameTooltip_Hide)
		self.markerButtons[i] = button
	end
end

function DRT:SaveSelected()
	local note = self:GetSelectedNote()
	if not IsOwnNote(note) then return end
	local ok, err = self.store:Save(note, Trim(self.titleEdit:GetText()), self.bodyEdit:GetText() or "", CurrentMillis())
	if not ok then Print(err or "Не удалось сохранить заметку."); return end
	self.store.drafts[self.selectedKey] = nil
	self.editorKey = nil
	self:PublishNotes()
	self:RefreshUI()
	self:UpdateNoteWindow()
	Print("заметка сохранена.")
end

function DRT:SetSelectedShared(shared)
	local note = self:GetSelectedNote()
	if not IsOwnNote(note) then return end
	local ok, err = self.store:Share(note, shared, CurrentMillis())
	if not ok then Print(err or "Не удалось изменить доступ."); end
	self.shareCheck:SetChecked(note.shared)
	self:PublishNotes()
	self:RefreshNotesList()
end

function DRT:CreateNewNote()
	self:CaptureDraft()
	local note = self.store:Create(CurrentMillis())
	self.selectedKey = self.store:Key(note)
	self:RefreshUI()
	self.titleEdit:SetFocus()
	self.titleEdit:HighlightText()
end

function DRT:DeleteSelected()
	local note = self:GetSelectedNote()
	if not self.store:Delete(note, CurrentMillis()) then return end
	self.editorKey, self.selectedKey = nil, nil
	self:PublishNotes()
	self:RefreshUI()
	self:UpdateNoteWindow()
	Print("заметка удалена.")
end

local function SplitChatLine(line)
	local chunks = {}
	line = tostring(line or "")
	if line == "" then
		chunks[#chunks + 1] = " "
		return chunks
	end

	while #line > 210 do
		local cut = 210
		for i = 210, 140, -1 do
			if line:sub(i, i) == " " then
				cut = i
				break
			end
		end
		-- Do not split a UTF-8 codepoint or a raid-marker token.
		local openToken = line:sub(1, cut):match(".*(){")
		if openToken and not line:sub(openToken, cut):find("}", 1, true) and line:find("}", cut + 1, true) then
			if openToken > 1 then cut = openToken - 1 end
		end
		while cut > 0 and line:byte(cut + 1) and line:byte(cut + 1) >= 128 and line:byte(cut + 1) < 192 do cut = cut - 1 end
		chunks[#chunks + 1] = line:sub(1, cut)
		line = Trim(line:sub(cut + 1))
	end
	if line ~= "" then
		chunks[#chunks + 1] = line
	end
	return chunks
end

local function FormatTextForChat(text)
	text = tostring(text or "")
	text = text:gsub("{[Rr][Tt]([1-8])}", function(index)
		return CHAT_RAID_MARKER_TOKENS[tonumber(index)] or ("{rt" .. tostring(index) .. "}")
	end)
	return text
end

function DRT:GetCurrentLinkText()
	local note = self:GetSelectedNote()
	return note and note.body or "", "текущая заметка"
end

function DRT:LinkCurrentNote()
	local rawText, noteLabel = self:GetCurrentLinkText()
	if Trim(rawText) == "" then
		Print(noteLabel .. " пустая.")
		return
	end
	if DRTDB.wrapLinkedNote then
		rawText = LINK_WRAP_START .. "\n" .. rawText:gsub("\n*$", "") .. "\n" .. LINK_WRAP_END
	end
	local text = FormatTextForChat(rawText)

	local channel = self:GetGroupChannel()
	if not channel then
		Print("вы не в группе или рейде.")
		return
	end

	local queue = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		local chunks = SplitChatLine(line)
		for i = 1, #chunks do
			queue[#queue + 1] = chunks[i]
		end
	end

	local generation = self.groupGeneration
	for i = 1, #queue do
		local message = queue[i]
		C_Timer.After((i - 1) * 0.25, function()
			if DRT.groupGeneration == generation and DRT:GetGroupChannel() == channel then
				SendChatMessage(message, channel)
			end
		end)
	end
end

function DRT:CreateMainFrame()
	if self.frame then
		return
	end

	local frame = CreateFrame("Frame", "DRTMainFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
	self.frame = frame
	frame:SetSize(920, 620)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetClampedToScreen(true)
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()
	SetBackdrop(frame, 0.04, 0.05, 0.06, 0.96)

	local title = CreateFont(frame, "GameFontNormalLarge", "Dynastia Raid Tools", "LEFT")
	title:SetPoint("TOPLEFT", 18, -16)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	local leftTitle = CreateFont(frame, "GameFontNormal", "Заметки", "LEFT")
	leftTitle:SetPoint("TOPLEFT", 18, -54)

	local listPanel = CreateFrame("Frame", nil, frame, BackdropTemplateMixin and "BackdropTemplate")
	listPanel:SetPoint("TOPLEFT", 18, -76)
	listPanel:SetSize(250, 430)
	SetPanelBackdrop(listPanel)
	self.listPanel = listPanel

	local listScroll = CreateFrame("ScrollFrame", "DRTNotesScrollFrame", listPanel, "UIPanelScrollFrameTemplate")
	listScroll:SetPoint("TOPLEFT", 8, -8)
	listScroll:SetSize(216, 414)
	self.notesListScroll = listScroll

	local listContent = CreateFrame("Frame", nil, listScroll)
	listContent:SetSize(214, 414)
	listScroll:SetScrollChild(listContent)
	self.notesListContent = listContent

	local newButton = CreateButton(frame, "Новая", 78, 23)
	newButton:SetPoint("TOPLEFT", listPanel, "BOTTOMLEFT", 0, -10)
	newButton:SetScript("OnClick", function()
		DRT:CreateNewNote()
	end)
	self.newButton = newButton

	local deleteButton = CreateButton(frame, "Удалить", 86, 23)
	deleteButton:SetPoint("LEFT", newButton, "RIGHT", 8, 0)
	deleteButton:SetScript("OnClick", function()
		DRT:DeleteSelected()
	end)
	self.deleteButton = deleteButton

	local linkButton = CreateButton(frame, "Линкануть", 88, 23)
	linkButton:SetPoint("LEFT", deleteButton, "RIGHT", 8, 0)
	linkButton:SetScript("OnClick", function()
		DRT:LinkCurrentNote()
	end)
	self.linkButton = linkButton

	local wrapCheck = CreateFrame("CheckButton", "DRTWrapLinkedNoteCheckButton", frame, "UICheckButtonTemplate")
	wrapCheck:SetSize(24, 24)
	wrapCheck:SetPoint("TOPLEFT", linkButton, "BOTTOMLEFT", -2, -4)
	wrapCheck:SetChecked(DRTDB.wrapLinkedNote)
	wrapCheck:SetScript("OnClick", function(self)
		DRTDB.wrapLinkedNote = self:GetChecked() and true or false
	end)
	wrapCheck:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Обернуть")
		GameTooltip:AddLine("Добавляет строки из < и > при линковке.", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	wrapCheck:SetScript("OnLeave", GameTooltip_Hide)
	self.wrapCheck = wrapCheck

	local wrapLabel = CreateFont(frame, "GameFontNormalSmall", "Обернуть", "LEFT")
	wrapLabel:SetPoint("LEFT", wrapCheck, "RIGHT", 0, 0)
	self.wrapLabel = wrapLabel

	local titleLabel = CreateFont(frame, "GameFontNormal", "Название", "LEFT")
	titleLabel:SetPoint("TOPLEFT", 286, -54)

	local titlePanel = CreateFrame("Frame", nil, frame, BackdropTemplateMixin and "BackdropTemplate")
	titlePanel:SetPoint("TOPLEFT", 286, -76)
	titlePanel:SetSize(360, 28)
	SetPanelBackdrop(titlePanel)
	self.titlePanel = titlePanel

	local titleEdit = CreateFrame("EditBox", "DRTTitleEdit", titlePanel)
	titleEdit:SetPoint("LEFT", 8, 0)
	titleEdit:SetPoint("RIGHT", -8, 0)
	titleEdit:SetHeight(22)
	titleEdit:SetAutoFocus(false)
	titleEdit:SetMaxLetters(80)
	titleEdit:SetFontObject(ChatFontNormal)
	titleEdit:SetTextColor(1, 1, 1, 1)
	if titleEdit.SetJustifyH then
		titleEdit:SetJustifyH("LEFT")
	end
	titleEdit:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	titleEdit:SetScript("OnEnterPressed", function()
		DRT:SaveSelected()
	end)
	titleEdit:SetScript("OnEditFocusGained", function()
		SetPanelBorder(titlePanel, true)
	end)
	titleEdit:SetScript("OnEditFocusLost", function()
		SetPanelBorder(titlePanel, false, not titleEdit.drtEnabled)
	end)
	if titleEdit.SetBlinkSpeed then
		titleEdit:SetBlinkSpeed(0.45)
	end
	titlePanel:SetScript("OnMouseDown", function()
		if titleEdit.drtEnabled then
			titleEdit:SetFocus()
		end
	end)
	titleEdit:SetScript("OnTextChanged", function() DRT:CaptureDraft() end)
	self.titleEdit = titleEdit

	local saveButton = CreateButton(frame, "Сохранить", 94, 23)
	saveButton:SetPoint("LEFT", titlePanel, "RIGHT", 16, 0)
	saveButton:SetScript("OnClick", function()
		DRT:SaveSelected()
	end)
	self.saveButton = saveButton

	local shareCheck = CreateCheckButton(frame, "DRTShareNoteCheckButton", "Шарить")
	shareCheck:SetPoint("LEFT", saveButton, "RIGHT", 10, 0)
	shareCheck:SetScript("OnClick", function(self)
		DRT:SetSelectedShared(self:GetChecked())
	end)
	self.shareCheck = shareCheck

	local ownerText = CreateFont(frame, "GameFontHighlightSmall", "", "LEFT")
	ownerText:SetPoint("TOPLEFT", titlePanel, "BOTTOMLEFT", 0, -8)
	ownerText:SetWidth(590)
	ownerText:SetWordWrap(false)
	ownerText:SetTextColor(0.78, 0.82, 0.86, 1)
	self.ownerText = ownerText

	local updatedText = CreateFont(frame, "GameFontHighlightSmall", "", "RIGHT")
	updatedText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -34, -158)
	updatedText:SetTextColor(0.58, 0.62, 0.66, 1)
	self.updatedText = updatedText

	local noteWindowShowCheck = CreateCheckButton(frame, "DRTShowNoteWindowCheckButton", "Показывать поверх UI")
	noteWindowShowCheck:SetPoint("TOPLEFT", titlePanel, "BOTTOMLEFT", -2, -26)
	noteWindowShowCheck:SetScript("OnClick", function(self)
		DRTDB.noteWindow.enabled = self:GetChecked() and true or false
		DRTDB.noteWindow.key = DRT.selectedKey
		DRT.store.profile.windowKey = DRT.selectedKey
		if DRT.noteWindow then DRT.noteWindow.scroll:SetVerticalScroll(0) end
		DRT:UpdateNoteWindow()
	end)
	noteWindowShowCheck:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Показывать поверх UI")
		GameTooltip:AddLine("Показывает выбранную заметку в отдельном окне.", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	noteWindowShowCheck:SetScript("OnLeave", GameTooltip_Hide)
	self.noteWindowShowCheck = noteWindowShowCheck

	local noteWindowLockCheck = CreateCheckButton(frame, "DRTLockNoteWindowCheckButton", "Закрепить окно")
	noteWindowLockCheck:SetPoint("TOPLEFT", titlePanel, "BOTTOMLEFT", 210, -26)
	noteWindowLockCheck:SetScript("OnClick", function(self)
		DRTDB.noteWindow.locked = self:GetChecked() and true or false
		DRT:UpdateNoteWindow()
	end)
	noteWindowLockCheck:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Закрепить окно")
		GameTooltip:AddLine("Запрещает перемещать и изменять размер окна заметки.", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	noteWindowLockCheck:SetScript("OnLeave", GameTooltip_Hide)
	self.noteWindowLockCheck = noteWindowLockCheck

	local bodyLabel = CreateFont(frame, "GameFontNormal", "Текст", "LEFT")
	bodyLabel:SetPoint("TOPLEFT", 286, -166)

	local bodyPanel = CreateFrame("Frame", nil, frame, BackdropTemplateMixin and "BackdropTemplate")
	bodyPanel:SetPoint("TOPLEFT", 286, -188)
	bodyPanel:SetSize(600, 266)
	SetPanelBackdrop(bodyPanel)
	self.bodyPanel = bodyPanel

	local bodyScroll = CreateFrame("ScrollFrame", "DRTBodyScrollFrame", bodyPanel, "UIPanelScrollFrameTemplate")
	bodyScroll:SetPoint("TOPLEFT", 8, -8)
	bodyScroll:SetSize(566, 250)
	self.bodyScroll = bodyScroll

	local bodyContent = CreateFrame("Frame", nil, bodyScroll)
	bodyContent:SetSize(548, 250)
	bodyContent:EnableMouse(true)
	self.bodyContent = bodyContent

	local bodyEdit = CreateFrame("EditBox", "DRTBodyEdit", bodyContent, BackdropTemplateMixin and "BackdropTemplate")
	bodyEdit:SetPoint("TOPLEFT", bodyContent, "TOPLEFT", 0, 0)
	bodyEdit:SetPoint("TOPRIGHT", bodyContent, "TOPRIGHT", 0, 0)
	bodyEdit:SetMultiLine(true)
	bodyEdit:SetAutoFocus(false)
	bodyEdit:SetFontObject(GameFontHighlight)
	bodyEdit:SetTextColor(1, 1, 1, 1)
	bodyEdit:SetHeight(250)
	if bodyEdit.SetBackdrop then
		bodyEdit:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Buttons\\WHITE8X8",
			edgeSize = 1,
			insets = { left = 0, right = 0, top = 0, bottom = 0 },
		})
		bodyEdit:SetBackdropColor(0, 0, 0, 0)
		bodyEdit:SetBackdropBorderColor(0, 0, 0, 0)
	end
	bodyEdit:SetTextInsets(5, 5, 2, 2)
	bodyEdit:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	bodyEdit:SetScript("OnEditFocusGained", function()
		SetPanelBorder(bodyPanel, true)
	end)
	bodyEdit:SetScript("OnEditFocusLost", function()
		SetPanelBorder(bodyPanel, false, not bodyEdit.drtEnabled)
	end)
	bodyEdit:SetScript("OnCursorChanged", function(self, x, y, width, height)
		local scrollBar = bodyScroll.ScrollBar or _G[bodyScroll:GetName() .. "ScrollBar"]
		if not scrollBar then
			return
		end

		y = abs(y)
		local scrollNow = bodyScroll:GetVerticalScroll()
		local heightNow = bodyScroll:GetHeight()
		if y < scrollNow then
			scrollBar:SetValue(max(floor(y), 0))
		elseif (y + height) > (scrollNow + heightNow) then
			local _, scrollMax = scrollBar:GetMinMaxValues()
			scrollBar:SetValue(min(ceil(y + height - heightNow), scrollMax))
		end
	end)
	bodyEdit:SetScript("OnTextChanged", function(self)
		local height = max(self:GetHeight(), bodyScroll:GetHeight())
		bodyContent:SetHeight(height)
		DRT:CaptureDraft()
	end)
	bodyPanel:SetScript("OnMouseDown", function()
		if bodyEdit.drtEnabled then
			bodyEdit:SetFocus()
		end
	end)
	bodyContent:SetScript("OnMouseDown", function()
		if bodyEdit.drtEnabled then
			bodyEdit:SetFocus()
		end
	end)
	bodyScroll:SetScrollChild(bodyContent)
	self.bodyEdit = bodyEdit

	local markerTitle = CreateFont(frame, "GameFontNormal", "Метки", "LEFT")
	markerTitle:SetPoint("TOPLEFT", bodyPanel, "BOTTOMLEFT", 0, -14)

	local markerFrame = CreateFrame("Frame", nil, frame)
	markerFrame:SetSize(260, 28)
	markerFrame:SetPoint("LEFT", markerTitle, "RIGHT", 16, 0)
	self:CreateMarkerButtons(markerFrame)

	local playersTitle = CreateFont(frame, "GameFontNormal", "Игроки", "LEFT")
	playersTitle:SetPoint("TOPLEFT", markerTitle, "BOTTOMLEFT", 0, -22)

	local playersPanel = CreateFrame("Frame", nil, frame, BackdropTemplateMixin and "BackdropTemplate")
	playersPanel:SetPoint("TOPLEFT", playersTitle, "BOTTOMLEFT", 0, -8)
	playersPanel:SetSize(600, 66)
	SetPanelBackdrop(playersPanel)
	self.playersPanel = playersPanel

	local playersScroll = CreateFrame("ScrollFrame", "DRTPlayersScrollFrame", playersPanel, "UIPanelScrollFrameTemplate")
	playersScroll:SetPoint("TOPLEFT", 8, -6)
	playersScroll:SetSize(566, 54)
	self.playersScroll = playersScroll

	local playersContent = CreateFrame("Frame", nil, playersScroll)
	playersContent:SetSize(540, 54)
	playersScroll:SetScrollChild(playersContent)
	self.playersContent = playersContent

	local isSpecialFrameRegistered = false
	for i = 1, #UISpecialFrames do
		if UISpecialFrames[i] == "DRTMainFrame" then
			isSpecialFrameRegistered = true
			break
		end
	end
	if not isSpecialFrameRegistered then
		tinsert(UISpecialFrames, "DRTMainFrame")
	end
end

function DRT:Toggle()
	if not self.store then return end
	self:CreateMainFrame()
	if self.frame:IsShown() then
		self.frame:Hide()
	else
		self:RefreshUI()
		self.frame:Show()
	end
end

function DRT:UpdateMinimapButtonPosition()
	if not self.minimapButton then
		return
	end

	local angle = DRTDB.minimap.angle or 225
	local radians = math.rad(angle)
	local radius = 80
	local x = math.cos(radians) * radius
	local y = math.sin(radians) * radius
	self.minimapButton:ClearAllPoints()
	self.minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function DRT:CreateMinimapButton()
	if self.minimapButton then
		return
	end

	local button = CreateFrame("Button", "DRTMinimapButton", Minimap)
	self.minimapButton = button
	button:SetSize(32, 32)
	button:SetFrameStrata("MEDIUM")
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(28, 28)
	icon:SetPoint("CENTER", 0, 0)
	icon:SetTexture(MINIMAP_ICON_TEXTURE)
	button.icon = icon

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(52, 52)
	border:SetPoint("CENTER", 10, -8)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	button.border = border

	button:SetScript("OnClick", function()
		DRT:Toggle()
	end)
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			px, py = px / scale, py / scale
			local angle = math.deg(math.atan2(py - my, px - mx))
			DRTDB.minimap.angle = angle
			DRT:UpdateMinimapButtonPosition()
		end)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Dynastia Raid Tools")
		GameTooltip:AddLine("ЛКМ: открыть заметки", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("Перетащить: переместить иконку", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)

	self:UpdateMinimapButtonPosition()
end

function DRT:GetGroupChannel()
	if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
	if IsInRaid() then return "RAID" end
	if IsInGroup() then return "PARTY" end
end

function DRT:QueuePayload(encoded, channel, revision)
	if not encoded or not channel or #encoded > DRTNotes.MAX_WIRE then return end
	self.messageSequence = (self.messageSequence or 0) + 1
	self.outgoingQueue[#self.outgoingQueue + 1] = {
		encoded = encoded, channel = channel, revision = revision, index = 1,
		total = max(1, ceil(#encoded / CHUNK_SIZE)),
		id = tostring(CurrentMillis()) .. "-" .. self.messageSequence,
		generation = self.groupGeneration,
	}
	self:ScheduleAddonFlush()
end

function DRT:ScheduleAddonFlush()
	if self.outgoingScheduled then return end
	self.outgoingScheduled = true
	C_Timer.After(0.35, function()
		DRT.outgoingScheduled = false
		DRT:FlushAddonQueue()
	end)
end

function DRT:FlushAddonQueue()
	local job = self.outgoingQueue[1]
	if not job then return end
	if not self.store or job.generation ~= self.groupGeneration or job.channel ~= self:GetGroupChannel()
		or (job.revision and job.revision ~= self.store.profile.revision) then
		tremove(self.outgoingQueue, 1)
	else
		local first = (job.index - 1) * CHUNK_SIZE + 1
		local message = "C|" .. job.id .. "|" .. job.index .. "|" .. job.total .. "|" .. job.encoded:sub(first, first + CHUNK_SIZE - 1)
		local result = SendAddonMessage(PREFIX, message, job.channel)
		local results = Enum and Enum.SendAddonMessageResult
		local throttled = results and result ~= nil and (result == results.AddonMessageThrottle or result == results.ChannelThrottle)
		if not throttled then
			job.index = job.index + 1
			if job.index > job.total then
				tremove(self.outgoingQueue, 1)
				if job.revision and self.resendAfterFlush then
					self.resendAfterFlush = nil
					self:SendAllNotes()
				end
			end
		end
	end
	if #self.outgoingQueue > 0 then self:ScheduleAddonFlush() end
end

function DRT:RequestSync()
	if not self.store then return end
	local channel = self:GetGroupChannel()
	if not channel then return end
	self:QueuePayload(DRTNotes.Encode(DRTNotes.Pack("REQ", { VERSION })), channel)
end

function DRT:SendAllNotes(requested)
	if not self.store then return end
	local channel = self:GetGroupChannel()
	if not channel then return end
	for _, job in ipairs(self.outgoingQueue) do
		if job.revision == self.store.profile.revision and job.generation == self.groupGeneration then
			-- A reloaded client may have missed the beginning of an in-flight snapshot.
			if requested and job.index > 1 then self.resendAfterFlush = true end
			return
		end
	end
	local encoded, err = self.store:Snapshot()
	if not encoded then Print(err); return end
	self:QueuePayload(encoded, channel, self.store.profile.revision)
end

function DRT:PublishNotes()
	-- Revoking access also cancels unsent chunks containing the previous text.
	wipe(self.outgoingQueue)
	self.resendAfterFlush = nil
	self:SendAllNotes()
end

function DRT:HandlePayload(sender, payload)
	if not self.store or not IsCurrentGroupMember(sender) or IsSamePlayerName(sender, self.playerFullName) then return end
	local kind, fields = DRTNotes.Unpack(payload)
	if kind == "REQ" and #fields == 1 then
		local now = GetTime()
		if self.responsePending then return end
		self.responsePending = true
		local generation = self.groupGeneration
		C_Timer.After(max(0, 2 - (now - (self.lastResponse or -10))), function()
			if generation ~= DRT.groupGeneration then return end
			DRT.responsePending = nil
			DRT.lastResponse = GetTime()
			DRT:SendAllNotes(true)
		end)
	elseif kind == "SNAP" then
		if self.store:Apply(sender, fields, IsCurrentGroupMember) then self:RefreshRemoteUI() end
	end
end

function DRT:HandleAddonMessage(prefix, message, channel, sender)
	if prefix ~= PREFIX or not self.store or type(message) ~= "string" or #message > 255
		or channel ~= self:GetGroupChannel() then return end
	sender = NormalizeFullName(sender)
	if not sender or IsSamePlayerName(sender, self.playerFullName) or not IsCurrentGroupMember(sender) then return end
	local id, index, total, part = message:match("^C|([%w%-]+)|(%d+)|(%d+)|(.*)$")
	index, total = tonumber(index), tonumber(total)
	if not id or #id > 64 or not index or not total or total < 1
		or total > ceil(DRTNotes.MAX_WIRE / CHUNK_SIZE) or index < 1 or index > total
		or #part > CHUNK_SIZE then return end
	local now = GetTime()
	for owner, buffer in pairs(self.incomingChunks) do
		if now - buffer.last > 60 then self.incomingChunks[owner] = nil end
	end
	local buffer = self.incomingChunks[sender]
	if not buffer or buffer.id ~= id then
		if index ~= 1 then return end
		buffer = { id = id, total = total, parts = {}, received = 0, bytes = 0, last = now }
		self.incomingChunks[sender] = buffer
	end
	if buffer.total ~= total then self.incomingChunks[sender] = nil; return end
	if buffer.parts[index] and buffer.parts[index] ~= part then self.incomingChunks[sender] = nil; return end
	buffer.last = now
	if not buffer.parts[index] then
		buffer.parts[index] = part
		buffer.received = buffer.received + 1
		buffer.bytes = buffer.bytes + #part
	end
	if buffer.bytes > DRTNotes.MAX_WIRE then self.incomingChunks[sender] = nil; return end
	if buffer.received == total then
		self.incomingChunks[sender] = nil
		local payload = DRTNotes.Decode(table.concat(buffer.parts))
		if payload then self:HandlePayload(sender, payload) end
	end
end

function DRT:HandleGroupChange()
	if not self.store then return end
	local members = {}
	for _, player in ipairs(self:GetRoster()) do members[#members + 1] = player.name end
	sort(members)
	local signature = (self:GetGroupChannel() or "") .. ":" .. table.concat(members, ",")
	if signature == self.groupSignature then
		self:RefreshPlayerButtons()
		return
	end
	self.groupSignature = signature
	self.groupGeneration = (self.groupGeneration or 0) + 1
	wipe(self.outgoingQueue)
	wipe(self.incomingChunks)
	self.lastResponse = nil
	self.responsePending, self.resendAfterFlush = nil, nil
	self:PruneForeignNotes()
	self:RefreshRemoteUI()
	self:RefreshPlayerButtons()
	local generation = self.groupGeneration
	C_Timer.After(0.6, function()
		if DRT.groupGeneration ~= generation then return end
		DRT:RequestSync()
		DRT:SendAllNotes()
	end)
end

function DRT:OnLogin()
	if self.store then return end
	self.realmName = NormalizeRealm(GetRealmName())
	self.playerFullName = UnitFullNameSafe("player")
	local guid = UnitGUID("player")
	if not guid or not self.playerFullName then
		C_Timer.After(1, function() DRT:OnLogin() end)
		return
	end
	EnsureDB()
	self.store = DRTNotes.Open(DRTDB, guid, self.playerFullName, self.realmName, CurrentMillis())
	DRTDB.noteWindow = type(DRTDB.noteWindow) == "table" and DRTDB.noteWindow or {}
	local window = DRTDB.noteWindow
	window.enabled, window.locked = window.enabled == true, window.locked == true
	window.width = min(800, max(NOTE_WINDOW_MIN_WIDTH, tonumber(window.width) or NOTE_WINDOW_DEFAULT_WIDTH))
	window.height = min(600, max(NOTE_WINDOW_MIN_HEIGHT, tonumber(window.height) or NOTE_WINDOW_DEFAULT_HEIGHT))
	window.left, window.top = tonumber(window.left), tonumber(window.top)
	-- Each character remembers which note is pinned; geometry remains account-wide.
	window.key = self.store.profile.windowKey
	if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(PREFIX) end
	self:CreateMinimapButton()
	self:UpdateNoteWindow()
	self:HandleGroupChange()
end

DRT:SetScript("OnEvent", function(self, event, ...)
	if event == "PLAYER_LOGIN" then
		self:OnLogin()
	elseif event == "CHAT_MSG_ADDON" then
		self:HandleAddonMessage(...)
	elseif event == "GROUP_ROSTER_UPDATE" then
		self:HandleGroupChange()
	end
end)

DRT:RegisterEvent("PLAYER_LOGIN")
DRT:RegisterEvent("CHAT_MSG_ADDON")
DRT:RegisterEvent("GROUP_ROSTER_UPDATE")

SLASH_DRT1 = "/drt"
SLASH_DRT2 = "/дрт"
SlashCmdList.DRT = function(msg)
	if not DRT.store then return end
	msg = Trim(msg):lower()
	if msg == "sync" then
		DRT:RequestSync()
		Print("запрошена синхронизация.")
	else
		DRT:Toggle()
	end
end

function DRT_Toggle()
	if DRT.store then DRT:Toggle() end
end
