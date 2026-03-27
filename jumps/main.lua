VERSION = "0.2.0"

local micro = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")

-- nextDiagnostic and prevDiagnostic push jump then delegate to the LSP plugin
function jnextDiagnostic(bp)
    micro.PushJump()
    bp:HandleCommand("nextdiag")
end

function jprevDiagnostic(bp)
    micro.PushJump()
    bp:HandleCommand("prevdiag")
end

function init()
    config.MakeCommand("jnextdiag", jnextDiagnostic, config.NoComplete)
    config.MakeCommand("jprevdiag", jprevDiagnostic, config.NoComplete)
    config.TryBindKey("Alt-j", "command:jnextdiag", false)
    config.TryBindKey("Alt-J", "command:jprevdiag", false)
end
