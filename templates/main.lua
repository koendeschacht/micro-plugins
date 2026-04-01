VERSION = "0.1.0"

local buffer = import("micro/buffer")
local util = import("micro/util")

local snippetsByFiletype = {
    python = {
        copyright = '"""\nCopyright 2016-2026 Boost AI AS\nAll rights reserved.\n"""',
        types = "from boost.ai import types as T",
        logger = "from boost.ai import logger\n\nLOG = logger.create(__name__)",
        script = '"""\nCopyright 2016-2025 Boost AI AS\nAll rights reserved.\n"""\n\nimport asyncio\nfrom boost.ai import types as T, resources, logger\nfrom mltools.data import data_db\n\nasync def main():\n    await data_db.create()\n    await resources.database.create("tmp script")\n    await resources.http.create()\n    await resources.signals.create("tmp script")\n\n\nif __name__ == "__main__":\n    asyncio.run(main())',
        imports = "from boost.ai import types as T, logger, resources, enums",
    },
}

local function lineContent(bp)
    local cursor = bp.Buf:GetActiveCursor()
    local origin = buffer.Loc(cursor.X, cursor.Y)
    cursor:SelectLine()
    local line = util.String(cursor:GetSelection()):gsub("\r?\n$", "")
    cursor:ResetSelection()
    cursor:GotoLoc(origin)
    return line, origin
end

local function endLoc(start, text)
    local x = start.X
    local y = start.Y

    for i = 1, #text do
        local ch = text:sub(i, i)
        if ch == "\n" then
            y = y + 1
            x = 0
        else
            x = x + 1
        end
    end

    return buffer.Loc(x, y)
end

function expand(bp)
    if bp == nil or bp.Buf == nil or bp.Cursor:HasSelection() then
        return false
    end

    local snippets = snippetsByFiletype[bp.Buf:FileType()]
    if snippets == nil then
        return false
    end

    local line, cursor = lineContent(bp)
    local left = line:sub(1, cursor.X)
    local right = line:sub(cursor.X + 1)
    if right:match("^[%w_]") ~= nil then
        return false
    end

    local trigger = left:match("([%w_]+)$")
    local body = trigger and snippets[trigger] or nil
    if body == nil then
        return false
    end

    local start = buffer.Loc(cursor.X - #trigger, cursor.Y)
    bp.Buf:remove(start, cursor)
    bp.Buf:insert(start, body)
    bp.Cursor:GotoLoc(endLoc(start, body))
    return true
end
