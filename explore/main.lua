VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")

local function shellQuote(text)
    return "'" .. string.gsub(text, "'", "'\\''") .. "'"
end

local microBanner = [[
_  _ _ ____ ____ ____ 
|\/| | |    |__/ |  | 
|  | | |___ |  \ |__| 
                      	
]]

local function isDirectory(path)
    if path == nil or path == "" then
        return false
    end

    local _, err = shell.RunCommand("sh -c " .. shellQuote("test -d " .. shellQuote(path)))
    return err == nil
end

local function bufferDir(bp)
    if bp == nil or bp.Buf == nil then
        return "."
    end

    local absPath = bp.Buf.AbsPath
    if absPath == nil or absPath == "" then
        return "."
    end

    if isDirectory(absPath) then
        return absPath
    end

    return absPath:match("^(.*)/[^/]*$") or "."
end

function shellExplore(bp)
    local dir = bufferDir(bp)

    local tmprc = "/tmp/micro_explorer_rc"
    local tmpresult = "/tmp/micro_explorer_result"

    os.remove(tmpresult)

    local f = io.open(tmprc, "w")
    f:write("export MICRO_SHELL=1\n")
    f:write("[ -f ~/.bashrc ] && source ~/.bashrc\n")
    f:write("cd " .. shellQuote(dir) .. "\n")
    f:write("clear\n")
    f:write("printf '%s\\n' " .. shellQuote(microBanner) .. "\n")
    f:write("l\n")
    f:write("open() { realpath \"$1\" > " .. shellQuote(tmpresult) .. "; exit; }\n")
    f:close()

    shell.RunInteractiveShell("bash --rcfile " .. shellQuote(tmprc), false, false)

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
    config.RegisterActionLabel("command:explore", "explore")
    config.TryBindKey("Ctrl-o", "command:explore", false)
end
