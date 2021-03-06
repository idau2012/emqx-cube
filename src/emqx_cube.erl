%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(emqx_cube).

-behaviour(gen_statem).

-include("emqx_cube.hrl").
-include_lib("emqtt/include/emqtt.hrl").
-include_lib("emqx/include/logger.hrl").

-define(DEFAULT_RECONNECT_DELAY_MS, timer:seconds(5)).

%% API
-export([start_link/1]).

%% gen_statem callbacks
-export([ callback_mode/0
        , init/1
        , terminate/3
        , code_change/4
        ]).

-export([ connecting/3
        , connected/3
        ]).

-export([ l2a/1
        , b2a/1
        , b2l/1
        ]).

-export([ encode_result/2
        , make_rsp_msg/2
        , send_response/1
        , send_response/2
        ]).

-import(proplists, [ get_value/3
                   , delete/2
                   ]).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Config) when is_list(Config) ->
    start_link(maps:from_list(Config));
start_link(Config) ->
    gen_statem:start_link({local, name(cube)}, ?MODULE, Config, []).

callback_mode() -> [state_functions, state_enter].

init(Config = #{username := UserName}) ->
    process_flag(trap_exit, true),
    BinUserName = list_to_binary(UserName),
    {ok, connecting, Config#{client_id => BinUserName,
                             keepalive => 60,
                             reconnect_delay_ms =>
                                  maps:get(reconnect_delay_ms, Config, ?DEFAULT_RECONNECT_DELAY_MS),
                             control_topic => <<"cube/control/", BinUserName/binary>>,
                             ack_topic => <<"cube/ack/", BinUserName/binary>>}}.

