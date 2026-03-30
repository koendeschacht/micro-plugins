VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")

function shellExplore(bp)
    local absPath = bp.Buf.AbsPath
    local dir = absPath:match("^(.*)/[^/]*$") or "."

    local tmprc = "/tmp/micro_explorer_rc"
    local tmpresult = "/tmp/micro_explorer_result"

    os.execute("rm -f " .. tmpresult)

    local f = io.open(tmprc, "w")
    f:write("[ -f ~/.bashrc ] && source ~/.bashrc\n")
    f:write("cd " .. dir .. "\n")
    f:write("clear\n")
    f:write("l\n")
    f:write("open() { realpath \"$1\" > " .. tmpresult .. "; exit; }\n")
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
    config.MakeCommand("explore", shellExplore, config.NoComplete)
    config.TryBindKey("Ctrl-o", "command:explore", false)
end
