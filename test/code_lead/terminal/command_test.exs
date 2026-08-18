defmodule CodeLead.Terminal.CommandTest do
  use ExUnit.Case, async: true

  alias CodeLead.Terminal.Command

  describe "local/3" do
    test "darwin with script uses the BSD form" do
      assert {"/usr/bin/script", ["-q", "/dev/null", "sh", "-c", payload], true} =
               Command.local(:darwin, "sh", "/usr/bin/script")

      assert payload == Command.payload("sh")
    end

    test "linux with script uses the util-linux form" do
      assert {"/usr/bin/script", ["-qec", payload, "/dev/null"], true} =
               Command.local(:linux, "bash", "/usr/bin/script")

      assert payload == Command.payload("bash")
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
               Command.payload("sh"),
               "/dev/null"
             ]
    end

    test "falls back to a plain pipe shell without script, keeping the argv prefix" do
      argv = Command.docker(["fake"], "codelead-task-7", "/work", [], "sh", false)

      assert argv == ["fake", "exec", "-i", "-w", "/work", "codelead-task-7", "sh", "-i"]
    end
  end

  describe "payload/1" do
    test "records the PTY device, applies the initial size, then execs the shell" do
      payload = Command.payload("/bin/zsh")

      assert payload =~ ~s(tty > "$CODELEAD_TTY_FILE")
      assert payload =~ ~s(stty rows "$LINES" cols "$COLUMNS")
      assert String.ends_with?(payload, "exec /bin/zsh -i")
    end

    test "every preparatory step is silenced so a bare context still gets a shell" do
      payload = Command.payload("sh")

      [prep, exec] = String.split(payload, "; exec ", parts: 2)

      assert exec == "sh -i"

      for step <- String.split(prep, "; ") do
        assert String.ends_with?(step, "2>/dev/null"), "unsilenced preparatory step: #{step}"
      end
    end

    test "avoids subshells, so the whole payload survives as one script argument" do
      refute Command.payload("sh") =~ "$("
    end
  end

  describe "resize_script/3" do
    test "reads the recorded device and tries both stty device flags" do
      script = Command.resize_script("/tmp/codelead-tty-7", 132, 45)

      assert script =~ ~s(read -r tty < "/tmp/codelead-tty-7")
      assert script =~ ~s(stty -F "$tty" rows 45 cols 132)
      assert script =~ ~s(stty -f "$tty" rows 45 cols 132)
    end

    test "a missing device file short-circuits before any stty runs" do
      missing = Path.join(System.tmp_dir!(), "codelead-tty-absent-#{System.unique_integer()}")

      assert {_output, status} =
               System.cmd("sh", ["-c", Command.resize_script(missing, 80, 24)],
                 stderr_to_stdout: true
               )

      assert status != 0
    end
  end
end
