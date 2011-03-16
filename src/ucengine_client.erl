%%% @author     Thierry Bomandouki <thierry.bomandouki@af83.com> [http://ucengine.org]
%%% @copyright  2011 af83
%%% @doc        U.C.Engine client
%%% @end
%%%
%%% This file is part of erlyvideo-ucengine.
%%%
%%% erlyvideo is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% erlyvideo is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with erlyvideo.  If not, see <http://www.gnu.org/licenses/>.
%%%
%%%---------------------------------------------------------------------------------------
-module(ucengine_client).
-author('thierry.bomandouki@af83.com').

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% API
-export([start_link/2, start_link/3,
         receive_events/5,
         connect/2, connect/3,
         subscribe/3, subscribe/4,
         publish/1,
         can/4, can/5,
         time/0]).

-include("include/ucengine.hrl").

-behaviour(gen_server).

%% Print every request and everything above.
-define(DEBUG, 0).
%% Print everything that seems fishy.
-define(WARNING, 1).
%% Print regular errors, usually HTTP errors.
-define(ERROR, 2).
%% Only print critical errors (bad hostname or port, etc).
-define(CRITICAL, 3).
%% Don't print anything (default).
-define(QUIET, 4).
%%
-define(AUTH_METHOD_TOKEN, "token").
-define(AUTH_METHOD_PASSWORD, "password").

-record(state, {host,
                port,
                debug = ?QUIET,
                uid,
                sid}).

start_link(Host, Port) ->
    start_link(Host, Port, ?QUIET).

start_link(Host, Port, Debug) ->
    ibrowse:start(),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Host, Port, Debug], []).