%% @doc Connecting state is a state with timeout.
%% After each timeout, it re-enters this state and start a retry until
%% successfully connected to remote node/cluster.
connecting(enter, connected, #{reconnect_delay_ms := Timeout}) ->
    Action = {state_timeout, Timeout, reconnect},
    {keep_state_and_data, Action};
connecting(enter, _, #{reconnect_delay_ms := Timeout} = State) ->
    ConnectConfig = maps:without([reconnect_delay_ms], State),
    case connect(ConnectConfig) of
        {ok, ConnRef, ConnPid} ->
            ?LOG(info, "[Cube] ~p connected", [name(cube)]),
            Action = {state_timeout, 0, connected},
            {keep_state, State#{conn_ref => ConnRef, connection => ConnPid}, Action};
        Error ->
            ?LOG(error, "[Cube] connected failed, Error: ~p ", [Error]),
            Action = {state_timeout, Timeout, reconnect},
            {keep_state_and_data, Action}
    end;
connecting(state_timeout, connected, State) ->
    {next_state, connected, State};
connecting(state_timeout, reconnect, _State) ->
    repeat_state_and_data;
connecting(info, {disconnected, _Ref, _Reason}, _State) ->
    keep_state_and_data;
connecting(Type, Content, State) ->
    common(connecting, Type, Content, State).

connected(enter, _OldState, _State) ->
    keep_state_and_data;
connected(info, {disconnected, ConnRef, Reason},
          #{conn_ref := ConnRefCurrent, connection := ConnPid} = State) ->
    case ConnRefCurrent =:= ConnRef of
        true ->
            ?LOG(info, "[Cube] ~p disconnected ~p reason=~p", [name(cube), ConnPid, Reason]),
            {next_state, connecting,
             State#{conn_ref := undefined, connection := undefined}};
        false ->
            keep_state_and_data
    end;
connected(Type, Content, State) ->
    common(connected, Type, Content, State).

common(StateName, Type, Content, State) ->
    ?LOG(info, "[Cube] ~p discarded ~p type event at state ~p:\n~p", [name(cube), Type, StateName, Content]),
    {keep_state, State}.

terminate(_Reason, _State, _Data) ->
    void.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

connect(Config = #{control_topic := ControlTopic}) ->
    Ref = make_ref(),
    Parent = self(),
    Handlers = make_msg_handler(Config, Parent, Ref),
    ConnectConfig = maps:without([control_topic, ack_topic],
                                 Config#{msg_handler => Handlers}),
    Subs = [{ControlTopic, 1}],
    case emqtt:start_link(ConnectConfig) of
        {ok, Pid} ->
            case emqtt:connect(Pid) of
                {ok, _} ->
                    try
                        subscribe_remote_topics(Pid, Subs),
                        {ok, Ref, Pid}
                    catch
                        throw:Reason ->
                            ?LOG(error, "[Cube] Subscribing remote topics failed, Reason : ~p", [Reason]),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    ?LOG(error, "[Cube] Connecting remote cube server failed, Reason : ~p", [Reason]),
                    {error, Reason}
            end;
        {error, _} = Error ->
            ?LOG(error, "[Cube] Starting Client failed, Error: ~p", [Error]),
            Error
    end.

name(Id) -> list_to_atom(lists:concat([?MODULE, "_", Id])).

make_msg_handler(Config, Parent, Ref) ->
    #{publish => fun(Msg) -> handle_msg(Msg, Config) end,
      puback => fun(_Ack) -> ok end,
      disconnected => fun(Reason) -> Parent ! {disconnected, Ref, Reason} end}.

handle_msg(Msg = #{topic     := ControlTopic,
                   payload   := Payload},
           Config = #{control_topic := ControlTopic,
                      ack_topic  := RspTopic}) ->
    ?LOG(debug, "[Cube] Handled message: ~p ~n, Config: ~p", [Msg, Config]),
    handle_payload(Payload, RspTopic);
handle_msg(_Msg, _Interaction) ->
    ok.

handle_payload(Payload, RspTopic) ->
    RspMsg = case emqx_json:safe_decode(Payload) of
                 {ok, Req} ->
                     {ok, RspPayload} = handle_request(Req, RspTopic),
                     make_rsp_msg(RspTopic, RspPayload);
                 {error, _Reason} ->
                     {ok, RspPayload} = encode_result([{code, ?ERROR1}], []),
                     make_rsp_msg(RspTopic, RspPayload)
             end,
    ?LOG(debug, "[Cube] Response message: ~p", [RspMsg]),
    ok = send_response(RspMsg).

subscribe_remote_topics(ClientPid, Subscriptions) ->
    lists:foreach(fun({Topic, QoS}) ->
                      case emqtt:subscribe(ClientPid, Topic, QoS) of
                          {ok, _, _} -> ok;
                          Error -> throw(Error)
                      end
                  end, Subscriptions).

send_response(Client, Msg) ->
    %% This function is evaluated by emqtt itself.
    %% hence delegate to another temp process for the loopback gen_statem call.
    spawn(fun() ->
              case emqtt:publish(Client, Msg) of
                  {error, Reason} ->
                      ?LOG(info, "Publish failed, Message: ~p, Reason: ~p", [Msg, Reason]);
                  _Ok -> ok
              end
          end),
    ok.

send_response(Msg) ->
    send_response(self(), Msg).

handle_request(Req, RspTopic) ->
    Type = b2l(get_value(<<"type">>, Req, <<>>)),
    Fun = b2a(get_value(<<"action">>, Req, <<>>)),
    RawArgs = get_value(<<"payload">>, Req, []),
    Args = convert(RawArgs),
    Module = list_to_atom("emqx_cube_" ++ Type),
    try Module:Fun(Args#{rsp_topic => RspTopic, cube_pid => self()}) of
        {ok, Result} ->
            encode_result(Result, Req)
    catch
        error:undef ->
            ?LOG(error, "[Cube] ~p is wrong action.", [Fun]),
            encode_result([{code, ?ERROR2}], Req);
        error:function_clause ->
            ?LOG(error, "[Cube] ~p is wrong type.", [Module]),
            encode_result([{code, ?ERROR3}], Req);
        Error:Reason ->
            ?LOG(error, "[Cube] Error: ~p, Reason: ~p, Args: ~p", [Error, Reason, Args]),
            encode_result([{code, ?ERROR5}], Req)
    end.

encode_result(Result, Req) ->
    Rsp = return(maps:from_list(Result)),
    emqx_json:safe_encode(restruct(Rsp, Req)).

b2a(B) -> binary_to_atom(B, utf8).

b2l(B) -> binary_to_list(B).

l2a(L) -> list_to_atom(L).

convert([{}]) ->
    convert([]);
convert(<<>>) ->
    convert([]);
convert(RawArgs) when is_list(RawArgs) ->
    convert(RawArgs, []).

convert([], Acc) ->
    maps:from_list(Acc);
convert([{K, V} | RestProps], Acc) ->
    convert(RestProps, [{b2a(K), V} | Acc]).

return(#{code := 0, data := Data}) ->
    [{<<"code">>, ?SUCCESS}, {<<"payload">>, Data}];
return(#{code := Code, data := Data}) when is_map(Data) ->
    [{<<"code">>, Code}, {<<"payload">>, maps:to_list(Data)}];
return(#{code := Code, data := Data}) ->
    [{<<"code">>, Code}, {<<"payload">>, Data}];
return(#{code := Code}) ->
    [{<<"code">>, Code}, {<<"payload">>, <<>>}];
return(_Map) ->
    [{<<"code">>, ?ERROR2}, {<<"payload">>, <<"Not found">>}].

restruct(Resp, Req) ->
    RspKeys = proplists:get_keys(Resp),
    Req1 = delete_by_keys(RspKeys, Req),
    lists:append(Req1, Resp).

delete_by_keys([], Req) ->
    Req;
delete_by_keys([Key | LeftKeys], Req) ->
    delete_by_keys(LeftKeys, delete(Key, Req)).

make_rsp_msg(Topic, Payload) ->
    #mqtt_msg{qos = 1,
              topic = Topic,
              payload = Payload}.
