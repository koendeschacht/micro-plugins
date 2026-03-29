VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")

local fzfBin = os.getenv("HOME") .. "/config/micro_plugins/fzfgrep/fzf"
local fzfColors = "--color=bg:#222436,bg+:#2d3f76,fg:#c8d3f5,fg+:#c8d3f5,hl:#82aaff,hl+:#86e1fc," ..
    "border:#5f9dc3,preview-border:#5f9dc3,prompt:#ffc777,pointer:#ff757f,marker:#c099ff," ..
    "spinner:#86e1fc,info:#828bb8,header:#636da6"

local function commandExists(cmd)
    local _, err = shell.RunCommand("sh -c 'command -v " .. cmd .. " >/dev/null 2>&1'")
    return err == nil
end

local function shellQuote(text)
    return "'" .. string.gsub(text, "'", "'\\''") .. "'"
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

    local rgCmd = "rg --line-number --no-heading --color=always " ..
        "--colors \"path:fg:130,170,255\" --colors \"line:fg:255,199,119\" " ..
        "--colors \"match:fg:200,211,245\" --colors \"match:style:nobold\" " ..
        "--glob \"!.git\" --glob \"!node_modules\" --glob \"!.venv\" " ..
        "--glob \"!venv\" --glob \"!dist\" --glob \"!build\" " ..
        "--glob \"!__pycache__\" --glob \"!.mypy_cache\" ."
    local previewCmd = "sh -c 'line=\"$2\"; lines=" .. previewLines .. "; half=$(( lines / 2 )); " ..
        "start=$(( line > half ? line - half : 1 )); end=$(( start + lines - 1 )); " ..
        "batcat --color=always --style=numbers --line-range \"${start}:${end}\" " ..
        "--highlight-line \"$line\" \"$1\"' sh {1} {2}"
    local fzfCmd = '"' .. fzfBin .. '" --ansi --layout=reverse --border ' ..
        '--border-label=" grep " --info=inline --prompt="Rg> " ' ..
        '--delimiter=: --nth=3.. ' ..
        fzfColors .. ' ' ..
        '--preview=' .. shellQuote(previewCmd) .. ' ' ..
        '--preview-window=right:55%,border-left'
    local resultPath = os.tmpname()
    local shellCmd = "script -q -c " .. shellQuote(rgCmd .. " | " .. fzfCmd .. " > " .. shellQuote(resultPath)) .. " /dev/null"
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
    if err ~= nil then
        return
    end
    local trimmed = output:match("^%s*(.-)%s*$")
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
    config.TryBindKey("Alt-g", "command:fzfgrep", false)
end
