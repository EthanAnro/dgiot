%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 DGIOT Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(dgiot_tdengine_handler).
-author("dgiot").
-behavior(dgiot_rest).
-dgiot_rest(all).
-include("dgiot_tdengine.hrl").
-include_lib("dgiot/include/logger.hrl").

%% API
-export([swagger_tdengine/0, get_props/1, get_time/2]).
-export([handle/4]).


%% API描述
%% 支持二种方式导入
%% 示例:
%% 1. Metadata为map表示的JSON,
%%    dgiot_http_server:bind(<<"/tdengine">>, ?MODULE, [], Metadata)
%% 2. 从模块的priv/swagger/下导入
%%    dgiot_http_server:bind(<<"/swagger_tdengine.json">>, ?MODULE, [], priv)
swagger_tdengine() ->
    [
        dgiot_http_server:bind(<<"/swagger_tdengine.json">>, ?MODULE, [], priv)
    ].


%%%===================================================================
%%% 请求处理
%%%  如果登录, Context 内有 <<"user">>, version
%%%===================================================================

-spec handle(OperationID :: atom(), Args :: map(), Context :: map(), Req :: dgiot_req:req()) ->
    {Status :: dgiot_req:http_status(), Body :: map()} |
    {Status :: dgiot_req:http_status(), Headers :: map(), Body :: map()} |
    {Status :: dgiot_req:http_status(), Headers :: map(), Body :: map(), Req :: dgiot_req:req()}.

