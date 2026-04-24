VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")

local scratchCount = 0

local function nextScratchName()
    scratchCount = scratchCount + 1
    return string.format("scratch-%d.md", scratchCount)
end

function openMarkdownScratch(bp)
    bp = bp or micro.CurPane()
    if bp == nil then
        return false
    end

    local scratch = buffer.NewScratchBuffer("", nextScratchName())
    scratch:SetOptionNative("filetype", "markdown")
    bp:HSplitBuf(scratch)
    return true
end

function init()
    config.RegisterActionLabel("lua:markdownscratch.openMarkdownScratch", "open scratch")
end
