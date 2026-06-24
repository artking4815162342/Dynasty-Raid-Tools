local ADDON_NAME = ...

local DRT = CreateFrame("Frame", "DRTEventFrame")
_G.DRT = DRT

local PREFIX = "DRT"
local VERSION = "1.0.0"
local CHUNK_SIZE = 170
local NOTE_KEY_SEPARATOR = "\030"
local MAIN_KEY = "__main"
local LINK_WRAP_START = "<<<<<<<<<<<<<<<<<<<<<<<<<"
local LINK_WRAP_END = ">>>>>>>>>>>>>>>>>>>>>>>>>"
local MAIN_NOTE_WINDOW_DEFAULT_WIDTH = 300
local MAIN_NOTE_WINDOW_DEFAULT_HEIGHT = 150
local MAIN_NOTE_WINDOW_MIN_WIDTH = 80
local MAIN_NOTE_WINDOW_MIN_HEIGHT = 42
local MINIMAP_ICON_TEXTURE = "Interface\\AddOns\\DRT\\media\\GuildCrest.tga"

local SendAddonMessage = C_ChatInfo and C_ChatInfo.SendAddonMessage or SendAddonMessage
local RegisterAddonMessagePrefix = C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix or RegisterAddonMessagePrefix
local SendChatMessage = C_ChatInfo and C_ChatInfo.SendChatMessage or SendChatMessage

local floor = math.floor
local ceil = math.ceil
local min = math.min
local max = math.max
local abs = math.abs
local random = math.random
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
DRT.wasGrouped = nil
DRT.selectedKey = MAIN_KEY
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
	if not name or name == "" then
		return nil
	end
	if name:find("-", 1, true) then
		return name
	end
	realm = NormalizeRealm(realm or DRT.realmName)
	if realm ~= "" then
		return name .. "-" .. realm
	end
	return name
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

local function NoteKey(owner, id)
	return tostring(owner or "") .. NOTE_KEY_SEPARATOR .. tostring(id or "")
end

local function CurrentMillis()
	return (time() * 1000) + floor((GetTime() * 1000) % 1000)
end

local function EnsureDB()
	DRTDB = DRTDB or {}
	DRTDB.notes = DRTDB.notes or {}
	DRTDB.main = DRTDB.main or {}
	DRTDB.main.text = DRTDB.main.text or ""
	DRTDB.main.updated = tonumber(DRTDB.main.updated or 0) or 0
	DRTDB.main.owner = DRTDB.main.owner or ""
	DRTDB.minimap = DRTDB.minimap or {}
	if DRTDB.minimap.angle == nil then
		DRTDB.minimap.angle = 225
	end
	DRTDB.wrapLinkedNote = DRTDB.wrapLinkedNote and true or false
	DRTDB.mainWindow = DRTDB.mainWindow or {}
	DRTDB.mainWindow.enabled = DRTDB.mainWindow.enabled and true or false
	DRTDB.mainWindow.locked = DRTDB.mainWindow.locked and true or false
	DRTDB.mainWindow.width = max(MAIN_NOTE_WINDOW_MIN_WIDTH, tonumber(DRTDB.mainWindow.width or MAIN_NOTE_WINDOW_DEFAULT_WIDTH) or MAIN_NOTE_WINDOW_DEFAULT_WIDTH)
	DRTDB.mainWindow.height = max(MAIN_NOTE_WINDOW_MIN_HEIGHT, tonumber(DRTDB.mainWindow.height or MAIN_NOTE_WINDOW_DEFAULT_HEIGHT) or MAIN_NOTE_WINDOW_DEFAULT_HEIGHT)
	DRTDB.mainWindow.left = tonumber(DRTDB.mainWindow.left)
	DRTDB.mainWindow.top = tonumber(DRTDB.mainWindow.top)
end

local function Encode(value)
	value = tostring(value or "")
	return value:gsub("([^A-Za-z0-9_%.%-])", function(char)
		return string.format("%%%02X", char:byte())
	end)
end

