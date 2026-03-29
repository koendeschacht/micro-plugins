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
local pendingActions = {}
local capabilities = {}
local filetype = ''
local rootUri = ''
local message = ''
local completionCursor = 0
local lastCompletion = {}
local splitBP = nil
local refOriginPane = nil
local completionRequestToken = {}
local semanticRequestToken = {}
local diagnosticsByPath = {}
local semanticByPath = {}
local tempFileCounter = 0

local completionDebounceNs = 75 * 1000000
local semanticDebounceNs = 120 * 1000000

local semanticTokenTypes = {
	"namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
	"parameter", "variable", "property", "enumMember", "event", "function", "method",
	"macro", "keyword", "modifier", "comment", "string", "number", "regexp",
	"operator", "decorator", "label", "escapeSequence",
}

local semanticTokenModifiers = {
	"declaration", "definition", "readonly", "static", "deprecated", "abstract",
	"async", "modification", "documentation", "defaultLibrary",
}

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

local function decodeURIPath(pathstr)
	if pathstr == nil then
		return nil
	end
	return (pathstr:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

local function diagnosticPathFromURI(uri)
	if uri == nil then
		return nil
	end
	local file = uri:gsub("^file://", "")
	return decodeURIPath(file)
end

local function diagnosticPathFromBuf(buf)
	if buf == nil then
		return nil
	end
	return buf.AbsPath
end

local function syncBufferDiagnostics(buf)
	if buf == nil then
		return
	end

	buf:ClearMessages("lsp")

	local msgs = diagnosticsByPath[diagnosticPathFromBuf(buf)]
	if msgs == nil then
		return
	end

	for _, msg in ipairs(msgs) do
		buf:AddMessage(msg)
	end
end

local function supportsSemanticTokens(filetype)
	local provider = capabilities[filetype] and capabilities[filetype].semanticTokensProvider
	return provider ~= nil and provider.full ~= nil and provider.legend ~= nil and provider.legend.tokenTypes ~= nil
end

local function supportsDidSave(filetype)
	local sync = capabilities[filetype] and capabilities[filetype].textDocumentSync
	return type(sync) == "table" and sync.save ~= nil and sync.save ~= false
end

local function syncBufferSemanticHighlights(buf)
	if buf == nil then
		return
	end
	if not supportsSemanticTokens(buf:FileType()) then
		buf:ClearSemanticHighlights()
		return
	end

	local uri = getUriFromBuf(buf)
	local path = diagnosticPathFromBuf(buf)
	local entry = semanticByPath[path]
	if entry ~= nil and uri ~= nil and entry.version == version[uri] then
		buf:SetSemanticHighlightsJSON(entry.payload, entry.version)
		return
	end

	buf:ClearSemanticHighlights()
end

local function fileExists(name)
	if name == nil or name == '' then
		return false
	end
	local info, err = go_os.Stat(name)
	return err == nil and info ~= nil and not info:IsDir()
end

local function parentDir(name)
	if name == nil or name == '' then
		return ''
	end
	local dir = filepath.Dir(name)
	if dir == "." then
		return ''
	end
	return dir
end

local function findPythonFormatter(file)
	local dir = parentDir(file)
	while dir ~= nil and dir ~= '' do
		local venvRuff = filepath.Join(dir, ".venv", "bin", "ruff")
		if fileExists(venvRuff) then
			return venvRuff
		end
		local parent = parentDir(dir)
		if parent == dir then
			break
		end
		dir = parent
	end

	local home, _ = go_os.Getenv("HOME")
	local localRuff = filepath.Join(home or "", ".local", "bin", "ruff")
	if fileExists(localRuff) then
		return localRuff
	end

	return nil
end

local function replaceWholeBuffer(bp, text)
	local original = buffer.Loc(bp.Cursor.X, bp.Cursor.Y)
	local start = bp.Buf:Start()
	local finish = bp.Buf:End()

	bp.Cursor:GotoLoc(start)
	bp.Cursor:SetSelectionStart(start)
	bp.Cursor:SetSelectionEnd(finish)
	bp.Cursor:DeleteSelection()
	bp.Cursor:ResetSelection()

	if text ~= nil and text ~= '' then
		bp.Buf:insert(start, text)
	end

	bp.Cursor:GotoLoc(original)
	onRune(bp)
end

local function externalPythonFormat(bp, callback)
	local file = bp.Buf.AbsPath
	if file == nil or file == '' then
		micro.InfoBar():Message("Formatting requires a file on disk")
		return true
	end

	local formatter = findPythonFormatter(file)
	if formatter == nil then
		micro.InfoBar():Message("No Python formatter found (looked for Ruff in .venv/bin/ruff)")
		return true
	end

	local dir = parentDir(file)
	tempFileCounter = tempFileCounter + 1
	local tmpName = dir .. "/.micro-format-" .. tostring(go_os.Getpid()) .. "-" .. tostring(tempFileCounter) .. ".py"

	local content = bp.Buf:Bytes()
	local err = go_os.WriteFile(tmpName, content, 384)
	if err ~= nil then
		go_os.Remove(tmpName)
		micro.InfoBar():Message("Could not write temporary file: " .. err:Error())
		return true
	end

	local _, cmdErr = shell.ExecCommand(formatter, "format", tmpName)
	if cmdErr ~= nil then
		go_os.Remove(tmpName)
		micro.InfoBar():Message("Ruff format failed: " .. cmdErr:Error())
		return true
	end

	local formatted, readErr = go_os.ReadFile(tmpName)
	go_os.Remove(tmpName)
	if readErr ~= nil then
		micro.InfoBar():Message("Could not read formatted output: " .. readErr:Error())
		return true
	end

	local formattedText = util.String(formatted)
	local currentText = util.String(content)
	if formattedText ~= currentText then
		replaceWholeBuffer(bp, formattedText)
	end

	if callback ~= nil then
		callback(bp)
	end
	return true
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

local function splitLines(text)
	local lines = {}
	text = text or ''
	if text == '' then
		return { '' }
	end
	text = text:gsub('\r\n', '\n')
	for line in (text .. '\n'):gmatch('(.-)\n') do
		table.insert(lines, line)
	end
	return lines
end

local function isIdentifierStart(ch)
	return ch ~= nil and ch:match("[A-Za-z_]") ~= nil
end

local function isIdentifierChar(ch)
	return ch ~= nil and ch:match("[A-Za-z0-9_]") ~= nil
end

local function extractPythonParameterInfo(lines)
	local declarationsByLine = {}
	local usageNamesByLine = {}
	local functionScopes = {}
	local inSignature = false
	local parenDepth = 0
	local bracketDepth = 0
	local braceDepth = 0
	local currentParam = nil
	local currentFunction = nil

	local function topLevel()
		return parenDepth == 1 and bracketDepth == 0 and braceDepth == 0
	end

	local function commitCurrentParam()
		if currentParam == nil or currentParam.name == nil or currentParam.name == "" or currentParam.name == "/" then
			currentParam = nil
			return
		end
		declarationsByLine[currentParam.line] = declarationsByLine[currentParam.line] or {}
		declarationsByLine[currentParam.line][currentParam.col] = true
		if currentFunction ~= nil then
			currentFunction.params[currentParam.name] = true
		end
		currentParam = nil
	end

	for lineIndex = 1, #lines do
		local line = lines[lineIndex] or ""
		local scanStart = 1
		if not inSignature then
			if line:match("^%s*def%s+[A-Za-z_][A-Za-z0-9_]*%s*%(") or line:match("^%s*async%s+def%s+[A-Za-z_][A-Za-z0-9_]*%s*%(") then
				local openPos = line:find("%(")
				if openPos ~= nil then
					inSignature = true
					parenDepth = 1
					bracketDepth = 0
					braceDepth = 0
					currentParam = nil
					currentFunction = {
						indent = #(line:match("^[ \t]*") or ""),
						bodyStartLine = lineIndex + 1,
						params = {},
					}
					scanStart = openPos + 1
				end
			end
		end

		if inSignature then
			local col = scanStart
			while col <= #line do
				local ch = line:sub(col, col)
				if ch == "(" then
					parenDepth = parenDepth + 1
				elseif ch == ")" then
					if topLevel() then
						commitCurrentParam()
					end
					parenDepth = parenDepth - 1
					if parenDepth == 0 then
						inSignature = false
						currentParam = nil
						if currentFunction ~= nil then
							currentFunction.bodyStartLine = lineIndex + 1
							table.insert(functionScopes, currentFunction)
							currentFunction = nil
						end
						break
					end
				elseif ch == "[" then
					bracketDepth = bracketDepth + 1
				elseif ch == "]" then
					bracketDepth = bracketDepth - 1
				elseif ch == "{" then
					braceDepth = braceDepth + 1
				elseif ch == "}" then
					braceDepth = braceDepth - 1
				elseif ch == "," and topLevel() then
					commitCurrentParam()
				elseif topLevel() and currentParam == nil then
					if ch ~= " " and ch ~= "\t" then
						if ch == "*" then
						elseif ch == "/" then
							currentParam = { name = "/" }
						else
							local startCol = col
							if isIdentifierStart(ch) then
								local endCol = col
								while endCol <= #line and isIdentifierChar(line:sub(endCol, endCol)) do
									endCol = endCol + 1
								end
								currentParam = {
									line = lineIndex - 1,
									col = startCol - 1,
									name = line:sub(startCol, endCol - 1),
								}
								col = endCol - 1
							end
						end
					end
				end
				col = col + 1
			end
		end
	end

	local activeScopes = {}
	local nextScope = 1
	for lineIndex = 1, #lines do
		while nextScope <= #functionScopes and functionScopes[nextScope].bodyStartLine == lineIndex do
			table.insert(activeScopes, functionScopes[nextScope])
			nextScope = nextScope + 1
		end

		local line = lines[lineIndex] or ""
		local trimmed = line:match("^%s*(.-)%s*$") or ""
		local isCodeLine = trimmed ~= "" and trimmed:sub(1, 1) ~= "#"
		if isCodeLine then
			local indent = #(line:match("^[ \t]*") or "")
			while #activeScopes > 0 and indent <= activeScopes[#activeScopes].indent do
				table.remove(activeScopes)
			end
		end

		if #activeScopes > 0 then
			local activeNames = {}
			for _, scope in ipairs(activeScopes) do
				for name in pairs(scope.params) do
					activeNames[name] = true
				end
			end
			usageNamesByLine[lineIndex - 1] = activeNames
		end
	end

	return {
		declarations = declarationsByLine,
		usageNames = usageNamesByLine,
	}
end

function parseOptions(inputstr)
	return mysplit(inputstr, ',')
end

function jsonStringArray(entries)
	local out = {}
	for _, entry in ipairs(entries) do
		table.insert(out, fmt.Sprintf('"%s"', entry))
	end
	return '[' .. table.join(out, ',') .. ']'
end

function semanticTokensClientCapabilities()
	return fmt.Sprintf('{"requests":{"full":true},"tokenTypes":%s,"tokenModifiers":%s,"formats":["relative"],"overlappingTokenSupport":false,"multilineTokenSupport":false}', jsonStringArray(semanticTokenTypes), jsonStringArray(semanticTokenModifiers))
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
			pendingActions[part[1]] = {}
			micro.Log("Starting server", part[1])
			cmd[part[1]] = shell.JobSpawn(runCmd, args, onStdout(part[1]), onStderr, onExit(part[1]), {})
			send("initialize", fmt.Sprintf('{"processId": %.0f, "rootUri": "%s", "workspaceFolders": [{"name": "root", "uri": "%s"}], "initializationOptions": %s, "capabilities": {"workspace": {"configuration": true}, "textDocument": {"completion": {"completionItem": {"documentationFormat": ["plaintext", "markdown"], "preselectSupport": true, "deprecatedSupport": true}}, "hover": {"contentFormat": ["plaintext", "markdown"]}, "publishDiagnostics": {"relatedInformation": false, "versionSupport": false, "codeDescriptionSupport": true, "dataSupport": true}, "signatureHelp": {"signatureInformation": {"documentationFormat": ["plaintext", "markdown"]}}, "semanticTokens": %s}}}', go_os.Getpid(), rootUri, rootUri, initOptions, semanticTokensClientCapabilities()), false, { method = "initialize", response = function (bp, data)
			    send("initialized", "{}", true)
				capabilities[filetype] = data.result and data.result.capabilities or {}
			    callback(bp.Buf, filetype)
			end })
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
	return function (method, params, isNotification, action) 
	    if cmd[filetype] == nil then
	    	return
	    end

		local requestID = nil
		if not isNotification then
			requestID = id[filetype]
			micro.Log(filetype .. ">>> " .. method, " id=" .. requestID)
		else
			micro.Log(filetype .. ">>> " .. method)
		end
		local msg = fmt.Sprintf('{"jsonrpc": "2.0", %s"method": "%s", "params": %s}', requestID ~= nil and fmt.Sprintf('"id": %.0f, ', requestID) or "", method, params)
		if requestID ~= nil then
			id[filetype] = id[filetype] + 1
			if action ~= nil then
				pendingActions[filetype] = pendingActions[filetype] or {}
				pendingActions[filetype][tostring(requestID)] = action
			end
		end
		msg = fmt.Sprintf("Content-Length: %.0f\r\n\r\n%s", #msg, msg)
		--micro.Log("send", filetype, "sending", method or msg, msg)
		shell.JobSend(cmd[filetype], msg)
		return requestID
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
	if supportsSemanticTokens(filetype) then
		scheduleSemanticTokens(bp)
	end
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

	if supportsDidSave(filetype) then
		send("textDocument/didSave", fmt.Sprintf('{"textDocument": {"uri": "%s"}}', uri), true)
	end
	if supportsSemanticTokens(filetype) then
		requestSemanticTokensForBuf(bp.Buf)
	end
end

function handleInitialized(buf, filetype)
	if cmd[filetype] == nil then return; end
	micro.Log("Found running lsp server for ", filetype, "firing textDocument/didOpen...")
	local send = withSend(filetype)
	local uri = getUriFromBuf(buf)
	version[uri] = version[uri] or 1
	local content = util.String(buf:Bytes()):gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub('"', '\\"'):gsub("\t", "\\t")
	send("textDocument/didOpen", fmt.Sprintf('{"textDocument": {"uri": "%s", "languageId": "%s", "version": %.0f, "text": "%s"}}', uri, filetype, version[uri], content), true)
	syncBufferSemanticHighlights(buf)
	if supportsSemanticTokens(filetype) then
		requestSemanticTokensForBuf(buf)
	end
end

function onBufferOpen(buf)
	local filetype = buf:FileType()
	micro.Log("ONBUFFEROPEN", filetype)
	if filetype ~= "unknown" and not cmd[filetype] then return startServer(filetype, handleInitialized); end
	if cmd[filetype] then
	    handleInitialized(buf, filetype)
	end
	syncBufferDiagnostics(buf)
	syncBufferSemanticHighlights(buf)
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
	elseif section == "zuban" or section == "zubanls" then
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
			local diagnosticPath = diagnosticPathFromURI(uri)
			local uriDiagnostics = {}
			diagnosticsByPath[diagnosticPath] = uriDiagnostics
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
				end
			end

			local curPane = micro.CurPane()
			if curPane ~= nil and curPane.Buf ~= nil and diagnosticPath == diagnosticPathFromBuf(curPane.Buf) then
				syncBufferDiagnostics(curPane.Buf)
			end
		elseif not data.method and data.jsonrpc and data.id ~= nil then			-- react to custom action event
			local bp = micro.CurPane()
			local action = pendingActions[filetype] and pendingActions[filetype][tostring(data.id)]
			if action and action.response then
				micro.Log("Received message for ", filetype, data)
				micro.Log(filetype .. " <<< response", " id=", data.id or "nil", " expected=", action.method)
				pendingActions[filetype][tostring(data.id)] = nil
				if data.error then
					micro.Log(filetype .. " <<< error", data.error)
				end
				action.response(bp, data)
			end
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
		pendingActions[filetype] = nil
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
		send("textDocument/hover", fmt.Sprintf('{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}}', file, line, char), false, { method = "textDocument/hover", response = hoverActionResponse })
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
	send("textDocument/definition", fmt.Sprintf('{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}}', file, line, char), false, { method = "textDocument/definition", response = definitionActionResponse })
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
	send("textDocument/completion", fmt.Sprintf('{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}}', file, line, char), false, { method = "textDocument/completion", response = completionActionResponse })
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

function jsonQuote(str)
	return '"' .. jsonEscape(str) .. '"'
end

function semanticTokenGroup(tokenTypeIndex, modifierMask, legend)
	local tokenType = legend.tokenTypes[tokenTypeIndex + 1] or "variable"
	local parts = { tokenType }
	for i, modifier in ipairs(legend.tokenModifiers or {}) do
		local bit = 2 ^ (i - 1)
		if math.floor(modifierMask / bit) % 2 == 1 then
			table.insert(parts, modifier)
		end
	end
	return table.join(parts, '.')
end

local function semanticTokenText(lines, line, start, length)
	local content = lines[line + 1]
	if content == nil then
		return ""
	end
	return content:sub(start + 1, start + length)
end

local function isPythonParameterPosition(parameterInfo, line, start)
	return parameterInfo ~= nil and parameterInfo.declarations ~= nil and parameterInfo.declarations[line] ~= nil and parameterInfo.declarations[line][start] == true
end

local function isPythonParameterUsage(parameterInfo, line, tokenText)
	return parameterInfo ~= nil and parameterInfo.usageNames ~= nil and parameterInfo.usageNames[line] ~= nil and parameterInfo.usageNames[line][tokenText] == true
end

local function normalizeSemanticTokenGroup(group, tokenText, filetype, line, start, parameterInfo)
	if filetype == "python" and isPythonParameterPosition(parameterInfo, line, start) then
		return "parameter"
	end
	if filetype == "python" and group == "variable" and isPythonParameterUsage(parameterInfo, line, tokenText) then
		return "parameter"
	end
	if tokenText:match("^[A-Z][A-Z0-9_]*$") then
		return "constant"
	end
	return group
end

function decodeSemanticTokens(data, legend, lines, filetype)
	local spans = {}
	local parameterInfo = nil
	if filetype == "python" then
		parameterInfo = extractPythonParameterInfo(lines or {})
	end
	local line = 0
	local start = 0
	for i = 1, #data, 5 do
		local deltaLine = data[i] or 0
		local deltaStart = data[i + 1] or 0
		local length = data[i + 2] or 0
		local tokenType = data[i + 3] or 0
		local tokenModifiers = data[i + 4] or 0

		line = line + deltaLine
		if deltaLine == 0 then
			start = start + deltaStart
		else
			start = deltaStart
		end

		if length > 0 then
			local group = semanticTokenGroup(tokenType, tokenModifiers, legend)
			local tokenText = semanticTokenText(lines or {}, line, start, length)
			table.insert(spans, {
				line = line,
				start = start,
				length = length,
				group = normalizeSemanticTokenGroup(group, tokenText, filetype, line, start, parameterInfo),
			})
		end
	end
	return spans
end

function serializeSemanticSpans(spans)
	local out = {}
	for _, span in ipairs(spans) do
		local line = tonumber(span.line)
		local start = tonumber(span.start)
		local length = tonumber(span.length)
		local group = span.group and tostring(span.group) or ''
		if line ~= nil and start ~= nil and length ~= nil and length > 0 and group ~= '' then
			table.insert(out, string.format('{"line":%d,"start":%d,"length":%d,"group":%s}', math.floor(line), math.floor(start), math.floor(length), jsonQuote(group)))
		end
	end
	return '[' .. table.join(out, ',') .. ']'
end

function requestSemanticTokensForBuf(buf)
	if buf == nil then
		return
	end
	local filetype = buf:FileType()
	if cmd[filetype] == nil or not supportsSemanticTokens(filetype) then
		return
	end

	local send = withSend(filetype)
	local uri = getUriFromBuf(buf)
	local path = diagnosticPathFromBuf(buf)
	local requestedVersion = version[uri] or 1

	send("textDocument/semanticTokens/full", fmt.Sprintf('{"textDocument": {"uri": "%s"}}', uri), false, {
		method = "textDocument/semanticTokens/full",
		response = function (_, data)
			if version[uri] ~= requestedVersion then
				return
			end

			local payload = '[]'
			local result = data.result
			local provider = capabilities[filetype] and capabilities[filetype].semanticTokensProvider
			if result ~= nil and result.data ~= nil and provider ~= nil and provider.legend ~= nil then
				payload = serializeSemanticSpans(decodeSemanticTokens(result.data, provider.legend, splitLines(util.String(buf:Bytes())), filetype))
			end

			semanticByPath[path] = {
				version = requestedVersion,
				payload = payload,
			}

			local curPane = micro.CurPane()
			if curPane ~= nil and curPane.Buf ~= nil and diagnosticPathFromBuf(curPane.Buf) == path then
				curPane.Buf:SetSemanticHighlightsJSON(payload, requestedVersion)
			end
		end,
	})
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

function scheduleSemanticTokens(bp)
	if bp == nil or bp.Buf == nil then
		return
	end
	local file = bp.Buf.AbsPath or ''
	semanticRequestToken[file] = (semanticRequestToken[file] or 0) + 1
	local token = semanticRequestToken[file]
	micro.After(semanticDebounceNs, function()
		if bp == nil or bp.Buf == nil then
			return
		end
		local currentFile = bp.Buf.AbsPath or ''
		if semanticRequestToken[currentFile] ~= token then
			return
		end
		requestSemanticTokensForBuf(bp.Buf)
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
	local caps = capabilities[filetype] or {}
	if not caps.documentFormattingProvider then
		if filetype == "python" and externalPythonFormat(bp, callback) then
			return
		end
		micro.InfoBar():Message("LSP formatting is not supported for " .. filetype)
		return
	end
	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local cfg = bp.Buf.Settings

	send("textDocument/formatting", fmt.Sprintf('{"textDocument": {"uri": "file://%s"}, "options": {"tabSize": %.0f, "insertSpaces": %t, "trimTrailingWhitespace": %t, "insertFinalNewline": %t}}', file, cfg["tabsize"], cfg["tabstospaces"], cfg["rmtrailingws"], cfg["eofnewline"]), false, { method = "textDocument/formatting", response = formatActionResponse(callback) })
end

function formatActionResponse(callback)
	return function (bp, data)
		if data.error ~= nil then
			micro.InfoBar():Message("LSP formatting failed: " .. (data.error.message or "unknown error"))
			return
		end
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
	send("textDocument/references", fmt.Sprintf('{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}, "context": {"includeDeclaration":true}}', file, line, char), false, { method = "textDocument/references", response = referencesActionResponse })
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

	send("textDocument/rename", fmt.Sprintf(
		'{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}, "newName": "%s"}',
		file, line, char, args[1]
	), false, { method = "textDocument/rename", response = renameActionResponse })
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

function onSetActive(bp)
	if bp ~= nil then
		syncBufferDiagnostics(bp.Buf)
		syncBufferSemanticHighlights(bp.Buf)
		if supportsSemanticTokens(bp.Buf:FileType()) then
			local uri = getUriFromBuf(bp.Buf)
			local path = diagnosticPathFromBuf(bp.Buf)
			local entry = semanticByPath[path]
			if entry == nil or entry.version ~= version[uri] then
				requestSemanticTokensForBuf(bp.Buf)
			end
		end
	end
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
