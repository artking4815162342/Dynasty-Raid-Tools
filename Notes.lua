-- Persistent character-owned notes and disposable remote snapshots never share a table.
local Notes = {}
DRTNotes = Notes
Notes.__index = Notes
Notes.MAX_WIRE = 524288
Notes.MAX_NOTES = 512
Notes.MAX_BODY = 65536
Notes.MAX_TITLE = 320

local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in pairs(value) do result[key] = copy(item) end
	return result
end

function Notes.NormalizeName(name, realm)
	if type(name) ~= "string" or name == "" then return nil end
	local player, server = name:match("^([^%-]+)%-(.+)$")
	player, server = player or name, server or realm
	if not server or server == "" then return nil end
	return player .. "-" .. server:gsub("%s+", "")
end

local function validNote(note)
	return type(note) == "table" and type(note.id) == "string" and note.id ~= ""
		and type(note.title) == "string" and type(note.body) == "string"
end

function Notes.Open(db, guid, owner, realm, now)
	assert(type(guid) == "string" and guid ~= "" and owner, "Missing player identity")
	db.characters = db.characters or {}
	local profile = db.characters[guid]
	if not profile then
		profile = { notes = {}, revision = 0, nextID = 0 }
		db.characters[guid] = profile
	end
	profile.notes = profile.notes or {}
	profile.revision = tonumber(profile.revision) or 0
	profile.nextID = tonumber(profile.nextID) or 0
	profile.owner = owner
	local self = setmetatable({ db = db, profile = profile, guid = guid, owner = owner,
		remote = {}, revisions = {}, drafts = {} }, Notes)

	-- Old account-wide records have no reliable local/remote provenance. Archive all,
	-- and claim only records matching the character that actually logged in.
	db.legacyNotes = db.legacyNotes or {}
	if type(db.notes) == "table" then
		for key, note in pairs(db.notes) do
			if db.legacyNotes[key] == nil then db.legacyNotes[key] = copy(note) end
		end
		db.notes = nil
	end
	db.legacyClaims = db.legacyClaims or {}
	for key, note in pairs(db.legacyNotes) do
		if validNote(note) and not note.deleted and not db.legacyClaims[key]
			and Notes.NormalizeName(note.owner, realm) == owner then
			local imported = copy(note)
			if profile.notes[imported.id] then imported.id = self:NextID(now) end
			imported.owner, imported.ownerGUID = owner, guid
			imported.shared = imported.shared ~= false
			imported.key, imported.deleted = nil, nil
			profile.notes[imported.id] = imported
			db.legacyClaims[key] = guid
		end
	end
	if type(db.main) == "table" then
		if type(db.main.text) == "string" and db.main.text:find("%S") then
			local note = self:Create(now)
			note.title, note.body = "Сохранённая заметка", db.main.text
			note.shared, note.localOnly = false, nil
		end
		db.main = nil
	end
	if not db.noteWindow and type(db.mainWindow) == "table" then
		db.noteWindow = copy(db.mainWindow)
		db.noteWindow.enabled, db.noteWindow.key = false, nil
	end
	db.mainWindow = nil
	for _, note in pairs(profile.notes) do
		if validNote(note) then
			note.owner, note.ownerGUID = owner, guid
			note.shared = note.shared ~= false
		end
	end
	db.schemaVersion = 2
	self:Touch(now)
	return self
end

function Notes:Touch(now)
	self.profile.revision = math.max(self.profile.revision + 1, now or 0)
	return self.profile.revision
end

function Notes:NextID(now)
	local id
	repeat
		self.profile.nextID = self.profile.nextID + 1
		id = tostring(now or 0) .. "-" .. tostring(self.profile.nextID)
	until not self.profile.notes[id]
	return id
end

function Notes:Create(now)
	local note = { id = self:NextID(now), owner = self.owner, ownerGUID = self.guid,
		title = "Новая заметка", body = "", updated = now, shared = true, localOnly = true }
	self.profile.notes[note.id] = note
	return note
end

function Notes:Own(note)
	return type(note) == "table" and self.profile.notes[note.id] == note
end

function Notes:Key(note)
	return self:Own(note) and ("local:" .. note.id) or (note.owner .. "\030" .. note.id)
end

function Notes:Get(key)
	if not key then return nil end
	local id = key:match("^local:(.+)$")
	return id and self.profile.notes[id] or self.remote[key]
end

