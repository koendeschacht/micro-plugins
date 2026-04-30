VERSION = "0.1.0"

local micro = import("micro")
local buffer = import("micro/buffer")
local config = import("micro/config")
local shell = import("micro/shell")
local filepath = import("path/filepath")
local strings = import("strings")

local PLUGIN = "gitstatus"
local cache = {}
local inflight = {}
local cacheTTLSeconds = 20
local styleMarker = string.char(31)
local emptyStatus = {
    branch = "",
    ahead = 0,
    behind = 0,
    dirty = false,
}

local function trim(text)
    return strings.TrimSpace(text or "")
end

local function statusKey(buf)
    if buf == nil or buf.Type.Kind == buffer.BTInfo or buf.AbsPath == nil or buf.AbsPath == "" then
        return nil
    end
    return filepath.Dir(buf.AbsPath)
end

local function invalidate(buf)
    local key = statusKey(buf)
    if key ~= nil then
        cache[key] = nil
    end
end

local function emptyCachedStatus(expiresAt)
    return {
        branch = emptyStatus.branch,
        ahead = emptyStatus.ahead,
        behind = emptyStatus.behind,
        dirty = emptyStatus.dirty,
        expiresAt = expiresAt,
    }
end

local function parseGitStatus(output)
    local branch = ""
    local detached = false
    local hash = ""
    local ahead = 0
    local behind = 0
    local dirty = false

    for line in string.gmatch(output or "", "[^\r\n]+") do
        if string.sub(line, 1, 14) == "# branch.head " then
            branch = trim(string.sub(line, 15))
            if branch == "(detached)" then
                detached = true
            end
        elseif string.sub(line, 1, 13) == "# branch.oid " then
            hash = trim(string.sub(line, 14))
        elseif string.sub(line, 1, 12) == "# branch.ab " then
            local plus, minus = string.match(line, "%+(%d+) %-(%d+)")
            ahead = tonumber(plus) or 0
            behind = tonumber(minus) or 0
        else
            local prefix = string.sub(line, 1, 1)
            if prefix == "1" or prefix == "2" or prefix == "u" or prefix == "?" then
                dirty = true
            end
        end
    end

    if detached then
        if hash ~= "" and hash ~= "(initial)" then
            branch = string.sub(hash, 1, 7)
        else
            branch = "detached"
        end
    end

    return {
        branch = branch,
        ahead = ahead,
        behind = behind,
        dirty = dirty,
    }
end

local function refreshPaneForBuf(buf)
    local bp = micro.CurPane()
    if bp == nil or bp.Buf ~= buf then
        return
    end
    if bp.Relocate then
        bp:Relocate()
    end
end

local function refreshGitStatus(buf, key)
    if key == nil or inflight[key] then
        return
    end

    inflight[key] = true
    shell.JobSpawn("git", {"-C", key, "status", "--porcelain=2", "--branch"}, nil, nil, function(output, args)
        local targetBuf = args[1]
        local targetKey = args[2]
        inflight[targetKey] = nil

        local status = parseGitStatus(output)
        if status.branch == nil or status.branch == "" then
            cache[targetKey] = emptyCachedStatus(os.time() + cacheTTLSeconds)
        else
            status.expiresAt = os.time() + cacheTTLSeconds
            cache[targetKey] = status
        end

        refreshPaneForBuf(targetBuf)
    end, buf, key)
end

local function readGitStatus(buf)
    local key = statusKey(buf)
    if key == nil then
        return nil
    end

    local now = os.time()
    local cached = cache[key]
    if cached ~= nil and cached.expiresAt ~= nil and cached.expiresAt >= now then
        return cached
    end

    refreshGitStatus(buf, key)
    return cached
end

local function stateStyle(status, buf)
    if status.dirty then
        return "statusline.git.dirty"
    end
    if status.ahead > 0 or status.behind > 0 then
        return "statusline.git.unsynced"
    end
    return "statusline.git.clean"
end

local function styled(text, styleName)
    if text == nil or text == "" or styleName == nil or styleName == "" then
        return text or ""
    end
    return styleMarker .. styleName .. styleMarker .. text .. styleMarker .. styleMarker
end

function init()
    micro.SetStatusInfoFn("gitstatus.branchstate")
end

function branchstate(buf)
    local status = readGitStatus(buf)
    if status == nil or status.branch == nil or status.branch == "" then
        return ""
    end

    return styled(status.branch, stateStyle(status, buf))
end

function onBufferOpen(buf)
    invalidate(buf)
    local key = statusKey(buf)
    refreshGitStatus(buf, key)
end

function onSave(bp)
    if bp ~= nil then
        invalidate(bp.Buf)
        refreshGitStatus(bp.Buf, statusKey(bp.Buf))
    end
end

function onSetActive(bp)
    if bp ~= nil then
        invalidate(bp.Buf)
        refreshGitStatus(bp.Buf, statusKey(bp.Buf))
    end
end
