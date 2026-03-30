VERSION = "0.1.0"

local micro = import("micro")
local buffer = import("micro/buffer")

local recentPath = os.getenv("HOME") .. "/config/micro/recent-files.txt"
local maxEntries = 200
local startupHandled = false

local function readRecentFiles()
    local file = io.open(recentPath, "r")
    if file == nil then
        return {}
    end

    local entries = {}
    for line in file:lines() do
        if line ~= "" then
            table.insert(entries, line)
        end
    end
    file:close()
    return entries
end

local function writeRecentFiles(entries)
    local file = io.open(recentPath, "w")
    if file == nil then
        return
    end

    for _, entry in ipairs(entries) do
        file:write(entry .. "\n")
    end
    file:close()
end

local function rememberFile(path)
    if path == nil or path == "" then
        return
    end

    local seen = { [path] = true }
    local entries = { path }
    for _, entry in ipairs(readRecentFiles()) do
        if not seen[entry] then
            table.insert(entries, entry)
            seen[entry] = true
        end
        if #entries >= maxEntries then
            break
        end
    end
    writeRecentFiles(entries)
end

local function shouldRestoreRecent(bp)
    return bp ~= nil
        and bp.Buf ~= nil
        and bp.Buf.AbsPath == ""
        and not bp.Buf:Modified()
        and bp.Buf:LinesNum() == 1
        and bp.Buf:Line(0) == ""
end

function onBufferOpen(buf)
    rememberFile(buf.AbsPath)
end

function onAnyEvent()
    if startupHandled then
        return
    end

    local bp = micro.CurPane()
    if bp == nil or bp.Buf == nil then
        return
    end

    startupHandled = true
    if not shouldRestoreRecent(bp) then
        return
    end

    for _, path in ipairs(readRecentFiles()) do
        local buf, err = buffer.NewBufferFromFile(path)
        if err == nil then
            micro.After(0, function()
                bp:PushJump()
                bp:OpenBuffer(buf)
                if bp.Relocate then
                    bp:Relocate()
                end
            end)
            return
        end
    end
end

function init()
end
