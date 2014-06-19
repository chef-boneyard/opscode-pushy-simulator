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
-include_lib("pushy_common/include/pushy_messaging.hrl").
-include_lib("pushy_common/include/pushy_metrics.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(INTERVAL_METRIC, pushy_metrics:app_metric(?MODULE,<<"heartbeat_interval">>)).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/3,
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
         connect_to_command/5,
         send_heartbeat/1,
         send_response/3,
         receive_message/3,
         respond/3,
         receive_zmq_pid/3
        ]).

%% TODO: tighten typedefs up
-record(state,
        {command_sock :: any(),
         heartbeat_sock :: any(),
         org_name :: binary(),
         heartbeat_interval :: integer(),
         heartbeat_timestamp :: integer(),
         sequence :: integer(),
         server_public_key :: rsa_public_key(),
         session_key :: binary(),
         session_method :: pushy_signing_method(),
         incarnation_id :: binary(),
         node_name :: binary(),
         fastpath :: boolean()}).

-define(ZMQ_CLOSE_TIMEOUT, 10).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(ClientState, OrgName, InstanceId) ->
    gen_server:start_link(?MODULE, [ClientState, OrgName, InstanceId], []).

heartbeat(Pid) ->
    gen_server:cast(Pid, heartbeat).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([#client_state{ctx = Ctx,
                    client_name = ClientName,
                    server_name = Hostname,
                    server_port = Port}, OrgName, InstanceId]) ->
    process_flag(trap_exit, true),

    IncarnationId = list_to_binary(pushy_util:guid_v4()),
    NodeName = list_to_binary(io_lib:format("~s-~4..0B", [ClientName, InstanceId])),
    lager:info("Creating pushy client with node id ~s (~s).", [NodeName, IncarnationId]),

    %% TODO This doesn't work - let's just fly for a bit with the CreatorKey
    %%{ok, PrivateKey} = pushysim_services:create_client(OrgName, NodeName),
    {ok, CreatorKey} = chef_keyring:get_key(creator),
    {ok, CreatorName} = application:get_env(pushysim, creator_name),

    lager:debug("Getting config from Pushy Server ~s:~w", [Hostname, Port]),
    {ok, ClientCurvePubKey, ClientCurveSecKey} = erlzmq:curve_keypair(),
    Config = ?TIME_IT(pushy_client_config, get_config,
                        (OrgName, NodeName, list_to_binary(CreatorName),
                         CreatorKey, Hostname, Port, ClientCurvePubKey)),

    #pushy_client_config{command_address = CommandAddress,
                         heartbeat_address = HeartbeatAddress,
                         heartbeat_interval = Interval,
                         session_method = SessionMethod,
                         session_key = SessionKey,
                         server_public_key = PublicKey,
                         server_curve_key = ServerCurveKey} = Config,

    {ok, HeartbeatSock} = ?TIME_IT(?MODULE, connect_to_heartbeat, (Ctx, HeartbeatAddress)),
    {ok, CommandSock} = ?TIME_IT(?MODULE, connect_to_command, (Ctx, CommandAddress, ServerCurveKey, ClientCurvePubKey, ClientCurveSecKey)),
    {ok, FastPath} = application:get_env(pushysim, enable_fastpath),

    State = #state{command_sock = CommandSock,
                   heartbeat_sock = HeartbeatSock,
                   org_name = OrgName,
                   heartbeat_interval = Interval,
                   sequence = 0,
                   server_public_key = PublicKey,
                   session_key = SessionKey,
                   session_method = SessionMethod,
                   node_name = NodeName,
                   incarnation_id = IncarnationId,
                   fastpath = FastPath
                  },
    start_spread_heartbeat(Interval),
    {ok, State}.

