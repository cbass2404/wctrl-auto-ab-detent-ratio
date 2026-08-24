--[[
    wctrl-auto-ab-detent-ratio-hook.lua

    Starts the WinWing afterburner-ratio helper when a mission begins, and tells
    it which aircraft the player is in.

    The helper also listens to WinWing's own export stream on UDP 16537, so this
    hook is belt-and-braces: wwtExport.lua sends its "mod" message only once per
    change, so if the helper is still starting up that single message is lost.
    Sending it again from here closes that race, and covers the case where the
    wwt export is disabled entirely.

    Everything is wrapped in pcall - a failure here must never affect DCS.
--]]

-- @@PROJECT_DIR@@ and @@VERSION@@ are substituted by deploy.ps1 so this hook
-- points at its own version-stamped folder. Running the file straight from the
-- repo leaves the placeholders in place and the helper simply is not found.
local PROJECT_DIR = '@@PROJECT_DIR@@'
local VERSION     = '@@VERSION@@'

local HELPER_HOST = '127.0.0.1'
local HELPER_PORT = 16537
local POLL_PERIOD = 0.5   -- seconds between LoGetSelfData checks

local WinctrlAB = {}

local socket_ok, socket = pcall(function()
    package.path  = package.path  .. ';' .. lfs.currentdir() .. '/LuaSocket/?.lua'
    package.cpath = package.cpath .. ';' .. lfs.currentdir() .. '/LuaSocket/?.dll'
    return require('socket')
end)

local udp
local helperStarted = false
local lastAircraft = nil
local lastPoll = 0

-- Capture DCS's global log table before defining our own helper, so the
-- local name cannot shadow it.
local dcsLog = log

local function logInfo(msg)
    pcall(function()
        dcsLog.write('WINCTRL-AB', dcsLog.INFO, msg)
    end)
end

local function send(payload)
    if not socket_ok then return end
    pcall(function()
        if not udp then
            udp = socket.udp()
            udp:settimeout(0)
        end
        udp:sendto(payload, HELPER_HOST, HELPER_PORT)
    end)
end

local function sendAircraft(name)
    if not name or name == '' or name == lastAircraft then return end
    lastAircraft = name
    -- Same shape wwtExport.lua uses, so the helper has a single code path.
    send('{"func":"mod","msg":"' .. tostring(name) .. '"}')
    logInfo('aircraft -> ' .. tostring(name))
end

local function startHelper()
    if helperStarted then return end
    helperStarted = true
    pcall(function()
        -- [[...]] literals: no escape processing, so backslashes are safe here.
        local vbs = lfs.writedir() .. [[Scripts\]] .. PROJECT_DIR .. [[\lib\run-hidden.vbs]]
        local f = io.open(vbs, 'r')
        if not f then
            logInfo('helper not installed at ' .. vbs .. ' - skipping')
            return
        end
        f:close()
        -- wscript with a hidden window; the helper self-exits when DCS closes.
        os.execute('start "" /B wscript.exe "' .. vbs .. '"')
        logInfo('helper launched (' .. VERSION .. ')')
    end)
end

function WinctrlAB.onSimulationStart()
    pcall(function()
        startHelper()
        lastAircraft = nil
        local selfData = Export.LoGetSelfData()
        if selfData and selfData.Name then sendAircraft(selfData.Name) end
    end)
end

function WinctrlAB.onPlayerChangeSlot(id)
    pcall(function()
        if id ~= net.get_my_player_id() then return end
        local slot = net.get_player_info(id, 'slot')
        local unitType = DCS.getUnitProperty(slot, DCS.UNIT_TYPE)
        if unitType then sendAircraft(unitType) end
    end)
end

function WinctrlAB.onSimulationFrame()
    -- onPlayerChangeSlot does not fire in single player, so poll as well.
    pcall(function()
        local now = DCS.getRealTime()
        if now >= lastPoll and now < lastPoll + POLL_PERIOD then return end
        lastPoll = now
        local selfData = Export.LoGetSelfData()
        if selfData and selfData.Name then sendAircraft(selfData.Name) end
    end)
end

function WinctrlAB.onSimulationStop()
    pcall(function()
        lastAircraft = nil
        send('{"func":"mission","msg":"stop"}')
        logInfo('mission stop sent')
    end)
end

DCS.setUserCallbacks(WinctrlAB)
