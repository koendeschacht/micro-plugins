VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")

function fzfGrep(bp)
    local output, err = shell.RunInteractiveShell(
        "sh -c 'rg --line-number --no-heading --color=always . | fzf --ansi'",
        false, true)
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
    local buf, bufErr = buffer.NewBufferFromFile(file)
    if bufErr ~= nil then
        micro.InfoBar():Error("fzfgrep: could not open " .. file)
        return
    end
    bp:PushJump()
    bp:OpenBuffer(buf)
    bp:GotoLoc(buffer.Loc(0, line * 1 - 1))
    bp:Center()
end

function init()
    config.MakeCommand("fzfgrep", fzfGrep, config.NoComplete)
    config.TryBindKey("Alt-g", "command:fzfgrep", false)
end