local function Decode(value)
	value = tostring(value or "")
	return value:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end)
end

local function BuildPayload(kind, ...)
	local payload = tostring(kind or "") .. "|"
	for i = 1, select("#", ...) do
		local field = tostring(select(i, ...) or "")
		payload = payload .. #field .. ":" .. field
	end
	return payload
end

local function ParsePayload(payload)
	local splitAt = payload:find("|", 1, true)
	if not splitAt then
		return nil
	end

	local kind = payload:sub(1, splitAt - 1)
	local fields = {}
	local pos = splitAt + 1

	while pos <= #payload do
		local colon = payload:find(":", pos, true)
		if not colon then
			return nil
		end

		local len = tonumber(payload:sub(pos, colon - 1))
		if not len then
			return nil
		end

		local startPos = colon + 1
		local endPos = startPos + len - 1
		fields[#fields + 1] = payload:sub(startPos, endPos)
		pos = endPos + 1
	end

	return kind, fields
end

local function SplitChunkMessage(message)
	local tag, id, index, total, part = message:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
	return tag, id, tonumber(index), tonumber(total), part
end

function DRT:ScheduleAddonFlush()
	if self.outgoingScheduled then
		return
	end
	self.outgoingScheduled = true
	C_Timer.After(0.12, function()
		DRT.outgoingScheduled = false
		DRT:FlushAddonQueue()
	end)
end

function DRT:QueueAddonMessage(message, channel, target)
	if not SendAddonMessage or not channel then
		return
	end

	self.outgoingQueue[#self.outgoingQueue + 1] = {
		message = message,
		channel = channel,
		target = target,
	}
	self:ScheduleAddonFlush()
end

function DRT:FlushAddonQueue()
	local sent = 0
	while sent < 8 and #self.outgoingQueue > 0 do
		local entry = tremove(self.outgoingQueue, 1)
		if entry.target then
			SendAddonMessage(PREFIX, entry.message, entry.channel, entry.target)
		else
			SendAddonMessage(PREFIX, entry.message, entry.channel)
		end
		sent = sent + 1
	end

	if #self.outgoingQueue > 0 then
		self:ScheduleAddonFlush()
	end
end

local function GetGroupChannel()
	if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
		return "INSTANCE_CHAT"
	end
	if IsInRaid() then
		return "RAID"
	end
	if IsInGroup() then
		return "PARTY"
	end
	return nil
end

local function GetBroadcastChannels()
	local channels = {}
	local groupChannel = GetGroupChannel()
	if groupChannel then
		channels[#channels + 1] = groupChannel
	end
	return channels
end

local function SendPayload(payload, channel, target)
	if not SendAddonMessage or not channel then
		return
	end

	local encoded = Encode(payload)
	local total = max(1, ceil(#encoded / CHUNK_SIZE))
	local id = tostring(CurrentMillis()) .. tostring(random(1000, 9999))

	for index = 1, total do
		local startPos = ((index - 1) * CHUNK_SIZE) + 1
		local part = encoded:sub(startPos, startPos + CHUNK_SIZE - 1)
		local message = "C|" .. id .. "|" .. index .. "|" .. total .. "|" .. part
		DRT:QueueAddonMessage(message, channel, target)
	end
end

local function BroadcastPayload(payload)
	local channels = GetBroadcastChannels()
	for i = 1, #channels do
		SendPayload(payload, channels[i])
	end
end

local function BuildNotePayload(note)
	return BuildPayload(
		"NOTE",
		note.id or "",
		note.owner or "",
		tostring(note.updated or 0),
		note.deleted and "1" or "0",
		note.title or "",
		note.body or ""
	)
end

local function BuildMainPayload()
	return BuildPayload(
		"MAIN",
		tostring(DRTDB.main.updated or 0),
		DRTDB.main.owner or "",
		DRTDB.main.text or ""
	)
end

local function BuildOwnerNotesPayload(owner, ids)
	return BuildPayload("OWNER", owner or "", table.concat(ids or {}, ","))
end

local function IsOwnNote(note)
	return note and note.owner == DRT.playerFullName
end

local function IsSamePlayerName(a, b)
	if not a or not b then
		return false
	end
	if a == b then
		return true
	end
	if Ambiguate then
		return Ambiguate(a, "none") == Ambiguate(b, "none")
	end
	return false
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

local function ShouldKeepRemoteNote(note)
	return IsOwnNote(note) or IsCurrentGroupMember(note and note.owner)
end

local function CompareNotes(a, b)
	if a.isMain then
		return true
	end
	if b.isMain then
		return false
	end

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
	wipe(self.notesList)
	self.notesList[#self.notesList + 1] = {
		key = MAIN_KEY,
		isMain = true,
		title = "Главная заметка",
		owner = DRTDB.main.owner or "",
		body = DRTDB.main.text or "",
		updated = DRTDB.main.updated or 0,
	}

	for key, note in pairs(DRTDB.notes) do
		if type(note) == "table" and not note.deleted and ShouldKeepRemoteNote(note) then
			note.key = key
			self.notesList[#self.notesList + 1] = note
		end
	end

	sort(self.notesList, CompareNotes)
end

function DRT:PruneForeignNotes(onlyUnavailable)
	local changed = false
	for key, note in pairs(DRTDB.notes) do
		if type(note) == "table" and note.deleted == false then
			note.deleted = nil
			changed = true
		end
		local shouldRemove = type(note) ~= "table" or note.deleted
		if not shouldRemove and not IsOwnNote(note) then
			shouldRemove = (not onlyUnavailable) or (not IsCurrentGroupMember(note.owner))
		end
		if shouldRemove then
			DRTDB.notes[key] = nil
			changed = true
			if self.selectedKey == key then
				self.selectedKey = MAIN_KEY
			end
		end
	end
	return changed
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

function DRT:UpdateMainNoteWindowText()
	local frame = self.mainNoteWindow
	if not frame then
		return
	end

	local text = FormatTextForDisplay(DRTDB.main.text or "")
	if Trim(text) == "" then
		text = " "
	end

	frame.content:SetWidth(max(1, frame.scroll:GetWidth()))
	frame.text:SetText(text)
	local textHeight = frame.text:GetStringHeight() or 0
	frame.content:SetHeight(max(frame.scroll:GetHeight(), textHeight + 12))
end

function DRT:SaveMainNoteWindowPosition()
	local frame = self.mainNoteWindow
	if not frame or not DRTDB or not DRTDB.mainWindow then
		return
	end
	DRTDB.mainWindow.left = frame:GetLeft()
	DRTDB.mainWindow.top = frame:GetTop()
end

function DRT:CreateMainNoteWindow()
	if self.mainNoteWindow then
		return
	end

	local frame = CreateFrame("Frame", "DRTMainNoteWindow", UIParent, BackdropTemplateMixin and "BackdropTemplate")
	self.mainNoteWindow = frame
	frame:SetSize(DRTDB.mainWindow.width or MAIN_NOTE_WINDOW_DEFAULT_WIDTH, DRTDB.mainWindow.height or MAIN_NOTE_WINDOW_DEFAULT_HEIGHT)
	if DRTDB.mainWindow.left and DRTDB.mainWindow.top then
		frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", DRTDB.mainWindow.left, DRTDB.mainWindow.top)
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
		frame:SetResizeBounds(MAIN_NOTE_WINDOW_MIN_WIDTH, MAIN_NOTE_WINDOW_MIN_HEIGHT, 800, 600)
	elseif frame.SetMinResize then
		frame:SetMinResize(MAIN_NOTE_WINDOW_MIN_WIDTH, MAIN_NOTE_WINDOW_MIN_HEIGHT)
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
		DRT:SaveMainNoteWindowPosition()
	end)
	frame:SetScript("OnSizeChanged", function(self, width, height)
		if DRTDB and DRTDB.mainWindow then
			DRTDB.mainWindow.width = width
			DRTDB.mainWindow.height = height
		end
		DRT:UpdateMainNoteWindowText()
	end)

	local scroll = CreateFrame("ScrollFrame", nil, frame)
	scroll:SetPoint("TOPLEFT", 8, -8)
	scroll:SetPoint("BOTTOMRIGHT", -8, 16)
	scroll:EnableMouseWheel(true)
	frame.scroll = scroll

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(MAIN_NOTE_WINDOW_DEFAULT_WIDTH - 16, MAIN_NOTE_WINDOW_DEFAULT_HEIGHT - 24)
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
		if not DRTDB.mainWindow.locked then
			frame:StartSizing()
		end
	end)
	resize:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		DRT:SaveMainNoteWindowPosition()
	end)
	frame.resizeButton = resize
end

function DRT:RefreshMainNoteControls(isMain)
	if not self.mainWindowShowCheck then
		return
	end

	SetFrameShown(self.mainWindowShowCheck, isMain)
	SetFrameShown(self.mainWindowShowCheck.label, isMain)
	SetFrameShown(self.mainWindowLockCheck, isMain)
	SetFrameShown(self.mainWindowLockCheck.label, isMain)

	if isMain then
		self.mainWindowShowCheck:SetChecked(DRTDB.mainWindow.enabled)
		self.mainWindowLockCheck:SetChecked(DRTDB.mainWindow.locked)
	end
end

function DRT:UpdateMainNoteWindow()
	if not DRTDB or not DRTDB.mainWindow then
		return
	end

	self:CreateMainNoteWindow()
	self:UpdateMainNoteWindowText()

	local frame = self.mainNoteWindow
	local locked = DRTDB.mainWindow.locked and true or false
	frame:SetMovable(not locked)
	frame:EnableMouse(not locked)
	if frame.SetResizable then
		frame:SetResizable(not locked)
	end
	frame.scroll:EnableMouseWheel(not locked)
	SetFrameShown(frame.resizeButton, not locked)

	if DRTDB.mainWindow.enabled then
		frame:Show()
	else
		frame:Hide()
	end

	self:RefreshMainNoteControls(self.selectedKey == MAIN_KEY)
end

function DRT:GetSelectedNote()
	if self.selectedKey == MAIN_KEY then
		return {
			key = MAIN_KEY,
			isMain = true,
			title = "Главная заметка",
			owner = DRTDB.main.owner or "",
			body = DRTDB.main.text or "",
			updated = DRTDB.main.updated or 0,
		}
	end
	local note = DRTDB.notes[self.selectedKey]
	if note and ShouldKeepRemoteNote(note) then
		return note
	end
	return nil
end

function DRT:SelectNote(key)
	self.selectedKey = key or MAIN_KEY
	self:RefreshUI()
end

local function GetNoteDisplayTitle(note)
	if note.isMain then
		return "|cff55ee55Главная заметка|r"
	end

	local title = Trim(note.title)
	if title == "" then
		title = "Без названия"
	end

	local owner = ShortName(note.owner)
	if IsOwnNote(note) then
		return "|cff91ff91" .. title .. "|r |cff888888(" .. owner .. ")|r"
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
				GameTooltip:AddLine(note.isMain and "Главная заметка" or (note.title ~= "" and note.title or "Без названия"))
				if note.owner and note.owner ~= "" then
					GameTooltip:AddLine("Автор: " .. ShortName(note.owner), 0.8, 0.8, 0.8)
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
	SetEditBoxEnabled(self.titleEdit, enabled and self.selectedKey ~= MAIN_KEY)
	SetEditBoxEnabled(self.bodyEdit, enabled)
	SetPanelBorder(self.titlePanel, false, not (enabled and self.selectedKey ~= MAIN_KEY))
	SetPanelBorder(self.bodyPanel, false, not enabled)

	if enabled then
		self.bodyEdit:SetTextColor(1, 1, 1, 1)
	else
		self.bodyEdit:SetTextColor(0.72, 0.72, 0.72, 1)
	end
end

function DRT:RefreshEditor()
	if not self.frame then
		return
	end

	local note = self:GetSelectedNote()
	if not note then
		self.selectedKey = MAIN_KEY
		note = self:GetSelectedNote()
	end

	local canEdit = note.isMain or IsOwnNote(note)
	local bodyText = note.isMain and (DRTDB.main.text or "") or (note.body or "")
	self.titleEdit:SetText(note.isMain and "Главная заметка" or (note.title or ""))
	self.bodyEdit:SetText(bodyText)
	self.ownerText:SetText(note.isMain and "Синхронизируется в текущей группе/рейде" or ("Автор: " .. ShortName(note.owner)))

	if note.updated and note.updated > 0 then
		self.updatedText:SetText("Обновлено: " .. date("%d.%m.%Y %H:%M:%S", floor(note.updated / 1000)))
	else
		self.updatedText:SetText("")
	end

	self:SetEditorEnabled(canEdit)
	SetButtonEnabled(self.saveButton, canEdit)
	SetButtonEnabled(self.deleteButton, (not note.isMain) and IsOwnNote(note))
	SetButtonEnabled(self.toMainButton, not note.isMain)
	self:RefreshMainNoteControls(note.isMain)
end

function DRT:RefreshUI()
	if not self.frame then
		return
	end
	self:RefreshNotesList()
	self:RefreshEditor()
	self:RefreshPlayerButtons()
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
	if not note then
		return
	end

	if note.isMain then
		DRTDB.main.text = self.bodyEdit:GetText() or ""
		DRTDB.main.owner = self.playerFullName
		DRTDB.main.updated = CurrentMillis()
		BroadcastPayload(BuildMainPayload())
		self:RefreshUI()
		self:UpdateMainNoteWindow()
		Print("главная заметка обновлена.")
		return
	end

	if not IsOwnNote(note) then
		Print("можно редактировать только свои заметки.")
		return
	end

	note.title = Trim(self.titleEdit:GetText())
	note.body = self.bodyEdit:GetText() or ""
	note.updated = CurrentMillis()
	note.owner = self.playerFullName
	note.deleted = nil
	note.localOnly = nil

	BroadcastPayload(BuildNotePayload(note))
	self:RefreshUI()
	Print("заметка сохранена.")
end

function DRT:CreateNewNote()
	local id = tostring(CurrentMillis()) .. tostring(random(1000, 9999))
	local note = {
		id = id,
		owner = self.playerFullName,
		title = "Новая заметка",
		body = "",
		updated = CurrentMillis(),
		localOnly = true,
	}
	local key = NoteKey(note.owner, note.id)
	DRTDB.notes[key] = note
	self.selectedKey = key
	self:RefreshUI()
	self.titleEdit:SetFocus()
	self.titleEdit:HighlightText()
end

function DRT:DeleteSelected()
	local note = self:GetSelectedNote()
	if not note or note.isMain then
		return
	end
	if not IsOwnNote(note) then
		Print("можно удалять только свои заметки.")
		return
	end

	if not note.localOnly then
		local deletePayload = {
			id = note.id,
			owner = note.owner,
			updated = CurrentMillis(),
			deleted = true,
			title = note.title or "",
			body = "",
		}
		BroadcastPayload(BuildNotePayload(deletePayload))
	end

	DRTDB.notes[self.selectedKey] = nil
	self.selectedKey = MAIN_KEY
	self:RefreshUI()
	Print("заметка удалена.")
end

function DRT:MoveSelectedToMain()
	local note = self:GetSelectedNote()
	if not note or note.isMain then
		return
	end

	DRTDB.main.text = note.body or ""
	DRTDB.main.owner = self.playerFullName
	DRTDB.main.updated = CurrentMillis()
	BroadcastPayload(BuildMainPayload())
	self.selectedKey = MAIN_KEY
	self:RefreshUI()
	self:UpdateMainNoteWindow()
	Print("заметка перенесена в главную.")
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
	if note and note.isMain then
		return DRTDB.main.text or "", "главная заметка"
	elseif note then
		return note.body or "", "текущая заметка"
	end
	return DRTDB.main.text or "", "текущая заметка"
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

	local channel
	if IsInRaid() then
		channel = "RAID"
	elseif IsInGroup() then
		channel = "PARTY"
	else
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

	for i = 1, #queue do
		local message = queue[i]
		C_Timer.After((i - 1) * 0.25, function()
			SendChatMessage(message, channel)
		end)
	end
end

function DRT:LinkMainNote()
	self:LinkCurrentNote()
end

function DRT:ClearMainNote(shouldBroadcast)
	DRTDB.main.text = ""
	DRTDB.main.owner = self.playerFullName or ""
	DRTDB.main.updated = CurrentMillis()
	if shouldBroadcast then
		BroadcastPayload(BuildMainPayload())
	end
	self:UpdateMainNoteWindow()
	if self.selectedKey == MAIN_KEY then
		self:RefreshUI()
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
	self.titleEdit = titleEdit

	local saveButton = CreateButton(frame, "Сохранить", 94, 23)
	saveButton:SetPoint("LEFT", titlePanel, "RIGHT", 16, 0)
	saveButton:SetScript("OnClick", function()
		DRT:SaveSelected()
	end)
	self.saveButton = saveButton

	local toMainButton = CreateButton(frame, "В главную", 98, 23)
	toMainButton:SetPoint("LEFT", saveButton, "RIGHT", 8, 0)
	toMainButton:SetScript("OnClick", function()
		DRT:MoveSelectedToMain()
	end)
	self.toMainButton = toMainButton

	local ownerText = CreateFont(frame, "GameFontHighlightSmall", "", "LEFT")
	ownerText:SetPoint("TOPLEFT", titlePanel, "BOTTOMLEFT", 0, -8)
	ownerText:SetTextColor(0.78, 0.82, 0.86, 1)
	self.ownerText = ownerText

	local updatedText = CreateFont(frame, "GameFontHighlightSmall", "", "RIGHT")
	updatedText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -34, -122)
	updatedText:SetTextColor(0.58, 0.62, 0.66, 1)
	self.updatedText = updatedText

	local mainWindowShowCheck = CreateCheckButton(frame, "DRTShowMainNoteWindowCheckButton", "Показывать главную")
	mainWindowShowCheck:SetPoint("TOPLEFT", titlePanel, "BOTTOMLEFT", -2, -26)
	mainWindowShowCheck:SetScript("OnClick", function(self)
		DRTDB.mainWindow.enabled = self:GetChecked() and true or false
		DRT:UpdateMainNoteWindow()
	end)
	mainWindowShowCheck:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Показывать главную")
		GameTooltip:AddLine("Открывает отдельное окно с главной заметкой поверх интерфейса.", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	mainWindowShowCheck:SetScript("OnLeave", GameTooltip_Hide)
	self.mainWindowShowCheck = mainWindowShowCheck

	local mainWindowLockCheck = CreateCheckButton(frame, "DRTLockMainNoteWindowCheckButton", "Закрепить главную")
	mainWindowLockCheck:SetPoint("TOPLEFT", titlePanel, "BOTTOMLEFT", 184, -26)
	mainWindowLockCheck:SetScript("OnClick", function(self)
		DRTDB.mainWindow.locked = self:GetChecked() and true or false
		DRT:UpdateMainNoteWindow()
	end)
	mainWindowLockCheck:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Закрепить главную")
		GameTooltip:AddLine("Запрещает перемещать и изменять размер окна главной заметки.", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	mainWindowLockCheck:SetScript("OnLeave", GameTooltip_Hide)
	self.mainWindowLockCheck = mainWindowLockCheck

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

function DRT:SendRequest(channel)
	SendPayload(BuildPayload("REQ", VERSION), channel)
end

function DRT:RequestSync()
	if not self.playerFullName then
		return
	end

	local channels = GetBroadcastChannels()
	for i = 1, #channels do
		self:SendRequest(channels[i])
	end
end

function DRT:SendAllNotes(channel, target)
	local delay = 0
	local ownNoteIds = {}
	for _, note in pairs(DRTDB.notes) do
		if type(note) == "table" and note.id and note.id ~= "" and not note.deleted and not note.localOnly and IsOwnNote(note) then
			ownNoteIds[#ownNoteIds + 1] = tostring(note.id)
			local payload = BuildNotePayload(note)
			C_Timer.After(delay, function()
				SendPayload(payload, channel, target)
			end)
			delay = delay + 0.06
		end
	end

	local ownerPayload = BuildOwnerNotesPayload(self.playerFullName, ownNoteIds)
	C_Timer.After(delay + 0.02, function()
		SendPayload(ownerPayload, channel, target)
	end)
	delay = delay + 0.06

	local mainPayload = BuildMainPayload()
	C_Timer.After(delay + 0.04, function()
		SendPayload(mainPayload, channel, target)
	end)
end

function DRT:HandleOwnerNotesPayload(fields)
	local owner = NormalizeFullName(fields[1])
	if not owner then
		return
	end
	if not IsSamePlayerName(owner, self.playerFullName) and not IsCurrentGroupMember(owner) then
		return
	end

	local activeIds = {}
	for id in tostring(fields[2] or ""):gmatch("[^,]+") do
		activeIds[id] = true
	end

	local changed = false
	for key, note in pairs(DRTDB.notes) do
		if type(note) == "table" and IsSamePlayerName(note.owner, owner) and not activeIds[tostring(note.id or "")] then
			DRTDB.notes[key] = nil
			changed = true
			if self.selectedKey == key then
				self.selectedKey = MAIN_KEY
			end
		end
	end

	if changed and self.frame and self.frame:IsShown() then
		self:RefreshUI()
	end
end

function DRT:HandleNotePayload(fields)
	local id = fields[1]
	local owner = NormalizeFullName(fields[2])
	local updated = tonumber(fields[3] or 0) or 0
	local deleted = fields[4] == "1"
	local title = fields[5] or ""
	local body = fields[6] or ""

	if not id or id == "" or not owner then
		return
	end
	if not IsSamePlayerName(owner, self.playerFullName) and not IsCurrentGroupMember(owner) then
		return
	end

	local key = NoteKey(owner, id)
	local existing = DRTDB.notes[key]
	if existing and (tonumber(existing.updated or 0) or 0) >= updated then
		return
	end
	if deleted then
		if existing then
			DRTDB.notes[key] = nil
			if self.selectedKey == key then
				self.selectedKey = MAIN_KEY
			end
			if self.frame and self.frame:IsShown() then
				self:RefreshUI()
			end
		end
		return
	end

	DRTDB.notes[key] = {
		id = id,
		owner = owner,
		updated = updated,
		title = title,
		body = body,
	}

	if self.selectedKey == key or self.frame and self.frame:IsShown() then
		self:RefreshUI()
	end
end

function DRT:HandleMainPayload(fields)
	local updated = tonumber(fields[1] or 0) or 0
	if (tonumber(DRTDB.main.updated or 0) or 0) >= updated then
		return
	end

	DRTDB.main.updated = updated
	DRTDB.main.owner = NormalizeFullName(fields[2]) or fields[2] or ""
	DRTDB.main.text = fields[3] or ""
	self:UpdateMainNoteWindow()

	if self.selectedKey == MAIN_KEY or self.frame and self.frame:IsShown() then
		self:RefreshUI()
	end
end

function DRT:HandlePayload(sender, payload)
	local kind, fields = ParsePayload(payload)
	if not kind then
		return
	end

	if kind == "REQ" then
		if not sender or sender == "" then
			return
		end
		if sender and Ambiguate and Ambiguate(sender, "none") == Ambiguate(self.playerFullName or "", "none") then
			return
		end
		self:SendAllNotes("WHISPER", sender)
	elseif kind == "NOTE" then
		self:HandleNotePayload(fields)
	elseif kind == "OWNER" then
		self:HandleOwnerNotesPayload(fields)
	elseif kind == "MAIN" then
		self:HandleMainPayload(fields)
	end
end

function DRT:HandleAddonMessage(prefix, message, channel, sender)
	if prefix ~= PREFIX or not message then
		return
	end

	if sender and Ambiguate and self.playerFullName and Ambiguate(sender, "none") == Ambiguate(self.playerFullName, "none") then
		return
	end

	local tag, id, index, total, part = SplitChunkMessage(message)
	if tag ~= "C" or not id or not index or not total or not part then
		return
	end

	local buffer = self.incomingChunks[id]
	if not buffer then
		buffer = {
			total = total,
			received = 0,
			parts = {},
			started = GetTime(),
		}
		self.incomingChunks[id] = buffer
	end

	if not buffer.parts[index] then
		buffer.parts[index] = part
		buffer.received = buffer.received + 1
	end

	if buffer.received >= buffer.total then
		local encoded = ""
		for i = 1, buffer.total do
			if not buffer.parts[i] then
				return
			end
			encoded = encoded .. buffer.parts[i]
		end
		self.incomingChunks[id] = nil
		self:HandlePayload(sender, Decode(encoded))
	end

	local now = GetTime()
	for chunkId, chunk in pairs(self.incomingChunks) do
		if now - (chunk.started or now) > 30 then
			self.incomingChunks[chunkId] = nil
		end
	end
end

function DRT:HandleGroupChange()
	local grouped = IsInGroup()
	if self.wasGrouped == nil then
		self.wasGrouped = grouped
		return
	end

	if grouped and not self.wasGrouped then
		C_Timer.After(0.6, function()
			if IsInGroup() and UnitIsGroupLeader("player") then
				DRT:ClearMainNote(true)
			end
			DRT:RequestSync()
			DRT:RefreshPlayerButtons()
		end)
	elseif not grouped and self.wasGrouped then
		self:PruneForeignNotes()
		self:RefreshPlayerButtons()
		if self.frame and self.frame:IsShown() then
			self:RefreshUI()
		end
	elseif grouped then
		local changed = self:PruneForeignNotes(true)
		self:RefreshPlayerButtons()
		if changed and self.frame and self.frame:IsShown() then
			self:RefreshUI()
		end
	end

	self.wasGrouped = grouped
end

function DRT:OnLogin()
	EnsureDB()
	self.realmName = NormalizeRealm(GetRealmName())
	self.playerFullName = UnitFullNameSafe("player")
	self.wasGrouped = IsInGroup()
	self:PruneForeignNotes(self.wasGrouped)

	if RegisterAddonMessagePrefix then
		RegisterAddonMessagePrefix(PREFIX)
	end

	self:CreateMinimapButton()
	self:UpdateMainNoteWindow()
	C_Timer.After(1.5, function()
		DRT:RequestSync()
	end)
end

DRT:SetScript("OnEvent", function(self, event, ...)
	if event == "PLAYER_LOGIN" then
		self:OnLogin()
	elseif event == "CHAT_MSG_ADDON" then
		self:HandleAddonMessage(...)
	elseif event == "GROUP_ROSTER_UPDATE" then
		self:HandleGroupChange()
	elseif event == "PLAYER_GUILD_UPDATE" then
		self:RequestSync()
	end
end)

DRT:RegisterEvent("PLAYER_LOGIN")
DRT:RegisterEvent("CHAT_MSG_ADDON")
DRT:RegisterEvent("GROUP_ROSTER_UPDATE")
DRT:RegisterEvent("PLAYER_GUILD_UPDATE")

SLASH_DRT1 = "/drt"
SLASH_DRT2 = "/дрт"
SlashCmdList.DRT = function(msg)
	msg = Trim(msg):lower()
	if msg == "sync" then
		DRT:RequestSync()
		Print("запрошена синхронизация.")
	elseif msg == "clear" then
		DRT:ClearMainNote(true)
		Print("главная заметка очищена.")
	else
		DRT:Toggle()
	end
end

function DRT_Toggle()
	DRT:Toggle()
end
