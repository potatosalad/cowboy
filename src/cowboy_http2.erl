%% Copyright (c) 2015-2017, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(cowboy_http2).

-export([init/5]).
-export([init/7]).
-export([init/9]).

-export([system_continue/3]).
-export([system_terminate/4]).
-export([system_code_change/4]).

-record(stream, {
	id = undefined :: cowboy_stream:streamid(),
	%% Stream handlers and their state.
	state = undefined :: {module(), any()},
	%% Whether we finished sending data.
	local = idle :: idle | cowboy_stream:fin(),
	%% Whether we finished receiving data.
	remote = nofin :: cowboy_stream:fin(),
	%% Request body length.
	body_length = 0 :: non_neg_integer()
}).

-type stream() :: #stream{}.

%% @todo priority: if we receive a message for a stream, do a selective receive
%% to get all messages in the mailbox and prioritize them. (later)

-record(state, {
	parent = undefined :: pid(),
	ref :: ranch:ref(),
	socket = undefined :: inet:socket(),
	transport :: module(),
	opts = #{} :: map(),

	%% Remote address and port for the connection.
	peer = undefined :: {inet:ip_address(), inet:port_number()},

	%% Settings are separate for each endpoint. In addition, settings
	%% must be acknowledged before they can be expected to be applied.
	%%
	%% @todo Since the ack is required, we must timeout if we don't receive it.
	%% @todo I haven't put as much thought as I should have on this,
	%% the final settings handling will be very different.
	local_settings = #{} :: map(),
	next_settings = [] :: [{reference(), map()}],
	%% @todo We need a TimerRef to do SETTINGS_TIMEOUT errors.
	%% We need to be careful there. It's well possible that we send
	%% two SETTINGS frames before we receive a SETTINGS ack.
	% next_settings = #{} :: undefined | map(), %% @todo perhaps set to undefined by default
	remote_settings = #{} :: map(),

	%% Stream identifiers.
	server_streamid = 2 :: pos_integer(),
	%% @todo last known good streamid

	%% Currently active HTTP/2 streams. Streams may be initiated either
	%% by the client or by the server through PUSH_PROMISE frames.
	streams = [] :: [stream()],

	%% Streams can spawn zero or more children which are then managed
	%% by this module if operating as a supervisor.
	children = [] :: [{pid(), cowboy_stream:streamid()}],

	%% The client starts by sending a sequence of bytes as a preface,
	%% followed by a potentially empty SETTINGS frame. Then the connection
	%% is established and continues normally. An exception is when a HEADERS
	%% frame is sent followed by CONTINUATION frames: no other frame can be
	%% sent in between.
	parse_needs = 9 :: pos_integer(),
	parse_state = undefined :: {preface, sequence, reference()}
		| {preface, settings, reference()}
		| normal
		| {continuation, cowboy_stream:streamid(), cowboy_stream:fin(), binary()},

	%% HPACK decoding and encoding state.
	decode_state = cow_hpack:init() :: cow_hpack:state(),
	encode_state = cow_hpack:init() :: cow_hpack:state()
}).

-spec init(pid(), ranch:ref(), inet:socket(), module(), cowboy:opts()) -> ok.
init(Parent, Ref, Socket, Transport, Opts) ->
	io:format("init/5 ~p~n", [{Parent, Ref, Socket, Transport, Opts}]),
	case Transport:peername(Socket) of
		{ok, Peer} ->
			init(Parent, Ref, Socket, Transport, Opts, Peer, <<>>);
		{error, Reason} ->
			%% Couldn't read the peer address; connection is gone.
			terminate(undefined, {socket_error, Reason, 'An error has occurred on the socket.'})
	end.

-spec init(pid(), ranch:ref(), inet:socket(), module(), cowboy:opts(),
	{inet:ip_address(), inet:port_number()}, binary()) -> ok.
init(Parent, Ref, Socket, Transport, Opts, Peer, Buffer) ->
	io:format("init/7 ~p~n", [{Parent, Ref, Socket, Transport, Opts, Peer, Buffer}]),
	State0 = #state{parent=Parent, ref=Ref, socket=Socket,
		transport=Transport, opts=Opts, peer=Peer,
		parse_state={preface, sequence, preface_timeout(Opts)}},
	State = preface(State0),
	case Buffer of
		<<>> -> before_loop(State, Buffer);
		_ -> parse(State, Buffer)
	end.

%% @todo Add an argument for the request body.
-spec init(pid(), ranch:ref(), inet:socket(), module(), cowboy:opts(),
	{inet:ip_address(), inet:port_number()}, binary(), map() | undefined, cowboy_req:req()) -> ok.
