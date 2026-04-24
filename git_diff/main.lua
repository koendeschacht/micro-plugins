VERSION = "0.3.20"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local util = import("micro/util")

local OWNER = "git_diff"
local LIST_BUFFER_NAME = "git_diff files"
local PERF_LOG_PATH = os.getenv("HOME") .. "/config/micro/git_diff_perf.log"
local BLAME_WIDTH = 40
local BLAME_REFRESH_DEBOUNCE_NS = 150000000
local BLAME_PALETTE = {
    "#7aa2f7",
    "#9ece6a",
    "#e0af68",
    "#bb9af7",
    "#7dcfff",
    "#f7768e",
    "#73daca",
    "#c0caf5",
}

local session = nil
local blame = nil
local nextChangedFile
local previousChangedFile
local openSessionFile
local sourcePane
local refreshChangedFiles
local bufferText
local jsonString
local tempFile
local perfSwitchSeq = 0
local perfContext = nil
local blameVersionSeq = 0
local blameSessionSeq = 0

local function paneAlive(bp)
    return bp ~= nil and bp.Buf ~= nil
end

local function isListBuffer(buf)
    return buf ~= nil and buf:GetName() == LIST_BUFFER_NAME
end

local function shellQuote(text)
    return "'" .. string.gsub(text, "'", "'\\''") .. "'"
end

local function perfNow()
    return micro.NanoTime()
end

local function perfMs(startNs)
    return (perfNow() - startNs) / 1000000
end

local function perfLog(message)
    local f = io.open(PERF_LOG_PATH, "a")
    if f == nil then
        return
    end
    f:write(os.date("%Y-%m-%d %H:%M:%S"), " ", message, "\n")
    f:close()
end

local function summarizeCommand(command)
    command = command:gsub("%s+", " ")
    if #command > 180 then
        return command:sub(1, 177) .. "..."
    end
    return command
end

local function setPerfContext(kind, path)
    perfSwitchSeq = perfSwitchSeq + 1
    perfContext = {
        id = perfSwitchSeq,
        kind = kind,
        path = path,
        startNs = perfNow(),
    }
    perfLog(string.format("context start id=%d kind=%s path=%s", perfContext.id, kind, path or ""))
end

local function perfContextTag()
    if perfContext == nil then
        return "ctx=none"
    end
    return string.format("ctx=%d kind=%s path=%s age_ms=%.1f", perfContext.id, perfContext.kind, perfContext.path or "", perfMs(perfContext.startNs))
end

local function shouldLogCallback()
    return perfContext ~= nil and perfMs(perfContext.startNs) < 3000
end

local function trim(text)
    if text == nil then
        return ""
    end
    return text:match("^%s*(.-)%s*$")
end

local function splitLines(text)
    local normalized = (text or ""):gsub("\r\n", "\n")
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

local function parentDir(path)
    return path:match("^(.*)/[^/]*$") or "."
end

local function runCommand(command)
    local startNs = perfNow()
    local output, err = shell.RunCommand("sh -c " .. shellQuote(command))
    perfLog(string.format("runCommand ms=%.1f ok=%s cmd=%s", perfMs(startNs), err == nil and "true" or "false", summarizeCommand(command)))
    if err ~= nil then
        return nil, err
    end
    return output, nil
end

local function nextBlameVersion()
    blameVersionSeq = blameVersionSeq + 1
    return blameVersionSeq
end

local function nextBlameSessionID()
    blameSessionSeq = blameSessionSeq + 1
    return blameSessionSeq
end

local function currentPane()
    local ok, bp = pcall(micro.CurPane)
    if not ok then
        return nil
    end
    return bp
end

local function activeBufPane(bp)
    if bp ~= nil then
        return bp
    end
    return currentPane()
end

local function gitRootFromPane(bp)
    if bp == nil or bp.Buf == nil or bp.Buf.AbsPath == nil or bp.Buf.AbsPath == "" then
        return nil, "git_diff: current buffer is not a file"
    end

    local root, err = runCommand("git -C " .. shellQuote(parentDir(bp.Buf.AbsPath)) .. " rev-parse --show-toplevel")
    if err ~= nil then
        return nil, "git_diff: current buffer is not in a git repository"
    end

    root = trim(root)
    if root == "" then
        return nil, "git_diff: could not determine repository root"
    end

    return root, nil
end

