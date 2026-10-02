-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local lastDiscover = nil
local discoversById = nil
local discoverFiles = nil
local pageInfosById = {}

--[[
-- use this to get the position, rotation and partConfig of all vehicles
for id in activeVehiclesIterator() do local veh = scenetree.findObjectById(id) print(veh) dump({veh:getPosition(), quatFromDir(veh:getDirectionVector(), veh:getDirectionVectorUp()), veh.jbeam, veh.partConfig}) end
]]
M.loadDiscovers = function()
  if discoversById then return end
  discoversById = {}
  local discoverFiles = FS:findFiles("lua/ge/extensions/gameplay/discover/", "*.lua", 1, false, true)
  for _, file in ipairs(discoverFiles) do
    local dir, fn, ext = path.splitWithoutExt(file)
    local discover = require(dir..fn)
    if discover.pageInfo then
      pageInfosById[fn] = discover.pageInfo
    end
    if discover.experiences then
      for _, experience in ipairs(discover.experiences) do
        discoversById[experience.id] = experience
      end
    end
  end
end

local function formatDiscover(discover)
  local discoverCopy = deepcopy(discover)
  discoverCopy.discoverId = discover.id
  discoverCopy.icon = discoverCopy.icon or "road"
  if discover.type == "mission" and not discoverCopy.name then
    local mission = gameplay_missions_missions.getMissionById(discoverCopy.missionId)
    discoverCopy.name = mission.name
    discoverCopy.description = mission.description
    discoverCopy.image = mission.previewFile
    discoverCopy.icon = mission.iconFontIcon
  end
  if not discoverCopy.image then
    discoverCopy.image = discover.type == "mission" and "/gameplay/discover/images/missionTBD.jpg" or "/gameplay/discover/images/freeroamTBD.jpg"
  end
  return discoverCopy
end

local function getDiscoverPages()
  M.loadDiscovers()
  local pages = {}
  for id, pageInfo in pairs(pageInfosById) do
    local page = deepcopy(pageInfo)
    page.sections = {}
    for _, section in ipairs(pageInfo.sections) do
      section.cards = {}
      for _, id in ipairs(section.discoverIds) do
        local discover = discoversById[id]
        table.insert(section.cards, formatDiscover(discover))
      end
      table.insert(page.sections, section)
    end
    table.insert(pages, page)
  end
  table.sort(pages, function(a, b) return a.title < b.title end)
  return pages
end

local function startDiscover(discoverId)
  M.loadDiscovers()
  if lastDiscover then
    log("W", "discover", "Already loading discover: " .. lastDiscover..", ignoring: " .. discoverId)
    return
  end
  local discover = discoversById[discoverId]
  lastDiscover = discoverId
  if discover then
    if discover.missionId then
      log('I', 'discover', 'Starting discover mission: ' .. discoverId)
      local mission = gameplay_missions_missions.getMissionById(discover.missionId)
      local scenario = scenario_scenariosLoader.getScenarioDataForMission(mission)
      if discover.model and discover.config then
        log('I', 'discover', 'Setting model and config for discover mission: ' .. discoverId)
        scenario.variables.model = discover.model
        scenario.variables.config = discover.config
      end
      scenario_scenariosLoader.start(scenario)
      M.onLoadingScreenFadeout = function()
        lastDiscover = nil
        M.onLoadingScreenFadeout = nil
        extensions.hookUpdate('onLoadingScreenFadeout')
      end
      extensions.hookUpdate('onLoadingScreenFadeout')
    else
      log('I', 'discover', 'Starting discover: ' .. discoverId)
      discover.trigger(M)
      M.onLoadingScreenFadeout = function()
        log('I', 'discover', 'Running discover tasks: ' .. discoverId)
        if discover.tasks then
          discover.tasks(M)
        end
        lastDiscover = nil
        M.onLoadingScreenFadeout = nil
        extensions.hookUpdate('onLoadingScreenFadeout')
      end
      extensions.hookUpdate('onLoadingScreenFadeout')

      M.onClientStartMission = function()
        log('I', 'discover', 'Setting game state to freeroam, discover: ' .. discoverId)
        core_gamestate.setGameState("freeroam","discover", nil)
        M.onClientStartMission = nil
        extensions.hookUpdate('onClientStartMission')
      end
      extensions.hookUpdate('onClientStartMission')
    end
  end
end

-- can be started with -discover <discoverName>
local function onInit()
  setExtensionUnloadMode(M, "manual")
  local cmdArgs = Engine.getStartingArgs()
  for i, v in ipairs(cmdArgs) do
    if v == "-discover" then
      M.startDiscover(cmdArgs[i+1])
    end
  end
end


local doneIntroPopups = {}
M.basicControlsIntroPopup = function()
  local deviceOrder = {"wheel","joystick","xinput","gamepad","mouse","keyboard"}
  local devices = {}
  for k, v in pairs(core_input_bindings.bindings) do
    if v.contents.devicetype and v.contents.imagePack then
      table.insert(devices, {device = v.contents.devicetype, imagePack = v.contents.imagePack})
    end
  end
  local function findIndex(arr, val)
    for i, v in ipairs(arr) do
      if v == val then return i end
    end
    return -1
  end
  table.sort(devices, function(a, b) return findIndex(deviceOrder, a.device) < findIndex(deviceOrder, b.device) end)
  table.insert(devices, {device = "fallback", imagePack = "fallback"})
  for i, v in ipairs(devices) do
    local popup = "basicDriving_"..v.imagePack
    if FS:fileExists("/gameplay/discover/popups/"..popup.."/content.html") then
      if not doneIntroPopups[popup] then
        M.introPopup(popup)
      end
      return
    else
      log("I","","Basic Driving Popup not found: "..popup)
    end
  end
end

M.introPopup = function(id)
  if doneIntroPopups[id] then
    return
  end
  doneIntroPopups[id] = true
  local file = "/gameplay/discover/popups/"..id.."/content.html"
  if not FS:fileExists(file) then
    return
  end
  local content = readFile(file):gsub("\r\n","")
  local entry = {
    type = "info",
    content = content,
    flavour = "onlyOk",
    isPopup = true,
  }
  log("I","","Intro Popup: " .. id)
  guihooks.trigger("introPopupTutorial", {entry})
end


M.getDiscoverPages = getDiscoverPages
M.onInit = onInit
M.startDiscover = startDiscover


return M
