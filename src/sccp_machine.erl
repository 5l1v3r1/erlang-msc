-module(sccp_machine).
-author('Duncan Smith <Duncan@xrtc.net>').
-include_lib("osmo_ss7/include/osmo_ss7.hrl").
-include_lib("emsc/include/ipaccess.hrl").
-include_lib("osmo_ss7/include/sccp.hrl").
-include_lib("emsc/include/sccp.hrl").

-export([boot_link/1]).

-export([sccp_loop/1]).

boot_link(Socket) ->
    Looper = spawn(fun () -> sccp_loop(Socket) end),
    Looper ! {Socket},
    register(sccp_loop, Looper),
    ipa_proto:register_stream(Socket, ?IPAC_PROTO_SCCP, {callback_fn, fun rx_message/4, []}),
    io:format("Sending hello~n", []),
    ipa_proto:send(Socket, 254, << 6 >>),
    ok.

rx_message(_Socket, Port, Data, []) ->
    Looper = whereis(sccp_loop),
    {ok, Msg} = sccp_codec:parse_sccp_msg(Data),
    Looper ! Msg.

sccp_loop(Socket) ->
    receive
	{sccp_msg, Type, Params} ->
	    % Find a receiver for this message.  Messages without a
	    % destination local reference that is in the table
	    % (e.g. messages from dead connections, connectionless
	    % messages) won't have one and so Controller will be
	    % undefined.  sccp_receive_dispatch should only throw
	    % errors in case of this being a genuine problem.
	    Class = proplists:get_value(protocol_class, Params),
	    LocalRef = proplists:get_value(dst_local_ref, Params),
	    RemoteRef = proplists:get_value(src_local_ref, Params),
	    Controller = get({sccp_local_ref, LocalRef}),
	    try sccp_receive_dispatch(Type, Class, Params, Controller)
	    catch
		X:Y ->
		    io:format("XXXX====XXXX Catching ~p (~p:~p)~n", [Type, X, Y]),
		    case LocalRef of
			% connection-oriented messages always have a
			% destination reference, but may not have a
			% protocol class element (wtf).
			undefined -> ok; % discard erroneous connectionless message
			_ when is_integer(LocalRef), is_integer(RemoteRef) ->
				% not sure if this is technically the
				% right cause code, but it'll do.
			    self() ! {sccp_released,
				      LocalRef,
				      RemoteRef,
				      ?SCCP_CAUSE_REL_SCCP_FAILURE};
			_ -> ok
			    % discard connectionful messages that
			    % don't have enough information to write
			    % into a RELEASED message.
		    end
	    end;
	{sccp_message, LocalRef, RemoteRef, Msg} ->
	    % send out a message
	    ipa_proto:send(Socket, ?IPAC_PROTO_SCCP, sccp_codec:encode_sccp_msg(Msg));
	{sccp_connect_confirm, LocalRef, RemoteRef} ->
	    % Connection confirm from MSC direction

	    Msg = {sccp_msg, ?SCCP_MSGT_CC, [{dst_local_ref, RemoteRef},
					     {src_local_ref, LocalRef},
					     {protocol_class, {2,0}}]},
	    ipa_proto:send(Socket, ?IPAC_PROTO_SCCP, sccp_codec:encode_sccp_msg(Msg));
	{sccp_released, LocalRef, RemoteRef, Cause} ->
	    % Release from MSC direction
	    Msg = {sccp_msg, ?SCCP_MSGT_RLSD, [{src_local_ref, LocalRef},
					       {dst_local_ref, RemoteRef},
					       {release_cause, Cause}]},
	    io:format("Sccp releasing ref=~p/~p: ~p~n", [LocalRef, RemoteRef, Msg]),
	    ipa_proto:send(Socket, ?IPAC_PROTO_SCCP, sccp_codec:encode_sccp_msg(Msg));
	{sccp_release_compl, LocalRef, RemoteRef} ->
	    % Release from BSS direction
	    io:format("Sccp release complete ref=~p/~p~n", [LocalRef, RemoteRef]),
	    Msg = {sccp_msg, ?SCCP_MSGT_RLC, [{src_local_ref, LocalRef},
					      {dst_local_ref, RemoteRef}]},
	    erase({sccp_local_ref, LocalRef}),
	    ipa_proto:send(Socket, ?IPAC_PROTO_SCCP, sccp_codec:encode_sccp_msg(Msg));
	{sccp_ping, To, From} ->
	    io:format("Sccp ref=~p/~p Sending ping~n", [From, To]),
	    Msg = {sccp_msg, ?SCCP_MSGT_IT, [{dst_local_ref, To},
					     {src_local_ref, From},
					     {protocol_class, {2,0}},
					     {seq_segm, 0},
					     {credit, 0}]},
	    ipa_proto:send(Socket, ?IPAC_PROTO_SCCP, sccp_codec:encode_sccp_msg(Msg));
	{killed, LocalRef} ->
	    % one of my workers has killed himself
	    io:format("Removing entry ~p from local worker table~n", [LocalRef]),
	    erase({sccp_local_ref, LocalRef})

