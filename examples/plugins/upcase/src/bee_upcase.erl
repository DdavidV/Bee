%% Upper-cases every selection of the active editor, as one undoable edit.
-module(bee_upcase).
-behaviour('Elixir.Bee.Plugin').

-export([upcase/2]).

-command({<<"upcase.selection">>, upcase}).

upcase(#{active_editor := nil}, _State) ->
    ok;
upcase(#{active_editor := Path} = Ctx, _State) ->
    Edits = [{From, To, string:uppercase(Text)}
             || {From, To, Text} <- 'Elixir.Bee.API':selected(Ctx), From < To],
    case Edits of
        [] ->
            'Elixir.Bee.API':show_message(Ctx, info, <<"Select some text first">>);
        _ ->
            case 'Elixir.Bee.API':edit(Path, Edits) of
                ok -> ok;
                {error, Reason} ->
                    Message = io_lib:format("Could not edit: ~p", [Reason]),
                    'Elixir.Bee.API':show_message(Ctx, error, iolist_to_binary(Message))
            end
    end,
    ok.
