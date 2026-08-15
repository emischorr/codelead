defmodule CodeLead.RuntimeConfigTest do
  # async: false — mutates process-global OS env vars.
  use ExUnit.Case, async: false

  @env_vars ["WORKSPACE_ROOT", "TEST_WORKSPACE_ROOT"]

  setup do
    original = Map.new(@env_vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(@env_vars, &System.delete_env/1)
  end

  defp workspace_root(env) do
    "config/runtime.exs"
    |> Config.Reader.read!(env: env, target: :host)
    |> get_in([:code_lead, :workspace_root])
  end

  test "test env ignores WORKSPACE_ROOT" do
    System.put_env("WORKSPACE_ROOT", "/data/workspace")
    assert workspace_root(:test) == Path.expand("tmp/test_workspace")
  end

  test "test env honors TEST_WORKSPACE_ROOT" do
    custom = Path.expand("tmp/other_test_workspace")
    System.put_env("TEST_WORKSPACE_ROOT", custom)
    assert workspace_root(:test) == custom
  end

  test "dev honors WORKSPACE_ROOT" do
    System.put_env("WORKSPACE_ROOT", "/data/workspace")
    assert workspace_root(:dev) == "/data/workspace"
  end

  test "dev falls back to the local workspace dir" do
    System.delete_env("WORKSPACE_ROOT")
    assert workspace_root(:dev) == Path.expand("workspace")
  end
end
