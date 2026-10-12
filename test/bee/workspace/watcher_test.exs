defmodule Bee.Workspace.WatcherTest do
  # The one watcher, with the events a file system watcher would send it.
  use ExUnit.Case, async: false

  alias Bee.Workspace.Watcher

  setup do
    Bee.Workspace.subscribe()
    %{dir: Path.join(System.tmp_dir!(), "bee_watcher_test_#{System.unique_integer([:positive])}")}
  end

  defp event(path), do: send(Process.whereis(Watcher), {:file_event, self(), {path, [:modified]}})

  test "a change is told at once; a burst after it once per path", %{dir: dir} do
    log = Path.join(dir, "build.log")
    other = Path.join(dir, "out.beam")

    event(log)
    assert_receive {:fs_changed, ^log}, 5

    # Written to again and again right after: told once more, not fifty times.
    for _ <- 1..50, do: event(log)
    event(other)
    assert_receive {:fs_changed, ^log}, 200
    assert_receive {:fs_changed, ^other}, 200
    refute_receive {:fs_changed, _}, 100

    # Quiet since: the next change is told at once again.
    event(other)
    assert_receive {:fs_changed, ^other}, 5
  end
end
