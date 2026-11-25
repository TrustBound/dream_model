%% Helpers for the tests: environment variables, command-line arguments,
%% JSON decoding, the clock, and a fake PostgreSQL server that follows a
%% script, for the protocol cases that a real server never sends.
-module(dream_model_test_ffi).
-export([get_env/1, get_arguments/0, decode_json/1, monotonic_milliseconds/0,
         start_fake_server/1]).

get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Returns the command-line arguments after `--`.
get_arguments() ->
    [unicode:characters_to_binary(Argument) || Argument <- init:get_plain_arguments()].

%% Decodes JSON text with the json module of Erlang/OTP 27 and newer.
decode_json(Text) ->
    try json:decode(Text) of
        Value -> {ok, Value}
    catch
        _:_ -> {error, nil}
    end.

monotonic_milliseconds() ->
    erlang:monotonic_time(millisecond).

%% Starts a server on a free local port that accepts one connection for
%% each script and runs the script on it. Returns the port.
%%
%% Steps:
%%   {send, Bytes}             send bytes
%%   receive_startup           read the startup message
%%   receive_message           read one typed message
%%   {expect_message, Bytes}   read one typed message; close when it differs
%%   accept_tls                read the SSLRequest, answer S, do the handshake
%%   {answer_ssl_request, B}   read the SSLRequest, answer with byte B
%%   {scram_server_first, Salt, Iterations}
%%                             read the SASLInitialResponse and send a
%%                             server-first message with the client nonce
%%   close                     close the connection
start_fake_server(Scripts) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {packet, raw},
                                      {ip, {127, 0, 0, 1}}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Pid = spawn(fun() ->
        receive go -> ok end,
        accept_all(Listen, Scripts),
        gen_tcp:close(Listen)
    end),
    ok = gen_tcp:controlling_process(Listen, Pid),
    Pid ! go,
    Port.

accept_all(_Listen, []) -> ok;
accept_all(Listen, [Steps | Rest]) ->
    case gen_tcp:accept(Listen, 10000) of
        {ok, Socket} ->
            Runner = spawn(fun() -> receive go -> run({plain, Socket}, Steps) end end),
            ok = gen_tcp:controlling_process(Socket, Runner),
            Runner ! go,
            accept_all(Listen, Rest);
        {error, _} -> ok
    end.

run(Socket, []) -> wait_for_close(Socket);
run(Socket, [Step | Rest]) ->
    case step(Socket, Step) of
        {ok, Next} -> run(Next, Rest);
        stop -> close(Socket)
    end.

wait_for_close(Socket) ->
    case recv(Socket, 0, 5000) of
        {ok, _} -> wait_for_close(Socket);
        _ -> close(Socket)
    end.

step(Socket, {send, Bytes}) -> ok = send(Socket, Bytes), {ok, Socket};
step(Socket, receive_startup) ->
    {ok, <<Length:32>>} = recv(Socket, 4, 5000),
    {ok, _} = recv(Socket, Length - 4, 5000),
    {ok, Socket};
step(Socket, receive_message) -> {_, _} = read_message(Socket), {ok, Socket};
step(Socket, {expect_message, Bytes}) ->
    {Kind, Body} = read_message(Socket),
    Length = byte_size(Body) + 4,
    case <<Kind, Length:32, Body/binary>> of
        Bytes -> {ok, Socket};
        _ -> stop
    end;
step({plain, Raw} = Socket, accept_tls) ->
    {ok, <<8:32, 80877103:32>>} = recv(Socket, 8, 5000),
    ok = send(Socket, <<"S">>),
    {ok, _} = application:ensure_all_started(ssl),
    case ssl:handshake(Raw, tls_options(), 10000) of
        {ok, Tls} -> {ok, {tls, Tls}};
        {error, _} -> stop
    end;
step(Socket, {answer_ssl_request, Byte}) ->
    {ok, <<8:32, 80877103:32>>} = recv(Socket, 8, 5000),
    ok = send(Socket, <<Byte>>),
    {ok, Socket};
step(Socket, {scram_server_first, Salt, Iterations}) ->
    {$p, Body} = read_message(Socket),
    [<<"SCRAM-SHA-256">>, <<_:32, First/binary>>] = binary:split(Body, <<0>>),
    [_, Nonce] = binary:split(First, <<",r=">>),
    Message = iolist_to_binary(["r=", Nonce, "server,s=", base64:encode(Salt),
                                ",i=", integer_to_binary(Iterations)]),
    ok = send(Socket, <<$R, (byte_size(Message) + 8):32, 11:32, Message/binary>>),
    {ok, Socket};
step(Socket, close) -> close(Socket), stop.

read_message(Socket) ->
    {ok, <<Kind, Length:32>>} = recv(Socket, 5, 5000),
    {Kind, read_body(Socket, Length - 4)}.

read_body(_Socket, 0) -> <<>>;
read_body(Socket, Length) ->
    {ok, Body} = recv(Socket, Length, 5000),
    Body.

tls_options() ->
    Key = {rsa, 2048, 65537},
    #{server_config := Server} = public_key:pkix_test_data(
        #{server_chain => #{root => [{key, Key}], peer => [{key, Key}]},
          client_chain => #{root => [{key, Key}], peer => [{key, Key}]}}),
    Server.

send({plain, Socket}, Bytes) -> gen_tcp:send(Socket, Bytes);
send({tls, Socket}, Bytes) -> ssl:send(Socket, Bytes).

recv({plain, Socket}, Length, Timeout) -> gen_tcp:recv(Socket, Length, Timeout);
recv({tls, Socket}, Length, Timeout) -> ssl:recv(Socket, Length, Timeout).

close({plain, Socket}) -> gen_tcp:close(Socket);
close({tls, Socket}) -> ssl:close(Socket).
