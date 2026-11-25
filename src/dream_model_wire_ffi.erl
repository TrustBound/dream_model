%% Socket and byte helpers for dream_model/postgres/wire.
%%
%% A socket is {plain, GenTcpSocket} or {tls, SslSocket}, so the Gleam code
%% sends and receives the same way before and after the TLS upgrade.
-module(dream_model_wire_ffi).
-export([connect/3, send/2, receive_exactly/3, start_tls/4, close/1, split_at_zero/1]).

connect(Host, Port, Timeout) ->
    Options = [binary, {active, false}, {packet, raw}, {nodelay, true}],
    case gen_tcp:connect(unicode:characters_to_list(Host), Port, Options, Timeout) of
        {ok, Socket} -> {ok, {plain, Socket}};
        {error, Reason} -> {error, describe(Reason)}
    end.

send({plain, Socket}, Data) -> result(gen_tcp:send(Socket, Data));
send({tls, Socket}, Data) -> result(ssl:send(Socket, Data)).

receive_exactly(_Socket, 0, _Timeout) -> {ok, <<>>};
receive_exactly({plain, Socket}, Length, Timeout) -> result(gen_tcp:recv(Socket, Length, Timeout));
receive_exactly({tls, Socket}, Length, Timeout) -> result(ssl:recv(Socket, Length, Timeout)).

start_tls({plain, Socket}, Host, VerifyHost, Timeout) ->
    {ok, _} = application:ensure_all_started(ssl),
    case ssl:connect(Socket, tls_options(Host, VerifyHost), Timeout) of
        {ok, TlsSocket} -> {ok, {tls, TlsSocket}};
        {error, Reason} -> {error, describe(Reason)}
    end.

tls_options(_Host, false) -> [{verify, verify_none}];
tls_options(Host, true) ->
    [{verify, verify_peer},
     {cacerts, public_key:cacerts_get()},
     {server_name_indication, unicode:characters_to_list(Host)},
     {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

close({plain, Socket}) -> gen_tcp:close(Socket), nil;
close({tls, Socket}) -> ssl:close(Socket), nil.

split_at_zero(Bytes) ->
    case binary:split(Bytes, <<0>>) of
        [Before, After] -> {ok, {Before, After}};
        [_] -> {error, nil}
    end.

result(ok) -> {ok, nil};
result({ok, Value}) -> {ok, Value};
result({error, Reason}) -> {error, describe(Reason)}.

describe(Reason) -> unicode:characters_to_binary(io_lib:format("~p", [Reason])).
