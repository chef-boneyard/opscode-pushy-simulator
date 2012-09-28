%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author James Casey <james@opscode.com>
%% @copyright 2012 Opscode Inc.

-module(pushysim_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
%-endif.

-include_lib("pushysim.hrl").

%% Helper macro for declaring children of supervisor
-define(SUP(I, Args), {I, {I, start_link, Args}, permanent, infinity, supervisor, [I]}).
-define(WORKER(I, Args), {I, {I, start_link, Args}, permanent, 5000, worker, [I]}).
-define(WORKERNL(I, Args), {I, {I, start, Args}, permanent, 5000, worker, [I]}).
%% ===================================================================
%% API functions
%% ===================================================================

start_link(Ctx) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Ctx]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([#client_state{} = ClientState0]) ->
    Hostname = list_to_binary(pushy_util:get_env(pushysim, server_name, fun is_list/1)),
    Port = pushy_util:get_env(pushysim, server_api_port, fun is_integer/1),
    EnableGraphite = pushy_util:get_env(pushy_common, enable_graphite, fun is_boolean/1),

    ClientState = ClientState0#client_state{server_name = Hostname,
                                            server_port = Port,
                                            client_name = client_name()},
    Workers = [?WORKER(chef_keyring, []),
               ?SUP(pushysim_client_sup, [ClientState])
              ],
    {ok, {{one_for_one, 10, 3600},
         maybe_run_graphite(EnableGraphite, Workers)}}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec client_name() -> binary().
client_name() ->
    {ok, Hostname} = inet:gethostname(),
    list_to_binary(Hostname).

maybe_run_graphite(true, Workers) ->
    [?SUP(folsom_graphite_sup, []) | Workers];
maybe_run_graphite(false, Workers) ->
    Workers.