function Notes:List()
	local list = {}
	for _, source in ipairs({ self.profile.notes, self.remote }) do
		for _, note in pairs(source) do
			if validNote(note) then list[#list + 1] = note end
		end
	end
	return list
end

function Notes:Prune(isMember)
	for key, note in pairs(self.remote) do
		if not isMember(note.owner) then self.remote[key] = nil end
	end
	for owner in pairs(self.revisions) do
		if not isMember(owner) then self.revisions[owner] = nil end
	end
end

function Notes.Pack(kind, fields)
	local parts = { kind .. "|" }
	for _, field in ipairs(fields) do
		field = tostring(field)
		parts[#parts + 1] = #field .. ":" .. field
	end
	return table.concat(parts)
end

function Notes.Unpack(payload)
	if type(payload) ~= "string" or #payload > Notes.MAX_WIRE then return nil end
	local kind, pos = payload:match("^([A-Z]+)|()")
	if not kind then return nil end
	local fields = {}
	while pos <= #payload do
		local digits, first = payload:match("^(%d+):()", pos)
		if not digits or #digits > 7 then return nil end
		local length = tonumber(digits)
		local last = first + length - 1
		if last > #payload or #fields >= 3 + Notes.MAX_NOTES * 4 then return nil end
		fields[#fields + 1] = payload:sub(first, last)
		pos = last + 1
	end
	return kind, fields
end

function Notes.Encode(payload)
	return (payload:gsub("([^A-Za-z0-9_%.%-])", function(char)
		return string.format("%%%02X", char:byte())
	end))
end

function Notes.Decode(payload)
	if payload:gsub("%%%x%x", ""):find("%%") then return nil end
	return (payload:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

function Notes:Snapshot()
	local fields = { self.owner, self.profile.revision, 0 }
	local ids = {}
	for id, note in pairs(self.profile.notes) do
		if validNote(note) and note.shared and not note.localOnly then ids[#ids + 1] = id end
	end
	table.sort(ids)
	if #ids > Notes.MAX_NOTES then return nil, "Слишком много расшаренных заметок (максимум 512)." end
	fields[3] = #ids
	for _, id in ipairs(ids) do
		local note = self.profile.notes[id]
		if #id > 96 or #note.title > Notes.MAX_TITLE or #note.body > Notes.MAX_BODY then
			return nil, "Заметка слишком большая для синхронизации: максимум 64 КБ текста и 80 символов названия."
		end
		fields[#fields + 1] = id
		fields[#fields + 1] = note.updated or 0
		fields[#fields + 1] = note.title
		fields[#fields + 1] = note.body
	end
	local encoded = Notes.Encode(Notes.Pack("SNAP", fields))
	if #encoded > Notes.MAX_WIRE then return nil, "Общий объём расшаренных заметок слишком большой. Отключите «Шарить» у части заметок." end
	return encoded
end

function Notes:Save(note, title, body, now)
	if not self:Own(note) then return false end
	local previous = { title = note.title, body = note.body, updated = note.updated, localOnly = note.localOnly }
	note.title, note.body, note.updated, note.localOnly = title, body, now, nil
	local encoded, err
	if note.shared then encoded, err = self:Snapshot() else encoded = true end
	if not encoded then
		for _, key in ipairs({ "title", "body", "updated", "localOnly" }) do note[key] = previous[key] end
		return false, err
	end
	self:Touch(now)
	return true
end

function Notes:Share(note, shared, now)
	if not self:Own(note) then return false end
	local previous = note.shared
	note.shared = shared and true or false
	local encoded, err = self:Snapshot()
	if not encoded and shared then note.shared = previous; return false, err end
	self:Touch(now)
	return true
end

function Notes:Delete(note, now)
	if not self:Own(note) then return false end
	local key = self:Key(note)
	self.profile.notes[note.id] = nil
	self.drafts[key] = nil
	self:Touch(now)
	return true
end

function Notes:Apply(sender, fields, isMember)
	if not isMember(sender) or sender == self.owner or fields[1] ~= sender then return false end
	local revision, count = tonumber(fields[2]), tonumber(fields[3])
	if not revision or revision < 0 or revision > 9007199254740991 or revision % 1 ~= 0
		or not count or count < 0 or count > Notes.MAX_NOTES or count % 1 ~= 0
		or #fields ~= 3 + count * 4 then return false end
	if self.revisions[sender] and revision <= self.revisions[sender] then return false end
	local replacement = {}
	for i = 1, count do
		local offset = 3 + (i - 1) * 4
		local id, updated, title, body = fields[offset + 1], tonumber(fields[offset + 2]), fields[offset + 3], fields[offset + 4]
		if not id or #id == 0 or #id > 96 or id:find("[%c]") or not updated
			or updated < 0 or updated > 4102444800000 or updated % 1 ~= 0
			or #title > Notes.MAX_TITLE or #body > Notes.MAX_BODY then return false end
		local key = sender .. "\030" .. id
		if replacement[key] then return false end
		replacement[key] = { id = id, owner = sender, title = title, body = body, updated = updated, shared = true }
	end
	-- Validate the complete snapshot before replacing only this sender's cache.
	for key, note in pairs(self.remote) do
		if note.owner == sender then self.remote[key] = nil end
	end
	for key, note in pairs(replacement) do self.remote[key] = note end
	self.revisions[sender] = revision
	return true
end