%	{sccp_msg, ?SCCP_MSG_
    end,
    sccp_machine:sccp_loop(Socket).


    % Connection request from BSS direction
sccp_receive_dispatch(?SCCP_MSGT_CR, {2,0}, Params, _) ->
    RemoteRef = proplists:get_value(src_local_ref, Params),
    Self = self(),
    LocalRef = get_cur_local_ref(),
    Controller = spawn(fun () -> sccp_socket_loop(incoming, LocalRef, Self) end),
    put({sccp_local_ref, LocalRef}, Controller),
    UserData = proplists:get_value(user_data, Params),
    Controller ! {sccp_connect_request, LocalRef, RemoteRef, UserData};

    % Connection confirm from BSS direction
sccp_receive_dispatch(?SCCP_MSGT_CC, {2,0}, Params, Controller) ->
    RemoteRef = proplists:get_value(src_local_ref, Params),
    LocalRef = proplists:get_value(dst_local_ref, Params),
    io:format("Connect confirm ~p~n", [RemoteRef]),
    Controller ! {sccp_connect_confirm, LocalRef, RemoteRef, proplists:get_value(user_data, Params)};

    % First phase of disconnect
sccp_receive_dispatch(?SCCP_MSGT_RLSD, _, Params, Controller) ->
    RemoteRef = proplists:get_value(src_local_ref, Params),
    LocalRef = proplists:get_value(dst_local_ref, Params),
    Msg = proplists:get_value(user_data, Params),
    Cause = proplists:get_value(release_cause, Params),
    io:format("Sccp releasing ref=~p/~p~n", [LocalRef, RemoteRef]),
    Controller ! {sccp_message, LocalRef, RemoteRef, Msg},
    Controller ! {sccp_released, LocalRef, RemoteRef, Cause};

    % Second and final phase of disconnect
sccp_receive_dispatch(?SCCP_MSGT_RLC, _, Params, Controller) ->
    RemoteRef = proplists:get_value(src_local_ref, Params),
    LocalRef = proplists:get_value(dst_local_ref, Params),
    Controller ! {sccp_release_compl, LocalRef, RemoteRef};

    % Connection-oriented dataframe type 1 from BSS direction
sccp_receive_dispatch(?SCCP_MSGT_DT1, _, Params, Controller) ->
    LocalRef = proplists:get_value(dst_local_ref, Params),
    MsgBin = proplists:get_value(user_data, Params),
    io:format("Sccp ref=~p/~p DT1=~p~n", [LocalRef, undefined, MsgBin]),
    Controller ! {sccp_message, LocalRef, undefined, MsgBin};

sccp_receive_dispatch(?SCCP_MSGT_UDT, {0,0}, Params, _) ->
    ok;

    % "Ping?"
sccp_receive_dispatch(?SCCP_MSGT_IT, {2,0}, Params, Controller) ->
    RemoteRef = proplists:get_value(src_local_ref, Params),
    LocalRef = proplists:get_value(dst_local_ref, Params),
    Controller ! {sccp_ping, LocalRef, RemoteRef};

% *UDTS messages are error responses.  This code is perfect and never
% generates erroneous messages.  Also, it's not interested in hearing
% about how much it sucks, so it sets the "don't tell me about errors"
% flag.  Thus, I don't even bother to parse *UDTS messages

    % Extended unitdata
sccp_receive_dispatch(?SCCP_MSGT_XUDT, {2,0}, Params, Controller) ->
    From = proplists:get_value(src_local_ref, Params),
    To = proplists:get_value(dst_local_ref, Params),
    MsgBin = proplists:get_value(user_data, Params),
    Controller ! {sccp_message, To, From, MsgBin};

    % Long unitdata
sccp_receive_dispatch(?SCCP_MSGT_LUDT, {2,0}, Params, Controller) ->
    From = proplists:get_value(src_local_ref, Params),
    To = proplists:get_value(dst_local_ref, Params),
    MsgBin = proplists:get_value(user_data, Params),
    Controller ! {sccp_message, To, From, MsgBin};

    % unknown messages are discarded (GSM 08.06 section 5.3, paragraph regarding Q.712 subclause 1.10)
sccp_receive_dispatch(Type, Class, Params, _Controller) ->
    io:format("Unknown message type ~p (~p)~n -->~p~n", [Type, Class, Params]),
    ok.


get_cur_local_ref() ->
    case get(local_ref_max) of
	undefined ->
	    put(local_ref_max, 0),
	    get_cur_local_ref();
	_ ->
	    Ref = get(local_ref_max),
	    put(local_ref_max, Ref + 1),
	    Ref
    end.

% Loop process to handle an SCCP connection.
%
% Downlink is the pid of the process that we use to send messages
% outbound.
sccp_socket_loop(incoming, LocalRef, Downlink) ->
    receive
	{sccp_connect_request, LocalRef, RemoteRef, Msg} ->
	    io:format("Sccp ref=~p/~p: accepting~n", [LocalRef, RemoteRef]),
	    self() ! {sccp_message, LocalRef, RemoteRef, Msg},
	    sccp_socket_loop(incoming, LocalRef, RemoteRef, Downlink);
	{_, LocalRef, RemoteRef} ->
	    io:format("Sccp ref=~p/~p: NOPE~n", [LocalRef, RemoteRef]),
	    Downlink ! {sccp_released, LocalRef, RemoteRef, ?SCCP_CAUSE_REL_INCONS_CONN_DAT}
    end.

% Choose or spawn an uplink process, then continue with the
% connection.
sccp_socket_loop(incoming, LocalRef, RemoteRef, Downlink) ->
    Downlink ! {sccp_connect_confirm, LocalRef, RemoteRef},
    Uplink = spawn(fun datagram_print_loop/0), % provisional
    io:format("Sccp ref=~p/~p: accepting from ~p into ~p~n", [LocalRef, RemoteRef, Downlink, Uplink]),
    sccp_socket_loop(established, LocalRef, RemoteRef, Downlink, Uplink).

sccp_socket_loop(outgoing, LocalRef, RemoteRef, Downlink, Uplink) ->
    receive
	{sccp_connect_confirm, LocalRef, _RemoteRef, Msg} ->
	    io:format("Sccp ref=~p: Confirmed~n", [LocalRef]),
	    Userdata = proplists:get_value(user_data, Msg),
	    if
		% if there's userdata, loop it back in so I can process it later
		is_binary(Userdata) ->
		    io:format("Looping in userdata ~p~n", [Msg]),
		    self() ! {sccp_message, LocalRef, RemoteRef, Msg}
	    end,
	    sccp_socket_loop(established, LocalRef, RemoteRef, Downlink, Uplink);
	Msg ->
	    io:format("Sccp ref=~p/~p: Failure to confirm (~p), killing~n", [LocalRef, RemoteRef, Msg]),
	    Downlink ! {sccp_released, LocalRef, RemoteRef, ?SCCP_CAUSE_REL_SCCP_FAILURE}
    after 10000 -> % provisional
	    io:format("Sccp ref=~p/~p: stale, killing myself/5~n", [LocalRef, RemoteRef]),
	    self() ! {kill}
    end;
sccp_socket_loop(established, LocalRef, RemoteRef, Downlink, Uplink) ->
    receive
	{sccp_message, LocalRef, _, Msg} ->
	    io:format("Sccp ref=~p/~p: Got a message~n", [LocalRef, RemoteRef]),
	    Uplink ! {sccp_message_in, Msg},
	    sccp_socket_loop(established, LocalRef, RemoteRef, Downlink, Uplink);
	{sccp_message, _, LocalRef, Msg} ->
	    io:format("Sccp ref=~p/~p: Sending a message~n", [LocalRef, RemoteRef]),
	    Downlink ! {sccp_message_out, LocalRef, RemoteRef, Msg}, % not sure about the tuple member order
	    sccp_socket_loop(established, LocalRef, RemoteRef, Downlink, Uplink);
	{sccp_ping, LocalRef, RemoteRef} ->
	    Downlink ! {sccp_ping, RemoteRef, LocalRef},
	    sccp_socket_loop(established, LocalRef, RemoteRef, Downlink, Uplink);
	{sccp_released, LocalRef, RemoteRef, Cause} ->
	    Downlink ! {sccp_release_compl, LocalRef, RemoteRef},
	    self() ! {kill},
	    sccp_socket_loop(established, LocalRef, RemoteRef, Downlink, Uplink);
	{sccp_release_compl, LocalRef, RemoteRef} ->
	    self() ! {kill},
	    sccp_socket_loop(established, LocalRef, RemoteRef, Downlink, Uplink);
	{kill} ->
% by GSM 08.06 sec 6.2, this can only be initiated by the MSC/network side.
	    io:format("Sccp ref=~p/~p: Killing myself~n", [LocalRef, RemoteRef]),
	    Downlink ! {killed, LocalRef};
	Msg ->
	    io:format("Sccp ref=~p/~p: Unknown message:~n --> ~p~n", [LocalRef, RemoteRef, Msg]),
	    sccp_socket_loop(established, LocalRef, RemoteRef, Downlink, Uplink)
    after 10000 -> % provisional
	    io:format("Sccp ref=~p/~p: stale, killing myself/6~n", [LocalRef, RemoteRef]),
	    self() ! {kill},
	    sccp_socket_loop(established, LocalRef, RemoteRef, Downlink, Uplink)
    end.


datagram_print_loop() ->
    io:format("Getting new packet ...~n"),
    receive
	{sccp_message_in, Msg} ->
	    io:format("Got message ~w~n", [Msg]),
	    datagram_print_loop()
    end.

