---@diagnostic disable:invisible
---@alias remote-nvim.providers.Provisioner.Step
---| '"directories"' # Workspace directories that must exist on the remote host
---| '"scripts"' # Plugin scripts that must be available on the remote host
---| '"neovim"' # Neovim release that must be installed on the remote host
---| '"config"' # Local Neovim configuration copied onto the remote host
---| '"data"' # Local Neovim data directories copied onto the remote host
---| '"cache"' # Local Neovim cache directories copied onto the remote host
---| '"state"' # Local Neovim state directories copied onto the remote host

---@class remote-nvim.providers.Provisioner: remote-nvim.Object
---@field private provider remote-nvim.providers.Provider Provider whose remote host gets provisioned
---@field private logger plenary.logger Logger instance
local Provisioner = require("remote-nvim.middleclass")("Provisioner")

local provider_utils = require("remote-nvim.providers.utils")
---@type remote-nvim.RemoteNeovim
local remote_nvim = require("remote-nvim")
local utils = require("remote-nvim.utils")

---Version of the provisioning state recorded on the remote host. Bumping it invalidates older records.
local STATE_VERSION = 1

---Name of the file storing the provisioning state inside the remote workspace
local STATE_FILE_NAME = ".provisioning-state.json"

---Steps in the order in which they must be applied on the remote host
local STEPS = { "directories", "scripts", "neovim", "config", "data", "cache", "state" }

---Signature recorded for a step that has nothing to do on the remote host
local NO_WORK = "noop"

---Modulus that keeps the intermediate values of a signature exactly representable
local SIGNATURE_MODULUS = 2147483647

