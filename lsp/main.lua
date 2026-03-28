VERSION = "0.6.3"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local util = import("micro/util")
local buffer = import("micro/buffer")
local fmt = import("fmt")
local go_os = import("os")
local path = import("path")
local filepath = import("path/filepath")

local cmd = {}
local id = {}
local version = {}
local currentAction = {}
local capabilities = {}
local filetype = ''
local rootUri = ''
local message = ''
local completionCursor = 0
local lastCompletion = {}
local splitBP = nil
local refOriginPane = nil
local completionRequestToken = {}
local diagnosticsByURI = {}

local completionDebounceNs = 75 * 1000000

local json = {}

function toBytes(str)
	local result = {}
	for i=1,#str do 
		local b = str:byte(i)
		if b < 32 then 
			table.insert(result, b)
		end
	end
	return result
end

function getUriFromBuf(buf)
	if buf == nil then return; end
	local file = buf.AbsPath
	local uri = fmt.Sprintf("file://%s", file)
	return uri
end

function mysplit (inputstr, sep)
        if sep == nil then
                sep = "%s"
        end
        local t={}
        for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
                table.insert(t, str)
        end
        return t
end

function table.join(tbl, sep)
	local result = ''
	for _, value in ipairs(tbl) do
		result = result .. (#result > 0 and sep or '') .. value
	end
	return result
end

function parseOptions(inputstr)
	return mysplit(inputstr, ',')
end

function startServer(filetype, callback)
	local wd, _ = go_os.Getwd()
	rootUri = fmt.Sprintf("file://%s", wd)
	local envSettings, _ = go_os.Getenv("MICRO_LSP")
	local settings = config.GetGlobalOption("lsp.server")
	local fallback = "python=pylsp,go=gopls,typescript=deno lsp,javascript=deno lsp,markdown=deno lsp,json=deno lsp,jsonc=deno lsp,rust=rust-analyzer,lua=lua-language-server,c++=clangd,dart=dart language-server"
	if envSettings ~= nil and #envSettings > 0 then
		settings = envSettings
	end
	if settings ~= nil and #settings > 0 then
		settings = settings .. "," .. fallback
	else
		settings = fallback
	end
	local server = parseOptions(settings)
	micro.Log("Server Options", server)
	for i in ipairs(server) do
		local part = mysplit(server[i], "=")
		local run = mysplit(part[2] or '', "%s")
		local initOptions = part[3] or '{}'
		local runCmd = table.remove(run, 1)
		local args = run
		for idx, narg in ipairs(args) do
			args[idx] = narg:gsub("%%[a-zA-Z0-9][a-zA-Z0-9]", function(entry)
				return string.char(tonumber(entry:sub(2), 16))
			end)
		end
		if filetype == part[1] then
		local send = withSend(part[1])
		if cmd[part[1]] ~= nil then return; end
			id[part[1]] = 0
			micro.Log("Starting server", part[1])
			cmd[part[1]] = shell.JobSpawn(runCmd, args, onStdout(part[1]), onStderr, onExit(part[1]), {})
			currentAction[part[1]] = { method = "initialize", response = function (bp, data)
			    send("initialized", "{}", true)
				capabilities[filetype] = data.result and data.result.capabilities or {}
			    callback(bp.Buf, filetype)
			end }
			send(currentAction[part[1]].method, fmt.Sprintf('{"processId": %.0f, "rootUri": "%s", "workspaceFolders": [{"name": "root", "uri": "%s"}], "initializationOptions": %s, "capabilities": {"workspace": {"configuration": true}, "textDocument": {"completion": {"completionItem": {"documentationFormat": ["plaintext", "markdown"], "preselectSupport": true, "deprecatedSupport": true}}, "hover": {"contentFormat": ["plaintext", "markdown"]}, "publishDiagnostics": {"relatedInformation": false, "versionSupport": false, "codeDescriptionSupport": true, "dataSupport": true}, "signatureHelp": {"signatureInformation": {"documentationFormat": ["plaintext", "markdown"]}}}}}', go_os.Getpid(), rootUri, rootUri, initOptions))
			return
		end
	end
end

function init()
	config.RegisterCommonOption("lsp", "server", "python=pylsp,go=gopls,typescript=deno lsp,javascript=deno lsp,markdown=deno lsp,json=deno lsp,jsonc=deno lsp,rust=rust-analyzer,lua=lua-language-server,c++=clangd,dart=dart language-server")
	config.RegisterCommonOption("lsp", "formatOnSave", false)
	config.RegisterCommonOption("lsp", "autocompleteDetails", false)
	config.RegisterCommonOption("lsp", "ignoreMessages", "")
	config.RegisterCommonOption("lsp", "tabcompletion", true)
	config.RegisterCommonOption("lsp", "ignoreTriggerCharacters", "completion")
	-- example to ignore all LSP server message starting with these strings:
	-- "lsp.ignoreMessages": "Skipping analyzing |See https://"
	
	config.MakeCommand("hover", hoverAction, config.NoComplete)
	config.MakeCommand("definition", definitionAction, config.NoComplete)
	config.MakeCommand("lspcompletion", completionAction, config.NoComplete)
	config.MakeCommand("format", formatAction, config.NoComplete)
	config.MakeCommand("references", referencesAction, config.NoComplete)
	config.MakeCommand("rename", renameAction, config.NoComplete)
	config.MakeCommand("nextdiag", nextDiagnostic, config.NoComplete)
	config.MakeCommand("prevdiag", prevDiagnostic, config.NoComplete)

	config.TryBindKey("Alt-k", "command:hover", false)
	config.TryBindKey("Alt-d", "command:definition", false)
	config.TryBindKey("Alt-f", "command:format", false)
	config.TryBindKey("Alt-r", "command:references", false)
	config.TryBindKey("CtrlSpace", "command:lspcompletion", false)
	config.TryBindKey("F2", "command-edit:rename ", false)

	config.AddRuntimeFile("lsp", config.RTHelp, "help/lsp.md")

	-- @TODO register additional actions here
end

function withSend(filetype)
	return function (method, params, isNotification) 
	    if cmd[filetype] == nil then
	    	return
	    end

		micro.Log(filetype .. ">>> " .. method, not isNotification and (" id=" .. id[filetype]) or "")
		local msg = fmt.Sprintf('{"jsonrpc": "2.0", %s"method": "%s", "params": %s}', not isNotification and fmt.Sprintf('"id": %.0f, ', id[filetype]) or "", method, params)
		id[filetype] = id[filetype] + 1
		msg = fmt.Sprintf("Content-Length: %.0f\r\n\r\n%s", #msg, msg)
		--micro.Log("send", filetype, "sending", method or msg, msg)
		shell.JobSend(cmd[filetype], msg)
	end
end

function closeSplitPane()
	if splitBP ~= nil then
		pcall(function () splitBP:Unsplit(); end)
		splitBP = nil
	end
end

function preRune(bp, r)
	if splitBP ~= nil then
		closeSplitPane()
		local cur = bp.Buf:GetActiveCursor()
		cur:Deselect(false);
		cur:GotoLoc(buffer.Loc(cur.X + 1, cur.Y))
	end
end

-- when a new character is types, the document changes
function onRune(bp, r)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then
		return
	end
	closeSplitPane()

	local send = withSend(filetype)
	local uri = getUriFromBuf(bp.Buf)
	if r ~= nil then
		lastCompletion = {}
	end
	-- allow the document contents to be escaped properly for the JSON string
	local content = util.String(bp.Buf:Bytes()):gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub('"', '\\"'):gsub("\t", "\\t")
	-- increase change version
	version[uri] = (version[uri] or 0) + 1
	send("textDocument/didChange", fmt.Sprintf('{"textDocument": {"version": %.0f, "uri": "%s"}, "contentChanges": [{"text": "%s"}]}', version[uri], uri, content), true)
	local ignored = mysplit(config.GetGlobalOption("lsp.ignoreTriggerCharacters") or '', ",")
	if capabilities[filetype] then
		if r and not contains(ignored, "completion") and r == '.' and capabilities[filetype].completionProvider and capabilities[filetype].completionProvider.triggerCharacters and contains(capabilities[filetype].completionProvider.triggerCharacters, r) then
			scheduleCompletionAction(bp)
		elseif shouldAutoTriggerCompletion(bp, r) then
			scheduleCompletionAction(bp)
		elseif r and not contains(ignored, "signature") and capabilities[filetype].signatureHelpProvider and capabilities[filetype].signatureHelpProvider.triggerCharacters and contains(capabilities[filetype].signatureHelpProvider.triggerCharacters, r) then
			hoverAction(bp)
		end
	end
end

-- alias functions for any kind of change to the document
function onMoveLinesUp(bp) onRune(bp) end
function onMoveLinesDown(bp) onRune(bp) end
function onDeleteWordRight(bp) onRune(bp) end
function onDeleteWordLeft(bp) onRune(bp) end
function onInsertNewline(bp) onRune(bp) end
function onInsertSpace(bp) onRune(bp) end
function onBackspace(bp) onRune(bp) end
function onDelete(bp) onRune(bp) end
function onInsertTab(bp) onRune(bp) end
function onUndo(bp) onRune(bp) end
function onRedo(bp) onRune(bp) end
function onCut(bp) onRune(bp) end
function onCutLine(bp) onRune(bp) end
function onDuplicateLine(bp) onRune(bp) end
function onDeleteLine(bp) onRune(bp) end
function onIndentSelection(bp) onRune(bp) end
function onOutdentSelection(bp) onRune(bp) end
function onOutdentLine(bp) onRune(bp) end
function onIndentLine(bp) onRune(bp) end
function onPaste(bp) onRune(bp) end
function onPlayMacro(bp) onRune(bp) end
function onAutocomplete(bp) end

function onEscape(bp) 
	closeSplitPane()
end

function preInsertNewline(bp)
	if bp.Buf.Path == "References found" then
		local cur = bp.Buf:GetActiveCursor()
		cur:SelectLine()
		local data = util.String(cur:GetSelection())
		local file, line, character = data:match("(./[^:]+):([^:]+):([^:]+)")
		local doc, _ = file:gsub("^file://", "")
		local newBuf, _ = buffer.NewBufferFromFile(doc)
		-- Record position in the origin pane before navigating
		if refOriginPane ~= nil then
			refOriginPane:PushJump()
			refOriginPane:OpenBuffer(newBuf)
			newBuf:GetActiveCursor():GotoLoc(buffer.Loc(character * 1, line * 1))
			refOriginPane:Center()
		end
		return false
	end
end

function preSave(bp)
	if config.GetGlobalOption("lsp.formatOnSave") then
		onRune(bp)
		formatAction(bp, function ()
			bp:Save()
		end)
	end
end

function onSave(bp)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then
		return
	end

	local send = withSend(filetype)
	local uri = getUriFromBuf(bp.Buf)

	send("textDocument/didSave", fmt.Sprintf('{"textDocument": {"uri": "%s"}}', uri), true)
end

function handleInitialized(buf, filetype)
	if cmd[filetype] == nil then return; end
	micro.Log("Found running lsp server for ", filetype, "firing textDocument/didOpen...")
	local send = withSend(filetype)
	local uri = getUriFromBuf(buf)
	local content = util.String(buf:Bytes()):gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub('"', '\\"'):gsub("\t", "\\t")
	send("textDocument/didOpen", fmt.Sprintf('{"textDocument": {"uri": "%s", "languageId": "%s", "version": 1, "text": "%s"}}', uri, filetype, content), true)
end

function onBufferOpen(buf)
	local filetype = buf:FileType()
	micro.Log("ONBUFFEROPEN", filetype)
	if filetype ~= "unknown" and not cmd[filetype] then return startServer(filetype, handleInitialized); end
	if cmd[filetype] then
	    handleInitialized(buf, filetype)
	end
end

function contains(list, x)
	for _, v in pairs(list) do
		if v == x then return true; end
	end
	return false
end

function string.starts(String, Start)
	return string.sub(String, 1, #Start) == Start
end

function string.ends(String, End)
	return string.sub(String, #String - (#End - 1), #String) == End
end

function string.random(CharSet, Length, prefix)

   local _CharSet = CharSet or '.'

   if _CharSet == '' then
      return ''
   else
      local Result = prefix or ""
      math.randomseed(os.time())
      for Loop = 1,Length do
	      local char = math.random(1, #CharSet)
         Result = Result .. CharSet:sub(char,char)
      end

      return Result
   end
end

function string.parse(text)
	if not text:find('"jsonrpc":') then return {}; end
	local start,fin = text:find("\n%s*\n")
	local cleanedText = text
	if fin ~= nil then
		cleanedText = text:sub(fin)
	end
	local status, res = pcall(json.parse, cleanedText)
	if status then
		return res
	end
	micro.Log("LSP parse failure", cleanedText)
	return false
end

function isIgnoredMessage(msg)
	-- Return true if msg matches one of the ignored starts of messages
	-- Useful for linters that show spurious, hard to disable warnings
	local ignoreList = mysplit(config.GetGlobalOption("lsp.ignoreMessages"), "|")
	for i, ignore in pairs(ignoreList) do
		if string.match(msg, ignore) then -- match from start of string
			micro.Log("Ignore message: '", msg, "', because it matched: '", ignore, "'.")
			return true -- ignore this message, dont show to user
		end
	end
	return false -- show this message to user
end

function configurationValue(section)
	if section == "python.analysis" then
		return '{"autoImportCompletions": true, "autoSearchPaths": true}'
	elseif section == "python" then
		return '{"analysis": {"autoImportCompletions": true, "autoSearchPaths": true}}'
	elseif section == "pyright" then
		return '{}'
	end
	return '{"enable": true}'
end

function configurationItems(params)
	if not params or not params.items then
		return {}
	end
	local items = {}
	for key, item in pairs(params.items) do
		if type(key) == 'number' then
			items[key] = item
		end
	end
	return items
end

function configurationResult(params)
	local results = {}
	local items = configurationItems(params)
	if #items == 0 then
		return '[{"analysis": {"autoImportCompletions": true, "autoSearchPaths": true}}]'
	end
	for _, item in ipairs(items) do
		table.insert(results, configurationValue(item.section or ''))
	end
	return '[' .. table.join(results, ',') .. ']'
end

function onStdout(filetype)
	return function (text)
		if text:starts("Content-Length:") then
			message = text
		else
			message = message .. text
		end
		if not text:ends("}") then
			return
		end	
		local data = message:parse()
		if data == false then
			return
		end

		micro.Log(filetype .. " <<< " .. (data.method or 'no method'))
		
		if data.method == "workspace/configuration" then
		    -- actually needs to respond with the same ID as the received JSON
			micro.Log(filetype .. " <<< workspace/configuration params", data.params)
			local message = fmt.Sprintf('{"jsonrpc": "2.0", "id": %.0f, "result": %s}', data.id, configurationResult(data.params))
			micro.Log(filetype .. " >>> workspace/configuration response", message)
			shell.JobSend(cmd[filetype], fmt.Sprintf('Content-Length: %.0f\r\n\r\n%s', #message, message))
		elseif data.method == "textDocument/publishDiagnostics" or data.method == "textDocument\\/publishDiagnostics" then
			-- react to server-published event
			local uri = data.params.uri
			local uriDiagnostics = {}
			diagnosticsByURI[uri] = uriDiagnostics
			local bp = micro.CurPane().Buf
			local currentURI = getUriFromBuf(bp)
			if uri == currentURI then
				bp:ClearMessages("lsp")
				bp:AddMessage(buffer.NewMessage("lsp", "", buffer.Loc(0, 10000000), buffer.Loc(0, 10000000), buffer.MTInfo))
			end
			for _, diagnostic in ipairs(data.params.diagnostics) do
				local type = buffer.MTInfo
				if diagnostic.severity == 1 then
					type = buffer.MTError
				elseif diagnostic.severity == 2 then
					type = buffer.MTWarning
				end
				local mstart = buffer.Loc(diagnostic.range.start.character, diagnostic.range.start.line)
		            local mend = buffer.Loc(diagnostic.range["end"].character, diagnostic.range["end"].line)

				if not isIgnoredMessage(diagnostic.message) then
					local msg = buffer.NewMessage("lsp", diagnostic.message, mstart, mend, type)
					table.insert(uriDiagnostics, msg)
					if uri == currentURI then
						bp:AddMessage(msg)
					end
		            end
			end
		elseif currentAction[filetype] and currentAction[filetype].method and not data.method and currentAction[filetype].response and data.jsonrpc then			-- react to custom action event
			local bp = micro.CurPane()
			micro.Log("Received message for ", filetype, data)
			micro.Log(filetype .. " <<< response", " id=", data.id or "nil", " expected=", currentAction[filetype].method)
			if data.error then
				micro.Log(filetype .. " <<< error", data.error)
			end
			currentAction[filetype].response(bp, data)
			currentAction[filetype] = {}
		elseif data.method == "window/showMessage" or data.method == "window\\/showMessage" then
			if filetype == micro.CurPane().Buf:FileType() then
				micro.InfoBar():Message(data.params.message)
			else
				micro.Log(filetype .. " message " .. data.params.message)
			end
		elseif data.method == "window/logMessage" or data.method == "window\\/logMessage" then
			micro.Log(data.params.message)
		elseif message:starts("Content-Length:") then
			if message:find('"') and not message:find('"result":null') then
				micro.Log("Unhandled message 1", filetype, message)
			end
		else
			-- enable for debugging purposes
			micro.Log("Unhandled message 2", filetype, message)
		end
	end
end

function onStderr(text)
	micro.Log("ONSTDERR", text)
	if not isIgnoredMessage(text) then
		micro.InfoBar():Message(text)
	end
end

function onExit(filetype)
	return function (str)
		currentAction[filetype] = nil
		cmd[filetype] = nil
		micro.Log("ONEXIT", filetype, str)
	end
end

-- the actual hover action request and response
-- the hoverActionResponse is hooked up in 
function hoverAction(bp)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] ~= nil then
		local send = withSend(filetype)
		local file = bp.Buf.AbsPath
		local line = bp.Buf:GetActiveCursor().Y
		local char = bp.Buf:GetActiveCursor().X
		currentAction[filetype] = { method = "textDocument/hover", response = hoverActionResponse }
		send(currentAction[filetype].method, fmt.Sprintf('{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}}', file, line, char))
	end
end

function hoverActionResponse(buf, data)
	if data.result and data.result.contents ~= nil and data.result.contents ~= "" then
		if data.result.contents.value then
			micro.InfoBar():Message(data.result.contents.value)
		elseif #data.result.contents > 0 then
			micro.InfoBar():Message(data.result.contents[1].value)
		end
	end
end

-- the definition action request and response
function definitionAction(bp)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then return; end

	micro.PushJump()

	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local line = bp.Buf:GetActiveCursor().Y
	local char = bp.Buf:GetActiveCursor().X
	currentAction[filetype] = { method = "textDocument/definition", response = definitionActionResponse }
	send(currentAction[filetype].method, fmt.Sprintf('{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}}', file, line, char))
end

function definitionActionResponse(bp, data)
	local results = data.result or data.partialResult
	if results == nil then return; end
	local file = bp.Buf.AbsPath
	if results.uri ~= nil then
		-- single result
		results = { results }
	end
	if #results <= 0 then return; end
	local uri = (results[1].uri or results[1].targetUri)
	local doc = uri:gsub("^file://", ""):gsub('%%[a-f0-9][a-f0-9]', function(x, y, z) print("X", x); return string.char(tonumber(x:gsub('%%', ''), 16)) end)
	local buf = bp.Buf
	if file ~= doc then
		-- it's from a different file, so open it as a new tab
		buf, _ = buffer.NewBufferFromFile(doc)
		bp:AddTab()
		micro.CurPane():OpenBuffer(buf)
		-- shorten the displayed name in status bar
		name = buf:GetName()
    	local wd, _ = go_os.Getwd()
		if name:starts(wd) then
    		buf:SetName("." .. name:sub(#wd + 1, #name + 1))
		else 
		  if #name > 30 then
		     buf:SetName("..." .. name:sub(-30, #name + 1))
		  end
		end
	end
	local range = results[1].range or results[1].targetSelectionRange
	buf:GetActiveCursor():GotoLoc(buffer.Loc(range.start.character, range.start.line))
	bp:Center()
end

function completionAction(bp)
	local filetype = bp.Buf:FileType()
	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local line = bp.Buf:GetActiveCursor().Y
	local char = bp.Buf:GetActiveCursor().X

	if lastCompletion[1] == file and lastCompletion[2] == line and lastCompletion[3] == char then 
		completionCursor = completionCursor + 1
	else
		completionCursor = 0
		if bp.Cursor:HasSelection() then
			-- we have a selection
			-- assume we want to indent the selection
			bp:IndentSelection()
			return
		end
		if char == 0 then
			-- we are at the very first character of a line
			-- assume we want to indent
			bp:IndentLine()
			return
		end
		local cur = bp.Buf:GetActiveCursor()
		cur:SelectLine()
		local lineContent = util.String(cur:GetSelection())
		cur:ResetSelection()
		cur:GotoLoc(buffer.Loc(char, line))
		local startOfLine = "" .. lineContent:sub(1, char)
		if startOfLine:match("^%s+$") then
			-- we are at the beginning of a line
			-- assume we want to indent the line
			bp:IndentLine()
			return
		end
	end
	if cmd[filetype] == nil then return; end
	lastCompletion = {file, line, char}
	currentAction[filetype] = { method = "textDocument/completion", response = completionActionResponse }
	send(currentAction[filetype].method, fmt.Sprintf('{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}}', file, line, char))
end

table.filter = function(t, filterIter)
  local out = {}

  for k, v in pairs(t) do
    if filterIter(v, k, t) then table.insert(out, v) end
  end

  return out
end

function findCommon(input, list)
	local commonLen = 0
	local prefixList = {}
	local str = input.textEdit and input.textEdit.newText or input.label
	for i = 1,#str,1 do
		local prefix = str:sub(1, i)
		prefixList[prefix] = 0
		for idx, entry in ipairs(list) do
			local currentEntry = entry.textEdit and entry.textEdit.newText or entry.label
			if currentEntry:starts(prefix) then
				prefixList[prefix] = prefixList[prefix] + 1
			end
		end
	end
	local longest = ""
	for idx, entry in pairs(prefixList) do
		if entry >= #list then
			if #longest < #idx then
				longest = idx
			end
		end
	end
	if #list == 1 then
		return list[1].textEdit and list[1].textEdit.newText or list[1].label
	end
	return longest
end

function jsonEscape(str)
	return (str or ''):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
end

function normalizeInsertText(entry)
	if entry.insertTextFormat == 2 then
		return entry.label or ''
	end
	return entry.textEdit and entry.textEdit.newText or entry.insertText or entry.label or ''
end

function serializeAdditionalTextEdits(entry)
	local out = {}
	for _, edit in ipairs(entry.additionalTextEdits or {}) do
		if edit.range and edit.range.start and edit.range['end'] then
			table.insert(out, fmt.Sprintf('{"text":"%s","start":{"x":%.0f,"y":%.0f},"end":{"x":%.0f,"y":%.0f}}',
				jsonEscape(edit.newText or ''),
				edit.range.start.character,
				edit.range.start.line,
				edit.range['end'].character,
				edit.range['end'].line))
		end
	end
	return '[' .. table.join(out, ',') .. ']'
end

function inferCompletionRange(bp, results)
	local xy = buffer.Loc(bp.Cursor.X, bp.Cursor.Y)
	if results[1] and results[1].textEdit and results[1].textEdit.range then
		local range = results[1].textEdit.range
		return buffer.Loc(range.start.character, range.start.line), buffer.Loc(range['end'].character, range['end'].line)
	end

	local cur = bp.Buf:GetActiveCursor()
	cur:SelectLine()
	local lineContent = util.String(cur:GetSelection()):gsub("\r?\n$", "")
	cur:ResetSelection()
	cur:GotoLoc(xy)

	local left = lineContent:sub(1, xy.X)
	local right = lineContent:sub(xy.X + 1)
	local prefix = left:match("([%w_]+)$") or ""
	local suffix = right:match("^([%w_]+)") or ""
	return buffer.Loc(xy.X - #prefix, xy.Y), buffer.Loc(xy.X + #suffix, xy.Y)
end

function serializeCompletionItems(results)
	local out = {}
	for _, entry in ipairs(results) do
		local insert = normalizeInsertText(entry)
		local label = entry.label or insert
		if insert ~= '' and label ~= '' then
			table.insert(out, fmt.Sprintf('{"insert":"%s","label":"%s","additionalTextEdits":%s,"sortText":"%s","preselect":%s,"deprecated":%s}',
				jsonEscape(insert),
				jsonEscape(label),
				serializeAdditionalTextEdits(entry),
				jsonEscape(entry.sortText or ''),
				entry.preselect and 'true' or 'false',
				entry.deprecated and 'true' or 'false'))
		end
	end
	return '[' .. table.join(out, ',') .. ']'
end

function isAutocompleteRune(r)
	return r == '.' or (r and r:match('[%w_]') ~= nil)
end

function isMemberAccessContext(bp)
	if bp == nil or bp.Buf == nil then
		return false
	end
	local cur = bp.Buf:GetActiveCursor()
	cur:SelectLine()
	local lineContent = util.String(cur:GetSelection()):gsub("\r?\n$", "")
	cur:ResetSelection()
	cur:GotoLoc(buffer.Loc(cur.X, cur.Y))
	local left = lineContent:sub(1, cur.X)
	return left:match("[%w_]+%.[%w_]*$") ~= nil
		or left:match("[%w_]+%.[%w_]+%.[%w_]*$") ~= nil
end

function shouldAutoTriggerCompletion(bp, r)
	if bp == nil or bp.Buf == nil then
		return false
	end
	if r == '.' then
		return true
	end
	if r ~= nil then
		return isAutocompleteRune(r)
	end
	if not (bp.Buf.CompletionMenu or bp.Buf:HasGhostCompletion()) then
		return false
	end
	if isMemberAccessContext(bp) then
		return true
	end
	if bp.Buf:CurrentWordLength() > 0 then
		return true
	end
	return false
end

function scheduleCompletionAction(bp)
	if bp == nil or bp.Buf == nil then
		return
	end
	local file = bp.Buf.AbsPath or ''
	completionRequestToken[file] = (completionRequestToken[file] or 0) + 1
	local token = completionRequestToken[file]
	micro.After(completionDebounceNs, function()
		if bp == nil or bp.Buf == nil then
			return
		end
		local currentFile = bp.Buf.AbsPath or ''
		if completionRequestToken[currentFile] ~= token then
			return
		end
		completionAction(bp)
	end)
end

function completionActionResponse(bp, data)
	local results = data.result
	if results == nil then 
		micro.Log("completionActionResponse: nil result", data)
		return
	end
	if results.items then
		results = results.items
	end
	micro.Log("completionActionResponse: count", #results)
	if #results == 0 then
		bp.Buf:DropProviderCompletions("lsp")
		return
	end

	local start, ending = inferCompletionRange(bp, results)
	local payload = serializeCompletionItems(results)
	bp.Buf:ShowExternalCompletionsJSON(payload, start.X, start.Y, ending.X, ending.Y)
end

function formatAction(bp, callback)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then return; end
	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local cfg = bp.Buf.Settings

	currentAction[filetype] = { method = "textDocument/formatting", response = formatActionResponse(callback) }
	send(currentAction[filetype].method, fmt.Sprintf('{"textDocument": {"uri": "file://%s"}, "options": {"tabSize": %.0f, "insertSpaces": %t, "trimTrailingWhitespace": %t, "insertFinalNewline": %t}}', file, cfg["tabsize"], cfg["tabstospaces"], cfg["rmtrailingws"], cfg["eofnewline"]))
end

function formatActionResponse(callback)
	return function (bp, data)
		if data.result == nil then return; end
		local edits = data.result
		-- make sure we apply the changes from back to front
		-- this allows for changes to not need position updates
		table.sort(edits, function (left, right)
			-- go by lines first
			return left.range['end'].line > right.range['end'].line or 
				-- if lines match, go by end character
				left.range['end'].line == right.range['end'].line and left.range['end'].character > right.range['end'].character or
				-- if they match too, go by start character
				left.range['end'].line == right.range['end'].line and left.range['end'].character == right.range['end'].character and left.range.start.line == left.range['end'].line and left.range.start.character > right.range.start.character
		end)

		-- save original cursor position
		local xy = buffer.Loc(bp.Cursor.X, bp.Cursor.Y)
		for _idx, edit in ipairs(edits) do
			rangeStart = buffer.Loc(edit.range.start.character, edit.range.start.line)
			rangeEnd = buffer.Loc(edit.range['end'].character, edit.range['end'].line)
			-- apply each change
			bp.Cursor:GotoLoc(rangeStart)
			bp.Cursor:SetSelectionStart(rangeStart)
			bp.Cursor:SetSelectionEnd(rangeEnd)
			bp.Cursor:DeleteSelection()
			bp.Cursor:ResetSelection()
			
			if edit.newText ~= "" then
				bp.Buf:insert(rangeStart, edit.newText)
			end
		end
		-- put the cursor back where it was
		bp.Cursor:GotoLoc(xy)
		-- if any changes were applied
		if #edits > 0 then
			-- tell the server about the changed document
			onRune(bp)
		end

		if callback ~= nil then
			callback(bp)
		end
	end
end

-- the references action request and response
function referencesAction(bp)
	local filetype = bp.Buf:FileType()	
	if cmd[filetype] == nil then return; end
	
	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local line = bp.Buf:GetActiveCursor().Y
	local char = bp.Buf:GetActiveCursor().X
	currentAction[filetype] = { method = "textDocument/references", response = referencesActionResponse }
	send(currentAction[filetype].method, fmt.Sprintf('{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}, "context": {"includeDeclaration":true}}', file, line, char))
end

function referencesActionResponse(bp, data)
	if data.result == nil then return; end
	local results = data.result or data.partialResult
	if results == nil or #results <= 0 then return; end

	local file = bp.Buf.AbsPath
	
	local msg = ''
	for _idx, ref in ipairs(results) do
		if msg ~= '' then msg = msg .. '\n'; end
		local doc = (ref.uri or ref.targetUri)
		msg = msg .. "." .. doc:sub(#rootUri + 1, #doc) .. ":" .. ref.range.start.line .. ":" .. ref.range.start.character
	end

	refOriginPane = bp
	local logBuf = buffer.NewBuffer(msg, "References found")
	splitBP = bp:HSplitBuf(logBuf)
end

-- the rename action request and response
function renameAction(bp, args)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then return; end
	if args == nil or #args == 0 then
		micro.InfoBar():Message("Usage: rename <new-name>")
		return
	end

	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local line = bp.Buf:GetActiveCursor().Y
	local char = bp.Buf:GetActiveCursor().X

	currentAction[filetype] = { method = "textDocument/rename", response = renameActionResponse }
	send(currentAction[filetype].method, fmt.Sprintf(
		'{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}, "newName": "%s"}',
		file, line, char, args[1]
	))
end

function applyTextEdits(bp, edits)
	-- sort edits from back to front to preserve positions
	table.sort(edits, function(left, right)
		return left.range['end'].line > right.range['end'].line or
			left.range['end'].line == right.range['end'].line and left.range['end'].character > right.range['end'].character or
			left.range['end'].line == right.range['end'].line and left.range['end'].character == right.range['end'].character and left.range.start.line == left.range['end'].line and left.range.start.character > right.range.start.character
	end)

	for _, edit in ipairs(edits) do
		local rangeStart = buffer.Loc(edit.range.start.character, edit.range.start.line)
		local rangeEnd = buffer.Loc(edit.range['end'].character, edit.range['end'].line)
		bp.Buf:remove(rangeStart, rangeEnd)
		if edit.newText ~= "" then
			bp.Buf:insert(rangeStart, edit.newText)
		end
	end
	onRune(bp)
end

function renameActionResponse(bp, data)
	if data.result == nil then
		micro.InfoBar():Message("Rename: no result from server")
		return
	end

	local changes = {}

	if data.result.documentChanges then
		for _, docChange in ipairs(data.result.documentChanges) do
			changes[docChange.textDocument.uri] = docChange.edits
		end
	elseif data.result.changes then
		changes = data.result.changes
	else
		micro.InfoBar():Message("Rename: no changes returned")
		return
	end

	local currentUri = getUriFromBuf(bp.Buf)
	local totalEdits = 0

	for uri, edits in pairs(changes) do
		totalEdits = totalEdits + #edits
		if uri == currentUri then
			applyTextEdits(bp, edits)
		else
			local doc = uri:gsub("^file://", "")
			local newBuf, err = buffer.NewBufferFromFile(doc)
			if err == nil then
				bp:AddTab()
				local newPane = micro.CurPane()
				newPane:OpenBuffer(newBuf)
				applyTextEdits(newPane, edits)
				newPane:Save()
			end
		end
	end

	micro.InfoBar():Message(fmt.Sprintf("Renamed: %.0f change(s) applied", totalEdits))
end

-- diagnostic navigation
local function diagnosticSortKey(msg)
	return buffer.Loc(msg.Start.X, msg.Start.Y)
end

local function locLessThan(a, b)
	if a.Y ~= b.Y then
		return a.Y < b.Y
	end
	return a.X < b.X
end

local function locGreaterThan(a, b)
	if a.Y ~= b.Y then
		return a.Y > b.Y
	end
	return a.X > b.X
end

local function jumpDiagnostic(bp, forward)
	local msgs = diagnosticsByURI[getUriFromBuf(bp.Buf)]
	if msgs == nil or #msgs == 0 then
		micro.InfoBar():Message("No diagnostics")
		return
	end

	local curLoc = bp.Buf:GetActiveCursor().Loc
	local target = nil
	local wrapTarget = nil

	for _, msg in ipairs(msgs) do
		local msgLoc = diagnosticSortKey(msg)
		if forward then
			if locGreaterThan(msgLoc, curLoc) and (target == nil or locLessThan(msgLoc, diagnosticSortKey(target))) then
				target = msg
			end
			if wrapTarget == nil or locLessThan(msgLoc, diagnosticSortKey(wrapTarget)) then
				wrapTarget = msg
			end
		else
			if locLessThan(msgLoc, curLoc) and (target == nil or locGreaterThan(msgLoc, diagnosticSortKey(target))) then
				target = msg
			end
			if wrapTarget == nil or locGreaterThan(msgLoc, diagnosticSortKey(wrapTarget)) then
				wrapTarget = msg
			end
		end
	end

	target = target or wrapTarget
	if target ~= nil then
		bp.Buf:GetActiveCursor():GotoLoc(buffer.Loc(target.Start.X, target.Start.Y))
		bp:Center()
	else
		micro.InfoBar():Message("No diagnostics")
	end

end

function nextDiagnostic(bp)
	jumpDiagnostic(bp, true)
end

function prevDiagnostic(bp)
	jumpDiagnostic(bp, false)
end

--
-- @TODO implement additional functions here...
--



--
-- JSON
--
-- Internal functions.

local function kind_of(obj)
  if type(obj) ~= 'table' then return type(obj) end
  local i = 1
  for _ in pairs(obj) do
    if obj[i] ~= nil then i = i + 1 else return 'table' end
  end
  if i == 1 then return 'table' else return 'array' end
end

local function escape_str(s)
  local in_char  = {'\\', '"', '/', '\b', '\f', '\n', '\r', '\t'}
  local out_char = {'\\', '"', '/',  'b',  'f',  'n',  'r',  't'}
  for i, c in ipairs(in_char) do
    s = s:gsub(c, '\\' .. out_char[i])
  end
  return s
end

-- Returns pos, did_find; there are two cases:
-- 1. Delimiter found: pos = pos after leading space + delim; did_find = true.
-- 2. Delimiter not found: pos = pos after leading space;     did_find = false.
-- This throws an error if err_if_missing is true and the delim is not found.
local function skip_delim(str, pos, delim, err_if_missing)
  pos = pos + #str:match('^%s*', pos)
  if str:sub(pos, pos) ~= delim then
    if err_if_missing then
      error('Expected ' .. delim .. ' near position ' .. pos)
    end
    return pos, false
  end
  return pos + 1, true
end

-- Expects the given pos to be the first character after the opening quote.
-- Returns val, pos; the returned pos is after the closing quote character.
local function parse_str_val(str, pos, val)
  val = val or ''
  local early_end_error = 'End of input found while parsing string.'
  if pos > #str then error(early_end_error) end
  local c = str:sub(pos, pos)
  if c == '"'  then return val, pos + 1 end
  if c ~= '\\' then return parse_str_val(str, pos + 1, val .. c) end
  -- We must have a \ character.
  local esc_map = {b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}
  local nextc = str:sub(pos + 1, pos + 1)
  if not nextc then error(early_end_error) end
  return parse_str_val(str, pos + 2, val .. (esc_map[nextc] or nextc))
end

-- Returns val, pos; the returned pos is after the number's final character.
local function parse_num_val(str, pos)
  local num_str = str:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
  local val = tonumber(num_str)
  if not val then error('Error parsing number at position ' .. pos .. '.') end
  return val, pos + #num_str
end

json.null = {}  -- This is a one-off table to represent the null value.

function json.parse(str, pos, end_delim)
  pos = pos or 1
  if pos > #str then error('Reached unexpected end of input.' .. str) end
  local pos = pos + #str:match('^%s*', pos)  -- Skip whitespace.
  local first = str:sub(pos, pos)
  if first == '{' then  -- Parse an object.
    local obj, key, delim_found = {}, true, true
    pos = pos + 1
    while true do
      key, pos = json.parse(str, pos, '}')
      if key == nil then return obj, pos end
      if not delim_found then error('Comma missing between object items.') end
      pos = skip_delim(str, pos, ':', true)  -- true -> error if missing.
      obj[key], pos = json.parse(str, pos)
      pos, delim_found = skip_delim(str, pos, ',')
    end
  elseif first == '[' then  -- Parse an array.
    local arr, val, delim_found = {}, true, true
    pos = pos + 1
    while true do
      val, pos = json.parse(str, pos, ']')
      if val == nil then return arr, pos end
      if not delim_found then error('Comma missing between array items.') end
      arr[#arr + 1] = val
      pos, delim_found = skip_delim(str, pos, ',')
    end
  elseif first == '"' then  -- Parse a string.
    return parse_str_val(str, pos + 1)
  elseif first == '-' or first:match('%d') then  -- Parse a number.
    return parse_num_val(str, pos)
  elseif first == end_delim then  -- End of an object or array.
    return nil, pos + 1
  else  -- Parse true, false, or null.
    local literals = {['true'] = true, ['false'] = false, ['null'] = json.null}
    for lit_str, lit_val in pairs(literals) do
      local lit_end = pos + #lit_str - 1
      if str:sub(pos, lit_end) == lit_str then return lit_val, lit_end + 1 end
    end
    local pos_info_str = 'position ' .. pos .. ': ' .. str:sub(pos, pos + 10)
    error('Invalid json syntax starting at ' .. pos_info_str .. ': ' .. str)
  end
end
