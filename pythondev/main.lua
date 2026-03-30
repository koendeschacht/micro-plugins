VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")

local function shellQuote(text)
    return "'" .. string.gsub(text, "'", "'\\''") .. "'"
end

local function commandExists(cmd)
    local _, err = shell.RunCommand("sh -c 'command -v " .. cmd .. " >/dev/null 2>&1'")
    return err == nil
end

local function copyToClipboard(text)
    local commands = {
        "xclip -selection clipboard",
        "wl-copy",
        "pbcopy",
    }

    for _, command in ipairs(commands) do
        local binary = command:match("^(%S+)")
        if commandExists(binary) then
            local _, err = shell.RunCommand("sh -c " .. shellQuote("printf '%s' " .. shellQuote(text) .. " | " .. command))
            if err == nil then
                return true
            end
        end
    end

    return false
end

local function copyCommand(command)
    if copyToClipboard(command) then
        micro.InfoBar():Message("Copied: " .. command)
        return
    end

    micro.InfoBar():Error("pythondev: no clipboard helper found")
end

local function currentFile(bp)
    if bp == nil or bp.Buf == nil or bp.Buf.AbsPath == nil or bp.Buf.AbsPath == "" then
        micro.InfoBar():Error("pythondev: current buffer is not a file")
        return nil
    end

    return bp.Buf.AbsPath
end

local function isPython(bp)
    return bp ~= nil and bp.Buf ~= nil and bp.Buf:FileType() == "python"
end

local function currentLines(buf)
    local lines = {}
    for i = 0, buf:LinesNum() - 1 do
        table.insert(lines, buf:Line(i))
    end
    return lines
end

local function currentPythonTestNodeId(bp)
    if not isPython(bp) then
        micro.InfoBar():Error("pythondev: current buffer is not Python")
        return nil
    end

    local path = currentFile(bp)
    if path == nil then
        return nil
    end

    local cursor = bp.Buf:GetActiveCursor()
    local cursorLine = cursor.Y + 1
    local lines = currentLines(bp.Buf)
    local functionName = nil
    local functionIndent = nil
    local functionLine = nil

    for lineNo = cursorLine, 1, -1 do
        local line = lines[lineNo]
        local indent, name = line:match("^(%s*)async%s+def%s+([%w_]+)")
        if name == nil then
            indent, name = line:match("^(%s*)def%s+([%w_]+)")
        end

        if name ~= nil then
            functionName = name
            functionIndent = #indent
            functionLine = lineNo
            break
        end
    end

    if functionName == nil then
        micro.InfoBar():Error("pythondev: no Python function found at cursor")
        return nil
    end

    local parts = { functionName }
    local indentLimit = functionIndent

    for lineNo = functionLine - 1, 1, -1 do
        local indent, className = lines[lineNo]:match("^(%s*)class%s+([%w_]+)")
        if className ~= nil then
            local indentLen = #indent
            if indentLen < indentLimit then
                table.insert(parts, 1, className)
                indentLimit = indentLen
            end
        end
    end

    return path .. "::" .. table.concat(parts, "::")
end

function pytestFile(bp)
    local path = currentFile(bp)
    if path == nil then
        return
    end

    copyCommand("run_pytest.sh " .. shellQuote(path))
end

function pytestNode(bp)
    local nodeid = currentPythonTestNodeId(bp)
    if nodeid == nil then
        return
    end

    copyCommand("run_pytest.sh " .. shellQuote(nodeid))
end

function pytestRetry(bp)
    copyCommand("run_pytest.sh --retry")
end

function init()
    config.MakeCommand("pytestfile", pytestFile, config.NoComplete)
    config.MakeCommand("pytestnode", pytestNode, config.NoComplete)
    config.MakeCommand("pytestretry", pytestRetry, config.NoComplete)
end
