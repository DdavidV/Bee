defmodule Bee.ModeTest do
  # Changes the VM's environment.
  use ExUnit.Case, async: false

  @vars ~w(RELEASE_ROOT RELEASE_NAME RELEASE_SYS_CONFIG BINDIR ROOTDIR EMU PROGNAME ELIXIR_ERL_OPTIONS BEE_TEST_KEPT PATH)

  setup do
    before = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- before,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)
  end

  test "a release's own variables aren't passed on to the programs Bee starts" do
    path = System.get_env("PATH")

    System.put_env(%{
      "PATH" => "/rel/erts-16.1.2/bin:/rel/bin:" <> path <> ":/relative-not/rel",
      "RELEASE_ROOT" => "/rel",
      "RELEASE_NAME" => "bee",
      "RELEASE_SYS_CONFIG" => "/rel/sys",
      "BINDIR" => "/rel/erts/bin",
      "ROOTDIR" => "/rel",
      "EMU" => "beam",
      "PROGNAME" => "erl",
      "ELIXIR_ERL_OPTIONS" => "+fnu -noinput",
      "BEE_TEST_KEPT" => "yes"
    })

    Bee.Mode.clean_env()

    for name <- ~w(RELEASE_ROOT RELEASE_NAME RELEASE_SYS_CONFIG BINDIR ROOTDIR EMU PROGNAME),
        do: assert(System.get_env(name) == nil, name)

    # Its own erl isn't the one found any more; the rest of the PATH stays.
    assert System.get_env("PATH") == path <> ":/relative-not/rel"
    assert System.get_env("ELIXIR_ERL_OPTIONS") == "+fnu"
    assert System.get_env("BEE_TEST_KEPT") == "yes"

    # What a program started now sees.
    {out, 0} =
      System.cmd("sh", ["-c", "echo ${ROOTDIR:-none} ${RELEASE_NAME:-none} $BEE_TEST_KEPT"])

    assert out == "none none yes\n"
  end

  test "not from a release: nothing is touched" do
    System.delete_env("RELEASE_ROOT")
    System.put_env(%{"BINDIR" => "/somewhere", "ELIXIR_ERL_OPTIONS" => "-noinput"})

    Bee.Mode.clean_env()

    assert System.get_env("BINDIR") == "/somewhere"
    assert System.get_env("ELIXIR_ERL_OPTIONS") == "-noinput"
  end
end
