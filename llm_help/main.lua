VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")
local shell = import("micro/shell")

local PLUGIN = "llm_help"
local BUFFER_NAME = "LLM Help"
local API_URL = "https://api.openai.com/v1/chat/completions"

local state = {
    buf = nil,
    pane = nil,
    isSending = false,
    requestId = 0,
    streamBuffer = "",
    streamHasContent = false,
    streamSawDone = false,
    streamAssistantStarted = false,
}

local json = {}

local function skipDelim(str, pos, delim, errIfMissing)
    pos = pos + #str:match("^%s*", pos)
    if str:sub(pos, pos) ~= delim then
        if errIfMissing then
            error("Expected " .. delim .. " near position " .. pos)
        end
        return pos, false
    end
    return pos + 1, true
end

local function parseStrVal(str, pos, val)
    val = val or ""
    local earlyEndError = "End of input found while parsing string."
    if pos > #str then
        error(earlyEndError)
    end
    local c = str:sub(pos, pos)
    if c == '"' then
        return val, pos + 1
    end
    if c ~= "\\" then
        return parseStrVal(str, pos + 1, val .. c)
    end
    local escMap = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
    local nextc = str:sub(pos + 1, pos + 1)
    if not nextc then
        error(earlyEndError)
    end
    return parseStrVal(str, pos + 2, val .. (escMap[nextc] or nextc))
end

local function parseNumVal(str, pos)
    local numStr = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    local val = tonumber(numStr)
    if not val then
        error("Error parsing number at position " .. pos .. ".")
    end
    return val, pos + #numStr
end

json.null = {}

