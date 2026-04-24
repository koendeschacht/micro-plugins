VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local go_os = import("os")

local function shellQuote(text)
    return "'" .. string.gsub(text, "'", "'\\''") .. "'"
end

local function commandExists(cmd)
    local _, err = shell.RunCommand("sh -c 'command -v " .. cmd .. " >/dev/null 2>&1'")
    return err == nil
end

local function copyToClipboard(text)
    local shellPayload = "printf '%s' " .. shellQuote(text)
    local commands = {
        {
            binary = "wl-copy",
            command = "sh -c " .. shellQuote("nohup sh -c " .. shellQuote(shellPayload .. " | wl-copy") .. " </dev/null >/dev/null 2>&1 &"),
        },
        {
            binary = "pbcopy",
            command = "sh -c " .. shellQuote(shellPayload .. " | pbcopy"),
        },
        {
            binary = "xclip",
            command = "sh -c " .. shellQuote("nohup sh -c " .. shellQuote(shellPayload .. " | xclip -selection clipboard") .. " </dev/null >/dev/null 2>&1 &"),
        },
    }

    for _, candidate in ipairs(commands) do
        if commandExists(candidate.binary) then
            local _, err = shell.RunCommand(candidate.command)
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

    copyCommand("uv run pytest " .. shellQuote(path))
end

function pytestNode(bp)
    local nodeid = currentPythonTestNodeId(bp)
    if nodeid == nil then
        return
    end

    copyCommand("uv run pytest " .. shellQuote(nodeid))
end

function pytestRetry(bp)
    copyCommand("run_pytest.sh --retry")
end

function uvRunFile(bp)
    local path = currentFile(bp)
    if path == nil then
        return
    end

    copyCommand("uv run " .. shellQuote(path))
end

function copyRelPath(bp)
    local path = currentFile(bp)
    if path == nil then
        return
    end

    local relpath, err = shell.RunCommand("realpath --relative-to=. " .. shellQuote(path))
    if err ~= nil then
        copyCommand(path)
        return
    end

    copyCommand(relpath:gsub("%s+$", ""))
end

function copyAbsPath(bp)
    local path = currentFile(bp)
    if path == nil then
        return
    end

    copyCommand(path)
end

function kittyTerminal(bp)
    if os.getenv("KITTY_WINDOW_ID") == nil or os.getenv("KITTY_WINDOW_ID") == "" then
        micro.InfoBar():Error("pythondev: not running inside kitty")
        return
    end

    if os.getenv("KITTY_LISTEN_ON") == nil or os.getenv("KITTY_LISTEN_ON") == "" then
        micro.InfoBar():Error("pythondev: kitty remote control unavailable")
        return
    end

    if not commandExists("kitty") then
        micro.InfoBar():Error("pythondev: kitty command not found")
        return
    end

    local cwd, cwdErr = go_os.Getwd()
    if cwdErr ~= nil then
        micro.InfoBar():Error("pythondev: could not determine working directory")
        return
    end

    local output, err = shell.ExecCommand("kitty", "@", "launch", "--type=window", "--cwd=" .. cwd)
    if err ~= nil then
        local message = output
        if message == nil or message == "" then
            message = err.Error()
        end
        micro.InfoBar():Error("pythondev: " .. message)
        return
    end
end

function init()
    config.MakeCommand("copyrelpath", copyRelPath, config.NoComplete)
    config.MakeCommand("copyabspath", copyAbsPath, config.NoComplete)
    config.MakeCommand("kittyterm", kittyTerminal, config.NoComplete)
    config.MakeCommand("uvrunfile", uvRunFile, config.NoComplete)
    config.MakeCommand("pytestfile", pytestFile, config.NoComplete)
    config.MakeCommand("pytestnode", pytestNode, config.NoComplete)
    config.MakeCommand("pytestretry", pytestRetry, config.NoComplete)
    config.RegisterActionLabel("command:copyrelpath", "relative path")
    config.RegisterActionLabel("command:copyabspath", "absolute path")
    config.RegisterActionLabel("command:kittyterm", "terminal")
    config.RegisterActionLabel("command:uvrunfile", "run")
    config.RegisterActionLabel("command:pytestfile", "test file")
    config.RegisterActionLabel("command:pytestnode", "test function")
    config.RegisterActionLabel("command:pytestretry", "test retry")
end
