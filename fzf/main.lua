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

function shellExplore(bp)
    local absPath = bp.Buf.AbsPath
    local dir = absPath:match("^(.*)/[^/]*$") or "."

    local tmprc = "/tmp/micro_explorer_rc"
    local tmpresult = "/tmp/micro_explorer_result"

    os.execute("rm -f " .. tmpresult)

    local f = io.open(tmprc, "w")
    f:write("[ -f ~/.bashrc ] && source ~/.bashrc\n")
    f:write("cd " .. dir .. "\n")
    f:write("open() { echo \"$1\" > " .. tmpresult .. "; exit; }\n")
    f:close()

    shell.RunInteractiveShell("bash --rcfile " .. tmprc, false, false)

    local rf = io.open(tmpresult, "r")
    if rf then
        local path = rf:read("*l")
        rf:close()
        if path and path ~= "" then
            local buf, bufErr = buffer.NewBufferFromFile(path)
            if bufErr ~= nil then
                micro.InfoBar():Error("explore: could not open " .. path)
                return
            end
            bp:PushJump()
            bp:OpenBuffer(buf)
        end
    end
end

function init()
    config.MakeCommand("fzf", fzfOpen, config.NoComplete)
    config.MakeCommand("fzfgrep", fzfGrep, config.NoComplete)
    config.MakeCommand("explore", shellExplore, config.NoComplete)
    config.TryBindKey("Ctrl-p", "command:fzf", false)
    config.TryBindKey("Alt-g", "command:fzfgrep", false)
    config.TryBindKey("Ctrl-b", "command:explore", false)
end
