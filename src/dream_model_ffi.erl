%% Helpers for the generator and the command: the SHA-256 hash of the
%% schema fingerprint, the command line, programs and the environment.
-module(dream_model_ffi).
-export([sha256_hex/1, arguments/0, run/3, get_env/1]).

%% The SHA-256 hash of a text, as 64 lowercase hexadecimal digits.
sha256_hex(Text) ->
    binary:encode_hex(crypto:hash(sha256, Text), lowercase).

%% The arguments after `gleam run -m dream_model --`.
arguments() ->
    [unicode:characters_to_binary(Argument) || Argument <- init:get_plain_arguments()].

%% Runs a program found on the PATH in a folder, and returns its exit status
%% and its output (standard output and standard error together).
run(Program, Arguments, Directory) ->
    case os:find_executable(unicode:characters_to_list(Program)) of
        false -> {error, nil};
        Path ->
            Port = open_port({spawn_executable, Path},
                             [{args, [unicode:characters_to_list(A) || A <- Arguments]},
                              {cd, unicode:characters_to_list(Directory)},
                              exit_status, binary, stderr_to_stdout, use_stdio, hide]),
            {ok, collect(Port, [])}
    end.

collect(Port, Output) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Output]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Output))}
    end.

get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