---Compute a deterministic signature for the provided string
---@param str string String whose signature should be computed
---@return string signature Signature of the provided string
local function signature(str)
  local hash = 5381
  for idx = 1, #str do
    hash = (hash * 33 + str:byte(idx)) % SIGNATURE_MODULUS
  end
  return ("%x-%x"):format(#str, hash)
end

---Collect the entries describing everything found under the provided local path
---@param path string Local path that should be described
---@param entries string[] List collecting the descriptions
---@return boolean readable Could the path be read?
local function collect_path_entries(path, entries)
  local stat = utils.uv.fs_stat(path)
  if stat == nil then
    return false
  end

  if stat.type ~= "directory" then
    table.insert(entries, ("%s:%s:%s.%s"):format(path, stat.size, stat.mtime.sec, stat.mtime.nsec))
    return true
  end

  local names = {}
  local readable = pcall(function()
    for name in vim.fs.dir(path) do
      table.insert(names, name)
    end
  end)
  if not readable then
    return false
  end

  table.sort(names)
  for _, name in ipairs(names) do
    if not collect_path_entries(utils.path_join(utils.is_windows, path, name), entries) then
      return false
    end
  end

  return true
end

---Describe everything found under the provided local paths
---@param paths string[] Local paths that should be described
---@return string[]? entries Sorted descriptions of the paths; nil, if any of the paths could not be read
local function fingerprint(paths)
  local entries = {}
  for _, path in ipairs(paths) do
    if not collect_path_entries(path, entries) then
      return nil
    end
  end
  table.sort(entries)
  return entries
end

---@class remote-nvim.providers.ProvisionerOpts
---@field provider remote-nvim.providers.Provider Provider whose remote host should be provisioned

---Create new provisioner instance
---@param opts remote-nvim.providers.ProvisionerOpts Provisioner options
function Provisioner:init(opts)
  assert(opts.provider ~= nil, "Provider must be provided")
  self.provider = opts.provider
  self.logger = utils.get_logger()
end

---@private
---Get path of the file storing the provisioning state on the remote host
---@return string state_path Path of the provisioning state file on the remote host
function Provisioner:_state_path()
  return utils.path_join(self.provider._remote_is_windows, self.provider._remote_workspace_id_path, STATE_FILE_NAME)
end

---@private
---Get directories that must exist on the remote host
---@return string[] dirs Directories that must exist on the remote host
function Provisioner:_necessary_dirs()
  local provider = self.provider
  return {
    provider._remote_scripts_path,
    utils.path_join(provider._remote_is_windows, provider._remote_xdg_config_path, remote_nvim.config.remote.app_name),
    utils.path_join(provider._remote_is_windows, provider._remote_xdg_cache_path, remote_nvim.config.remote.app_name),
    utils.path_join(provider._remote_is_windows, provider._remote_xdg_state_path, remote_nvim.config.remote.app_name),
    utils.path_join(provider._remote_is_windows, provider._remote_xdg_data_path, remote_nvim.config.remote.app_name),
    provider:_remote_neovim_binary_dir(),
  }
end

---@private
---Get local directory containing the plugin scripts
---@return string script_dir Local directory containing the plugin scripts
function Provisioner:_default_script_dir()
  local script_dir = vim.fn.fnamemodify(remote_nvim.default_opts.neovim_install_script_path, ":h:p")
  if not script_dir:match("/$") then
    script_dir = script_dir .. "/"
  end
  return script_dir
end

---@private
---Get local paths that get uploaded onto the remote host as plugin scripts
---@return string[] local_paths Local paths that get uploaded onto the remote host
function Provisioner:_local_script_paths()
  ---@type string[]
  local local_paths = { self:_default_script_dir() }

  if remote_nvim.default_opts.neovim_install_script_path ~= remote_nvim.config.neovim_install_script_path then
    table.insert(local_paths, remote_nvim.config.neovim_install_script_path)
  end

  return local_paths
end

---@private
---Get remote paths of the plugin scripts that must be executable
---@return string[] remote_paths Remote paths that must be executable
function Provisioner:_remote_script_paths()
  local default_script_dir = self:_default_script_dir()
  local local_script_paths = vim.fs.find(function(name, _)
    return name:match("%.sh$")
  end, { limit = math.huge, type = "file", path = default_script_dir })
  local remote_paths = {}

  for _, path in ipairs(local_script_paths) do
    local relative_path = vim.fn.fnamemodify(path, ":p"):gsub("^" .. vim.pesc(default_script_dir), "")
    table.insert(
      remote_paths,
      utils.path_join(self.provider._remote_is_windows, self.provider._remote_scripts_path, relative_path)
    )
  end

  return remote_paths
end

---@private
---Should the Neovim release be uploaded from the local machine onto the remote host?
---@return boolean should_upload Should the release be uploaded from the local machine?
function Provisioner:_should_upload_offline_release()
  return self.provider.offline_mode and self.provider._remote_neovim_install_method ~= "system"
end

---@private
---Get local paths of the Neovim release that gets uploaded in offline mode
---@return string[] local_paths Local paths of the Neovim release
function Provisioner:_offline_release_paths()
  local provider = self.provider
  local local_release_path = utils.path_join(
    utils.is_windows,
    remote_nvim.config.offline_mode.cache_dir,
    provider_utils.get_offline_neovim_release_name(
      provider._remote_os,
      provider._remote_neovim_version,
      provider._remote_arch,
      provider._remote_neovim_install_method
    )
  )

  ---@type string[]
  local local_paths = { local_release_path }
  if provider._remote_neovim_install_method == "binary" then
    table.insert(local_paths, ("%s.sha256sum"):format(local_release_path))
  end

  return local_paths
end

---@private
---Compute the signature of the provided local paths
---@param paths string[] Local paths whose signature should be computed
---@param extra string[]? Additional values that should influence the signature
---@return string signature Signature of the provided paths
function Provisioner:_paths_signature(paths, extra)
  local entries = fingerprint(paths)
  if entries == nil then
    -- We could not describe the paths, so this step can never be considered as already done
    return utils.generate_random_string(16)
  end
  return signature(table.concat(vim.list_extend(entries, extra or {}), "\n"))
end

---@private
---Compute the signature of the directories that must exist on the remote host
---@return string signature Signature of the directories step
function Provisioner:_directories_signature()
  return signature(table.concat(self:_necessary_dirs(), "\n"))
end

---@private
---Compute the signature of the plugin scripts that must be uploaded onto the remote host
---@return string signature Signature of the scripts step
function Provisioner:_scripts_signature()
  return self:_paths_signature(self:_local_script_paths(), {
    self.provider._remote_neovim_home,
    self.provider._remote_scripts_path,
  })
end

---@private
---Compute the signature of the Neovim release that must be installed on the remote host
---@return string signature Signature of the neovim step
function Provisioner:_neovim_signature()
  local provider = self.provider
  return self:_paths_signature(self:_should_upload_offline_release() and self:_offline_release_paths() or {}, {
    provider._remote_neovim_version,
    provider._remote_neovim_install_method,
    provider._remote_arch,
    provider._remote_neovim_home,
    provider._remote_neovim_install_script_path,
  })
end

---@private
---Compute the signature of the local Neovim configuration copied onto the remote host
---@return string signature Signature of the config step
function Provisioner:_config_signature()
  if not self.provider:_get_neovim_config_upload_preference() then
    return NO_WORK
  end
  return self:_paths_signature(self.provider._local_path_to_remote_neovim_config, {
    self.provider._remote_neovim_config_path,
  })
end

---@private
---Compute the signature of the local XDG directories copied onto the remote host
---@param step remote-nvim.providers.Provisioner.Step Step whose signature should be computed
---@return string signature Signature of the provided step
function Provisioner:_copy_dirs_signature(step)
  local local_paths = self.provider._local_path_copy_dirs[step]
  if vim.tbl_isempty(local_paths) then
    return NO_WORK
  end

  local remote_upload_path = utils.path_join(
    self.provider._remote_is_windows,
    self.provider["_remote_xdg_" .. step .. "_path"],
    remote_nvim.config.remote.app_name
  )
  return self:_paths_signature(local_paths, { remote_upload_path })
end

---@private
---Compute the signature of the provided step
---@param step remote-nvim.providers.Provisioner.Step Step whose signature should be computed
---@return string signature Signature describing the work the step does on the remote host
function Provisioner:_step_signature(step)
  if step == "directories" then
    return self:_directories_signature()
  elseif step == "scripts" then
    return self:_scripts_signature()
  elseif step == "neovim" then
    return self:_neovim_signature()
  elseif step == "config" then
    return self:_config_signature()
  end
  return self:_copy_dirs_signature(step)
end

---Get the state that the remote host must have to run the desired Neovim server
---@return table<remote-nvim.providers.Provisioner.Step, string> desired_state Signatures of all provisioning steps
function Provisioner:desired_state()
  local desired_state = {}
  for _, step in ipairs(STEPS) do
    desired_state[step] = self:_step_signature(step)
  end
  return desired_state
end

---Get the state that was recorded on the remote host the last time it was provisioned
---@return table<remote-nvim.providers.Provisioner.Step, string> remote_state Signatures recorded on the remote host
function Provisioner:remote_state()
  local state_path = self:_state_path()
  self.provider:run_command(("cat %s 2>/dev/null || true"):format(state_path), "Checking remote provisioning state")

  local contents = table.concat(self.provider.executor:job_stdout(), "")
  if contents == "" then
    return {}
  end

  local decoded, state = pcall(vim.json.decode, contents)
  if not decoded or type(state) ~= "table" or state.version ~= STATE_VERSION then
    self.logger.fmt_debug(
      "[%s][%s] Discarding unreadable provisioning state",
      self.provider.provider_type,
      self.provider.unique_host_id
    )
    return {}
  end

  return state.steps or {}
end

---Determine the steps that must be applied on the remote host
---@param desired_state table<remote-nvim.providers.Provisioner.Step, string> State the remote host must have
---@param remote_state table<remote-nvim.providers.Provisioner.Step, string>? State recorded on the remote host
---@return remote-nvim.providers.Provisioner.Step[] pending_steps Steps that must be applied on the remote host
function Provisioner:plan(desired_state, remote_state)
  remote_state = remote_state or {}

  local pending_steps = {}
  for _, step in ipairs(STEPS) do
    if remote_state[step] ~= desired_state[step] then
      table.insert(pending_steps, step)
    end
  end
  return pending_steps
end

---@private
---Apply the provided step on the remote host
---@param step remote-nvim.providers.Provisioner.Step Step that should be applied
function Provisioner:_apply_step(step)
  self.logger.fmt_debug(
    "[%s][%s] Provisioning '%s' on remote host",
    self.provider.provider_type,
    self.provider.unique_host_id,
    step
  )

  if step == "directories" then
    self:_provision_directories()
  elseif step == "scripts" then
    self:_provision_scripts()
  elseif step == "neovim" then
    self:_provision_neovim()
  elseif step == "config" then
    self:_provision_config()
  else
    self:_provision_copy_dirs(step)
  end
end

---Apply the provided steps on the remote host
---@param steps remote-nvim.providers.Provisioner.Step[] Steps that should be applied
function Provisioner:apply(steps)
  for _, step in ipairs(steps) do
    self:_apply_step(step)
  end
end

---Record the state of the remote host once it has been provisioned
---@param state table<remote-nvim.providers.Provisioner.Step, string> State of the remote host post provisioning
function Provisioner:record(state)
  local recorded_state = { version = STATE_VERSION, steps = state }

  local local_state_path = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode(recorded_state) }, local_state_path)

  self.provider:upload(local_state_path, self:_state_path(), "Recording provisioning state on remote")
  vim.fn.delete(local_state_path)
