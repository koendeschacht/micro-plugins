VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local go_os = import("os")
local filepath = import("path/filepath")

local fzfBin = os.getenv("HOME") .. "/config/micro_plugins/fzfgrep/fzf"
local batTheme = "TokyoNight Moon.micro"
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

function fzfGrep(bp)
    if not commandExists("rg") then
        micro.InfoBar():Error("fzfgrep: required command not found: rg")
        return
    end

    if not commandExists("batcat") then
        micro.InfoBar():Error("fzfgrep: required command not found: batcat")
        return
    end

    local _, fzfErr = shell.RunCommand("sh -c 'test -x " .. shellQuote(fzfBin) .. "'")
    if fzfErr ~= nil then
        micro.InfoBar():Error("fzfgrep: required executable not found: " .. fzfBin)
        return
    end

    local previewLines = 40
    if bp.BWindow ~= nil and bp.BWindow.Height ~= nil then
        previewLines = math.max(10, bp.BWindow.Height - 1)
    end

    local rgPrefix = "rg --smart-case --line-number --no-heading --color=always " ..
        "--colors \"path:fg:130,170,255\" --colors \"line:fg:255,199,119\" " ..
        "--colors \"match:fg:200,211,245\" --colors \"match:style:nobold\" " ..
        "--hidden --no-ignore " ..
        "--glob \"!.git\" --glob \"!node_modules\" --glob \"!.venv\" " ..
        "--glob \"!venv\" --glob \"!dist\" --glob \"!build\" " ..
        "--glob \"!__pycache__\" --glob \"!.mypy_cache\" -- "
    local awkScript = "BEGIN { while ((getline recent_line < recent) > 0) recent_rank[recent_line] = ++recent_count; close(recent) } " ..
        "{ path = $1; gsub(/\\033\\[[0-9;]*m/, \"\", path); sub(/^\\.\\//, \"\", path); score = 1000; " ..
        "if (path in recent_rank) score = recent_rank[path]; printf \"%04d:%s\\n\", score, $0; }"
    local rankCmd = "awk -v recent=" .. shellQuote(recentPath()) .. " " .. shellQuote(awkScript) .. " | " ..
        "sort -t: -k1,1n -k2,2 | cut -d: -f2-"
    local reloadScript = "query=\"$1\"; " ..
        "if [ -z \"$query\" ]; then exit 0; fi; " ..
        rgPrefix .. "\"$query\" . | " .. rankCmd .. " || true"
    local reloadCmd = "sh -c " .. shellQuote(reloadScript) .. " sh {q}"
    local previewCmd = "sh -c 'line=\"$2\"; lines=" .. previewLines .. "; half=$(( lines / 2 )); " ..
        "start=$(( line > half ? line - half : 1 )); end=$(( start + lines - 1 )); " ..
        "batcat --theme=\"" .. batTheme .. "\" --color=always --style=numbers --line-range \"${start}:${end}\" " ..
        "--highlight-line \"$line\" \"$1\"' sh {1} {2}"
    local fzfCmd = '"' .. fzfBin .. '" --ansi --disabled --layout=reverse --border ' ..
        '--print-query --query=' .. shellQuote(lastQuery) .. ' ' ..
        '--border-label=" grep " --info=inline --prompt="Rg> " ' ..
        '--delimiter=: --nth=3.. ' ..
        fzfColors .. ' ' ..
        '--bind=' .. shellQuote('start:reload:' .. reloadCmd) .. ' ' ..
        '--bind=' .. shellQuote('change:reload:' .. reloadCmd) .. ' ' ..
        '--preview=' .. shellQuote(previewCmd) .. ' ' ..
        '--preview-window=right:55%,border-left'
    local resultPath = os.tmpname()
    local shellCmd = "script -q -c " .. shellQuote(fzfCmd .. " > " .. shellQuote(resultPath)) .. " /dev/null"
    local _, err = shell.RunInteractiveShell(
        shellCmd,
        false, false)
    local output = ""
    local resultFile = io.open(resultPath, "r")
    if resultFile ~= nil then
        output = resultFile:read("*a") or ""
        resultFile:close()
    end
    os.remove(resultPath)
    local query, trimmed = parseOutput(output)
    lastQuery = query
    if err ~= nil then
        return
    end
    if trimmed == "" then
        return
    end
    local file, line = trimmed:match("^([^:]+):(%d+):")
    if file == nil then
        return
    end
    micro.After(0, function()
        local buf, bufErr = buffer.NewBufferFromFile(file)
        if bufErr ~= nil then
            micro.InfoBar():Error("fzfgrep: could not open " .. file)
            return
        end
        bp:PushJump()
        bp:OpenBuffer(buf)
        bp:GotoLoc(buffer.Loc(0, line * 1 - 1))
        bp:Center()
        if bp.Relocate then
            bp:Relocate()
        end
    end)
end

function init()
    config.MakeCommand("fzfgrep", fzfGrep, config.NoComplete)
    config.RegisterActionLabel("command:fzfgrep", "grep")
    config.TryBindKey("Alt-g", "command:fzfgrep", false)
end
