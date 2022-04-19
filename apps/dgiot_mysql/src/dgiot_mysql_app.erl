%%%-------------------------------------------------------------------
%% @doc dgiot_mysql public API
%% @end
%%%-------------------------------------------------------------------

-module(dgiot_mysql_app).
-include("dgiot_mysql.hrl").
-include_lib("dgiot/include/logger.hrl").

-emqx_plugin(?MODULE).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    dgiot_mysql_sup:start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================