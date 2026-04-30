VERSION = "0.1.0"

local micro = import("micro")
local filepath = import("filepath")

local styleMarker = string.char(31)
local home = os.getenv("HOME") or ""

local function styled(text, styleName)
    if text == nil or text == "" or styleName == nil or styleName == "" then
        return text or ""
    end
    return styleMarker .. styleName .. styleMarker .. text
end

function init()
    micro.SetStatusInfoFn("statuspath.display")
end

function display(buf)
    if buf == nil then
        return ""
    end

    local name = buf:GetName()
    if name == nil or name == "" then
        return ""
    end

    if home ~= "" and string.sub(name, 1, #home) == home and (#name == #home or string.sub(name, #home + 1, #home + 1) == "/") then
        name = "~" .. string.sub(name, #home + 1)
    end

    local base = filepath.Base(name)
    local split = #name - #base
    if split <= 0 then
        return styled(base, "statusline.path.filename") .. styleMarker .. styleMarker
    end

    local prefix = string.sub(name, 1, split)
    return styled(prefix, "statusline.path") .. styled(base, "statusline.path.filename") .. styleMarker .. styleMarker
end
