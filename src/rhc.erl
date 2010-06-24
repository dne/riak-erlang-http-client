-module(rhc).

-export([create/0, create/4,
         ping/1,
         get_client_id/1,
         get_server_info/1,
         get/3, get/4,
         put/2, put/3,
         delete/3, delete/4,
         list_buckets/1,
         list_keys/2,
         stream_list_keys/2,
         get_bucket/2,
         set_bucket/3,
         mapred/3,mapred/4,
         mapred_stream/4, mapred_stream/5,
         mapred_bucket/3, mapred_bucket/4,
         mapred_bucket_stream/5]).

-include("raw_http.hrl").

-define(DEFAULT_TIMEOUT, 60000).

-record(rhc, {ip,
              port,
              prefix,
              options}).

create() ->
    create("127.0.0.1", 8098, "riak", []).

create(IP, Port, Prefix, Opts0) when is_list(IP), is_integer(Port),
                                     is_list(Prefix), is_list(Opts0) ->
    Opts = case proplists:lookup(client_id, Opts0) of
               none -> [{client_id, random_client_id()}|Opts0];
               Bin when is_binary(Bin) ->
                   [{client_id, binary_to_list(Bin)}
                    | [ O || O={K,_} <- Opts0, K =/= client_id ]];
               _ ->
                   Opts0
           end,
    #rhc{ip=IP, port=Port, prefix=Prefix, options=Opts}.

ping(Rhc) ->
    Url = ping_url(Rhc),
    case request(get, Url, ["200","204"]) of
        {ok, _Status, _Headers, _Body} ->
            ok;
        {error, Error} ->
            {error, Error}
    end.

get_client_id(Rhc) ->
    {ok, client_id(Rhc, [])}.

get_server_info(_Rhc) ->
    throw(not_implemented).

get(Rhc, Bucket, Key) ->
    get(Rhc, Bucket, Key, []).

get(Rhc, Bucket, Key, Options) ->
    Qs = get_q_params(Rhc, Options),
    Url = make_url(Rhc, Bucket, Key, Qs),
    case request(get, Url, ["200", "300"]) of
        {ok, _Status, Headers, Body} ->
            {ok, make_riakc_obj(Bucket, Key, Headers, Body)};
        {error, {ok, "404", _, _}} ->
            {error, notfound};
        {error, Error} ->
            {error, Error}
    end.

put(Rhc, Object) ->
    put(Rhc, Object, []).

put(Rhc, Object, Options) ->
    Qs = put_q_params(Rhc, Options),
    Bucket = riakc_obj:bucket(Object),
    Key = riakc_obj:key(Object),
    Url = make_url(Rhc, Bucket, Key, Qs),
    Method = if Key =:= undefined -> post;
                true              -> put
             end,
    {Headers0, Body} = serialize_riakc_obj(Rhc, Object),
    Headers = [{?HEAD_CLIENT, client_id(Rhc, Options)}
               |Headers0],
    case request(Method, Url, ["200", "204", "300"], Headers, Body) of
        {ok, Status, ReplyHeaders, ReplyBody} ->
            if Status =:= "204" ->
                    ok;
               true ->
                    {ok, make_riakc_obj(Bucket, Key, ReplyHeaders, ReplyBody)}
            end;
        {error, Error} ->
            {error, Error}
    end.
    
delete(Rhc, Bucket, Key) ->
    delete(Rhc, Bucket, Key, []).

delete(Rhc, Bucket, Key, Options) ->
    Qs = delete_q_params(Rhc, Options),
    Url = make_url(Rhc, Bucket, Key, Qs),
    Headers = [{?HEAD_CLIENT, client_id(Rhc, Options)}],
    case request(delete, Url, ["204"], Headers) of
        {ok, "204", _Headers, _Body} -> ok;
        {error, Error}               -> {error, Error}
    end.
    
list_buckets(_Rhc) ->
    throw(not_implemented).

list_keys(_Rhc, _Bucket) ->
    throw(not_implemented).

stream_list_keys(_Rhc, _Bucket) ->
    throw(not_implemented).

get_bucket(Rhc, Bucket) ->
    Url = make_url(Rhc, Bucket, undefined, [{<<"keys">>, <<"false">>}]),
    case request(get, Url, ["200"]) of
        {ok, "200", _Headers, Body} ->
            {struct, Response} = mochijson2:decode(Body),
            {struct, Props} = proplists:get_value(?JSON_PROPS, Response),
            {ok, erlify_bucket_props(Props)};
        {error, Error} ->
            {error, Error}
    end.

set_bucket(Rhc, Bucket, Props0) ->
    Url = make_url(Rhc, Bucket, undefined, []),
    Headers =  [{"Content-Type", "application/json"}],
    Props = httpify_bucket_props(Props0),
    Body = mochijson2:encode({struct, [{<<"props">>, {struct, Props}}]}),
    case request(put, Url, ["204"], Headers, Body) of
        {ok, "204", _Headers, _Body} -> ok;
        {error, Error}               -> {error, Error}
    end.