handle_call(getname, _From, #state{node_name = NodeName} = State) ->
    {reply, {ok, NodeName}, State};
handle_call(Request, _From, #state{node_name = NodeName} = State) ->
    lager:warning("handle_call: [~s] unhandled message ~w:", [NodeName, Request]),
    {reply, ignored, State}.

handle_cast(heartbeat, State) ->
    State1 = send_heartbeat(State),
    {noreply, State1};
handle_cast(Msg, #state{node_name = NodeName} = State) ->
    lager:warning("handle_cast: [~s] unhandled message ~w:", [NodeName, Msg]),
    {noreply, State}.

handle_info(start_heartbeat, #state{heartbeat_interval = Interval,
                                    node_name = NodeName} = State) ->
    lager:info("Starting heartbeat: [~s] (interval ~ws)", [NodeName, Interval]),
    timer:apply_interval(Interval, ?MODULE, heartbeat, [self()]),
    {noreply, State#state{heartbeat_timestamp = pushy_time:timestamp()}};
handle_info({zmq, Sock, Frame, [rcvmore]}, #state{fastpath = FastPath} = State) ->
    case FastPath of
        true ->
            {noreply, fastpath_receive_message(Sock, Frame, State)};
        false ->
            {noreply, receive_message(Sock, Frame, State)}
    end;
handle_info(Info, #state{node_name = NodeName} = State) ->
    lager:warning("handle_info: [~s] unhandled message ~w:", [NodeName, Info]),
    {noreply, State}.

terminate(_Reason, #state{command_sock = CommandSock,
                          heartbeat_sock = HeartbeatSock,
                          node_name = NodeName}) ->
    lager:info("Stoppping: [~s]", [NodeName]),
    erlzmq:close(CommandSock, ?ZMQ_CLOSE_TIMEOUT),
    erlzmq:close(HeartbeatSock, ?ZMQ_CLOSE_TIMEOUT),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec send_heartbeat(#state{}) -> #state{}.
send_heartbeat(#state{command_sock = Sock,
                      org_name = OrgName,
                      sequence = Sequence,
                      heartbeat_timestamp = LastTimestamp,
                      session_key = SessionKey,
                      session_method = SessionMethod,
                      incarnation_id = IncarnationId,
                      node_name = NodeName} = State) ->
    lager:debug("Sending heartbeat ~w for ~s", [Sequence, NodeName]),
    Msg = {[{node, NodeName},
            {org, OrgName},
            {type, heartbeat},
            {timestamp, list_to_binary(httpd_util:rfc1123_date())},
            {sequence, Sequence},
            {incarnation_id, IncarnationId},
            {job_state, <<"idle">>},
            {job_id, null}
           ]},
    % JSON encode message
    BodyFrame = jiffy:encode(Msg),

    % Send Header (including signed checksum)
    HeaderFrame = pushy_messaging:make_header(proto_v2, SessionMethod, SessionKey, BodyFrame),
    Now = pushy_time:timestamp(),
    folsom_metrics:notify(?INTERVAL_METRIC, pushy_time:diff_in_secs(LastTimestamp, Now), histogram),
    pushy_messaging:send_message(Sock, [HeaderFrame, BodyFrame]),
    lager:debug("Heartbeat sent: ~s,sequence=~p",[NodeName, Sequence]),
    State#state{sequence=Sequence + 1,
                heartbeat_timestamp=Now}.

-spec send_response(Type :: binary(),
                    JobId :: binary(),
                    State :: #state{}) -> #state{}.
send_response(Type, JobId, #state{command_sock = Sock,
                                  org_name = OrgName,
                                  session_key = SessionKey,
                                  session_method = SessionMethod,
                                  incarnation_id = IncarnationId,
                                  node_name = NodeName} = State) ->
    lager:debug("Sending response for ~s : ~s", [NodeName, Type]),
    Msg = {[{node, NodeName},
            {org, OrgName},
            {type, Type},
            {timestamp, list_to_binary(httpd_util:rfc1123_date())},
            {incarnation_id, IncarnationId},
            {job_id, JobId}
           ]},
    % JSON encode message
    BodyFrame = jiffy:encode(Msg),

    % Send Header (including signed checksum)
    HeaderFrame = pushy_messaging:make_header(proto_v2, SessionMethod, SessionKey, BodyFrame),
    lager:debug("Sending Response: header=~s,body=~s",[HeaderFrame, BodyFrame]),
    pushy_messaging:send_message(Sock, [HeaderFrame, BodyFrame]),
    State.

%% @doc bypass message verification to speed things along
-spec fastpath_receive_message(Sock :: erlzmq_socket(),
                               Frame :: binary(),
                               State :: #state{}) -> #state{}.
fastpath_receive_message(Sock, Frame, #state{command_sock = CommandSock,
                                             heartbeat_sock = HeartbeatSock} = State) ->
    [_Header, Body] = pushy_messaging:receive_message_async(Sock, Frame),
    try ?TIME_IT(jiffy, decode, (Body)) of
        {error, Error} ->
            lager:error("JSON parsing of message failed with error: ~w", [Error]),
            State;
        ParsedBody ->
            case Sock of
                CommandSock ->
                    process_server_command(ParsedBody, State);
                HeartbeatSock ->
                    process_server_heartbeat(ParsedBody, State)
            end
    catch
        throw:Error ->
            lager:error("JSON parsing failed with throw: ~w", [Error]),
            State
    end.

-spec receive_message(Sock :: erlzmq_socket(),
                      Frame :: binary(),
                      State :: #state{}) -> #state{} | {error, bad_body | bad_header}.
receive_message(Sock, Frame, #state{command_sock = CommandSock,
                                    heartbeat_sock = HeartbeatSock,
                                    server_public_key = PublicKey,
                                    session_key = SessionKey} = State) ->
    [Header, Body] = pushy_messaging:receive_message_async(Sock, Frame),

    lager:debug("Received message~n\tH ~s~n\tB ~s", [Header, Body]),
    KeyFun = fun(M, _EJson) ->
            case M of
                hmac_sha256 ->
                    {ok, SessionKey};
                rsa2048_sha1 ->
                    {ok, PublicKey}
            end
    end,
    case catch pushy_messaging:parse_message(Header, Body, KeyFun) of
        {ok, #pushy_message{validated = ok,
                            body = ParsedBody}} ->
            case Sock of
                CommandSock ->
                    process_server_command(ParsedBody, State);
                HeartbeatSock ->
                    process_server_heartbeat(ParsedBody, State)
            end;
        {error, Message}  ->
            lager:error("Command message failed verification: ~s", [Message]),
            {error, Message}
    end.

-spec process_server_command(ParsedBody :: json_term(),
                             State :: #state{}) -> #state{}.
process_server_command(ParsedBody, State) ->
    Type = ej:get({<<"type">>}, ParsedBody),
    JobId = ej:get({<<"job_id">>}, ParsedBody),
    respond(Type, JobId, State).

-spec process_server_heartbeat(ParsedBody :: json_term(),
                               State :: #state{}) -> #state{}.
process_server_heartbeat(ParsedBody, State) ->
    %% TODO - we should do something with these heartbeats...
    ej:get({<<"server">>}, ParsedBody),
    State.

-spec respond(Type :: binary(),
              JobId :: binary(),
              State :: #state{}) -> #state{}.
respond(<<"commit">>, JobId, State) ->
    send_response(<<"ack_commit">>, JobId, State);
respond(<<"run">>, JobId, #state{node_name = NodeName} = State) ->
    State1 = send_response(<<"ack_run">>, JobId, State),
    lager:info("[~s] Wheee ! Running a job...", [NodeName]),
    send_response(<<"succeeded">>, JobId, State1);
respond(<<"abort">>, undefined, State) ->
    send_response(<<"aborted">>, <<"">>, State);
respond(<<"abort">>, JobId, State) ->
    send_response(<<"aborted">>, JobId, State);
respond(<<"ack">>, _, State) ->
    State.


-spec connect_to_command(Ctx :: erlzmq_context(),
                         Address :: list(),
                         ServerCurveKey :: binary(),
                         ClientCurvePubKey :: binary(),
                         ClientCurveSecKey :: binary()) -> {ok, erlzmq_socket()}.
connect_to_command(Ctx, Address, ServerCurveKey, ClientCurvePubKey, ClientCurveSecKey) ->
    lager:debug("Client : Connecting to command channel at ~s.", [Address]),
    {ok, Sock} = erlzmq:socket(Ctx, [dealer, {active, false}]),
    ok = erlzmq:setsockopt(Sock, curve_serverkey, ServerCurveKey),
    ok = erlzmq:setsockopt(Sock, curve_publickey, ClientCurvePubKey),
    ok = erlzmq:setsockopt(Sock, curve_secretkey, ClientCurveSecKey),
    erlzmq:setsockopt(Sock, linger, 0),
    spawn_link(?MODULE, receive_zmq_pid, [self(), Sock, Address]),
    {ok, Sock}.

-spec receive_zmq_pid(Pid :: pid(), Sock :: erlzmq_socket(), Address :: list()) -> ok.
receive_zmq_pid(P, Sock, Address) ->
    erlzmq:connect(Sock, Address),
    receive_zmq(P, Sock, Address).

receive_zmq(P, Sock, Address) ->
    {ok, Msg} = erlzmq:recv(Sock),
    {ok, Rcvmore} = erlzmq:getsockopt(Sock, rcvmore),
    Flags = case Rcvmore of
                0 -> [];
                1 -> [rcvmore]
            end,
    P ! {zmq, Sock, Msg, Flags},
    receive_zmq(P, Sock, Address).
    
-spec connect_to_heartbeat(Ctx :: erlzmq_context(),
                           Address :: list()) -> {ok, erlzmq_socket()}.
connect_to_heartbeat(Ctx, Address) ->
    lager:debug("Client : Connecting to server heartbeat channel at ~s.", [Address]),
    {ok, Sock} = erlzmq:socket(Ctx, [sub, {active, true}]),
    erlzmq:setsockopt(Sock, linger, 0),
    erlzmq:connect(Sock, Address),
    erlzmq:setsockopt(Sock, subscribe, ""),
    {ok, Sock}.

%
% Start a function after a random amount of time spread across a given time interval
% in ms
%
start_spread_heartbeat(Interval) ->
    <<A1:32, A2:32, A3:32>> = crypto:rand_bytes(12),
    random:seed(A1, A2, A3),
    Delay = random:uniform(Interval),
    {ok, _Timer} = timer:send_after(Delay, start_heartbeat).