end

---Provision the remote host so that it can run the desired Neovim server
function Provisioner:provision()
  local desired_state = self:desired_state()
  local pending_steps = self:plan(desired_state, self:remote_state())

  if #pending_steps == 0 then
    self.logger.fmt_debug(
      "[%s][%s] Remote host is already provisioned. Skipping provisioning.",
      self.provider.provider_type,
      self.provider.unique_host_id
    )
    return
  end

  self.logger.fmt_debug(
    "[%s][%s] Provisioning steps to be applied: %s",
    self.provider.provider_type,
    self.provider.unique_host_id,
    table.concat(pending_steps, ", ")
  )
  self:apply(pending_steps)
  self:record(desired_state)
end

---@private
---Create the directories that must exist on the remote host
function Provisioner:_provision_directories()
  local mkdirs_cmds = {}
  for _, dir in ipairs(self:_necessary_dirs()) do
    table.insert(mkdirs_cmds, ("mkdir -p %s"):format(dir))
  end
  self.provider:run_command(table.concat(mkdirs_cmds, " && "), "Creating custom neovim directories on remote")
end

---@private
---Upload the plugin scripts onto the remote host and make them executable
function Provisioner:_provision_scripts()
  local provider = self.provider

  provider:upload(
    vim.fn.fnamemodify(remote_nvim.default_opts.neovim_install_script_path, ":h"),
    provider._remote_neovim_home,
    "Copying plugin scripts onto remote"
  )

  if remote_nvim.default_opts.neovim_install_script_path ~= remote_nvim.config.neovim_install_script_path then
    provider:upload(
      remote_nvim.config.neovim_install_script_path,
      provider._remote_scripts_path,
      "Copying custom install scripts specified by user"
    )
  end

  local chmod_cmds = vim.tbl_map(function(script_path)
    return ("chmod +x %s"):format(script_path)
  end, self:_remote_script_paths())
  if #chmod_cmds > 0 then
    provider:run_command(table.concat(chmod_cmds, " && "), "Setting up plugin scripts on remote")
  end