handle(OperationID, Args, Context, Req) ->
    Headers = #{},
    case catch do_request(OperationID, Args, Context, Req) of
        {ErrType, Reason} when ErrType == 'EXIT'; ErrType == error ->
            ?LOG(info, "do request: ~p, ~p, ~p~n", [OperationID, Args, Reason]),
            Err = case is_binary(Reason) of
                      true -> Reason;
                      false -> list_to_binary(io_lib:format("~p", [Reason]))
                  end,
            {500, Headers, #{<<"error">> => Err}};
        ok ->
            ?LOG(debug, "do request: ~p, ~p ->ok ~n", [OperationID, Args]),
            {200, Headers, #{}, Req};
        {ok, Res} ->
            %?LOG(info,"do request: ~p, ~p ->~p~n", [OperationID, Args, Res]),
            {200, Headers, Res, Req};
        {Status, Res} ->
            ?LOG(info, "do request: ~p, ~p ->~p~n", [OperationID, Args, Res]),
            {Status, Headers, Res, Req};
        {Status, NewHeaders, Res} ->
            ?LOG(info, "do request: ~p, ~p ->~p~n", [OperationID, Args, Res]),
            {Status, maps:merge(Headers, NewHeaders), Res, Req};
        {Status, NewHeaders, Res, NewReq} ->
            ?LOG(debug, "do request: ~p, ~p ->~p~n", [OperationID, Args, Res]),
            {Status, maps:merge(Headers, NewHeaders), Res, NewReq}
    end.


%%%===================================================================
%%% 内部函数 Version:API版本
%%%===================================================================


%% TDengine 概要: 获取当前产品下的所有设备数据 描述:获取当前产品下的所有设备数据
%% OperationId:get_td_cid_pid
%% 请求:GET /iotapi/td/prodcut/:productId
do_request(get_product_pid, #{
    <<"pid">> := ProductId,
    <<"where">> := Where,
    <<"keys">> := _Keys
} = Args, #{<<"sessionToken">> := SessionToken} = _Context, _Req) ->
    Fun =
        fun(ChannelId) ->
            TableName = ?Table(ProductId),
            Query = maps:without([<<"pid">>], Args),
            case jsx:is_json(Where) of
                true ->
                    case dgiot_tdengine:query_object(ChannelId, TableName, Query#{
                        <<"db">> => ProductId,
                        <<"where">> => jsx:decode(Where, [{labels, binary}, return_maps])
                    }) of
                        {ok, Data} ->
                            {ok, Data};
                        {error, Reason} ->
                            {400, Reason}
                    end;
                false ->
                    {400, <<"where is not json">>}
            end
        end,
    do_channel(ProductId, SessionToken, Fun);


%% TDengine 概要: 获取当前产品下的所有设备数据 描述:获取当前产品下的所有设备数据
%% OperationId:get_td_productid_channelid_addr_productid
%% 请求:GET /iotapi/td/:ProductId/:channelId/:addr/:productId
do_request(get_device_deviceid, #{<<"deviceid">> := DeviceId} = Args, #{<<"sessionToken">> := SessionToken} = _Context, _Req) ->
    case dgiot_tdengine:get_channel(SessionToken) of
        {error, Error} -> {error, Error};
        {ok, Channel} ->
            ?LOG(info, "DeviceId ~p", [DeviceId]),
            case dgiot_parse:get_object(<<"Device">>, DeviceId) of
                {ok, #{<<"objectId">> := DeviceId, <<"product">> := #{<<"objectId">> := ProductId}}} ->
                    get_tddata(Channel, ProductId, DeviceId, Args);
                _ ->
                    {error, <<"not find device">>}
            end
    end;

%% TDengine 概要: 获取设备数据图表 描述:获取设备数据图表
do_request(get_echart_deviceid, #{<<"deviceid">> := DeviceId} = Args, #{<<"sessionToken">> := SessionToken} = _Context, _Req) ->
    case dgiot_tdengine:get_channel(SessionToken) of
        {error, Error} -> {error, Error};
        {ok, Channel} ->
            case dgiot_parse:get_object(<<"Device">>, DeviceId) of
                {ok, #{<<"objectId">> := DeviceId, <<"product">> := #{<<"objectId">> := ProductId}}} ->
                    get_chartdata(Channel, ProductId, DeviceId, Args);
                _ ->
                    {error, <<"not find device">>}
            end
    end;

%% TDengine 概要: 获取当前设备最新时序数据卡片
do_request(get_app_deviceid, #{<<"deviceid">> := DeviceId} = Args, #{<<"sessionToken">> := SessionToken} = _Context, _Req) ->
    case dgiot_tdengine:get_channel(SessionToken) of
        {error, Error} -> {error, Error};
        {ok, Channel} ->
%%            ?LOG(info,"DeviceId ~p", [DeviceId]),
            case dgiot_parse:get_object(<<"Device">>, DeviceId) of
                {ok, #{<<"objectId">> := DeviceId, <<"product">> := #{<<"objectId">> := ProductId}}} ->
                    get_appdata(Channel, ProductId, DeviceId, Args);
                _ ->
                    {error, <<"not find device">>}
            end
    end;

%%  服务器不支持的API接口
do_request(_OperationId, _Args, _Context, _Req) ->
    {error, <<"Not Allowed.">>}.

get_tddata(Channel, ProductId, DeviceId, Args) ->
    Query = maps:without([<<"productid">>, <<"deviceid">>], Args),
    ?LOG(info, "Channel ~p Args ~p", [Channel, Args]),
    case dgiot_data:get({tdengine_os, Channel}) of
        <<"windows">> ->
            Keys =
                lists:foldl(fun(X, Acc) ->
                    case X of
                        <<"count(*)">> -> Acc ++ [<<"count(*)">>];
                        <<"*">> -> Acc ++ [<<"values">>];
                        _ -> Acc ++ [<<"values.", X/binary>>]
                    end
                            end, [], binary:split(maps:get(<<"keys">>, Args, <<"count(*)">>), <<$,>>, [global, trim])),
            Query2 = Query#{<<"where">> => #{<<"product">> => ProductId,
                <<"device">> => DeviceId}, <<"keys">> => Keys},
            ?LOG(info, "Query2 ~p", [Query2]),
            case dgiot_parse:query_object(<<"Timescale">>, Query2) of
                {ok, #{<<"results">> := Results} = All} when length(Results) > 0 ->
                    Data = lists:foldl(fun(X, Acc) ->
                        Acc ++ [maps:get(<<"values">>, X)]
                                       end, [], Results),
                    {ok, All#{<<"results">> => Data}};
                {ok, #{<<"results">> := Result}} ->
                    {error, Result};
                Error ->
                    Error
            end;
        _ ->
            Where = maps:get(<<"where">>, Args),
            Query = maps:without([<<"productid">>, <<"deviceid">>], Args),
            TableName = ?Table(DeviceId),
            case dgiot_tdengine:query_object(Channel, TableName, Query#{
                <<"db">> => ProductId,
                <<"where">> => Where
            }) of
                {ok, Data} ->
                    {ok, Data};
                {error, Reason} ->
                    {400, Reason}
            end
    end.

get_chartdata(Channel, ProductId, DeviceId, Args) ->
    Query = maps:without([<<"productid">>, <<"deviceid">>], Args),
    case dgiot_data:get({tdengine_os, Channel}) of
        <<"windows">> ->
            pass;
        _ ->
            Query = maps:without([<<"productid">>, <<"deviceid">>], Args),
            Interval = maps:get(<<"interval">>, Args),
            TableName = ?Table(DeviceId),
            case dgiot_tdengine:get_chartdata(Channel, TableName, Query#{
                <<"db">> => ProductId
            }) of
                {Names, {ok, #{<<"results">> := Results}}} ->
                    Chartdata = get_chart(ProductId, Results, Names, Interval),
                    {ok, #{<<"chartData">> => Chartdata}};
                _ ->
                    {ok, #{<<"code">> => 400, <<"msg">> => <<"no data">>}}
            end
    end.

get_appdata(Channel, ProductId, DeviceId, Args) ->
    case dgiot_data:get({tdengine_os, Channel}) of
        <<"windows">> ->
            pass;
        _ ->
            TableName = ?Table(DeviceId),
            case dgiot_tdengine:get_appdata(Channel, TableName, Args#{<<"db">> => ProductId}) of
                {ok, #{<<"results">> := Results}} when length(Results) > 0 ->
                    Chartdata = get_app(ProductId, Results, DeviceId, Args),
                    {ok, #{<<"data">> => Chartdata}};
                _ ->
                    Chartdata = get_app(ProductId, [#{}], DeviceId, Args),
                    {ok, #{<<"data">> => Chartdata}}
            end
    end.

get_prop(ProductId) ->
    case dgiot_product:lookup_prod(ProductId) of
        {ok, #{<<"thing">> := #{<<"properties">> := Props}}} ->
            lists:foldl(fun(X, Acc) ->
                case X of
                    #{<<"identifier">> := Identifier, <<"name">> := Name, <<"isshow">> := true} ->
                        Acc#{Identifier => Name};
                    _ -> Acc
                end
                        end, #{}, Props);
        _ ->
            #{}
    end.


get_unit(ProductId) ->
    case dgiot_product:lookup_prod(ProductId) of
        {ok, #{<<"thing">> := #{<<"properties">> := Props}}} ->
            lists:foldl(fun(X, Acc) ->
                case X of
                    #{<<"name">> := Name, <<"dataType">> := #{<<"specs">> := #{<<"unit">> := Unit}}} ->
                        Acc#{Name => Unit};
                    _ -> Acc
                end
                        end, #{}, Props);
        _ ->
            #{}
    end.

get_props(ProductId) ->
    case dgiot_product:lookup_prod(ProductId) of
        {ok, #{<<"thing">> := #{<<"properties">> := Props}}} ->
            lists:foldl(fun(X, Acc) ->
                case X of
                    #{<<"identifier">> := Identifier, <<"isshow">> := true} ->
                        Acc#{Identifier => X};
                    _ -> Acc
                end
                        end, #{}, Props);
        _ ->
            #{}
    end.

get_chart(ProductId, Results, Names, Interval) ->
    Maps = get_prop(ProductId),
    Units = get_unit(ProductId),
    NewMaps = maps:merge(#{<<"createdat">> => <<"日期"/utf8>>}, Maps),
    Columns = [<<"日期"/utf8>>] ++ Names,
    Rows =
        lists:foldl(fun(Line, Lines) ->
            NewLine =
                maps:fold(fun(K, V, Acc) ->
                    case maps:find(K, NewMaps) of
                        error ->
                            Acc;
                        {ok, Name} ->
                            case Name of
                                <<"日期"/utf8>> ->
                                    NewV = get_time(V, Interval),
                                    Acc#{Name => NewV};
                                _ ->
                                    Acc#{Name => V}
                            end
                    end
                          end, #{}, Line),
            Lines ++ [NewLine]
                    end, [], Results),
    ?LOG(debug, "Rows ~p", [Rows]),
    ChildRows = lists:foldl(fun(X, Acc1) ->
        Date = maps:get(<<"日期"/utf8>>, X),
        maps:fold(fun(K1, V1, Acc) ->
            case maps:find(K1, Acc) of
                error ->
                    Acc#{K1 => [#{<<"日期"/utf8>> => Date, K1 => V1}]};
                {ok, V2} ->
                    Acc#{K1 => V2 ++ [#{<<"日期"/utf8>> => Date, K1 => V1}]}
            end
                  end, Acc1, maps:without([<<"日期"/utf8>>], X))
                            end, #{}, Rows),
    ?LOG(debug, "ChildRows ~p", [ChildRows]),
    Child =
        maps:fold(fun(K, V, Acc) ->
            Unit =
                case maps:find(K, Units) of
                    error -> <<"">>;
                    {ok, Unit1} -> Unit1
                end,
            Acc ++ [#{<<"columns">> => [<<"日期"/utf8>>, K], <<"rows">> => V, <<"unit">> => Unit}]
                  end, [], ChildRows),
    ?LOG(debug, "Child ~p", [Child]),
    #{<<"columns">> => Columns, <<"rows">> => Rows, <<"child">> => Child}.

get_Props(ProductId, <<"*">>) ->
    case dgiot_product:lookup_prod(ProductId) of
        {ok, #{<<"thing">> := #{<<"properties">> := Props}}} ->
            Props;
        _ ->
            []
    end;

get_Props(ProductId, Keys) when Keys == undefined; Keys == <<>> ->
    get_Props(ProductId, <<"*">>);

get_Props(ProductId, Keys) ->
    List =
        case is_list(Keys) of
            true -> Keys;
            false -> re:split(Keys, <<",">>)
        end,
    lists:foldl(fun(Identifier, Acc) ->
        case dgiot_product:lookup_prod(ProductId) of
            {ok, #{<<"thing">> := #{<<"properties">> := Props}}} ->
                lists:foldl(fun(Prop, Acc1) ->
                    case Prop of
                        #{<<"identifier">> := Identifier} ->
                            Acc1 ++ [Prop];
                        _ ->
                            Acc1
                    end
                            end, Acc, Props);
            _ ->
                Acc
        end
                end, [], List).

get_app(ProductId, Results, DeviceId, Args) ->
    [Result | _] = Results,
    Keys = maps:get(<<"keys">>, Args, <<"*">>),
    Props = get_Props(ProductId, Keys),
    lists:foldl(fun(X, Acc) ->
        case X of
            #{<<"name">> := Name, <<"identifier">> := Identifier, <<"dataForm">> := #{<<"protocol">> := Protocol}, <<"dataSource">> := DataSource, <<"dataType">> := #{<<"type">> := Typea} = DataType} ->
                Time = maps:get(<<"createdat">>, Result, dgiot_datetime:now_secs()),
                NewTime = dgiot_tdengine_handler:get_time(dgiot_utils:to_binary(Time), <<"111">>),
                Devicetype = maps:get(<<"devicetype">>, X, <<"others">>),
                Ico = maps:get(<<"ico">>, X, <<"">>),
                Specs = maps:get(<<"specs">>, DataType, #{}),
                Unit = maps:get(<<"unit">>, Specs, <<"">>),
                case do_hook({Protocol, Identifier}, DataSource#{<<"deviceid">> => DeviceId}) of
                    ignore ->
                        NewV =
                            case maps:find(Identifier, Result) of
                                error ->
                                    <<"--">>;
                                {ok, V} ->
                                    check_field(Typea, V, #{<<"datatype">> => DataType, <<"specs">> => Specs, <<"deviceid">> => DeviceId})
                            end,
                        Acc ++ [#{<<"identifier">> => Identifier, <<"name">> => Name,
                            <<"type">> => Typea, <<"number">> => NewV,
                            <<"time">> => NewTime, <<"unit">> => Unit,
                            <<"imgurl">> => Ico, <<"devicetype">> => Devicetype}];
                    {error, _Reason} ->
                        Acc;
                    V ->
                        NewV = check_field(Typea, V, #{<<"datatype">> => DataType, <<"specs">> => Specs, <<"deviceid">> => DeviceId}),
                        Acc ++ [#{<<"identifier">> => Identifier, <<"name">> => Name,
                            <<"type">> => Typea, <<"number">> => NewV,
                            <<"time">> => NewTime, <<"unit">> => Unit,
                            <<"imgurl">> => Ico, <<"devicetype">> => Devicetype}]
                end;
            _ ->
                Acc
        end
                end, [], Props).

do_hook(Key, Args) ->
    case catch dgiot_hook:run_hook(Key, Args) of
        {'EXIT', Reason} ->
            {error, Reason};
        {error, not_find} ->
            ignore;
        {ok, []} ->
            ignore;
        {ok, [{error, Reason} | _]} ->
            {error, Reason};
        {ok, [Rtn | _]} ->
            Rtn
    end.

check_field(Typea, V, #{<<"specs">> := Specs}) when Typea == <<"enum">>; Typea == <<"bool">> ->
    maps:get(dgiot_utils:to_binary(V), Specs, V);

check_field(<<"struct">>, V, _) ->
    V;

check_field(<<"geopoint">>, V, #{<<"deviceid">> := DeviceId}) ->
    BinV = dgiot_utils:to_binary(V),
    case binary:split(BinV, <<$_>>, [global, trim]) of
        [Longitude, Latitude] ->
            case dgiot_gps:get_baidu_addr(Longitude, Latitude) of
                #{<<"baiduaddr">> := #{<<"formatted_address">> := FormattedAddress}} ->
                    case dgiot_parse:get_object(<<"Device">>, DeviceId) of
                        {ok, #{<<"location">> := #{<<"__type">> := <<"GeoPoint">>, <<"longitude">> := Longitude, <<"latitude">> := Latitude}}} ->
                            pass;
                        {ok, #{<<"detail">> := Detail}} ->
                            dgiot_parse:update_object(<<"Device">>, DeviceId, #{
                                <<"location">> => #{<<"__type">> => <<"GeoPoint">>, <<"longitude">> => Longitude, <<"latitude">> => Latitude},
                                <<"detail">> => Detail#{<<"address">> => FormattedAddress}});
                        _ ->
                            pass
                    end,
                    FormattedAddress;
                _ ->
                    <<"[", BinV/binary, "]经纬度解析错误"/utf8>>
            end;
        _ ->
            <<"无GPS信息"/utf8>>
    end;

check_field(Typea, V, #{<<"specs">> := Specs}) when Typea == <<"float">>; Typea == <<"double">> ->
    Precision = maps:get(<<"precision">>, Specs, 3),
    dgiot_utils:to_float(V, Precision);

check_field(<<"image">>, V, #{<<"datatype">> := DataType, <<"deviceid">> := DeviceId}) ->
    AppName = dgiot_device:get_appname(DeviceId),
    Url = dgiot_device:get_url(AppName),
    Imagevalue = maps:get(<<"imagevalue">>, DataType, <<"">>),
    BinV = dgiot_utils:to_binary(V),
    <<Url/binary, "/dgiot_file/", DeviceId/binary, "/", BinV/binary, ".", Imagevalue/binary>>;

check_field(<<"date">>, V, _) ->
    case V of
        <<"1970-01-01 08:00:00.000">> ->
            <<"--">>;
        _ ->
            V
    end;

check_field(_Typea, V, _) ->
    V.


%%get_app(ProductId, Results, DeviceId) ->
%%    Maps = get_prop(ProductId),
%%    Props = get_props(ProductId),
%%    lists:foldl(fun(R, _Acc) ->
%%        Time = maps:get(<<"createdat">>, R),
%%        NewTime = get_time(Time, <<"111">>),
%%        maps:fold(fun(K, V, Acc) ->
%%            case maps:find(K, Maps) of
%%                error ->
%%                    Acc;
%%                {ok, Name} ->
%%                    {Type, NewV, Unit, Ico, Devicetype} =
%%                        case maps:find(K, Props) of
%%                            error ->
%%                                {<<"">>, V, <<"">>, <<"">>, <<"others">>};
%%                            {ok, #{<<"dataType">> := #{<<"type">> := Typea} = DataType} = Prop} ->
%%                                Devicetype1 = maps:get(<<"devicetype">>, Prop, <<"others">>),
%%                                Specs = maps:get(<<"specs">>, DataType, #{}),
%%                                case Typea of
%%                                    Type1 when Type1 == <<"enum">>; Type1 == <<"bool">> ->
%%                                        Value = maps:get(dgiot_utils:to_binary(V), Specs, V),
%%                                        Ico1 = maps:get(<<"ico">>, Prop, <<"">>),
%%                                        {Type1, Value, <<"">>, Ico1, Devicetype1};
%%                                    Type2 when Type2 == <<"struct">> ->
%%                                        Ico1 = maps:get(<<"ico">>, Prop, <<"">>),
%%                                        {Type2, V, <<"">>, Ico1, Devicetype1};
%%                                    Type3 when Type3 == <<"geopoint">> ->
%%                                        Ico1 = maps:get(<<"ico">>, Prop, <<"">>),
%%                                        BinV = dgiot_utils:to_binary(V),
%%                                        Addr =
%%                                            case binary:split(BinV, <<$_>>, [global, trim]) of
%%                                                [Longitude, Latitude] ->
%%                                                    case dgiot_gps:get_baidu_addr(Longitude, Latitude) of
%%                                                        #{<<"baiduaddr">> := #{<<"formatted_address">> := FormattedAddress}} ->
%%                                                            case dgiot_parse:get_object(<<"Device">>, DeviceId) of
%%                                                                {ok, #{<<"location">> := #{<<"__type">> := <<"GeoPoint">>, <<"longitude">> := Longitude, <<"latitude">> := Latitude}}} ->
%%                                                                    pass;
%%                                                                {ok, #{<<"detail">> := Detail}} ->
%%                                                                    dgiot_parse:update_object(<<"Device">>, DeviceId, #{
%%                                                                        <<"location">> => #{<<"__type">> => <<"GeoPoint">>, <<"longitude">> => Longitude, <<"latitude">> => Latitude},
%%                                                                        <<"detail">> => Detail#{<<"address">> => FormattedAddress}});
%%                                                                _ ->
%%                                                                    pass
%%                                                            end,
%%                                                            FormattedAddress;
%%                                                        _ ->
%%                                                            <<"[", BinV/binary, "]经纬度解析错误"/utf8>>
%%                                                    end;
%%                                                _ ->
%%                                                    <<"无GPS信息"/utf8>>
%%                                            end,
%%                                        {Type3, Addr, <<"">>, Ico1, Devicetype1};
%%                                    Type4 when Type4 == <<"float">>; Type4 == <<"double">> ->
%%                                        Unit1 = maps:get(<<"unit">>, Specs, <<"">>),
%%                                        Precision = maps:get(<<"precision">>, Specs, 3),
%%                                        Ico1 = maps:get(<<"ico">>, Prop, <<"">>),
%%                                        {Type4, dgiot_utils:to_float(V, Precision), Unit1, Ico1, Devicetype1};
%%                                    Type5 when Type5 == <<"image">> ->
%%                                        AppName = dgiot_device:get_appname(DeviceId),
%%                                        Url = dgiot_device:get_url(AppName),
%%                                        Unit1 = maps:get(<<"unit">>, Specs, <<"">>),
%%                                        Ico1 = maps:get(<<"ico">>, Prop, <<"">>),
%%                                        Imagevalue = maps:get(<<"imagevalue">>, DataType, <<"">>),
%%                                        BinV = dgiot_utils:to_binary(V),
%%                                        {Type5, <<Url/binary, "/dgiot_file/", DeviceId/binary, "/", BinV/binary, ".", Imagevalue/binary>>, Unit1, Ico1, Devicetype1};
%%                                    Type6 when Type6 == <<"date">> ->
%%                                        V1 =
%%                                            case V of
%%                                                <<"1970-01-01 08:00:00.000">> ->
%%                                                    <<"--">>;
%%                                                _ ->
%%                                                    V
%%                                            end,
%%                                        Unit1 = maps:get(<<"unit">>, Specs, <<"">>),
%%                                        Ico1 = maps:get(<<"ico">>, Prop, <<"">>),
%%                                        {Type6, V1, Unit1, Ico1, Devicetype1};
%%                                    _ ->
%%                                        Unit1 = maps:get(<<"unit">>, Specs, <<"">>),
%%                                        Ico1 = maps:get(<<"ico">>, Prop, <<"">>),
%%                                        {Typea, V, Unit1, Ico1, Devicetype1}
%%                                end;
%%                            _ ->
%%                                {<<"others">>, V, <<"">>, <<"">>, <<"others">>}
%%                        end,
%%                    Acc ++ [#{<<"name">> => Name, <<"type">> => Type, <<"number">> => NewV, <<"time">> => NewTime, <<"unit">> => Unit, <<"imgurl">> => Ico, <<"devicetype">> => Devicetype}]
%%            end
%%                  end, [], R)
%%                end, [], Results).

get_time(V, Interval) ->
    NewV =
        case binary:split(V, <<$.>>, [global, trim]) of
            [NewV1, _] ->
                NewV1;
            _ ->
                V
        end,
    Size = erlang:size(Interval) - 1,
    <<_:Size/binary, Type/binary>> = Interval,
    case Type of
        <<"a">> ->
            NewV;
        <<"s">> ->
            dgiot_datetime:format(dgiot_datetime:to_localtime(NewV), <<"DD HH:NN:SS">>);
        <<"m">> ->
            dgiot_datetime:format(dgiot_datetime:to_localtime(NewV), <<"MM-DD HH:NN">>);
        <<"h">> ->
            dgiot_datetime:format(dgiot_datetime:to_localtime(NewV), <<"MM-DD HH">>);
        <<"d">> ->
            dgiot_datetime:format(dgiot_datetime:to_localtime(NewV), <<"YY-MM-DD">>);
        <<"y">> ->
            dgiot_datetime:format(dgiot_datetime:to_localtime(NewV), <<"YY">>);
        _ ->
            dgiot_datetime:format(dgiot_datetime:to_localtime(NewV), <<"YY-MM-DD HH:NN:SS">>)
    end.

do_channel(ProductId, Session, Fun) ->
    Body = #{
        <<"keys">> => <<"objectId">>,
        <<"order">> => <<"-createdAt">>,
        <<"limit">> => 1,
        <<"where">> => #{
            <<"cType">> => ?TYPE,
            <<"isEnable">> => true,
            <<"product">> => #{
                <<"__type">> => <<"Pointer">>,
                <<"className">> => <<"Product">>,
                <<"objectId">> => ProductId
            }
        }
    },
    case dgiot_parse:query_object(<<"Channel">>, Body, [{"X-Parse-Session-Token", Session}], [{from, rest}]) of
        {ok, #{<<"results">> := []}} ->
            {404, <<"not find channel">>};
        {ok, #{<<"results">> := [#{<<"objectId">> := ChannelId}]}} ->
            Fun(ChannelId);
        {error, Reason} ->
            {error, Reason}
    end.
