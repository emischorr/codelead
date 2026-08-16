defmodule CodeLead.Terminal.CommandTest do
  use ExUnit.Case, async: true

  alias CodeLead.Terminal.Command

  describe "local/3" do
    test "darwin with script uses the BSD form" do
      assert Command.local(:darwin, "sh", "/usr/bin/script") ==
               {"/usr/bin/script", ["-q", "/dev/null", "sh"], true}
    end

    test "linux with script uses the util-linux form" do
      assert Command.local(:linux, "bash", "/usr/bin/script") ==
               {"/usr/bin/script", ["-qec", "bash", "/dev/null"], true}
    end

    test "no script falls back to a plain interactive pipe" do
      assert Command.local(:darwin, "/bin/sh", nil) == {"/bin/sh", ["-i"], false}
      assert Command.local(:linux, "/bin/sh", nil) == {"/bin/sh", ["-i"], false}

      assert Command.local(:unknown, "/bin/sh", "/usr/bin/script") ==
               {"/bin/sh", ["-i"], false}
    end
  end

  describe "docker/6" do
    test "allocates the PTY inside the container when the image has script" do
      argv = Command.docker([], "codelead-task-7", "/work", ["-e", "A=1"], "sh", true)

      assert argv == [
               "exec",
               "-i",
               "-w",
               "/work",
               "-e",
               "A=1",
               "codelead-task-7",
               "script",
               "-qec",
               "sh",
               "/dev/null"
             ]
    end

    test "falls back to a plain pipe shell without script, keeping the argv prefix" do
      argv = Command.docker(["fake"], "codelead-task-7", "/work", [], "sh", false)

      assert argv == ["fake", "exec", "-i", "-w", "/work", "codelead-task-7", "sh", "-i"]
    end
  end
end
