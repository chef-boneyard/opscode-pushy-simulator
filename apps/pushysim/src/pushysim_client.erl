%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @copyright 2011-2012 Opscode Inc.

-module(pushysim_client).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1,
         heartbeat/0
        ]).

%% ------------------------------------------------------------------
%% Private Exports - only exported for instrumentation
%% ------------------------------------------------------------------

-export([do_send/1
        ]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq/include/erlzmq.hrl").
-include("pushysim.hrl").


%% TODO: tighten typedefs up
-record(state,
        {command_sock :: any(),
         heartbeat_interval :: integer(),
         sequence :: integer(),
         private_key :: any(),
         incarnation_id :: binary(),
         node_id :: binary()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(PushyState) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [PushyState], []).

heartbeat() ->
    gen_server:cast(?SERVER, heartbeat).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------


init([#client_state{ctx = Ctx,
                    node_id = NodeId,
                    instance_id = InstanceId}]) ->
    IncarnationId = list_to_binary(pushy_util:guid_v4()),

    NodeInstance = list_to_binary(io_lib:format("~s~4..0B", [NodeId, InstanceId])),
    lager:info("Starting pushy client with node id ~s (~s).", [NodeInstance, IncarnationId]),
    Interval =  pushy_util:get_env(pushysim, heartbeat_interval, fun is_integer/1),

    {ok, Sock} = erlzmq:socket(Ctx, dealer),
    erlzmq:setsockopt(Sock, linger, 0),

    %% TODO - replace with pushy_utl code to construct address
    Host = pushy_util:get_env(pushysim, server_name, fun is_list/1),
    Port = pushy_util:get_env(pushysim, server_command_port, fun is_integer/1),
    CommandAddress = lists:flatten(io_lib:format("tcp://~s:~w",[Host,Port])),

    lager:info("Client : Connecting to command channel at ~s.", [CommandAddress]),
    erlzmq:connect(Sock, CommandAddress),
    {ok, PrivateKey} = chef_keyring:get_key(client_private),

    State = #state{command_sock = Sock,
                   heartbeat_interval = Interval,
                   sequence = 0,
                   private_key = PrivateKey,
                   node_id = NodeInstance,
                   incarnation_id = IncarnationId
                  },
    timer:apply_interval(Interval, ?MODULE, heartbeat, []),
    {ok, State}.

handle_call(_Request, _From, State) ->
    {noreply, ok, State}.

handle_cast(heartbeat, State) ->
    {noreply, do_send(State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

do_send(#state{command_sock = Sock,
               sequence = Sequence,
               private_key = PrivateKey,
               incarnation_id = IncarnationId,
               node_id = NodeId} = State) ->

    {ok, Hostname} = inet:gethostname(),
    Msg = {[{node, NodeId},
            {client, list_to_binary(Hostname)},
            {org, "pushy"},
            {type, heartbeat},
            {timestamp, list_to_binary(httpd_util:rfc1123_date())},
            {sequence, Sequence},
            {incarnation_id, IncarnationId},
            {job_state, "idle"},
            {job_id, "null"}
           ]},
    % JSON encode message
    BodyFrame = jiffy:encode(Msg),

    % Send Header (including signed checksum)
    HeaderFrame = pushy_util:signed_header_from_message(PrivateKey, BodyFrame),
    pushy_messaging:send_message(Sock, [HeaderFrame, BodyFrame]),
    lager:debug("Heartbeat sent: header=~s,body=~s",[HeaderFrame, BodyFrame]),
    State#state{sequence=Sequence + 1}.


