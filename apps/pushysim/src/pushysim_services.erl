
-module(pushysim_services).

-export([create_job/2]).

-include_lib("public_key/include/public_key.hrl").
-type json_term() :: any().

%% Create a job in erchef, running on all the nodes, and return the JobId
%% (or throws an error)
-spec create_job(OrgName :: binary(),
                 Nodes :: [binary()]) -> json_term().
create_job(OrgName, Nodes) ->
    {ok, CreatorKey} = chef_keyring:get_key(creator),
    {ok, CreatorName} = application:get_env(pushysim, creator_name),
    Body = make_job_body(Nodes),
    {ok, ServerHost} = application:get_env(pushysim, server_name),
    ServerPort = case application:get_env(pushysim, server_api_port) of
                     undefined -> undefined;  % ok to be undefined
                     {ok, P} -> P
                 end,
    Response = pushy_api_request:do_request(CreatorKey, list_to_binary(CreatorName), jobs_path(OrgName), ServerHost, ServerPort, post, Body),
    {ok, Code, ResponseHeaders, _ResponseBody} = Response,
    "201" = Code, % Assert we're getting a "created"
    {_, JobId} = lists:keyfind("Location", 1, ResponseHeaders),
    JobId.

%   Body:
%   Command: <<"chef-client">> (built-in job-handler -- maybe it is ignored though)
%   NodeName: client names
%   RunTimeout: 10000 (or undefined)
%   Quorum: Number of clients (or undefined)
-spec make_job_body([binary()]) -> binary().
make_job_body(Nodes) ->
    jiffy:encode({[{<<"command">>,<<"chef-client">>}, {<<"nodes">>,Nodes}]}).

%   Body:
%   Command: <<"chef-client">> (built-in job-handler -- maybe it is ignored though)
%   NodeName: client names
%   RunTimeout: 10000 (or undefined)
%   Quorum: Number of clients
%-spec make_job_body(Binary, [Binary], integer(), integer()) -> binary().
%make_job_body(Command, Nodes, RunTimeout, Quorum) ->
    %RT = case RunTimeout of undefined -> []; _ -> [{<<"run_timeout">>, RunTimeout}] end,
    %Q = case Quorum of undefined -> []; _ -> [{<<"quorum">>, Quorum}] end,
    %CN = [{<<"command">>,Command}, {<<"nodes">>,Nodes}],
    %Json = {lists:append([CN, RT, Q])},
    %jiffy:encode(Json).

% RunTimeout and Quorum are optional
%make_job_body(Command, Nodes) -> make_job_body(Command, Nodes, undefined).
%make_job_body(Command, Nodes, RunTimeout) ->
    %make_job_body(Command, Nodes, RunTimeout, undefined).

jobs_path(OrgName) -> iolist_to_binary([<<"/organizations/">>, OrgName, <<"/pushy/jobs">>]).
