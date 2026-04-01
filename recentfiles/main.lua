VERSION = "0.1.0"

local micro = import("micro")
local buffer = import("micro/buffer")
local shell = import("micro/shell")
local go_os = import("os")
local filepath = import("path/filepath")

local home = os.getenv("HOME") or ""
local stateHome = os.getenv("XDG_STATE_HOME")
if stateHome == nil or stateHome == "" then
    stateHome = filepath.Join(home, ".local", "state")
end
local recentDir = filepath.Join(stateHome, "micro", "recent-files")
local startupRoot, _ = go_os.Getwd()
local maxEntries = 10
local startupHandled = false

local function shellQuote(text)
    return "'" .. string.gsub(text, "'", "'\\''") .. "'"
end

local function encodePath(path)
    local parts = {}
    for i = 1, #path do
        local byte = string.byte(path, i)
        if (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte == 45 or byte == 46 or byte == 95 then
            parts[#parts + 1] = string.char(byte)
        else
            parts[#parts + 1] = string.format("=%02X", byte)
        end
    end
    return table.concat(parts)
end

local function recentPath()
    if startupRoot == nil or startupRoot == "" then
        return filepath.Join(recentDir, "default.txt")
    end
    return filepath.Join(recentDir, encodePath(startupRoot) .. ".txt")
end

local function ensureRecentDir()
    go_os.MkdirAll(recentDir, 448)
end

local function relativeToRoot(path)
    if startupRoot == nil or startupRoot == "" then
        return path
    end

    local rel, err = filepath.Rel(startupRoot, path)
    if err ~= nil or rel == ".." or string.sub(rel, 1, 3) == "../" then
        return ""
    end

    return rel
end

local function isFile(path)
    if path == nil or path == "" then
        return false
    end

    local _, err = shell.RunCommand("sh -c " .. shellQuote("test -f " .. shellQuote(path)))
    return err == nil
end

local function isDirectory(path)
    if path == nil or path == "" then
        return false
    end

    local _, err = shell.RunCommand("sh -c " .. shellQuote("test -d " .. shellQuote(path)))
    return err == nil
end

local function readRecentFiles()
    local file = io.open(recentPath(), "r")
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
    ensureRecentDir()

    local file = io.open(recentPath(), "w")
    if file == nil then
        return
    end

    for _, entry in ipairs(entries) do
        file:write(entry .. "\n")
    end
    file:close()
end

local function rememberFile(path)
    if not isFile(path) then
        return
    end

    local relPath = relativeToRoot(path)
    if relPath == "" then
        return
    end

    local seen = { [relPath] = true }
    local entries = { relPath }
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
        and (bp.Buf.AbsPath == nil or bp.Buf.AbsPath == "" or isDirectory(bp.Buf.AbsPath))
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

    for _, relPath in ipairs(readRecentFiles()) do
        local path = relPath
        if startupRoot ~= nil and startupRoot ~= "" then
            path = filepath.Join(startupRoot, relPath)
        end

        if isFile(path) then
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
end

function init()
end