init(Parent, Ref, Socket, Transport, Opts, Peer, Buffer, _Settings, Req) ->
	io:format("init/9 ~p~n", [{Parent, Ref, Socket, Transport, Opts, Peer, Buffer, _Settings, Req}]),
	State0 = #state{parent=Parent, ref=Ref, socket=Socket,
		transport=Transport, opts=Opts, peer=Peer,
		parse_state={preface, sequence, preface_timeout(Opts)}},
	State1 = preface(State0),
	%% @todo Apply settings.
	%% StreamID from HTTP/1.1 Upgrade requests is always 1.
	%% The stream is always in the half-closed (remote) state.
	State = stream_handler_init(State1, 1, fin, Req),
	case Buffer of
		<<>> -> before_loop(State, Buffer);
		_ -> parse(State, Buffer)
	end.

preface(State=#state{opts=Opts, next_settings=[]}) ->
	Settings = maps:get(http2_settings, Opts, #{}),
	settings(State, Settings).

preface_timeout(Opts) ->
	PrefaceTimeout = maps:get(preface_timeout, Opts, 5000),
	erlang:start_timer(PrefaceTimeout, self(), preface_timeout).

settings(State=#state{socket=Socket, transport=Transport, opts=Opts, next_settings=NextSettings0}, Settings) ->
	ok = Transport:send(Socket, cow_http2:settings(Settings)),
	NextSettings = NextSettings0 ++ [{settings_timeout(Opts), Settings}],
	State#state{next_settings=NextSettings}.

settings_timeout(Opts) ->
	SettingsTimeout = maps:get(settings_timeout, Opts, 5000),
	erlang:start_timer(SettingsTimeout, self(), settings_timeout).

%% @todo Add the timeout for last time since we heard of connection.
before_loop(State, Buffer) ->
	loop(State, Buffer).

loop(State=#state{parent=Parent, socket=Socket, transport=Transport,
		children=Children, next_settings=NS, parse_state=PS}, Buffer) ->
	io:format("state ~p~n", [State]),
	Transport:setopts(Socket, [{active, once}]),
	{OK, Closed, Error} = Transport:messages(),
	receive
		%% Socket messages.
		{OK, Socket, Data} ->
			parse(State, << Buffer/binary, Data/binary >>);
		{Closed, Socket} ->
			terminate(State, {socket_error, closed, 'The socket has been closed.'});
		{Error, Socket, Reason} ->
			terminate(State, {socket_error, Reason, 'An error has occurred on the socket.'});
		%% System messages.
		{'EXIT', Parent, Reason} ->
			exit(Reason);
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Parent, ?MODULE, [], {State, Buffer});
		{timeout, TRef, preface_timeout} ->
			case PS of
				{preface, _, TRef} ->
					terminate(State, {connection_error, protocol_error,
						'The preface was not received in a reasonable amount of time.'});
				_ ->
					loop(State, Buffer)
			end;
		{timeout, TRef, settings_timeout} ->
			case lists:keyfind(TRef, 1, NS) of
				{TRef, _} ->
					terminate(State, {connection_error, settings_timeout,
						'The settings were not acknowledged in a reasonable amount of time.'});
				false ->
					loop(State, Buffer)
			end;
		%% Messages pertaining to the connection.
		{{Pid, 0}, Msg} when Pid =:= self() ->
			loop(info(State, Msg), Buffer);
		%% Messages pertaining to a stream.
		{{Pid, StreamID}, Msg} when Pid =:= self() ->
			loop(info(State, StreamID, Msg), Buffer);
		%% Exit signal from children.
		Msg = {'EXIT', Pid, _} ->
			loop(down(State, Pid, Msg), Buffer);
		%% Calls from supervisor module.
		{'$gen_call', {From, Tag}, which_children} ->
			Workers = [{?MODULE, Pid, worker, [?MODULE]} || {Pid, _} <- Children],
			From ! {Tag, Workers},
			loop(State, Buffer);
		{'$gen_call', {From, Tag}, count_children} ->
			NbChildren = length(Children),
			Counts = [{specs, 1}, {active, NbChildren},
				{supervisors, 0}, {workers, NbChildren}],
			From ! {Tag, Counts},
			loop(State, Buffer);
		{'$gen_call', {From, Tag}, _} ->
			From ! {Tag, {error, ?MODULE}},
			loop(State, Buffer);
		Msg ->
			error_logger:error_msg("Received stray message ~p.", [Msg]),
			loop(State, Buffer)
	%% @todo Configurable timeout.
	after 60000 ->
		terminate(State, {internal_error, timeout, 'No message or data received before timeout.'})
	end.

parse(State=#state{socket=Socket, transport=Transport, parse_state={preface, sequence, TRef}}, Data) ->
	case Data of
		<< "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", Rest/bits >> ->
			parse(State#state{parse_state={preface, settings, TRef}}, Rest);
		_ when byte_size(Data) >= 24 ->
			Transport:close(Socket),
			exit({shutdown, {connection_error, protocol_error,
				'The connection preface was invalid. (RFC7540 3.5)'}});
		_ ->
			Len = byte_size(Data),
			<< Preface:Len/binary, _/bits >> = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>,
			case Data of
				Preface ->
					%% @todo OK we should have a timeout when waiting for the preface.
					before_loop(State, Data);
				_ ->
					Transport:close(Socket),
					exit({shutdown, {connection_error, protocol_error,
						'The connection preface was invalid. (RFC7540 3.5)'}})
			end
	end;
%% @todo Perhaps instead of just more we can have {more, Len} to avoid all the checks.
parse(State0=#state{parse_needs=Len0, parse_state=ParseState}, Data) when Len0 =< byte_size(Data) ->
	case cow_http2:parse(Data) of
		{ok, Frame, Rest} ->
			io:format("frame: ~p~n", [Frame]),
			State = State0#state{parse_needs=9},
			case ParseState of
				normal ->
					parse(frame(State, Frame), Rest);
				{preface, settings, TRef} ->
					parse_settings_preface(State, Frame, Rest, TRef);
				{continuation, _, _, _} ->
					parse(continuation_frame(State, Frame), Rest)
			end;
		{stream_error, StreamID, Reason, Human, Rest} ->
			State = State0#state{parse_needs=9},
			parse(stream_reset(State, StreamID, {stream_error, Reason, Human}), Rest);
		Error = {connection_error, _, _} ->
			State = State0#state{parse_needs=9},
			terminate(State, Error);
		{more, Len} ->
			State = State0#state{parse_needs=Len},
			before_loop(State, Data)
	end;
parse(State, Data) ->
	before_loop(State, Data).

parse_settings_preface(State, Frame={settings, _}, Rest, TRef) ->
	_ = erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
	parse(frame(State#state{parse_state=normal}, Frame), Rest);
parse_settings_preface(State, _, _, _) ->
	terminate(State, {connection_error, protocol_error,
		'The preface sequence must be followed by a SETTINGS frame. (RFC7540 3.5)'}).

%% @todo When we get a 'fin' we need to check if the stream had a 'fin' sent back
%% and terminate the stream if this is the end of it.

%% DATA frame.
frame(State=#state{streams=Streams}, {data, StreamID, IsFin0, Data}) ->
	case lists:keyfind(StreamID, #stream.id, Streams) of
		Stream = #stream{state=StreamState0, remote=nofin, body_length=Len0} ->
			Len = Len0 + byte_size(Data),
			IsFin = case IsFin0 of
				fin -> {fin, Len};
				nofin -> nofin
			end,
			try cowboy_stream:data(StreamID, IsFin, Data, StreamState0) of
				{Commands, StreamState} ->
					commands(State, Stream#stream{state=StreamState, body_length=Len}, Commands)
			catch Class:Reason ->
				error_logger:error_msg("Exception occurred in "
					"cowboy_stream:data(~p, ~p, ~p, ~p) with reason ~p:~p.",
					[StreamID, IsFin0, Data, StreamState0, Class, Reason]),
				stream_reset(State, StreamID, {internal_error, {Class, Reason},
					'Exception occurred in cowboy_stream:data/4.'})
			end;
		_ ->
			stream_reset(State, StreamID, {stream_error, stream_closed,
				'DATA frame received for a closed or non-existent stream. (RFC7540 6.1)'})
	end;
%% Single HEADERS frame headers block.
frame(State, {headers, StreamID, IsFin, head_fin, HeaderBlock}) ->
	%% @todo We probably need to validate StreamID here and in 4 next clauses.
	stream_init(State, StreamID, IsFin, HeaderBlock);
%% HEADERS frame starting a headers block. Enter continuation mode.
frame(State, {headers, StreamID, IsFin, head_nofin, HeaderBlockFragment}) ->
	State#state{parse_state={continuation, StreamID, IsFin, HeaderBlockFragment}};
%% Single HEADERS frame headers block with priority.
frame(State, {headers, StreamID, IsFin, head_fin,
		_IsExclusive, _DepStreamID, _Weight, HeaderBlock}) ->
	%% @todo Handle priority.
	stream_init(State, StreamID, IsFin, HeaderBlock);
%% HEADERS frame starting a headers block. Enter continuation mode.
frame(State, {headers, StreamID, IsFin, head_nofin,
		_IsExclusive, _DepStreamID, _Weight, HeaderBlockFragment}) ->
	%% @todo Handle priority.
	State#state{parse_state={continuation, StreamID, IsFin, HeaderBlockFragment}};
%% PRIORITY frame.
frame(State, {priority, _StreamID, _IsExclusive, _DepStreamID, _Weight}) ->
	%% @todo Validate StreamID?
	%% @todo Handle priority.
	State;
%% RST_STREAM frame.
frame(State, {rst_stream, StreamID, Reason}) ->
	stream_reset(State, StreamID, {stream_error, Reason, 'Stream reset requested by client.'});
%% SETTINGS frame.
frame(State=#state{socket=Socket, transport=Transport}, {settings, _Settings}) ->
	%% @todo Apply SETTINGS.
	Transport:send(Socket, cow_http2:settings_ack()),
	State;
%% Ack for a previously sent SETTINGS frame.
frame(State=#state{next_settings=[{TRef, Settings} | NextSettings]}, settings_ack) ->
	_ = erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
	State#state{local_settings=Settings, next_settings=NextSettings};
%% Unexpected PUSH_PROMISE frame.
frame(State, {push_promise, _, _, _, _}) ->
	terminate(State, {connection_error, protocol_error,
		'PUSH_PROMISE frames MUST only be sent on a peer-initiated stream. (RFC7540 6.6)'});
%% PING frame.
frame(State=#state{socket=Socket, transport=Transport}, {ping, Opaque}) ->
	Transport:send(Socket, cow_http2:ping_ack(Opaque)),
	State;
%% Ack for a previously sent PING frame.
%%
%% @todo Might want to check contents but probably a waste of time.
frame(State, {ping_ack, _Opaque}) ->
	State;
%% GOAWAY frame.
frame(State, Frame={goaway, _, _, _}) ->
	terminate(State, {stop, Frame, 'Client is going away.'});
%% Connection-wide WINDOW_UPDATE frame.
frame(State, {window_update, _Increment}) ->
	%% @todo control flow
	State;
%% Stream-specific WINDOW_UPDATE frame.
frame(State, {window_update, _StreamID, _Increment}) ->
	%% @todo stream-specific control flow
	State;
%% Unexpected CONTINUATION frame.
frame(State, {continuation, _, _, _}) ->
	terminate(State, {connection_error, protocol_error,
		'CONTINUATION frames MUST be preceded by a HEADERS frame. (RFC7540 6.10)'}).

continuation_frame(State=#state{parse_state={continuation, StreamID, IsFin, HeaderBlockFragment0}},
		{continuation, StreamID, head_fin, HeaderBlockFragment1}) ->
	stream_init(State#state{parse_state=normal}, StreamID, IsFin,
		<< HeaderBlockFragment0/binary, HeaderBlockFragment1/binary >>);
continuation_frame(State=#state{parse_state={continuation, StreamID, IsFin, HeaderBlockFragment0}},
		{continuation, StreamID, head_nofin, HeaderBlockFragment1}) ->
	State#state{parse_state={continuation, StreamID, IsFin,
		<< HeaderBlockFragment0/binary, HeaderBlockFragment1/binary >>}};
continuation_frame(State, _) ->
	terminate(State, {connection_error, protocol_error,
		'An invalid frame was received while expecting a CONTINUATION frame. (RFC7540 6.2)'}).

down(State=#state{children=Children0}, Pid, Msg) ->
	case lists:keytake(Pid, 1, Children0) of
		{value, {_, StreamID}, Children} ->
			info(State#state{children=Children}, StreamID, Msg);
		false ->
			error_logger:error_msg("Received EXIT signal ~p for unknown process ~p.", [Msg, Pid]),
			State
	end.

info(State, {settings, Settings}) ->
	settings(State, Settings).

info(State=#state{streams=Streams}, StreamID, Msg) ->
	case lists:keyfind(StreamID, #stream.id, Streams) of
		Stream = #stream{state=StreamState0} ->
			try cowboy_stream:info(StreamID, Msg, StreamState0) of
				{Commands, StreamState} ->
					commands(State, Stream#stream{state=StreamState}, Commands)
			catch Class:Reason ->
				error_logger:error_msg("Exception occurred in "
					"cowboy_stream:info(~p, ~p, ~p) with reason ~p:~p.",
					[StreamID, Msg, StreamState0, Class, Reason]),
				stream_reset(State, StreamID, {internal_error, {Class, Reason},
					'Exception occurred in cowboy_stream:info/3.'})
			end;
		false ->
			error_logger:error_msg("Received message ~p for unknown stream ~p.", [Msg, StreamID]),
			State
	end.

commands(State, Stream, []) ->
	after_commands(State, Stream);
%% Error responses are sent only if a response wasn't sent already.
commands(State, Stream=#stream{local=idle}, [{error_response, StatusCode, Headers, Body}|Tail]) ->
	commands(State, Stream, [{response, StatusCode, Headers, Body}|Tail]);
commands(State, Stream, [{error_response, _, _, _}|Tail]) ->
	commands(State, Stream, Tail);
%% Send response headers.
%%
%% @todo Kill the stream if it sent a response when one has already been sent.
%% @todo Keep IsFin in the state.
%% @todo Same two things above apply to DATA, possibly promise too.
commands(State=#state{socket=Socket, transport=Transport, encode_state=EncodeState0, remote_settings=Settings},
		Stream=#stream{id=StreamID, local=idle}, [{response, StatusCode, Headers0, Body}|Tail]) ->
	Headers = Headers0#{<<":status">> => status(StatusCode)},
	{HeaderBlock, EncodeState} = headers_encode(Headers, EncodeState0),
	case Body of
		<<>> ->
			Transport:send(Socket, cow_http2:headers(StreamID, fin, HeaderBlock)),
			commands(State#state{encode_state=EncodeState}, Stream#stream{local=fin}, Tail);
		{sendfile, O, B, P} ->
			Transport:send(Socket, cow_http2:headers(StreamID, nofin, HeaderBlock)),
			commands(State#state{encode_state=EncodeState}, Stream#stream{local=nofin},
				[{sendfile, fin, O, B, P}|Tail]);
		_ ->
			Transport:send(Socket, cow_http2:headers(StreamID, nofin, HeaderBlock)),
			MaxFrameSize = maps:get(max_frame_size, Settings, 16#4000),
			send_data(Socket, Transport, StreamID, fin, Body, MaxFrameSize),
			commands(State#state{encode_state=EncodeState}, Stream#stream{local=fin}, Tail)
	end;
%% @todo response when local!=idle
%% Send response headers and initiate chunked encoding.
commands(State=#state{socket=Socket, transport=Transport, encode_state=EncodeState0},
		Stream=#stream{id=StreamID, local=idle}, [{headers, StatusCode, Headers0}|Tail]) ->
	Headers = Headers0#{<<":status">> => status(StatusCode)},
	{HeaderBlock, EncodeState} = headers_encode(Headers, EncodeState0),
	Transport:send(Socket, cow_http2:headers(StreamID, nofin, HeaderBlock)),
	commands(State#state{encode_state=EncodeState}, Stream#stream{local=nofin}, Tail);
%% @todo headers when local!=idle
%% Send a response body chunk.
%%
%% @todo WINDOW_UPDATE stuff require us to buffer some data.
%%
%% When the body is sent using sendfile, the current solution is not
%% very good. The body could be too large, blocking the connection.
%% Also sendfile technically only works over TCP, so it's not that
%% useful for HTTP/2. At the very least the sendfile call should be
%% split into multiple calls and flow control should be used to make
%% sure we only send as fast as the client can receive and don't block
%% anything.
commands(State=#state{socket=Socket, transport=Transport}, Stream=#stream{id=StreamID, local=nofin},
		[{data, IsFin, Data}|Tail]) ->
	Transport:send(Socket, cow_http2:data(StreamID, IsFin, Data)),
	commands(State, Stream#stream{local=IsFin}, Tail);

%% @todo data when local!=nofin

%% Send a file.
%%
%% @todo This implementation is terrible. A good implementation would
%% need to check that Bytes is exact (or we need to document that we
%% trust it to be exact), and would need to send the file asynchronously
%% in many data frames. Perhaps a sendfile call should result in a
%% process being created specifically for this purpose. Or perhaps
%% the protocol should be "dumb" and the stream handler be the one
%% to ensure the file is sent in chunks (which would require a better
%% flow control at the stream handler level). One thing for sure, the
%% implementation necessarily varies between HTTP/1.1 and HTTP/2.
commands(State=#state{socket=Socket, transport=Transport, remote_settings=Settings},
		Stream=#stream{id=StreamID, local=nofin},
		[{sendfile, IsFin, Offset, Bytes, Path}|Tail]) ->
	MaxFrameSize = maps:get(max_frame_size, Settings, 16#4000),
	send_file(Socket, Transport, StreamID, IsFin, Offset, Bytes, Path, MaxFrameSize),
	% send_file()
	% Transport:send(Socket, cow_http2:data_header(StreamID, IsFin, Bytes)),
	% Transport:sendfile(Socket, Path, Offset, Bytes),
	commands(State, Stream#stream{local=IsFin}, Tail);
%% @todo sendfile when local!=nofin
%% Send a push promise.
%%
%% @todo We need to keep track of what promises we made so that we don't
%% end up with an infinite loop of promises.
commands(State0=#state{socket=Socket, transport=Transport, server_streamid=PromisedStreamID,
		encode_state=EncodeState0}, Stream=#stream{id=StreamID},
		[{push, Method, Scheme, Host, Port, Path, Qs, Headers0}|Tail]) ->
	Authority = case {Scheme, Port} of
		{<<"http">>, 80} -> Host;
		{<<"https">>, 443} -> Host;
		_ -> [Host, $:, integer_to_binary(Port)]
	end,
	PathWithQs = case Qs of
		<<>> -> Path;
		_ -> [Path, $?, Qs]
	end,
	Headers = Headers0#{<<":method">> => Method,
			<<":scheme">> => Scheme,
			<<":authority">> => Authority,
			<<":path">> => PathWithQs},
	{HeaderBlock, EncodeState} = headers_encode(Headers, EncodeState0),
	Transport:send(Socket, cow_http2:push_promise(StreamID, PromisedStreamID, HeaderBlock)),
	%% @todo iolist_to_binary(HeaderBlock) isn't optimal. Need a shortcut.
	State = stream_init(State0#state{server_streamid=PromisedStreamID + 2, encode_state=EncodeState},
		PromisedStreamID, fin, iolist_to_binary(HeaderBlock)),
	commands(State, Stream, Tail);
%% @todo Update the flow control state.
commands(State, Stream, [{flow, _Size}|Tail]) ->
	commands(State, Stream, Tail);
%% Supervise a child process.
commands(State=#state{children=Children}, Stream=#stream{id=StreamID},
		[{spawn, Pid, _Shutdown}|Tail]) -> %% @todo Shutdown
	 commands(State#state{children=[{Pid, StreamID}|Children]}, Stream, Tail);
%% Error handling.
commands(State, Stream=#stream{id=StreamID}, [Error = {internal_error, _, _}|_Tail]) ->
	%% @todo Do we want to run the commands after an internal_error?
	%% @todo Do we even allow commands after?
	%% @todo Only reset when the stream still exists.
	stream_reset(after_commands(State, Stream), StreamID, Error);
%% @todo HTTP/2 has no support for the Upgrade mechanism.
commands(State, Stream, [{switch_protocol, _Headers, _Mod, _ModState}|Tail]) ->
	%% @todo This is an error. Not sure what to do here yet.
	commands(State, Stream, Tail);
commands(State, Stream=#stream{id=StreamID}, [stop|_Tail]) ->
	%% @todo Do we want to run the commands after a stop?
	%% @todo Do we even allow commands after?
	stream_terminate(after_commands(State, Stream), StreamID, normal).

after_commands(State=#state{streams=Streams0}, Stream=#stream{id=StreamID}) ->
	Streams = lists:keystore(StreamID, #stream.id, Streams0, Stream),
	State#state{streams=Streams}.

status(Status) when is_integer(Status) ->
	integer_to_binary(Status);
status(<< H, T, U, _/bits >>) when H >= $1, H =< $9, T >= $0, T =< $9, U >= $0, U =< $9 ->
	<< H, T, U >>.

%% This same function is found in gun_http2.
send_data(Socket, Transport, StreamID, IsFin, Data, Length) ->
	FlagEndStream = case IsFin of
		nofin -> 0;
		fin -> 1
	end,
	Frame = cow_http2:split_data(StreamID, #{
		end_stream => FlagEndStream
	}, #{
		data => Data
	}, Length),
	Transport:send(Socket, Transport, Frame).

send_file(Socket, Transport, StreamID, IsFin, Offset, Bytes, Filename, Length)
		when Bytes > Length
		andalso (is_list(Filename) orelse is_atom(Filename) orelse is_binary(Filename)) ->
	case file:open(Filename, [read, raw, binary]) of
		{ok, RawFile} ->
			_ = case Offset of
				0 ->
					ok;
				_ ->
					{ok, _} = file:position(RawFile, {bof, Offset})
			end,
			try
				send_file_loop(Socket, Transport, StreamID, IsFin, 0, Bytes, RawFile, Length)
			after
				ok = file:close(RawFile)
			end;
		Error = {error, _Reason} ->
			Error
	end;
send_file(Socket, Transport, StreamID, IsFin, Offset, Bytes, RawFile, Length)
		when Bytes > Length ->
	Initial2 = case file:position(RawFile, {cur, 0}) of
		{ok, Offset} ->
			Offset;
		{ok, Initial} ->
			{ok, _} = file:position(RawFile, {bof, Offset}),
			Initial
		end,
	case send_file_loop(Socket, Transport, StreamID, IsFin, 0, Bytes, RawFile, Length) of
		Result = {ok, _Sent} ->
			{ok, _} = file:position(RawFile, {bof, Initial2}),
			Result;
		Error = {error, _Reason} ->
			Error
	end;
send_file(Socket, Transport, StreamID, IsFin, Offset, Bytes, Path, _Length) ->
	Transport:send(Socket, cow_http2:data_header(StreamID, IsFin, Bytes)),
	Transport:sendfile(Socket, Path, Offset, Bytes).

send_file_loop(Socket, Transport, StreamID, IsFin, Sent, Sent, _RawFile, Length) ->
	FlagEndStream = case IsFin of
		fin -> 1;
		nofin -> 0
	end,
	Frame = cow_http2:split_data(StreamID, #{ end_stream => FlagEndStream }, #{ data => [] }, Length),
	case Transport:send(Socket, Frame) of
		ok ->
			{ok, Sent};
		Error = {error, _Reason} ->
			Error
	end;
send_file_loop(Socket, Transport, StreamID, IsFin, Sent, Bytes, RawFile, Length) ->
	ReadSize = case Bytes of
		0 -> Length;
		_ -> min(Bytes - Sent, Length)
	end,
	case file:read(RawFile, ReadSize) of
		{ok, IoData} ->
			IsLastFrame = (Bytes - Sent - Length) =< 0,
			Frame = if
				IsLastFrame ->
					FlagEndStream = case IsFin of
						fin -> 1;
						nofin -> 0
					end,
					cow_http2:split_data(StreamID, #{ end_stream => FlagEndStream }, #{ data => IoData }, Length);
				true ->
					cow_http2:split_data(StreamID, #{ end_stream => 0 }, #{ data => IoData }, Length)
			end,
			case Transport:send(Socket, Frame) of
				ok when IsLastFrame == false ->
					Sent2 = iolist_size(IoData) + Sent,
					send_file_loop(Socket, Transport, StreamID, IsFin, Sent2, Bytes, RawFile, Length);
				ok when IsLastFrame == true ->
					Sent2 = iolist_size(IoData) + Sent,
					{ok, Sent2};
				Error = {error, _Reason} ->
					Error
			end;
		eof ->
			FlagEndStream = case IsFin of
				fin -> 1;
				nofin -> 0
			end,
			Frame = cow_http2:split_data(StreamID, #{ end_stream => FlagEndStream }, #{ data => [] }, Length),
			case Transport:send(Socket, Frame) of
				ok ->
					{ok, Sent};
				Error = {error, _Reason} ->
					Error
			end;
		Error = {error, _Reason} ->
			Error
	end.

-spec terminate(#state{}, _) -> no_return().
terminate(#state{socket=Socket, transport=Transport,
		streams=Streams, children=Children}, Reason) ->
	%% @todo Send GOAWAY frame; need to keep track of last good stream id; how?
	terminate_all_streams(Streams, Reason, Children),
	Transport:close(Socket),
	exit({shutdown, Reason}).

terminate_all_streams([], _, []) ->
	ok;
terminate_all_streams([#stream{id=StreamID, state=StreamState}|Tail], Reason, Children0) ->
	stream_call_terminate(StreamID, Reason, StreamState),
	Children = stream_terminate_children(Children0, StreamID, []),
	terminate_all_streams(Tail, Reason, Children).

%% Stream functions.

stream_init(State0=#state{ref=Ref, socket=Socket, transport=Transport, peer=Peer, decode_state=DecodeState0},
		StreamID, IsFin, HeaderBlock) ->
	%% @todo Add clause for CONNECT requests (no scheme/path).
	try headers_decode(HeaderBlock, DecodeState0) of
		{Headers0=#{
				<<":method">> := Method,
				<<":scheme">> := Scheme,
				<<":authority">> := Authority,
				<<":path">> := PathWithQs}, DecodeState} ->
			State = State0#state{decode_state=DecodeState},
			Headers = maps:without([<<":method">>, <<":scheme">>, <<":authority">>, <<":path">>], Headers0),
			BodyLength = case Headers of
				_ when IsFin =:= fin ->
					0;
				#{<<"content-length">> := <<"0">>} ->
					0;
				#{<<"content-length">> := BinLength} ->
					Length = try
						cow_http_hd:parse_content_length(BinLength)
					catch _:_ ->
						terminate(State0, {stream_error, StreamID, protocol_error,
							''}) %% @todo
						%% @todo Err should terminate here...
					end,
					Length;
				_ ->
					undefined
			end,
			{Host, Port} = cow_http_hd:parse_host(Authority),
			{Path, Qs} = cow_http:parse_fullpath(PathWithQs),
			Req = #{
				ref => Ref,
				pid => self(),
				streamid => StreamID,
				peer => Peer,
				method => Method,
				scheme => Scheme,
				host => Host,
				port => Port,
				path => Path,
				qs => Qs,
				version => 'HTTP/2',
				headers => Headers,

				has_body => IsFin =:= nofin,
				body_length => BodyLength
				%% @todo multipart? keep state separate

				%% meta values (cowboy_websocket, cowboy_rest)
			},
			stream_handler_init(State, StreamID, IsFin, Req);
		{_, DecodeState} ->
			Transport:send(Socket, cow_http2:rst_stream(StreamID, protocol_error)),
			State0#state{decode_state=DecodeState}
	catch _:_ ->
		terminate(State0, {connection_error, compression_error,
			'Error while trying to decode HPACK-encoded header block. (RFC7540 4.3)'})
	end.

stream_handler_init(State=#state{opts=Opts}, StreamID, IsFin, Req) ->
	try cowboy_stream:init(StreamID, Req, Opts) of
		{Commands, StreamState} ->
			commands(State, #stream{id=StreamID, state=StreamState, remote=IsFin}, Commands)
	catch Class:Reason ->
		error_logger:error_msg("Exception occurred in "
			"cowboy_stream:init(~p, ~p, ~p) with reason ~p:~p.",
			[StreamID, IsFin, Req, Class, Reason]),
		stream_reset(State, StreamID, {internal_error, {Class, Reason},
			'Exception occurred in cowboy_stream:init/3.'})
	end.

%% @todo We might need to keep track of which stream has been reset so we don't send lots of them.
stream_reset(State=#state{socket=Socket, transport=Transport}, StreamID,
		StreamError={internal_error, _, _}) ->
	Transport:send(Socket, cow_http2:rst_stream(StreamID, internal_error)),
	stream_terminate(State, StreamID, StreamError);
stream_reset(State=#state{socket=Socket, transport=Transport}, StreamID,
		StreamError={stream_error, Reason, _}) ->
	Transport:send(Socket, cow_http2:rst_stream(StreamID, Reason)),
	stream_terminate(State, StreamID, StreamError).

stream_terminate(State=#state{socket=Socket, transport=Transport,
		streams=Streams0, children=Children0, encode_state=EncodeState0}, StreamID, Reason) ->
	case lists:keytake(StreamID, #stream.id, Streams0) of
		{value, #stream{state=StreamState, local=idle}, Streams} when Reason =:= normal ->
			Headers = #{<<":status">> => <<"204">>},
			{HeaderBlock, EncodeState} = headers_encode(Headers, EncodeState0),
			Transport:send(Socket, cow_http2:headers(StreamID, fin, HeaderBlock)),
			stream_call_terminate(StreamID, Reason, StreamState),
			Children = stream_terminate_children(Children0, StreamID, []),
			State#state{streams=Streams, children=Children, encode_state=EncodeState};
		{value, #stream{state=StreamState, local=nofin}, Streams} when Reason =:= normal ->
			Transport:send(Socket, cow_http2:data(StreamID, fin, <<>>)),
			stream_call_terminate(StreamID, Reason, StreamState),
			Children = stream_terminate_children(Children0, StreamID, []),
			State#state{streams=Streams, children=Children};
		{value, #stream{state=StreamState}, Streams} ->
			stream_call_terminate(StreamID, Reason, StreamState),
			Children = stream_terminate_children(Children0, StreamID, []),
			State#state{streams=Streams, children=Children};
		false ->
			%% @todo Unknown stream. Not sure what to do here. Check again once all
			%% terminate calls have been written.
			State
	end.

stream_call_terminate(StreamID, Reason, StreamState) ->
	try
		cowboy_stream:terminate(StreamID, Reason, StreamState)
	catch Class:Reason ->
		error_logger:error_msg("Exception occurred in "
			"cowboy_stream:terminate(~p, ~p, ~p) with reason ~p:~p.",
			[StreamID, Reason, StreamState, Class, Reason])
	end.

stream_terminate_children([], _, Acc) ->
	Acc;
stream_terminate_children([{Pid, StreamID}|Tail], StreamID, Acc) ->
	exit(Pid, kill),
	stream_terminate_children(Tail, StreamID, Acc);
stream_terminate_children([Child|Tail], StreamID, Acc) ->
	stream_terminate_children(Tail, StreamID, [Child|Acc]).

%% Headers encode/decode.

headers_decode(HeaderBlock, DecodeState0) ->
	{Headers, DecodeState} = cow_hpack:decode(HeaderBlock, DecodeState0),
	{headers_to_map(Headers, #{}), DecodeState}.

%% This function is necessary to properly handle duplicate headers
%% and the special-case cookie header.
headers_to_map([], Acc) ->
	Acc;
headers_to_map([{Name, Value}|Tail], Acc0) ->
	Acc = case Acc0 of
		%% The cookie header does not use proper HTTP header lists.
		#{Name := Value0} when Name =:= <<"cookie">> -> Acc0#{Name => << Value0/binary, "; ", Value/binary >>};
		#{Name := Value0} -> Acc0#{Name => << Value0/binary, ", ", Value/binary >>};
		_ -> Acc0#{Name => Value}
	end,
	headers_to_map(Tail, Acc).

%% The set-cookie header is special; we can only send one cookie per header.
headers_encode(Headers0=#{<<"set-cookie">> := SetCookies}, EncodeState) ->
	Headers1 = maps:to_list(maps:remove(<<"set-cookie">>, Headers0)),
	Headers = Headers1 ++ [{<<"set-cookie">>, Value} || Value <- SetCookies],
	cow_hpack:encode(Headers, EncodeState);
headers_encode(Headers0, EncodeState) ->
	Headers = maps:to_list(Headers0),
	cow_hpack:encode(Headers, EncodeState).

%% System callbacks.

-spec system_continue(_, _, {#state{}, binary()}) -> ok.
system_continue(_, _, {State, Buffer}) ->
	loop(State, Buffer).

-spec system_terminate(any(), _, _, _) -> no_return().
system_terminate(Reason, _, _, _) ->
	exit(Reason).

-spec system_code_change(Misc, _, _, _) -> {ok, Misc} when Misc::{#state{}, binary()}.
system_code_change(Misc, _, _, _) ->
	{ok, Misc}.
