%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author James Casey <james@opscode.com>
%% @copyright 2011-2012 Opscode Inc.

%% @doc A supervisor which manages a pool of clients
%% and can create and control them on demand
-module(pushysim_client_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
%-endif.

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Ctx) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Ctx]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([Ctx]) ->
    %% Seed the RNG which we'll use in the client init/1
    <<A1:32, A2:32, A3:32>> = crypto:rand_bytes(12),
    random:seed(A1, A2, A3),

    {ok, {{simple_one_for_one, 0, 1},
          [{pushysim_client, {pushysim_client, start_link, [Ctx]},
            temporary, brutal_kill, worker, [pushysim_client]}
          ]}}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
