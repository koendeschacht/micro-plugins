VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")

local jumpHistory = {}
local jumpIndex = 0
local MAX_HISTORY = 100
local isJumping = false

-- pushJump saves the current cursor position to the jump history.
-- Called from this plugin's hooks and from the LSP plugin before jumps.
function pushJump(bp)
    if isJumping then return end
    local file = bp.Buf.AbsPath
    if file == nil or file == "" then return end
    local line = bp.Buf:GetActiveCursor().Y
    local char = bp.Buf:GetActiveCursor().X

    -- Truncate forward history when branching from a previous jump
    while #jumpHistory > jumpIndex do
        table.remove(jumpHistory)
    end

    -- Don't record duplicate of last entry (same file and line)
    if jumpIndex > 0 then
        local last = jumpHistory[jumpIndex]
        if last.file == file and last.line == line then return end
    end

    table.insert(jumpHistory, {file = file, line = line, char = char})
    if #jumpHistory > MAX_HISTORY then
        table.remove(jumpHistory, 1)
    end
    jumpIndex = #jumpHistory
end

function jumpToEntry(bp, entry)
    isJumping = true
    local currentFile = bp.Buf.AbsPath
    if entry.file ~= currentFile then
        local newBuf, err = buffer.NewBufferFromFile(entry.file)
        if err == nil then
            micro.CurPane():OpenBuffer(newBuf)
        else
            micro.InfoBar():Message("Could not open: " .. entry.file)
            isJumping = false
            return
        end
    end
    bp.Buf:GetActiveCursor():GotoLoc(buffer.Loc(entry.char, entry.line))
    bp:Center()
    isJumping = false
end

function jumpBack(bp)
    if jumpIndex <= 1 then
        micro.InfoBar():Message("No previous jump")
        return
    end
    -- Save current position before going back (only if at the end of history)
    if jumpIndex == #jumpHistory then
        pushJump(bp)
    end
    jumpIndex = jumpIndex - 1
    jumpToEntry(bp, jumpHistory[jumpIndex])
end

function jumpForward(bp)
    if jumpIndex >= #jumpHistory then
        micro.InfoBar():Message("No next jump")
        return
    end
    jumpIndex = jumpIndex + 1
    jumpToEntry(bp, jumpHistory[jumpIndex])
end

-- jgotoAction saves position then jumps to the given line number
function jgotoAction(bp, args)
    if args == nil or #args == 0 then
        micro.InfoBar():Message("Usage: jgoto <line>")
        return
    end
    local line = tonumber(args[1])
    if line == nil then
        micro.InfoBar():Message("Invalid line number")
        return
    end
    pushJump(bp)
    bp.Buf:GetActiveCursor():GotoLoc(buffer.Loc(0, line - 1))
    bp:Center()
end

function init()
    config.MakeCommand("jgoto", jgotoAction, config.NoComplete)
    config.TryBindKey("Alt-h", "command:jumpback", false)
    config.TryBindKey("Alt-l", "command:jumpforward", false)
end

-- Hooks for built-in jump actions
function preCursorPageUp(bp)   pushJump(bp) end
function preCursorPageDown(bp) pushJump(bp) end
function preFindNext(bp)       pushJump(bp) end
function preFindPrevious(bp)   pushJump(bp) end
