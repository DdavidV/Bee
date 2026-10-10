# Tests of the extension host (tagged :node) need Node.js.
exclude =
  if System.find_executable("node") do
    []
  else
    IO.puts("Node.js not found: skipping the extension host's tests")
    [:node]
  end

ExUnit.start(exclude: exclude)
