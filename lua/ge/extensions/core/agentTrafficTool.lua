-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"ui_imgui"}

local im = ui_imgui
local logTag = "agentTrafficTool"
local appTitle = " Agent Traffic Tool v1"

local ui = {
  show = nil,
  quickStartPtr = nil,
  includeLargePtr = nil,
  usePoolingPtr = nil,
  includeParkedPtr = nil,

  selectedGroup = im.IntPtr(0),
  selectedPlates = im.IntPtr(0),
  selectedPlateShape = im.IntPtr(0),
  selectedPlateDesign = im.IntPtr(0),

  varAmount = im.IntPtr(0),
  varPooling = im.IntPtr(0),
  varParked = im.IntPtr(0),
  varAggression = im.FloatPtr(0),
  varRespawnRate = im.FloatPtr(0),
}

local state = {
  -- groups
  groupsTable = {},
  groupString = "",
  currentGroup = nil,
  expansionsTable = {},
  expansionsString = "",

  -- spawn behavior
  alreadySpawned = false,
  lastSpawnTargetAmount = 0,

  -- options
  quickStart = true,
  includeLarge = false,

  usePooling = settings.getValue("trafficExtraVehicles") or false,
  usePoolingNumber = settings.getValue("trafficExtraAmount") or 0,

  includeParked = settings.getValue("trafficParkedVehicles") or false,
  includeParkedNumber = settings.getValue("trafficParkedAmount") or 0,

  -- parking support
  levelSpots = 0,
  maxParked = 128,

  -- traffic
  agentTrafficActive = false,
  vehicleAmount = settings.getValue("trafficAmount") or 0,

  -- expansions: list of extra groups mixed into base spawn
  -- weight is 0..100 (% of total target). Base group gets the remainder.
  expansions = {
    items = {
      -- { groupIndex = 1, weight = 30 }
    }
  },
}

local traffic = {}

local plateFrontOptions = {
  "Front Plates",
  "No Front Plates",
  "Random Front Plates",
}

local plateShapeOptions = {
  "Standard Wide (EU) Plates",
  "Standard Square (US) Plates",
  "Japanese Correct Type Plates",
  "Small Italian 36x11 Front Plates",
  "Mercosur-Mercosul 40x13 Plates",
  "Yellow UK/French Rear Plates",
  "Yellow Cypriot Rear Plates",
}

