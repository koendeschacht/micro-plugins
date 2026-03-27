VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")

function fzfOpen(bp)
    local output, err = shell.RunInteractiveShell("sh -c 'fd --type f | fzf'", false, true)
    if err ~= nil then
        -- user cancelled or fzf failed
        return
    end
    local file = output:match("^%s*(.-)%s*$")  -- trim whitespace
    if file == "" then
        return
    end
    local buf, bufErr = buffer.NewBufferFromFile(file)
    if bufErr ~= nil then
        micro.InfoBar():Error("fzf: could not open " .. file)
        return
    end
    bp:PushJump()
    bp:OpenBuffer(buf)
end

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
        micro.InfoBar():Error("fzf: could not open " .. file)
        return
    end
    bp:PushJump()
    bp:OpenBuffer(buf)
    bp:GotoLoc(buffer.Loc(0, line * 1 - 1))
    bp:Center()
end

function init()
    config.MakeCommand("fzf", fzfOpen, config.NoComplete)
    config.MakeCommand("fzfgrep", fzfGrep, config.NoComplete)
    config.TryBindKey("Ctrl-p", "command:fzf", false)
    config.TryBindKey("Alt-g", "command:fzfgrep", false)
end