function json.parse(str, pos, endDelim)
    pos = pos or 1
    if pos > #str then
        error("Reached unexpected end of input.")
    end
    pos = pos + #str:match("^%s*", pos)
    local first = str:sub(pos, pos)
    if first == "{" then
        local obj, key, delimFound = {}, true, true
        pos = pos + 1
        while true do
            key, pos = json.parse(str, pos, "}")
            if key == nil then
                return obj, pos
            end
            if not delimFound then
                error("Comma missing between object items.")
            end
            pos = skipDelim(str, pos, ":", true)
            obj[key], pos = json.parse(str, pos)
            pos, delimFound = skipDelim(str, pos, ",")
        end
    elseif first == "[" then
        local arr, val, delimFound = {}, true, true
        pos = pos + 1
        while true do
            val, pos = json.parse(str, pos, "]")
            if val == nil then
                return arr, pos
            end
            if not delimFound then
                error("Comma missing between array items.")
            end
            arr[#arr + 1] = val
            pos, delimFound = skipDelim(str, pos, ",")
        end
    elseif first == '"' then
        return parseStrVal(str, pos + 1)
    elseif first == "-" or first:match("%d") then
        return parseNumVal(str, pos)
    elseif first == endDelim then
        return nil, pos + 1
    else
        local literals = { ["true"] = true, ["false"] = false, ["null"] = json.null }
        for litStr, litVal in pairs(literals) do
            local litEnd = pos + #litStr - 1
            if str:sub(pos, litEnd) == litStr then
                return litVal, litEnd + 1
            end
        end
        error("Invalid json syntax at position " .. pos)
    end
end

local function jsonEscape(str)
    return ((str or "")
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\b", "\\b")
        :gsub("\f", "\\f")
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t"))
end

local function jsonQuote(str)
    return '"' .. jsonEscape(str) .. '"'
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

local function bufferAlive(buf)
    if buf == nil then
        return false
    end
    return pcall(function()
        return buf:LinesNum()
    end)
end

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

local function sessionTemplate()
    return { "# User", "", "" }
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

local function appendBufferText(buf, text)
    if text == nil or text == "" then
        return
    end

    local wasReadonly = buf.Settings["readonly"]
    if wasReadonly then
        buf:SetOptionNative("readonly", false)
    end

    buf:insert(buf:End(), text)

    if wasReadonly then
        buf:SetOptionNative("readonly", true)
    end
end

local function trimBlankEdges(lines)
    local startIdx = 1
    local endIdx = #lines

    while startIdx <= endIdx and lines[startIdx]:match("^%s*$") do
        startIdx = startIdx + 1
    end

    while endIdx >= startIdx and lines[endIdx]:match("^%s*$") do
        endIdx = endIdx - 1
    end

    if startIdx > endIdx then
        return {}
    end

    local trimmed = {}
    for i = startIdx, endIdx do
        trimmed[#trimmed + 1] = lines[i]
    end
    return trimmed
end

local function flushMessage(messages, role, lines)
    if role == nil then
        return
    end

    local trimmed = trimBlankEdges(lines)
    if #trimmed == 0 then
        return
    end

    messages[#messages + 1] = {
        role = role,
        content = table.concat(trimmed, "\n"),
    }
end

local function matchHeader(line, roleName)
    local header = "# " .. roleName
    if line == header then
        return ""
    end
    return line:match("^# " .. roleName .. "%s+(.+)$")
end

local function hasConversationHeaders(lines)
    for _, line in ipairs(lines) do
        if matchHeader(line, "User") ~= nil or matchHeader(line, "Assistant") ~= nil then
            return true
        end
    end
    return false
end

local function promoteUnlabeledInputToUser(buf)
    local lines = bufferLines(buf)
    if hasConversationHeaders(lines) or #trimBlankEdges(lines) == 0 then
        return lines
    end

    local updated = { "# User", "" }
    for _, line in ipairs(lines) do
        updated[#updated + 1] = line
    end

    replaceWholeBuffer(buf, joinLines(updated))
    buf:SetOptionNative("filetype", "markdown")
    local cur = buf:GetActiveCursor()
    cur:GotoLoc(buf:End())
    if paneAlive(state.pane) and state.pane.Buf == state.buf and state.pane.Relocate then
        state.pane:Relocate()
    end
    return updated
end

local function parseMessages(lines)
    local messages = {}
    local currentRole = nil
    local currentContent = {}

    for _, line in ipairs(lines) do
        local userInline = matchHeader(line, "User")
        local assistantInline = matchHeader(line, "Assistant")

        if userInline ~= nil then
            flushMessage(messages, currentRole, currentContent)
            currentRole = "user"
            currentContent = {}
            if userInline ~= "" then
                currentContent[#currentContent + 1] = userInline
            end
        elseif assistantInline ~= nil then
            flushMessage(messages, currentRole, currentContent)
            currentRole = "assistant"
            currentContent = {}
            if assistantInline ~= "" then
                currentContent[#currentContent + 1] = assistantInline
            end
        elseif currentRole ~= nil then
            currentContent[#currentContent + 1] = line
        end
    end

    flushMessage(messages, currentRole, currentContent)
    return messages
end

local function ensureSessionBuffer()
    if bufferAlive(state.buf) then
        return state.buf
    end

    state.buf = buffer.NewScratchBuffer(joinLines(sessionTemplate()), BUFFER_NAME)
    state.buf:SetOptionNative("filetype", "markdown")
    state.buf:SetOptionNative("softwrap", true)
    state.buf:SetOptionNative("wordwrap", true)
    state.pane = nil
    return state.buf
end

local function moveCursorToEnd()
    if not paneAlive(state.pane) or state.pane.Buf ~= state.buf then
        return
    end
    local cur = state.pane.Buf:GetActiveCursor()
    cur:GotoLoc(state.pane.Buf:End())
    if state.pane.Relocate then
        state.pane:Relocate()
    end
end

local function ensureSessionPane(bp)
    local chatBuf = ensureSessionBuffer()
    bp = bp or micro.CurPane()
    if bp == nil then
        updateStatus("llm_help: no active pane", true)
        return nil
    end

    if bp.Buf == chatBuf then
        state.pane = bp
        moveCursorToEnd()
        return bp
    end

    state.pane = bp:HSplitBuf(chatBuf)
    moveCursorToEnd()
    return state.pane
end

local function commandExists(cmd)
    local _, err = shell.RunCommand("sh -c 'command -v " .. cmd .. " >/dev/null 2>&1'")
    return err == nil
end

local function activeModel()
    local model = config.GetGlobalOption(PLUGIN .. ".model")
    if model == nil or model == "" then
        return "gpt-4.1-mini"
    end
    return model
end

local function buildRequestBody(messages, stream)
    local encoded = {}
    for _, message in ipairs(messages) do
        encoded[#encoded + 1] = "{" ..
            '"role":' .. jsonQuote(message.role) .. "," ..
            '"content":' .. jsonQuote(message.content) ..
            "}"
    end

    return "{" ..
        '"model":' .. jsonQuote(activeModel()) .. "," ..
        '"messages":[' .. table.concat(encoded, ",") .. "]," ..
        '"stream":' .. (stream and "true" or "false") ..
        "}"
end

local function writeRequestFile(messages, stream)
    local path = os.tmpname()
    local file = io.open(path, "w")
    if file == nil then
        return nil, "llm_help: could not create request file"
    end

    file:write(buildRequestBody(messages, stream))
    file:close()
    return path, nil
end

local function splitHttpStatus(output)
    local body, status = (output or ""):match("^(.*)\nHTTP_STATUS:(%d%d%d)\n?$")
    if body == nil then
        return output or "", nil
    end
    return body, status
end

local function decodeResponseBody(body)
    local ok, decoded = pcall(json.parse, body or "")
    if not ok or decoded == nil then
        local message = trim(body)
        if message ~= "" then
            return nil, message
        end
        return nil, "invalid response from OpenAI"
    end

    if decoded.error and decoded.error.message then
        return nil, decoded.error.message
    end

    local choices = decoded.choices
    local choice = choices and choices[1]
    local message = choice and choice.message
    local content = message and message.content

    if type(content) == "string" and content ~= "" then
        return content, nil
    end

    if type(content) == "table" then
        local parts = {}
        for _, part in ipairs(content) do
            if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
                parts[#parts + 1] = part.text
            end
        end
        if #parts > 0 then
            return table.concat(parts, "\n\n"), nil
        end
    end

    return nil, "no assistant message in response"
end

local function appendAssistantResponse(text)
    local buf = ensureSessionBuffer()
    local lines = bufferLines(buf)

    if #lines > 0 and lines[#lines] ~= "" then
        lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "# Assistant"
    lines[#lines + 1] = ""

    local responseLines = splitLines(text)
    if #responseLines == 0 then
        responseLines = { "" }
    end
    for _, line in ipairs(responseLines) do
        lines[#lines + 1] = line
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "# User"
    lines[#lines + 1] = ""

    replaceWholeBuffer(buf, joinLines(lines))
    buf:SetOptionNative("filetype", "markdown")
    moveCursorToEnd()
end

local function resetStreamState()
    state.streamBuffer = ""
    state.streamHasContent = false
    state.streamSawDone = false
    state.streamAssistantStarted = false
end

local function ensureAssistantSectionStarted()
    if state.streamAssistantStarted then
        return
    end

    local buf = ensureSessionBuffer()
    local prefix = ""
    if buf:LinesNum() > 0 and buf:Line(buf:LinesNum() - 1) ~= "" then
        prefix = "\n\n"
    end
    appendBufferText(buf, prefix .. "# Assistant\n\n")
    state.streamAssistantStarted = true
    moveCursorToEnd()
end

local function appendAssistantChunk(text)
    if text == nil or text == "" then
        return
    end

    ensureAssistantSectionStarted()
    appendBufferText(ensureSessionBuffer(), text)
    if not state.streamHasContent then
        updateStatus("Streaming response...", false)
    end
    state.streamHasContent = true
    moveCursorToEnd()
end

local function finishAssistantSection()
    if not state.streamAssistantStarted then
        return
    end

    local buf = ensureSessionBuffer()
    local suffix = "\n\n# User\n\n"
    if buf:LinesNum() > 0 and buf:Line(buf:LinesNum() - 1) == "" then
        suffix = "# User\n\n"
    end
    appendBufferText(buf, suffix)
    moveCursorToEnd()
end

local function handleStreamPayload(payload)
    local ok, decoded = pcall(json.parse, payload)
    if not ok or decoded == nil then
        return
    end

    local choice = decoded.choices and decoded.choices[1]
    local delta = choice and choice.delta
    local content = delta and delta.content

    if type(content) == "string" then
        appendAssistantChunk(content)
    elseif type(content) == "table" then
        for _, part in ipairs(content) do
            if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
                appendAssistantChunk(part.text)
            end
        end
    end

    if choice ~= nil and choice.finish_reason ~= nil then
        state.streamSawDone = true
    end
end

local function handleStreamLine(line)
    if line == nil or line == "" then
        return
    end
    if line:match("^HTTP_STATUS:") then
        return
    end

    local payload = line:match("^data:%s?(.*)$")
    if payload == nil then
        return
    end
    if payload == "[DONE]" then
        state.streamSawDone = true
        return
    end

    handleStreamPayload(payload)
end

local function processStreamOutput(chunk, finalFlush)
    if chunk ~= nil and chunk ~= "" then
        state.streamBuffer = state.streamBuffer .. chunk
    end

    while true do
        local nl = state.streamBuffer:find("\n", 1, true)
        if nl == nil then
            break
        end
        local line = state.streamBuffer:sub(1, nl - 1):gsub("\r$", "")
        state.streamBuffer = state.streamBuffer:sub(nl + 1)
        handleStreamLine(line)
    end

    if finalFlush and state.streamBuffer ~= "" then
        local line = state.streamBuffer:gsub("\r$", "")
        state.streamBuffer = ""
        handleStreamLine(line)
    end
end

local function onStreamStdout(output, userargs)
    local requestId = userargs[1]
    if requestId ~= state.requestId then
        return
    end
    processStreamOutput(output, false)
end

local function finishRequest(output, userargs)
    local requestId = userargs[1]
    local requestPath = userargs[2]

    if requestPath ~= nil and requestPath ~= "" then
        os.remove(requestPath)
    end

    if requestId ~= state.requestId then
        return
    end

    processStreamOutput("", true)

    state.isSending = false
    if bufferAlive(state.buf) then
        state.buf:SetOptionNative("readonly", false)
        state.buf:SetOptionNative("filetype", "markdown")
    end

    local body, status = splitHttpStatus(output)
    if status ~= nil and status ~= "200" then
        local _, err = decodeResponseBody(body)
        resetStreamState()
        updateStatus("OpenAI error (" .. status .. "): " .. (err or trim(body)), true)
        return
    end

    if state.streamHasContent or state.streamSawDone then
        finishAssistantSection()
        resetStreamState()
        updateStatus("Ready", false)
        return
    end

    local responseText, err = decodeResponseBody(body)
    if err ~= nil then
        resetStreamState()
        updateStatus("llm_help: " .. err, true)
        return
    end

    appendAssistantResponse(responseText)
    resetStreamState()
    updateStatus("Ready", false)
end

local function sendToOpenAI(messages)
    if not commandExists("curl") then
        updateStatus("llm_help: required command not found: curl", true)
        return
    end

    local apiKey = os.getenv("OPENAI_API_KEY")
    if apiKey == nil or apiKey == "" then
        updateStatus("OPENAI_API_KEY is not set", true)
        return
    end

    local requestPath, err = writeRequestFile(messages, true)
    if err ~= nil then
        updateStatus(err, true)
        return
    end

    state.isSending = true
    state.requestId = state.requestId + 1
    resetStreamState()
    ensureSessionBuffer():SetOptionNative("readonly", true)
    updateStatus("Sending to OpenAI...", false)

    shell.JobSpawn("curl", {
        "-sS",
        "-N",
        API_URL,
        "-H", "Accept: text/event-stream",
        "-H", "Content-Type: application/json",
        "-H", "Authorization: Bearer " .. apiKey,
        "--data", "@" .. requestPath,
        "-w", "\nHTTP_STATUS:%{http_code}",
    }, onStreamStdout, nil, finishRequest, state.requestId, requestPath)
end

function openChat(bp)
    local pane = ensureSessionPane(bp)
    if pane == nil then
        return
    end
    updateStatus("Ready", false)
end

function clearChat(bp)
    if state.isSending then
        updateStatus("Wait for the current response before clearing the session", true)
        return
    end

    ensureSessionBuffer()
    replaceWholeBuffer(state.buf, joinLines(sessionTemplate()))
    state.buf:SetOptionNative("readonly", false)
    state.buf:SetOptionNative("filetype", "markdown")
    if bp ~= nil and bp.Buf == state.buf then
        state.pane = bp
    end
    moveCursorToEnd()
    updateStatus("Started a fresh chat session", false)
end

function submitChat(bp)
    if state.isSending then
        updateStatus("Already waiting for a response", false)
        return false
    end

    if bp ~= nil and bp.Buf == state.buf then
        state.pane = bp
    end

    local buf = ensureSessionBuffer()
    local messages = parseMessages(promoteUnlabeledInputToUser(buf))
    if #messages == 0 then
        updateStatus("Write a prompt under # User before sending", true)
        return false
    end

    if messages[#messages].role ~= "user" then
        updateStatus("The last message must be under # User", true)
        return false
    end

    sendToOpenAI(messages)
    return true
end

function submitChatIfActive(bp)
    if bp == nil or bp.Buf == nil or state.buf == nil or bp.Buf ~= state.buf then
        return false
    end
    return submitChat(bp)
end

function init()
    config.RegisterGlobalOption(PLUGIN, "model", "gpt-4.1-mini")
    config.MakeCommand("llmhelp", openChat, config.NoComplete)
    config.MakeCommand("llmhelpsend", submitChat, config.NoComplete)
    config.MakeCommand("llmhelpclear", clearChat, config.NoComplete)
    config.RegisterActionLabel("command:llmhelp", "llm help")
    config.RegisterActionLabel("command:llmhelpsend", "send chat")
    config.RegisterActionLabel("command:llmhelpclear", "clear chat")
    config.RegisterActionLabel("lua:llm_help.submitChatIfActive", "send chat")
    config.AddRuntimeFile(PLUGIN, config.RTHelp, "help/llm_help.md")
end
