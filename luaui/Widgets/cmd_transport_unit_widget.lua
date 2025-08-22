function widget:GetInfo()
	return {
		name = "Transport To",
		desc = "Adds a map-click Transport To command and auto-assigns transports",
		author = "Silla Noble",
		license = "A what now?",
		layer = 1,
		enabled = true,
		handler = true,
	}
end

local LOG_VERBOSE = false
local LOG_DETAIL = false

local Echo = Spring.Echo
local GetMyPlayerID = Spring.GetMyPlayerID
local GetPlayerInfo = Spring.GetPlayerInfo
local GetTeamUnits = Spring.GetTeamUnits
local GetUnitDefID = Spring.GetUnitDefID
local GetUnitCommands = Spring.GetUnitCommands
local GetUnitIsTransporting = Spring.GetUnitIsTransporting
local GetUnitPosition = Spring.GetUnitPosition
local GetUnitTeam = Spring.GetUnitTeam
local GiveOrderToUnit = Spring.GiveOrderToUnit
local ValidUnitID = Spring.ValidUnitID
local AreTeamsAllied = Spring.AreTeamsAllied
local GameFrame = Spring.GetGameFrame
local spGetUnitCurrentCommand = Spring.GetUnitCurrentCommand
local spFindUnitCmdDesc = Spring.FindUnitCmdDesc
local spGetUnitCmdDescs = Spring.GetUnitCmdDescs

local CMDTYPE_ICON_MAP = CMDTYPE.ICON_MAP
local CMD_LOAD_UNITS = CMD.LOAD_UNITS
local CMD_UNLOAD_UNITS = CMD.UNLOAD_UNITS
local CMD_STOP = CMD.STOP
local CMD_WAIT = CMD.WAIT
local CMD_INSERT = CMD.INSERT
local CMD_MOVE = CMD.MOVE
local CMD_FIGHT = CMD.FIGHT

