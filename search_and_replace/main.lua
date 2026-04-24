VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local go_os = import("os")

local MODE_IN_FILE = "find_in_file"
local MODE_ACROSS = "find_accross_files"
local FIELD_SEARCH = "search"
local FIELD_REGEX = "regex"
local FIELD_PATTERN = "pattern"
local PROMPT_TYPE = "search_and_replace"

local state = {
    sourcePane = nil,
    promptPane = nil,
    form = nil,
    cwd = "",
}

state.cwd = go_os.Getwd()

local function paneAlive(bp)
    return bp ~= nil and bp.Buf ~= nil
end

local function updateStatus(text, isError)
    if isError then
        micro.InfoBar():Error(text)
    else
        micro.InfoBar():Message(text)
    end
end

local function trim(text)
    if text == nil then
        return ""
    end
    return text:match("^%s*(.-)%s*$")
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

local function shellQuote(text)
    return "'" .. string.gsub(text or "", "'", "'\\''") .. "'"
end

local function commandExists(cmd)
    local _, err = shell.RunCommand("sh -c 'command -v " .. cmd .. " >/dev/null 2>&1'")
    return err == nil
end

local function chars(text)
    local out = {}
    for ch in (text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        out[#out + 1] = ch
    end
    return out
end

local function runeCount(text)
    return #chars(text)
end

local function activePromptPane()
    local pane = state.promptPane or micro.InfoBar()
    if pane == nil or not pane.HasPrompt or pane.PromptType ~= PROMPT_TYPE or pane.Buf == nil then
        return nil
    end
    return pane
end

local function activeSourcePane(bp)
    if paneAlive(bp) and bp ~= activePromptPane() then
        return bp
    end
    if paneAlive(state.sourcePane) and state.sourcePane ~= activePromptPane() then
        return state.sourcePane
    end
    local cur = micro.CurPane()
    if paneAlive(cur) and cur ~= activePromptPane() then
        return cur
    end
    return nil
end

local function getFieldOrder()
    if state.form == nil then
        return {}
    end
    if state.form.mode == MODE_ACROSS then
        return { FIELD_SEARCH, FIELD_REGEX, FIELD_PATTERN }
    end
    return { FIELD_SEARCH, FIELD_REGEX }
end

local function cycleField(step)
    local order = getFieldOrder()
    if #order == 0 then
        return
    end

    local idx = 1
    for i, field in ipairs(order) do
        if field == state.form.activeField then
            idx = i
            break
        end
    end

    idx = ((idx - 1 + step) % #order) + 1
    state.form.activeField = order[idx]
end

local function currentFieldValue()
    if state.form.activeField == FIELD_PATTERN then
        return state.form.filePattern
    end
    return state.form.search
end

local function setCurrentFieldValue(value)
    if state.form.activeField == FIELD_PATTERN then
        state.form.filePattern = value
    else
        state.form.search = value
    end
end

local function currentCursor()
    if state.form.activeField == FIELD_PATTERN then
        return state.form.patternCursor
    end
    return state.form.searchCursor
end

local function setCurrentCursor(value)
    if state.form.activeField == FIELD_PATTERN then
        state.form.patternCursor = value
    else
        state.form.searchCursor = value
    end
end

local function linePrefix(field)
    if field == FIELD_SEARCH then
        return "Search: "
    end
    if field == FIELD_REGEX then
        return "Regex: "
    end
    return "File pattern: "
end

local function editableField(field)
    return field == FIELD_SEARCH or field == FIELD_PATTERN
end

local function renderPrompt(bp)
    if state.form == nil then
        return
    end

    local pane = bp or activePromptPane()
    if pane == nil or pane.Buf == nil then
        return
    end

    local lines = {
        "Search: " .. state.form.search,
        "Regex: " .. (state.form.regex and "1" or "0"),
    }
    if state.form.mode == MODE_ACROSS then
        lines[#lines + 1] = "File pattern: " .. state.form.filePattern
    end

    replaceWholeBuffer(pane.Buf, table.concat(lines, "\n"))
    pane.Buf:SetOptionNative("softwrap", false)
    pane.Buf:SetOptionNative("readonly", true)

    local field = state.form.activeField
    local order = getFieldOrder()
    local lineIndex = 0
    for i, name in ipairs(order) do
        if name == field then
            lineIndex = i - 1
            break
        end
    end

    local col = runeCount(linePrefix(field))
    if field == FIELD_REGEX then
        col = col + (state.form.regex and 1 or 0)
    else
        col = col + currentCursor()
    end

    local cur = pane.Buf:GetActiveCursor()
    cur:GotoLoc(buffer.Loc(col, lineIndex))
end

local function insertRuneIntoField(ch)
    local value = currentFieldValue()
    local cursor = currentCursor()
    local parts = chars(value)
    table.insert(parts, cursor + 1, ch)
    setCurrentFieldValue(table.concat(parts, ""))
    setCurrentCursor(cursor + 1)
end

local function backspaceField()
    local cursor = currentCursor()
    if cursor <= 0 then
        return
    end
    local parts = chars(currentFieldValue())
    table.remove(parts, cursor)
    setCurrentFieldValue(table.concat(parts, ""))
    setCurrentCursor(cursor - 1)
end

local function deleteField()
    local cursor = currentCursor()
    local parts = chars(currentFieldValue())
    if cursor >= #parts then
        return
    end
    table.remove(parts, cursor + 1)
    setCurrentFieldValue(table.concat(parts, ""))
end

local function moveCursor(delta)
    local value = currentFieldValue()
    local nextPos = currentCursor() + delta
    nextPos = math.max(0, math.min(nextPos, runeCount(value)))
    setCurrentCursor(nextPos)
end

local function interactiveShellCommand(command)
    if commandExists("script") then
        return "script -q -c " .. shellQuote(command) .. " /dev/null"
    end
    return command
end

local function saveSourceBuffer(sourcePane)
    if sourcePane == nil or sourcePane.Buf == nil then
        return true
    end

    local buf = sourcePane.Buf
    local path = buf.Path or buf.AbsPath or ""
    if path == "" or not buf:Modified() then
        return true
    end

    local err = buf:Save()
    if err ~= nil then
        updateStatus("search_and_replace: could not save current file: " .. tostring(err), true)
        return false
    end

    return true
end

local function reloadOpenBuffers()
    local tabs = micro.Tabs()
    if tabs == nil or tabs.List == nil then
        return 0, 0, 0
    end

    local seen = {}
    local reloaded = 0
    local skipped = 0
    local failed = 0

    for _, tab in tabs.List() do
        if tab ~= nil and tab.Panes ~= nil then
            for _, pane in tab.Panes() do
                if pane ~= nil and pane.Buf ~= nil and seen[pane.Buf] == nil then
                    seen[pane.Buf] = true

                    local buf = pane.Buf
                    local path = buf.Path or buf.AbsPath or ""
                    if path ~= "" then
                        if buf:Modified() then
                            skipped = skipped + 1
                        else
                            local err = buf:ReOpen()
                            if err ~= nil then
                                failed = failed + 1
                            else
                                reloaded = reloaded + 1
                            end
                        end
                    end
                end
            end
        end
    end

    return reloaded, skipped, failed
end

local function buildSearchCommand(sourcePane)
    if not commandExists("rgr") then
        return nil, "search_and_replace: required command not found: rgr"
    end

    local searchKey = trim(state.form.search)
    if searchKey == "" then
        return nil, "Search is empty"
    end

    local parts = {
        "rgr",
        "-C", "3",
        '--context-separator=---',
    }

    if not state.form.regex then
        parts[#parts + 1] = "-F"
    end

    if state.form.mode == MODE_IN_FILE then
        parts[#parts + 1] = shellQuote(searchKey)
        local path = sourcePane.Buf.AbsPath or ""
        if path == "" then
            return nil, "Current buffer has no file on disk"
        end
        parts[#parts + 1] = shellQuote(path)
    else
        local pattern = trim(state.form.filePattern)
        if pattern == "" then
            pattern = "*.*"
        end
        state.form.filePattern = pattern
        parts[#parts + 1] = "-g"
        parts[#parts + 1] = shellQuote(pattern)
        parts[#parts + 1] = shellQuote(searchKey)
    end

    return table.concat(parts, " "), nil
end

local function clearPromptState()
    state.promptPane = nil
    state.form = nil
end

local function startSearch(bp)
    if state.form == nil then
        return false
    end

    local sourcePane = activeSourcePane(nil)
    if sourcePane == nil then
        updateStatus("search_and_replace: no source pane available", true)
        return false
    end
    state.sourcePane = sourcePane

    if not saveSourceBuffer(sourcePane) then
        return false
    end

    local command, err = buildSearchCommand(sourcePane)
    if err ~= nil then
        updateStatus(err, true)
        return false
    end

    local pane = bp or activePromptPane()
    if pane ~= nil then
        pane:DonePrompt(false)
    else
        clearPromptState()
    end
    updateStatus("Starting repgrep...", false)

    micro.After(0, function()
        local _, runErr = shell.RunInteractiveShell(interactiveShellCommand(command), false, false)
        local reloaded, skipped, failed = reloadOpenBuffers()
        if runErr ~= nil then
            updateStatus("search_and_replace: " .. tostring(runErr), true)
        elseif failed > 0 then
            updateStatus("Reloaded " .. reloaded .. " buffers, skipped " .. skipped .. ", failed " .. failed, true)
        elseif skipped > 0 then
            updateStatus("Reloaded " .. reloaded .. " buffers, skipped " .. skipped .. " modified buffers", false)
        else
            updateStatus("Reloaded " .. reloaded .. " buffers", false)
        end
    end)

    return false
end

local function openPrompt(mode, bp)
    local sourcePane = activeSourcePane(bp)
    if sourcePane == nil then
        updateStatus("search_and_replace: no source pane available", true)
        return
    end

    state.sourcePane = sourcePane
    state.form = {
        mode = mode,
        search = "",
        regex = false,
        filePattern = "*.*",
        activeField = FIELD_SEARCH,
        searchCursor = 0,
        patternCursor = runeCount("*.*"),
    }

    state.promptPane = micro.InfoBar()
    local rows = #getFieldOrder()
    state.promptPane:PromptBuffer("", "", PROMPT_TYPE, rows, nil, function(_, _)
        clearPromptState()
    end)
    renderPrompt(state.promptPane)
    updateStatus("Enter to launch repgrep, Tab to move fields", false)
end

local function handlePromptRune(bp, r)
    if state.form == nil or bp ~= activePromptPane() then
        return true
    end

    if state.form.activeField == FIELD_REGEX then
        if r == " " then
            state.form.regex = not state.form.regex
            renderPrompt(bp)
        end
        return false
    end

    insertRuneIntoField(r)
    renderPrompt(bp)
    return false
end

local function handlePromptAction(bp, action)
    if state.form == nil or bp ~= activePromptPane() then
        return true
    end

    if action == "tab" then
        cycleField(1)
    elseif action == "up" then
        cycleField(-1)
    elseif action == "down" then
        cycleField(1)
    elseif action == "left" then
        if editableField(state.form.activeField) then
            moveCursor(-1)
        end
    elseif action == "right" then
        if editableField(state.form.activeField) then
            moveCursor(1)
        end
    elseif action == "home" then
        if editableField(state.form.activeField) then
            setCurrentCursor(0)
        end
    elseif action == "end" then
        if editableField(state.form.activeField) then
            setCurrentCursor(runeCount(currentFieldValue()))
        end
    elseif action == "backspace" then
        if editableField(state.form.activeField) then
            backspaceField()
        end
    elseif action == "delete" then
        if editableField(state.form.activeField) then
            deleteField()
        end
    elseif action == "enter" then
        return startSearch(bp)
    end

    renderPrompt(bp)
    return false
end

function find_in_file(bp)
    openPrompt(MODE_IN_FILE, bp)
end

function find_accross_files(bp)
    openPrompt(MODE_ACROSS, bp)
end

function onSetActive(bp)
    if paneAlive(bp) and bp ~= activePromptPane() then
        state.sourcePane = bp
    end
end

function preInfoRune(bp, r)
    return handlePromptRune(bp, r)
end

function preInfoInsertTab(bp)
    return handlePromptAction(bp, "tab")
end

function preInfoInsertNewline(bp)
    return handlePromptAction(bp, "enter")
end

function preInfoBackspace(bp)
    return handlePromptAction(bp, "backspace")
end

function preInfoDelete(bp)
    return handlePromptAction(bp, "delete")
end

function preInfoCursorLeft(bp)
    return handlePromptAction(bp, "left")
end

function preInfoCursorRight(bp)
    return handlePromptAction(bp, "right")
end

function preInfoCursorUp(bp)
    return handlePromptAction(bp, "up")
end

function preInfoCursorDown(bp)
    return handlePromptAction(bp, "down")
end

function preInfoStartOfTextToggle(bp)
    return handlePromptAction(bp, "home")
end

function preInfoEndOfLine(bp)
    return handlePromptAction(bp, "end")
end

function init()
    config.MakeCommand("find_in_file", find_in_file, config.NoComplete)
    config.MakeCommand("find_accross_files", find_accross_files, config.NoComplete)
    config.RegisterActionLabel("command:find_in_file", "find in file")
    config.RegisterActionLabel("command:find_accross_files", "find across files")
    config.AddRuntimeFile("search_and_replace", config.RTHelp, "help/search_and_replace.md")
end
