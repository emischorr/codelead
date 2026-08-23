defmodule CodeLead.Executor.EnvScrubTest do
  # async: false — the spawn test mutates process-global OS env vars.
  use ExUnit.Case, async: false

  alias CodeLead.Executor.Context
  alias CodeLead.Executor.EnvScrub
  alias CodeLead.Executor.LocalSubprocess

  describe "port_env/1" do
    test "emits removal entries for internal vars and charlist pairs for explicit env" do
      env = EnvScrub.port_env([{"MY_VAR", "value"}])

      assert {~c"WORKSPACE_ROOT", false} in env
      assert {~c"DATABASE_URL", false} in env
      assert {~c"MY_VAR", ~c"value"} in env
    end

    test "an explicitly set internal key is not scrubbed" do
      env = EnvScrub.port_env([{"DATABASE_URL", "ecto://target-app-db"}])

      refute {~c"DATABASE_URL", false} in env
      assert {~c"DATABASE_URL", ~c"ecto://target-app-db"} in env
    end

    # A previewed app inheriting it would believe it is the instance
    # running the subdomain gateway.
    test "the gateway selector is instance config, so it is scrubbed too" do
      assert {~c"PREVIEW_DOMAIN", false} in EnvScrub.port_env([{"MY_VAR", "value"}])
    end
  end

  describe "cmd_env/1" do
    test "emits unset entries for internal vars, keeping explicit env" do
      env = EnvScrub.cmd_env([{"MY_VAR", "value"}])

      assert {"WORKSPACE_ROOT", nil} in env
      assert {"MY_VAR", "value"} in env
    end

    test "an explicitly set internal key is not scrubbed" do
      env = EnvScrub.cmd_env([{"WORKSPACE_ROOT", "/elsewhere"}])

      refute {"WORKSPACE_ROOT", nil} in env
      assert {"WORKSPACE_ROOT", "/elsewhere"} in env
    end
  end

  describe "LocalSubprocess.spawn/2 environment" do
    setup do
      original = System.get_env("WORKSPACE_ROOT")
      System.put_env("WORKSPACE_ROOT", "/data/workspace")

      on_exit(fn ->
        if original do
          System.put_env("WORKSPACE_ROOT", original)
        else
          System.delete_env("WORKSPACE_ROOT")
        end
      end)

      :ok
    end

    test "the spawned process does not see internal vars but sees the explicit env" do
      context = %Context{
        type: :folder,
        path: File.cwd!(),
        task_id: 1,
        env: [{"CODELEAD_TEST_VAR", "visible"}]
      }

      {:ok, port} = LocalSubprocess.spawn(context, ["env"])
      output = collect_port_output(port)

      refute output =~ "WORKSPACE_ROOT="
      assert output =~ "CODELEAD_TEST_VAR=visible"
    end

    defp collect_port_output(port, acc \\ "") do
      receive do
        {^port, {:data, data}} -> collect_port_output(port, acc <> data)
        {^port, {:exit_status, 0}} -> acc
      after
        5_000 -> flunk("spawned process did not exit: #{acc}")
      end
    end
  end
end
