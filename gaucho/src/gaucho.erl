-module(gaucho).

-include("route.hrl").
-include_lib("cowboy/include/http.hrl").
-compile({parse_transform, do}).

-export([process/4, parse_transform/2, start/2]).

-spec parse_transform/2 :: (list(), list()) -> list().

parse_transform(Forms, Options ) ->
    gaucho_pt:parse_transform(Forms, Options).

-spec transform/2 :: (string()|list()|integer()|binary()|float(), atom()) -> any().
transform(Value, To) ->
    Function = list_to_atom(string:concat("to_", atom_to_list(To))),
    apply(xl_string, Function, [Value]).




get_body(Req) ->
    case cowboy_http_req:body(Req) of 
        {ok, Body, Req1} ->
            {ok, {Body, Req1}};
        E -> E
    end.
get_attributes(Req, PathVariables, Attributes) ->
        get_attributes(Req, PathVariables, [], Attributes).

get_attributes(Req, PathVariables, Acc, 
        [{{Name, {body, {ContentType, Converter}}}, Spec}| Attributes]) ->

        %{ok, Body, Req} = cowboy_http_req:body(_Req),
        %Content = Converter:from(Body, ContentType, Spec),
        do([error_m ||
            {Body, Req1} <- get_body(Req),
            Content <- Converter:from(Body, ContentType, Spec),
            get_attributes(Req1, PathVariables, [{Name, Content} | Acc], Attributes)
        ]);
        %Acc1 = lists:append(Acc, [{Name, Content}]),
        %get_attributes(Req, PathVariables, Acc1, Attributes);

get_attributes(Req, PathVariables, Acc, 
        [{{Name, {body, ContentType}}, Spec}| Attributes]) ->
        do([error_m ||
            {Body, Req1} <- get_body(Req),
            Content <- gaucho_default_converter:from(Body,ContentType, Spec),
            get_attributes(Req1, PathVariables, [{Name, Content} | Acc], Attributes)
        ]);

get_attributes(Req, PathVariables, Acc, [{{Name, Spec}, AttributeType}| Attributes]) when is_atom(AttributeType) ->
    do([error_m ||
            {Val, Req1} <- case Spec of
                path ->
                    case xl_lists:kvfind(Name, PathVariables) of
                        {ok, Value} -> {ok, {Value, Req}};
                        undefined -> {error, {unknown_pathvariable, Name}}
                    end;
                'query' ->
                    {ok, cowboy_http_req:qs_val(atom_to_binary(Name, utf8), Req)};

                cookie ->
                    {ok, cowboy_http_req:cookie(atom_to_binary(Name, utf8), Req)};

                header ->
                    {ok, cowboy_http_req:header(Name, Req)};
                _ -> {error, {unknown_spec, Spec}}

            end,
            CValue <- return(transform(Val, AttributeType)),
            get_attributes(Req, PathVariables, [{Name, CValue}| Acc], Attributes)
    ]);

get_attributes(_, _, Acc, _) ->
    {ok, lists:reverse(Acc)}.

get_api(Routes) ->
    {ok, Api} = get_api(Routes, ""),
    xl_string:to_binary(Api).

