VERSION = "0.1.1"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")

local function shellQuote(text)
    return "'" .. string.gsub(text, "'", "'\\''") .. "'"
end

local function trim(text)
    if text == nil then
        return ""
    end
    return text:match("^%s*(.-)%s*$")
end

local function runCommand(command)
    local output, err = shell.RunCommand("sh -c " .. shellQuote(command))
    if err ~= nil then
        return nil, err
    end
    return output, nil
end

local function commandSucceeded(command)
    local _, err = shell.RunCommand("sh -c " .. shellQuote(command))
    return err == nil
end

local function parentDir(path)
    return path:match("^(.*)/[^/]*$") or "."
end

local function gitRoot(bp)
    if bp == nil or bp.Buf == nil or bp.Buf.AbsPath == nil or bp.Buf.AbsPath == "" then
        return nil, "view_pr: current buffer is not a file"
    end

    local root, err = runCommand("git -C " .. shellQuote(parentDir(bp.Buf.AbsPath)) .. " rev-parse --show-toplevel")
    if err ~= nil then
        return nil, "view_pr: current buffer is not in a git repository"
    end

    root = trim(root)
    if root == "" then
        return nil, "view_pr: could not determine repository root"
    end
    return root, nil
end

local function parsePrUrl(input)
    local cleaned = trim(input or "")
    cleaned = cleaned:gsub("#.*$", "")
    cleaned = cleaned:gsub("%?.*$", "")
    local owner, repo, pr = cleaned:match("^https://github%.com/([^/]+)/([^/]+)/pull/(%d+)/?.*$")
    if owner == nil then
        owner, repo, pr = cleaned:match("^https://github%.com/([^/]+)/([^/]+)/pull/(%d+)$")
    end
    if owner == nil then
        return nil
    end
    return { owner = owner, repo = repo, number = pr }
end

local function fetchPrRefs(pr)
    local command = "gh pr view " .. shellQuote(pr.number) ..
        " --repo " .. shellQuote(pr.owner .. "/" .. pr.repo) ..
        " --json headRefName,baseRefName --template '{{.headRefName}}\n{{.baseRefName}}'"
    local output, err = runCommand(command)
    if err ~= nil then
        return nil, "view_pr: could not read PR information"
    end

    local head, base = output:match("([^\n]+)\n([^\n]+)")
    if head == nil or base == nil then
        return nil, "view_pr: could not determine PR branches"
    end

    return { head = trim(head), base = trim(base) }, nil
end

local function currentBranch(root)
    local output, err = runCommand("git -C " .. shellQuote(root) .. " branch --show-current")
    if err ~= nil then
        return ""
    end
    return trim(output)
end

local function worktreeClean(root)
    local output, err = runCommand("git -C " .. shellQuote(root) .. " status --porcelain")
    if err ~= nil then
        return false
    end
    return trim(output) == ""
end

local function localBranchExists(root, branch)
    return commandSucceeded("git -C " .. shellQuote(root) .. " rev-parse --verify --quiet refs/heads/" .. shellQuote(branch) .. " >/dev/null")
end

local function remoteBranchExists(root, branch)
    return commandSucceeded("git -C " .. shellQuote(root) .. " rev-parse --verify --quiet refs/remotes/origin/" .. shellQuote(branch) .. " >/dev/null")
end

local function checkoutHeadBranch(root, branch)
    if localBranchExists(root, branch) then
        local _, err = runCommand("git -C " .. shellQuote(root) .. " checkout " .. shellQuote(branch))
        if err ~= nil then
            return false
        end
        return true
    end

    if remoteBranchExists(root, branch) then
        local _, err = runCommand("git -C " .. shellQuote(root) .. " checkout --track " .. shellQuote("origin/" .. branch))
        if err ~= nil then
            return false
        end
        return true
    end

    return false
end

local function targetRef(root, branch)
    if localBranchExists(root, branch) then
        return branch
    end
    if remoteBranchExists(root, branch) then
        return "origin/" .. branch
    end
    return branch
end

local function mergeBase(root, baseRef, headRef)
    local output, err = runCommand("git -C " .. shellQuote(root) .. " merge-base " .. shellQuote(baseRef) .. " " .. shellQuote(headRef))
    if err ~= nil then
        return nil
    end
    output = trim(output)
    if output == "" then
        return nil
    end
    return output
end

local function reopenBuffer(bp)
    if bp == nil or bp.Buf == nil then
        return
    end
    bp.Buf:ReOpen()
end

local function viewPrFromUrlResolved(bp, input)
    bp = bp or micro.CurPane()
    local root, rootErr = gitRoot(bp)
    if rootErr ~= nil then
        micro.InfoBar():Error(rootErr)
        return
    end

    local pr = parsePrUrl(input)
    if pr == nil then
        micro.InfoBar():Error("view_pr: expected a GitHub PR URL")
        return
    end

    local refs, refsErr = fetchPrRefs(pr)
    if refsErr ~= nil then
        micro.InfoBar():Error(refsErr)
        return
    end

    if currentBranch(root) ~= refs.head then
        if not worktreeClean(root) then
            micro.InfoBar():Error("view_pr: worktree must be clean before checking out the PR branch")
            return
        end
        if not checkoutHeadBranch(root, refs.head) then
            micro.InfoBar():Error("view_pr: could not checkout PR branch " .. refs.head)
            return
        end
        reopenBuffer(bp)
    end

    local baseRef = targetRef(root, refs.base)
    local mergeBaseRef = mergeBase(root, baseRef, "HEAD")
    if mergeBaseRef == nil then
        micro.InfoBar():Error("view_pr: could not determine PR merge base")
        return
    end

    bp:HandleCommand("gitdifftarget " .. mergeBaseRef)
end

function viewPrFromUrl(bp)
    micro.InfoBar():Prompt("PR URL: ", "", "view_pr", nil, function(resp, canceled)
        if canceled then
            return
        end
        viewPrFromUrlResolved(bp, resp)
    end)
end

function init()
    config.MakeCommand("view_pr_from_url", viewPrFromUrl, config.NoComplete)
    config.RegisterActionLabel("command:view_pr_from_url", "view PR")
end
