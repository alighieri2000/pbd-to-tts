--[[ ===========================================================================
  AsyncTI4 -> TTS unit loader  ::  LIVE BUILD (local proxy)
  ---------------------------------------------------------------------------
  TTS can't reach bot.asyncti4.com directly (TLS 1.3, TTS can't negotiate it).
  Solution: run asyncti4-proxy.ps1 on the same PC before opening TTS.
  That script listens on http://localhost:7331/ and forwards requests to the
  real API over PowerShell (which handles TLS 1.3 fine).

  To revert to the embedded-snapshot fallback, paste the JSON into EMBEDDED_JSON.
=========================================================================== ]]

local API_BASE = 'https://silent-silence-79ed.dantexcameron.workers.dev/game/'

-- Leave empty to always fetch live data via the local proxy.
-- Paste a JSON snapshot here to use offline without running the proxy.
local EMBEDDED_JSON = [==[]==]

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

local ASYNC_TO_TTS_COLOR = {
    red = 'Red', blue = 'Blue', green = 'Green', yellow = 'Yellow',
    purple = 'Purple', orange = 'Orange', pink = 'Pink', black = 'Black',
    white = 'White', brown = 'Brown',
    copper = 'Orange', rose = 'Pink', aberration = 'Black', gold = 'Yellow',
    tan = 'Brown', teal = 'Blue', petrol = 'Blue', chrome = 'White',
    emerald = 'Green', navy = 'Blue', magenta = 'Purple', sunset = 'Orange',
    turquoise = 'Blue', lightgray = 'White', lightgrey = 'White',
}

local _gameName = 'pbd24975' -- offline build is pinned to the embedded snapshot
local _busy = false

-- All possible TTS player colors (for zone discovery)
local ALL_TTS_COLORS = { 'Red', 'Blue', 'Green', 'Yellow', 'Purple',
    'Orange', 'Pink', 'Black', 'White', 'Brown' }

-- Probe every TTS color and return a table of color→center for zones that exist.
-- Also prints which zones were found so we can debug seat mismatches.
-- Discover active TTS player zones from the command sheets TI4_SETUP_HELPER placed.
-- "Command Sheet (Red)" etc. are always loose objects with no script — safe to call
-- from any context without triggering cross-script errors.  Avoids TI4_ZONE_HELPER
-- entirely, which uses startLuaCoroutine and throws uncatchable errors when active.
local function discoverZones()
    local zones = {}
    for _, obj in ipairs(getAllObjects()) do
        local nm = obj.getName() or ''
        local color = nm:match('^Command Sheet %((%a+)%)$')
        if color then
            local pos = obj.getPosition()
            -- Skip sheets that have been sent to the junk pile (x < -50).
            -- setupTFInner moves old command sheets to x≈-70; they must not
            -- be used as zone anchors after TF setup runs.
            if pos.x > -65 then zones[color] = pos end
        end
    end
    if next(zones) then return zones end
    -- Fallback: TF faction sheets (after TF setup replaced standard command sheets).
    -- Build a reverse map from sheet name → tf color so we can use the canonical
    -- TTS color as zone key (same key buildColorToZone expects).
    local sheetToTF = {}
    for tf, sn in pairs(TF_COLOR_TO_KING_SHEET) do sheetToTF[sn] = tf end
    for _, obj in ipairs(getAllObjects()) do
        local nm = obj.getName() or ''
        local tf = sheetToTF[nm]
        if tf then
            local ttsColor = ASYNC_TO_TTS_COLOR[tf] or (tf:sub(1,1):upper()..tf:sub(2))
            zones[ttsColor] = obj.getPosition()
        end
    end
    return zones
end

