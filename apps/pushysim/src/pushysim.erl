%% ex: ts=4 sw=4 et
%% @author James Casey <james@opscode.com>
%% @copyright 2011-2012 Opscode Inc.

%% @doc Public API of pushysim
-module(pushysim).

%% API
-export([start_client/1,
         start_clients/1,
         start_clients/2,
         stop_clients/0,
         count_clients/0,
         start_jobs/0,
         start_jobs/1
        ]).

%% ===================================================================
%% API functions
%% ===================================================================

%% @doc start a client with a given InstanceId which identifies
%% it on this simulator instance
start_client(InstanceId) when is_integer(InstanceId) ->
    supervisor:start_child(pushysim_client_sup, [org_name(), InstanceId]).

%% @doc Start a set of clients.  They are created in series.
start_clients(Num) when is_integer(Num) ->
    start_clients(1, Num).

%% @doc Start a set of clients.  They are created in a range.
start_clients(Num1,Num2) when is_integer(Num1), is_integer(Num2) ->
    Clients = [ begin
                    start_client(N),
                    timer:sleep(5)
                end || N <- lists:seq(Num1, Num2)],
    {ok, length(Clients)}.

%% @doc Cleanly stop all running clients, shutting down zeromq sockets.
%% We let the pushy_client_sup do the work for us.
%%
stop_clients() ->
    lager:info("Stopping ~w clients", [count_clients()]),
    supervisor:terminate_child(pushysim_sup, pushysim_client_sup),
    supervisor:restart_child(pushysim_sup, pushysim_client_sup).

count_clients() ->
    ClientDesc = supervisor:count_children(pushysim_client_sup),
    proplists:get_value(workers, ClientDesc).

start_jobs() ->
    Cs = supervisor:which_children(pushysim_client_sup),
    Ns = [gen_server:call(P, getname) || {_, P, _, _} <- Cs],
    Names = [Name || {ok, Name} <- Ns],
    start_jobs(Names).

start_jobs(Names) ->
    OrgName = org_name(),
    pushysim_services:create_job(OrgName, Names).

%%
%% INTERNAL FUNCTIONS
%%

org_name() ->
    list_to_binary(pushy_util:get_env(pushysim, org_name, fun is_list/1)).