-- Pretty, cycle-safe table -> string for debugging.
local function debug_tostring(value, opts, _depth, _seen)
    opts = opts or {}
    local indentStr = opts.indent or "  "
    local maxDepth = opts.maxDepth or 3
    local sortKeys = (opts.sortKeys ~= false)
    local maxItems = opts.maxItems or 200
    local showMeta = opts.showMetatable or false
    local compact = opts.compact or false
    local showFuncs = (opts.showFunctions ~= false)

    _depth = _depth or 0
    _seen = _seen or {}

    local t = type(value)
    if t == "nil" or t == "number" or t == "boolean" then
        return tostring(value)
    elseif t == "string" then
        return string.format("%q", value)
    elseif t ~= "table" then
        if showFuncs or t ~= "function" then
            return string.format("<%s:%s>", t, tostring(value))
        else
            return "<function>"
        end
    end

    if _seen[value] then
        return string.format("<ref#%d>", _seen[value].id)
    end
    if _depth >= maxDepth then
        return "<table ...>"
    end

    local id = 1 + (function()
        local c = 0
        for _ in pairs(_seen) do c = c + 1 end
        return c
    end)()
    _seen[value] = { id = id }

    local function indent(n)
        return compact and "" or string.rep(indentStr, n)
    end

    -- detect array
    local arrMax, count = 0, 0
    for k, _ in pairs(value) do
        count = count + 1
        if type(k) == "number" and k > 0 and math.floor(k) == k then
            if k > arrMax then arrMax = k end
        end
    end
    local isArray = true
    local seenCount = 0
    for i = 1, arrMax do
        if value[i] == nil then isArray = false break end
        seenCount = seenCount + 1
    end
    if seenCount ~= count then isArray = false end

    if isArray then
        local items = {}
        for i = 1, arrMax do
            if #items >= maxItems then
                items[#items + 1] = "...(truncated)"
                break
            end
            items[#items + 1] = debug_tostring(value[i], opts, _depth + 1, _seen)
        end
        if compact then
            return "{" .. table.concat(items, ",") .. "}"
        else
            local pad = indent(_depth + 1)
            return "{"
                .. (#items > 0 and ("\n" .. pad .. table.concat(items, ",\n" .. pad) .. "\n" .. indent(_depth)) or "")
                .. "}"
        end
    else
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = k end
        if sortKeys then
            table.sort(keys, function(a, b)
                local ta, tb = type(a), type(b)
                if ta == tb then
                    if ta == "string" or ta == "number" then
                        return a < b
                    end
                    return tostring(a) < tostring(b)
                end
                return ta < tb
            end)
        end
        local pieces, emitted = {}, 0
        for _, k in ipairs(keys) do
            emitted = emitted + 1
            if emitted > maxItems then
                pieces[#pieces + 1] = compact and "...(truncated)" or (indent(_depth + 1) .. "...(truncated)")
                break
            end
            local v = value[k]
            local kv
            if type(k) == "string" and k:match("^[_%a][_%w]*$") then
                kv = string.format("%s = %s", k, debug_tostring(v, opts, _depth + 1, _seen))
            else
                kv = string.format("[%s] = %s", debug_tostring(k, opts, _depth + 1, _seen), debug_tostring(v, opts, _depth + 1, _seen))
            end
            if compact then pieces[#pieces + 1] = kv else pieces[#pieces + 1] = indent(_depth + 1) .. kv end
        end
        if showMeta then
            local mt = getmetatable(value)
            if mt then
                local mtStr = debug_tostring(mt, opts, _depth + 1, _seen)
                local line = compact and ("<metatable>=" .. mtStr) or (indent(_depth + 1) .. "<metatable> = " .. mtStr)
                pieces[#pieces + 1] = line
            end
        end
        if compact then
            return "{" .. table.concat(pieces, ",") .. "}"
        else
            local inner = table.concat(pieces, ",\n")
            return inner == "" and "{}" or ("{\n" .. inner .. "\n" .. indent(_depth) .. "}")
        end
    end
end

local function unameByDef(defID)
	local ud = defID and UnitDefs[defID]
	return (ud and ud.name) or ("def:" .. tostring(defID))
end

local function uname(unitID)
	local defID = GetUnitDefID(unitID)
	return string.format("%s#%d", unameByDef(defID), unitID or -1)
end

local function gf()
	return string.format("gf=%d", GameFrame())
end

local function E(fmt, ...)
	if LOG_VERBOSE then
		Echo(string.format(fmt, ...))
	end
end

local function Ed(fmt, ...)
	if LOG_DETAIL then
		Echo(string.format(fmt, ...))
	end
end

local CMD_TRANSPORT_TO = GameCMD.TRANSPORT_TO
local CMD_TRANSPORT_TO_DESC = {
	id = CMD_TRANSPORT_TO,
	type = CMDTYPE_ICON_MAP,
	name = "Transport To",
	cursor = nil,
	action = "transport_to",
}

local CMD_AUTO_TRANSPORT = GameCMD.AUTO_TRANSPORT

local HEAVY_TRANSPORT_MASS_THRESHOLD = 3000
local LIGHT_UNIT_SIZE_THRESHOLD = 6
local UNLOAD_RADIUS = 10

local function distanceSq(ax, az, bx, bz)
	local dx, dz = ax - bx, az - bz
	return dx * dx + dz * dz
end

local myTeamID = nil

local isFactoryDef = {}
local isNanoDef = {}
local isTransportDef = {}
local transportClass = {}
local transportCapacityMass = {}
local transportSizeLimit = {}
local transportCapSlots = {}

local isTransportableDef = {}
local unitMass = {}
local unitXsize = {}

local knownTransports = setmetatable({}, { __mode = "k" })
local busyTransport = {}
local pendingRequests = {}

local UPDATE_PERIOD = 0.25
local updateTimer = 0

local function buildDefCaches()
	for defID, ud in pairs(UnitDefs) do
		if ud.isTransport and ud.canFly and (ud.transportCapacity or 0) > 0 then
			isTransportDef[defID] = true
			transportCapacityMass[defID] = ud.transportMass or 0
			transportSizeLimit[defID] = ud.transportSize or 0
			transportCapSlots[defID] = ud.transportCapacity or 0
			transportClass[defID] = (transportCapacityMass[defID] >= HEAVY_TRANSPORT_MASS_THRESHOLD) and "heavy"
				or "light"
		end

		local movable = (ud.speed or 0) > 0
		local grounded = not ud.canFly
		local notBuilding = not ud.isBuilding
		local notCantBeTransported = (ud.cantBeTransported == nil) or (ud.cantBeTransported == false)
		local isNano = ud.isBuilder and not ud.canMove and not ud.isFactory
		local isFactory = ud.isFactory


		if grounded and notCantBeTransported then
			isTransportableDef[defID] = true
		end
		if isNano then
			isNanoDef[defID] = true
			isTransportableDef[defID] = true
		end
		if isFactory then
			isFactoryDef[defID] = true
			isTransportableDef[defID] = true
		end

		unitMass[defID] = ud.mass or 0
		unitXsize[defID] = ud.xsize or 0
	end
end

local function canTransportWithReason(transportID, transportDefID, unitID, unitDefID)
	local tName = uname(transportID)
	local uName = uname(unitID)

	local trans = GetUnitIsTransporting(transportID)
	if not trans then
		return false, string.format("%s has no transport state", tName)
	end
	if #trans > 0 then
		return false, string.format("%s already carrying cargo (#%d)", tName, #trans)
	end

	local maxSize = transportSizeLimit[transportDefID] or 0
	local uSize = unitXsize[unitDefID] or 0
	if maxSize > 0 and (uSize > maxSize * 2) then
		return false, string.format("%s size too big for %s (uSize=%d > limit*2=%d)", uName, tName, uSize, maxSize * 2)
	end

	local capacityMass = transportCapacityMass[transportDefID] or 0
	local uMass = unitMass[unitDefID] or 0
	if capacityMass > 0 and uMass > capacityMass then
		return false, string.format("%s mass too high for %s (uMass=%d > cap=%d)", uName, tName, uMass, capacityMass)
	end

	local q = GetUnitCommands(transportID, 5) or {}
	if #q > 0 then
		for i = 1, #q do
			if q[i].id == CMD_WAIT then
				return false, string.format("%s is waiting", tName)
			end
		end
		return false, string.format("%s has non-empty queue (#%d)", tName, #q)
	end

	return true, "ok"
end

local function unitRequestedType(unitDefID)
	local size = unitXsize[unitDefID] or 0
	local mass = unitMass[unitDefID] or 0
	if size <= LIGHT_UNIT_SIZE_THRESHOLD and mass < HEAVY_TRANSPORT_MASS_THRESHOLD then
		return "light"
	end
	return "heavy"
end

local function isValidAndMine(unitID)
	if not ValidUnitID(unitID) then
		return false
	end
	local team = GetUnitTeam(unitID)
	return team and AreTeamsAllied(team, myTeamID)
end

local function refreshKnownTransports()
	knownTransports = setmetatable({}, { __mode = "k" })
	local units = GetTeamUnits(myTeamID)
	for i = 1, #units do
		local u = units[i]
		local defID = GetUnitDefID(u)
		if defID and isTransportDef[defID] then
			knownTransports[u] = true
		end
	end
	E("[TransportTo] %s refreshed transports: %d found", gf(), (units and #units) or 0)
end

function isAutomaticTransport(unitID)
    local cmdDescIndex = spFindUnitCmdDesc(unitID, CMD_AUTO_TRANSPORT)
	return cmdDescIndex and spGetUnitCmdDescs(unitID)[cmdDescIndex].params[1]+0 == 1
end

local function pickBestTransport(unitID, ux, uz, unitDefID)
	local wantType = unitRequestedType(unitDefID)
	local bestLight, bestLightD, bestHeavy, bestHeavyD

	-- Ed("[TransportTo:Pick] %s searching for transport", gf())
	for transportID in pairs(knownTransports) do
		local isAutomatic = isAutomaticTransport(transportID)
		if (not busyTransport[transportID]) and isAutomatic then
			local tDefID = GetUnitDefID(transportID)
			if tDefID then
				local ok, reason = canTransportWithReason(transportID, tDefID, unitID, unitDefID)
				if ok then
					local tx, _, tz = GetUnitPosition(transportID)
					if tx and tz and ux and uz then
						local d = distanceSq(tx, tz, ux, uz)
						local cls = transportClass[tDefID]
						if cls == "light" then
							if not bestLight or d < bestLightD then
								bestLight, bestLightD = transportID, d
							end
						else
							if not bestHeavy or d < bestHeavyD then
								bestHeavy, bestHeavyD = transportID, d
							end
						end
						Ed(
							"[TransportTo:Pick] %s candidate %s (%s) dist2=%.0f",
							gf(),
							uname(transportID),
							cls or "?",
							d
						)
					end
				else
					Ed("[TransportTo:Pick] %s reject %s -> %s", gf(), uname(transportID), reason)
				end
			end
		else
			if busyTransport[transportID] then
				Ed("[TransportTo:Pick] %s skip %s (busy)", gf(), uname(transportID))
			end
			if not isAutomatic then
				Ed("[TransportTo:Pick] %s skip %s (not automatic)", gf(), uname(transportID))
			end
		end
	end

	if wantType == "light" and bestLight then
		return bestLight, "light"
	end
	if bestLight then
		return bestLight, "light"
	end
	if bestHeavy then
		return bestHeavy, "heavy"
	end
	return nil, nil
end

local function issuePickupAndDrop(transportID, unitID, target)
	E(
		"[TransportTo:Queue] %s pickup %s then drop at (%.1f,%.1f,%.1f) %s",
		gf(),
		uname(unitID),
		target[1],
		target[2],
		target[3],
		uname(transportID)
	)
	local chainedTargets = {}
	local chainLenght = 0
	for _, cmd in ipairs(GetUnitCommands(unitID, -1)) do
		if cmd.id == CMD_TRANSPORT_TO then
			chainLenght = chainLenght + 1
			table.insert(chainedTargets, cmd)
		else break end
	end
	GiveOrderToUnit(transportID, CMD_LOAD_UNITS, { unitID }, 0)
	for index, cmd in ipairs(chainedTargets) do
		if index == #chainedTargets then
			GiveOrderToUnit(transportID, CMD_UNLOAD_UNITS, {cmd.params[1], cmd.params[2], cmd.params[3], UNLOAD_RADIUS }, { "shift" })
		else
			GiveOrderToUnit(transportID, CMD_MOVE, {cmd.params[1], cmd.params[2], cmd.params[3]}, { "shift" })
		end
	end
end

local function reloadBindings() end

function widget:Initialize()
	local _, _, _, teamID = GetPlayerInfo(GetMyPlayerID(), false)
	myTeamID = teamID
	buildDefCaches()
	refreshKnownTransports()
	reloadBindings()
	Spring.AssignMouseCursor("transto", "cursortransport")
	Spring.SetCustomCommandDrawData(CMD_TRANSPORT_TO, "transto", {1,1,1,1}) 
	E("[TransportTo] %s init complete", gf())
end

function widget:PlayerChanged(playerID)
	if Spring.GetSpectatingState() then
		E("[TransportTo] %s removed (spectator)", gf())
		widgetHandler:RemoveWidget()
		return
	end
	local _, _, _, teamID = GetPlayerInfo(GetMyPlayerID(), false)
	myTeamID = teamID
	refreshKnownTransports()
end

function widget:UnitCreated(unitID, unitDefID, teamID)
	if teamID ~= myTeamID then
		return
	end
	if isTransportDef[unitDefID] then
		knownTransports[unitID] = true
		E("[TransportTo] %s transport spawned: %s", gf(), uname(unitID))
	end
end

function widget:UnitIdle(unitID, unitDefID, unitTeam)
	if unitTeam ~= myTeamID then
		return
	end
	if not isTransportDef[unitDefID] then
		return
	end
	busyTransport[unitID] = nil
end

function widget:UnitDestroyed(unitID, unitDefID, teamID)
	knownTransports[unitID] = nil
	busyTransport[unitID] = nil
	if pendingRequests[unitID] then
		E("[TransportTo:Abort] %s pending request dropped: %s destroyed", gf(), uname(unitID))
		pendingRequests[unitID] = nil
	end
end

function widget:CommandsChanged()
	local selected = Spring.GetSelectedUnits()
	local cc = widgetHandler.customCommands
	if #selected == 0 then
		return
	end
	local addCustom = false
	for i = 1, #selected do
		local defID = GetUnitDefID(selected[i])
		if defID and (isTransportableDef[defID] or isNanoDef[defID] or isFactoryDef[defID]) then
			addCustom = true
			break
		end
	end
	if addCustom then
		cc[#cc + 1] = CMD_TRANSPORT_TO_DESC
	end
end

function widget:CommandNotify(cmdID, params, opts)
	-- local commandQueue = GetUnitCommands(unitID, -1) or {}
	local selected = Spring.GetSelectedUnits()
	if cmdID == CMD_TRANSPORT_TO then
		if #selected > 1 then
			return true
		end
	end
	return false
end

function widget:Update(dt)
	updateTimer = updateTimer + dt
	if updateTimer < UPDATE_PERIOD then
		return
	end
	updateTimer = 0

	for unitID, req in pairs(pendingRequests) do
		local cmdID, opts, tag = spGetUnitCurrentCommand(unitID, count)
		local commandQueue = GetUnitCommands(unitID, -1)
		if not isValidAndMine(unitID) then
			E("[TransportTo:Abort] %s pending invalid: %s (unit invalid)", gf(), uname(unitID))
			pendingRequests[unitID] = nil
		elseif cmdID ~= CMD_TRANSPORT_TO and #commandQueue > 0 then
			E("[TransportTo:Abort] %s pending no longer has a TRNASPORT_TO command: unit: %s, queue: %s", gf(), uname(unitID), debug_tostring(commandQueue))
			pendingRequests[unitID] = nil
		else
			local ux, uy, uz = GetUnitPosition(unitID)
			local tID, cls = pickBestTransport(unitID, ux, uz, req.unitDefID)
			if tID and isValidAndMine(tID) then
				busyTransport[tID] = true
				local target = { req[1], req[2], req[3] }
				E("[TransportTo:Pick] %s assigned %s (%s) -> %s", gf(), uname(tID), cls or "?", uname(unitID))
				issuePickupAndDrop(tID, unitID, target)
				E("[TransportTo] %s pending fulfilled: %s by %s", gf(), uname(unitID), uname(tID))
				pendingRequests[unitID] = nil
			else
				Ed("[TransportTo:Pick] %s no match yet for %s", gf(), uname(unitID))
			end
		end
	end
end

local function handleTransportToUnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag, bypass)
	local commandQueue = GetUnitCommands(unitID, -1)

	if not unitTeam or not AreTeamsAllied(unitTeam, myTeamID) then
		return
	end
	if not unitID or not unitDefID or not isTransportableDef[unitDefID] then
		return
	end

	if not bypass then
		if commandQueue[1] then
			if commandQueue[1].id ~= CMD_TRANSPORT_TO then
				return
			else
				cmdParams = commandQueue[1].params
				cmdOpts = commandQueue[1].options
			end
		else
			return
		end
	end

	local x, y, z = cmdParams[1], cmdParams[2], cmdParams[3]
	if not (x and y and z) then
		E("[TransportTo] %s UnitCommand missing coords for %s for CMDID %s", gf(), uname(unitID), tostring(unitID))
		return
	end

	pendingRequests[unitID] = { x, y, z, requestedGF = GameFrame(), unitDefID = unitDefID }
	-- if not pendingRequests[unitID] then
	-- 	pendingRequests[unitID] = { x, y, z, requestedGF = GameFrame(), unitDefID = unitDefID }
	-- end

	local t = unitRequestedType(unitDefID)
	E("[TransportTo] %s pending (UnitCommand): %s -> (%.1f,%.1f,%.1f) type=%s, commandQueue: %s", gf(), uname(unitID), x, y, z, t, debug_tostring(commandQueue))
end

function widget:UnitCmdDone(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag)
	handleTransportToUnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag, false)
end

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag)
	if not unitTeam or not AreTeamsAllied(unitTeam, myTeamID) then
		return
	end
	-- if cmdOpts and cmdOpts.internal then
	-- 	return
	-- end

	if cmdID == CMD_TRANSPORT_TO then
		local commandQueue = GetUnitCommands(unitID, 2)
		if commandQueue[1] and not(commandQueue[1].id == CMD_MOVE or commandQueue[1].id == CMD_FIGHT) then
			return
		else
			E("[TransportTo] %s using bypass for transportee %s", gf(), uname(unitID))
			handleTransportToUnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts, cmdTag, true)
		end
	end
	-- if cmdID == CMD_WAIT then
	-- 	return
	-- end

	-- if pendingRequests[unitID] then
	-- 	E("[TransportTo:Abort] %s %s new cmd (%s) -> cancel pending request",
	-- 		gf(), uname(unitID), tostring(cmdID))
	-- 	pendingRequests[unitID] = nil
	-- end
end

function widget:Shutdown()
	busyTransport = {}
	pendingRequests = {}
	E("[TransportTo] %s shutdown", gf())
end
