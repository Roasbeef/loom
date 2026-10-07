%% Bounded test-only access to the final opaque Door and Remote tuple shapes.
%% Door = {door, {subject, OriginalPid, OriginalReference}} and
%% Remote = {bytes, OriginalSenderPid, CanonicalPacketBytes}. These fixed probes
%% inject into fixture-owned actors only; no production code imports this module.
-module(executor_launch_beam_probe).
-export([inject/3, foreign_sender/2, closed/1, recv_exact/3, original_reader_monitor/1, reader_down/2]).

inject({door, {subject, Destination, Tag}},
       {door, {subject, OriginalSender, SenderTag}}, Bytes)
  when is_pid(Destination), is_reference(Tag), is_pid(OriginalSender),
       is_reference(SenderTag), is_binary(Bytes), byte_size(Bytes) =< 262180 ->
    send_packet(Destination, Tag, OriginalSender, Bytes);
inject(_, _, _) -> {error, nil}.

foreign_sender({door, {subject, Destination, Tag}}, Bytes)
  when is_pid(Destination), is_reference(Tag), is_binary(Bytes),
       byte_size(Bytes) =< 262180 ->
    send_packet(Destination, Tag, self(), Bytes);
foreign_sender(_, _) -> {error, nil}.

send_packet(Destination, Tag, Sender, Bytes) ->
    case erlang:send(Destination, {Tag, {bytes, Sender, Bytes}},
                     [nosuspend, noconnect]) of
        ok -> {ok, nil};
        _ -> {error, nil}
    end.

%% The checked original actor must have received its actual result before this
%% witness succeeds. DOWN, socket EOF and historical records cannot satisfy it.
closed(Pid) when is_pid(Pid), node(Pid) =:= node() ->
    try sys:get_state(Pid, 1000) of
        {closed, _} -> true;
        _ -> false
    catch _:_ -> false end;
closed(_) -> false.


%% The fixture's exact maximum frame read is bounded independently of peer bytes.
recv_exact(Socket,Length,Timeout) when is_integer(Length),Length>0,Length=<16777220,
    is_integer(Timeout),Timeout>0,Timeout=<5000 ->
    case gen_tcp:recv(Socket,Length,Timeout) of
        {ok,Bytes} -> {ok,Bytes};
        {error,_} -> {error,nil}
    end;
recv_exact(_,_,_) -> {error,nil}.

%% This fixture-only witness depends on the checked local records:
%% bridge Owned.source is field13, Connection.close field5 captures one commands
%% Subject, and channel Owned.reader is field16. No closure or endpoint leaves
%% this executor node; only the original reader monitor is returned to the test.
original_reader_monitor({door,{subject,Bridge,_}}) when node(Bridge)=:=node() ->
    try
        {_,Owned}=sys:get_state(Bridge,1000),
        true=tuple_size(Owned)=:=29,
        {some,Connection}=element(14,Owned),
        {connection,_,_,_,_,Close}=Connection,
        {env,[{subject,Channel,_}]}=erlang:fun_info(Close,env),
        {_,ChannelOwned}=sys:get_state(Channel,1000),
        true=tuple_size(ChannelOwned)=:=26,
        {some,{subject,Reader,_}}=element(17,ChannelOwned),
        {ok,{Reader,erlang:monitor(process,Reader)}}
    catch _:_ -> {error,nil} end;
original_reader_monitor(_) -> {error,nil}.

%% Only this exact original reader's normal exit proves Final termination.
reader_down({Reader,Ref},Timeout) when is_pid(Reader),is_reference(Ref),
    is_integer(Timeout),Timeout>0,Timeout=<2000 ->
    receive {'DOWN',Ref,process,Reader,normal} -> {ok,nil};
            {'DOWN',Ref,process,Reader,_} -> {error,nil}
    after Timeout -> {error,nil} end;
reader_down(_,_) -> {error,nil}.
