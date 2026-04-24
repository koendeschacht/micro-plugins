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
local startupRoot, _ = go_os.Getwd()
local rootUri = ''
local completionCursor = 0
local lastCompletion = {}
local referencesLastQuery = ''
local splitBP = nil
local refOriginPane = nil
local completionRequestToken = {}
local semanticRequestToken = {}
local changeRequestToken = {}
local pendingDidChange = {}
local diagnosticsByPath = {}
local semanticByPath = {}
local stdoutBuffer = {}
local tempFileCounter = 0
local startErrorByFiletype = {}
local restartRequestByFiletype = {}
local suppressExitMessageByFiletype = {}

local documentChangeDebounceNs = 60 * 1000000
local completionDebounceNs = 75 * 1000000
local semanticDebounceNs = 600 * 1000000

local function lspLog(...)
	local ok, enabled = pcall(config.GetGlobalOption, "lsp.debug")
	if ok and enabled then
		micro.Log(...)
	end
end

local function traceEnabled()
	local ok, enabled = pcall(config.GetGlobalOption, "lsp.trace")
	return ok and enabled
end

local function tracePath()
	local ok, value = pcall(config.GetGlobalOption, "lsp.traceFile")
	if ok and value ~= nil and value ~= '' then
		return value
	end
	return "/tmp/micro-lsp.log"
end

local function resetTraceLog()
	local file = io.open(tracePath(), "w")
	if file ~= nil then
		file:close()
	end
end

local function traceLog(...)
	if not traceEnabled() then
		return
	end

	local parts = {}
	for i = 1, select('#', ...) do
		local text = tostring(select(i, ...))
		text = text:gsub("\r", "\\r"):gsub("\n", "\\n")
		if #text > 400 then
			text = text:sub(1, 400) .. "..."
		end
		parts[i] = text
	end

	local line = table.join(parts, " ")
	local file = io.open(tracePath(), "a")
	if file == nil then
		return
	end
	file:write(os.date("!%Y-%m-%dT%H:%M:%SZ"), " ", line, "\n")
	file:close()
end

local function infoMessage(source, text)
	traceLog("INFOBAR", source, text or "")
	micro.InfoBar():Message(text)
end

local function errorMessage(source, text)
	traceLog("INFOBAR_ERROR", source, text or "")
	micro.InfoBar():Error(text)
end

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

local function bufferFromTarget(target)
	if target == nil then
		return nil
	end
	if target.Buf ~= nil then
		return target.Buf
	end
	return target
end

local function fileTypeFromBuf(buf)
	if buf == nil then
		return nil
	end
	if buf.FileType ~= nil then
		return buf:FileType()
	end
	if buf.Settings ~= nil then
		return buf.Settings["filetype"]
	end
	return nil
end

local function syncBufferSemanticHighlights(buf)
	if buf == nil then
		return
	end
	if not supportsSemanticTokens(fileTypeFromBuf(buf)) then
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

local function shellQuote(text)
	return "'" .. string.gsub(text, "'", "'\\''") .. "'"
end

local function commandExists(name, cwd)
	if name == nil or name == '' then
		return false
	end

	if name:find("/", 1, true) ~= nil then
		if filepath.IsAbs(name) then
			return fileExists(name)
		end
		if cwd ~= nil and cwd ~= '' then
			return fileExists(filepath.Join(cwd, name))
		end
		return fileExists(name)
	end

	local _, err = shell.RunCommand("sh -c " .. shellQuote("command -v " .. shellQuote(name) .. " >/dev/null 2>&1"))
	return err == nil
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

local function workspaceRoot()
	if startupRoot ~= nil and startupRoot ~= '' then
		return startupRoot
	end
	local wd, _ = go_os.Getwd()
	return wd
end

local function executableExists(name)
	if name == nil or name == '' then
		return false
	end

	local _, err = shell.RunCommand("sh -c " .. shellQuote("test -x " .. shellQuote(name)))
	return err == nil
end

