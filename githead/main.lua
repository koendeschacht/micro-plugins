VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")

local stateByPath = {}

local function shellQuote(text)
    return "'" .. string.gsub(text, "'", "'\\''") .. "'"
end

local function trim(text)
    if text == nil then
        return ""
    end
    return text:match("^%s*(.-)%s*$")
end

local function parentDir(path)
    return path:match("^(.*)/[^/]*$") or "."
end

local function splitLines(text)
    local normalized = text:gsub("\r\n", "\n")
    if normalized == "" then
        return {}
    end

    local lines = {}
    for line in (normalized .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end

    if normalized:sub(-1) == "\n" and #lines > 0 then
        table.remove(lines)
    end
    return lines
end

local function joinLines(lines)
    return table.concat(lines, "\n")
end

local function runCommand(command)
    local output, err = shell.RunCommand("sh -c " .. shellQuote(command))
    if err ~= nil then
        return nil, err
    end
    return output, nil
end

local function gitInfo(absPath)
    if absPath == nil or absPath == "" then
        return nil
    end

    if stateByPath[absPath] ~= nil then
        return stateByPath[absPath] or nil
    end

    local root, rootErr = runCommand("git -C " .. shellQuote(parentDir(absPath)) .. " rev-parse --show-toplevel")
    if rootErr ~= nil then
        stateByPath[absPath] = false
        return nil
    end

    root = trim(root)
    local prefix = root .. "/"
    if absPath:sub(1, #prefix) ~= prefix then
        stateByPath[absPath] = false
        return nil
    end

    local relPath = absPath:sub(#prefix + 1)
    local _, trackedErr = runCommand("git -C " .. shellQuote(root) .. " ls-files --error-unmatch -- " .. shellQuote(relPath))
    if trackedErr ~= nil then
        stateByPath[absPath] = false
        return nil
    end

    local info = {
        root = root,
        relPath = relPath,
    }
    stateByPath[absPath] = info
    return info
end

local function headContents(info)
    if type(info) ~= "table" then
        return ""
    end

    local output, err = runCommand("git -C " .. shellQuote(info.root) .. " cat-file -p " .. shellQuote("HEAD:" .. info.relPath))
    if err ~= nil then
        return ""
    end
    return output
end

local function syncDiffBase(buf)
    if buf == nil or buf.AbsPath == nil or buf.AbsPath == "" then
        return
    end

    local info = gitInfo(buf.AbsPath)
    if info == nil then
        buf:SetDiffBase(nil)
        buf:SetOptionNative("diffgutter", false)
        return
    end

    buf:SetDiffBase(headContents(info))
    buf:SetOptionNative("diffgutter", true)
end

local function parseHunks(diffText)
    local hunks = {}
    for line in diffText:gmatch("[^\n]+") do
        local oldStart, oldCount, newStart, newCount = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
        if oldStart ~= nil then
            table.insert(hunks, {
                oldStart = tonumber(oldStart),
                oldCount = oldCount == "" and 1 or tonumber(oldCount),
                newStart = tonumber(newStart),
                newCount = newCount == "" and 1 or tonumber(newCount),
            })
        end
    end
    return hunks
end

local function hunkAtLine(hunks, lineNo)
    for _, hunk in ipairs(hunks) do
        local startLine = hunk.newStart
        local endLine = hunk.newCount == 0 and hunk.newStart or (hunk.newStart + hunk.newCount - 1)
        if lineNo >= startLine and lineNo <= endLine then
            return hunk
        end
    end
    return nil
end

local function bufferLines(buf)
    local lines = {}
    for i = 0, buf:LinesNum() - 1 do
        table.insert(lines, buf:Line(i))
    end
    return lines
end

local function replaceWholeBuffer(bp, lines, cursorLine)
    local cur = bp.Buf:GetActiveCursor()
    local start = bp.Buf:Start()
    local finish = bp.Buf:End()

    cur:GotoLoc(start)
    cur:SetSelectionStart(start)
    cur:SetSelectionEnd(finish)
    cur:DeleteSelection()
    cur:ResetSelection()

    local text = joinLines(lines)
    if text ~= "" then
        bp.Buf:insert(start, text)
    end

    local targetLine = math.max(0, math.min(cursorLine - 1, bp.Buf:LinesNum() - 1))
    cur:GotoLoc(buffer.Loc(0, targetLine))
    bp:Center()
    if bp.Relocate then
        bp:Relocate()
    end
end

function resetHunk(bp)
    if bp == nil or bp.Buf == nil or bp.Buf.AbsPath == nil or bp.Buf.AbsPath == "" then
        micro.InfoBar():Error("githead: current buffer is not a file")
        return
    end

    local info = gitInfo(bp.Buf.AbsPath)
    if info == nil then
        micro.InfoBar():Error("githead: file is not tracked in git")
        return
    end

    local diffText, diffErr = runCommand("git -C " .. shellQuote(info.root) .. " diff --no-color --unified=0 HEAD -- " .. shellQuote(info.relPath))
    if diffErr ~= nil then
        micro.InfoBar():Error("githead: could not read git diff")
        return
    end

    local cursorLine = bp.Buf:GetActiveCursor().Y + 1
    local hunk = hunkAtLine(parseHunks(diffText), cursorLine)
    if hunk == nil then
        micro.InfoBar():Message("githead: no diff hunk at cursor")
        return
    end

    local headLines = splitLines(headContents(info))
    local replacement = {}
    for lineNo = hunk.oldStart, hunk.oldStart + hunk.oldCount - 1 do
        table.insert(replacement, headLines[lineNo] or "")
    end

    local current = bufferLines(bp.Buf)
    local updated = {}
    for lineNo = 1, hunk.newStart - 1 do
        table.insert(updated, current[lineNo])
    end
    for _, line in ipairs(replacement) do
        table.insert(updated, line)
    end
    for lineNo = hunk.newStart + hunk.newCount, #current do
        table.insert(updated, current[lineNo])
    end

    replaceWholeBuffer(bp, updated, hunk.newStart)
    micro.InfoBar():Message("githead: reset hunk")
end

function onBufferOpen(buf)
    syncDiffBase(buf)
end

function onSetActive(bp)
    if bp ~= nil and bp.Buf ~= nil then
        syncDiffBase(bp.Buf)
    end
end

function init()
    config.MakeCommand("resethunk", resetHunk, config.NoComplete)
end
