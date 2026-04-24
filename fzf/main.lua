VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local go_os = import("os")
local filepath = import("path/filepath")

local fzfBin = os.getenv("HOME") .. "/config/micro_plugins/fzf/fzf"
local fzfColors = "--color=bg:#222436,bg+:#2d3f76,fg:#c8d3f5,fg+:#c8d3f5,hl:#82aaff,hl+:#86e1fc," ..
    "border:#5f9dc3,preview-border:#5f9dc3,prompt:#ffc777,pointer:#ff757f,marker:#c099ff," ..
    "spinner:#86e1fc,info:#828bb8,header:#636da6"
local lastQuery = ""
local home = os.getenv("HOME") or ""
local stateHome = os.getenv("XDG_STATE_HOME")
if stateHome == nil or stateHome == "" then
    stateHome = filepath.Join(home, ".local", "state")
end
local recentDir = filepath.Join(stateHome, "micro", "recent-files")
local startupRoot, _ = go_os.Getwd()

local function commandExists(cmd)
    local _, err = shell.RunCommand("sh -c 'command -v " .. cmd .. " >/dev/null 2>&1'")
    return err == nil
end

local function fileSearchCommand()
    local flags = "--type f --hidden --no-ignore" ..
        " --exclude .git --exclude node_modules --exclude .venv" ..
        " --exclude venv --exclude dist --exclude build" ..
        " --exclude __pycache__ --exclude .mypy_cache" ..
        " --exclude .ruff_cache --exclude .hypothesis" ..
        " --exclude '*.pyc'"
    if commandExists("fd") then
        return "fd " .. flags
    end

    if commandExists("fdfind") then
        return "fdfind " .. flags
    end

    return nil
end

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

local function parseOutput(text)
    local query, selection = text:match("^([^\n]*)\n?(.*)$")
    if query == nil then
        return "", ""
    end

    selection = (selection or ""):gsub("\n+$", "")
    return query, selection
end

local function rankCommand(fileSearch, recentFile)
    local awkScript = "BEGIN { while ((getline line < recent) > 0) recent_rank[line] = ++recent_count; close(recent) } " ..
        "{ display = $0; sub(/^\\.\\//, \"\", display); path = tolower(display); score = 100; " ..
        "if (display in recent_rank) score = recent_rank[display]; " ..
        "else { " ..
        "if (path ~ /(^|\\/)(app|lib)\\//) score = score - 10; " ..
        "else if (path ~ /(^|\\/)(pkg|python)\\//) score = score - 5; " ..
        "if (path ~ /(^|\\/)(tests?|__tests__|spec)\\// || path ~ /(_test\\.|_spec\\.|\\.test\\.|\\.spec\\.)/) score = score + 20; " ..
        "} " ..
        "printf \"%04d %s\\n\", score, display; }"
    return fileSearch ..
        " | awk -v recent=" .. shellQuote(recentFile) .. " " .. shellQuote(awkScript) ..
        " | sort -k1,1n -k2,2 | cut -c6-"
end

function fzfOpen(bp)
    local fileSearch = fileSearchCommand()
    if fileSearch == nil then
        micro.InfoBar():Error("fzf: required command not found: fd or fdfind")
        return
    end

    local _, fzfErr = shell.RunCommand("sh -c 'test -x " .. shellQuote(fzfBin) .. "'")
    if fzfErr ~= nil then
        micro.InfoBar():Error("fzf: required executable not found: " .. fzfBin)
        return
    end

    if recentfiles == nil or recentfiles.recentfiles_getList == nil then
        micro.InfoBar():Error("fzf: recentfiles plugin is unavailable")
        return
    end

    local list = recentfiles.recentfiles_getList()
    local tempRecentFile = os.tmpname()
    local f = io.open(tempRecentFile, "w")
    if f == nil then
        micro.InfoBar():Error("fzf: could not prepare recent file list")
        return
    end
    for _, entry in ipairs(list) do
        f:write(entry .. "\n")
    end
    f:close()

    local resultPath = os.tmpname()
    local fzfCmd = '"' .. fzfBin .. '" --layout=reverse --tiebreak=index --print-query --query=' .. shellQuote(lastQuery) .. ' ' .. fzfColors
    local shellCmd = "script -q -c " .. shellQuote(rankCommand(fileSearch, tempRecentFile) .. " | " .. fzfCmd .. " > " .. shellQuote(resultPath)) .. " /dev/null"
    local _, err = shell.RunInteractiveShell(shellCmd, false, false)
    local output = ""
    local resultFile = io.open(resultPath, "r")
    if resultFile ~= nil then
        output = resultFile:read("*a") or ""
        resultFile:close()
    end
    os.remove(resultPath)
    if tempRecentFile ~= nil then
        os.remove(tempRecentFile)
    end
    local query, file = parseOutput(output)
    lastQuery = query
    if err ~= nil then
        return
    end
    if file == "" then
        return
    end
    local buf, bufErr = buffer.NewBufferFromFile(file)
    if bufErr ~= nil then
        micro.InfoBar():Error("fzf: could not open " .. file)
        return
    end
    micro.After(0, function()
        bp:PushJump()
        bp:OpenBuffer(buf)
        if bp.Relocate then
            bp:Relocate()
        end
    end)
end

function init()
    config.MakeCommand("fzf", fzfOpen, config.NoComplete)
    config.RegisterActionLabel("command:fzf", "files")
    config.TryBindKey("Ctrl-p", "command:fzf", false)
end
