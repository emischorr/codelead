# Start each run with a clean test workspace — leftover clones/origins
# from a previous run would collide with this run's unique_integer ids.
#
# Tripwire: the rm_rf! below must never reach real data. The workspace
# root has to be a strict subdirectory of this checkout — anything else
# means an inherited WORKSPACE_ROOT/TEST_WORKSPACE_ROOT points at a live
# workspace (this has happened: an agent's `mix test` inside a task
# worktree wiped a deployed instance's workspace volume).
workspace_root = Path.expand(Application.fetch_env!(:code_lead, :workspace_root))
project_dir = File.cwd!()

unless String.starts_with?(workspace_root, project_dir <> "/") do
  raise """
  refusing to delete workspace_root:

      #{workspace_root}

  It is outside the project directory (#{project_dir}). The test suite
  wipes workspace_root before running; a root outside the checkout is
  real data, not test scratch. If a custom location is truly needed,
  TEST_WORKSPACE_ROOT must resolve to a path inside the checkout.
  """
end

File.rm_rf!(workspace_root)

# The suite runs as a licensed (:owner) instance, so gated features —
# container execution today — are exercised by the ordinary tests instead
# of being refused everywhere. Tests that assert the gate itself install a
# community grant in their own setup; see `CodeLead.LicenseHelpers`.
CodeLead.LicenseHelpers.grant_owner!()

# :docker tests need a real Docker daemon (`mix test --only docker`);
# :devcontainer tests additionally need the devcontainer CLI
# (`mix test --only devcontainer`).
ExUnit.start(exclude: [:docker, :devcontainer])
Ecto.Adapters.SQL.Sandbox.mode(CodeLead.Repo, :manual)
