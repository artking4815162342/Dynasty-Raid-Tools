local passed = 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if not ok then error(name .. ": " .. tostring(err), 0) end
	passed = passed + 1
	print("PASS " .. name)
end
local function eq(actual, expected, message)
	assert(actual == expected, (message or "mismatch") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end
local function clone(t)
	if type(t) ~= "table" then return t end
	local result = {}
	for k, v in pairs(t) do result[k] = clone(v) end
	return result
end

assert(loadfile(PROJECT_ROOT .. "/Notes.lua"))()
local N = DRTNotes
local function store(name, guid, db)
	return N.Open(db or {}, guid or name, name .. "-Realm", "Realm", 1000)
end
local function save(s, title, body, shared)
	local note = s:Create(1001)
	if shared == false then assert(s:Share(note, false, 1002)) end
	assert(s:Save(note, title or "Title", body or "Body", 1003))
	return note
end
local function apply(source, target, encoded)
	local kind, fields = N.Unpack(assert(N.Decode(encoded or assert(source:Snapshot()))))
	eq(kind, "SNAP")
	return target:Apply(source.owner, fields, function() return true end)
end

test("new notes default shared; drafts are not published", function()
	local a, b = store("A"), store("B")
	local note = a:Create(1)
	eq(note.shared, true)
	assert(apply(a, b)); eq(count(b.remote), 0)
	assert(a:Save(note, "hello", "raid", 2))
	assert(apply(a, b)); eq(count(b.remote), 1)
end)

test("private title and body never enter a snapshot", function()
	local a, b = store("A"), store("B")
	save(a, "SECRET_TITLE", "SECRET_BODY", false)
	save(a, "public", "public body")
	local encoded = assert(a:Snapshot())
	assert(not N.Decode(encoded):find("SECRET", 1, true))
	assert(apply(a, b, encoded)); eq(count(b.remote), 1)
end)

test("unshare removes remote copy; late snapshots cannot resurrect it", function()
	local a, b = store("A"), store("B")
	local note = save(a)
	local old = assert(a:Snapshot())
	assert(apply(a, b, old)); eq(count(b.remote), 1)
	assert(a:Share(note, false, 1004)); assert(apply(a, b)); eq(count(b.remote), 0)
	assert(not apply(a, b, old)); eq(count(b.remote), 0)
	eq(a.profile.notes[note.id], note)
	assert(a:Share(note, true, 1005)); assert(apply(a, b)); eq(count(b.remote), 1)
end)

test("explicit delete removes local and remote records", function()
	local a, b = store("A"), store("B")
	local note = save(a)
	assert(apply(a, b))
	a.drafts[a:Key(note)] = { body = "draft" }
	assert(a:Delete(note, 1004)); assert(apply(a, b))
	eq(count(a.profile.notes), 0); eq(count(a.drafts), 0); eq(count(b.remote), 0)
end)

test("pruning cannot delete local notes, including private and draft notes", function()
	local a, b = store("A"), store("B")
	save(a); save(a, "private", "secret", false); a:Create(1004)
	save(b); assert(apply(b, a)); eq(count(a.remote), 1)
	a:Prune(function() return false end)
	eq(count(a.remote), 0); eq(count(a.profile.notes), 3)
	local reloaded = store("A", "A", clone(a.db))
	eq(count(reloaded.profile.notes), 3); eq(count(reloaded.remote), 0)
end)

test("GUID ownership survives alternate characters and a rename", function()
	local db = {}
	local a = store("A", "GUID-A", db)
	local note = save(a)
	local b = store("B", "GUID-B", db)
	save(b); b:Prune(function() return false end)
	eq(count(a.profile.notes), 1)
	local renamed = store("NewName", "GUID-A", db)
	eq(count(renamed.profile.notes), 1); eq(renamed.profile.notes[note.id].owner, "NewName-Realm")
	eq(count(b.profile.notes), 1)
end)

test("legacy migration is lossless, private for old main, and idempotent", function()
	local db = { notes = {
		a = { id = "a", owner = "A-Rea lm", title = "A", body = "one" },
		b = { id = "b", owner = "B-Realm", title = "B", body = "two" },
		unknown = { id = "x", owner = "Somebody-Else", title = "X", body = "archive" },
	}, main = { text = "old main text" }, mainWindow = { enabled = true, width = 90 } }
	local a = store("A", "GUID-A", db)
	eq(count(a.profile.notes), 2); eq(count(db.legacyNotes), 3)
	eq(db.main, nil); eq(db.notes, nil); eq(db.mainWindow, nil)
	eq(db.noteWindow.enabled, false); eq(db.noteWindow.width, 90)
	local restored
	for _, note in pairs(a.profile.notes) do if note.body == "old main text" then restored = note end end
	assert(restored); eq(restored.shared, false)
	local b = store("B", "GUID-B", db); eq(count(b.profile.notes), 1)
	assert(a:Delete(a.profile.notes.a, 2000))
	local again = store("A", "GUID-A", db)
	eq(count(again.profile.notes), 1, "migration must not restore an explicitly deleted note")
	eq(count(db.legacyNotes), 3)
end)

test("foreign snapshots cannot impersonate owners or affect personal storage", function()
	local a, b, c = store("A"), store("B"), store("C")
	save(a); save(b); save(c)
	assert(apply(b, a)); assert(apply(c, a))
	local _, fields = N.Unpack(N.Decode(b:Snapshot()))
	assert(not a:Apply(c.owner, fields, function() return true end))
	fields[1] = a.owner
	assert(not a:Apply(b.owner, fields, function() return true end))
	assert(not a:Apply(a.owner, fields, function() return true end))
	eq(count(a.profile.notes), 1); eq(count(a.remote), 2)
	fields[1] = b.owner
	assert(not a:Apply(b.owner, fields, function() return false end))
	eq(count(a.profile.notes), 1)
end)

test("malformed payloads are rejected atomically", function()
	for _, payload in ipairs({ "SNAP|-1:x", "SNAP|1.5:xx", "SNAP|100:x", "SNAP|:a", "SNAP|1:xjunk" }) do
		eq(N.Unpack(payload), nil)
	end
	eq(N.Decode("%XX"), nil)
	local a, b = store("A"), store("B")
	save(a); assert(apply(a, b))
	local _, fields = N.Unpack(N.Decode(a:Snapshot()))
	fields[2] = "9999"; fields[3] = "2"
	assert(not b:Apply(a.owner, fields, function() return true end)); eq(count(b.remote), 1)
	fields[3] = "1"; fields[5] = "nan"
	assert(not b:Apply(a.owner, fields, function() return true end)); eq(count(b.remote), 1)
	fields[5] = "9007199254740991"
	assert(not b:Apply(a.owner, fields, function() return true end)); eq(count(b.remote), 1)
end)

test("oversized shared edits roll back; private text is retained", function()
	local a = store("A")
	local note = save(a)
	local ok = a:Save(note, "Title", string.rep("x", N.MAX_BODY + 1), 1004)
	eq(ok, false); eq(note.body, "Body")
	assert(a:Share(note, false, 1005))
	assert(a:Save(note, "Title", string.rep("x", N.MAX_BODY + 1), 1006))
	eq(a:Share(note, true, 1007), false); eq(note.shared, false)
end)

-- Minimal strict WoW API double. It runs the real event, timer, UI and wire code.
local function world()
	local w = { now = 0, timers = {}, clients = {}, sent = {}, chat = {}, group = {}, raid = false, instance = false }
	function w:advance(seconds)
		local untilTime, steps = self.now + seconds, 0
		while true do
			local index, first
			for i, timer in ipairs(self.timers) do
				if timer.at <= untilTime and (not first or timer.at < first.at) then index, first = i, timer end
			end
			if not first then break end
			table.remove(self.timers, index); self.now = first.at
			if not first.client.closed then first.fn() end
			steps = steps + 1; assert(steps < 100000, "timer loop")
		end
		self.now = untilTime
	end
	function w:roster(names)
		self.group = names
		for _, client in pairs(self.clients) do if not client.closed then client.DRT:HandleGroupChange() end end
	end
	function w:client(name, db, guid)
		local env = setmetatable({ name = name, DRTDB = db, messages = {}, frames = {} }, { __index = _G })
		env._G = env
		local methods = {}
		local function frame(kind, frameName, parent, template)
			local f = setmetatable({ scripts = {}, width = 100, height = 100, textValue = "", shown = true,
				parent = parent, frameName = frameName, kind = kind, enabled = true, scrollValue = 0 }, { __index = methods })
			if frameName then env[frameName] = f end
			env.frames[#env.frames + 1] = f
			if template == "UIPanelScrollFrameTemplate" then f.ScrollBar = frame("Slider") end
			return f
		end
		function methods:SetScript(event, fn) self.scripts[event] = fn end
		function methods:SetText(text)
			self.textValue = text or ""
			self.setTextCount = (self.setTextCount or 0) + 1
			if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, false) end
		end
		function methods:GetText() return self.textValue end
		function methods:SetSize(width, height)
			self.width, self.height = width, height
			if self.scripts.OnSizeChanged then self.scripts.OnSizeChanged(self, width, height) end
		end
		function methods:SetWidth(width) self.width = width end
		function methods:SetHeight(height) self.height = height end
		function methods:GetWidth() return self.width end
		function methods:GetHeight() return self.height end
		function methods:GetName() return self.frameName end
		function methods:GetLeft() return 0 end
		function methods:GetTop() return 100 end
		function methods:GetStringHeight() return 14 end
		function methods:GetVerticalScroll() return self.scrollValue end
		function methods:SetVerticalScroll(value) self.scrollValue = value end
		function methods:GetMinMaxValues() return 0, 1000 end
		function methods:SetValue(value) self.value = value end
		function methods:SetChecked(value) self.checked = value and true or false end
		function methods:GetChecked() return self.checked end
		function methods:Enable() self.enabled = true end
		function methods:Disable() self.enabled = false end
		function methods:Show() self.shown = true end
		function methods:Hide() self.shown = false end
		function methods:IsShown() return self.shown end
		function methods:SetFocus() self.focus = true end
		function methods:ClearFocus() self.focus = false end
		function methods:Insert(text) self:SetText(self.textValue .. text) end
		function methods:CreateFontString() return frame("FontString", nil, self) end
		function methods:CreateTexture() return frame("Texture", nil, self) end
		function methods:SetMovable(value) self.movable = value end
		function methods:IsMovable() return self.movable end
		function methods:SetFrameStrata(value) self.strata = value end
		function methods:SetPoint(...) self.point = { ... } end
		for _, method in ipairs({ "SetAutoFocus", "SetMaxLetters", "SetFontObject", "SetTextColor", "SetJustifyH", "SetJustifyV",
			"SetBlinkSpeed", "SetMultiLine", "SetTextInsets", "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor",
			"SetAllPoints", "SetWordWrap", "SetNonSpaceWrap", "SetColorTexture", "SetTexture", "SetNormalTexture",
			"SetPushedTexture", "SetHighlightTexture", "EnableMouse", "EnableMouseWheel", "SetClampedToScreen",
			"SetResizable", "SetResizeBounds", "RegisterForDrag", "RegisterForClicks", "RegisterEvent", "StartMoving",
			"StopMovingOrSizing", "StartSizing", "SetScrollChild", "ClearAllPoints", "HighlightText" }) do
			methods[method] = function() end
		end
		env.CreateFrame = frame
		env.UIParent, env.Minimap = frame("Frame"), frame("Frame")
		env.BackdropTemplateMixin = {}
		env.ChatFontNormal, env.GameFontHighlight = {}, {}
		env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) env.messages[#env.messages + 1] = msg end }
		env.C_Timer = { After = function(delay, fn) self.timers[#self.timers + 1] = { at = self.now + delay, fn = fn, client = env } end }
		env.GetTime = function() return self.now end
		env.time = function() return 1700000000 + math.floor(self.now) end
		env.date = os.date
		env.GetRealmName = function() return "Realm" end
		env.UnitGUID = function() return guid or ("GUID-" .. name) end
		env.LE_PARTY_CATEGORY_INSTANCE = 2
		env.IsInGroup = function(category)
			local found = false
			for _, member in ipairs(self.group) do if member == name then found = true end end
			return found and #self.group > 1 and (category ~= 2 or self.instance)
		end
		env.IsInRaid = function() return self.raid and env.IsInGroup() end
		env.GetNumGroupMembers = function() return #self.group end
		local function unitName(unit)
			if unit == "player" then return name end
			local raidIndex = unit:match("^raid(%d+)$")
			if raidIndex then return self.group[tonumber(raidIndex)] end
			local partyIndex = tonumber(unit:match("^party(%d+)$"))
			if partyIndex then
				for _, member in ipairs(self.group) do
					if member ~= name then partyIndex = partyIndex - 1; if partyIndex == 0 then return member end end
				end
			end
		end
		env.UnitFullName = function(unit)
			local full = unitName(unit)
			if not full then return nil end
			return full:match("^([^%-]+)%-(.+)$") or full, full:match("^[^%-]+%-(.+)$") or "Realm"
		end
		env.UnitExists = function(unit) return unitName(unit) ~= nil end
		env.UnitClass = function() return "Mage", "MAGE" end
		env.GetRaidRosterInfo = function() return nil, nil, 1 end
		env.Ambiguate = function(full, mode) return mode == "short" and full:match("^[^%-]+") or full end
		env.wipe = function(t) for k in pairs(t) do t[k] = nil end end
		env.UISpecialFrames, env.SlashCmdList = {}, {}
		env.Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, ChannelThrottle = 8 } }
		env.C_ChatInfo = {
			RegisterAddonMessagePrefix = function() end,
			SendAddonMessage = function(prefix, message, channel)
				assert(#message <= 255)
				if env.throttleResults and #env.throttleResults > 0 then return table.remove(env.throttleResults, 1) end
				self.sent[#self.sent + 1] = { sender = name, prefix = prefix, message = message, channel = channel }
				for _, other in pairs(self.clients) do
					if not other.closed and other.IsInGroup() then
						other.DRT:HandleAddonMessage(prefix, message, channel, N.NormalizeName(name, "Realm"))
					end
				end
				return 0
			end,
			SendChatMessage = function(message, channel) self.chat[#self.chat + 1] = { message = message, channel = channel } end,
		}
		self.clients[name] = env
		for _, file in ipairs({ "Notes.lua", "Core.lua" }) do
			local chunk = assert(loadfile(PROJECT_ROOT .. "/" .. file)); setfenv(chunk, env); chunk("DRT")
		end
		env.DRT:OnLogin()
		return env
	end
	return w
end

local function uiSave(client, title, body)
	local d = client.DRT
	if not d.frame then d:Toggle() end
	d:CreateNewNote(); d.titleEdit:SetText(title); d.bodyEdit:SetText(body); d:SaveSelected()
	return d:GetSelectedNote()
end

test("real UI has empty state, shared checkbox and no common-note controls", function()
	local w = world(); local a = w:client("A")
	a.DRT:Toggle()
	eq(#a.DRT.notesList, 0); eq(a.DRT.bodyEdit.enabled, false)
	eq(a.DRT.toMainButton, nil); eq(a.DRT.MoveSelectedToMain, nil)
	a.DRT:CreateNewNote(); eq(a.DRT.shareCheck:GetChecked(), true)
	eq(a.DRT.bodyEdit.enabled, true)
	eq(a.DRT.frame.strata, "DIALOG"); eq(a.DRT.noteWindow.strata, "HIGH")
end)

test("two real clients synchronize and revoke through chunked messages", function()
	local w = world(); local a, b = w:client("A"), w:client("B")
	local note = uiSave(a, "Raid", "{rt1} Player")
	w:roster({ "A", "B" }); w:advance(30)
	eq(count(b.DRT.store.remote), 1)
	a.DRT:SetSelectedShared(false); w:advance(15)
	eq(count(b.DRT.store.remote), 0); eq(count(a.DRT.store.profile.notes), 1)
	a.DRT:SetSelectedShared(true); w:advance(15); eq(count(b.DRT.store.remote), 1)
	a.DRT:DeleteSelected(); w:advance(15); eq(count(b.DRT.store.remote), 0)
	eq(a.DRT.store.profile.notes[note.id], nil)
end)

test("network refresh preserves the local draft and caret state", function()
	local w = world(); local a, b = w:client("A"), w:client("B")
	uiSave(a, "Mine", "saved"); uiSave(b, "Other", "other")
	w:roster({ "A", "B" }); w:advance(20)
	a.DRT.bodyEdit:SetText("UNSAVED"); a.DRT.bodyEdit:SetFocus()
	local before = a.DRT.bodyEdit.setTextCount
	b.DRT.bodyEdit:SetText("changed"); b.DRT:SaveSelected(); w:advance(15)
	eq(a.DRT.bodyEdit:GetText(), "UNSAVED"); eq(a.DRT.bodyEdit.setTextCount, before); eq(a.DRT.bodyEdit.focus, true)
	local ownKey = a.DRT.selectedKey
	for key in pairs(a.DRT.store.remote) do a.DRT:SelectNote(key); break end
	eq(a.DRT.bodyEdit.enabled, false); eq(a.DRT.shareCheck:IsShown(), false)
	a.DRT:SelectNote(ownKey); eq(a.DRT.bodyEdit:GetText(), "UNSAVED")
end)

test("reload in group fetches remote notes again; leaving removes only cache", function()
	local w = world(); local a, b = w:client("A"), w:client("B")
	uiSave(a, "Mine", "local"); uiSave(b, "Theirs", "remote")
	w:roster({ "A", "B" }); w:advance(20)
	local db = clone(a.DRTDB); a.closed = true
	a = w:client("A", db); w:advance(25)
	eq(count(a.DRT.store.profile.notes), 1); eq(count(a.DRT.store.remote), 1)
	w:roster({}); w:advance(5)
	eq(count(a.DRT.store.profile.notes), 1); eq(count(a.DRT.store.remote), 0)
	eq(a.DRTDB.notes, nil)
end)

test("reload during a large transmission receives a complete retry", function()
	local w = world(); local a, b = w:client("A"), w:client("B")
	uiSave(a, "Large", string.rep("text ", 500))
	w:roster({ "A", "B" }); w:advance(2)
	b.closed = true; b = w:client("B", clone(b.DRTDB))
	w:advance(60); eq(count(b.DRT.store.remote), 1)
end)

test("unsharing cancels already queued private text before the next send", function()
	local w = world(); local a, b = w:client("A"), w:client("B")
	w:roster({ "A", "B" }); w:advance(5)
	uiSave(a, "Sensitive", string.rep("SECRET", 500))
	w:advance(1)
	a.DRT:SetSelectedShared(false)
	local offset = #w.sent
	w:advance(30)
	for i = offset + 1, #w.sent do assert(not w.sent[i].message:find("SECRET", 1, true)) end
	eq(count(b.DRT.store.remote), 0)
end)

test("outsiders, wrong channels, legacy packets and forged owners are ignored", function()
	local w = world(); local a, b = w:client("A"), w:client("B")
	uiSave(a, "Mine", "local"); w:roster({ "A", "B" }); w:advance(10)
	local payload = N.Encode(N.Pack("SNAP", { "A-Realm", "9999999999999", "0" }))
	a.DRT:HandleAddonMessage("DRT2", "C|forged|1|1|" .. payload, "PARTY", "B-Realm")
	a.DRT:HandleAddonMessage("DRT2", "C|outside|1|1|" .. payload, "PARTY", "Outsider-Realm")
	a.DRT:HandleAddonMessage("DRT2", "C|guild|1|1|" .. payload, "GUILD", "B-Realm")
	a.DRT:HandleAddonMessage("DRT", "C|legacy|1|1|" .. payload, "PARTY", "B-Realm")
	eq(count(a.DRT.store.profile.notes), 1)
	for _, text in ipairs({ "C|bad|0|1|x", "C|bad|1|999999999|x", "C|bad|2|1|x" }) do
		a.DRT:HandleAddonMessage("DRT2", text, "PARTY", "B-Realm")
	end
	eq(count(a.DRT.incomingChunks), 0)
end)

test("popup follows a pinned personal or shared note without copying it", function()
	local w = world(); local a, b = w:client("A"), w:client("B")
	uiSave(a, "A", "own"); uiSave(b, "B", "other")
	w:roster({ "A", "B" }); w:advance(15)
	local check = a.DRT.noteWindowShowCheck
	check:SetChecked(true); check.scripts.OnClick(check)
	eq(a.DRT.noteWindow.text:GetText(), "own")
	local remoteKey = next(a.DRT.store.remote)
	a.DRT:SelectNote(remoteKey); check:SetChecked(true); check.scripts.OnClick(check)
	eq(a.DRT.noteWindow.text:GetText(), "other")
	b.DRT.bodyEdit:SetText("updated"); b.DRT:SaveSelected(); w:advance(15)
	eq(a.DRT.noteWindow.text:GetText(), "updated")
	b.DRT:SetSelectedShared(false); w:advance(15)
	eq(a.DRT.noteWindow:IsShown(), false); eq(count(a.DRT.store.profile.notes), 1)
end)

test("instance chat, current note, wrapping and UTF-8 line splitting", function()
	local w = world(); local a, b = w:client("A"), w:client("B")
	w.instance = true
	w:roster({ "A", "B" }); w:advance(5)
	uiSave(a, "Chat", string.rep("я", 220) .. " {rt1}")
	a.DRTDB.wrapLinkedNote = true
	a.DRT:LinkCurrentNote(); w:advance(3)
	eq(w.chat[1].message, "<<<<<<<<<<<<<<<<<<<<<<<<<")
	eq(w.chat[#w.chat].message, ">>>>>>>>>>>>>>>>>>>>>>>>>")
	for _, message in ipairs(w.chat) do
		eq(message.channel, "INSTANCE_CHAT"); assert(#message.message <= 210)
		local text = message.message:gsub("я", "")
		assert(not text:find("[\128-\255]"), "split UTF-8 codepoint")
	end
	assert(w.chat[#w.chat - 1].message:find("{star}", 1, true))
end)

test("group transition cancels delayed chat and queued addon transmissions", function()
	local w = world(); local a, b = w:client("A"), w:client("B")
	w:roster({ "A", "B" }); w:advance(5)
	uiSave(a, "Chat", "one\ntwo\nthree")
	a.DRT:LinkCurrentNote(); w:advance(0)
	w:roster({}); local sent = #w.sent; w:advance(5)
	eq(#w.chat, 1); eq(#w.sent, sent); eq(count(a.DRT.store.profile.notes), 1)
end)

test("same character name on different realms never shares ownership", function()
	local w = world()
	local a, b = w:client("Twin-One"), w:client("Twin-Two")
	uiSave(a, "First", "one"); uiSave(b, "Second", "two")
	w:roster({ "Twin-One", "Twin-Two" }); w:advance(20)
	eq(count(a.DRT.store.profile.notes), 1); eq(count(a.DRT.store.remote), 1)
	for key, note in pairs(a.DRT.store.remote) do
		eq(note.owner, "Twin-Two"); eq(a.DRT.store:Own(note), false)
		a.DRT:SelectNote(key); a.DRT:DeleteSelected(); a.DRT:SaveSelected()
	end
	eq(count(a.DRT.store.remote), 1); eq(count(a.DRT.store.profile.notes), 1)
end)

test("empty realm from UnitFullName falls back to the local realm", function()
	local w = world(); local a = w:client("A")
	a.DRT.store = nil
	a.UnitFullName = function() return "A", "" end
	a.DRT:OnLogin()
	eq(a.DRT.playerFullName, "A-Realm"); assert(a.DRT.store)
end)

test("missing player identity defers initialization without touching saves", function()
	local w = world(); local a = w:client("A")
	uiSave(a, "Mine", "precious")
	local profile = a.DRT.store.profile
	a.DRT.store = nil; a.UnitGUID = function() return nil end
	a.DRT:OnLogin(); w:advance(2)
	eq(a.DRT.store, nil); eq(count(profile.notes), 1)
	a.UnitGUID = function() return "GUID-A" end
	w:advance(2); eq(a.DRT.store.profile, profile); eq(count(profile.notes), 1)
end)

test("40-member raid isolates simultaneous same-ID chunk streams", function()
	local w = world(); w.raid = true
	local names, clients = {}, {}
	for i = 1, 40 do
		local name = "Player" .. i
		names[i] = name; clients[i] = w:client(name)
		uiSave(clients[i], "Note " .. i, "{rt1} " .. string.rep("текст ", 20))
	end
	w:roster(names); w:advance(40)
	for _, client in ipairs(clients) do
		eq(count(client.DRT.store.profile.notes), 1)
		eq(count(client.DRT.store.remote), 39)
		for _, note in pairs(client.DRT.store.remote) do assert(note.body:find("текст", 1, true)) end
	end
	local first = clients[1]
	first.DRT:SetSelectedShared(false); w:advance(35)
	for i = 2, 40 do eq(count(clients[i].DRT.store.remote), 38) end
	w:roster({}); w:advance(1)
	for _, client in ipairs(clients) do
		eq(count(client.DRT.store.profile.notes), 1); eq(count(client.DRT.store.remote), 0)
	end
end)

test("untrusted parser input stays bounded and cannot throw", function()
	math.randomseed(731)
	for _ = 1, 2000 do
		local chars = {}
		for i = 1, math.random(0, 200) do chars[i] = string.char(math.random(0, 255)) end
		local payload = table.concat(chars)
		assert(pcall(N.Unpack, payload)); assert(pcall(N.Decode, payload))
	end
end)

test("addon and channel throttling retry the same chunk", function()
	local w = world(); local a, b = w:client("A"), w:client("B")
	uiSave(a, "Large", string.rep("throttle ", 100))
	a.throttleResults = { 3, 8 }
	w:roster({ "A", "B" }); w:advance(30)
	eq(#a.throttleResults, 0); eq(count(b.DRT.store.remote), 1)
end)

print("All " .. passed .. " regression tests passed (" .. _VERSION .. ").")
