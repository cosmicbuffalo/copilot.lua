local api = require("copilot.api")
local c = require("copilot.client")
local logger = require("copilot.logger")

local M = {}

local function echo(message)
  vim.cmd('echom "[Copilot] ' .. tostring(message):gsub('"', '\\"') .. '"')
end

function M.setup(client)
  local function copy_to_clipboard(str)
    vim.cmd(string.format(
      [[
        let @+ = "%s"
        let @* = "%s"
      ]],
      str,
      str
    ))
  end

  local function open_signin_popup(code, url)
    local lines = {
      " [Copilot] ",
      "",
      " First copy your one-time code: ",
      "   " .. code .. " ",
      " In your browser, visit: ",
      "   " .. url .. " ",
      "",
      " ...waiting, it might take a while and ",
      " this popup will auto close once done... ",
    }
    local height, width = #lines, math.max(unpack(vim.tbl_map(function(line)
      return #line
    end, lines)))

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    local winid = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      style = "minimal",
      border = "single",
      row = (vim.o.lines - height) / 2,
      col = (vim.o.columns - width) / 2,
      height = height,
      width = width,
    })
    vim.api.nvim_set_option_value("winhighlight", "Normal:Normal", { win = winid })

    return function()
      vim.api.nvim_win_close(winid, true)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end

  local initiate_setup = coroutine.wrap(function()
    local cserr, status = api.check_status(client)
    if cserr then
      echo(cserr)
      return
    end

    if status.user then
      echo("Authenticated as GitHub user: " .. status.user)
      return
    end

    local siierr, signin = api.sign_in_initiate(client)
    if siierr then
      echo(siierr)
      return
    end

    if not signin.verificationUri or not signin.userCode then
      echo("Failed to setup")
      return
    end

    copy_to_clipboard(signin.userCode)

    local close_signin_popup = open_signin_popup(signin.userCode, signin.verificationUri)

    local sicerr, confirm = api.sign_in_confirm(client, { userCode = signin.userCode })

    close_signin_popup()

    if sicerr then
      echo(sicerr)
      return
    end

    if string.lower(confirm.status) ~= "ok" then
      echo("Authentication failure: " .. confirm.error.message)
      return
    end

    echo("Authenticated as GitHub user: " .. confirm.user)
  end)

  initiate_setup()
end

function M.signin()
  c.use_client(function(client)
    M.setup(client)
  end)
end

function M.signout()
  c.use_client(function(client)
    api.check_status(
      client,
      { options = { localChecksOnly = true } },
      ---@param status copilot_check_status_data
      function(err, status)
        if err then
          echo(err)
          return
        end

        if status.user then
          echo("Signed out as GitHub user " .. status.user)
        else
          echo("Not signed in")
        end

        api.sign_out(client, function() end)
      end
    )
  end)
end

function M.find_config_path()
  local config = vim.fn.expand("$XDG_CONFIG_HOME")
  if config and vim.fn.isdirectory(config) > 0 then
    return config
  elseif vim.fn.has("win32") > 0 then
    config = vim.fn.expand("~/AppData/Local")
    if vim.fn.isdirectory(config) > 0 then
      return config
    end
  else
    config = vim.fn.expand("~/.config")
    if vim.fn.isdirectory(config) > 0 then
      return config
    end
  end

  logger.error("could not find config path")
end

M.get_creds = function()
  local filename = M.find_config_path() .. "/github-copilot/apps.json"

  if vim.fn.filereadable(filename) == 0 then
    logger.error("Copilot auth file could not be read from:" .. filename)
    return
  end

  local filedata = vim.api.nvim_eval("readfile('" .. filename .. "')")

  if not filedata or #filedata == 0 then
    logger.error("Copilot's apps.json file not found or empty, make sure to sign in first")
    return
  end

  local appsdata = vim.json.decode(filedata[1])
  return appsdata
end

function M.info()
  local info = M.get_creds()
  if not info then
    logger.error("no GitHub Copilot token found, make sure to sign in first")
    return
  end

  logger.notify("GitHub Copilot token information: ", info)
end

local auth_cache = {
  status = nil,
  timestamp = 0,
  lsp_check_pending = false,
}

local function get_cache_ttl(status)
  if status then
    return 300000 -- 5 minutes for true status
  else
    return 30000  -- 30 seconds for false status
  end
end

function M.is_authenticated()
  local current_time = vim.loop.now()

  if auth_cache.status ~= nil and not auth_cache.lsp_check_pending then

    local ttl = get_cache_ttl(auth_cache.status)
    if (current_time - auth_cache.timestamp) < ttl then
      return auth_cache.status
    end
  end

  local client = c.get()
  if not client then
    auth_cache.status = false
    auth_cache.timestamp = current_time
    return false
  end

  if auth_cache.lsp_check_pending then
    return auth_cache.status or false
  end

  auth_cache.lsp_check_pending = true
  vim.schedule(function()
    api.check_status(client, {}, function(err, status)
      auth_cache.lsp_check_pending = false
      local current_check_time = vim.loop.now()

      if not err and status and status.user then
        auth_cache.status = true
        auth_cache.timestamp = current_check_time
      else
        auth_cache.status = false
        auth_cache.timestamp = current_check_time
      end
    end)
  end)

  return auth_cache.status or false
end

return M
