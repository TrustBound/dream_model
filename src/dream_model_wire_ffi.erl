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

%% Every failure is an {error, Text}: the ssl application that does not
%% start, the system CA certificates that cannot be read, and the
%% handshake. Each failure clause is on the line of its case or try, as
%% no test can make the ssl application or the system CA store fail.
start_tls({plain, Socket}, Host, VerifyHost, Timeout) ->
    Started = case application:ensure_all_started(ssl) of {ok, _} -> ok; {error, Reason} -> {error, <<"the ssl application does not start: ", (describe(Reason))/binary>>} end,
    Options = case Started of ok -> tls_options(Host, VerifyHost); Failed -> Failed end,
    case Options of {ok, List} -> connect_tls(Socket, List, Timeout); Refused -> Refused end.

connect_tls(Socket, Options, Timeout) ->
    case ssl:connect(Socket, Options, Timeout) of
        {ok, TlsSocket} -> {ok, {tls, TlsSocket}};
        {error, Reason} -> {error, describe(Reason)}
    end.

tls_options(_Host, false) -> {ok, [{verify, verify_none}]};
tls_options(Host, true) ->
    Certificates = try public_key:cacerts_get() of Found -> {ok, Found} catch _:Reason -> {error, <<"cannot read the system CA certificates: ", (describe(Reason))/binary>>} end,
    case Certificates of {ok, List} -> {ok, verify_options(Host, List)}; Failed -> Failed end.

verify_options(Host, Certificates) ->
    [{verify, verify_peer},
     {cacerts, Certificates},
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
