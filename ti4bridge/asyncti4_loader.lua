--[[ ===========================================================================
  AsyncTI4 -> TTS unit loader
  ---------------------------------------------------------------------------
  Drop this script on ANY object in the TI4 mod (a tile/notecard/token).
  Workflow:
    1. Build the galaxy first with the mod's Map Tool (paste the map string,
       hit Build). Units are NOT placed by the Map Tool.
    2. Type the AsyncTI4 game name into the input field on this object
       (e.g. "pbd24975").
    3. Click "Place Units". The loader fetches the live game state from
       asyncti4 and spawns every player's ships/ground forces/structures
       onto the matching system tiles.

  Stateless / disposable: spawn a clean table, build the map, run this. To
  reset, just reload a fresh table. Nothing is saved or mutated server-side.

  Scope (v1): places ship + ground unit plastic for player factions:
    Carrier, Cruiser, Destroyer, Dreadnought, Fighter, Infantry, Mech,
    PDS, Space Dock, War Sun.
  Logs (does not place): Flagships (bag names are faction-specific) and
  neutral map tokens (custodian / frontier / DMZ / exploration, mostly
  already placed by the Map Tool). Place those by hand if needed.
=========================================================================== ]]

local API_BASE = 'https://bot.asyncti4.com/api/public/game/'

-- AsyncTI4 unit id -> TTS unit-bag suffix.  Flagship handled separately.
local UNIT_ID_TO_NAME = {
    cv = 'Carrier',
    ca = 'Cruiser',
    dd = 'Destroyer',
    dn = 'Dreadnought',
    ff = 'Fighter',
    gf = 'Infantry',
    mf = 'Mech',
    pd = 'PDS',
    sd = 'Space Dock',
    ws = 'War Sun',
    -- fs (Flagship) intentionally omitted -> logged for manual placement.
}

-- Extended AsyncTI4 colour names -> nearest standard TTS colour.  Standard
-- async colours (red/blue/green/yellow/purple/orange/pink/black) pass through.
-- Editable: if a Twilight's Fall colour lands on the wrong plastic, fix here.
local ASYNC_TO_TTS_COLOR = {
    red = 'Red', blue = 'Blue', green = 'Green', yellow = 'Yellow',
    purple = 'Purple', orange = 'Orange', pink = 'Pink', black = 'Black',
    white = 'White', brown = 'Brown',
    -- extended:
    copper = 'Orange', rose = 'Pink', aberration = 'Black', gold = 'Yellow',
    tan = 'Brown', teal = 'Blue', petrol = 'Blue', chrome = 'White',
    emerald = 'Green', navy = 'Blue', magenta = 'Purple', sunset = 'Orange',
    turquoise = 'Blue', lightgray = 'White', lightgrey = 'White',
}

local _gameName = ''
local _busy = false

