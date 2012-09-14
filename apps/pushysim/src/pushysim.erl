%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author James Casey <james@opscode.com>
%% @copyright 2011-2012 Opscode Inc.

%% @doc Public API of pushysim
-module(pushysim).

%% API
-export([start_client/1,
         start_clients/1
        ]).

%% ===================================================================
%% API functions
%% ===================================================================

%% @doc start a client with a given InstanceId which identifies
%% it on this simulator instance
start_client(InstanceId) when is_integer(InstanceId) ->
    supervisor:start_child(pushysim_client_sup, [InstanceId]).

%% @doc Start a set of clients.  They are create in series.
start_clients(Num) when is_integer(Num) ->
    [ start_client(N) || N <- lists:seq(1, Num)].


