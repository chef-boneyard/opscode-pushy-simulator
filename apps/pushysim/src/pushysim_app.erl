%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @copyright 2011-2012 Opscode Inc.

-module(pushysim_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
%-endif.

-include("pushysim.hrl").

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    error_logger:info_msg("Pushy Client Simulator starting.~n"),
    IoProcesses = pushy_util:get_env(pushysim, zmq_io_processes, fun is_integer/1),
    case erlzmq:context(IoProcesses) of
        {ok, Ctx} ->
            case pushysim_sup:start_link(#client_state{ctx=Ctx}) of
                {ok, Pid} -> {ok, Pid, Ctx};
                Error -> Error
            end;
        Error ->
            Error
    end.

stop(Ctx) ->
    erlzmq:term(Ctx, 5000).