local function relativePath(root, absPath)
    local prefix = root .. "/"
    if absPath == root then
        return "."
    end
    if absPath:sub(1, #prefix) ~= prefix then
        return nil
    end
    return absPath:sub(#prefix + 1)
end

local function gitInfo(absPath, requireTracked)
    if absPath == nil or absPath == "" then
        return nil
    end

    local root, err = runCommand("git -C " .. shellQuote(parentDir(absPath)) .. " rev-parse --show-toplevel")
    if err ~= nil then
        return nil
    end

    root = trim(root)
    local relPath = relativePath(root, absPath)
    if relPath == nil or relPath == "." then
        return nil
    end

    if requireTracked then
        local _, trackedErr = runCommand("git -C " .. shellQuote(root) .. " ls-files --error-unmatch -- " .. shellQuote(relPath))
        if trackedErr ~= nil then
            return nil
        end
    end

    return {
        root = root,
        relPath = relPath,
    }
end

local function repoFile(absPath)
    if session == nil or absPath == nil or absPath == "" then
        return nil
    end
    if absPath == session.root then
        return nil
    end
    return relativePath(session.root, absPath)
end

local function trackedContents(root, target, relPath)
    local command = "git -C " .. shellQuote(root) .. " show " .. shellQuote(target .. ":" .. relPath)
    local text, err = runCommand(command)
    if err ~= nil then
        return ""
    end
    return text
end

local function blameContents(root, relPath, contentsPath)
    local command = "git -C " .. shellQuote(root) .. " blame --line-porcelain --contents " .. shellQuote(contentsPath) .. " -- " .. shellQuote(relPath)
    local text, err = runCommand(command)
    if err ~= nil then
        return nil, "git_diff: could not compute blame"
    end
    return text, nil
end

local function parseBlamePorcelain(text)
    local entries = {}
    local current = nil

    for _, line in ipairs(splitLines(text)) do
        local commit = line:match("^(%x+)%s+%d+%s+%d+")
        if commit ~= nil then
            current = {
                commit = commit,
                author = "",
                authorTime = nil,
                summary = "",
            }
        elseif current ~= nil then
            if line:sub(1, 1) == "\t" then
                table.insert(entries, current)
                current = nil
            else
                local key, value = line:match("^(%S+)%s(.*)$")
                if key == "author" then
                    current.author = value
                elseif key == "author-time" then
                    current.authorTime = tonumber(value)
                elseif key == "summary" then
                    current.summary = value
                end
            end
        end
    end

    return entries
end

local function blameColorGroup(commit)
    if commit == nil or commit:match("^0+$") then
        return "#f7768e"
    end

    local total = 0
    for i = 1, #commit do
        local digit = tonumber(commit:sub(i, i), 16)
        if digit ~= nil then
            total = total + digit
        end
    end
    return BLAME_PALETTE[(total % #BLAME_PALETTE) + 1]
end

local function blameShortCommit(commit)
    if commit == nil or commit == "" then
        return "????????"
    end
    if commit:match("^0+$") then
        return "WORKTREE"
    end
    return commit:sub(1, 8)
end

local function blameDate(entry)
    if entry.authorTime == nil then
        return "??????????"
    end
    return os.date("%Y-%m-%d", entry.authorTime)
end

local function blameHeaderText(entry)
    local author = trim(entry.author)
    if author == "" then
        author = "unknown"
    end

    return blameShortCommit(entry.commit) .. " " .. author .. " " .. blameDate(entry)
end

local function blameSummaryText(entry)
    local summary = trim(entry.summary)
    if summary == "" then
        summary = "(no summary)"
    end

    return summary
end

local function sidePaneLine(lineNo, text, group)
    return table.concat({
        '{"line":', tostring(lineNo),
        ',"text":', jsonString(text),
        ',"group":', jsonString(group),
        '}'
    })
end

local function sidePaneJSON(width, entries)
    return '{"width":' .. tostring(width) .. ',"entries":[' .. table.concat(entries, ",") .. ']}'
end

local function githubRepoURL(root)
    local remote, err = runCommand("git -C " .. shellQuote(root) .. " remote get-url origin")
    if err ~= nil then
        return nil
    end

    remote = trim(remote)
    if remote == "" then
        return nil
    end

    local path = remote:match("^git@github%.com:(.+)$")
    if path == nil then
        path = remote:match("^ssh://git@github%.com/(.+)$")
    end
    if path == nil then
        path = remote:match("^https://github%.com/(.+)$")
    end
    if path == nil then
        path = remote:match("^http://github%.com/(.+)$")
    end
    if path == nil then
        return nil
    end

    path = path:gsub("%.git$", "")
    return "https://github.com/" .. path
end

local function openURL(url)
    local _, err = runCommand("xdg-open " .. shellQuote(url) .. " >/dev/null 2>&1 &")
    return err == nil
end

local function blameSignature(buf)
    return table.concat({
        buf.AbsPath or "",
        tostring(buf:LinesNum()),
        tostring(buf:Size()),
    }, ":")
end

local function clearBlamePane(bp)
    if paneAlive(bp) and not isListBuffer(bp.Buf) then
        bp:SetSidePaneJSON("", nextBlameVersion())
    end
end

local function dropBlame()
    if blame ~= nil then
        clearBlamePane(blame.pane)
    end
    blame = nil
end

local function renderBlame(bp, sessionID, showErrors)
    bp = activeBufPane(bp)
    if bp == nil or bp.Buf == nil or bp.Buf.AbsPath == nil or bp.Buf.AbsPath == "" then
        if showErrors then
            micro.InfoBar():Error("git_diff: current buffer is not a file")
        end
        return false
    end

    if isListBuffer(bp.Buf) then
        if showErrors then
            micro.InfoBar():Error("git_diff: current buffer is not a file")
        end
        return false
    end

    local info = gitInfo(bp.Buf.AbsPath, true)
    if info == nil then
        if showErrors then
            micro.InfoBar():Error("git_diff: file is not tracked in git")
        end
        return false
    end

    local contentsPath = tempFile(bufferText(bp.Buf))
    if contentsPath == nil then
        if showErrors then
            micro.InfoBar():Error("git_diff: could not create temporary files")
        end
        return false
    end

    local blameText, blameErr = blameContents(info.root, info.relPath, contentsPath)
    os.remove(contentsPath)
    if blameErr ~= nil then
        if showErrors then
            micro.InfoBar():Error(blameErr)
        end
        return false
    end

    local parsed = parseBlamePorcelain(blameText)
    local serialized = {}
    local lineCommits = {}
    local previousCommit = nil
    for lineNo, entry in ipairs(parsed) do
        local text = ""
        if entry.commit ~= previousCommit then
            text = blameHeaderText(entry)
        elseif lineNo > 1 and parsed[lineNo - 1].commit == entry.commit and (lineNo == 2 or parsed[lineNo - 2].commit ~= entry.commit) then
            text = blameSummaryText(entry)
        end
        table.insert(serialized, sidePaneLine(lineNo - 1, text, blameColorGroup(entry.commit)))
        lineCommits[lineNo - 1] = entry.commit
        previousCommit = entry.commit
    end

    local version = nextBlameVersion()
    if not bp:SetSidePaneJSON(sidePaneJSON(BLAME_WIDTH, serialized), version) then
        return false
    end

    blame = {
        pane = bp,
        sessionID = sessionID,
        refreshToken = blame ~= nil and blame.sessionID == sessionID and blame.refreshToken or 0,
        root = info.root,
        absPath = bp.Buf.AbsPath,
        signature = blameSignature(bp.Buf),
        lineCommits = lineCommits,
    }
    return true
end

local function blameClickCommit(bp, te)
    if blame == nil or bp == nil or te == nil or blame.pane ~= bp then
        return nil
    end

    local view = bp:GetView()
    local bufView = bp:BufView()
    if view == nil or bufView == nil then
        return nil
    end

    local mx, my = te:Position()
    if my < bufView.Y or my >= bufView.Y + bufView.Height then
        return nil
    end

    local blameWidth = math.min(BLAME_WIDTH, bufView.X - view.X)
    if blameWidth <= 0 or mx < view.X or mx >= view.X + blameWidth then
        return nil
    end

    local loc = bp:LocFromVisual(buffer.Loc(mx, my))
    return blame.lineCommits ~= nil and blame.lineCommits[loc.Y] or nil
end

local function openClickedBlameCommit(bp, te)
    local commit = blameClickCommit(bp, te)
    if commit == nil then
        return false
    end

    if commit:match("^0+$") then
        micro.InfoBar():Message("git_diff: uncommitted lines do not have a GitHub commit")
        return true
    end

    local repoURL = githubRepoURL(blame.root)
    if repoURL == nil then
        micro.InfoBar():Error("git_diff: could not determine GitHub remote")
        return true
    end

    if not openURL(repoURL .. "/commit/" .. commit) then
        micro.InfoBar():Error("git_diff: could not open browser")
        return true
    end

    return true
end

local function scheduleBlameRefresh(bp, force)
    if blame == nil or bp == nil or blame.pane ~= bp or not paneAlive(bp) or isListBuffer(bp.Buf) then
        return
    end

    local signature = blameSignature(bp.Buf)
    if not force and blame.absPath == bp.Buf.AbsPath and blame.signature == signature then
        return
    end

    blame.refreshToken = (blame.refreshToken or 0) + 1
    local refreshToken = blame.refreshToken
    local sessionID = blame.sessionID
    micro.After(BLAME_REFRESH_DEBOUNCE_NS, function()
        if blame == nil or blame.sessionID ~= sessionID or blame.refreshToken ~= refreshToken then
            return
        end
        if not paneAlive(bp) or isListBuffer(bp.Buf) then
            return
        end
        renderBlame(bp, sessionID, false)
    end)
end

local function syncBlameForPane(bp, force)
    if blame == nil or bp == nil or blame.pane ~= bp then
        return
    end

    if not paneAlive(bp) or bp.Buf == nil or bp.Buf.AbsPath == nil or bp.Buf.AbsPath == "" or isListBuffer(bp.Buf) then
        dropBlame()
        return
    end

    if force or blame.absPath ~= bp.Buf.AbsPath then
        renderBlame(bp, blame.sessionID, false)
        return
    end

    scheduleBlameRefresh(bp, false)
end

local function syncHeadDiffBase(buf)
    if buf == nil or buf.AbsPath == nil or buf.AbsPath == "" or isListBuffer(buf) then
        return
    end

    local info = gitInfo(buf.AbsPath, true)
    if info == nil then
        buf:SetDiffBase(nil)
        buf:SetOptionNative("diffgutter", false)
        return
    end

    buf:SetDiffBase(trackedContents(info.root, "HEAD", info.relPath))
    buf:SetOptionNative("diffgutter", true)
end

local function listUntrackedFiles(root)
    local output, err = runCommand("git -C " .. shellQuote(root) .. " ls-files --others --exclude-standard")
    if err ~= nil then
        return {}
    end
    return splitLines(output)
end

local function changedFilesForTarget(root, target)
    local diffArgs = ""
    if target ~= ":0" then
        diffArgs = shellQuote(target)
    end

    local names, err = runCommand("git -C " .. shellQuote(root) .. " diff --name-status " .. diffArgs)
    if err ~= nil then
        return nil, err
    end

    local seen = {}
    local lines = {}
    for _, line in ipairs(splitLines(names)) do
        if line ~= "" then
            table.insert(lines, line)
            local rel = line:match("^[A-Z?]+%s+(.+)$")
            if rel ~= nil then
                seen[rel] = true
            end
        end
    end

    for _, rel in ipairs(listUntrackedFiles(root)) do
        if not seen[rel] then
            table.insert(lines, "??\t" .. rel)
        end
    end

    table.sort(lines)
    return lines, nil
end

local function statusIcon(status)
    if status == "A" or status == "??" then
        return ""
    end
    if status == "D" then
        return ""
    end
    return ""
end

local function formatFileListLine(line)
    local status, rel = line:match("^([A-Z?]+)%s+(.+)$")
    if status == nil or rel == nil then
        return line
    end
    return statusIcon(status) .. " " .. rel
end

local function listIconGroup(line)
    if line:match("^ ") then
        return "green"
    end
    if line:match("^ ") then
        return "red"
    end
    if line:match("^ ") then
        return "#e0af68"
    end
    return nil
end

bufferText = function(buf)
    local lines = {}
    for i = 0, buf:LinesNum() - 1 do
        table.insert(lines, buf:Line(i))
    end
    return joinLines(lines)
end

local function bufferLines(buf)
    local lines = {}
    for i = 0, buf:LinesNum() - 1 do
        table.insert(lines, buf:Line(i))
    end
    return lines
end

local function replaceWholeBuffer(buf, text)
    local wasReadonly = buf.Settings["readonly"]
    if wasReadonly then
        buf:SetOptionNative("readonly", false)
    end

    local cur = buf:GetActiveCursor()
    local start = buf:Start()
    local finish = buf:End()

    cur:GotoLoc(start)
    cur:SetSelectionStart(start)
    cur:SetSelectionEnd(finish)
    cur:DeleteSelection()
    cur:ResetSelection()

    if text ~= "" then
        buf:insert(start, text)
    end
    cur:GotoLoc(start)

    if wasReadonly then
        buf:SetOptionNative("readonly", true)
    end
end

local function resetCursorAfterReplace(bp, cursorLine)
    local cur = bp.Buf:GetActiveCursor()
    local targetLine = math.max(0, math.min(cursorLine - 1, bp.Buf:LinesNum() - 1))
    cur:GotoLoc(buffer.Loc(0, targetLine))
    bp:Center()
    if bp.Relocate then
        bp:Relocate()
    end
end

tempFile = function(text)
    local path = os.tmpname()
    local f = io.open(path, "wb")
    if f == nil then
        return nil
    end
    f:write(text)
    f:close()
    return path
end

local function diffTextForContents(targetText, currentText)
    local startNs = perfNow()
    local targetPath = tempFile(targetText)
    local currentPath = tempFile(currentText)
    if targetPath == nil or currentPath == nil then
        if targetPath ~= nil then
            os.remove(targetPath)
        end
        if currentPath ~= nil then
            os.remove(currentPath)
        end
        return nil, "git_diff: could not create temporary files"
    end

    local command = "git diff --no-index --no-color --unified=0 -- " .. shellQuote(targetPath) .. " " .. shellQuote(currentPath)
    local text, err = shell.RunCommand("sh -c " .. shellQuote(command .. "; code=$?; test $code -eq 0 -o $code -eq 1"))
    os.remove(targetPath)
    os.remove(currentPath)
    perfLog(string.format("diffTextForContents ms=%.1f ok=%s", perfMs(startNs), err == nil and "true" or "false"))
    if err ~= nil then
        return nil, "git_diff: could not compute diff"
    end
    return text or "", nil
end

local function wordDiffTextForContents(targetText, currentText)
    local startNs = perfNow()
    local targetPath = tempFile(targetText)
    local currentPath = tempFile(currentText)
    if targetPath == nil or currentPath == nil then
        if targetPath ~= nil then
            os.remove(targetPath)
        end
        if currentPath ~= nil then
            os.remove(currentPath)
        end
        return nil, "git_diff: could not create temporary files"
    end

    local command = "git diff --no-index --no-color --word-diff=porcelain --word-diff-regex='[^[:space:]]+|[[:space:]]+' --unified=0 -- " .. shellQuote(targetPath) .. " " .. shellQuote(currentPath)
    local text, err = shell.RunCommand("sh -c " .. shellQuote(command .. "; code=$?; test $code -eq 0 -o $code -eq 1"))
    os.remove(targetPath)
    os.remove(currentPath)
    perfLog(string.format("wordDiffTextForContents ms=%.1f ok=%s", perfMs(startNs), err == nil and "true" or "false"))
    if err ~= nil then
        return nil, "git_diff: could not compute word diff"
    end
    return text or "", nil
end

local function parseDiff(diffText)
    local hunks = {}
    local current = nil

    for _, line in ipairs(splitLines(diffText)) do
        local oldStart, oldCount, newStart, newCount = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
        if oldStart ~= nil then
            current = {
                oldStart = tonumber(oldStart),
                oldCount = oldCount == "" and 1 or tonumber(oldCount),
                newStart = tonumber(newStart),
                newCount = newCount == "" and 1 or tonumber(newCount),
                removed = {},
                added = {},
            }
            table.insert(hunks, current)
        elseif current ~= nil then
            if line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
                table.insert(current.removed, line:sub(2))
            elseif line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
                table.insert(current.added, line:sub(2))
            end
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

local function parseWordDiff(wordDiffText)
    local spans = { added = {}, removed = {} }
    local oldLineNo = nil
    local newLineNo = nil
    local oldCol = 0
    local newCol = 0
    local lineHadRemoval = false
    local lineHadAddition = false
    local oldLineSpans = {}
    local newLineSpans = {}

    local function flushLine()
        if oldLineNo == nil or newLineNo == nil then
            return false, false
        end
        if lineHadRemoval and lineHadAddition then
            if #newLineSpans > 0 then
                spans.added[newLineNo] = newLineSpans
            end
            if #oldLineSpans > 0 then
                spans.removed[oldLineNo] = oldLineSpans
            end
        end

        local oldAdvance = lineHadRemoval or oldCol > 0
        local newAdvance = lineHadAddition or newCol > 0
        oldCol = 0
        newCol = 0
        lineHadRemoval = false
        lineHadAddition = false
        oldLineSpans = {}
        newLineSpans = {}
        return oldAdvance, newAdvance
    end

    for _, line in ipairs(splitLines(wordDiffText)) do
        local oldStart, oldCount, newStart, newCount = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
        if oldStart ~= nil then
            flushLine()
            oldLineNo = tonumber(oldStart) - 1
            newLineNo = tonumber(newStart) - 1
        else
            local prefix = line:sub(1, 1)
            local text = line:sub(2)
            if prefix == " " then
                local width = util.CharacterCountInString(text)
                oldCol = oldCol + width
                newCol = newCol + width
            elseif prefix == "+" then
                local width = util.CharacterCountInString(text)
                lineHadAddition = true
                if width > 0 and newLineNo ~= nil then
                    table.insert(newLineSpans, { start = newCol, finish = newCol + width })
                    newCol = newCol + width
                end
            elseif prefix == "-" then
                local width = util.CharacterCountInString(text)
                lineHadRemoval = true
                if width > 0 and oldLineNo ~= nil then
                    table.insert(oldLineSpans, { start = oldCol, finish = oldCol + width })
                    oldCol = oldCol + width
                end
            elseif prefix == "~" then
                local oldAdvance, newAdvance = flushLine()
                if oldAdvance and oldLineNo ~= nil then
                    oldLineNo = oldLineNo + 1
                end
                if newAdvance and newLineNo ~= nil then
                    newLineNo = newLineNo + 1
                end
            end
        end
    end

    flushLine()
    return spans
end

local function decoration(kind, fields)
    local parts = {"{\"kind\":\"" .. kind .. "\""}
    for _, item in ipairs(fields) do
        table.insert(parts, item)
    end
    return table.concat(parts, ",") .. "}"
end

jsonString = function(text)
    text = string.gsub(text, "\\", "\\\\")
    text = string.gsub(text, '"', '\\"')
    text = string.gsub(text, "\n", "\\n")
    return '"' .. text .. '"'
end

local function virtualLineDecoration(id, startPos, endPos, group, priority)
    return table.concat({
        '{"id":', jsonString(id),
        ',"start":', tostring(startPos),
        ',"end":', tostring(endPos),
        ',"group":', jsonString(group),
        ',"priority":', tostring(priority),
        '}'
    })
end

local function buildOverlayJSON(hunks, wordSpans, buf)
    local decorations = {}
    local virtualLines = {}
    local virtualLineDecorations = {}
    local lineCount = buf:LinesNum()

    for _, hunk in ipairs(hunks) do
        local startLine = hunk.newStart - 1
        local newCount = hunk.newCount
        local oldCount = hunk.oldCount
        local hasAdded = newCount > 0
        local hasRemoved = oldCount > 0

        if hasAdded then
            for i = 0, newCount - 1 do
                local lineNo = startLine + i
                table.insert(decorations, decoration("line", {
                    '"line":' .. tostring(lineNo),
                    '"group":' .. jsonString("diff-added"),
                    '"priority":10',
                }))

                local spansForLine = wordSpans.added[lineNo]
                if spansForLine ~= nil then
                    for _, span in ipairs(spansForLine) do
                        table.insert(decorations, decoration("span", {
                            '"startLine":' .. tostring(lineNo),
                            '"start":' .. tostring(span.start),
                            '"endLine":' .. tostring(lineNo),
                            '"end":' .. tostring(span.finish),
                            '"group":' .. jsonString("bold #f8fff8,#1c4f31"),
                            '"priority":30',
                        }))
                    end
                end
            end
        end

        if hasRemoved then
            if lineCount > 0 then
                for i = 1, #hunk.removed do
                    local text = hunk.removed[i]
                    local oldLineNo = (hunk.oldStart - 1) + (i - 1)
                    local lineID = "old:" .. tostring(oldLineNo)
                    local anchorLine = startLine + math.min(i - 1, newCount)
                    local above = true

                    if newCount == 0 then
                        if anchorLine <= 0 then
                            anchorLine = 0
                            above = true
                        elseif anchorLine >= lineCount then
                            anchorLine = lineCount - 1
                            above = false
                        else
                            above = true
                        end
                    elseif anchorLine >= lineCount then
                        anchorLine = lineCount - 1
                        above = false
                    end

                    table.insert(virtualLines, table.concat({
                        '{"id":', jsonString(lineID),
                        ',"line":', tostring(anchorLine),
                        ',"above":', above and 'true' or 'false',
                        ',"text":', jsonString(text),
                        ',"group":', jsonString("diff-deleted"),
                        '}'
                    }))

                    local spansForLine = wordSpans.removed[oldLineNo]
                    if spansForLine ~= nil then
                        for _, span in ipairs(spansForLine) do
                            table.insert(virtualLineDecorations, virtualLineDecoration(lineID, span.start, span.finish, "bold #fff0f0,#6a2b2b", 30))
                        end
                    end
                end
            end
        end
    end

    return "[" .. table.concat(decorations, ",") .. "]", "[" .. table.concat(virtualLines, ",") .. "]", "[" .. table.concat(virtualLineDecorations, ",") .. "]"
end

local function clearOverlay(buf)
    buf:ClearDecorations(OWNER)
    buf:ClearVirtualLines(OWNER)
    buf:ClearVirtualLineDecorations(OWNER)
    buf:SetDiffBase(nil)
    buf:SetOptionNative("diffgutter", false)
end

local function ensureSessionBuffer(buf)
    if session == nil or buf == nil or buf.AbsPath == nil or buf.AbsPath == "" then
        return false, nil
    end

    if isListBuffer(buf) then
        return false, nil
    end

    local relPath = repoFile(buf.AbsPath)
    if relPath == nil or relPath == "." then
        if session.touched ~= nil and session.touched[buf.AbsPath] ~= nil then
            clearOverlay(buf)
            session.touched[buf.AbsPath] = nil
            session.cache[buf.AbsPath] = nil
        end
        return false, nil
    end

    return true, relPath
end

local function applyOverlay(buf)
    local totalStartNs = perfNow()
    local ok, relPath = ensureSessionBuffer(buf)
    if not ok then
        return
    end

    local stepStartNs = perfNow()
    local currentText = bufferText(buf)

    local targetText = session.targetTextCache[relPath]
    if targetText == nil then
        targetText = trackedContents(session.root, session.target, relPath)
        session.targetTextCache[relPath] = targetText
    end
    perfLog(string.format("applyOverlay step=buffer-and-target path=%s ms=%.1f", relPath, perfMs(stepStartNs)))

    local cacheKey = currentText
    local overlay = session.overlayCache[relPath]
    if overlay ~= nil and overlay.cacheKey == cacheKey then
		buf:SetDiffBase(targetText)
		buf:SetOptionNative("diffgutter", true)
		buf:SetDecorationsJSON(OWNER, overlay.decorationsJSON, session.version)
		buf:SetVirtualLinesJSON(OWNER, overlay.virtualLinesJSON, session.version)
		buf:SetVirtualLineDecorationsJSON(OWNER, overlay.virtualLineDecorationsJSON, session.version)
		session.cache[buf.AbsPath] = cacheKey
		session.touched[buf.AbsPath] = buf
		perfLog(string.format("applyOverlay path=%s cached=overlay total_ms=%.1f", relPath, perfMs(totalStartNs)))
		return
	end

    if session.cache[buf.AbsPath] == cacheKey and session.touched[buf.AbsPath] == buf then
		perfLog(string.format("applyOverlay path=%s cached=buffer total_ms=%.1f", relPath, perfMs(totalStartNs)))
        return
    end

    stepStartNs = perfNow()
    local diffText, diffErr = diffTextForContents(targetText, currentText)
    if diffErr ~= nil then
        micro.InfoBar():Error(diffErr)
        return
    end
    perfLog(string.format("applyOverlay step=diff path=%s ms=%.1f", relPath, perfMs(stepStartNs)))

    stepStartNs = perfNow()
    local wordDiffText, wordDiffErr = wordDiffTextForContents(targetText, currentText)
    if wordDiffErr ~= nil then
        micro.InfoBar():Error(wordDiffErr)
        return
    end
    perfLog(string.format("applyOverlay step=worddiff path=%s ms=%.1f", relPath, perfMs(stepStartNs)))

    stepStartNs = perfNow()
    local decorationsJSON, virtualLinesJSON, virtualLineDecorationsJSON = buildOverlayJSON(parseDiff(diffText), parseWordDiff(wordDiffText), buf)
	perfLog(string.format("applyOverlay step=build-overlay path=%s ms=%.1f", relPath, perfMs(stepStartNs)))
	session.overlayCache[relPath] = {
		cacheKey = cacheKey,
		decorationsJSON = decorationsJSON,
		virtualLinesJSON = virtualLinesJSON,
		virtualLineDecorationsJSON = virtualLineDecorationsJSON,
	}
	stepStartNs = perfNow()
    buf:SetDiffBase(targetText)
    buf:SetOptionNative("diffgutter", true)
    buf:SetDecorationsJSON(OWNER, decorationsJSON, session.version)
    buf:SetVirtualLinesJSON(OWNER, virtualLinesJSON, session.version)
    buf:SetVirtualLineDecorationsJSON(OWNER, virtualLineDecorationsJSON, session.version)
    perfLog(string.format("applyOverlay step=apply-buffer-state path=%s ms=%.1f", relPath, perfMs(stepStartNs)))
    session.cache[buf.AbsPath] = cacheKey
    session.touched[buf.AbsPath] = buf
    perfLog(string.format("applyOverlay path=%s cached=false total_ms=%.1f", relPath, perfMs(totalStartNs)))
end

local function clearTouchedBuffers()
    if session == nil then
        return
    end
    for _, buf in pairs(session.touched) do
        clearOverlay(buf)
    end
end

local function restoreTouchedBuffers()
    if session == nil then
        return
    end
    for _, buf in pairs(session.touched) do
        clearOverlay(buf)
        syncHeadDiffBase(buf)
    end
end

local function closeListPane()
    if session == nil or not paneAlive(session.listPane) then
        return
    end
    pcall(function()
        session.listPane:Quit()
    end)
end

function gitDiffClose(bp)
    if session == nil then
        micro.InfoBar():Message("git_diff: no active diff session")
        return
    end

    restoreTouchedBuffers()
    closeListPane()
    session = nil
    if bp ~= nil and bp.Buf ~= nil and not isListBuffer(bp.Buf) then
        syncHeadDiffBase(bp.Buf)
    end
    micro.InfoBar():Message("git_diff: closed diff session")
end

function gitDiffBlame(bp)
    bp = activeBufPane(bp)
    if bp == nil then
        micro.InfoBar():Error("git_diff: no active buffer pane")
        return
    end

    local previous = blame
    local sessionID = nextBlameSessionID()
    if previous ~= nil and previous.pane == bp then
        sessionID = previous.sessionID
    end

    if renderBlame(bp, sessionID, true) then
        if previous ~= nil and previous.pane ~= bp then
            clearBlamePane(previous.pane)
        end
        return
    end

    blame = previous
end

function gitDiffBlameClose(bp)
    if blame == nil then
        micro.InfoBar():Message("git_diff: no active blame session")
        return
    end

    dropBlame()
    micro.InfoBar():Message("git_diff: closed blame session")
end

local function activeResetTarget(bp)
    if session ~= nil and bp ~= nil and bp.Buf ~= nil and not isListBuffer(bp.Buf) then
        local relPath = repoFile(bp.Buf.AbsPath)
        if relPath ~= nil then
            return {
                root = session.root,
                relPath = relPath,
                target = session.target,
                label = session.label,
            }
        end
    end

    local info = gitInfo(bp.Buf.AbsPath, true)
    if info == nil then
        return nil
    end

    return {
        root = info.root,
        relPath = info.relPath,
        target = "HEAD",
        label = "HEAD",
    }
end

local function activeSessionTarget(bp)
    if session == nil or bp == nil or bp.Buf == nil or isListBuffer(bp.Buf) then
        return nil
    end

    local relPath = repoFile(bp.Buf.AbsPath)
    if relPath == nil then
        return nil
    end

    return {
        root = session.root,
        relPath = relPath,
        target = session.target,
    }
end

local function currentHunks(bp)
    local targetInfo = activeSessionTarget(bp)
    if targetInfo == nil then
        return nil
    end

    local currentText = bufferText(bp.Buf)
    local targetText = trackedContents(targetInfo.root, targetInfo.target, targetInfo.relPath)
    local diffText, diffErr = diffTextForContents(targetText, currentText)
    if diffErr ~= nil then
        micro.InfoBar():Error(diffErr)
        return nil
    end
    return parseDiff(diffText)
end

local function gotoDiffLine(bp, lineNo)
    bp:GotoLoc(buffer.Loc(0, math.max(0, lineNo)))
    bp:Center()
end

local function gotoFirstChange(bp)
    local hunks = currentHunks(bp)
    if hunks == nil or #hunks == 0 then
        return false
    end
    gotoDiffLine(bp, hunks[1].newStart - 1)
    return true
end

local function builtinDiffJump(bp, forward)
    local lineNo, err = bp.Buf:FindNextDiffLine(bp.Buf:GetActiveCursor().Y, forward)
    if err ~= nil then
        return false
    end
    gotoDiffLine(bp, lineNo)
    return true
end

function gitDiffNext(bp)
    local hunks = currentHunks(bp)
    if hunks == nil then
        if not builtinDiffJump(bp, true) then
            micro.InfoBar():Message("No more changes")
        end
        return
    end

    local cursorLine = bp.Buf:GetActiveCursor().Y + 1
    for _, hunk in ipairs(hunks) do
        local endLine = hunk.newCount == 0 and hunk.newStart or (hunk.newStart + hunk.newCount - 1)
        if cursorLine < hunk.newStart then
            gotoDiffLine(bp, hunk.newStart - 1)
            return
        end
        if cursorLine >= hunk.newStart and cursorLine <= endLine then
            -- skip current hunk
        end
    end

    for _, hunk in ipairs(hunks) do
        if hunk.newStart > cursorLine then
            gotoDiffLine(bp, hunk.newStart - 1)
            return
        end
    end

    local targetInfo = activeSessionTarget(bp)
    if targetInfo ~= nil then
        local relPath = nextChangedFile(targetInfo.relPath)
        if relPath ~= nil and openSessionFile(bp, relPath) then
            return
        end
    end

    micro.InfoBar():Message("No more changes")
end

function gitDiffPrevious(bp)
    local hunks = currentHunks(bp)
    if hunks == nil then
        if not builtinDiffJump(bp, false) then
            micro.InfoBar():Message("No more changes")
        end
        return
    end

    local cursorLine = bp.Buf:GetActiveCursor().Y + 1
    local targetLine = nil
    for _, hunk in ipairs(hunks) do
        if hunk.newStart < cursorLine then
            targetLine = hunk.newStart - 1
        else
            break
        end
    end

    if targetLine ~= nil then
        gotoDiffLine(bp, targetLine)
        return
    end

    local targetInfo = activeSessionTarget(bp)
    if targetInfo ~= nil then
        local relPath = previousChangedFile(targetInfo.relPath)
        if relPath ~= nil and openSessionFile(bp, relPath) then
            local targetPane = currentPane()
            local prevHunks = currentHunks(targetPane)
            if prevHunks ~= nil and #prevHunks > 0 then
                gotoDiffLine(targetPane, prevHunks[#prevHunks].newStart - 1)
                return
            end
        end
    end

    micro.InfoBar():Message("No more changes")
end

function resetHunk(bp)
    if bp == nil or bp.Buf == nil or bp.Buf.AbsPath == nil or bp.Buf.AbsPath == "" then
        micro.InfoBar():Error("git_diff: current buffer is not a file")
        return
    end

    local targetInfo = activeResetTarget(bp)
    if targetInfo == nil then
        micro.InfoBar():Error("git_diff: file is not tracked in git")
        return
    end

    local currentText = bufferText(bp.Buf)
    local targetText = trackedContents(targetInfo.root, targetInfo.target, targetInfo.relPath)
    local diffText, diffErr = diffTextForContents(targetText, currentText)
    if diffErr ~= nil then
        micro.InfoBar():Error(diffErr)
        return
    end

    local cursorLine = bp.Buf:GetActiveCursor().Y + 1
    local hunk = hunkAtLine(parseDiff(diffText), cursorLine)
    if hunk == nil then
        micro.InfoBar():Message("git_diff: no diff hunk at cursor")
        return
    end

    local targetLines = splitLines(targetText)
    local replacement = {}
    for lineNo = hunk.oldStart, hunk.oldStart + hunk.oldCount - 1 do
        table.insert(replacement, targetLines[lineNo] or "")
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

    replaceWholeBuffer(bp.Buf, joinLines(updated))
    resetCursorAfterReplace(bp, hunk.newStart)
    micro.InfoBar():Message("git_diff: reset hunk to " .. targetInfo.label)
end

local function fileListLinePath(lineNo)
    if session == nil or session.listEntries == nil then
        return nil
    end
    return session.listEntries[lineNo + 1]
end

local function firstChangedFile(lines)
    for _, line in ipairs(lines) do
        local _, rel = line:match("^([A-Z?]+)%s+(.+)$")
        if rel ~= nil then
            return rel
        end
    end
    return nil
end

nextChangedFile = function(relPath)
    if session == nil or session.fileOrder == nil then
        return nil
    end
    for i, candidate in ipairs(session.fileOrder) do
        if candidate == relPath then
            return session.fileOrder[i + 1]
        end
    end
    return nil
end

previousChangedFile = function(relPath)
    if session == nil or session.fileOrder == nil then
        return nil
    end
    for i, candidate in ipairs(session.fileOrder) do
        if candidate == relPath then
            return session.fileOrder[i - 1]
        end
    end
    return nil
end

local function listPaneActive(bp)
    return session ~= nil and paneAlive(bp) and isListBuffer(bp.Buf)
end

local function selectedListEntry(bp, lineNo)
    if not listPaneActive(bp) then
        return nil
    end

    local relPath = fileListLinePath(lineNo)
    return relPath
end

local function currentSessionRelPath()
    local bp = sourcePane() or currentPane()
    if bp == nil or bp.Buf == nil or isListBuffer(bp.Buf) then
        return nil
    end
    return repoFile(bp.Buf.AbsPath)
end

sourcePane = function()
    if session ~= nil and paneAlive(session.sourcePane) and not isListBuffer(session.sourcePane.Buf) then
        return session.sourcePane
    end
    return nil
end

local function targetPaneForOpen(originPane)
    if listPaneActive(originPane) then
        originPane:NextSplit()
        local target = currentPane()
        if paneAlive(target) and not isListBuffer(target.Buf) then
            session.sourcePane = target
            return target
        end
    end

    local target = sourcePane()
    if target ~= nil then
        return target
    end

    target = currentPane()
    if paneAlive(target) and not isListBuffer(target.Buf) then
        session.sourcePane = target
        return target
    end

    return nil
end

openSessionFile = function(originPane, relPath)
    local totalStartNs = perfNow()
    if session == nil or relPath == nil then
        return false
    end

    setPerfContext("openSessionFile", relPath)

    local targetPane = targetPaneForOpen(originPane)
    if targetPane == nil then
        micro.InfoBar():Error("git_diff: source pane is no longer available")
        return false
    end

    local absPath = session.root .. "/" .. relPath
    local stepStartNs = perfNow()
    local buf, err = buffer.NewBufferFromFile(absPath)
    perfLog(string.format("openSessionFile step=open-buffer path=%s ms=%.1f ok=%s", relPath, perfMs(stepStartNs), err == nil and "true" or "false"))
    if err ~= nil then
        micro.InfoBar():Error("git_diff: could not open " .. relPath)
        return false
    end

    stepStartNs = perfNow()
    targetPane:PushJump()
    targetPane:OpenBuffer(buf)
    perfLog(string.format("openSessionFile step=open-pane path=%s ms=%.1f", relPath, perfMs(stepStartNs)))

    stepStartNs = perfNow()
    applyOverlay(buf)
    perfLog(string.format("openSessionFile step=apply-overlay path=%s ms=%.1f", relPath, perfMs(stepStartNs)))

    stepStartNs = perfNow()
    gotoFirstChange(targetPane)
    refreshChangedFiles()
    perfLog(string.format("openSessionFile step=post-open path=%s ms=%.1f", relPath, perfMs(stepStartNs)))
    perfLog(string.format("openSessionFile path=%s total_ms=%.1f", relPath, perfMs(totalStartNs)))
    return true
end

local function openSelectedListEntry(bp)
    local cursor = bp.Buf:GetActiveCursor()
    local relPath = selectedListEntry(bp, cursor.Y)
    if relPath == nil then
        return false
    end

    return openSessionFile(bp, relPath)
end

local function openClickedListEntry(bp, te)
    if te == nil then
        return openSelectedListEntry(bp)
    end

    local mx, my = te:Position()
    local loc = bp:LocFromVisual(buffer.Loc(mx, my))
    local relPath = selectedListEntry(bp, loc.Y)
    if relPath == nil then
        return false
    end

    return openSessionFile(bp, relPath)
end

local function listBufferText(lines)
    local entries = {}
    local order = {}
    local out = {
        "Showing changes relative to " .. session.label,
        "",
    }
    if #lines == 0 then
        table.insert(out, "(none)")
    else
        for _, line in ipairs(lines) do
            table.insert(out, formatFileListLine(line))
            local status, rel = line:match("^([A-Z?]+)%s+(.+)$")
            if rel ~= nil then
                entries[#out] = rel
                table.insert(order, rel)
            end
        end
    end
    return joinLines(out), entries, order
end

local function listDecorationsJSON(lines)
    local decorations = {}
    local activeRelPath = currentSessionRelPath()
    local cursorLineBg = config.GetColorBackground("cursor-line")
    for i, line in ipairs(lines) do
        local lineIndex = i - 1
        local relPath = session.listEntries[i]
        if activeRelPath ~= nil and relPath == activeRelPath then
            table.insert(decorations, decoration("line", {
                '"line":' .. tostring(lineIndex),
                '"group":' .. jsonString("bold default," .. cursorLineBg),
                '"priority":10',
            }))
        end

        local group = listIconGroup(line)
        if group ~= nil then
            table.insert(decorations, decoration("span", {
                '"startLine":' .. tostring(lineIndex),
                '"start":0',
                '"endLine":' .. tostring(lineIndex),
                '"end":1',
                '"group":' .. jsonString(group),
                '"priority":20',
            }))
        end
    end
    return "[" .. table.concat(decorations, ",") .. "]"
end

local function ensureListPane(bp, lines)
    local text, entries, order = listBufferText(lines)
    local decorationsJSON = listDecorationsJSON(splitLines(text))
    session.listEntries = entries
    session.fileOrder = order
    if paneAlive(session.listPane) and isListBuffer(session.listPane.Buf) then
        replaceWholeBuffer(session.listPane.Buf, text)
        session.listPane.Buf:SetOptionNative("readonly", true)
        session.listPane.Buf:SetDecorationsJSON(OWNER, decorationsJSON, session.version)
        return
    end

    local listBuf = buffer.NewScratchBuffer(text, LIST_BUFFER_NAME)
    listBuf:SetOptionNative("softwrap", false)
    listBuf:SetOptionNative("readonly", true)
    listBuf:SetDecorationsJSON(OWNER, decorationsJSON, session.version)
    session.listPane = bp:HSplitBuf(listBuf)
end

refreshChangedFiles = function()
    local totalStartNs = perfNow()
    if session == nil then
        return
    end

    local lines, err = changedFilesForTarget(session.root, session.target)
    if err ~= nil then
        return
    end

    local text = listBufferText(lines)
    local activeRelPath = currentSessionRelPath()
    if session.listText == text and session.listActiveRelPath == activeRelPath then
        perfLog(string.format("refreshChangedFiles changed=false total_ms=%.1f", perfMs(totalStartNs)))
        return
    end

    if session.listText == text and session.listActiveRelPath ~= activeRelPath and paneAlive(session.listPane) and isListBuffer(session.listPane.Buf) then
        session.listActiveRelPath = activeRelPath
        local decorationsJSON = listDecorationsJSON(splitLines(text))
        session.listPane.Buf:SetDecorationsJSON(OWNER, decorationsJSON, session.version)
        perfLog(string.format("refreshChangedFiles changed=decorations-only total_ms=%.1f", perfMs(totalStartNs)))
        return
    end

    session.listText = text
    session.listActiveRelPath = activeRelPath
    ensureListPane(sourcePane() or currentPane(), lines)
    perfLog(string.format("refreshChangedFiles changed=full total_ms=%.1f", perfMs(totalStartNs)))
end

local function startSession(bp, target, label)
    bp = activeBufPane(bp)
    if bp == nil then
        micro.InfoBar():Error("git_diff: no active buffer pane")
        return
    end

    local root, rootErr = gitRootFromPane(bp)
    if rootErr ~= nil then
        micro.InfoBar():Error(rootErr)
        return
    end

    local changed, changedErr = changedFilesForTarget(root, target)
    if changedErr ~= nil then
        micro.InfoBar():Error("git_diff: could not list changed files")
        return
    end

    clearTouchedBuffers()
    session = {
        root = root,
        target = target,
        label = label,
        version = os.time(),
        cache = {},
        targetTextCache = {},
        overlayCache = {},
        touched = {},
        listPane = nil,
        listText = nil,
        listActiveRelPath = nil,
        listEntries = {},
        fileOrder = {},
        sourcePane = bp,
    }

    ensureListPane(bp, changed)
    session.listText = listBufferText(changed)
    local firstFile = firstChangedFile(changed)
    if firstFile ~= nil then
        openSessionFile(bp, firstFile)
    else
        applyOverlay(bp.Buf)
        gotoFirstChange(bp)
    end
end

local function refreshSessionPane(bp)
    if session == nil then
        return
    end

    if bp == nil or bp.Buf == nil then
        return
    end

    refreshChangedFiles()

    local relPath = repoFile(bp.Buf.AbsPath)
    if relPath ~= nil then
        applyOverlay(bp.Buf)
    end
end

function onBufferOpen(buf)
    local startNs = perfNow()
    if shouldLogCallback() then
        perfLog(string.format("callback=onBufferOpen start %s buf=%s", perfContextTag(), buf ~= nil and (buf.AbsPath or buf:GetName()) or ""))
    end
    if session ~= nil and repoFile(buf.AbsPath) ~= nil and not isListBuffer(buf) then
        local curPane = currentPane()
        if curPane ~= nil and curPane.Buf == buf then
            session.sourcePane = curPane
        end
        applyOverlay(buf)
        refreshChangedFiles()
    else
        syncHeadDiffBase(buf)
    end
    local curPane = currentPane()
    if curPane ~= nil and curPane.Buf == buf then
        syncBlameForPane(curPane, false)
    end
    if shouldLogCallback() then
        perfLog(string.format("callback=onBufferOpen end %s ms=%.1f", perfContextTag(), perfMs(startNs)))
    end
end

function onSetActive(bp)
    local startNs = perfNow()
    if shouldLogCallback() then
        perfLog(string.format("callback=onSetActive start %s buf=%s", perfContextTag(), bp ~= nil and bp.Buf ~= nil and (bp.Buf.AbsPath or bp.Buf:GetName()) or ""))
    end
    if bp == nil or bp.Buf == nil then
        return
    end

    if session ~= nil and repoFile(bp.Buf.AbsPath) ~= nil and not isListBuffer(bp.Buf) then
        if not listPaneActive(bp) then
            session.sourcePane = bp
            refreshChangedFiles()
        end
        if session.touched[bp.Buf.AbsPath] == nil then
            applyOverlay(bp.Buf)
        end
    else
        syncHeadDiffBase(bp.Buf)
    end
    syncBlameForPane(bp, false)
    if shouldLogCallback() then
        perfLog(string.format("callback=onSetActive end %s ms=%.1f", perfContextTag(), perfMs(startNs)))
    end
end

function preInsertNewline(bp)
    if openSelectedListEntry(bp) then
        return false
    end
    return true
end

function preInsertEnter(bp)
    return preInsertNewline(bp)
end

function onMousePress(bp, te)
    return openClickedListEntry(bp, te) or openClickedBlameCommit(bp, te)
end

function onSave(bp)
    refreshSessionPane(bp)
    syncBlameForPane(bp, true)
end

function onAnyEvent()
    local startNs = perfNow()
    local logThis = shouldLogCallback()
    if logThis then
        local bp = currentPane()
        perfLog(string.format("callback=onAnyEvent start %s buf=%s", perfContextTag(), bp ~= nil and bp.Buf ~= nil and (bp.Buf.AbsPath or bp.Buf:GetName()) or ""))
    end
    local bp = currentPane()
    if bp == nil or bp.Buf == nil or isListBuffer(bp.Buf) then
        return
    end

    syncBlameForPane(bp, false)

    if session == nil then
        return
    end

    local relPath = repoFile(bp.Buf.AbsPath)
    if relPath == nil then
        return
    end

    if session.sourcePane ~= bp or session.listActiveRelPath ~= relPath then
        session.sourcePane = bp
        refreshChangedFiles()
    end
    if logThis then
        perfLog(string.format("callback=onAnyEvent end %s ms=%.1f", perfContextTag(), perfMs(startNs)))
    end
end

function diffViewUnstaged(bp)
    startSession(bp, ":0", "HEAD+staged")
end

function diffViewWorktree(bp)
    startSession(bp, "HEAD", "HEAD")
end

function diffViewTarget(bp, args)
    if args == nil or #args ~= 1 then
        micro.InfoBar():Error("Usage: gitdifftarget <branch-or-ref>")
        return
    end
    startSession(bp, args[1], args[1])
end

function init()
    config.MakeCommand("gitdiffclose", gitDiffClose, config.NoComplete)
    config.MakeCommand("gitdiffblame", gitDiffBlame, config.NoComplete)
    config.MakeCommand("gitdiffblameclose", gitDiffBlameClose, config.NoComplete)
    config.MakeCommand("gitdiffnext", gitDiffNext, config.NoComplete)
    config.MakeCommand("gitdiffprev", gitDiffPrevious, config.NoComplete)
    config.MakeCommand("gitdiffresethunk", resetHunk, config.NoComplete)
    config.MakeCommand("gitdiffunstaged", diffViewUnstaged, config.NoComplete)
    config.MakeCommand("gitdiffworktree", diffViewWorktree, config.NoComplete)
    config.MakeCommand("gitdifftarget", diffViewTarget, config.NoComplete)
    config.RegisterActionLabel("command:gitdiffclose", "close diff")
    config.RegisterActionLabel("command:gitdiffblame", "show blame")
    config.RegisterActionLabel("command:gitdiffblameclose", "close blame")
    config.RegisterActionLabel("command:gitdiffnext", "next diff")
    config.RegisterActionLabel("command:gitdiffprev", "prev diff")
    config.RegisterActionLabel("command:gitdiffresethunk", "reset hunk")
    config.RegisterActionLabel("command:gitdiffunstaged", "diff unstaged")
    config.RegisterActionLabel("command:gitdiffworktree", "diff worktree")
    config.RegisterActionLabel("command:gitdifftarget", "diff target")
end