mapred(Rhc, Inputs, Query) ->
    mapred(Rhc, Inputs, Query, ?DEFAULT_TIMEOUT).

mapred(_Rhc, _Inputs, _Query, _Timeout) ->
    throw(not_implemented).

mapred_stream(Rhc, Inputs, Query, ClientPid) ->
    mapred_stream(Rhc, Inputs, Query, ClientPid, ?DEFAULT_TIMEOUT).

mapred_stream(_Rhc, _Inputs, _Query, _ClientPid, _Timeout) ->
    throw(not_implemented).

mapred_bucket(Rhc, Bucket, Query) ->
    mapred_bucket(Rhc, Bucket, Query, ?DEFAULT_TIMEOUT).

mapred_bucket(_Rhc, _Bucket, _Query, _Timeout) ->
    throw(not_implemented).

mapred_bucket_stream(_Rhc, _Bucket, _Query, _ClientPid, _Timeout) ->
    throw(not_implemented).

%% INTERNAL

client_id(#rhc{options=RhcOptions}, Options) ->
    case proplists:get_value(client_id, Options) of
        undefined ->
            proplists:get_value(client_id, RhcOptions);
        ClientId ->
            ClientId
    end.

random_client_id() ->
    {{Y,Mo,D},{H,Mi,S}} = erlang:universaltime(),
    {_,_,NowPart} = now(),
    Id = erlang:phash2([Y,Mo,D,H,Mi,S,node(),NowPart]),
    base64:encode_to_string(<<Id:32>>).

root_url(#rhc{ip=Ip, port=Port}) ->
    ["http://",Ip,":",integer_to_list(Port),"/"].

mapred_url(Rhc) ->
    binary_to_list(iolist_to_binary([root_url(Rhc), "mapred/"])).

ping_url(Rhc) ->
    binary_to_list(iolist_to_binary([root_url(Rhc), "ping/"])).
    
make_url(Rhc=#rhc{prefix=Prefix}, Bucket, Key, Query) ->
    binary_to_list(
      iolist_to_binary(
        [root_url(Rhc),
         Prefix, "/",
         Bucket, "/",
         [ [Key,"/"] || Key =/= undefined ],
         [ ["?", mochiweb_util:urlencode(Query)] || Query =/= [] ]
        ])).

request(Method, Url, Expect) ->
    request(Method, Url, Expect, [], []).
request(Method, Url, Expect, Headers) ->
    request(Method, Url, Expect, Headers, []).
request(Method, Url, Expect, Headers, Body) ->
    Accept = {"Accept", "multipart/mixed, */*;q=0.9"},
    case ibrowse:send_req(Url, [Accept|Headers], Method, Body) of
        Resp={ok, Status, _, _} ->
            case lists:member(Status, Expect) of
                true -> Resp;
                false -> {error, Resp}
            end;
        Error ->
            Error
    end.

options(#rhc{options=Options}) ->
    Options.

get_q_params(Rhc, Options) ->
    options_list([r], Options ++ options(Rhc)).

put_q_params(Rhc, Options) ->
    options_list([r,w,dw,return_body], Options ++ options(Rhc)).

delete_q_params(Rhc, Options) ->
    options_list([r,rw], Options ++ options(Rhc)).

options_list(Keys, Options) ->
    options_list(Keys, Options, []).

options_list([K|Rest], Options, Acc) ->
    NewAcc = case proplists:lookup(K, Options) of
                 {K,V} -> [{K,V}|Acc];
                 none  -> Acc
             end,
    options_list(Rest, Options, NewAcc);
options_list([], _, Acc) ->
    Acc.

make_riakc_obj(Bucket, Key, Headers, Body) ->
    Vclock = base64:decode(proplists:get_value(?HEAD_VCLOCK, Headers, "")),
    case ctype_from_headers(Headers) of
        {"multipart/mixed", Args} ->
            {"boundary", Boundary} = proplists:lookup("boundary", Args),
            riakc_obj:new_obj(
              Bucket, Key, Vclock,
              decode_siblings(Boundary, Body));
        {_CType, _} ->
            riakc_obj:new_obj(
              Bucket, Key, Vclock,
              [{headers_to_metadata(Headers), list_to_binary(Body)}])
    end.

ctype_from_headers(Headers) ->
    mochiweb_util:parse_header(
      proplists:get_value(?HEAD_CTYPE, Headers)).

vtag_from_headers(Headers) ->
    %% non-sibling uses ETag, sibling uses Etag
    %% (note different capitalization on 't')
    case proplists:lookup("ETag", Headers) of
        {"ETag", ETag} -> ETag;
        none -> proplists:get_value("Etag", Headers)
    end.
           

lastmod_from_headers(Headers) ->
    RfcDate = proplists:get_value("Last-Modified", Headers),
    GS = calendar:datetime_to_gregorian_seconds(
           httpd_util:convert_request_date(RfcDate)),
    ES = GS-62167219200, %% gregorian seconds of the epoch
    {ES div 1000000, % Megaseconds
     ES rem 1000000, % Seconds
     0}.              % Microseconds

decode_siblings(Boundary, "\r\n"++SibBody) ->
    decode_siblings(Boundary, SibBody);
decode_siblings(Boundary, SibBody) ->
    Parts = webmachine_multipart:get_all_parts(
              list_to_binary(SibBody), Boundary),
    [ {headers_to_metadata([ {binary_to_list(H), binary_to_list(V)}
                             || {H, V} <- Headers ]),
       element(1, split_binary(Body, size(Body)-2))} %% remove trailing \r\n
      || {_, {_, Headers}, Body} <- Parts ].

headers_to_metadata(Headers) ->
    UserMeta = extract_user_metadata(Headers),

    {CType,_} = ctype_from_headers(Headers),
    CUserMeta = dict:store(?MD_CTYPE, CType, UserMeta),

    VTag = vtag_from_headers(Headers),
    VCUserMeta = dict:store(?MD_VTAG, VTag, CUserMeta),

    LastMod = lastmod_from_headers(Headers),
    LVCUserMeta = dict:store(?MD_LASTMOD, LastMod, VCUserMeta),

    case extract_links(Headers) of
        [] -> LVCUserMeta;
        Links -> dict:store(?MD_LINKS, Links, LVCUserMeta)
    end.

extract_user_metadata(_Headers) ->
    %%TODO
    dict:new().

extract_links(Headers) ->
    {ok, Re} = re:compile("</[^/]+/([^/]+)/([^/]+)>; *riaktag=\"(.*)\""),
    Extractor = fun(L, Acc) ->
                        case re:run(L, Re, [{capture,[1,2,3],binary}]) of
                            {match, [Bucket, Key,Tag]} ->
                                [{{Bucket,Key},Tag}|Acc];
                            nomatch ->
                                Acc
                        end
                end,
    LinkHeader = proplists:get_value(?HEAD_LINK, Headers, []),
    lists:foldl(Extractor, [], string:tokens(LinkHeader, ",")).

serialize_riakc_obj(Rhc, Object) ->
    {make_headers(Rhc, Object), make_body(Object)}.

make_headers(Rhc, Object) ->
    MD = riakc_obj:get_update_metadata(Object),
    CType = case dict:find(?MD_CTYPE, MD) of
                {ok, C} -> C;
                error -> <<"application/octet-stream">>
            end,
    Links = case dict:find(?MD_LINKS, MD) of
                {ok, L} -> L;
                error   -> []
            end,
    VClock = riakc_obj:vclock(Object),
    lists:flatten(
      [{?HEAD_CTYPE, binary_to_list(CType)},
       [ {?HEAD_LINK, encode_links(Rhc, Links)} || Links =/= [] ],
       [ {?HEAD_VCLOCK, base64:encode_to_string(VClock)}
         || VClock =/= undefined ]
       | encode_user_metadata(MD) ]).

encode_links(_, []) -> [];
encode_links(#rhc{prefix=Prefix}, Links) ->
    {{FirstBucket, FirstKey}, FirstTag} = hd(Links),
    lists:foldl(
      fun({{Bucket, Key}, Tag}, Acc) ->
              [format_link(Prefix, Bucket, Key, Tag), ", "|Acc]
      end,
      format_link(Prefix, FirstBucket, FirstKey, FirstTag),
      tl(Links)).

encode_user_metadata(_Metadata) ->
    %% TODO
    [].

format_link(Prefix, Bucket, Key, Tag) ->
    io_lib:format("</~s/~s/~s>; riaktag=\"~s\"",
                  [Prefix, Bucket, Key, Tag]).

make_body(Object) ->
    case riakc_obj:get_update_value(Object) of
        Val when is_binary(Val) -> Val;
        Val when is_list(Val) ->
            case is_iolist(Val) of
                true -> Val;
                false -> term_to_binary(Val)
            end;
        Val ->
            term_to_binary(Val)
    end.

is_iolist(Binary) when is_binary(Binary) -> true;
is_iolist(List) when is_list(List) ->
    lists:all(fun is_iolist/1, List);
is_iolist(_) -> false.

erlify_bucket_props(Props) ->
    lists:flatten([ erlify_bucket_prop(K, V) || {K, V} <- Props ]).
erlify_bucket_prop(?JSON_N_VAL, N) -> {n_val, N};
erlify_bucket_prop(?JSON_ALLOW_MULT, AM) -> {allow_mult, AM};
erlify_bucket_prop(_Ignore, _) -> [].

httpify_bucket_props(Props) ->
    lists:flatten([ httpify_bucket_prop(K, V) || {K, V} <- Props ]).
httpify_bucket_prop(n_val, N) -> {?JSON_N_VAL, N};
httpify_bucket_prop(allow_mult, AM) -> {?JSON_ALLOW_MULT, AM};
httpify_bucket_prop(_Ignore, _) -> [].