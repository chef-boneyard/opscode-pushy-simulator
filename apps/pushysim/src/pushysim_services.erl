
-module(pushysim_services).

-export([create_client/2]).

-include_lib("public_key/include/public_key.hrl").

%% Create a client in erchef and return {ok, PrivateKey} otherwise
%% an error tuple
-spec create_client(OrgName :: binary(),
                    NodeName :: binary()) -> {ok, rsa_private_key()} | {error, binary()}.
create_client(OrgName, NodeName) ->
    {ok, CreatorKey} = chef_keyring:get_key(creator),
    {ok, CreatorName} = application:get_env(pushysim, creator_name),
    Body = make_body(NodeName),
    Headers = chef_authn:sign_request(CreatorKey, Body,
                                      CreatorName, <<"POST">>,
                                      now, path(OrgName)),
    FullHeaders= [{"Accept", "application/json"} | Headers],
    Url = url(OrgName),
    case ibrowse:send_req(Url, FullHeaders, post, Body) of
        {ok, "404", _ResponseHeaders, _ResponseBody} ->
            not_found;
        {ok, Code, ResponseHeaders, ResponseBody} ->
            ok = check_http_response(Code, ResponseHeaders, ResponseBody),
            parse_json_response(ResponseBody);
        {error, Reason} ->
            throw({error, Reason})
    end.

url(OrgName) ->
    {ok, ErchefHost} = application:get_env(pushysim, erchef_root_url),
    ErchefHost ++ path(OrgName).

path(OrgName) ->
    "/organizations/" ++ binary_to_list(OrgName) ++ "/clients".


make_body(NodeName) ->
    Json = {[{<<"name">>,NodeName},
             {<<"client_name">>,NodeName},
             {<<"admin">>, false}
            ]},
    jiffy:encode(Json).

%% @doc extract the private_key from the json structure.
%%
parse_json_response(Body) ->
    try
        EJson = jiffy:decode(Body),
        lager:info(EJson),
        ej:get({<<"private_key">>}, EJson)
    catch
        throw:{error, _} ->
            throw({error, invalid_json})
    end.


%% @doc Check the code of the HTTP response and throw error if non-2XX
%%
check_http_response(Code, Headers, Body) ->
    case Code of
        "2" ++ _Digits ->
            ok;
        "3" ++ _Digits ->
            throw({error, {redirection, {Code, Headers, Body}}});
        "4" ++ _Digits ->
            throw({error, {client_error, {Code, Headers, Body}}});
        "5" ++ _Digits ->
            throw({error, {server_error, {Code, Headers, Body}}})
    end.


