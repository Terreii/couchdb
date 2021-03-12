-module(couch_prometheus_http).

-compile(tuple_calls).

-export([
    start_link/0,
    handle_request/1
]).

-include("couch_prometheus.hrl").

start_link() ->
    IP = case config:get("prometheus", "bind_address", "any") of
        "any" -> any;
        Else -> Else
    end,
    Port = config:get("prometheus", "port"),
    ok = couch_httpd:validate_bind_address(IP),

    Options = [
        {name, ?MODULE},
        {loop, fun ?MODULE:handle_request/1},
        {ip, IP},
        {port, Port}
    ],
    case mochiweb_http:start(Options) of
        {ok, Pid} ->
            {ok, Pid};
        {error, Reason} ->
            io:format("Failure to start Mochiweb: ~s~n", [Reason]),
            {error, Reason}
    end.

handle_request(MochiReq) ->
    RawUri = MochiReq:get(raw_path),
    {"/" ++ Path, _, _} = mochiweb_util:urlsplit_path(RawUri),
    PathParts =  string:tokens(Path, "/"),    try
        case PathParts of
            ["_node", Node, "_prometheus"] ->
                send_prometheus(MochiReq, Node);
            _ ->
                send_resp(MochiReq, 404, [], <<>>)
        end
    catch T:R ->
        Body = io_lib:format("~p:~p", [T, R]),
        send_resp(MochiReq, 500, [], Body)
    end.

send_prometheus(MochiReq, Node) ->
    Headers = couch_httpd:server_header() ++ [
        {<<"Content-Type">>, <<"text/plain">>}
    ],
    Body = call_node(Node, couch_prometheus_server, scrape, []),
    send_resp(MochiReq, 200, Headers, Body).

send_resp(MochiReq, Status, ExtraHeaders, Body) ->
    Headers = couch_httpd:server_header() ++ ExtraHeaders,
    MochiReq:respond({Status, Headers, Body}).


call_node("_local", Mod, Fun, Args) ->
    call_node(node(), Mod, Fun, Args);
call_node(Node0, Mod, Fun, Args) when is_list(Node0) ->
    Node1 = try
        list_to_existing_atom(Node0)
    catch
        error:badarg ->
            NoNode = list_to_binary(Node0),
            throw({not_found, <<"no such node: ", NoNode/binary>>})
        end,
    call_node(Node1, Mod, Fun, Args);
call_node(Node, Mod, Fun, Args) when is_atom(Node) ->
    case rpc:call(Node, Mod, Fun, Args) of
        {badrpc, nodedown} ->
            Reason = list_to_binary(io_lib:format("~s is down", [Node])),
            throw({error, {nodedown, Reason}});
        Else ->
            Else
    end.