-- ---------------------------------------------------------------------------
-- Helper client (verbatim pattern from the mod's scripts)
-- ---------------------------------------------------------------------------
function getHelperClient(helperObjectName)
    local function getHelperObject()
        for _, object in ipairs(getAllObjects()) do
            if object.getName() == helperObjectName then return object end
        end
        error('missing object "' .. helperObjectName .. '"')
    end
    local helperObject = false
    local function getCallWrapper(functionName)
        helperObject = helperObject or getHelperObject()
        if not helperObject.getVar(functionName) then
            error('missing ' .. helperObjectName .. '.' .. functionName)
        end
        return function(parameters) return helperObject.call(functionName, parameters) end
    end
    return setmetatable({}, { __index = function(t, k) return getCallWrapper(k) end })
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------
function onLoad(saveState)
    if saveState and saveState ~= '' then
        local ok, decoded = pcall(function() return JSON.decode(saveState) end)
        if ok and type(decoded) == 'table' and decoded.gameName then
            _gameName = decoded.gameName
        end
    end
    self.createInput({
        label = 'AsyncTI4 game name',
        value = _gameName,
        input_function = 'onGameNameChanged',
        function_owner = self,
        alignment = 2,
        position = { x = 0, y = 0.3, z = -1.05 },
        width = 1800, height = 220, font_size = 140,
    })
    self.createButton({
        label = 'Clear Home Slots',
        click_function = 'onClearHomeSlots',
        function_owner = self,
        position = { x = 0, y = 0.3, z = -0.4 },
        width = 1400, height = 300, font_size = 150,
        color = { 0.7, 0.45, 0.1 }, font_color = { 1, 1, 1 },
    })
    self.createButton({
        label = 'Print Map String',
        click_function = 'onPrintMapString',
        function_owner = self,
        position = { x = 0, y = 0.3, z = 0.25 },
        width = 1400, height = 300, font_size = 150,
        color = { 0.2, 0.3, 0.55 }, font_color = { 1, 1, 1 },
    })
    self.createButton({
        label = 'Place Units',
        click_function = 'onPlaceUnits',
        function_owner = self,
        position = { x = 0, y = 0.3, z = 0.9 },
        width = 1400, height = 300, font_size = 150,
        color = { 0.1, 0.5, 0.1 }, font_color = { 1, 1, 1 },
    })
end

function onSave()
    return JSON.encode({ gameName = _gameName })
end

function onGameNameChanged(_, _, value)
    _gameName = (value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

-- Remove the mod's home-system placeholder tiles so the Map Tool's
-- _moveHomeSystems step has nothing to reset your real home tiles back to.
-- Build the map AFTER clicking this and the string's literal home systems
-- (e.g. tile 02 Mentak) stay placed. Reload the game to restore placeholders.
function onClearHomeSlots()
    local toKill = {}
    for _, obj in ipairs(getAllObjects()) do
        local nm = obj.getName() or ''
        if nm:find('Home System Location', 1, true) then
            toKill[#toKill + 1] = obj
        end
    end
    for _, obj in ipairs(toKill) do obj.destruct() end
    broadcastToAll(string.format(
        'AsyncTI4 loader: cleared %d home placeholder(s). Build the map now - real home tiles will stay.',
        #toKill), { 1, 0.7, 0.3 })
    if #toKill == 0 then
        print('[AsyncTI4 loader] No "Home System Location" objects found - nothing to clear.')
    end
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------
function onPlaceUnits()
    if _busy then return end
    if _gameName == '' then
        broadcastToAll('AsyncTI4 loader: enter a game name first.', { 1, 0.4, 0.4 })
        return
    end
    _busy = true
    local url = API_BASE .. _gameName .. '/web-data'
    broadcastToAll('AsyncTI4 loader: fetching "' .. _gameName .. '"...', { 0.8, 0.8, 0.8 })
    WebRequest.get(url, function(result)
        local ok, err = pcall(function() handleWebData(result) end)
        if not ok then
            broadcastToAll('AsyncTI4 loader error: ' .. tostring(err), { 1, 0.3, 0.3 })
        end
        _busy = false
    end)
end

function onPrintMapString()
    if _busy then return end
    if _gameName == '' then
        broadcastToAll('AsyncTI4 loader: enter a game name first.', { 1, 0.4, 0.4 })
        return
    end
    _busy = true
    WebRequest.get(API_BASE .. _gameName .. '/web-data', function(result)
        local ok, err = pcall(function()
            if result.is_error then error('web request failed: ' .. tostring(result.error)) end
            local data = JSON.decode(result.text)
            if type(data) ~= 'table' or not data.tilePositions then
                error('unexpected response (wrong game name, or fog-of-war game?)')
            end
            local parts = {}
            for _, entry in ipairs(data.tilePositions) do
                local pos, tile = string.match(entry, '^([^:]+):(.+)$')
                if pos == '000' then
                    parts[#parts + 1] = '{' .. tile .. '}'
                elseif pos and string.match(pos, '^%d%d%d$') then
                    parts[#parts + 1] = tile
                end
            end
            local mapString = table.concat(parts, ' ')
            print('[AsyncTI4 loader] map string for ' .. _gameName .. ':')
            print(mapString)
            broadcastToAll('AsyncTI4 loader: map string printed to console (~). Paste it into the Map Tool.', { 0.6, 0.8, 1 })
        end)
        if not ok then broadcastToAll('AsyncTI4 loader error: ' .. tostring(err), { 1, 0.3, 0.3 }) end
        _busy = false
    end)
end

function handleWebData(result)
    if result.is_error then
        error('web request failed: ' .. tostring(result.error))
    end
    local data = JSON.decode(result.text)
    if type(data) ~= 'table' or not data.tilePositions or not data.tileUnitData then
        error('unexpected response (wrong game name, or fog-of-war game?)')
    end

    -- position string -> tile number (strip braces/letters: "{112}"->112, "86a"->86)
    local posToTileNum = {}
    for _, entry in ipairs(data.tilePositions) do
        local pos, tile = string.match(entry, '^([^:]+):(.+)$')
        if pos and tile then
            local n = tonumber(string.match(tile, '%d+'))
            if n then posToTileNum[pos] = n end
        end
    end

    -- tile number -> placed tile object (uses the mod's authoritative registry)
    local systemHelper = getHelperClient('TI4_SYSTEM_HELPER')
    local guidToSystem = systemHelper.systems()
    local tileNumToObject = {}
    for _, obj in ipairs(getAllObjects()) do
        local sys = guidToSystem[obj.getGUID()]
        if sys and sys.tile then tileNumToObject[sys.tile] = obj end
    end

    -- faction -> TTS colour (Twilight's Fall: "<colour>tf"; else player colour)
    local factionToColor = {}
    for _, p in ipairs(data.playerData or {}) do
        if p.faction then
            factionToColor[p.faction] = resolveColor(p.faction, p.color)
        end
    end

    -- bag name -> supply container.  The TI4 mod's unit supply are INFINITE
    -- bags (type "Infinite"), not plain "Bag" -- filtering to only "Bag" finds
    -- none and places zero units.  Accept both.  Restricting to container types
    -- also avoids matching loose units already on the table, which carry the
    -- exact same "<Color> <Unit>" name but are Figurines (not takeable).
    local nameToBag = {}
    for _, obj in ipairs(getAllObjects()) do
        local objType = obj.type or obj.tag -- .tag is deprecated; .type is current
        if objType == 'Bag' or objType == 'Infinite' then
            nameToBag[obj.getName()] = obj
        end
    end

    local tally = { placed = 0, flagship = 0, neutral = 0, nobag = {}, notile = {}, nocolor = {} }
    local spawnIndex = {} -- per-tile counter so units fan out

    local function placeUnits(tileObj, faction, unitList)
        local color = factionToColor[faction]
        for _, e in ipairs(unitList) do
            local count = tonumber(e.count) or 1
            local id = e.entityId
            if id == 'fs' then
                tally.flagship = tally.flagship + count
            elseif not UNIT_ID_TO_NAME[id] then
                tally.neutral = tally.neutral + count -- tokens, custodian, etc.
            elseif not color then
                tally.nocolor[faction] = true
            else
                local unitName = UNIT_ID_TO_NAME[id]
                local bagName = color .. ' ' .. unitName
                local bag = nameToBag[bagName]
                if not bag then
                    tally.nobag[bagName] = true
                else
                    for _ = 1, count do
                        local guid = tileObj.getGUID()
                        local k = (spawnIndex[guid] or 0)
                        spawnIndex[guid] = k + 1
                        local phi = k * 0.55
                        local r = 0.8 + (k * 0.12)
                        bag.takeObject({
                            position = tileObj.positionToWorld({
                                x = math.cos(phi) * r, y = 1.5, z = math.sin(phi) * r,
                            }),
                            smooth = true,
                        })
                        tally.placed = tally.placed + 1
                    end
                end
            end
        end
    end

    for pos, tdata in pairs(data.tileUnitData) do
        local tileNum = posToTileNum[pos]
        local tileObj = tileNum and tileNumToObject[tileNum]
        if not tileObj then
            if tileNum then tally.notile[tostring(tileNum)] = true end
        else
            -- space units
            if type(tdata.space) == 'table' then
                for faction, unitList in pairs(tdata.space) do
                    if type(unitList) == 'table' then placeUnits(tileObj, faction, unitList) end
                end
            end
            -- planet units
            if type(tdata.planets) == 'table' then
                for _, pdata in pairs(tdata.planets) do
                    if type(pdata) == 'table' and type(pdata.entities) == 'table' then
                        for faction, unitList in pairs(pdata.entities) do
                            if type(unitList) == 'table' then placeUnits(tileObj, faction, unitList) end
                        end
                    end
                end
            end
        end
    end

    -- summary
    broadcastToAll(string.format('AsyncTI4 loader: placed %d units.', tally.placed), { 0.4, 1, 0.4 })
    if tally.flagship > 0 then
        broadcastToAll(string.format('  %d flagship(s) skipped - place by hand.', tally.flagship), { 1, 0.85, 0.4 })
    end
    if tally.neutral > 0 then
        print(string.format('[AsyncTI4 loader] %d neutral token(s) skipped (custodian/frontier/etc).', tally.neutral))
    end
    reportSet('No unit bag found for', tally.nobag)
    reportSet('No placed tile for tile#', tally.notile)
    reportSet('No colour resolved for faction', tally.nocolor)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
function resolveColor(faction, asyncColor)
    local tf = string.match(faction, '^(%a+)tf$') -- "redtf" -> "red"
    local base = tf or asyncColor
    if not base then return nil end
    base = string.lower(base)
    return ASYNC_TO_TTS_COLOR[base] or (base:sub(1, 1):upper() .. base:sub(2))
end

function reportSet(label, set)
    local keys = {}
    for k in pairs(set) do keys[#keys + 1] = k end
    if #keys > 0 then
        print('[AsyncTI4 loader] ' .. label .. ': ' .. table.concat(keys, ', '))
    end
end