get_api([#route{accepted_methods=[Method], raw_path=RawPath, output_spec=OutSpec, attribute_specs=InSpec}| Routes], Acc) ->
    do([error_m||
            ApiString <- return(io_lib:format("~s ~s~n\tInputSpec: ~p~n\tOutputSpec: ~p ~n~n", [xl_string:to_upper(xl_string:to_string(Method)), RawPath, InSpec, OutSpec])),
            %ApiString <- return(io_lib:format("~s ~s~n~n", [xl_string:to_upper(xl_string:to_string(Method)), RawPath])),
            get_api(Routes, Acc ++ ApiString)
        ]);
get_api([], Acc) ->
    {ok, Acc}.
%find handler for rawpath
process(AllRoutes = [Route|Routes], Req, State,  Module) ->
    {RawPath, _} = cowboy_http_req:raw_path(Req),
    case lists:last(Req#http_req.path) of
        <<"_api">> ->
            {ok, Req1} = cowboy_http_req:reply(200, [], get_api(AllRoutes), Req),
            {ok, Req1, 200};
        _ ->
            case re:run(RawPath, Route#route.path, [{capture, all, list}]) of
                nomatch ->
                    process(Routes, Req, State,  Module);
                {match, _} ->
                    Method = case cowboy_http_req:method(Req) of
                        {RawMethod, _} when is_binary(RawMethod) ->
                            binary_to_atom(RawMethod, utf8);
                        {RawMethod, _} when is_atom(RawMethod) ->
                            list_to_atom(string:to_lower(atom_to_list(RawMethod)))
                    end,
                    case lists:member(Method, Route#route.accepted_methods) of
                        true ->
                            PathVariables = extract_path_variables(Req, Route),
                            {ok, Variables} = get_attributes(Req, PathVariables, Route#route.attribute_specs),
                            Attributes = [Val||{_, Val} <- Variables],

                            case apply(Module, Route#route.handler, Attributes) of
                                {ok, Result} ->
                                    {ok, Response} = prepare_response(Result, Route),
                                    {ok, Req1} = cowboy_http_req:reply(200, [], Response, Req),
                                    {ok, Req1, 200};
                                ok -> 
                                    {ok, Req, 204};
                                {error, {Status, Message}} -> 
                                    {ok, Req1} = cowboy_http_req:reply(Status, [], Message, Req),
                                    {ok, Req1, Status};

                                {error, UnexpectedError} ->
                                    io:format("~p~n", [UnexpectedError]),
                                    {ok, Req1} = cowboy_http_req:reply(404, [], <<"Not found">>, Req),
                                    {ok, Req1, 404};
                                UnexpectedResult  ->
                                    Info = io_lib:format("~p~n", [UnexpectedResult]),
                                    {ok, Req1} = cowboy_http_req:reply(500, [], list_to_binary(Info), Req),
                                    {ok, Req1, 500}
                            end;
                        false -> 
                            process(Routes, Req, State, Module)
                    end
            end
    end;
process([], Req, State, _) ->
    {ok, Req1} = cowboy_http_req:reply(404, [], <<"">>, Req),
    {ok, Req1, State}.


prepare_response(Result, #route{out_format=raw}) ->
    {ok, Result};
prepare_response(Result, #route{output_spec=OutputSpec,produces={ContentType, Converter},out_format=auto})->
    Converter:to(Result, ContentType, OutputSpec);
prepare_response(Result, R = #route{produces=ContentType, out_format=auto})->
    prepare_response(Result, R#route{produces={ContentType, gaucho_default_converter}}).

extract_path_variables(Req, Route) ->
    case re:run(Route#route.raw_path, "{([^/:]*):?[^/]*}", [global, {capture, [1], list}]) of
	{match, VariableNames} ->
	    Keys = [list_to_atom(Name)||[Name] <- VariableNames],
	    {RawPath, _} = cowboy_http_req:raw_path(Req),
	    {match, [_|Values]} = re:run(RawPath, Route#route.path, [{capture, all, list}]),
	    lists:zip(Keys, Values);
	nomatch -> []
    end.



fill_path_variables(Variables, [PathVariable = {Key, _}| PathVariables]) ->
    fill_path_variables(lists:keyreplace(Key, 1, Variables, PathVariable), PathVariables);

fill_path_variables(Variables, []) ->
    Variables.


-spec start/2 :: (term(), [{atom(), pos_integer(), atom(), [term()], atom(), [term()]}]) -> error_m:monad(ok).
start(Dispatch, Listeners) ->
    xl_lists:eforeach(fun({Name, Acceptors, Transport, TransportOpts, Protocol, ProtocolOpts}) ->
        cowboy:start_listener(Name, Acceptors, Transport, TransportOpts, Protocol, [{dispatch, Dispatch} | ProtocolOpts])
    end, Listeners).