-- Build async-player-color → TTS zone-center, handling seat-color mismatches.
-- Returns: tfColor→center, allZones, tfColor→actualTTSColor
-- Strategy:
--   1. Try the canonical tf-color → TTS color mapping first.
--   2. Any async player whose expected TTS color has no zone is "unmatched".
--   3. Any TTS zone not claimed by a canonical match is "spare".
--   4. Auto-pair unmatched async players to spare zones (1-to-1).
local function buildColorToZone(data)
    local zones = discoverZones()
    if not next(zones) then return {}, {}, {} end

    local claimedZones = {}   -- TTS color already assigned
    local result = {}         -- tfColor → TTS center
    local tfToTTS = {}        -- tfColor → actual TTS seat color (after pairing)
    local unmatched = {}

    for _, p in ipairs(data.playerData or {}) do
        if p.faction and p.faction ~= 'neutral' then
            local tf = string.match(p.faction, '^(%a+)tf$')
            if tf then
                local ttsColor = ASYNC_TO_TTS_COLOR[tf:lower()] or (tf:sub(1,1):upper()..tf:sub(2))
                if zones[ttsColor] then
                    result[tf]          = zones[ttsColor]
                    tfToTTS[tf]         = ttsColor
                    claimedZones[ttsColor] = true
                else
                    unmatched[#unmatched + 1] = tf
                end
            end
        end
    end

    -- collect spare (unclaimed) zones
    local spare = {}
    for ttsColor, center in pairs(zones) do
        if not claimedZones[ttsColor] then
            spare[#spare + 1] = { color = ttsColor, center = center }
        end
    end

    -- pair unmatched async players to spare zones
    if #unmatched > 0 then
        local spareInfo = {}
        for _, s in ipairs(spare) do spareInfo[#spareInfo + 1] = s.color end
        print(string.format(
            '[AsyncTI4] Zone mismatch: async [%s] have no canonical TTS zone. Spare zones: [%s]. Auto-pairing.',
            table.concat(unmatched, ', '), table.concat(spareInfo, ', ')))
        for i, tf in ipairs(unmatched) do
            if spare[i] then
                result[tf]    = spare[i].center
                tfToTTS[tf]   = spare[i].color
                print(string.format('[AsyncTI4] Auto-paired %stf → %s zone', tf, spare[i].color))
            end
        end
    end

    return result, zones, tfToTTS
end

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
        -- TTS C# throws "Value cannot be null. Parameter name: key" when params is nil.
        -- Pass an empty table when no parameters are needed.
        return function(parameters) return helperObject.call(functionName, parameters or {}) end
    end
    return setmetatable({}, { __index = function(t, k) return getCallWrapper(k) end })
end

-- ---------------------------------------------------------------------------
-- Diagnostic log — written to self.description so it survives a TTS save.
-- Call diagLog() from any function; flushDiag() persists it.
-- ---------------------------------------------------------------------------
local _diagLines = {}
local function diagLog(msg)
    _diagLines[#_diagLines + 1] = msg
    print('[AsyncTI4 diag] ' .. msg)
end
local function flushDiag()
    self.setDescription('=== AsyncTI4 Diag ===\n' .. table.concat(_diagLines, '\n'))
end
local function resetDiag()
    _diagLines = {}
    diagLog('--- new run ---')
end

-- Single fetch path: embedded snapshot if present, else live WebRequest.
-- Logs URL, source, and raw response so network failures are visible.
function fetchData(onResult)
    if EMBEDDED_JSON ~= '' then
        diagLog('fetch: using EMBEDDED_JSON (' .. #EMBEDDED_JSON .. ' chars)')
        onResult({ is_error = false, text = EMBEDDED_JSON })
    else
        local url = API_BASE .. _gameName .. '/web-data'
        diagLog('fetch: GET ' .. url)
        WebRequest.get(url, function(result)
            diagLog('fetch result: is_error=' .. tostring(result.is_error)
                .. ' error=' .. tostring(result.error)
                .. ' text_len=' .. tostring(result.text and #result.text or 0))
            if result.text and #result.text > 0 then
                diagLog('fetch text[1:120]: ' .. result.text:sub(1, 120))
            end
            flushDiag()
            onResult(result)
        end)
    end
end

local _mapStringDisplay = ''

function onLoad(saveState)
    self.setLock(true)
    self.UI.setXml([[
<Panel id="panel_main"
       width="340" height="310"
       position="0 0 0"
       color="#0F172A"
       outline="#334155" outlineSize="2"
       padding="12 12 12 12">

  <!-- Header -->
  <HorizontalLayout height="28" childAlignment="MiddleLeft" spacing="6">
    <Text text="⬡" color="#38BDF8" fontSize="20" width="26"/>
    <Text text="AsyncTI4 Loader" color="#F1F5F9" fontSize="15" fontStyle="Bold"/>
  </HorizontalLayout>

  <!-- Divider -->
  <Panel height="1" color="#334155" margin="0 6 0 6"/>

  <!-- Game name input -->
  <HorizontalLayout height="32" spacing="6" margin="0 0 0 4">
    <Text text="Game" color="#94A3B8" fontSize="12" width="40" alignment="MiddleLeft"/>
    <InputField id="gameNameField"
                text="]] .. _gameName .. [["
                onValueChanged="onGameNameChanged"
                color="#1E293B" textColor="#F1F5F9"
                fontSize="13" height="32"/>
  </HorizontalLayout>

  <!-- Map string display -->
  <HorizontalLayout height="28" spacing="6" margin="0 0 0 6">
    <Text text="Map" color="#94A3B8" fontSize="12" width="40" alignment="MiddleLeft"/>
    <Text id="mapStringText"
          text="(build map to populate)"
          color="#64748B" fontSize="11" alignment="MiddleLeft"/>
  </HorizontalLayout>

  <!-- Buttons -->
  <Button id="btnBuild"
          text="⬡  Build Map"
          onClick="onBuildMap"
          color="#1E3A5F" textColor="#93C5FD"
          fontSize="14" height="44"
          outline="#3B82F6" outlineSize="1"
          margin="0 0 0 4"/>

  <Button id="btnClearHome"
          text="✕  Clear Home Slots"
          onClick="onClearHomeSlots"
          color="#431407" textColor="#FCA5A5"
          fontSize="14" height="40"
          outline="#DC2626" outlineSize="1"
          margin="0 0 0 4"/>

  <Button id="btnSetup"
          text="▶  Setup TF Game"
          onClick="onSetupTFGame"
          color="#064E3B" textColor="#6EE7B7"
          fontSize="15" height="48"
          outline="#10B981" outlineSize="1"
          fontStyle="Bold"/>

</Panel>
]])
end

-- Called by XML UI InputField
function onGameNameChanged(player, value)
    _gameName = (value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function updateMapStringDisplay(s)
    _mapStringDisplay = s or ''
    local display = _mapStringDisplay ~= '' and _mapStringDisplay or '(build map to populate)'
    pcall(function()
        self.UI.setAttribute('mapStringText', 'text', display)
        self.UI.setAttribute('mapStringText', 'color', _mapStringDisplay ~= '' and '#CBD5E1' or '#64748B')
    end)
end

local function findObjByName(name)
    for _, obj in ipairs(getAllObjects()) do
        if obj.getName() == name then return obj end
    end
    return nil
end

-- Build the map string from tile positions in the game data and attempt to
-- apply it to the TI4 map tool. Falls back to broadcasting the string if no
-- known map-tool helper is found.
local function buildMap(data)
    if type(data.tilePositions) ~= 'table' then
        broadcastToAll('[AsyncTI4] No tile positions in game data.', {1,0.6,0.3})
        return false
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
    local mapStr = table.concat(parts, ' ')
    if mapStr == '' then
        broadcastToAll('[AsyncTI4] Map string is empty.', {1,0.6,0.3})
        return false
    end

    updateMapStringDisplay(mapStr)
    broadcastToAll('[AsyncTI4] Map string ready — shown on loader panel and printed below:', {0.8, 0.8, 1})
    broadcastToAll(mapStr, {1, 1, 1})
    diagLog('map string stored: ' .. #mapStr .. ' chars')
    return true
end

function onBuildMap()
    if _busy then return end
    _busy = true
    resetDiag()
    fetchData(function(result)
        local ok, err = pcall(function()
            if result.is_error then error(result.error) end
            local data = JSON.decode(result.text)
            buildMap(data)
        end)
        if not ok then broadcastToAll('[AsyncTI4] Map error: ' .. tostring(err), {1,0.3,0.3}) end
        _busy = false
    end)
end

-- Shared: remove Home System Location placeholders so real home tiles stay in place.
-- destruct() is called with a short stagger to avoid batch C# errors.
local function clearHomeSlots()
    local toKill = {}
    for _, obj in ipairs(getAllObjects()) do
        local ok, nm = pcall(function() return obj.getName() end)
        if ok and nm and nm:find('Home System Location', 1, true) then
            toKill[#toKill + 1] = obj
        end
    end
    for i, obj in ipairs(toKill) do
        Wait.frames(function()
            local ok2 = pcall(function() obj.destruct() end)
            if not ok2 then obj.setPositionSmooth({x=200, y=5, z=0}, false, false) end
        end, i - 1)
    end
    return #toKill
end

-- Remove the mod's home-system placeholder tiles so the Map Tool's
-- _moveHomeSystems step has nothing to reset your real home tiles back to.
-- Build the map AFTER clicking this and the string's literal home systems
-- (e.g. tile 02 Mentak) stay placed. Reload the game to restore placeholders.
function onClearHomeSlots()
    local n = clearHomeSlots()
    broadcastToAll(string.format(
        'AsyncTI4 loader: cleared %d home placeholder(s). Build the map now - real home tiles will stay.',
        n), { 1, 0.7, 0.3 })
    if n == 0 then
        print('[AsyncTI4 loader] No "Home System Location" objects found - nothing to clear.')
    end
end

-- ---------------------------------------------------------------------------
-- Player cards: spawn the actual TF cards (abilities, faction tech, leaders)
-- into each player's play area.  Cards are located by name in whatever
-- decks/bags are on the table and taken (unlocked) into the zone; exhausted
-- ones are laid rotated.  Anything not found is reported -- that list tells us
-- what still needs to be present (TF setup not run, nested bag, name mismatch).
-- Decode tables are first-draft; unknown ids fall back to a prettified form.
-- ---------------------------------------------------------------------------


-- async leaderID -> exact TTS card nickname (sourced from mod JSON 1288687076.json)
local LEADER_NAMES = {
    yssarilagent      = 'Ssruu',
    ['naaluagent-te'] = "Z'eu",
    sardakkagent      = "T'ro",
    crimsonagent      = 'Ahk Ravin',
    -- TF factions use Genome cards (in the shared Genome deck) as their "agent"
    -- Genome cards (full deck from TF mod 1288687076.json)
    -- Async IDs follow the pattern [genomename]agent (lowercase, no spaces/apostrophes)
    valiantagent       = 'Valiant Genome',
    hyperagent         = 'Hyper Genome',
    limitagent         = 'Limit Genome',
    breachagent        = 'Breach Genome',
    actionagent        = 'Action Genome',
    altruisticagent    = 'Altruistic Genome',
    aristocraticagent  = 'Aristocratic Genome',
    brutalagent        = 'Brutal Genome',
    captainsagent      = "Captain's Genome",
    cleveragent        = 'Clever Genome',
    cosmicagent        = 'Cosmic Genome',
    courieragent       = 'Courier Genome',
    curiousagent       = 'Curious Genome',
    deploymentagent    = 'Deployment Genome',
    diplomaticagent    = 'Diplomatic Genome',
    divineagent        = 'Divine Genome',
    enigmaticagent     = 'Enigmatic Genome',
    experimentalagent  = 'Experimental Genome',
    humanagent         = 'Human Genome',
    investmentagent    = 'Investment Genome',
    mirroragent        = 'Mirror Genome',
    moltenagent        = 'Molten Genome',
    pacificagent       = 'Pacific Genome',
    ravenousagent      = 'Ravenous Genome',
    recursiveagent     = 'Recursive Genome',
    researchagent      = 'Research Genome',
    scornfulagent      = 'Scornful Genome',
    silveragent        = 'Silver Genome',
    splittingagent     = 'Splitting Genome',
    swarmagent         = 'Swarm Genome',
    temporalagent      = 'Temporal Genome',
}

-- Standard faction agent IDs that async uses to track TF faction genomes.
-- Each faction has exactly one associated genome per the TF wiki.
local TF_AGENT_GENOME = {
    ['naaluagent-te'] = 'Limit Genome',   -- Il Na Viroset / purpletf
    crimsonagent      = 'Breach Genome',  -- Avarice Rex / yellowtf
    yssarilagent      = 'Clever Genome',  -- The Ruby Monarch / redtf
    sardakkagent      = 'Swarm Genome',   -- The Saint of Swords / bluetf
}

-- Complete static map: async tech ID (tf- stripped, lowercase) -> exact TTS nickname.
-- Built from 1288687076.json. Covers every multi-word or abbreviated async ID.
-- Simple single-word tf- cards (tf-armada, tf-mitosis, tf-zealous, ...) fall through
-- to the prettyId fallback which adds "TF " + title-case automatically.
local TF_CARD = {
    as = 'TF Aetherstream', aetherstream = 'TF Aetherstream',
    -- abbreviated IDs (async uses first word; TTS name is longer)
    munitions              = 'TF Munitions Reserves',
    munitionsreserves      = 'TF Munitions Reserves',
    valkyrie               = 'TF Valkyrie Particle Weave',
    valkyrieparticleweave  = 'TF Valkyrie Particle Weave',
    -- merged multi-word IDs
    agencysupplynetwork    = 'TF Agency Supply Network',
    aeriehololattice       = 'TF Aerie Hololattice',
    biosyntheticsynergy    = 'TF Bio-Synthetic Synergy',
    blessingoftheyin       = 'TF Blessing of the Yin',
    brillianceofthehylar   = 'TF Brilliance of the Hylar',
    broodswarm             = 'TF Brood Swarm',
    changingtheways        = 'TF Changing the Ways',
    chaosmapping           = 'TF Chaos Mapping',
    couriertransport       = 'TF Courier Transport',
    devourworld            = 'TF Devour World',
    dimensionalreflection  = 'TF Dimensional Reflection',
    dimensionalsplicer     = 'TF Dimensional Splicer',
    dimensionaltear        = 'TF Dimensional Tear',
    distantsuns            = 'TF Distant Suns',
    eressiphons            = 'TF E-Res Siphons',
    entropicharvest        = 'TF Entropic Harvest',
    eternitysend           = "TF Eternity's End",
    eventhorizon           = 'TF Event Horizon',
    fleetlogistics         = 'TF Fleet Logistics',
    floatingfactories      = 'TF Floating Factories',
    flockmigration         = 'TF Flock Migration',
    forgelegend            = 'TF Forge Legend',
    futurepath             = 'TF Future Path',
    geneticresearch        = 'TF Genetic Research',
    gravitationalcollapse  = 'TF Gravitational Collapse',
    guildagents            = 'TF Guild Agents',
    guildships             = 'TF Guild Ships',
    hegemonictradepolicy   = 'TF Hegemonic Trade Policy',
    inheritancesystems     = 'TF Inheritance Systems',
    instincttraining       = 'TF Instinct Training',
    intelligenceunshackled = 'TF Intelligence Unshackled',
    lazaxgatefolding       = 'TF Lazax Gate Folding',
    limitbreak             = 'TF Limit Break',
    magmusreactor          = 'TF Magmus Reactor',
    mirrorcomputing        = 'TF Mirror Computing',
    neuralparasite         = 'TF Neural Parasite',
    noneuclideanshielding  = 'TF Non-Euclidean Shielding',
    nullificationfield     = 'TF Nullification Field',
    openingtheeye          = 'TF Opening The Eye',
    orbitaldrop            = 'TF Orbital Drop',
    peaceaccords           = 'TF Peace Accords',
    poisonofthenefishh     = 'TF Poison of the Nefishh',
    productionbiomes       = 'TF Production Biomes',
    proximatargetingvi     = 'TF Proxima Targeting VI',
    puppetcouncil          = 'TF Puppet Council',
    quantumdatahubnode     = 'TF Quantum Datahub Node',
    quantumdrive           = 'TF Quantum Drive',
    quantumentanglement    = 'TF Quantum Entanglement',
    radicaladvancement     = 'TF Radical Advancement',
    raidformation          = 'TF Raid Formation',
    sanctionofthequieron   = 'TF Sanction of the Quieron',
    singularityxa          = 'TF Singularity Xa',
    singularityy           = 'TF Singularity Y',
    singularityz           = 'TF Singularity Z',
    sinsofthefather        = 'TF Sins of the Father',
    smotheringpresence     = 'TF Smothering Presence',
    spatialconduitcylinder = 'TF Spatial Conduit Cylinder',
    specopstraining        = 'TF Spec Ops Training',
    stalltactics           = 'TF Stall Tactics',
    stellargenesis         = 'TF Stellar Genesis',
    subatomicsplicer       = 'TF Subatomic Splicer',
    survivalinstinct       = 'TF Survival Instinct',
    tacticalbrilliance     = 'TF Tactical Brilliance',
    temporalcommandsuite   = 'TF Temporal Command Suite',
    theburningeye          = 'TF The Burning Eye',
    thedragonfreed         = 'TF The Dragon Freed',
    thelawsunwritten       = 'TF The Laws Unwritten',
    thelayoflisis          = 'TF The Lay of Lisis',
    thewindsofchange       = 'TF The Winds of Change',
    timewarp               = 'TF Time Warp',
    voidtransference       = 'TF Void Transference',
    voiceofthecouncil      = 'TF Voice of the Council',
    witchinghour           = 'TF Witching Hour',
    yinascendant           = 'TF Yin Ascendant',
    -- unit upgrade cards (also keyed by async unitsOwned IDs when spelling differs)
    advancedcarrier        = 'TF Advanced Carrier',
    dawncrusher            = 'TF Dawncrusher',
    eidolonlandwaster      = 'TF Eidolon Landwaster',
    eidolonterminus        = 'TF Eidolon Terminus',
    heliosentity           = 'TF Helios Entity',
    heltitan               = 'TF Hel-Titan',
    hybridcrystalfighter   = 'TF Hybrid Crystal Fighter',
    justicierrail          = 'TF Justicier Rail',   -- fully spelled
    justicerrail           = 'TF Justicier Rail',   -- async spelling (no middle "i")
    keepermatrix           = 'TF Keeper Matrix',
    letaniwarrior          = 'TF Letani Warrior',   -- TTS correct spelling
    lataniwarrior          = 'TF Letani Warrior',   -- async misspelling
    prototypewarsun        = 'TF Prototype War Sun',
    saggitaria             = 'TF Saggitaria',
    sledfactories          = 'TF Sled Factories',
    strikewingtaplha       = 'TF Strike Wing Alpha',
    strikewinglalpha       = 'TF Strike Wing Alpha',
    superdreadnought       = 'TF Super-Dreadnought',
    triune                 = 'TF Triune',
    universitywarsun       = 'TF University War Sun',
    valefarprime           = 'TF Valefar Prime',
    valkyriavanguard       = 'TF Valkyrie Vanguard',
    yinclone               = 'TF Yin Clone',
}

local function prettyId(id)
    id = tostring(id)
    local clean = id:gsub('^tf%-', '')
    if TF_CARD[clean] then return TF_CARD[clean] end
    -- tf- prefixed, not in table: simple "TF " + title-case (works for single-word cards)
    if id:match('^tf%-') then
        local spaced = clean:gsub('%-', ' ')
        return 'TF ' .. (spaced:gsub('(%a)(%w*)', function(a, b) return a:upper() .. b end))
    end
    -- bare ID: title-case; findCardSource also tries "TF <name>" as fallback
    local spaced = clean:gsub('%-', ' ')
    return (spaced:gsub('(%a)(%w*)', function(a, b) return a:upper() .. b end))
end

-- the card names to pull for a player: abilities + unit upgrades + leaders
local function playerCardNames(p)
    local names = {}
    -- TF ability / tech cards (from the Abilities deck and related)
    for _, t in ipairs(p.techs or {}) do names[#names + 1] = prettyId(t) end
    -- TF unit upgrade cards (from the Unit Upgrades deck).
    -- unitsOwned entries: standard units (carrier, fighter...) → skip;
    -- tf_warsun (underscore, not a named card) → skip;
    -- color-prefixed mechs/flagships (redtf_mech, greentf_flagship) → skip;
    -- tf-* (hyphen, TF named unit upgrades) → deal these.
    for _, uid in ipairs(p.unitsOwned or {}) do
        if uid:match('^tf%-') then
            names[#names + 1] = prettyId(uid)
        end
    end
    -- agent / leader cards
    -- For TF factions: async tracks the "faction genome" using the base faction's
    -- agent ID (e.g. naaluagent-te → Limit Genome). Look up TF_AGENT_GENOME first;
    -- proper genome IDs (e.g. valiantagent) already resolve correctly via LEADER_NAMES.
    for _, lid in ipairs(p.leaderIDs or {}) do
        local genomeName = TF_AGENT_GENOME[lid]
        if genomeName then
            names[#names + 1] = genomeName
        else
            names[#names + 1] = LEADER_NAMES[lid] or prettyId(lid)
        end
    end
    return names
end

-- find a card by display name inside any deck/bag (or loose) on the table.
-- Infinite bags (token/commodity supply) do NOT support getObjects() -- skip them.
-- Also tries "TF <name>" so bare IDs like "wavelength" find "TF Wavelength".
local function findCardSource(name)
    local nameLower = name:lower()
    local tfNameLower = ('tf ' .. name):lower()
    for _, obj in ipairs(getAllObjects()) do
        local t = obj.type or obj.tag
        if t == 'Deck' or t == 'Bag' then
            local ok, contents = pcall(function() return obj.getObjects() end)
            if ok and type(contents) == 'table' then
                for _, e in ipairs(contents) do
                    local n = (e.nickname ~= '' and e.nickname or e.name) or ''
                    local nLower = n:lower()
                    if nLower == nameLower or nLower == tfNameLower then
                        return { container = obj, guid = e.guid }
                    end
                end
            end
        elseif t == 'Card' then
            local n = obj.getName() or ''
            local nLower = n:lower()
            if nLower == nameLower or nLower == tfNameLower then
                return { loose = obj }
            end
        end
    end
    return nil
end

function onPlacePlayerInfo()
    if _busy then return end
    _busy = true
    fetchData(function(result)
        local ok, err = pcall(function() placePlayerCards(result) end)
        if not ok then broadcastToAll('AsyncTI4 loader error: ' .. tostring(err), {1,0.3,0.3}) end
        _busy = false
    end)
end

function placePlayerCards(result, colorToZoneIn)
    if result.is_error then error('web request failed: ' .. tostring(result.error)) end
    local data = JSON.decode(result.text)
    if type(data) ~= 'table' or type(data.playerData) ~= 'table' then
        error('no playerData in response')
    end

    -- Use Phase 1 zone positions when provided so that command sheets moved by
    -- TF mod scripts during setup do not corrupt card placement positions.
    local colorToZone = colorToZoneIn or buildColorToZone(data)

    local placedTotal, nozone, missing = 0, {}, {}
    for _, p in ipairs(data.playerData) do
        if p.faction and p.faction ~= 'neutral' then
            local tf = string.match(p.faction, '^(%a+)tf$')
            local center = tf and colorToZone[tf:lower()]
            if not center then
                local color = resolveColor(p.faction, p.color)
                if color then nozone[color .. ' (faction=' .. p.faction .. ')'] = true end
            else
                local exhausted = {}
                for _, e in ipairs(p.exhaustedTechs or {}) do exhausted[prettyId(e)] = true end
                for _, leader in ipairs(p.leaders or {}) do
                    if leader.exhausted then
                        local nm = TF_AGENT_GENOME[leader.id]
                                or LEADER_NAMES[leader.id]
                                or prettyId(leader.id)
                        if nm then exhausted[nm] = true end
                    end
                end
                local i = 0
                for _, name in ipairs(playerCardNames(p)) do
                    local src = findCardSource(name)
                    if not src then
                        missing[name] = true
                    else
                        local col, row = i % 4, math.floor(i / 4)
                        -- Cards go to one tangential side of the faction sheet so they don't
                        -- overlap it. Sheet sits at -4 radial; cards at +5 tangential, -4 radial.
                        local len = math.sqrt(center.x*center.x + center.z*center.z)
                        if len < 1 then len = 1 end
                        local rx, rz = center.x/len, center.z/len   -- radial (outward)
                        local tx, tz = -rz, rx                       -- tangential
                        local pos = {
                            x = center.x + tx*(5 + col*1.6) - rx*(4 + row*2.2),
                            y = (center.y or 1) + 1 + row * 0.1,
                            z = center.z + tz*(5 + col*1.6) - rz*(4 + row*2.2),
                        }
                        local rot = { x = 0, y = 0, z = exhausted[name] and 180 or 0 }
                        if src.container then
                            -- Guard: nil guid causes an uncatchable C# ArgumentNullException.
                            if src.guid then
                                src.container.takeObject({ guid = src.guid, position = pos, rotation = rot, smooth = true })
                            else
                                src.container.takeObject({ position = pos, rotation = rot, smooth = true })
                            end
                        elseif src.loose then
                            src.loose.setPositionSmooth(pos)
                            src.loose.setRotationSmooth(rot)
                        end
                        placedTotal = placedTotal + 1
                        i = i + 1
                    end
                end
            end
        end
    end
    broadcastToAll(string.format('AsyncTI4 loader: placed %d player card(s).', placedTotal), {0.6,0.9,1})
    reportSet('No zone found for colour', nozone)
    reportSet('Cards not found (run TF setup first, or name mismatch below)', missing)
    if next(missing) then
        -- Targeted scan: print name+nickname of every card in the "Abilities" deck
        -- so we know exactly what TTS has stored vs what we searched for.
        for _, obj in ipairs(getAllObjects()) do
            local t = obj.type or obj.tag
            if (t == 'Deck' or t == 'Bag') and obj.getName() == 'Abilities' then
                local ok, contents = pcall(function() return obj.getObjects() end)
                if ok and type(contents) == 'table' then
                    local lines = {}
                    for _, e in ipairs(contents) do
                        local nn = (e.nickname or '')
                        local nm = (e.name or '')
                        lines[#lines + 1] = '"' .. nn .. '" / "' .. nm .. '"'
                    end
                    print('[AsyncTI4] Abilities deck contents (nickname/name): ' .. table.concat(lines, ', '))
                else
                    print('[AsyncTI4] Abilities deck: getObjects() failed (wrong type?)')
                end
                break
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Faction sheets: move old/unused sheets to a junk pile, deal active TF
-- faction sheets into the correct player zone.
-- Sheets may be inside faction boxes (TTS Bag objects) rather than loose.
-- Zone resolution uses buildColorToZone so mismatched TTS seat colors are
-- auto-detected and paired with the correct async player.
-- ---------------------------------------------------------------------------

-- Canonical TF mapping: *tf color slot → Mahact King faction sheet name.
local TF_COLOR_TO_KING_SHEET = {
    red    = 'The Ruby Monarch Sheet',
    purple = 'Il Na Viroset Sheet',
    yellow = 'Avarice Rex Sheet',
    green  = 'Il Sai Lakoe, Herald of Thorns Sheet',
    blue   = 'The Saint of Swords Sheet',
    orange = 'Radiant Aur Sheet',
    pink   = 'El Nen Janovet Sheet',
    black  = 'A Sickening Lurch Sheet',
}

-- Corresponding faction box names (the Bag each sheet lives in).
local TF_COLOR_TO_KING_BOX = {
    red    = 'The Ruby Monarch Box',
    purple = 'Il Na Viroset Box',
    yellow = 'Avarice Rex Box',
    green  = 'Il Sai Lakoe, Herald of Thorns Box',
    blue   = 'Saint of Swords Box',
    orange = 'Radiant Aur Box',
    pink   = 'El Nen Janovet Box',
    black  = 'A Sickening Lurch Box',
}

-- Command token bags inside each faction box.
-- "Saint of Swords" has no "The" unlike the sheet (matches the box pattern).
local TF_COLOR_TO_CC_BAG = {
    red    = 'The Ruby Monarch Command Tokens Bag',
    purple = 'Il Na Viroset Command Tokens Bag',
    yellow = 'Avarice Rex Command Tokens Bag',
    green  = 'Il Sai Lakoe, Herald of Thorns Command Tokens Bag',
    blue   = 'Saint of Swords Command Tokens Bag',
    orange = 'Radiant Aur Command Tokens Bag',
    pink   = 'El Nen Janovet Command Tokens Bag',
    black  = 'A Sickening Lurch Command Tokens Bag',
}

local function isFactionSheet(name)
    -- "The * Sheet", "Avarice Rex Sheet", etc.
    -- but NOT "Command Sheet (Red)", "Leader Sheet", "Sliding Reference Sheet"
    return name:match(' Sheet$') ~= nil
        and not name:match('^Command Sheet')
        and not name:match('^Leader Sheet')
        and not name:match('^Sliding Reference')
end

-- Scan all TTS objects and return:
--   looseName[sheetName]     = obj          (loose card/object)
--   boxedName[sheetName]     = {box=obj, guid=guid}  (inside a Bag)
--   boxByName[boxDisplayName] = obj
local function catalogSheets()
    local loose, boxed, boxes = {}, {}, {}
    for _, obj in ipairs(getAllObjects()) do
        local t   = obj.type or obj.tag or ''
        local nm  = obj.getName() or ''
        if t == 'Bag' or t == 'Infinite' then
            boxes[nm] = obj
            -- Infinite bags throw a C# exception from getObjects() that pcall cannot
            -- intercept.  Faction sheets are never stored in infinite bags anyway.
            if t ~= 'Infinite' then
                local ok, contents = pcall(function() return obj.getObjects() end)
                if ok and type(contents) == 'table' then
                    for _, e in ipairs(contents) do
                        local en = (e.nickname ~= '' and e.nickname) or e.name or ''
                        if isFactionSheet(en) then
                            boxed[en] = { box = obj, guid = e.guid }
                        end
                    end
                end
            end
        elseif isFactionSheet(nm) then
            loose[nm] = obj
        end
    end
    return loose, boxed, boxes
end

local JUNK_POSITION = { x = -70, y = 3, z = 0 }

function onMoveFactionSheets()
    if _busy then return end
    _busy = true
    fetchData(function(result)
        local ok, err = pcall(function()
            if result.is_error then error('web request failed: ' .. tostring(result.error)) end
            local data = JSON.decode(result.text)

            local colorToZone = buildColorToZone(data)

            -- Build active set: sheetName → zone center
            local sheetToZone = {}
            for _, p in ipairs(data.playerData or {}) do
                if p.faction and p.faction ~= 'neutral' then
                    local tf = string.match(p.faction, '^(%a+)tf$')
                    if tf then
                        local sheet = TF_COLOR_TO_KING_SHEET[tf:lower()]
                        local center = colorToZone[tf:lower()]
                        if sheet and center then
                            sheetToZone[sheet] = center
                        end
                    end
                end
            end

            local loose, boxed = catalogSheets()
            local dealtIn, moved, unknown = 0, 0, {}

            -- Place each active faction sheet into the owning player's zone.
            -- Prefer a loose sheet; fall back to taking it from a faction box.
            for sheetName, center in pairs(sheetToZone) do
                local pos = { x = center.x, y = (center.y or 1) + 0.5, z = center.z - 4 }
                if loose[sheetName] then
                    loose[sheetName].setPositionSmooth(pos, false, false)
                    dealtIn = dealtIn + 1
                elseif boxed[sheetName] then
                    local entry = boxed[sheetName]
                    local takenOk, takenErr = pcall(function()
                        entry.box.takeObject({ guid = entry.guid, position = pos, smooth = true })
                    end)
                    if takenOk then
                        dealtIn = dealtIn + 1
                    else
                        unknown[sheetName .. ' (takeObject failed: ' .. tostring(takenErr) .. ')'] = true
                    end
                else
                    unknown[sheetName .. ' (not found on table or in box)'] = true
                end
            end

            -- Move any other faction sheet (not active in this game) to junk.
            local function junkit(nm, obj)
                local jx = JUNK_POSITION.x + moved * 3
                if obj then
                    obj.setPositionSmooth({ x = jx, y = JUNK_POSITION.y, z = JUNK_POSITION.z }, false, false)
                else
                    print('[AsyncTI4] Cannot junk "' .. nm .. '" — object ref missing')
                end
                moved = moved + 1
            end

            for nm, obj in pairs(loose) do
                if not sheetToZone[nm] then junkit(nm, obj) end
            end
            for nm, entry in pairs(boxed) do
                if not sheetToZone[nm] then
                    -- take out of box then send to junk
                    local jx = JUNK_POSITION.x + moved * 3
                    local jpos = { x = jx, y = JUNK_POSITION.y, z = JUNK_POSITION.z }
                    pcall(function()
                        entry.box.takeObject({ guid = entry.guid, position = jpos, smooth = true })
                    end)
                    moved = moved + 1
                end
            end

            broadcastToAll(string.format(
                'AsyncTI4 loader: placed %d faction sheet(s) into zones, moved %d to junk.',
                dealtIn, moved), { 0.9, 0.8, 0.5 })
            reportSet('Could not place faction sheet', unknown)
        end)
        if not ok then broadcastToAll('AsyncTI4 loader error: ' .. tostring(err), { 1, 0.3, 0.3 }) end
        _busy = false
    end)
end

-- ---------------------------------------------------------------------------
-- Full TF game setup:
--   1. Extract active TF faction boxes from the "Factions" bag
--   2. Remove standard Command/Leader/faction sheets from player zones
--   3. Place the TF faction sheet in each player zone
--   4. Deal owned planet cards (flip exhausted ones)
-- ---------------------------------------------------------------------------

-- async planet ID "mollprimus" → normalized key "mollprimus"
-- TTS card name "Moll Primus"  → normalized key "mollprimus"
local function normalizePlanetKey(s)
    return (s or ''):lower():gsub("[%s%-_']", '')
end

-- Pull the CC token bag for each active player out of their faction box so we can
-- take individual tokens from it in the next phase.
local function extractCCBags(data, colorToZone)
    colorToZone = colorToZone or {}
    for _, p in ipairs(data.playerData or {}) do
        if p.faction and p.faction ~= 'neutral' then
            local tf = string.match(p.faction, '^(%a+)tf$')
            if tf then
                local ccBagName = TF_COLOR_TO_CC_BAG[tf:lower()]
                if ccBagName and not findObjByName(ccBagName) then
                    local boxName = TF_COLOR_TO_KING_BOX[tf:lower()]
                    local box = boxName and findObjByName(boxName)
                    if box then
                        local ok, contents = pcall(function() return box.getObjects() end)
                        if ok and contents then
                            for _, e in ipairs(contents) do
                                local nm = (e.nickname ~= '' and e.nickname) or e.name or ''
                                if nm == ccBagName then
                                    local center = colorToZone[tf:lower()] or {x=0,y=0,z=0}
                                    pcall(function()
                                        box.takeObject({ guid = e.guid,
                                            position = {x=center.x, y=(center.y or 0)+4, z=center.z},
                                            smooth=false })
                                    end)
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Take tactic/fleet/strategy/reinf tokens from each player's CC bag and place
-- them as four labelled piles near their zone center.
local function placeCCTokens(data, colorToZone, tfToTTS)
    local function pile(bag, n, pos)
        if n <= 0 then return end
        for i = 1, n do
            pcall(function()
                bag.takeObject({ position = { x=pos.x, y=pos.y + (i-1)*0.15, z=pos.z }, smooth=false })
            end)
        end
    end

    for _, p in ipairs(data.playerData or {}) do
        if p.faction and p.faction ~= 'neutral' then
            local tf = string.match(p.faction, '^(%a+)tf$')
            if tf then
                local ccBagName = TF_COLOR_TO_CC_BAG[tf:lower()]
                local ccBag = ccBagName and findObjByName(ccBagName)
                local zc = colorToZone[tf:lower()]
                if ccBag and zc then
                    -- Use radial/tangential directions so tokens land correctly regardless of
                    -- which side of the board the player sits on. Tokens go outward (away from
                    -- the map) in a tangential row, slightly above the faction sheet.
                    local len = math.sqrt(zc.x*zc.x + zc.z*zc.z)
                    if len < 1 then len = 1 end
                    local rx, rz = zc.x/len, zc.z/len  -- unit vector pointing outward from board center
                    local tx, tz = -rz, rx              -- tangential (perpendicular, counter-clockwise)
                    local by = (zc.y or 0) + 1.5
                    local tactic   = tonumber(p.tacticalCC)  or 0
                    local fleet    = tonumber(p.fleetCC)     or 0
                    local strategy = tonumber(p.strategicCC) or 0
                    local reinf    = tonumber(p.ccReinf)     or 0
                    -- Three piles in a tangential row, 5 units radially outward from zone center
                    pile(ccBag, tactic,   { x=zc.x - tx*3 + rx*5, y=by, z=zc.z - tz*3 + rz*5 })
                    pile(ccBag, fleet,    { x=zc.x         + rx*5, y=by, z=zc.z         + rz*5 })
                    pile(ccBag, strategy, { x=zc.x + tx*3 + rx*5, y=by, z=zc.z + tz*3 + rz*5 })
                    -- reinf tokens stay in the bag
                    print(string.format('[AsyncTI4] %stf CCs: T=%d F=%d S=%d (+%d reinf in bag)', tf, tactic, fleet, strategy, reinf))
                end
            end
        end
    end
end

-- Clear scripts on objects that block cross-script operations (coroutine lock + globals lock).
-- The Factions bag and TI4_SETUP_HELPER both use startLuaCoroutine which prevents
-- external takeObject calls. Clearing their scripts immediately releases those locks.
-- onLoad clears the object's own UI panel so "Choose a Faction to Unpack" popups disappear.
local CLEARED_SCRIPT = ''
local function clearBlockingScripts()
    local cleared = {}
    for _, name in ipairs({ 'TI4_SETUP_HELPER', 'TI4_FACTION_HELPER', 'Factions' }) do
        local obj = findObjByName(name)
        if obj then
            local ok = pcall(function() obj.setScript(CLEARED_SCRIPT) end)
            -- Also immediately clear the object's UI panel in case setScript's
            -- onLoad fires asynchronously or not at all in this TTS version.
            pcall(function() obj.UI.setXml('') end)
            if ok then cleared[#cleared + 1] = name end
        end
    end
    if #cleared > 0 then
        print('[AsyncTI4] Cleared blocking scripts: ' .. table.concat(cleared, ', '))
    end
end

-- Extract active TF faction boxes from the now-unlocked Factions bag.
local function extractFactionBoxes(data)
    local fb = findObjByName('Factions')
    if not fb then print('[AsyncTI4] "Factions" bag not found'); return false end
    local ok, contents = pcall(function() return fb.getObjects() end)
    if not ok or type(contents) ~= 'table' then return false end
    local bagByName = {}
    for _, e in ipairs(contents) do
        local nm = (e.nickname ~= '' and e.nickname) or e.name or ''
        bagByName[nm] = e.guid
    end
    local extracted, idx = false, 0
    for _, p in ipairs(data.playerData or {}) do
        if p.faction and p.faction ~= 'neutral' then
            local tf = string.match(p.faction, '^(%a+)tf$')
            if tf then
                local boxName = TF_COLOR_TO_KING_BOX[tf:lower()]
                if boxName and bagByName[boxName] and not findObjByName(boxName) then
                    local pos = { x = -24 + idx * 11, y = 2, z = 78 }
                    local ok2 = pcall(function()
                        fb.takeObject({ guid = bagByName[boxName], position = pos, smooth = false })
                    end)
                    if ok2 then extracted = true; idx = idx + 1
                    else print('[AsyncTI4] takeObject failed for ' .. boxName) end
                end
            end
        end
    end
    return extracted
end

-- Change TTS player seat colors so they match TF async colors.
-- Uses tfToTTS (from buildColorToZone) to detect which seats were auto-paired.
local function fixPlayerColors(tfToTTS)
    for tf, actual in pairs(tfToTTS) do
        local expected = ASYNC_TO_TTS_COLOR[tf:lower()] or (tf:sub(1,1):upper()..tf:sub(2))
        if expected ~= actual then
            local ok = pcall(function() Player[actual].changeColor(expected) end)
            print(string.format('[AsyncTI4] Color seat: %s → %s %s', actual, expected, ok and 'OK' or 'FAILED'))
        end
    end
end

-- Build lookup: normalizedPlanetName → {deck=obj, guid=string}
-- Scans ALL deck/bag objects so TF-specific planet decks are included.
local function buildPlanetLookup()
    local lookup = {}
    local totalScanned = 0
    for _, obj in ipairs(getAllObjects()) do
        local t = obj.type or obj.tag
        if t == 'Deck' or (t == 'Bag' and obj.getName() ~= 'Factions') then
            local ok, contents = pcall(function() return obj.getObjects() end)
            if ok and type(contents) == 'table' then
                totalScanned = totalScanned + #contents
                for _, e in ipairs(contents) do
                    local nm = (e.nickname ~= '' and e.nickname) or e.name or ''
                    local key = normalizePlanetKey(nm)
                    if key ~= '' and not lookup[key] then
                        lookup[key] = { deck = obj, guid = e.guid }
                    end
                end
            end
        end
    end
    local nKeys = 0; for _ in pairs(lookup) do nKeys = nKeys + 1 end
    diagLog('planet lookup: scanned ' .. totalScanned .. ' cards, ' .. nKeys .. ' unique planet keys')
    return lookup
end

-- Inner setup: colorToZone and tfToTTS are pre-computed before any script clearing.
local function setupTFInner(data, colorToZone, tfToTTS)
    colorToZone = colorToZone or {}
    tfToTTS     = tfToTTS     or {}

    -- ---- Step 1: remove standard TI4 sheets from all active TTS zones ----
    -- Collect the actual TTS colors in use so we can match "Command Sheet (X)"
    local activeTTSColors = {}
    for _, c in pairs(tfToTTS) do activeTTSColors[c] = true end

    local junkX = JUNK_POSITION.x
    local junkZ = JUNK_POSITION.z + 10  -- offset so it doesn't pile on top of unit junk
    local junkCount = 0
    local function sendToJunk(obj)
        -- Unlock first; TTS silently ignores setPosition on locked objects.
        pcall(function() obj.setLock(false) end)
        obj.setPositionSmooth({ x = junkX + junkCount * 3, y = JUNK_POSITION.y, z = junkZ }, false, false)
        junkCount = junkCount + 1
    end

    for _, obj in ipairs(getAllObjects()) do
        local nm = obj.getName() or ''
        -- Remove "Leader Sheet (Color)" for each active seat.
        -- Command Sheets are kept in play — they're generic quick-reference cards.
        for c in pairs(activeTTSColors) do
            if nm == 'Leader Sheet (' .. c .. ')' then
                sendToJunk(obj)
                break
            end
        end
        -- Remove any base TI4 faction sheets (not TF king sheets)
        if isFactionSheet(nm) then
            local isTFKing = false
            for _, sn in pairs(TF_COLOR_TO_KING_SHEET) do
                if nm == sn then isTFKing = true; break end
            end
            if not isTFKing then sendToJunk(obj) end
        end
        -- Move the "Choose a Faction to Unpack" selector popup off the table
        -- and clear its attached UI panel (moving alone does not hide the XML UI).
        if nm == 'Faction Selector' then
            sendToJunk(obj)
            pcall(function() obj.UI.setXml('') end)
        end
    end

    -- ---- Step 2: place TF faction sheets ----
    -- Re-catalog after removal (objects may have moved)
    local loose, boxed = catalogSheets()
    local sheetsDone = 0
    local sheetsMissing = {}

    for _, p in ipairs(data.playerData or {}) do
        if p.faction and p.faction ~= 'neutral' then
            local tf = string.match(p.faction, '^(%a+)tf$')
            if tf then
                local sheetName = TF_COLOR_TO_KING_SHEET[tf:lower()]
                local center    = colorToZone[tf:lower()]
                if sheetName and center then
                    local pos = { x = center.x, y = (center.y or 1) + 0.5, z = center.z - 4 }
                    if loose[sheetName] then
                        loose[sheetName].setPositionSmooth(pos, false, false)
                        sheetsDone = sheetsDone + 1
                    elseif boxed[sheetName] then
                        local e = boxed[sheetName]
                        pcall(function() e.box.takeObject({ guid = e.guid, position = pos, smooth = true }) end)
                        sheetsDone = sheetsDone + 1
                    else
                        -- Try the faction box sitting on the table (just extracted)
                        local boxObj = findObjByName(TF_COLOR_TO_KING_BOX[tf:lower()] or '')
                        if boxObj then
                            local ok2, c2 = pcall(function() return boxObj.getObjects() end)
                            if ok2 and c2 then
                                for _, e2 in ipairs(c2) do
                                    local en = (e2.nickname ~= '' and e2.nickname) or e2.name or ''
                                    if en == sheetName then
                                        boxObj.takeObject({ guid = e2.guid, position = pos, smooth = true })
                                        sheetsDone = sheetsDone + 1
                                        break
                                    end
                                end
                            end
                        else
                            sheetsMissing[sheetName] = true
                        end
                    end
                end
            end
        end
    end

    -- ---- Step 3: deal planet cards ----
    local planetLookup = buildPlanetLookup()
    local planetsDealt = 0
    local planetsMissing = {}

    for _, p in ipairs(data.playerData or {}) do
        if p.faction and p.faction ~= 'neutral' then
            local tf = string.match(p.faction, '^(%a+)tf$')
            if tf then
                local center = colorToZone[tf:lower()]
                if center and p.planets and #p.planets > 0 then
                    local exhaustedSet = {}
                    for _, pid in ipairs(p.exhaustedPlanets or {}) do exhaustedSet[pid] = true end

                    local i = 0
                    for _, pid in ipairs(p.planets) do
                        local key   = normalizePlanetKey(pid)
                        local entry = planetLookup[key]
                        if entry then
                            local col = i % 6
                            local row = math.floor(i / 6)
                            local pos = {
                                x = center.x + (col - 2.5) * 2.3,
                                y = (center.y or 1) + 1,
                                z = center.z + 9 + row * 3.2,
                            }
                            local rot = { x = 0, y = 0, z = exhaustedSet[pid] and 90 or 0 }
                            local tok, _ = pcall(function()
                                entry.deck.takeObject({ guid = entry.guid, position = pos, rotation = rot, smooth = true })
                            end)
                            if tok then
                                planetLookup[key] = nil  -- prevent double-take
                                planetsDealt = planetsDealt + 1
                                i = i + 1
                            else
                                planetsMissing[pid] = true
                            end
                        else
                            planetsMissing[pid] = true
                        end
                    end
                end
            end
        end
    end

    broadcastToAll(string.format(
        '[AsyncTI4] TF setup: %d sheet(s) placed, %d planet card(s) dealt.',
        sheetsDone, planetsDealt), { 0.4, 1, 0.6 })
    reportSet('Faction sheets not found', sheetsMissing)
    reportSet('Planets not found in deck', planetsMissing)
    -- Log missing planet IDs to diag so we can see name mismatches
    for pid in pairs(planetsMissing) do
        diagLog('planet missing: "' .. pid .. '" (key=' .. normalizePlanetKey(pid) .. ')')
    end
end

function onSetupTFGame()
    if _busy then return end
    _busy = true
    resetDiag()
    local lg = diagLog
    local flushLog = flushDiag

    fetchData(function(result)
        -- Capture text NOW as plain Lua strings. TTS frees the WebRequest C# object
        -- once this callback returns; our Wait.frames closures run 125+ frames later.
        -- Accessing the disposed C# object throws an uncatchable null-ref that silently
        -- kills handleWebData and placePlayerCards.
        local _rawText   = (not result.is_error) and result.text or nil
        local _isErr     = result.is_error
        local _errMsg    = result.error
        local safeResult = { is_error = _isErr, error = _errMsg, text = _rawText or '' }

        local ok, err = pcall(function()
            if _isErr then error('web request failed: ' .. tostring(_errMsg)) end
            local data = JSON.decode(_rawText)

            -- Phase 1: capture zone data from command sheets on the table.
            lg('-- Phase 1: discoverZones --')
            for _, obj in ipairs(getAllObjects()) do
                local nm = obj.getName() or ''
                if nm:match('^Command Sheet') or nm:match('^Leader Sheet') or nm == 'Faction Selector' then
                    local pos = obj.getPosition()
                    local locked = pcall(function() return obj.getLock() end) and obj.getLock() or '?'
                    lg(string.format('  OBJ "%s" pos=(%.1f,%.1f,%.1f) locked=%s', nm, pos.x, pos.y, pos.z, tostring(locked)))
                end
            end

            local colorToZone, zones, tfToTTS = buildColorToZone(data)

            lg('-- colorToZone --')
            for tf, ctr in pairs(colorToZone) do
                lg(string.format('  %s -> (%.1f,%.1f,%.1f)', tf, ctr.x, ctr.y, ctr.z))
            end
            lg('-- tfToTTS --')
            for tf, tts in pairs(tfToTTS) do lg(string.format('  %s -> %s', tf, tts)) end

            -- Clear home slot placeholders so real tiles survive map build
            local nSlots = clearHomeSlots()
            if nSlots > 0 then
                broadcastToAll(string.format('[AsyncTI4] Cleared %d home slot(s).', nSlots), {0.9,0.7,0.3})
            end

            -- Apply (or broadcast) the map string before touching mod objects
            buildMap(data)

            broadcastToAll('[AsyncTI4] Unlocking mod objects...', { 0.8, 0.8, 0.8 })
            clearBlockingScripts()

            Wait.frames(function()
                local _ok, _err = pcall(function() extractFactionBoxes(data) end)
                if not _ok then print('[AsyncTI4] extractFactionBoxes: ' .. tostring(_err)) end
                broadcastToAll('[AsyncTI4] Faction boxes extracted. Running setup...', { 0.8, 0.8, 0.8 })
                flushLog()

                Wait.frames(function()
                    lg('-- Phase 4: setupTFInner --')
                    for _, obj in ipairs(getAllObjects()) do
                        local nm = obj.getName() or ''
                        if nm == 'Faction Selector' or nm:match('^Leader Sheet') or nm:match('^Command Sheet') then
                            local pos = obj.getPosition()
                            local lk = '?'
                            pcall(function() lk = tostring(obj.getLock()) end)
                            lg(string.format('  PRE-JUNK "%s" pos=(%.1f,%.1f,%.1f) locked=%s', nm, pos.x, pos.y, pos.z, lk))
                        end
                    end

                    local ok2, err2 = pcall(function() setupTFInner(data, colorToZone, tfToTTS) end)
                    if not ok2 then broadcastToAll('[AsyncTI4] Setup error: ' .. tostring(err2), { 1, 0.3, 0.3 }) end

                    lg('-- Phase 4: post-junk positions --')
                    for _, obj in ipairs(getAllObjects()) do
                        local nm = obj.getName() or ''
                        if nm == 'Faction Selector' or nm:match('^Leader Sheet') or nm:match('^Command Sheet') then
                            local pos = obj.getPosition()
                            lg(string.format('  POST-JUNK "%s" pos=(%.1f,%.1f,%.1f)', nm, pos.x, pos.y, pos.z))
                        end
                    end

                    extractCCBags(data, colorToZone)

                    Wait.frames(function()
                        lg('-- Phase 5: CC + units + cards --')
                        flushLog()

                        lg('placeCCTokens start'); flushLog()
                        local ok3, err3 = pcall(function() placeCCTokens(data, colorToZone, tfToTTS) end)
                        lg('placeCCTokens done ok=' .. tostring(ok3))
                        if not ok3 then lg('CC token error: ' .. tostring(err3)); broadcastToAll('[AsyncTI4] CC token error: ' .. tostring(err3), { 1, 0.3, 0.3 }) end
                        flushLog()

                        lg('handleWebData start'); flushLog()
                        local ok4, err4 = pcall(function() handleWebData(safeResult, tfToTTS) end)
                        lg('handleWebData done ok=' .. tostring(ok4))
                        if not ok4 then lg('Unit placement error: ' .. tostring(err4)); broadcastToAll('[AsyncTI4] Unit placement error: ' .. tostring(err4), { 1, 0.3, 0.3 }) end
                        flushLog()

                        lg('-- Phase 6: cards --')
                        for tf, ctr in pairs(colorToZone) do
                            lg(string.format('  zone %s=(%.1f,%.1f,%.1f)', tf, ctr.x, ctr.y, ctr.z))
                        end

                        local ok5, err5 = pcall(function() placePlayerCards(safeResult, colorToZone) end)
                        if not ok5 then lg('Card placement error: ' .. tostring(err5)); broadcastToAll('[AsyncTI4] Card placement error: ' .. tostring(err5), { 1, 0.3, 0.3 }) end

                        flushLog()
                        broadcastToAll('[AsyncTI4] TF game setup complete. Check loader description for diagnostics.', { 0.4, 1, 0.4 })
                        _busy = false
                    end, 45)
                end, 60)
            end, 20)
        end)
        if not ok then
            lg('FATAL: ' .. tostring(err))
            flushLog()
            broadcastToAll('[AsyncTI4] Error: ' .. tostring(err), { 1, 0.3, 0.3 })
            _busy = false
        end
    end)
end

-- Legacy callback kept for compatibility (XML UI uses the onLoad version above)
function onGameNameChanged(a, b, c)
    local value = c or b or a or ''
    _gameName = value:gsub('^%s+', ''):gsub('%s+$', '')
end

function onPlaceUnits()
    if _busy then return end
    _busy = true
    broadcastToAll('AsyncTI4 loader: loading embedded "' .. _gameName .. '"...', { 0.8, 0.8, 0.8 })
    fetchData(function(result)
        local ok, err = pcall(function() handleWebData(result) end)
        if not ok then
            broadcastToAll('AsyncTI4 loader error: ' .. tostring(err), { 1, 0.3, 0.3 })
        end
        _busy = false
    end)
end

function onPrintMapString()
    if _busy then return end
    _busy = true
    fetchData(function(result)
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

-- tfToTTS: optional map of tf-color → actual TTS seat color.
-- Used so seat-mismatched players (e.g. greentf in Black seat) look up
-- "Black Carrier" unit bags instead of "Green Carrier" (which doesn't exist).
function handleWebData(result, tfToTTS)
    if result.is_error then
        error('web request failed: ' .. tostring(result.error))
    end
    local data = JSON.decode(result.text)
    if type(data) ~= 'table' or not data.tilePositions or not data.tileUnitData then
        error('unexpected response (wrong game name, or fog-of-war game?)')
    end

    local posToTileNum = {}
    for _, entry in ipairs(data.tilePositions) do
        local pos, tile = string.match(entry, '^([^:]+):(.+)$')
        if pos and tile then
            local n = tonumber(string.match(tile, '%d+'))
            if n then posToTileNum[pos] = n end
        end
    end

    -- TI4_SYSTEM_HELPER.systems() can throw an uncatchable C# exception if the
    -- helper uses coroutines internally. Wrap with pcall and fall back to a
    -- direct tile scan if it fails.
    local guidToSystem = {}
    local sysOk, sysErr = pcall(function()
        local systemHelper = getHelperClient('TI4_SYSTEM_HELPER')
        guidToSystem = systemHelper.systems()
    end)
    if not sysOk then
        diagLog('TI4_SYSTEM_HELPER.systems() failed: ' .. tostring(sysErr))
    end
    local tileNumToObject = {}
    for _, obj in ipairs(getAllObjects()) do
        local sys = guidToSystem[obj.getGUID()]
        if sys and sys.tile then
            tileNumToObject[sys.tile] = obj
        else
            local ok2, nm = pcall(function() return obj.getGMNotes() or '' end)
            if ok2 and nm ~= '' then
                local n = tonumber(nm:match('^%s*(%d+)%s*$'))
                if n then tileNumToObject[n] = obj end
            end
        end
    end
    local tileCount = 0; for _ in pairs(tileNumToObject) do tileCount = tileCount + 1 end
    diagLog('tileNumToObject: ' .. tileCount .. ' tiles found')

    local factionToColor = {}
    for _, p in ipairs(data.playerData or {}) do
        if p.faction then
            local tf = string.match(p.faction, '^(%a+)tf$')
            local actualColor = tf and tfToTTS and tfToTTS[tf:lower()]
            factionToColor[p.faction] = actualColor or resolveColor(p.faction, p.color)
        end
    end

    -- Unit supply: Custom_Model_Bag objects named "[Color] [Unit]" (e.g. "Blue Carrier").
    -- These are NOT Infinite or plain Bag — they are Custom_Model_Bag type.
    local nameToBag = {}
    for _, obj in ipairs(getAllObjects()) do
        local t = obj.type or obj.tag
        if t == 'Bag' or t == 'Infinite' or t == 'Custom_Model_Bag' then
            nameToBag[obj.getName()] = obj
        end
    end
    local bagCount = 0; for _ in pairs(nameToBag) do bagCount = bagCount + 1 end
    diagLog('nameToBag: ' .. bagCount .. ' bags found')

    local tally = { placed = 0, flagship = 0, neutral = 0, nobag = {}, notile = {}, nocolor = {} }
    local spawnIndex = {}

    local function placeUnits(tileObj, faction, unitList, localOffset, groupKey)
        local color = factionToColor[faction]
        local lox = (localOffset and localOffset.x) or 0
        local loz = (localOffset and localOffset.z) or 0
        local ikey = groupKey or tileObj.getGUID()
        for _, e in ipairs(unitList) do
            local count = tonumber(e.count) or 1
            local id = e.entityId
            if id == 'fs' then
                tally.flagship = tally.flagship + count
            elseif not UNIT_ID_TO_NAME[id] then
                tally.neutral = tally.neutral + count
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
                        local k = (spawnIndex[ikey] or 0)
                        spawnIndex[ikey] = k + 1
                        local phi = k * 0.55
                        local r = 0.35 + (k * 0.12)
                        bag.takeObject({
                            position = tileObj.positionToWorld({
                                x = lox + math.cos(phi) * r, y = 1.5, z = loz + math.sin(phi) * r,
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
            local guid = tileObj.getGUID()
            if type(tdata.space) == 'table' then
                for faction, unitList in pairs(tdata.space) do
                    if type(unitList) == 'table' then
                        placeUnits(tileObj, faction, unitList, nil, guid .. '_s')
                    end
                end
            end
            if type(tdata.planets) == 'table' then
                local planetKeys = {}
                for k in pairs(tdata.planets) do planetKeys[#planetKeys+1] = k end
                table.sort(planetKeys)
                -- Per-planet local offsets so units cluster near each planet rather than piling at center.
                -- Offsets are in tile local-space XZ; spread along X axis by planet index.
                local n = #planetKeys
                local POFF = {}
                if n == 1 then
                    POFF = { {x=0, z=0} }
                elseif n == 2 then
                    POFF = { {x=-0.65, z=0}, {x=0.65, z=0} }
                else
                    POFF = { {x=0, z=-0.65}, {x=-0.6, z=0.4}, {x=0.6, z=0.4} }
                end
                for pi, pk in ipairs(planetKeys) do
                    local pdata = tdata.planets[pk]
                    if type(pdata) == 'table' and type(pdata.entities) == 'table' then
                        local poff = POFF[pi] or {x=0, z=0}
                        for faction, unitList in pairs(pdata.entities) do
                            if type(unitList) == 'table' then
                                placeUnits(tileObj, faction, unitList, poff, guid .. '_p' .. pi)
                            end
                        end
                    end
                end
            end
        end
    end


    -- Activated-system CC tokens: API field is "ccs" (array of faction strings).
    local ccPlaced = 0
    for pos, tdata in pairs(data.tileUnitData) do
        local tileNum2 = posToTileNum[pos]
        local tileObj2 = tileNum2 and tileNumToObject[tileNum2]
        if tileObj2 then
            local ccData = tdata.ccs
            if type(ccData) == 'string' then ccData = {ccData} end
            if type(ccData) == 'table' then
                for _, faction in ipairs(ccData) do
                    local tf2 = faction:match('^(%a+)tf$')
                    local ccBagName2 = tf2 and TF_COLOR_TO_CC_BAG[tf2:lower()]
                    local ccBag2 = ccBagName2 and findObjByName(ccBagName2)
                    if ccBag2 then
                        local tp = tileObj2.getPosition()
                        pcall(function()
                            ccBag2.takeObject({ position = {x=tp.x, y=tp.y+1.5, z=tp.z}, smooth=true })
                        end)
                        ccPlaced = ccPlaced + 1
                    end
                end
            end
        end
    end
    if ccPlaced > 0 then
        broadcastToAll(string.format('[AsyncTI4] Placed %d activated-system CC token(s).', ccPlaced), {0.4, 0.8, 1})
    end

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

function resolveColor(faction, asyncColor)
    local tf = string.match(faction, '^(%a+)tf$')
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
