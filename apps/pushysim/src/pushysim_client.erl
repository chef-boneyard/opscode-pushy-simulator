%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @copyright 2011-2012 Opscode Inc.

-module(pushysim_client).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq/include/erlzmq.hrl").
-include("pushysim.hrl").
-include_lib("pushy_common/include/pushy_client.hrl").
-include_lib("pushy_common/include/pushy_metrics.hrl").


%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/2,
         heartbeat/1
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


%% ------------------------------------------------------------------
%% Private Exports - only exported for instrumentation
%% ------------------------------------------------------------------

-export([connect_to_heartbeat/2,
         connect_to_command/2,
         send_heartbeat/1,
         send_response/3,
         receive_message/3,
         respond/3
        ]).

%% TODO: tighten typedefs up
-record(state,
        {command_sock :: any(),
         heartbeat_sock :: any(),
         client_name :: binary(),
         heartbeat_interval :: integer(),
         sequence :: integer(),
         server_public_key,
         private_key :: any(),
         incarnation_id :: binary(),
         node_id :: binary()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(ClientState, InstanceId) ->
    gen_server:start_link(?MODULE, [ClientState, InstanceId], []).

heartbeat(Pid) ->
    gen_server:cast(Pid, heartbeat).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

-spec init([#client_state{}]) -> {ok, #state{} }.
init([#client_state{ctx = Ctx,
                    client_name = ClientName,
                    server_name = Hostname,
                    server_port = Port}, InstanceId]) ->
    IncarnationId = list_to_binary(pushy_util:guid_v4()),

    lager:debug("Getting config from Pushy Server ~s:~w", [Hostname, Port]),
    #pushy_client_config{command_address = CommandAddress,
                         heartbeat_address = HeartbeatAddress,
                         heartbeat_interval = Interval,
                         server_public_key = PublicKey } = ?TIME_IT(pushy_client_config, get_config,
                                                                    (?PUSHY_ORGNAME, Hostname, Port)),

    NodeId = list_to_binary(io_lib:format("~s-~4..0B", [ClientName, InstanceId])),
    lager:info("Starting pushy client with node id ~s (~s).", [NodeId, IncarnationId]),


    {ok, HeartbeatSock} = ?TIME_IT(?MODULE, connect_to_heartbeat, (Ctx, HeartbeatAddress)),
    {ok, CommandSock} = ?TIME_IT(?MODULE, connect_to_command, (Ctx, CommandAddress)),

    {ok, PrivateKey} = chef_keyring:get_key(client_private),

    State = #state{command_sock = CommandSock,
                   heartbeat_sock = HeartbeatSock,
                   client_name = ClientName,
                   heartbeat_interval = Interval,
                   sequence = 0,
                   server_public_key = PublicKey,
                   private_key = PrivateKey,
                   node_id = NodeId,
                   incarnation_id = IncarnationId
                  },
    lager:info("Starting heartbeat for ~s (interval ~ws)", [NodeId, Interval]),
    {ok, _Timer} = timer:apply_interval(Interval, ?MODULE, heartbeat, [self()]),
    {ok, State}.

handle_call(_Request, _From, State) ->
    {noreply, ok, State}.

handle_cast(heartbeat, State) ->
    State1 = send_heartbeat(State),
    {noreply, State1};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({zmq, Sock, Frame, [rcvmore]}, State) ->
    {noreply, receive_message(Sock, Frame, State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec send_heartbeat(#state{}) -> #state{}.
send_heartbeat(#state{command_sock = Sock,
                      client_name = ClientName,
                      sequence = Sequence,
                      private_key = PrivateKey,
                      incarnation_id = IncarnationId,
                      node_id = NodeId} = State) ->
    lager:debug("Sending heartbeat ~d for ~s", [Sequence, NodeId]),

    Msg = {[{node, NodeId},
            {client, ClientName},
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

-spec send_response(Type :: binary(),
                    JobId :: binary(),
                    State :: #state{}) -> #state{}.
send_response(Type, JobId, #state{command_sock = Sock,
                                  client_name = ClientName,
                                  private_key = PrivateKey,
                                  incarnation_id = IncarnationId,
                                  node_id = NodeId} = State) ->
    lager:debug("Sending response for ~s : ~s", [NodeId, Type]),
    Msg = {[{node, NodeId},
            {client, ClientName},
            {org, "pushy"},
            {type, Type},
            {timestamp, list_to_binary(httpd_util:rfc1123_date())},
            {incarnation_id, IncarnationId},
            {job_id, JobId}
           ]},
    % JSON encode message
    BodyFrame = jiffy:encode(Msg),

    % Send Header (including signed checksum)
    HeaderFrame = pushy_util:signed_header_from_message(PrivateKey, BodyFrame),
    lager:debug("Sending Response: header=~s,body=~s",[HeaderFrame, BodyFrame]),
    pushy_messaging:send_message(Sock, [HeaderFrame, BodyFrame]),
    State.

-spec receive_message(Sock :: erlzmq_socket(),
                      Frame :: binary(),
                      State :: #state{}) -> #state{} | {error, bad_body | bad_header}.
receive_message(Sock, Frame, #state{command_sock = CommandSock,
                               heartbeat_sock = HeartbeatSock,
                               server_public_key = PublicKey} = State) ->
    [Header, Body] = pushy_messaging:receive_message_async(Sock, Frame),

    lager:debug("Received message~n\tH ~s~n\tB ~s", [Header, Body]),
    case catch pushy_util:do_authenticate_message(Header, Body, PublicKey) of
        ok ->
            case Sock of
                CommandSock ->
                    process_server_command(Body, State);
                HeartbeatSock ->
                    process_server_heartbeat(Body, State)
            end;
        {no_authn, bad_sig} ->
            lager:error("Command message failed verification: header=~s", [Header]),
            {error, bad_header}
    end.

-spec process_server_command(binary(), #state{}) -> #state{} | {error, bad_body}.
process_server_command(Body, State) ->
    case catch jiffy:decode(Body) of
        {Data} ->
            Type = ej:get({<<"type">>}, Data),
            JobId = ej:get({<<"job_id">>}, Data),
            respond(Type, JobId, State);
        {'EXIT', Error} ->
            lager:error("Status message JSON parsing failed: body=~s, error=~s", [Body, Error]),
            {error, bad_body}
    end.

-spec process_server_heartbeat(binary(), #state{}) -> #state{} | {error, bad_body}.
process_server_heartbeat(Body, State) ->
    case catch jiffy:decode(Body) of
        {Data} ->
            %% TODO - we should do something with these heartbeats...
            ej:get({<<"server">>}, Data),
            State;
        {'EXIT', Error} ->
            lager:error("Server heartbeat JSON parsing failed: body=~s, error=~s", [Body, Error]),
            {error, bad_body}
    end.

-spec respond(Type :: binary(),
              JobId :: binary(),
              State :: #state{}) -> #state{}.
respond(<<"commit">>, JobId, State) ->
    send_response(<<"ack_commit">>, JobId, State);
respond(<<"run">>, JobId, #state{node_id = NodeId} = State) ->
    State1 = send_response(<<"ack_run">>, JobId, State),
    lager:info("[~s] Wheee ! Running a job...", [NodeId]),
    send_response(<<"complete">>, JobId, State1);
respond(<<"abort">>, JobId, State) ->
    send_response(<<"aborted">>, JobId, State).


-spec connect_to_command(Ctx :: erlzmq_context(),
                         Address :: list()) -> {ok, erlzmq_socket()}.
connect_to_command(Ctx, Address) ->
    lager:debug("Client : Connecting to command channel at ~s.", [Address]),
    {ok, Sock} = erlzmq:socket(Ctx, [dealer, {active, true}]),
    erlzmq:setsockopt(Sock, linger, 0),
    erlzmq:connect(Sock, Address),
    {ok, Sock}.

-spec connect_to_heartbeat(Ctx :: erlzmq_context(),
                           Address :: list()) -> {ok, erlzmq_socket()}.
connect_to_heartbeat(Ctx, Address) ->
    lager:debug("Client : Connecting to server heartbeat channel at ~s.", [Address]),
    {ok, Sock} = erlzmq:socket(Ctx, [sub, {active, true}]),
    erlzmq:connect(Sock, Address),
    erlzmq:setsockopt(Sock, subscribe, ""),
    {ok, Sock}.

