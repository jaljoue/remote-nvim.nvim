---@diagnostic disable:invisible
describe("Provisioner", function()
  local assert = require("luassert.assert")
  ---@type remote-nvim.RemoteNeovim
  local remote_nvim = require("remote-nvim")
  local Provider = require("remote-nvim.providers.provider")
  local stub = require("luassert.stub")
  local mock = require("luassert.mock")
  local match = require("luassert.match")
  ---@type remote-nvim.providers.Provider
  local provider
  local provider_host
  local progress_viewer
  local remote_nvim_config_copy
  local run_command_stub, upload_stub

  before_each(function()
    provider_host = require("remote-nvim.utils").generate_random_string(6)
    progress_viewer = mock(require("remote-nvim.ui.progressview"), true)
    remote_nvim_config_copy = vim.deepcopy(remote_nvim.config)

    provider = Provider({
      host = provider_host,
      progress_view = progress_viewer,
    })
    stub(vim, "notify")

    provider._config_provider:add_workspace_config(provider.unique_host_id, {
      provider = provider.provider_type,
      host = provider.host,
      connection_options = provider.conn_opts,
      remote_neovim_home = "~/.remote-nvim",
      config_copy = true,
      client_auto_start = nil,
      workspace_id = "akfdjakjfdk",
      neovim_version = "stable",
      os = "Linux",
      arch = "x86_64",
      neovim_install_method = "binary",
    })
    provider:_setup_workspace_variables()
    provider._local_path_to_remote_neovim_config = { "scripts" }

    run_command_stub = stub(provider, "run_command")
    upload_stub = stub(provider, "upload")
  end)

  after_each(function()
    provider._config_provider:remove_workspace_config(provider.unique_host_id)
    remote_nvim.config = remote_nvim_config_copy
  end)

  describe("should describe the desired state", function()
    it("by generating a signature for every provisioning step", function()
      local desired_state = provider._provisioner:desired_state()

      for _, step in ipairs({ "directories", "scripts", "neovim", "config", "data", "cache", "state" }) do
        assert.is_string(desired_state[step])
      end
    end)

    it("by not repeating work when nothing about the desired state changed", function()
      assert.are.same(provider._provisioner:desired_state(), provider._provisioner:desired_state())
    end)

    it("by generating a new signature when the Neovim version changes", function()
      local before_state = provider._provisioner:desired_state()
      provider._remote_neovim_version = "v0.11.0"

      assert.not_equal(before_state["neovim"], provider._provisioner:desired_state()["neovim"])
    end)

    it("by generating a new signature when the copied configuration changes", function()
      local config_path = vim.fn.tempname()
      vim.fn.mkdir(config_path, "p")
      vim.fn.writefile({ "init.lua" }, ("%s/init.lua"):format(config_path))
      provider._local_path_to_remote_neovim_config = { config_path }

      local before_state = provider._provisioner:desired_state()
      vim.fn.writefile({ "vim.opt.number = true" }, ("%s/init.lua"):format(config_path))
      local after_state = provider._provisioner:desired_state()

      assert.not_equal(before_state["config"], after_state["config"])
      vim.fn.delete(config_path, "rf")
    end)

    it("by marking steps that have nothing to do as no-op", function()
      provider._config_provider:update_workspace_config(provider.unique_host_id, { config_copy = false })
      provider:_setup_workspace_variables()

      local desired_state = provider._provisioner:desired_state()
      assert.equals("noop", desired_state["data"])
      assert.equals("noop", desired_state["cache"])
      assert.equals("noop", desired_state["state"])
      assert.equals("noop", desired_state["config"])
    end)
  end)

  describe("should describe the remote state", function()
    local job_stdout_stub

    before_each(function()
      job_stdout_stub = stub(provider.executor, "job_stdout")
    end)

    it("when nothing has been provisioned yet", function()
      job_stdout_stub.returns({})
      assert.are.same({}, provider._provisioner:remote_state())
    end)

    it("when the recorded state is not readable", function()
      job_stdout_stub.returns({ "not-json" })
      assert.are.same({}, provider._provisioner:remote_state())
    end)

    it("when the recorded state was written by an older provisioning version", function()
      job_stdout_stub.returns({ vim.json.encode({ version = 0, steps = { neovim = "signature" } }) })
      assert.are.same({}, provider._provisioner:remote_state())
    end)

    it("when the recorded state is valid", function()
      job_stdout_stub.returns({ vim.json.encode({ version = 1, steps = { neovim = "signature" } }) })
      assert.are.same({ neovim = "signature" }, provider._provisioner:remote_state())
    end)
  end)

  describe("should plan the work to be done", function()
    ---@type remote-nvim.providers.Provisioner
    local provisioner
    local desired_state

    before_each(function()
      provisioner = provider._provisioner
      desired_state = provisioner:desired_state()
    end)

    it("when the remote host is already provisioned", function()
      assert.are.same({}, provisioner:plan(desired_state, desired_state))
    end)

    it("when only some of the steps have to be re-applied", function()
      local remote_state = vim.deepcopy(desired_state)
      remote_state["neovim"] = "outdated"
      remote_state["config"] = nil

      assert.are.same({ "neovim", "config" }, provisioner:plan(desired_state, remote_state))
    end)

    it("when the remote host has never been provisioned", function()
      assert.are.same(
        { "directories", "scripts", "neovim", "config", "data", "cache", "state" },
        provisioner:plan(desired_state, {})
      )
    end)
  end)

  describe("should provision the remote host", function()
    ---@type remote-nvim.providers.Provisioner
    local provisioner

    before_each(function()
      provisioner = provider._provisioner
    end)

    it("by doing nothing when the remote host is already provisioned", function()
      stub(provisioner, "remote_state").returns(provisioner:desired_state())

      provisioner:provision()

      assert.stub(run_command_stub).was.not_called()
      assert.stub(upload_stub).was.not_called()
    end)

    it("by applying only the steps that changed since the last run", function()
      local remote_state = vim.deepcopy(provisioner:desired_state())
      remote_state["neovim"] = "outdated"
      stub(provisioner, "remote_state").returns(remote_state)
      local record_stub = stub(provisioner, "record")

      provisioner:provision()

      assert.stub(run_command_stub).was.called_with(
        match.is_ref(provider),
        "bash ~/.remote-nvim/scripts/neovim_install.sh -v stable -d ~/.remote-nvim -m binary -a x86_64",
        "Installing Neovim (if required)"
      )
      assert.stub(upload_stub).was.not_called()
      assert.stub(record_stub).was.called_with(match.is_ref(provisioner), provisioner:desired_state())
    end)

    it("by recording the state of a freshly provisioned remote host", function()
      stub(provisioner, "remote_state").returns({})

      provisioner:provision()

      assert.stub(upload_stub).was.called_with(
        match.is_ref(provider),
        match.is_string(),
        "~/.remote-nvim/workspaces/akfdjakjfdk/.provisioning-state.json",
        match.is_string()
      )
    end)

    it("by recording a state that can be read back", function()
      local recorded_state
      upload_stub.invokes(function(_, local_path, remote_path, _)
        if remote_path:match("provisioning%-state%.json$") then
          recorded_state = vim.json.decode(table.concat(vim.fn.readfile(local_path), ""))
        end
      end)
      stub(provisioner, "remote_state").returns({})

      provisioner:provision()

      assert.are.same(provisioner:desired_state(), recorded_state["steps"])
    end)
  end)
end)