init([Host, Port, Debug]) ->
    {ok, #state{host=Host, port=Port, debug=Debug}}.

%% @desc: Connect to the UCEngine server with the User ID 'uid' and the its credential.
%% It is currently possible to use :token or :password as authentification method, default is :token
%% @param Uid string : brick id or name
%% @param Credential string : brick password or token
connect(Uid, Credential) ->
    connect(Uid, Credential, ?AUTH_METHOD_TOKEN).

connect(Uid, Credential, Method) ->
    gen_server:call(?MODULE, {connect, Uid, Credential, Method}).

%%
%% Subscribe to an event stream. The 'location' parameter is where you're expecting
%% the events to come:
%% * "meeting": events from a specific meeting.
%% * "": all events.
%%
%% The function takes extra parameters:
%% :type => the type of event (ex. 'chat.message.new', 'internal.user.add', etc).
%% :from => the origin of the message, the value is an uid.
%% :parent => the id of the the parent event.
%% :search => list of keywords that match the metadata of the returned events
%%
subscribe(Location, Type, Pid) ->
    subscribe(Location, Type, [], Pid).
subscribe(Location, Type, Params, Pid) ->
    gen_server:call(?MODULE, {subscribe, Location, Type, Params, Pid}).

%%
%% Publish event
%%
publish(#uce_event{} = Event) ->
    gen_server:call(?MODULE, {publish, Event}).

%%
%% check ACL
%%
can(Uid, Object, Action, Location) ->
    can(Uid, Object, Action, Location, []).
can(Uid, Object, Action, Location, Conditions) ->
    gen_server:call(?MODULE, {can, Uid, Object, Action, Location, Conditions}).

%%
%% get server time
%%
time() ->
    gen_server:call(?MODULE, {time}).

decode_event({_, Event}) ->
    case utils:get(Event,
                   [id, datetime, from, location, type, parent, metadata],
                   [none, none, none, <<"">>, none, <<"">>, {array, []}]) of
        {error, Reason} ->
            {error, Reason};
        [Id, Datetime, From, Location, Type, Parent, {_, Metadata}] ->
            #uce_event{id=binary_to_list(Id),
                       datetime=Datetime,
                       from=binary_to_list(From),
                       location=binary_to_list(Location),
                       type=binary_to_list(Type),
                       parent=binary_to_list(Parent),
                       metadata=[{binary_to_list(Key), binary_to_list(Value)} || {Key, Value} <- Metadata]}
    end.

receive_events(State, Location, Type, Params, Pid) ->
    %% We just want to flush mailbox
    %% ibrowse send message on timeout
    receive
        {_Pid, {error,req_timedout}} ->
            ok;
        Message ->
            io:format("event not recognized ~p", [Message])
        after
            0 ->
                ok
    end,

    Resp = http_get(State, "/event/" ++ Location,
                    Params ++ [{"uid", State#state.uid},
                               {"sid", State#state.sid},
                               {"type", Type},
                               {"_async", "lp"}]),
    NewParams = case Resp of
                    {ok, "200", _, Array} ->
                        io:format("jsonevent ~p", [Array]),
                        Events = [decode_event(JSonEvent) || JSonEvent <- Array],
                        case Events of
                            [] ->
                                Params;
                            _ ->
                                [ Pid ! {event, Event} || Event <- Events ],
                                LastEvent = lists:last(Events),
                                lists:keyreplace("start", 1, Params,
                                                 {"start", integer_to_list(LastEvent#uce_event.datetime + 1)})
                        end;
                    {error,req_timedout} ->
                        Params;
                    Error ->
                        io:format("Subscribe: error: ~p", [Error]),
                        timer:sleep(5000),
                        Params
                end,
    receive_events(State, Location, Type, NewParams, Pid).

handle_call({connect, Uid, Credential, Method}, _From, State) ->
    Resp = http_post(State, "/presence/", [{"uid", Uid},
                                           {"auth", Method},
                                           {"credential", Credential}]),
    case Resp of
        {ok, "201", _, Sid} ->
            {reply, {ok, binary_to_list(Sid)},
             State#state{uid = Uid, sid = binary_to_list(Sid)}};
        {ok, _, _, Error} ->
            {reply, {error, binary_to_list(Error)}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State};
        Error ->
            {reply, {error, Error}, State}
    end;

handle_call({subscribe, _Location, _Type, _Params, _Pid}, _From, #state{uid = Uid, sid = Sid} = State) when Uid == undefined;  Sid == undefined ->
    {reply, {error, not_connected}, State};

handle_call({subscribe, Location, Type, Params, Pid}, _From, State) ->
    ListenerPid = spawn_link(?MODULE, receive_events, [State, Location, Type, Params, Pid]),
    {reply, {ok, ListenerPid}, State};

handle_call({publish, #uce_event{}}, _From, #state{uid = Uid, sid = Sid} = State) when Uid == undefined;  Sid == undefined ->
    {reply, {error, not_connected}, State};

handle_call({publish, #uce_event{type = Type,
                                 to = To,
                                 metadata=Metadata} = Event}, _From, State) ->
    case http_post(State, "/event/" ++ Event#uce_event.location, [{"uid", State#state.uid},
                                                                  {"sid", State#state.sid},
                                                                  {"type", Type},
                                                                  {"to", To},
                                                                  {"metadata", Metadata}]) of
        {ok, "201", _, Id} ->
            {reply, {ok, binary_to_list(Id)}, State};
        {ok, _, _, Error} ->
            {reply, {error, binary_to_list(Error)}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State};
        Error ->
            {reply, {error, Error}, State}
    end;

handle_call({can, Uid, Object, Action, Location, Conditions}, _From, State) ->
    Resp = http_get(State, "/user/" ++ Uid ++ "/acl/" ++ Object ++ "/" ++ Action ++ "/" ++ Location,
                    [{"uid", State#state.uid},
                     {"sid", State#state.sid},
                     {"conditions", Conditions}]),
    case Resp of
        {ok, "200", _, Value} ->
            case Value of
                <<"true">> ->
                    {reply, true, State};
                _ ->
                    {reply, false, State}
            end;
        {ok, _, _, Error} ->
            {reply, {error, binary_to_list(Error)}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State};
        Error ->
            {reply, {error, Error}, State}
    end;

handle_call({time}, _From, State) ->
    case http_get(State, "/time", []) of
        {ok, "200", _, Time} ->
            {reply, Time, State};
        {error, Reason} ->
            {reply, {error, Reason}, State};
        Error ->
            {reply, {error, Error}, State}
    end.

handle_cast(_, State) ->
    {noreply, State}.

code_change(_,State,_) ->
    {ok, State}.

handle_info(_Info, State) ->
    {reply, State}.

terminate(_Reason, _State) ->
    ok.

%%
%% Private functions
%%

http_get(State, Path, Params) ->
    http_request(State, get, Path, Params).

http_post(State, Path, Params) ->
    http_request(State, post, Path, Params).

http_request(State, Method, Path, Params) ->
    Query = case Params of
                [] ->
                    "";
                _ ->
                    "?" ++ url_encode(Params)
            end,
    Addr = "http://" ++ State#state.host ++ ":" ++ integer_to_list(State#state.port),
    process_response(catch ibrowse:send_req(Addr ++ "/api/" ++ ?UCE_API_VERSION ++ Path ++ Query, [], Method, [])).

process_response({ok, Status, Headers, JSONString}) ->
    {struct,[{<<"result">>, Json}]} = mochijson2:decode(JSONString),
    {ok, Status, Headers, Json};
process_response(R) ->
    R.

url_encode(RawParams) ->
    Params =
        lists:map(fun({Key, Value}) ->
                          if
                              Key == "metadata" ; Key == "conditions" ->
                                  ArrayParams =
                                      lists:map(fun({Name, Data}) ->
                                                        ibrowse_lib:url_encode(Key ++ "[" ++ Name ++ "]") ++ "=" ++
                                                            ibrowse_lib:url_encode(Data)
                                                end,
                                                Value),
                                  string:join(ArrayParams, "&");
                              true ->
                                  ibrowse_lib:url_encode(Key) ++ "=" ++
                                      ibrowse_lib:url_encode(Value)
                          end
                  end,
                  RawParams),
    string:join(Params, "&").

%%
%% Tests
%%
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-endif.