local function displayPath(pathstr)
	if pathstr == nil or pathstr == '' then
		return ''
	end

	local root = workspaceRoot()
	if root ~= nil and root ~= '' then
		if pathstr == root then
			return "."
		end

		local prefix = root .. "/"
		if pathstr:sub(1, #prefix) == prefix then
			return "." .. pathstr:sub(#root + 1)
		end
	end

	return pathstr
end

local function trimReferenceSnippet(text)
	if text == nil then
		return ''
	end

	text = text:gsub("\t", "    ")
	text = text:gsub("%s+", " ")
	text = text:gsub("^%s+", "")
	text = text:gsub("%s+$", "")
	if #text > 160 then
		return text:sub(1, 157) .. "..."
	end
	return text
end

local function readReferenceLines(pathstr, cache)
	if pathstr == nil or pathstr == '' then
		return {}
	end

	if cache[pathstr] == nil then
		local lines = {}
		local file = io.open(pathstr, "r")
		if file ~= nil then
			local idx = 0
			for line in file:lines() do
				lines[idx] = line
				idx = idx + 1
			end
			file:close()
		end
		cache[pathstr] = lines
	end

	return cache[pathstr]
end

local function readReferenceLine(pathstr, targetLine, cache)
	if pathstr == nil or pathstr == '' or targetLine == nil or targetLine < 0 then
		return ''
	end

	local lines = readReferenceLines(pathstr, cache)
	return lines[targetLine] or ''
end

local function readReferenceSnippet(pathstr, targetLine, cache)
	return trimReferenceSnippet(readReferenceLine(pathstr, targetLine, cache))
end

local function luaPatternEscape(text)
	if text == nil then
		return ''
	end
	return (text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

local function isWordChar(ch)
	return ch ~= nil and ch ~= '' and ch:match("[%w_]") ~= nil
end

local function referenceIdentifier(line, character)
	if line == nil or line == '' then
		return nil
	end

	local idx = math.max(1, math.min(#line, (character or 0) + 1))
	if not isWordChar(line:sub(idx, idx)) and idx > 1 and isWordChar(line:sub(idx - 1, idx - 1)) then
		idx = idx - 1
	end
	if not isWordChar(line:sub(idx, idx)) then
		return nil
	end

	local startIdx = idx
	while startIdx > 1 and isWordChar(line:sub(startIdx - 1, startIdx - 1)) do
		startIdx = startIdx - 1
	end
	local endIdx = idx
	while endIdx < #line and isWordChar(line:sub(endIdx + 1, endIdx + 1)) do
		endIdx = endIdx + 1
	end
	return line:sub(startIdx, endIdx)
end

local function isImportLine(trimmed)
	return trimmed:match("^import%s+") ~= nil or
		trimmed:match("^from%s+.+%s+import%s+") ~= nil or
		trimmed:match("^import%s*{%s*$") ~= nil or
		trimmed:match("^export%s+{%s*$") ~= nil or
		trimmed:match("^export%s+type%s+{%s*$") ~= nil or
		trimmed:match("^export%s+.*%s+from%s+['\"]") ~= nil or
		trimmed:match("^const%s+.+=%s*require%s*%(") ~= nil or
		trimmed:match("^let%s+.+=%s*require%s*%(") ~= nil or
		trimmed:match("^var%s+.+=%s*require%s*%(") ~= nil or
		trimmed:match("^local%s+.+=%s*require%s*%(") ~= nil
end

local function isImportReference(pathstr, targetLine, cache)
	local line = readReferenceLine(pathstr, targetLine, cache)
	local trimmed = line:match("^%s*(.-)%s*$") or ''
	if isImportLine(trimmed) then
		return true
	end

	for delta = 1, 8 do
		local prev = readReferenceLine(pathstr, targetLine - delta, cache)
		local prevTrimmed = prev:match("^%s*(.-)%s*$") or ''
		if prevTrimmed == '' then
			break
		end
		if prevTrimmed:match("^from%s+.+%s+import%s*%($") or
			prevTrimmed:match("^import%s*{%s*$") or
			prevTrimmed:match("^export%s+{%s*$") or
			prevTrimmed:match("^export%s+type%s+{%s*$") then
			return true
		end
	end

	for delta = 1, 3 do
		local nextLine = readReferenceLine(pathstr, targetLine + delta, cache)
		local nextTrimmed = nextLine:match("^%s*(.-)%s*$") or ''
		if nextTrimmed == '' then
			break
		end
		if nextTrimmed:match("^}%s*from%s+['\"]") ~= nil then
			return true
		end
	end

	return false
end

local function isDefinitionReference(pathstr, targetLine, character, cache)
	local line = readReferenceLine(pathstr, targetLine, cache)
	local trimmed = line:match("^%s*(.-)%s*$") or ''
	local ident = referenceIdentifier(line, character)
	if ident == nil or ident == '' then
		return false
	end

	local name = luaPatternEscape(ident)
	local patterns = {
		"^async%s+def%s+" .. name .. "[%s%(]",
		"^def%s+" .. name .. "[%s%(]",
		"^class%s+" .. name .. "[%s%(:]",
		"^local%s+function%s+" .. name .. "[%s%(]",
		"^function%s+.*" .. name .. "[%s%(]",
		"^async%s+function%s+" .. name .. "[%s%(]",
		"^function%s+" .. name .. "[%s%(]",
		"^func%s+" .. name .. "[%s%(]",
		"^func%s+%b()%s*" .. name .. "[%s%(]",
		"^type%s+" .. name .. "[%s={]",
		"^interface%s+" .. name .. "[%s{]",
		"^enum%s+" .. name .. "[%s{]",
		"^class%s+" .. name .. "[%s{]",
		"^const%s+" .. name .. "[%s=:]",
		"^let%s+" .. name .. "[%s=:]",
		"^var%s+" .. name .. "[%s=:]",
		"^local%s+" .. name .. "[%s=:]",
	}

	for _, pattern in ipairs(patterns) do
		if trimmed:match(pattern) ~= nil then
			return true
		end
	end

	return false
end

local function normalizeReferences(results)
	local cache = {}
	local normalized = {}
	for idx, ref in ipairs(results) do
		local uri = ref.uri or ref.targetUri
		local refRange = ref.range or ref.targetSelectionRange
		local doc = diagnosticPathFromURI(uri)
		if doc ~= nil and refRange ~= nil and refRange.start ~= nil then
			local line = refRange.start.line or 0
			local character = refRange.start.character or 0
			if not isDefinitionReference(doc, line, character, cache) then
				table.insert(normalized, {
					doc = doc,
					line = line,
					character = character,
					display = displayPath(doc),
					snippet = readReferenceSnippet(doc, line, cache),
					isImport = isImportReference(doc, line, cache),
					order = idx,
				})
			end
		end
	end

	table.sort(normalized, function(left, right)
		if left.isImport ~= right.isImport then
			return not left.isImport
		end
		return left.order < right.order
	end)

	return normalized
end

local function parseCommandOutput(text)
	local query, selection = text:match("^([^\n]*)\n?(.*)$")
	if query == nil then
		return "", ""
	end

	selection = (selection or ""):gsub("\n+$", "")
	return query, selection
end

local function referenceFzfBin()
	local home, _ = go_os.Getenv("HOME")
	home = home or ''
	local candidates = {
		filepath.Join(home, "config", "micro_plugins", "fzfgrep", "fzf"),
		filepath.Join(home, "config", "micro_plugins", "fzf", "fzf"),
	}

	for _, candidate in ipairs(candidates) do
		if executableExists(candidate) then
			return candidate
		end
	end

	if commandExists("fzf", workspaceRoot()) then
		return "fzf"
	end

	return nil
end

local function referencePreviewBin()
	if commandExists("batcat", workspaceRoot()) then
		return "batcat"
	end
	if commandExists("bat", workspaceRoot()) then
		return "bat"
	end
	return nil
end

local function openReferenceLocation(bp, doc, line, character)
	if bp == nil or doc == nil or doc == '' then
		return
	end

	local newBuf, err = buffer.NewBufferFromFile(doc)
	if err ~= nil then
		micro.InfoBar():Error("LSP: could not open " .. doc)
		return
	end

	bp:PushJump()
	bp:OpenBuffer(newBuf)
	newBuf:GetActiveCursor():GotoLoc(buffer.Loc(math.max(0, character or 0), math.max(0, line or 0)))
	bp:Center()
	if bp.Relocate then
		bp:Relocate()
	end
end

local function showReferencesSplit(bp, refs)
	local msg = ''
	for _idx, ref in ipairs(refs) do
		if msg ~= '' then msg = msg .. '\n'; end
		msg = msg .. ref.display .. ":" .. ref.line .. ":" .. ref.character
	end

	refOriginPane = bp
	local logBuf = buffer.NewBuffer(msg, "References found")
	splitBP = bp:HSplitBuf(logBuf)
end

local function showReferencesPicker(bp, refs)
	local fzfBin = referenceFzfBin()
	local previewBin = referencePreviewBin()
	if fzfBin == nil or previewBin == nil then
		return false
	end

	local inputPath = os.tmpname()
	local resultPath = os.tmpname()
	local inputFile = io.open(inputPath, "w")
	if inputFile == nil then
		return false
	end

	local count = 0
	for _, ref in ipairs(refs) do
		local line = ref.line + 1
		local character = ref.character + 1
		local text = string.format("%s:%d:%d", ref.display, line, character)
		if ref.snippet ~= '' then
			text = text .. " " .. ref.snippet
		end
		inputFile:write(table.concat({ ref.doc, tostring(line), tostring(character), text }, "\t") .. "\n")
		count = count + 1
	end
	inputFile:close()

	if count == 0 then
		os.remove(inputPath)
		os.remove(resultPath)
		return false
	end

	local previewLines = 40
	if bp ~= nil and bp.BWindow ~= nil and bp.BWindow.Height ~= nil then
		previewLines = math.max(10, bp.BWindow.Height - 1)
	end

	local previewCmd = "sh -c " .. shellQuote(
		"line=\"$2\"; lines=" .. previewLines .. "; half=$(( lines / 2 )); " ..
		"start=$(( line > half ? line - half : 1 )); end=$(( start + lines - 1 )); " ..
		previewBin .. " --color=always --style=numbers --line-range \"${start}:${end}\" " ..
		"--highlight-line \"$line\" \"$1\""
	) .. " sh {1} {2}"
	local fzfCmd = shellQuote(fzfBin) ..
		" --layout=reverse --border --info=inline --print-query --delimiter='\\t' --with-nth=4.." ..
		" --query=" .. shellQuote(referencesLastQuery) ..
		" --prompt='Refs> ' --border-label=' references ' " ..
		" --preview=" .. shellQuote(previewCmd) ..
		" --preview-window=right:55%,border-left"
	local shellCmd = "script -q -c " .. shellQuote(fzfCmd .. " < " .. shellQuote(inputPath) .. " > " .. shellQuote(resultPath)) .. " /dev/null"
	local _, err = shell.RunInteractiveShell(shellCmd, false, false)

	local output = ""
	local resultFile = io.open(resultPath, "r")
	if resultFile ~= nil then
		output = resultFile:read("*a") or ""
		resultFile:close()
	end
	os.remove(inputPath)
	os.remove(resultPath)

	local query, selection = parseCommandOutput(output)
	referencesLastQuery = query
	if err ~= nil or selection == '' then
		return true
	end

	local doc, line, character = selection:match("^([^\t]+)\t(%d+)\t(%d+)\t")
	if doc == nil then
		micro.InfoBar():Error("LSP: could not parse selected reference")
		return true
	end

	micro.After(0, function()
		openReferenceLocation(bp, doc, line * 1 - 1, character * 1 - 1)
	end)
	return true
end

local function shellCommand(runCmd, args)
	local parts = { shellQuote(runCmd) }
	for _, arg in ipairs(args) do
		table.insert(parts, shellQuote(arg))
	end
	return table.join(parts, " ")
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

function startServer(buf, filetype, callback)
	local projectRoot = workspaceRoot()
	rootUri = fmt.Sprintf("file://%s", projectRoot)
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
	lspLog("Server Options", server)
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
			if not commandExists(runCmd, projectRoot) then
				local msg = "LSP: server not found for " .. part[1] .. ": " .. (runCmd or "")
				traceLog("START_FAILED", part[1], msg)
				if startErrorByFiletype[part[1]] ~= msg then
					startErrorByFiletype[part[1]] = msg
					errorMessage("start", msg)
				end
				return
			end
			startErrorByFiletype[part[1]] = nil
			id[part[1]] = 0
			pendingActions[part[1]] = {}
			lspLog("Starting server", part[1])
			traceLog("START", part[1], "cmd", runCmd or "", "args", table.join(args, " "), "root", projectRoot or "", "rootUri", rootUri)
			local job = shell.JobStart("cd " .. shellQuote(projectRoot) .. " && exec " .. shellCommand(runCmd, args), onStdout(part[1]), onStderr, onExit(part[1]), {})
			if job == nil then
				local msg = "LSP: failed to start server for " .. part[1] .. ": " .. (runCmd or "")
				traceLog("START_SPAWN_FAILED", part[1], msg)
				if startErrorByFiletype[part[1]] ~= msg then
					startErrorByFiletype[part[1]] = msg
					errorMessage("start", msg)
				end
				return
			end
			cmd[part[1]] = job
			send("initialize", fmt.Sprintf('{"processId": %.0f, "rootUri": "%s", "workspaceFolders": [{"name": "root", "uri": "%s"}], "initializationOptions": %s, "capabilities": {"workspace": {"configuration": true}, "textDocument": {"completion": {"completionItem": {"documentationFormat": ["plaintext", "markdown"], "preselectSupport": true, "deprecatedSupport": true}}, "hover": {"contentFormat": ["plaintext", "markdown"]}, "publishDiagnostics": {"relatedInformation": false, "versionSupport": false, "codeDescriptionSupport": true, "dataSupport": true}, "signatureHelp": {"signatureInformation": {"documentationFormat": ["plaintext", "markdown"]}}, "semanticTokens": {"augmentsSyntaxTokens": true, "requests": {"full": true}, "tokenTypes": %s, "tokenModifiers": %s, "formats": ["relative"], "overlappingTokenSupport": false, "multilineTokenSupport": false}}}}', go_os.Getpid(), rootUri, rootUri, initOptions, jsonStringArray(semanticTokenTypes), jsonStringArray(semanticTokenModifiers)), false, { method = "initialize", response = function (_, data)
			    send("initialized", "{}", true)
				capabilities[filetype] = data.result and data.result.capabilities or {}
				traceLog("INITIALIZED", filetype, "semanticTokensProvider", capabilities[filetype].semanticTokensProvider ~= nil)
			    callback(buf, filetype)
			end })
			return
		end
	end
end

local function startServerForBuf(buf, filetype, action)
	startServer(buf, filetype, function(startedBuf, startedFiletype)
		handleInitialized(startedBuf, startedFiletype)
		if action ~= nil then
			action(startedFiletype)
		end
	end)
end

function restartAction(bp)
	if bp == nil or bp.Buf == nil then
		return
	end

	local filetype = bp.Buf:FileType()
	if filetype == nil or filetype == "" or filetype == "unknown" then
		errorMessage("restart", "LSP: no configured server for this buffer")
		return
	end

	if restartRequestByFiletype[filetype] ~= nil then
		infoMessage("restart", "LSP server restart already in progress for " .. filetype)
		return
	end

	if cmd[filetype] == nil then
		startServerForBuf(bp.Buf, filetype, function(startedFiletype)
			infoMessage("restart", "Started LSP server for " .. startedFiletype)
		end)
		return
	end

	restartRequestByFiletype[filetype] = { buf = bp.Buf }
	suppressExitMessageByFiletype[filetype] = true
	infoMessage("restart", "Restarting LSP server for " .. filetype)
	shell.JobStop(cmd[filetype])
end

function init()
	config.RegisterCommonOption("lsp", "server", "python=pylsp,go=gopls,typescript=deno lsp,javascript=deno lsp,markdown=deno lsp,json=deno lsp,jsonc=deno lsp,rust=rust-analyzer,lua=lua-language-server,c++=clangd,dart=dart language-server")
	config.RegisterCommonOption("lsp", "formatOnSave", false)
	config.RegisterCommonOption("lsp", "autocompleteDetails", false)
	config.RegisterCommonOption("lsp", "debug", false)
	config.RegisterCommonOption("lsp", "trace", false)
	config.RegisterCommonOption("lsp", "traceFile", "/tmp/micro-lsp.log")
	resetTraceLog()
	config.RegisterCommonOption("lsp", "ignoreMessages", "")
	config.RegisterCommonOption("lsp", "tabcompletion", true)
	config.RegisterCommonOption("lsp", "ignoreTriggerCharacters", "completion")
	-- example to ignore all LSP server message starting with these strings:
	-- "lsp.ignoreMessages": "Skipping analyzing |See https://"
	
	config.MakeCommand("hover", hoverAction, config.NoComplete)
	config.MakeCommand("definition", definitionAction, config.NoComplete)
	config.MakeCommand("smartreference", smartReferenceAction, config.NoComplete)
	config.MakeCommand("lspcompletion", completionAction, config.NoComplete)
	config.MakeCommand("format", formatAction, config.NoComplete)
	config.MakeCommand("references", referencesAction, config.NoComplete)
	config.MakeCommand("rename", renameAction, config.NoComplete)
	config.MakeCommand("lsprestart", restartAction, config.NoComplete)
	config.RegisterActionLabel("command:hover", "hover")
	config.RegisterActionLabel("command:definition", "definition")
	config.RegisterActionLabel("command:smartreference", "smart reference")
	config.RegisterActionLabel("command:lspcompletion", "completion")
	config.RegisterActionLabel("command:format", "format")
	config.RegisterActionLabel("command:references", "references")
	config.RegisterActionLabel("command:rename", "rename")
	config.RegisterActionLabel("command:lsprestart", "restart lsp")

	config.TryBindKey("Alt-k", "command:hover", false)
	config.TryBindKey("Alt-d", "command:definition", false)
	config.TryBindKey("Alt-f", "command:format", false)
	config.TryBindKey("Alt-r", "command:references", false)
	config.TryBindKey("Ctrl-Space", "command:lspcompletion", false)
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
			lspLog(filetype .. ">>> " .. method, " id=" .. requestID)
		else
			lspLog(filetype .. ">>> " .. method)
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

local function serializedBufferText(buf)
	return (util.String(buf:Bytes()):gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub('"', '\\"'):gsub("\t", "\\t"))
end

local function sendDidChangeForBuf(buf)
	if buf == nil then
		return
	end

	local filetype = fileTypeFromBuf(buf)
	if cmd[filetype] == nil then
		return
	end

	local uri = getUriFromBuf(buf)
	pendingDidChange[uri] = nil
	traceLog("DID_CHANGE", filetype, diagnosticPathFromBuf(buf) or "nil", version[uri] or -1)
	withSend(filetype)("textDocument/didChange", fmt.Sprintf(
		'{"textDocument": {"version": %.0f, "uri": "%s"}, "contentChanges": [{"text": "%s"}]}',
		version[uri] or 1,
		uri,
		serializedBufferText(buf)
	), true)
end

local function flushPendingDidChangeForBuf(buf)
	if buf == nil then
		return
	end

	local uri = getUriFromBuf(buf)
	if uri == nil or not pendingDidChange[uri] then
		return
	end

	changeRequestToken[uri] = (changeRequestToken[uri] or 0) + 1
	sendDidChangeForBuf(buf)
end

local function scheduleDidChange(target)
	local buf = bufferFromTarget(target)
	if buf == nil then
		return
	end

	local uri = getUriFromBuf(buf)
	if uri == nil then
		return
	end
	pendingDidChange[uri] = true
	traceLog("SCHEDULE_DID_CHANGE", fileTypeFromBuf(buf) or "nil", diagnosticPathFromBuf(buf) or "nil", changeRequestToken[uri] or 0, version[uri] or -1)
	changeRequestToken[uri] = (changeRequestToken[uri] or 0) + 1
	local token = changeRequestToken[uri]
	micro.After(documentChangeDebounceNs, function()
		if buf == nil then
			return
		end

		local currentURI = getUriFromBuf(buf)
		if currentURI ~= uri or changeRequestToken[uri] ~= token or not pendingDidChange[uri] then
			return
		end

		sendDidChangeForBuf(buf)
	end)
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

function onRune(bp, r)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then
		return
	end
	closeSplitPane()

	if r ~= nil then
		lastCompletion = {}
	end

	local caps = capabilities[filetype]
	if caps == nil then
		return
	end

	local ignored = mysplit(config.GetGlobalOption("lsp.ignoreTriggerCharacters") or '', ",")

	if r and not contains(ignored, "signature")
			and caps.signatureHelpProvider and caps.signatureHelpProvider.triggerCharacters
			and contains(caps.signatureHelpProvider.triggerCharacters, r) then
		flushPendingDidChangeForBuf(bp.Buf)
		hoverAction(bp)
	elseif not contains(ignored, "completion") and shouldAutoTriggerCompletion(bp, r) then
		scheduleCompletionAction(bp)
	end
end

local function noteDocumentMutation(buf)
	if buf == nil then
		return
	end

	local filetype = fileTypeFromBuf(buf)
	if cmd[filetype] == nil then
		return
	end

	closeSplitPane()
	lastCompletion = {}

	local uri = getUriFromBuf(buf)
	if uri == nil then
		return
	end

	version[uri] = (version[uri] or 0) + 1
	traceLog("MANUAL_TEXT_EVENT", filetype, diagnosticPathFromBuf(buf) or "nil", version[uri])
	local path = diagnosticPathFromBuf(buf)
	if path ~= nil then
		semanticByPath[path] = nil
	end
	scheduleDidChange(buf)
	if supportsSemanticTokens(filetype) then
		scheduleSemanticTokens(buf)
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
function onUndo(bp)
	noteDocumentMutation(bp.Buf)
	onRune(bp)
end
function onRedo(bp)
	noteDocumentMutation(bp.Buf)
	onRune(bp)
end
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

function onBeforeTextEvent(buf, t)
	if buf == nil then
		return true
	end

	local filetype = fileTypeFromBuf(buf)
	if cmd[filetype] == nil then
		return true
	end

	closeSplitPane()
	lastCompletion = {}

	local uri = getUriFromBuf(buf)
	if uri == nil then
		return true
	end

	version[uri] = (version[uri] or 0) + 1
	traceLog("TEXT_EVENT", filetype, diagnosticPathFromBuf(buf) or "nil", t and t.EventType or "nil", t and t.Deltas and #t.Deltas or 0, version[uri])
	local path = diagnosticPathFromBuf(buf)
	if path ~= nil then
		semanticByPath[path] = nil
	end
	scheduleDidChange(buf)
	if supportsSemanticTokens(filetype) then
		scheduleSemanticTokens(buf)
	end

	return true
end

function onEscape(bp) 
	closeSplitPane()
end

function preInsertNewline(bp)
	if bp.Buf.Path == "References found" then
		local cur = bp.Buf:GetActiveCursor()
		cur:SelectLine()
		local data = util.String(cur:GetSelection())
		local doc, line, character = data:match("([^:]+):([^:]+):([^:]+)")
		if refOriginPane ~= nil then
			openReferenceLocation(refOriginPane, doc, line * 1, character * 1)
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

	flushPendingDidChangeForBuf(bp.Buf)
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
	lspLog("Found running lsp server for ", filetype, "firing textDocument/didOpen...")
	traceLog("HANDLE_INITIALIZED", filetype, buf and buf.AbsPath or "nil", supportsSemanticTokens(filetype))
	local send = withSend(filetype)
	local uri = getUriFromBuf(buf)
	version[uri] = version[uri] or 1
	local content = serializedBufferText(buf)
	send("textDocument/didOpen", fmt.Sprintf('{"textDocument": {"uri": "%s", "languageId": "%s", "version": %.0f, "text": "%s"}}', uri, filetype, version[uri], content), true)
	syncBufferSemanticHighlights(buf)
end

function onBufferOpen(buf)
	local filetype = buf:FileType()
	lspLog("ONBUFFEROPEN", filetype)
	traceLog("BUFFER_OPEN", filetype, buf.AbsPath or "nil")
	if filetype ~= "unknown" and not cmd[filetype] then return startServer(buf, filetype, handleInitialized); end
	if cmd[filetype] then
	    handleInitialized(buf, filetype)
	end
	syncBufferDiagnostics(buf)
	syncBufferSemanticHighlights(buf)
end

function postinit()
	local bp = micro.CurPane()
	if bp ~= nil then
		onSetActive(bp)
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
	lspLog("LSP parse failure", cleanedText)
	return false
end

function isIgnoredMessage(msg)
	-- Return true if msg matches one of the ignored starts of messages
	-- Useful for linters that show spurious, hard to disable warnings
	local ignoreList = mysplit(config.GetGlobalOption("lsp.ignoreMessages"), "|")
	for i, ignore in pairs(ignoreList) do
		if string.match(msg, ignore) then -- match from start of string
			lspLog("Ignore message: '", msg, "', because it matched: '", ignore, "'.")
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

local function nextLSPPayload(text)
	if text == nil or text == '' then
		return nil, text or ''
	end

	local headerStart, headerEnd = text:find("\r\n\r\n", 1, true)
	if headerStart == nil then
		headerStart, headerEnd = text:find("\n\n", 1, true)
	end
	if headerStart == nil then
		return nil, text
	end

	local header = text:sub(1, headerStart - 1)
	local length = tonumber(header:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
	if length == nil then
		traceLog("STDOUT_BAD_HEADER", header)
		return nil, ''
	end

	local bodyStart = headerEnd + 1
	local bodyEnd = bodyStart + length - 1
	if #text < bodyEnd then
		return nil, text
	end

	return text:sub(bodyStart, bodyEnd), text:sub(bodyEnd + 1)
end

function onStdout(filetype)
	return function (text)
		stdoutBuffer[filetype] = (stdoutBuffer[filetype] or '') .. text
		while true do
			local payload, rest = nextLSPPayload(stdoutBuffer[filetype])
			stdoutBuffer[filetype] = rest
			if payload == nil then
				return
			end

			local data = payload:parse()
			if data == false then
				traceLog("PARSE_FAILED", filetype, payload)
			else
				lspLog(filetype .. " <<< " .. (data.method or 'no method'))
				
				if data.method == "workspace/configuration" then
				    -- actually needs to respond with the same ID as the received JSON
					lspLog(filetype .. " <<< workspace/configuration params", data.params)
					local message = fmt.Sprintf('{"jsonrpc": "2.0", "id": %.0f, "result": %s}', data.id, configurationResult(data.params))
					lspLog(filetype .. " >>> workspace/configuration response", message)
					shell.JobSend(cmd[filetype], fmt.Sprintf('Content-Length: %.0f\r\n\r\n%s', #message, message))
				elseif data.method == "workspace/semanticTokens/refresh" or data.method == "workspace\\/semanticTokens\\/refresh" then
					traceLog("SEMANTIC_REFRESH", filetype)
					if data.id ~= nil then
						local response = fmt.Sprintf('{"jsonrpc": "2.0", "id": %.0f, "result": null}', data.id)
						shell.JobSend(cmd[filetype], fmt.Sprintf('Content-Length: %.0f\r\n\r\n%s', #response, response))
					end
					local curPane = micro.CurPane()
					if curPane ~= nil and curPane.Buf ~= nil and curPane.Buf:FileType() == filetype and supportsSemanticTokens(filetype) then
						requestSemanticTokensForBuf(curPane.Buf)
					end
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
					traceLog("DIAGNOSTICS", filetype, diagnosticPath or "nil", #uriDiagnostics)

					local curPane = micro.CurPane()
					if curPane ~= nil and curPane.Buf ~= nil and diagnosticPath == diagnosticPathFromBuf(curPane.Buf) then
						syncBufferDiagnostics(curPane.Buf)
						if supportsSemanticTokens(filetype) then
							-- Pyrefly can report diagnostics before startup semantic tokens are ready,
							-- so request highlights once diagnostics confirm the document is indexed.
							local currentURI = getUriFromBuf(curPane.Buf)
							local entry = semanticByPath[diagnosticPath]
							if entry == nil or entry.version ~= version[currentURI] then
								scheduleSemanticTokens(curPane)
							end
						end
					end
				elseif not data.method and data.jsonrpc and data.id ~= nil then
					local bp = micro.CurPane()
					local action = pendingActions[filetype] and pendingActions[filetype][tostring(data.id)]
					if action and action.response then
						lspLog("Received message for ", filetype, data)
						lspLog(filetype .. " <<< response", " id=", data.id or "nil", " expected=", action.method)
						pendingActions[filetype][tostring(data.id)] = nil
						if data.error then
							lspLog(filetype .. " <<< error", data.error)
						end
						action.response(bp, data)
					end
				elseif data.method == "window/showMessage" or data.method == "window\\/showMessage" then
					traceLog("WINDOW_SHOW", filetype, data.params and data.params.message or "")
					local curPane = micro.CurPane()
					if curPane ~= nil and curPane.Buf ~= nil and filetype == curPane.Buf:FileType() then
						infoMessage("window/showMessage", data.params.message)
					else
						lspLog(filetype .. " message " .. data.params.message)
					end
				elseif data.method == "window/logMessage" or data.method == "window\\/logMessage" then
					traceLog("WINDOW_LOG", filetype, data.params and data.params.message or "")
					lspLog(data.params.message)
				else
					traceLog("UNHANDLED_PAYLOAD", filetype, payload)
				end
			end
		end
	end
end

function onStderr(text)
	lspLog("ONSTDERR", text)
	traceLog("STDERR", text or "")
	if text == nil or text == '' then
		return
	end

	for line in string.gmatch(text, "([^\r\n]+)") do
		local trimmed = line:match("^%s*(.-)%s*$") or ""
		local lowered = string.lower(trimmed)
		local isErrorLike = lowered:match("^error[:%s]") ~= nil
			or lowered:match("^fatal[:%s]") ~= nil
			or lowered:match("^panic[:%s]") ~= nil
			or lowered:match("^traceback") ~= nil
			or lowered:match("^exception[:%s]") ~= nil

		if isErrorLike and not isIgnoredMessage(trimmed) then
			errorMessage("stderr", trimmed)
			return
		end
	end
end

function onExit(filetype)
	return function (str)
		local restartRequest = restartRequestByFiletype[filetype]
		local suppressExitMessage = suppressExitMessageByFiletype[filetype]
		pendingActions[filetype] = nil
		cmd[filetype] = nil
		id[filetype] = nil
		capabilities[filetype] = nil
		stdoutBuffer[filetype] = nil
		traceLog("ONEXIT", filetype, str or "")
		lspLog("ONEXIT", filetype, str)
		if restartRequest ~= nil then
			restartRequestByFiletype[filetype] = nil
			suppressExitMessageByFiletype[filetype] = nil
			startServerForBuf(restartRequest.buf, filetype, function(startedFiletype)
				if supportsSemanticTokens(startedFiletype) then
					scheduleSemanticTokens(restartRequest.buf)
				end
				infoMessage("restart", "Restarted LSP server for " .. startedFiletype)
			end)
			return
		end
		suppressExitMessageByFiletype[filetype] = nil
		if suppressExitMessage then
			return
		end
		errorMessage("onExit", "LSP server for " .. filetype .. " exited unexpectedly")
	end
end

-- the actual hover action request and response
-- the hoverActionResponse is hooked up in 
function hoverAction(bp)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] ~= nil then
		flushPendingDidChangeForBuf(bp.Buf)
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
local function sendDefinitionRequest(filetype, file, line, char, response)
	withSend(filetype)("textDocument/definition", fmt.Sprintf('{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}}', file, line, char), false, {
		method = "textDocument/definition",
		response = response,
	})
end

function definitionAction(bp)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then return; end

	micro.PushJump()
	flushPendingDidChangeForBuf(bp.Buf)

	local file = bp.Buf.AbsPath
	local line = bp.Buf:GetActiveCursor().Y
	local char = bp.Buf:GetActiveCursor().X
	sendDefinitionRequest(filetype, file, line, char, definitionActionResponse)
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
		-- Reuse the current pane when jumping across files.
		buf, _ = buffer.NewBufferFromFile(doc)
		bp:OpenBuffer(buf)
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

local function definitionResultList(data)
	local results = data.result or data.partialResult
	if results == nil then
		return nil
	end
	if results.uri ~= nil then
		return { results }
	end
	return results
end

local function definitionMatchesPosition(data, file, line, character)
	local results = definitionResultList(data)
	if results == nil or #results <= 0 then
		return false
	end

	local target = results[1]
	local uri = target.uri or target.targetUri
	local range = target.range or target.targetSelectionRange
	local doc = diagnosticPathFromURI(uri)
	if doc == nil or range == nil or range.start == nil or range['end'] == nil then
		return false
	end
	if doc ~= file then
		return false
	end
	if line < range.start.line or line > range['end'].line then
		return false
	end
	if line == range.start.line and character < range.start.character then
		return false
	end
	if line == range['end'].line and character >= range['end'].character then
		return false
	end
	return true
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
	return ((str or ''):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t'))
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
				rawGroup = group,
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
	local filetype = fileTypeFromBuf(buf)
	if cmd[filetype] == nil or not supportsSemanticTokens(filetype) then
		return
	end

	local send = withSend(filetype)
	local uri = getUriFromBuf(buf)
	local path = diagnosticPathFromBuf(buf)
	flushPendingDidChangeForBuf(buf)
	local requestedVersion = version[uri] or 1

	send("textDocument/semanticTokens/full", fmt.Sprintf('{"textDocument": {"uri": "%s"}}', uri), false, {
		method = "textDocument/semanticTokens/full",
		response = function (_, data)
			if version[uri] ~= requestedVersion then
				traceLog("SEMANTIC_SKIP_VERSION", filetype, path or "nil", requestedVersion, version[uri] or -1)
				return
			end

			local result = data.result
			if result == nil or result.data == nil then
				traceLog("SEMANTIC_EMPTY_RESULT", filetype, path or "nil", requestedVersion)
				return
			end

			local payload = '[]'
			local spans = {}
			local provider = capabilities[filetype] and capabilities[filetype].semanticTokensProvider
			if provider ~= nil and provider.legend ~= nil then
				spans = decodeSemanticTokens(result.data, provider.legend, splitLines(util.String(buf:Bytes())), filetype)
				payload = serializeSemanticSpans(spans)
			end
			traceLog("SEMANTIC_RESPONSE", filetype, path or "nil", result ~= nil and result.data ~= nil and (#result.data / 5) or 0, #payload)

			semanticByPath[path] = {
				version = requestedVersion,
				payload = payload,
				spans = spans,
			}

			local curPane = micro.CurPane()
			if curPane ~= nil and curPane.Buf ~= nil and diagnosticPathFromBuf(curPane.Buf) == path then
				curPane.Buf:SetSemanticHighlightsJSON(payload, requestedVersion)
			end
		end,
	})
end

local function isDefinitionLikeToken(span)
	if span == nil or span.rawGroup == nil then
		return false
	end
	return span.rawGroup:match("(^|%.)definition(%.|$)") ~= nil or span.rawGroup:match("(^|%.)declaration(%.|$)") ~= nil
end

local function currentWordRange(bp)
	if bp == nil or bp.Buf == nil then
		return nil
	end

	local cur = bp.Buf:GetActiveCursor()
	local line = util.String(bp.Buf:LineBytes(cur.Y))
	if line == '' then
		return nil
	end

	local pos = math.max(1, math.min(#line, cur.X + 1))
	if not isWordChar(line:sub(pos, pos)) and pos > 1 and isWordChar(line:sub(pos - 1, pos - 1)) then
		pos = pos - 1
	end
	if not isWordChar(line:sub(pos, pos)) then
		return nil
	end

	local startPos = pos
	while startPos > 1 and isWordChar(line:sub(startPos - 1, startPos - 1)) do
		startPos = startPos - 1
	end

	local endPos = pos
	while endPos < #line and isWordChar(line:sub(endPos + 1, endPos + 1)) do
		endPos = endPos + 1
	end

	return {
		line = cur.Y,
		start = startPos - 1,
		finish = endPos,
	}
end

local function definitionLikeTokenForRange(entry, line, startX, endX)
	if entry == nil or entry.spans == nil then
		return nil
	end

	for _, span in ipairs(entry.spans) do
		if span.line == line and isDefinitionLikeToken(span) then
			local spanEnd = span.start + span.length
			if span.start < endX and startX < spanEnd then
				return span
			end
		end
	end

	return nil
end

local function definitionLikeTokenAtCursor(bp)
	if bp == nil or bp.Buf == nil then
		return nil
	end

	local path = diagnosticPathFromBuf(bp.Buf)
	if path == nil then
		return nil
	end

	local entry = semanticByPath[path]
	if entry == nil or entry.spans == nil then
		return nil
	end

	local cur = bp.Buf:GetActiveCursor()
	local span = definitionLikeTokenForRange(entry, cur.Y, cur.X, cur.X + 1)
	if span ~= nil then
		return span
	end

	if cur.X > 0 then
		span = definitionLikeTokenForRange(entry, cur.Y, cur.X - 1, cur.X)
		if span ~= nil then
			return span
		end
	end

	local word = currentWordRange(bp)
	if word == nil then
		return nil
	end

	return definitionLikeTokenForRange(entry, word.line, word.start, word.finish)
end

function smartReferenceAction(bp)
	if definitionLikeTokenAtCursor(bp) ~= nil then
		referencesAction(bp)
		return
	end

	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then return; end

	flushPendingDidChangeForBuf(bp.Buf)
	local file = bp.Buf.AbsPath
	local line = bp.Buf:GetActiveCursor().Y
	local char = bp.Buf:GetActiveCursor().X
	local originPane = bp
	sendDefinitionRequest(filetype, file, line, char, function (_, data)
		if definitionMatchesPosition(data, file, line, char) then
			referencesAction(originPane)
			return
		end
		micro.PushJump()
		definitionActionResponse(originPane, data)
	end)
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

-- Returns true if the text to the left of the cursor is a member access
-- pattern like "foo.", "foo.bar", "foo.bar.baz", etc.
function isMemberAccessContext(bp)
	if bp == nil or bp.Buf == nil then
		return false
	end
	local cur = bp.Buf:GetActiveCursor()
	local left = util.String(bp.Buf:LineBytes(cur.Y)):sub(1, cur.X)
	return left:match("[%w_]+%.[%w_]*$") ~= nil
end

-- Decides whether typing a character should trigger LSP completions.
function shouldAutoTriggerCompletion(bp, r)
	if bp == nil or bp.Buf == nil then
		return false
	end
	-- Dot always triggers (member access)
	if r == '.' then
		return true
	end
	-- Regular character: trigger if we're continuing a member access (e.g. typing "ba" after "foo.")
	if r ~= nil then
		return isMemberAccessContext(bp)
	end
	-- Non-rune event (paste, undo): refresh if completions are already visible
	return (bp.Buf.CompletionMenu or bp.Buf:HasGhostCompletion())
		and (isMemberAccessContext(bp) or bp.Buf:CurrentWordLength() > 0)
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
		flushPendingDidChangeForBuf(bp.Buf)
		completionAction(bp)
	end)
end

function scheduleSemanticTokens(target)
	local buf = bufferFromTarget(target)
	if buf == nil then
		return
	end
	local file = buf.AbsPath or ''
	traceLog("SCHEDULE_SEMANTIC", fileTypeFromBuf(buf) or "nil", diagnosticPathFromBuf(buf) or "nil", semanticRequestToken[file] or 0)
	semanticRequestToken[file] = (semanticRequestToken[file] or 0) + 1
	local token = semanticRequestToken[file]
	micro.After(semanticDebounceNs, function()
		if buf == nil then
			return
		end
		local currentFile = buf.AbsPath or ''
		if semanticRequestToken[currentFile] ~= token then
			return
		end
		requestSemanticTokensForBuf(buf)
	end)
end

function completionActionResponse(bp, data)
	local results = data.result
	if results == nil then 
		lspLog("completionActionResponse: nil result", data)
		return
	end
	if results.items then
		results = results.items
	end
	lspLog("completionActionResponse: count", #results)
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
	flushPendingDidChangeForBuf(bp.Buf)
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
	
	flushPendingDidChangeForBuf(bp.Buf)
	local send = withSend(filetype)
	local file = bp.Buf.AbsPath
	local line = bp.Buf:GetActiveCursor().Y
	local char = bp.Buf:GetActiveCursor().X
	local originPane = bp
	send("textDocument/references", fmt.Sprintf('{"textDocument": {"uri": "file://%s"}, "position": {"line": %.0f, "character": %.0f}, "context": {"includeDeclaration":false}}', file, line, char), false, { method = "textDocument/references", response = function (_, data)
		referencesActionResponse(originPane, data)
	end })
end

function referencesActionResponse(bp, data)
	local results = normalizeReferences(data.result or data.partialResult or {})
	if results == nil or #results <= 0 then
		micro.InfoBar():Message("LSP: no references found")
		return
	end

	closeSplitPane()
	if #results == 1 then
		openReferenceLocation(bp, results[1].doc, results[1].line, results[1].character)
		return
	end
	if showReferencesPicker(bp, results) then
		return
	end
	showReferencesSplit(bp, results)
end

-- the rename action request and response
function renameAction(bp, args)
	local filetype = bp.Buf:FileType()
	if cmd[filetype] == nil then return; end
	if args == nil or #args == 0 then
		micro.InfoBar():Message("Usage: rename <new-name>")
		return
	end

	flushPendingDidChangeForBuf(bp.Buf)
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
		local filetype = bp.Buf:FileType()
		local uri = getUriFromBuf(bp.Buf)
		if filetype ~= "unknown" then
			if cmd[filetype] == nil then
				startServer(bp.Buf, filetype, handleInitialized)
				return
			elseif uri ~= nil and version[uri] == nil then
				handleInitialized(bp.Buf, filetype)
			end
		end

		syncBufferDiagnostics(bp.Buf)
		syncBufferSemanticHighlights(bp.Buf)
		if supportsSemanticTokens(bp.Buf:FileType()) then
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