local function comboString(list, field)
  local out = {}
  for _, item in ipairs(list or {}) do
    out[#out + 1] = field and item[field] or item
  end
  return table.concat(out, "\0") .. "\0"
end

local plates = {
  platesString = comboString(plateFrontOptions),
  plateShapeString = comboString(plateShapeOptions),

  plateDesignString = "Map Plate Design\0",
  licensePlates = {},

  plateReplaceUSF = "_licenseplate_F_US",
  plateReplaceUSR = "_licenseplate_R_US",

  plateShapeSupported = false,
  plateShapeInstalled = false,

  japanPlateDesign = "",
  japanPlateType = "",
}

local rhdRegion = {
  jp = true,
  gb = true,
  uk = true,
  cy = true,
  au = true,
  nz = true,
  mt = true,
  za = true
}

local plateShapeMods = {
  [2] = { repo="MK4GEHS6D", msg='This requires "Agents Japanese Plates\nPack" by AgentMooshroom5 to\nfunction, which is not installed' },
  [3] = { repo="M51RLD32Y", msg='This requires "The Italian Mod"\nby gsbr_697 to function,\nwhich is not installed',
          installedWarn='This will force the "Italy 1999"\nplate design to be used, as it\nis required for this option\nto work' },
  [4] = { repo="MUAKPD25B", msg='This requires "Mercosur/Mercosul\nLicense Plate Pack" by RealVector\nto function, which is not installed',
          installedWarn="Only supported mod plate\ndesigns will work with this\nsetting! Double check before\nspawning traffic" },
  [5] = { repo="MPH2FQWXK", msg='This requires "European License\nPlates Compilation" by JorgePinto\nto function, which is not installed',
          installedWarn="Only supported mod plate\ndesigns will work with this\nsetting! Double check before\nspawning traffic" },
  [6] = { repo="MOUXET72H", msg='This requires "Middle East License\nPlate Pack" by RealVector to\nfunction, which is not installed',
          installedWarn="Only supported mod plate\ndesigns will work with this\nsetting! Double check before\nspawning traffic" },
}

local publicShamingList = {
    { name = "SimpleNG", vramusage = 20 }, --auto fill in a couple of the main traffic mod values for this so there isn't such a sea of empty values in info tab
    { name = "Need for Speed", vramusage = 7 } --that and its nice to show the decent optmisations people are putting in, the nfs one is great for a first mod in this regard
}

-- caches to avoid repeated filesystem scans
local cache = {
  platePackInstalled = {}, -- [shapeIndex]=bool
  platesScanned = false
}

local jobs = {
  platesScan = nil
}

local function publicShaming(group)
  if not group or not group.name then return nil end
  for _, entry in ipairs(publicShamingList) do
    if entry.name and string.find(group.name, entry.name, 1, true) then
      return entry.vramusage
    end
  end
  return nil
end

local function vramText(value)
    if value == nil or value == 0 then
        return "unknown"
    end

    return tostring(value) .. "MB"
end

local function tagsContain(tags, needle)
  for _, t in pairs(tags or {}) do
    if type(t)=="string" and t:find(needle, 1, true) then return true end
  end
  return false
end

local function groupSupportsLarge(g)
  if not g then return false end
  return g.supportsLarge == true or tagsContain(g.tags, "agent_supports_large")
end

local function drawPlateShapeModStatus(shape)
  local meta = plateShapeMods[shape]
  if not meta then return end
  if plates.plateShapeInstalled == false then
    im.TextColored(im.ImVec4(1,0,0,1), meta.msg)
    if im.Button("Download it here\n(Ingame repo)") then
      extensions.core_repository.uiShowMod(meta.repo)
    end
  elseif meta.installedWarn then
    im.TextColored(im.ImVec4(1,1,0,1), meta.installedWarn)
  end
end

-- initial AI vars
ui.varAggression[0] = 0.3
gameplay_traffic.setTrafficVars({baseAggression = ui.varAggression[0]})

ui.varRespawnRate[0] = 1
gameplay_traffic.setTrafficVars({spawnValue = ui.varRespawnRate[0]})

local coreAmount = Engine.Platform.getCPUInfo().coresLogical or 4

if state.vehicleAmount == 0 then state.vehicleAmount = coreAmount - 1 end
if state.usePoolingNumber == 0 then state.usePoolingNumber = coreAmount - 1 end
if state.includeParkedNumber == 0 then state.includeParkedNumber = coreAmount * 2 end

ui.quickStartPtr = im.BoolPtr(state.quickStart)
ui.includeLargePtr = im.BoolPtr(state.includeLarge)
ui.usePoolingPtr = im.BoolPtr(state.usePooling)
ui.includeParkedPtr = im.BoolPtr(state.includeParked)

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function computeTrafficTargetAmount()
  if state.usePooling == true then
    return state.vehicleAmount + state.usePoolingNumber
  end
  return state.vehicleAmount
end

local function fixBadEUName(p)
  if p and p:find("_EU_EU", 1, true) then
    return (p:gsub("_EU_EU", "_EU"))
  end
  return p
end

local function applyDefaultPlateShapeFromTags(tags, region)
  if region then
    if region == "eu" then ui.selectedPlateShape[0] = 0 end
    if region == "us" then ui.selectedPlateShape[0] = 1 end
    if region == "jp" then ui.selectedPlateShape[0] = 2 end
  elseif tags then
    for _, q in pairs(tags) do
      if q:find("agent_region_eu", 1, true) then ui.selectedPlateShape[0] = 0 end
      if q:find("agent_region_us", 1, true) then ui.selectedPlateShape[0] = 1 end
      if q:find("agent_region_jp", 1, true) then ui.selectedPlateShape[0] = 2 end
    end
  end
end

-- this process is very slow with mods and if we do it every vehicle it checks for all common parts repeatedly

local randomPartCache = {}

local function getRandomPart(model, slot, path)
  if not model or not slot then return nil end
  local path = path or '/vehicles/' .. model .. '/'
  if not randomPartCache[slot] then
    randomPartCache[slot] = {}
    local jbeamFiles = FS:findFiles(path, "*.jbeam", -1, true, false) or {}
    for _, filename in ipairs(jbeamFiles) do
      local ok = true
      local jbeamData = jsonReadFile(filename)
      if type(jbeamData) ~= "table" then ok = false end
      if ok then
        for k, v in pairs(jbeamData) do
          if type(v) == "table" and v.slotType == slot then
            table.insert(randomPartCache[slot], k)
          end
        end
      end
    end
  end
  return randomPartCache[slot][math.random(1, #randomPartCache[slot])] or nil
end

local function isPlateShapeInstalled(shape)
  local cached = cache.platePackInstalled[shape]
  if cached ~= nil then return cached end

  local ok
  if shape == 2 then
    ok = FS:directoryExists("vehicles/common/licenseplates/am5jp_shizuoka")
  elseif shape == 3 then
    ok = FS:directoryExists("vehicles/common/licenseplates/front_99")
  elseif shape == 4 then
    ok = FS:directoryExists("vehicles/common/licenseplates/models/mercosur")
  elseif shape == 5 then
    ok = FS:directoryExists("vehicles/common/UK_LicensePlates_JP")
  elseif shape == 6 then
    ok = FS:directoryExists("vehicles/common/licenseplates/models/f-52")
  else
    ok = true
  end

  cache.platePackInstalled[shape] = ok
  return ok
end

local function groupSortKey(name)
  name = tostring(name or "")
  local lower = name:lower()
  local agentFirst = lower:find("^agent", 1, false) and 0 or 1
  return agentFirst, lower
end

local function sortGroups(groups)
  table.sort(groups, function(a, b)
    local ap, an = groupSortKey(a and a.name)
    local bp, bn = groupSortKey(b and b.name)

    if ap ~= bp then return ap < bp end
    if an ~= bn then return an < bn end

    return tostring(a._filename or "") < tostring(b._filename or "")
  end)
end

local function buildGroupComboString(groups)
  return comboString(groups, "name")
end

local function onGroupDataLoad()
  state.groupsTable = {}
  state.expansionsTable = {}
  state.currentGroup = nil

  local groupFiles = FS:findFiles("/vehicleGroups/agentTraffic/", "*.vehGroup.json", 1, true, false)

  for _, filename in ipairs(groupFiles) do
    local g = jsonReadFile(filename) or {}
    g._filename = filename

    if not g.isExpansion then
      state.groupsTable[#state.groupsTable + 1] = g
    end

    state.expansionsTable[#state.expansionsTable + 1] = g
  end

  sortGroups(state.groupsTable)
  sortGroups(state.expansionsTable)

  state.groupString = buildGroupComboString(state.groupsTable)
  state.expansionsString = buildGroupComboString(state.expansionsTable)
end

local function setPopulation(group, isParked, includeLarge)
  if includeLarge == nil then includeLarge = state.includeLarge end
  local vehicleData = {popTotal = 0}
  local lastPopMin = 0

  for _, h in pairs(group.data) do
    local model = h.model
    local modelInfo = core_vehicles.getModel(model)
    local configs = modelInfo.configs

    for _, config in pairs(h) do
      local configCopy = configs and configs[config] and deepcopy(configs[config]) or nil
      if configCopy then
        local pop = configCopy.Population
        if h.population then pop = h.population end

        if includeLarge == false then
          if configCopy.isLarge == "true" or configCopy.isLarge == true then
            pop = 0
          end
        end

        if isParked == true and h.populationParked then
          pop = h.populationParked
        end

        local popMin = lastPopMin + 1
        local popMax = lastPopMin + 1 + pop

        vehicleData[#vehicleData + 1] = {
          model = model,
          config = config,
          pop = pop,
          popRange = {popMin, popMax},
          japanType = configCopy.japanType
        }

        if popMax > vehicleData.popTotal then
          vehicleData.popTotal = popMax
        end
        lastPopMin = popMax
      end
    end
  end

  return vehicleData
end

local function getIndexRandomPop(data, selected)
  local randNum = math.random(1, data.popTotal)
  for i = 1, #data do
    local v = data[i]
    local r1, r2 = v.popRange[1], v.popRange[2]
    if selected and selected[v.config] then
      local div = selected[v.config]
      r1 = r1 / div
      r2 = r2 / div
    end
    if r1 <= randNum and r2 >= randNum then
      return i
    end
  end
end

local function buildGroup(data, amount)
  local popFactor = 10
  table.sort(data, function(a, b) return a.pop > b.pop end)

  local newGroup = {}
  local selected = {}

  while #newGroup < amount do
    local idx = getIndexRandomPop(data, selected)
    local model = idx and data[idx] or nil
    if model then
      local key = model.config
      selected[key] = (selected[key] or popFactor) + popFactor

      local entry = {model = model.model, config = model.config, modelPop = model.pop}
      if model.japanType then entry.japanType = model.japanType end
      newGroup[#newGroup+1] = entry
    end
  end

  local selectedAmnt = 0
  for _, _ in pairs(selected) do selectedAmnt = selectedAmnt + 1 end

  local finalGroup = {
    data = newGroup,
    tags = data.tags,
    info = data.info,
    author = data.author,
    contributors = data.contributors,
    vramusage = data.vramusage,
    region = data.region
  }

  log("I", logTag,
    "Used " .. tostring(selectedAmnt) ..
    " out of " .. tostring(#data) ..
    " configs to make a list of " .. tostring(amount) ..
    " vehicles for " .. data.name .. " group."
  )

  return finalGroup
end

local function prepareCombinedGroup(isParked)
  local baseIndex = ui.selectedGroup[0] + 1
  local baseGroup = state.groupsTable[baseIndex]
  if not baseGroup then
    log("E", logTag, "Base group is missing!!!")
    return
  end

  local totalTarget = isParked and state.includeParkedNumber or computeTrafficTargetAmount()

  local pool = {
    popTotal = 0,
    tags = baseGroup.tags,
    name = baseGroup.name,
    info = baseGroup.info,
    author = baseGroup.author,
    contributors = baseGroup.contributors,
    vramusage = baseGroup.vramusage,
    region = baseGroup.region
  }

  local function addGroupToPool(group, weightPercent, includeLarge)
    if not group then return end
    local mult = clamp((tonumber(weightPercent) or 0) / 100, 0, 1)
    if mult <= 0 then return end

    local vd = setPopulation(group, isParked, includeLarge)

    for i = 1, #vd do
      local e = vd[i]
      local p = tonumber(e.pop) or 0

      p = math.floor(p * mult + 0.5)
      if p > 0 then
        e.pop = p
        pool[#pool + 1] = e
      end
    end
  end

  addGroupToPool(baseGroup, 100, state.includeLarge and groupSupportsLarge(baseGroup))

  local items = (state.expansions and state.expansions.items) or {}
  for _, it in ipairs(items) do
    local gi = tonumber(it.groupIndex)
    local w = tonumber(it.weight) or 0
    local expGroup = gi and state.expansionsTable[gi] or nil

    if expGroup and w > 0 then
      local allowLarge = it.includeLarge == true and groupSupportsLarge(expGroup)
      addGroupToPool(expGroup, w, allowLarge)
    end
  end

  local last = 0
  pool.popTotal = 0
  for i = 1, #pool do
    local p = tonumber(pool[i].pop) or 0
    local popMin = last + 1
    local popMax = last + 1 + p
    pool[i].popRange = {popMin, popMax}
    last = popMax
    pool.popTotal = popMax
  end

  if pool.popTotal <= 0 then
    log("E", logTag, "Combined pool has popTotal=0 (no eligible configs after scaling).")
    state.currentGroup = {data = {}, tags = baseGroup.tags, name = baseGroup.name}
    return
  end

  local built = buildGroup(pool, totalTarget)

  for i = 1, #built.data do
    local v = built.data[i]
    local configPath = "/vehicles/" .. v.model .. "/" .. v.config .. ".pc"
    local configTable = jsonReadFile(configPath) or {}
    configTable.partConfigFilename = configPath
    v.config = configTable
  end
  for _, q in pairs(built.tags or {}) do
    if q:find("agent_platenaming_basic", 1, true) then
      plates.plateReplaceUSF = "_licenseplate_F"
      plates.plateReplaceUSR = "_licenseplate_R"
      plates.plateShapeInstalled = false
      plates.plateShapeSupported = false
    else
      plates.plateReplaceUSF = "_licenseplate_F_US"
      plates.plateReplaceUSR = "_licenseplate_R_US"
      plates.plateShapeSupported = true
    end
  end

  state.currentGroup = built
end

local function scanAvailableLicensePlatesJob(job)
  job.active = true
  job.finished = false
  job.processed = 0
  job.allfiles = 0
  job.error = nil

  local found = {}
  local designString = "Map Plate Design\0"

  local jbeamFiles = FS:findFiles("/vehicles/common/", "*.jbeam", -1, true, false) or {}
  job.allfiles = #jbeamFiles

  for _, filename in ipairs(jbeamFiles) do
    job.yield()

    local ok = true
    local jbeamData = jsonReadFile(filename)
    if type(jbeamData) ~= "table" then ok = false end

    if ok then
      for k, v in pairs(jbeamData) do
        job.yield()
        if type(v) == "table"
          and v.slotType == "licenseplate_design_2_1"
          and v.information and v.information.name
        then
          found[#found+1] = { id = k, name = v.information.name }
        end
      end
    end

    job.processed = job.processed + 1
    job.yield()
  end

  table.sort(found, function(a, b)
    return string.upper(a.name) < string.upper(b.name)
  end)

  for i = 1, #found do
    designString = designString .. found[i].name .. "\0"
    job.yield()
  end

  plates.licensePlates = found
  plates.plateDesignString = designString
  cache.platesScanned = true

  job.active = false
  job.finished = true
end

local function plateScanJob()
  if cache.platesScanned then return end
  if jobs.platesScan and jobs.platesScan.active then return end

  plates.licensePlates = {}
  plates.plateDesignString = "Map Plate Design\0"
  jobs.platesScan = extensions.core_jobsystem.create(scanAvailableLicensePlatesJob, 1)
end

local function preparePartsPlates(group)
  local shape = ui.selectedPlateShape[0]
  local frontOpt = ui.selectedPlates[0]
  local designIdx = ui.selectedPlateDesign[0]
  local designId = (designIdx ~= 0 and plates.licensePlates[designIdx] and plates.licensePlates[designIdx].id) or nil

  local plateReplaceUSF = plates.plateReplaceUSF
  local plateReplaceUSR = plates.plateReplaceUSR

  local shapeInstalled = plates.plateShapeInstalled
  local shapeSupported = plates.plateShapeSupported

  for i = 1, #group.data do
    local v = group.data[i]
    local cfg = v.config
    local partsTbl = cfg and cfg.parts or nil
    if partsTbl then
      for slot, part in pairs(partsTbl) do
        -- tires randomization
        if slot:find("skin_am5common_tires", 1, true) then
          partsTbl[slot] = getRandomPart(cfg.model, slot, '/vehicles/common/agent_traffic/ck_tires/') or part
        end

        --regional parts (only works if slot exists)
        if traffic.partsRegion and traffic.partsRegion ~= "" then
          if slot:find("_stickers", 1, true) then --stickers
            partsTbl[slot] = slot .. "_" .. tostring(traffic.partsRegion)
          elseif slot:find("_regiontrim", 1, true) then --generic trim (maybe useful one day)
            partsTbl[slot] = slot .. "_" .. tostring(traffic.partsRegion)
          end
        end

        --regional interior side
        if rhdRegion[traffic.partsRegion] then
          if part:find("_regionint_lhd", 1, true) then --rhd interiors
            partsTbl[slot] = part:gsub("_regionint_lhd", "_regionint_rhd")
          end
        else
          if part:find("_regionint_rhd", 1, true) then --lhd
            partsTbl[slot] = part:gsub("_regionint_rhd", "_regionint_lhd")
          end
        end

        -- clear existing plate design (edge cases)
        if slot:find("licenseplate_design_2_1", 1, true) then
          partsTbl[slot] = ""
        end

        if type(part) == "string" and (part:find("vivace", 1, true) or part:find("tograc", 1, true)) then
          print("Plates skipped for stock traffic")
        else
          if type(part) == "string" then
            -- EU baseline
            if part:find(plateReplaceUSF, 1, true) and ((shape == 0) or (shape >= 3)) then
              partsTbl[slot] = part:gsub(plateReplaceUSF, "_licenseplate_F_EU")
              part = partsTbl[slot]
            end
            if part:find(plateReplaceUSR, 1, true) and ((shape == 0) or (shape >= 3)) then
              partsTbl[slot] = part:gsub(plateReplaceUSR, "_licenseplate_R_EU")
              part = partsTbl[slot]
            end

            -- US/JP square
            if part:find("_licenseplate_F_EU", 1, true) and ((shape == 1) or (shape == 2)) then
              partsTbl[slot] = part:gsub("_licenseplate_F_EU", plateReplaceUSF)
              part = partsTbl[slot]
            end
            if part:find("_licenseplate_R_EU", 1, true) and ((shape == 1) or (shape == 2)) then
              partsTbl[slot] = part:gsub("_licenseplate_R_EU", plateReplaceUSR)
              part = partsTbl[slot]
            end
          end
        end

        -- fix naming
        partsTbl[slot] = fixBadEUName(partsTbl[slot])

        -- front plate options
        if frontOpt == 2 then
          if math.random(0, 2) == 2 then
            if slot:find("_licenseplate_F", 1, true) then partsTbl[slot] = "" end
          end
        elseif frontOpt == 1 then
          if slot:find("_licenseplate_F", 1, true) then partsTbl[slot] = "" end
        end

        -- selected plate design
        if designId and slot:find("licenseplate_design_2_1", 1, true) then
          partsTbl[slot] = designId
        end

        -- mod plate shapes
        if shapeInstalled == true and shapeSupported == true then
          if shape == 2 then
            plates.japanPlateType = v.japanType or "standard"
            plates.japanPlateDesign = "shinagawa"
            if not ui.selectedPlateDesign[0] == 0 then
              local lp = plates.licensePlates[ui.selectedPlateDesign[0]]
              if lp and lp.id and lp.id:find("am5jp_", 1, true) then
                local jp = lp.id:gsub("am5jp_", "")
                jp = jp:gsub("_keicommercial", ""):gsub("_kei", ""):gsub("_commercial", "")
                jp = jp:gsub("_standard", ""):gsub("_olympiccommercial", ""):gsub("_olympic", "")
                plates.japanPlateDesign = jp
              end
            end

            if slot:find("licenseplate_design_2_1", 1, true) then
              if plates.japanPlateType == "olympiccommercial" then
                partsTbl[slot] = "am5jp_shinagawa_olympiccommercial"
              elseif plates.japanPlateType == "olympic" then
                partsTbl[slot] = "am5jp_shinagawa_olympic"
              elseif plates.japanPlateType == "temporary" then
                partsTbl[slot] = "am5jp_shinagawa_temporary"
              else
                partsTbl[slot] = "am5jp_" .. plates.japanPlateDesign .. "_" .. plates.japanPlateType
              end
            end
          elseif shape == 3 then
            dump(partsTbl[slot])
            if type(part) == "string" and (part:find("_licenseplate_F_EU", 1, true) or part:find("_licenseplate_F_US", 1, true)) then
              local r = part:gsub("_licenseplate_F_EU", "_licenseplate_F_IT")
              r = r:gsub("_licenseplate_F_US", "_licenseplate_F_IT")
              partsTbl[slot] = r
            end
            if slot:find("licenseplate_design_2_1", 1, true) then
              partsTbl[slot] = "license_plate_italy_1999_2_1"
            end
          elseif shape == 4 then
            if type(part) == "string" then
              local r = part
              r = r:gsub("_licenseplate_F_EU", "_licenseplate_F_SA")
              r = r:gsub("_licenseplate_R_EU", "_licenseplate_R_SA")
              r = r:gsub("_licenseplate_F_US", "_licenseplate_F_SA")
              r = r:gsub("_licenseplate_R_US", "_licenseplate_R_SA")
              partsTbl[slot] = r
            end
          elseif shape == 5 then
            if type(part) == "string" and part:find("_licenseplate_R_EU", 1, true) then
              partsTbl[slot] = part .. "_yellow"
            end
          elseif shape == 6 then
            if type(part) == "string" and part:find("_licenseplate_F_EU", 1, true) then
              partsTbl[slot] = part .. "_white"
            end
          end

          partsTbl[slot] = fixBadEUName(partsTbl[slot])
        end
      end
    end
  end
end

local function preparePartsParked(parkedGroup)
  for i = 1, #parkedGroup.data do
    local v = parkedGroup.data[i]
    local partsTbl = v.config and v.config.parts or nil
    if partsTbl then
      for slot, part in pairs(partsTbl) do
        if slot:find("_controller", 1, true) then partsTbl[slot] = "" end
        if slot:find("_engine", 1, true) then partsTbl[slot] = "" end
        if slot:find("_transmission", 1, true) then partsTbl[slot] = "" end
        if slot:find("_drivetrain", 1, true) then partsTbl[slot] = "" end

        if type(part) == "string" and not part:find("_parked", 1, true) then
          if part:find("_wheels_F", 1, true) or part:find("_wheels_R", 1, true) or part:find("_steeringbox", 1, true) then
            partsTbl[slot] = part .. "_parked"
          end
          if part:find("_hubcaps_F", 1, true) then
            partsTbl[slot .. "_parked"] = part .. "_parked"
          end
          if part:find("_hubcaps_R", 1, true) then
            partsTbl[slot .. "_parked"] = part .. "_parked"
          end
        end
      end
    end
  end
end

local function getTrafficAmnt()
  local amount = coreAmount - 1
  local trafficList = extensions.gameplay_traffic.getTrafficList()
  local parkedList = extensions.gameplay_parking.getParkedCarsList()
  if trafficList and parkedList then
    amount = 0
    for _, _ in pairs(trafficList) do amount = amount + 1 end
    for _, _ in pairs(parkedList) do amount = amount + 1 end
  end
  return amount
end

local function getParkingSpots()
  local spots = extensions.gameplay_parking.getParkingSpots()
  local count = 0
  if spots and spots.byName then
    for _, _ in pairs(spots.byName) do count = count + 1 end
  end

  state.levelSpots = count
  if count > 0 then state.maxParked = count end
  if count >= coreAmount*8 then state.maxParked = coreAmount*8 end
  if state.includeParkedNumber >= state.maxParked then
    state.includeParkedNumber = state.maxParked
  end
end

local function spawnParked()
  prepareCombinedGroup(true)
  preparePartsPlates(state.currentGroup)

  local parkedGroup = state.currentGroup
  preparePartsParked(parkedGroup)

  extensions.core_multiSpawn.spawnGroup(
    parkedGroup.data,
    state.includeParkedNumber,
    {name = "autoParking", mode = "roadBehind", shuffle = false, gap = 20, instant = false, configPopPower = 10}
  )
end

local function startTraffic()
  extensions.gameplay_traffic.activate()
  if state.usePooling == true and state.vehicleAmount > 0 then
    extensions.gameplay_traffic.setActiveAmount(state.vehicleAmount)
  end
  extensions.gameplay_traffic.scatterTraffic()
  state.agentTrafficActive = true
end

local function spawnTraffic()
  guihooks.trigger("app:waiting", true)

  plates.plateShapeInstalled = isPlateShapeInstalled(ui.selectedPlateShape[0])

  prepareCombinedGroup(false)
  preparePartsPlates(state.currentGroup)

  local targetAmount = computeTrafficTargetAmount()
  state.lastSpawnTargetAmount = targetAmount

  extensions.core_multiSpawn.spawnGroup(
    state.currentGroup.data,
    targetAmount,
    {name = "agentTrafficCurrent", shuffle = true, gap = 20, instant = false, mode = "traffic", configPopPower = 10}
  )

  if state.includeParked == true then
    spawnParked()
  end

  state.alreadySpawned = true
  guihooks.trigger("app:waiting", false)
end

local function testGroup(zOffset)
  log("I", logTag, "Starting test")
  local g = state.groupsTable[ui.selectedGroup[0] + 1]
  if g and g.name and g.data then
    log("I", logTag, "Starting with a selected group: " .. g.name)

    local spawnOptions = {autoEnterVehicle = false}
    local mainPos = core_camera.getPosition()
    local count = 0

    for _, v in pairs(g.data) do
      spawnOptions.config = v.config
      spawnOptions.pos = mainPos + vec3(0, count, 0)
      if zOffset then spawnOptions.pos = spawnOptions.pos + vec3(0, 0, zOffset) end
      core_vehicles.spawnNewVehicle(v.model, spawnOptions)
      count = count + 1.5
    end
  else
    log("E", logTag, "None of groups are selected or table is missing / corrupted")
  end
end

local function delayedScatter(job)
  job.sleep(0.1)
  extensions.gameplay_parking.scatterParkedCars()
end

local function onVehicleGroupSpawned(vehList, groupId, groupName)
  if groupName == "agentTrafficCurrent" then
    if state.quickStart == true then
      startTraffic()
    end
  elseif groupName == "autoParking" then
    extensions.core_jobsystem.create(delayedScatter, 1)
  end
end

local function getSelectedBaseGroup()
  local idx = (ui.selectedGroup[0] or 0) + 1
  return (state.groupsTable and state.groupsTable[idx]) or nil
end

local function updatePlateSupportFromSelectedGroup()
  local g = getSelectedBaseGroup()
  local basic = tagsContain((g and g.tags), "agent_platenaming_basic")
  plates.plateReplaceUSF = basic and "_licenseplate_F" or "_licenseplate_F_US"
  plates.plateReplaceUSR = basic and "_licenseplate_R" or "_licenseplate_R_US"
  plates.plateShapeSupported = not basic
end

local function uiStartTraffic()
  startTraffic()
  state.agentTrafficActive = true
end

local function uiStopTraffic()
  state.agentTrafficActive = false
  extensions.gameplay_traffic.deactivate(true)
end

local function uiDeleteTraffic()
  local amountToDelete = math.max(state.lastSpawnTargetAmount, getTrafficAmnt())
  extensions.core_multiSpawn.deleteVehicles(amountToDelete)
  state.alreadySpawned = false
  state.agentTrafficActive = false
end

local function onExtensionLoaded()
  if ui.show == nil then ui.show = im.BoolPtr(false) end
  onGroupDataLoad()
  updatePlateSupportFromSelectedGroup()
  plateScanJob()
  getParkingSpots()
end

local function expansionsTab()
  local items = state.expansions.items
  if not items then state.expansions.items = {}; items = state.expansions.items end

  for i = 1, #items do
    local it = items[i]
    -- group chooser
    local idxPtr = im.IntPtr((it.groupIndex or 1) - 1)
    im.TextUnformatted("Expansion #"..i)
    im.PushItemWidth(220 * im.uiscale[0])
    im.Combo2("##expGroup" .. i, idxPtr, state.expansionsString)
    it.groupIndex = idxPtr[0] + 1
    im.PopItemWidth()
    im.SameLine()
    if im.Button("X##removeExp" .. i) then
      table.remove(items, i)
      break
    end

    local expGroup = state.expansionsTable[it.groupIndex]

    if groupSupportsLarge(expGroup) then
      local largePtr = im.BoolPtr(it.includeLarge == true)

      if im.Checkbox("Include Large Vehicles##expLarge" .. i, largePtr) then
        it.includeLarge = largePtr[0]
      end

      if im.IsItemHovered() then
        im.BeginTooltip()
        im.TextUnformatted("Allows this expansion to spawn configs marked as large vehicles.")
        im.EndTooltip()
      end
    else
      it.includeLarge = false
    end

    -- weight slider 0..100
    local wPtr = im.FloatPtr(tonumber(it.weight) or 30)
    im.TextUnformatted("Rarity:")
    if im.IsItemHovered() then
      im.BeginTooltip(); im.TextUnformatted("Allows to adjust global weight of expansion in relation to base pack"); im.EndTooltip()
    end
    im.SameLine()
    if im.Button("Rare##"..i) then
      wPtr[0] = 10
    end
    if im.IsItemHovered() then
      im.BeginTooltip(); im.TextUnformatted("Sets expansion weight to 10%"); im.EndTooltip()
    end
    im.SameLine()
    if im.Button("Medium##"..i) then
      wPtr[0] = 50
    end
    if im.IsItemHovered() then
      im.BeginTooltip(); im.TextUnformatted("Sets expansion weight to 50%"); im.EndTooltip()
    end
    im.SameLine()
    if im.Button("Common##"..i) then
      wPtr[0] = 100
    end
    if im.IsItemHovered() then
      im.BeginTooltip(); im.TextUnformatted("Sets expansion weight to 100%"); im.EndTooltip()
    end
    im.PushItemWidth(220 * im.uiscale[0])
    if im.SliderFloat("##expWeight" .. i, wPtr, 0, 100, "%.0f%%") then
      it.weight = wPtr[0]
    else
      it.weight = wPtr[0]
    end
    im.PopItemWidth()
    im.Separator()
  end

  if im.Button("Add##addExpansion") then
    items[#items + 1] = {
      groupIndex = ui.selectedGroup[0] + 1,
      weight = 30,
      includeLarge = false
    }
  end
end

local function groupTab()
  local g = getSelectedBaseGroup()
  local vramCnt = 0
  local vram = 0
  local baseUsage = g and tonumber(g.vramusage) or publicShaming(g)
  if baseUsage then
    vramCnt = vramCnt + 1
    vram = vram + baseUsage
  end

  local items = (state.expansions and state.expansions.items) or {}
  for _, it in ipairs(items) do
    local gi = tonumber(it.groupIndex)
    local group = gi and state.groupsTable[gi]

    if group then
      local usage = tonumber(group.vramusage) or publicShaming(group)
      if usage then
        vramCnt = vramCnt + 1
        vram = vram + usage
      end
    end
  end

  local vehicleCount = (state.vehicleAmount or 0)
  if state.usePooling == true then
    vehicleCount = vehicleCount + (state.usePoolingNumber or 0)
  end
  if state.includeParked == true then
    vehicleCount = vehicleCount + (state.includeParkedNumber or 0)
  end
  local avgVram = 0
  if vramCnt > 0 then
    avgVram = vram / vramCnt
    -- add avg plates VRAM usage
    avgVram = avgVram + 18
  end

  local vramtotal = avgVram * vehicleCount

  im.TextUnformatted("Traffic Group")
  im.SameLine()

  local info = (g and g.info) or "No additional info for this group"
  local author = (g and g.author) or "Unknown"
  local contributors = (g and g.contributors) or "None"

  local helpText =
    "" .. info ..
    "\nAuthor: " .. author ..
    "\nContributors: " .. contributors ..
    "\nVRAM Usage: " .. vramText(avgVram) .. " per car" ..
    "\n(estimated " .. vramText(vramtotal) .. " total with current spawn number)"

  im.ShowHelpMarker(helpText)

  im.PushItemWidth(200 * im.uiscale[0])
  if im.Combo2("##Selected Preset", ui.selectedGroup, state.groupString) then
    local gg = getSelectedBaseGroup()
    applyDefaultPlateShapeFromTags(gg and gg.tags, gg and gg.region)
  end
  im.PopItemWidth()

  --new tag options setting (group lines)
  traffic.partsRegion = (g and g.partsRegion) or nil
  traffic.supportsLarge = groupSupportsLarge(g)

  if traffic.supportsLarge then
    if im.Checkbox("Include Large Vehicles", ui.includeLargePtr) then
      state.includeLarge = ui.includeLargePtr[0]
    end
  end

  im.TextUnformatted("Number Of Cars")
  im.PushItemWidth(200 * im.uiscale[0])
  ui.varAmount[0] = state.vehicleAmount
  if im.SliderInt("##agentTrafficTool", ui.varAmount, 0, coreAmount * 4) then
    state.vehicleAmount = ui.varAmount[0]
  end
  im.PopItemWidth()

  if im.Checkbox("Use Pooling", ui.usePoolingPtr) then
    state.usePooling = ui.usePoolingPtr[0]
  end
  if im.IsItemHovered() then
    im.BeginTooltip(); im.TextUnformatted("Enables vehicle pooling"); im.EndTooltip()
  end

  if state.usePooling == true then
    im.TextUnformatted("Number Of Pooled Cars")
    im.PushItemWidth(200 * im.uiscale[0])
    ui.varPooling[0] = state.usePoolingNumber
    if im.SliderInt("##agentTrafficPooled", ui.varPooling, 1, coreAmount * 8) then
      state.usePoolingNumber = ui.varPooling[0]
    end
    im.PopItemWidth()
  end

  -- parked
  if state.levelSpots > 0 then
    if im.Checkbox("Parked Vehicles", ui.includeParkedPtr) then
      state.includeParked = ui.includeParkedPtr[0]
    end
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.TextUnformatted("Includes parked vehicles in regular spawns, like how the official traffic spawning works")
      im.EndTooltip()
    end
    if state.includeParked == true then
      if state.includeParkedNumber > state.levelSpots then
        im.TextColored(im.ImVec4(1, 1, 0, 1), "Amount of parked is higher\nthan amount of parking spots!")
      end
      im.TextUnformatted("Number Of Parked Cars")
      im.PushItemWidth(200 * im.uiscale[0])
      ui.varParked[0] = state.includeParkedNumber
      if im.SliderInt("##agentTrafficParked", ui.varParked, 1, state.maxParked) then
        state.includeParkedNumber = ui.varParked[0]
      end
      im.PopItemWidth()
    end
  else
    im.TextColored(im.ImVec4(1, 0, 0, 1), "This level does not support\nparked vehicles!")
    state.includeParked = false
    ui.includeParkedPtr[0] = false
  end
end

local function setupTab()
  -- quick start
  if im.Checkbox("Quick Start", ui.quickStartPtr) then
    state.quickStart = ui.quickStartPtr[0]
  end
  if im.IsItemHovered() then
    im.BeginTooltip(); im.TextUnformatted("Automatically start traffic after spawning"); im.EndTooltip()
  end
  im.Separator()

  -- plates
  im.TextUnformatted("Plate Model/Type")
  im.PushItemWidth(160 * im.uiscale[0])
  if plates.plateShapeSupported == false then
    im.TextColored(im.ImVec4(1, 0, 0, 1),
      "The current group does not support\nmodded plate models and therefore\nsome of these options may not function")
  else
    im.Combo2("##Plate Shape", ui.selectedPlateShape, plates.plateShapeString)
    if im.IsItemHovered() then
      im.BeginTooltip()
      im.TextUnformatted("Extra modded plate styles, only some plate designs supported!")
      im.EndTooltip()
    end
  end
  im.PopItemWidth()

  plates.plateShapeInstalled = isPlateShapeInstalled(ui.selectedPlateShape[0])
  drawPlateShapeModStatus(ui.selectedPlateShape[0])

  im.TextUnformatted("Plate Design")
  im.PushItemWidth(160 * im.uiscale[0])

  if not cache.platesScanned then
    plateScanJob()
    local j = jobs.platesScan
    if j and j.active and j.allfiles and j.allfiles > 0 then
      im.TextUnformatted(("Checking for plates... (%d/%d)"):format(j.processed or 0, j.allfiles))
    else
      im.TextUnformatted("Checking for plates...")
    end
  else
    im.Combo2("##Plate Design", ui.selectedPlateDesign, plates.plateDesignString)
  end

  im.PopItemWidth()
  im.Separator()
  if im.TreeNode1("Extra License Plate Settings") then
    im.TextUnformatted("Front Plate Usage")
    im.PushItemWidth(160 * im.uiscale[0])
    im.Combo2("##Selected Plates", ui.selectedPlates, plates.platesString)
    if im.IsItemHovered() then
      im.BeginTooltip(); im.TextUnformatted("Only recommended for US maps/vehicle groups"); im.EndTooltip()
    end
    im.PopItemWidth()
    im.TreePop()
  end
  im.Separator()

  if im.TreeNode1("Traffic AI Settings") then
    im.TextUnformatted("AI Risk/Aggression")
    im.PushItemWidth(150 * im.uiscale[0])
    if im.SliderFloat("##AI Risk", ui.varAggression, 0.1, 2, "%.1f") then
      gameplay_traffic.setTrafficVars({baseAggression = ui.varAggression[0]})
    end
    im.TextUnformatted("AI Respawn Rate")
    if im.SliderFloat("##AI Respawn", ui.varRespawnRate, 0.1, 3, "%.1f") then
      gameplay_traffic.setTrafficVars({spawnValue = ui.varRespawnRate[0]})
    end
    im.PopItemWidth()
    im.TreePop()
  end
end

local function drawUI()
  im.Begin(appTitle, ui.show, im.WindowFlags_AlwaysAutoResize + im.WindowFlags_NoResize)

  if im.BeginTabBar("##agentTrafficTabs") then
    if im.BeginTabItem("Group", nil, im.TabItemFlags_None) then
      groupTab()
      im.EndTabItem()
    end
    if im.BeginTabItem("Expansions", nil, im.TabItemFlags_None) then
      expansionsTab()
      im.EndTabItem()
    end
    if im.BeginTabItem("Setup", nil, im.TabItemFlags_None) then
      setupTab()
      im.EndTabItem()
    end
    im.EndTabBar()
  end

  im.Separator()

  local spawnLabel = state.alreadySpawned and "Delete" or "Spawn"
  local startLabel = state.agentTrafficActive and "Stop" or "Start"

  if im.Button(spawnLabel .. "##spawnDelete", im.ImVec2(120 * im.uiscale[0], 0)) then
    if state.alreadySpawned then
      uiDeleteTraffic()
    else
      spawnTraffic()
      if state.quickStart == true then
        state.agentTrafficActive = true
      end
    end
  end

  im.SameLine()

  if im.Button(startLabel .. "##startStop", im.ImVec2(120 * im.uiscale[0], 0)) then
    if state.agentTrafficActive then
      uiStopTraffic()
    else
      uiStartTraffic()
    end
  end

  im.End()
end

local function onUpdate()
  if ui.show == nil then ui.show = im.BoolPtr(false) end
  if not ui.show[0] then return end
  drawUI()
end

local function onClientStartMission()
  getParkingSpots()
end

local function openUI()
  if ui.show == nil then ui.show = im.BoolPtr(false) end
  ui.show[0] = true
end
local function hideUI()
  if ui.show == nil then ui.show = im.BoolPtr(false) end
  ui.show[0] = false
end
local function toggleUI()
  if ui.show == nil then ui.show = im.BoolPtr(false) end
  ui.show[0] = not ui.show[0]
end

M.show = openUI
M.hide = hideUI
M.toggle = toggleUI
M.testGroup = testGroup

M.onClientStartMission = onClientStartMission
M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.onVehicleGroupSpawned = onVehicleGroupSpawned

return M