end

---@private
---Install the desired Neovim release on the remote host
function Provisioner:_provision_neovim()
  local provider = self.provider
  local install_cmd = ("bash %s -v %s -d %s -m %s -a %s"):format(
    provider._remote_neovim_install_script_path,
    provider._remote_neovim_version,
    provider._remote_neovim_home,
    provider._remote_neovim_install_method,
    provider._remote_arch
  )

  if self:_should_upload_offline_release() then
    if not remote_nvim.config.offline_mode.no_github then
      provider:run_command(
        ("bash %s -o %s -v %s -a %s -t %s -d %s"):format(
          utils.path_join(utils.is_windows, utils.get_plugin_root(), "scripts", "neovim_download.sh"),
          provider._remote_os,
          provider._remote_neovim_version,
          provider._remote_arch,
          provider._remote_neovim_install_method,
          remote_nvim.config.offline_mode.cache_dir
        ),
        "Downloading Neovim release locally",
        nil,
        nil,
        true
      )
    end

    provider:upload(
      self:_offline_release_paths(),
      provider:_remote_neovim_binary_dir(),
      "Upload Neovim release from local to remote"
    )

    install_cmd = install_cmd .. " -o"
  end

  provider:run_command(install_cmd, "Installing Neovim (if required)")
end

---@private
---Upload the local Neovim configuration onto the remote host
function Provisioner:_provision_config()
  local provider = self.provider
  if not provider:_get_neovim_config_upload_preference() then
    return
  end

  provider:upload(
    provider._local_path_to_remote_neovim_config,
    provider._remote_neovim_config_path,
    "Copying your Neovim configuration files onto remote",
    remote_nvim.config.remote.copy_dirs.config.compression
  )
end

---@private
---Upload the local XDG directories onto the remote host
---@param step remote-nvim.providers.Provisioner.Step Step whose directories should be uploaded
function Provisioner:_provision_copy_dirs(step)
  local provider = self.provider
  local local_paths = provider._local_path_copy_dirs[step]
  if vim.tbl_isempty(local_paths) then
    return
  end

  local remote_upload_path = utils.path_join(
    provider._remote_is_windows,
    provider["_remote_xdg_" .. step .. "_path"],
    remote_nvim.config.remote.app_name
  )
  provider:upload(
    local_paths,
    remote_upload_path,
    ("Copying over Neovim '%s' directories onto remote"):format(step),
    remote_nvim.config.remote.copy_dirs[step].compression
  )
end

return Provisioner
