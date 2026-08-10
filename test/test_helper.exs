# Start each run with a clean test workspace — leftover clones/origins
# from a previous run would collide with this run's unique_integer ids.
File.rm_rf!(Application.fetch_env!(:code_lead, :workspace_root))

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(CodeLead.Repo, :manual)
