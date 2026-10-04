defmodule Bee.Commands.CommandTest do
  use ExUnit.Case, async: true

  defmodule Sample do
    use Bee.Commands.Command

    @command "sample.first"
    def first(wb), do: wb

    @command "sample.multi"
    def multi(%{active: nil} = wb), do: wb
    def multi(wb), do: wb

    def not_a_command(wb), do: wb
  end

  test "builds the id → function table" do
    assert Sample.__commands__() == %{"sample.first" => :first, "sample.multi" => :multi}
  end

  defp compile(body) do
    name = "Elixir.Bee.Commands.CommandTest.Dynamic#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{name} do
      use Bee.Commands.Command
      #{body}
    end
    """)
  end

  test "duplicate ids are a compile error" do
    assert_raise CompileError, ~r/defined twice/, fn ->
      compile("""
      @command "x"
      def a(wb), do: wb
      @command "x"
      def b(wb), do: wb
      """)
    end
  end

  test "handlers take exactly one argument" do
    assert_raise CompileError, ~r/must take 1 argument/, fn ->
      compile("""
      @command "x"
      def a(wb, extra), do: {wb, extra}
      """)
    end
  end

  test "handlers must be public" do
    assert_raise CompileError, ~r/public function/, fn ->
      compile("""
      @command "x"
      defp a(wb), do: wb
      def b(wb), do: a(wb)
      """)
    end
  end

  test "a dangling @command is a compile error" do
    assert_raise CompileError, ~r/not followed by a function/, fn ->
      compile(~s(@command "x"))
    end
  end
end
