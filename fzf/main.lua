VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")

local fzfBin = os.getenv("HOME") .. "/config/micro_plugins/fzf/fzf"
local fzfColors = "--color=bg:#222436,bg+:#2d3f76,fg:#c8d3f5,fg+:#c8d3f5,hl:#82aaff,hl+:#86e1fc," ..
    "border:#5f9dc3,preview-border:#5f9dc3,prompt:#ffc777,pointer:#ff757f,marker:#c099ff," ..
    "spinner:#86e1fc,info:#828bb8,header:#636da6"

local function commandExists(cmd)
    local _, err = shell.RunCommand("sh -c 'command -v " .. cmd .. " >/dev/null 2>&1'")
    return err == nil
end

local function fileSearchCommand()
    if commandExists("fd") then
        return "fd --type f"
    end

    if commandExists("fdfind") then
        return "fdfind --type f"
    end

    return nil
end

local function shellQuote(text)
    return "'" .. string.gsub(text, "'", "'\\''") .. "'"
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

    local resultPath = os.tmpname()
    local fzfCmd = '"' .. fzfBin .. '" --layout=reverse ' .. fzfColors
    local shellCmd = "script -q -c " .. shellQuote(fileSearch .. " | " .. fzfCmd .. " > " .. shellQuote(resultPath)) .. " /dev/null"
    local _, err = shell.RunInteractiveShell(shellCmd, false, false)
    local output = ""
    local resultFile = io.open(resultPath, "r")
    if resultFile ~= nil then
        output = resultFile:read("*a") or ""
        resultFile:close()
    end
    os.remove(resultPath)
    if err ~= nil then
        return
    end
    local file = output:match("^%s*(.-)%s*$")
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
    config.TryBindKey("Ctrl-p", "command:fzf", false)
end
