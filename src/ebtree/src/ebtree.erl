% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
% http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(ebtree).

-export([
     open/3,
     open/4,
     min/0,
     max/0,
     insert/4,
     delete/3,
     lookup/3,
     range/6,
     reverse_range/6,
     fold/4,
     fold/5,
     reduce/4,
     full_reduce/2,
     group_reduce/7,
     group_reduce/8,
     validate_tree/2
]).

-record(node, {
    id,
    level = 0,
    prev,
    next,
    members = [] %% [{Key0, Value0} | {FirstKey0, LastKey0, Pointer0, Reduction0}, ...]
}).

-record(tree, {
    prefix,
    min,
    max,
    collate_fun,
    reduce_fun,
    encode_fun
}).

-define(META, 0).
-define(META_ORDER, 0).
-define(META_NEXT_ID, 1).

-define(NODE, 1).
-define(NODE_ROOT_ID, 0).

-define(underflow(Tree, Node), Tree#tree.min > length(Node#node.members)).
-define(at_min(Tree, Node), Tree#tree.min == length(Node#node.members)).
-define(is_full(Tree, Node), Tree#tree.max == length(Node#node.members)).

%% two special 1-bit bitstrings that cannot appear in valid keys.
-define(MIN, <<0:1>>).
-define(MAX, <<1:1>>).


%% @equiv open(Db, Prefix, Order, [])
-spec open(term(), binary(), pos_integer()) -> #tree{}.
open(Db, Prefix, Order) ->
    open(Db, Prefix, Order, []).


%% @doc Open a new ebtree, initialising it if doesn't already exist.
%% @param Db An erlfdb database or transaction.
%% @param Prefix The key prefix applied to all ebtree keys.
%% @param Order The maximum number of items allowed in an ebtree node (must be an even number). Ignored
%% if ebtree is already initialised.
%% @param Options Supported options are {reduce_fun, Fun} and {collate_fun, Fun}.
%% @returns A data structure representing the ebtree, to be passed to all other functions.
-spec open(term(), binary(), pos_integer(), list()) -> #tree{}.
open(Db, Prefix, Order, Options) when is_binary(Prefix), is_integer(Order), Order > 2, Order rem 2 == 0 ->
    ReduceFun = proplists:get_value(reduce_fun, Options, fun reduce_noop/2),
    CollateFun = proplists:get_value(collate_fun, Options, fun collate_raw/2),
    EncodeFun = proplists:get_value(encode_fun, Options, fun encode_erlang/3),

    Tree = #tree{
        prefix = Prefix,
        reduce_fun = ReduceFun,
        collate_fun = CollateFun,
        encode_fun = EncodeFun
    },

    erlfdb:transactional(Db, fun(Tx) ->
        case get_meta(Tx, Tree, ?META_ORDER) of
            not_found ->
                erlfdb:clear_range_startswith(Tx, Prefix),
                set_meta(Tx, Tree, ?META_ORDER, Order),
                set_meta(Tx, Tree, ?META_NEXT_ID, 1),
                set_node(Tx, Tree, #node{id = ?NODE_ROOT_ID}),
                init_order(Tree, Order);
            ActualOrder when is_integer(ActualOrder) ->
                init_order(Tree, ActualOrder)
        end
    end).


%% @doc a special value guaranteed to be smaller than any value in an ebtree.
min() ->
    ?MIN.


%% @doc a special value guaranteed to be larger than any value in an ebtree.
max() ->
    ?MAX.

%% @doc Lookup a specific key in the ebtree.
%% @param Db An erlfdb database or transaction.
%% @param Tree the ebtree.
%% @param Key the key to lookup
%% @returns A key-value tuple if found, false if not present in the ebtree.
-spec lookup(Db :: term(), Tree :: #tree{}, Key :: term()) ->
    {Key :: term(), Value :: term()} | false.
lookup(Db, #tree{} = Tree, Key) ->
    Fun = fun
        ({visit, K, V}, _Acc) when K =:= Key ->
            {stop, {K, V}};
        ({visit, K, _V}, Acc) ->
            case greater_than(Tree, K, Key) of
                true ->
                    {stop, Acc};
                false ->
                    {ok, Acc}
            end;
        ({traverse, F, L, _R}, Acc) ->
            case {greater_than(Tree, F, Key), less_than_or_equal(Tree, Key, L)} of
                {true, _} ->
                    {stop, Acc};
                {false, true} ->
                    {ok, Acc};
                {false, false} ->
                    {skip, Acc}
            end
    end,
    fold(Db, Tree, Fun, false, []).


%% @equiv fold(Db, Tree, Fun, Acc, [])
fold(Db, #tree{} = Tree, Fun, Acc) ->
    fold(Db, Tree, Fun, Acc, []).


%% @doc Custom traversal of the ebtree.
%% @param Db An erlfdb database or transaction.
%% @param Tree the ebtree.
%% @param Fun A callback function as nodes are loaded that directs the traversal.
%% @param Acc The initial accumulator.
%% @param Options Options that control how the fold is executed.
%% @returns the final accumulator.

-type fold_args() ::
    {visit, Key :: term(), Value :: term()} |
    {traverse, First :: term(), Last :: term(), Reduction :: term()}.

-type fold_option() :: [{dir, fwd | rev}].

-spec fold(Db, Tree, Fun, Acc0, Options) -> Acc1 when
    Db :: term(),
    Tree :: #tree{},
    Fun :: fun((fold_args(), Acc0) -> {ok | skip | stop, Acc1}),
    Acc0 :: term(),
    Options :: [fold_option()],
    Acc1 :: term().
fold(Db, #tree{} = Tree, Fun, Acc, Options) ->
    {_, Reduce} = erlfdb:transactional(Db, fun(Tx) ->
        Root = get_node(Tx, Tree, ?NODE_ROOT_ID),
        fold(Db, Tree, Root, Fun, Acc, Options)
    end),
    Reduce.


fold(Db, #tree{} = Tree, #node{} = Node, Fun, Acc, Options) ->
    Dir = proplists:get_value(dir, Options, fwd),
    Members = case Dir of
        fwd -> Node#node.members;
        rev -> lists:reverse(Node#node.members)
    end,
    fold(Db, #tree{} = Tree, Members, Fun, Acc, Options);


fold(_Db, #tree{} = _Tree, [], _Fun, Acc, _Options) ->
    {ok, Acc};

fold(Db, #tree{} = Tree, [{K, V} | Rest], Fun, Acc0, Options) ->
    case Fun({visit, K, V}, Acc0) of
        {ok, Acc1} ->
            fold(Db, Tree, Rest, Fun, Acc1, Options);
        {stop, Acc1} ->
            {stop, Acc1}
    end;

fold(Db, #tree{} = Tree, [{F, L, P, R} | Rest], Fun, Acc0, Options) ->
    case Fun({traverse, F, L, R}, Acc0) of
        {ok, Acc1} ->
            Node = get_node(Db, Tree, P),
            case fold(Db, Tree, Node, Fun, Acc1, Options) of
                {ok, Acc2} ->
                    fold(Db, Tree, Rest, Fun, Acc2, Options);
                {stop, Acc2} ->
                    {stop, Acc2}
            end;
        {skip, Acc1} ->
            fold(Db, Tree, Rest, Fun, Acc1, Options);
        {stop, Acc1} ->
            {stop, Acc1}
    end.


%% @doc Calculate the final reduce value for the whole ebtree.
%% @param Db An erlfdb database or transaction.
%% @param Tree the ebtree.
%% @returns the final reduce value
-spec full_reduce(Db :: term(), Tree :: #tree{}) -> term().
full_reduce(Db, #tree{} = Tree) ->
    Fun = fun
        ({visit, K, V}, {MapAcc, ReduceAcc}) ->
            {ok, {[{K, V} | MapAcc], ReduceAcc}};
        ({traverse, _F, _L, R}, {MapAcc, ReduceAcc}) ->
            {skip, {MapAcc, [R | ReduceAcc]}}
    end,
    {MapValues, ReduceValues} = fold(Db, Tree, Fun, {[], []}, []),
    do_reduce(Tree, MapValues, ReduceValues).


%% @doc Calculate the reduce value for all keys in the specified range.
%% @param Db An erlfdb database or transaction.
%% @param Tree The ebtree.
%% @param StartKey The beginning of the range
%% @param EndKey The end of the range
%% @returns the reduce value for the specified range
-spec reduce(Db :: term(), Tree :: #tree{}, StartKey :: term(), EndKey :: term()) -> term().
reduce(Db, #tree{} = Tree, StartKey, EndKey) ->
    Fun = fun
        ({visit, Key, Value}, {MapAcc, ReduceAcc}) ->
            BeforeStart = less_than(Tree, Key, StartKey),
            AfterEnd = greater_than(Tree, Key, EndKey),
            InRange = greater_than_or_equal(Tree, Key, StartKey) andalso less_than_or_equal(Tree, Key, EndKey),
            if
                BeforeStart ->
                    {ok, {MapAcc, ReduceAcc}};
                AfterEnd ->
                    {stop, {MapAcc, ReduceAcc}};
                InRange ->
                     {ok, {[{Key, Value} | MapAcc], ReduceAcc}}
            end;
        ({traverse, FirstKey, LastKey, Reduction}, {MapAcc, ReduceAcc}) ->
            BeforeStart = less_than(Tree, LastKey, StartKey),
            AfterEnd = greater_than(Tree, FirstKey, EndKey),
            Whole = greater_than_or_equal(Tree, FirstKey, StartKey) andalso less_than_or_equal(Tree, LastKey, EndKey),
            if
                BeforeStart ->
                    {skip, {MapAcc, ReduceAcc}};
                AfterEnd ->
                    {stop, {MapAcc, ReduceAcc}};
                Whole ->
                    {skip, {MapAcc, [Reduction | ReduceAcc]}};
                true ->
                    {ok, {MapAcc, ReduceAcc}}
            end
    end,
    {MapValues, ReduceValues} = fold(Db, Tree, Fun, {[], []}, []),
    do_reduce(Tree, MapValues, ReduceValues).


do_reduce(#tree{} = Tree, [], ReduceValues) when is_list(ReduceValues) ->
    reduce_values(Tree, ReduceValues, true);

do_reduce(#tree{} = Tree, MapValues, ReduceValues) when is_list(MapValues), is_list(ReduceValues) ->
    do_reduce(Tree, [], [reduce_values(Tree, MapValues, false) | ReduceValues]).


%% @equiv group_reduce(Db, Tree, StartKey, EndKey, GroupKeyFun, UserAccFun, UserAcc0, [])
-spec group_reduce(
    Db :: term(),
    Tree :: #tree{},
    StartKey :: term(),
    EndKey :: term(),
    GroupKeyFun :: fun((term()) -> group_key()),
    UserAccFun :: fun(({group_key(), GroupValue :: term()}, Acc0 :: term()) -> Acc1 :: term()),
    UserAcc0 :: term()) -> Acc1 :: term().
group_reduce(Db, #tree{} = Tree, StartKey, EndKey, GroupKeyFun, UserAccFun, UserAcc0) ->
    group_reduce(Db, Tree, StartKey, EndKey, GroupKeyFun, UserAccFun, UserAcc0, []).


%% @doc Calculate the reduce value for all groups in the specified range.
%% @param Db An erlfdb database or transaction.
%% @param Tree The ebtree.
%% @param StartKey The beginning of the range
%% @param EndKey The end of the range
%% @param GroupKeyFun A function that takes a key as a parameter and returns the group key.
%% @param UserAccFun A function called when a new group reduction is calculated and returns an acc.
%% @param UserAcc0 The initial accumulator.
%% @param Options Currently supported options are [{dir, fwd}] and [{dir, rev}]
%% @returns the final accumulator.
-type group_key() :: term().

-spec group_reduce(
    Db :: term(),
    Tree :: #tree{},
    StartKey :: term(),
    EndKey :: term(),
    GroupKeyFun :: fun((term()) -> group_key()),
    UserAccFun :: fun(({group_key(), GroupValue :: term()}, Acc0 :: term()) -> Acc1 :: term()),
    UserAcc0 :: term(),
    Options :: [fold_option()]) -> Acc1 :: term().
group_reduce(Db, #tree{} = Tree, StartKey, EndKey, GroupKeyFun, UserAccFun, UserAcc0, Options) ->
    Dir = proplists:get_value(dir, Options, fwd),
    NoGroupYet = ?MIN,
    Fun = fun
        ({visit, Key, Value}, {CurrentGroup, UserAcc, MapAcc, ReduceAcc}) ->
            BeforeStart = less_than(Tree, Key, StartKey),
            AfterEnd = greater_than(Tree, Key, EndKey),
            InRange = in_range(Tree, StartKey, Key, EndKey),
            KeyGroup = GroupKeyFun(Key),
            SameGroup = CurrentGroup =:= KeyGroup,
            if
                Dir == fwd andalso BeforeStart ->
                    {ok, {CurrentGroup, UserAcc, MapAcc, ReduceAcc}};
                Dir == rev andalso AfterEnd ->
                    {ok, {CurrentGroup, UserAcc, MapAcc, ReduceAcc}};
                Dir == fwd andalso AfterEnd ->
                    {stop, {CurrentGroup, UserAcc, MapAcc, ReduceAcc}};
                Dir == rev andalso BeforeStart ->
                    {stop, {CurrentGroup, UserAcc, MapAcc, ReduceAcc}};
                SameGroup ->
                    {ok, {CurrentGroup, UserAcc, [{Key, Value} | MapAcc], ReduceAcc}};
                InRange andalso CurrentGroup =:= NoGroupYet ->
                    {ok, {KeyGroup, UserAcc, [{Key, Value}], []}};
                InRange ->
                    %% implicit end of current group and start of a new one
                    GroupValue = do_reduce(Tree, MapAcc, ReduceAcc),
                    {ok, {KeyGroup, UserAccFun({CurrentGroup, GroupValue}, UserAcc), [{Key, Value}], []}}
            end;
        ({traverse, FirstKey, LastKey, Reduction}, {CurrentGroup, UserAcc, MapAcc, ReduceAcc}) ->
            BeforeStart = less_than(Tree, LastKey, StartKey),
            AfterEnd = greater_than(Tree, FirstKey, EndKey),
            Whole = CurrentGroup =:= GroupKeyFun(FirstKey) andalso CurrentGroup =:= GroupKeyFun(LastKey),
            FirstInRange = in_range(Tree, StartKey, FirstKey, EndKey),
            LastInRange = in_range(Tree, StartKey, LastKey, EndKey),
            if
                Dir == fwd andalso BeforeStart ->
                    {skip, {CurrentGroup, UserAcc, MapAcc, ReduceAcc}};
                Dir == rev andalso AfterEnd ->
                    {skip, {CurrentGroup, UserAcc, MapAcc, ReduceAcc}};
                Dir == fwd andalso AfterEnd ->
                    {stop, {CurrentGroup, UserAcc, MapAcc, ReduceAcc}};
                Dir == rev andalso BeforeStart ->
                    {stop, {CurrentGroup, UserAcc, MapAcc, ReduceAcc}};
                Whole andalso FirstInRange andalso LastInRange ->
                    {skip, {CurrentGroup, UserAcc, MapAcc, [Reduction | ReduceAcc]}};
                true ->
                    {ok, {CurrentGroup, UserAcc, MapAcc, ReduceAcc}}
            end
    end,
    {CurrentGroup, UserAcc1, MapValues, ReduceValues} = fold(Db, Tree, Fun, {NoGroupYet, UserAcc0, [], []}, Options),
    if
        MapValues /= [] orelse ReduceValues /= [] ->
            FinalGroup = do_reduce(Tree, MapValues, ReduceValues),
            UserAccFun({CurrentGroup, FinalGroup}, UserAcc1);
        true ->
            UserAcc1
    end.


%% @doc Finds all key-value pairs for the specified range in forward order.
%% @param Db An erlfdb database or transaction.
%% @param Tree The ebtree.
%% @param StartKey The beginning of the range
%% @param EndKey The end of the range
%% @param AccFun A function that is called when a key-value pair is found, returning an accumulator.
%% @param Acc0 The initial accumulator
%% @returns the final accumulator
-spec range(Db :: term(), Tree :: #tree{}, StartKey :: term(), EndKey :: term(),
    AccFun :: fun(), Acc0 :: term()) -> term().
range(Db, #tree{} = Tree, StartKey, EndKey, AccFun, Acc0) ->
    erlfdb:transactional(Db, fun(Tx) ->
        range(Tx, Tree, get_node(Tx, Tree, ?NODE_ROOT_ID), StartKey, EndKey, AccFun, Acc0)
    end).


range(Tx, #tree{} = Tree, #node{level = 0} = Node, StartKey, EndKey, AccFun, Acc0) ->
    InRange = [{K, V} || {K, V} <- Node#node.members,
        less_than_or_equal(Tree, StartKey, K), less_than_or_equal(Tree, K, EndKey)],
    Acc1 = AccFun(InRange, Acc0),
    LastKey = last_key(Node),
    case Node#node.next /= undefined andalso less_than_or_equal(Tree, LastKey, EndKey) of
        true ->
            range(Tx, Tree, get_node(Tx, Tree, Node#node.next), StartKey, EndKey, AccFun, Acc1);
        false ->
            Acc1
    end;

range(Tx, #tree{} = Tree, #node{} = Node, StartKey, EndKey, AccFun, Acc) ->
    ChildId = find_child_id(Tree, Node, StartKey),
    range(Tx, Tree, get_node(Tx, Tree, ChildId), StartKey, EndKey, AccFun, Acc).


%% @doc Finds all key-value pairs for the specified range in reverse order.
%% @param Db An erlfdb database or transaction.
%% @param Tree The ebtree.
%% @param StartKey The beginning of the range
%% @param EndKey The end of the range
%% @param AccFun A function that is called when a key-value pair is found, returning an accumulator.
%% @param Acc0 The initial accumulator
%% @returns the final accumulator
-spec reverse_range(Db :: term(), Tree :: #tree{}, StartKey :: term(), EndKey :: term(),
    AccFun :: fun(), Acc0 :: term()) -> term().
reverse_range(Db, #tree{} = Tree, StartKey, EndKey, AccFun, Acc0) ->
    erlfdb:transactional(Db, fun(Tx) ->
        reverse_range(Tx, Tree, get_node(Tx, Tree, ?NODE_ROOT_ID), StartKey, EndKey, AccFun, Acc0)
    end).


reverse_range(Tx, #tree{} = Tree, #node{level = 0} = Node, StartKey, EndKey, AccFun, Acc0) ->
    InRange = [{K, V} || {K, V} <- Node#node.members,
        less_than_or_equal(Tree, StartKey, K), less_than_or_equal(Tree, K, EndKey)],
    Acc1 = AccFun(lists:reverse(InRange), Acc0),
    FirstKey = first_key(Node),
    case Node#node.prev /= undefined andalso less_than_or_equal(Tree, StartKey, FirstKey) of
        true ->
            reverse_range(Tx, Tree, get_node(Tx, Tree, Node#node.prev), StartKey, EndKey, AccFun, Acc1);
        false ->
            Acc1
    end;

reverse_range(Tx, #tree{} = Tree, #node{} = Node, StartKey, EndKey, AccFun, Acc) ->
    ChildId = find_child_id(Tree, Node, EndKey),
    reverse_range(Tx, Tree, get_node(Tx, Tree, ChildId), StartKey, EndKey, AccFun, Acc).


%% @doc Inserts or updates a value in the ebtree
%% @param Db An erlfdb database or transaction.
%% @param Tree The ebtree.
%% @param Key The key to store the value under.
%% @param Value The value to store.
%% @returns the tree.
-spec insert(Db :: term(), Tree :: #tree{}, Key :: term(), Value :: term()) -> #tree{}.
insert(_Db, #tree{} = _Tree, ?MIN, _Value) ->
    erlang:error(min_not_allowed);

insert(_Db, #tree{} = _Tree, ?MAX, _Value) ->
    erlang:error(max_not_allowed);

insert(Db, #tree{} = Tree, Key, Value) ->
    erlfdb:transactional(Db, fun(Tx) ->
        Root0 = get_node(Tx, Tree, ?NODE_ROOT_ID),
        case ?is_full(Tree, Root0) of
            true ->
                OldRoot = Root0#node{id = new_node_id(Tx, Tree)},
                FirstKey = first_key(OldRoot),
                LastKey = last_key(OldRoot),
                Root1 = #node{
                    id = ?NODE_ROOT_ID,
                    level = Root0#node.level + 1,
                    members = [{FirstKey, LastKey, OldRoot#node.id, []}]},
                {Root2, _, _} = split_child(Tx, Tree, Root1, OldRoot),
                insert_nonfull(Tx, Tree, Root2, Key, Value);
            false ->
                insert_nonfull(Tx, Tree, Root0, Key, Value)
        end
    end),
    Tree.


split_child(Tx, #tree{} = Tree, #node{} = Parent0, #node{} = Child) ->
    {LeftMembers, RightMembers} = lists:split(Tree#tree.min, Child#node.members),

    LeftId = new_node_id(Tx, Tree),
    RightId = new_node_id(Tx, Tree),

    LeftChild = remove_pointers_if_not_leaf(#node{
        id = LeftId,
        level = Child#node.level,
        prev = Child#node.prev,
        next = RightId,
        members = LeftMembers
    }),

    RightChild = remove_pointers_if_not_leaf(#node{
        id = RightId,
        level = Child#node.level,
        prev = LeftId,
        next = Child#node.next,
        members = RightMembers
    }),

    update_prev_neighbour(Tx, Tree, LeftChild),
    update_next_neighbour(Tx, Tree, RightChild),

    %% adjust parent members
    FirstLeftKey = first_key(LeftMembers),
    LastLeftKey = last_key(LeftMembers),
    FirstRightKey = first_key(RightMembers),
    LastRightKey = last_key(RightMembers),

    %% adjust parent reductions
    LeftReduction = reduce_node(Tree, LeftChild),
    RightReduction = reduce_node(Tree, RightChild),

    Parent1 = Parent0#node{
        members =
            umerge_members(Tree, [{FirstLeftKey, LastLeftKey, LeftId, LeftReduction}],
                umerge_members(Tree, [{FirstRightKey, LastRightKey, RightId, RightReduction}],
                    lists:keydelete(Child#node.id, 3, Parent0#node.members)))
    },
    clear_node(Tx, Tree, Child),
    set_nodes(Tx, Tree, [LeftChild, RightChild, Parent1]),
    {Parent1, LeftChild, RightChild}.


update_prev_neighbour(_Tx, #tree{} = _Tree, #node{prev = undefined} = _Node) ->
    ok;

update_prev_neighbour(Tx, #tree{} = Tree, #node{} = Node) ->
    Left = get_node(Tx, Tree, Node#node.prev),
    set_node(Tx, Tree, Left#node{next = Node#node.id}).


update_next_neighbour(_Tx, #tree{} = _Tree, #node{next = undefined} = _Node) ->
    ok;

update_next_neighbour(Tx, #tree{} = Tree, #node{} = Node) ->
    Left = get_node(Tx, Tree, Node#node.next),
    set_node(Tx, Tree, Left#node{prev = Node#node.id}).


insert_nonfull(Tx, #tree{} = Tree, #node{level = 0} = Node0, Key, Value) ->
    Node1 = Node0#node{
        members = umerge_members(Tree, [{Key, Value}], Node0#node.members)
    },
    set_node(Tx, Tree, Node0, Node1),
    reduce_node(Tree, Node1);

insert_nonfull(Tx, #tree{} = Tree, #node{} = Node0, Key, Value) ->
    ChildId0 = find_child_id(Tree, Node0, Key),
    Child0 = get_node(Tx, Tree, ChildId0),
    {Node1, Child1} = case ?is_full(Tree, Child0) of
        true ->
            {Parent, LeftChild, RightChild} = split_child(Tx, Tree, Node0, Child0),
            ChildId = find_child_id(Tree, Parent, Key),
            Child = if
                ChildId =:= LeftChild#node.id ->
                    LeftChild;
                ChildId =:= RightChild#node.id ->
                    RightChild
            end,
            {Parent, Child};
        false ->
            {Node0, Child0}
    end,
    ChildId1 = Child1#node.id,
    NewReduction = insert_nonfull(Tx, Tree, Child1, Key, Value),
    {CurrentFirstKey, CurrentLastKey, ChildId1, _OldReduction} = lists:keyfind(ChildId1, 3, Node1#node.members),
    [NewFirstKey, _] = sort_keys(Tree, [Key, CurrentFirstKey]),
    [_, NewLastKey] = sort_keys(Tree, [Key, CurrentLastKey]),
    Node2 = Node1#node{
        members = lists:keyreplace(ChildId1, 3, Node1#node.members,
            {NewFirstKey, NewLastKey, ChildId1, NewReduction})
    },
    set_node(Tx, Tree, Node0, Node2),
    reduce_node(Tree, Node2).


%% @doc Deletes an entry from the ebtree
%% @param Db An erlfdb database or transaction.
%% @param Tree The ebtree.
%% @param Key The key of the entry to delete.
%% @returns the tree.
-spec delete(Db :: term(), Tree :: #tree{}, Key :: term()) -> #tree{}.
delete(Db, #tree{} = Tree, Key) ->
    erlfdb:transactional(Db, fun(Tx) ->
        Root0 = get_node(Tx, Tree, ?NODE_ROOT_ID),
        case delete(Tx, Tree, Root0, Key) of
            % if only one child, make it the new root.
            #node{level = L, members = [_]} = Root1 when L > 0 ->
                [{_, _, ChildId, _}] = Root1#node.members,
                Root2 = get_node(Tx, Tree, ChildId),
                clear_node(Tx, Tree, Root2),
                set_node(Tx, Tree, Root2#node{id = ?NODE_ROOT_ID});
            Root1 ->
                set_node(Tx, Tree, Root0, Root1)
        end
    end),
    Tree.


delete(_Tx, #tree{} = _Tree, #node{level = 0} = Node, Key) ->
    Node#node{
        members = lists:keydelete(Key, 1, Node#node.members)
    };

delete(Tx, #tree{} = Tree, #node{} = Parent0, Key) ->
    ChildId0 = find_child_id(Tree, Parent0, Key),
    Child0 = get_node(Tx, Tree, ChildId0),
    Child1 = delete(Tx, Tree, Child0, Key),
    case ?underflow(Tree, Child1) of
        true ->
            SiblingId = find_sibling_id(Tree, Parent0, ChildId0, Key),
            Sibling = get_node(Tx, Tree, SiblingId),
            NewNodes = case ?at_min(Tree, Sibling) of
                true ->
                    Merged = merge(Tx, Tree, Child1, Sibling),
                    update_prev_neighbour(Tx, Tree, Merged),
                    update_next_neighbour(Tx, Tree, Merged),
                    [Merged];
                false ->
                    {Left, Right} = rebalance(Tx, Tree, Child1, Sibling),
                    update_prev_neighbour(Tx, Tree, Left),
                    update_next_neighbour(Tx, Tree, Right),
                    [Left, Right]
            end,

            %% remove old members and insert new members
            Members0 = Parent0#node.members,
            Members1 = lists:keydelete(ChildId0, 3, Members0),
            Members2 = lists:keydelete(Sibling#node.id, 3, Members1),
            Members3 = lists:foldl(fun(N, Acc) ->
                umerge_members(Tree, [{first_key(N), last_key(N), N#node.id, reduce_node(Tree, N)}], Acc)
            end, Members2, NewNodes),

            Parent1 = Parent0#node{
                %% TODO change id
                members = Members3
            },

            clear_nodes(Tx, Tree, [Child0, Sibling]),
            set_nodes(Tx, Tree, NewNodes),
            Parent1;
        false ->
            set_node(Tx, Tree, Child0, Child1),
            {_OldFirstKey, _OldLastKey, ChildId0, _OldReduction} = lists:keyfind(ChildId0, 3, Parent0#node.members),
            Parent0#node{
                members = lists:keyreplace(ChildId0, 3, Parent0#node.members,
                    {first_key(Child1), last_key(Child1), Child1#node.id, reduce_node(Tree, Child1)})
            }
    end.


merge(Tx, #tree{} = Tree, #node{level = Level} = Node1, #node{level = Level} = Node2) ->
    [Left, Right] = sort_nodes(Tree, [Node1, Node2]),

    #node{
        id = new_node_id(Tx, Tree),
        level = Level,
        prev = Left#node.prev,
        next = Right#node.next,
        members = lists:append(Left#node.members, Right#node.members)
    }.


rebalance(Tx, #tree{} = Tree, #node{level = Level} = Node1, #node{level = Level} = Node2) ->
    [Left0, Right0] = sort_nodes(Tree, [Node1, Node2]),

    Members = lists:append(Left0#node.members, Right0#node.members),
    {LeftMembers, RightMembers} = lists:split(length(Members) div 2, Members),

    Left1Id = new_node_id(Tx, Tree),
    Right1Id = new_node_id(Tx, Tree),

    Left1 = remove_pointers_if_not_leaf(Left0#node{
        id = Left1Id,
        next = Right1Id,
        members = LeftMembers
    }),
    Right1 = remove_pointers_if_not_leaf(Right0#node{
        id = Right1Id,
        prev = Left1Id,
        members = RightMembers
    }),
    {Left1, Right1}.


%% lookup functions

find_child_id(#tree{} = Tree, #node{} = Node, Key) ->
    element(3, find_child(Tree, Node, Key)).


find_sibling_id(#tree{} = Tree, #node{level = L} = Node0, Id, Key) when L > 0 ->
    Node1 = Node0#node{members = lists:keydelete(Id, 3, Node0#node.members)},
    find_child_id(Tree, Node1, Key).


find_child(#tree{} = Tree, #node{level = L} = Node, Key) when L > 0 ->
    find_child_int(Tree, Node#node.members, Key).


find_child_int(#tree{} = _Tree, [Child], _Key) ->
    Child;

find_child_int(#tree{} = Tree, [{_F, L, _P, _R} = Child| Rest], Key) ->
    case less_than_or_equal(Tree, Key, L) of
        true ->
            Child;
        false ->
            find_child_int(Tree, Rest, Key)
    end.


%% metadata functions

get_meta(Tx, #tree{} = Tree, MetaKey) ->
    #tree{prefix = Prefix, encode_fun = EncodeFun} = Tree,
    Key = meta_key(Prefix, MetaKey),
    Future = erlfdb:get(Tx, Key),
    case erlfdb:wait(Future) of
        not_found ->
            not_found;
        Bin when is_binary(Bin) ->
            EncodeFun(decode, Key, Bin)
    end.


set_meta(Tx, #tree{} = Tree, MetaKey, MetaValue) ->
    #tree{prefix = Prefix, encode_fun = EncodeFun} = Tree,
    Key = meta_key(Prefix, MetaKey),
    erlfdb:set(
        Tx,
        Key,
        EncodeFun(encode, Key, MetaValue)
    ).


meta_key(Prefix, MetaKey) when is_binary(Prefix) ->
    erlfdb_tuple:pack({?META, MetaKey}, Prefix).

%% node persistence functions

get_node(Tx, #tree{} = Tree, Id) ->
    Key = node_key(Tree#tree.prefix, Id),
    Future = erlfdb:get(Tx, Key),
    Value = erlfdb:wait(Future),
    decode_node(Tree, Id, Key, Value).


clear_nodes(Tx, #tree{} = Tree, Nodes) ->
    lists:foreach(fun(Node) ->
        clear_node(Tx, Tree, Node)
    end, Nodes).


clear_node(Tx, #tree{} = Tree, #node{} = Node) ->
     Key = node_key(Tree#tree.prefix, Node#node.id),
     erlfdb:clear(Tx, Key).


set_nodes(Tx, #tree{} = Tree, Nodes) ->
    lists:foreach(fun(Node) ->
        set_node(Tx, Tree, Node)
    end, Nodes).


set_node(_Tx, #tree{} = _Tree, #node{} = Same, #node{} = Same) ->
    ok;

set_node(Tx, #tree{} = Tree, #node{} = _From, #node{} = To) ->
    set_node(Tx, Tree, To).


set_node(Tx, #tree{} = Tree, #node{} = Node) ->
    validate_node(Tree, Node),
    Key = node_key(Tree#tree.prefix, Node#node.id),
    Value = encode_node(Tree, Key, Node),
    erlfdb:set(Tx, Key, Value).


node_key(Prefix, Id) when is_binary(Prefix), is_integer(Id) ->
    erlfdb_tuple:pack({?NODE, Id}, Prefix).


%% @doc Walks the whole tree and checks it for consistency.
%% It also prints it to screen.
validate_tree(Db, #tree{} = Tree) ->
    erlfdb:transactional(Db, fun(Tx) ->
        Root = get_node(Db, Tree, ?NODE_ROOT_ID),
        validate_tree(Tx, Tree, Root)
    end).


validate_tree(_Tx, #tree{} = Tree, #node{level = 0} = Node) ->
    print_node(Node),
    validate_node(Tree, Node);

validate_tree(Tx, #tree{} = Tree, #node{} = Node) ->
    print_node(Node),
    validate_node(Tree, Node),
    validate_tree(Tx, Tree, Node#node.members);

validate_tree(_Tx, #tree{} = _Tree, []) ->
    ok;

validate_tree(Tx, #tree{} = Tree, [{_F, _L, P, _R} | Rest]) ->
    Node = get_node(Tx, Tree, P),
    validate_tree(Tx, Tree, Node),
    validate_tree(Tx, Tree, Rest).


validate_node(#tree{} = Tree, #node{} = Node) ->
    NumKeys = length(Node#node.members),
    IsLeaf = Node#node.level =:= 0,
    IsRoot = ?NODE_ROOT_ID == Node#node.id,
    OutOfOrder = Node#node.members /= sort_members(Tree, Node#node.members),
    Duplicates = Node#node.members /= usort_members(Tree, Node#node.members),
    if
        Node#node.id == undefined ->
            erlang:error({node_without_id, Node});
        not IsRoot andalso NumKeys < Tree#tree.min ->
            erlang:error({too_few_keys, Node});
        NumKeys > Tree#tree.max ->
            erlang:error({too_many_keys, Node});
        not IsLeaf andalso Node#node.prev /= undefined ->
            erlang:error({non_leaf_with_prev, Node});
        not IsLeaf andalso Node#node.next /= undefined ->
            erlang:error({non_leaf_with_next, Node});
        OutOfOrder ->
            erlang:error({out_of_order, Node});
        Duplicates ->
            erlang:error({duplicates, Node});
        true ->
            ok
    end.


%% data marshalling functions (encodes unnecesary fields as a NIL_REF)

encode_node(#tree{} = Tree, Key, #node{prev = undefined} = Node) ->
    encode_node(Tree, Key, Node#node{prev = []});

encode_node(#tree{} = Tree, Key, #node{next = undefined} = Node) ->
    encode_node(Tree, Key, Node#node{next = []});

encode_node(#tree{} = Tree, Key, #node{} = Node) ->
    #tree{encode_fun = EncodeFun} = Tree,
    EncodeFun(encode, Key, Node#node{id = []}).


decode_node(#tree{} = Tree, Id, Key, Value) when is_binary(Value) ->
    #tree{encode_fun = EncodeFun} = Tree,
    Term = EncodeFun(decode, Key, Value),
    decode_node(Id, Term).


decode_node(Id, #node{prev = []} = Node) ->
    decode_node(Id, Node#node{prev = undefined});

decode_node(Id, #node{next = []} = Node) ->
    decode_node(Id, Node#node{next = undefined});

decode_node(Id, #node{} = Node) ->
    Node#node{id = Id}.

%% built-in reduce functions.

reduce_noop(_KVs, _Rereduce) ->
    [].


reduce_node(#tree{} = Tree, #node{level = 0} = Node) ->
    reduce_values(Tree, Node#node.members, false);

reduce_node(#tree{} = Tree, #node{} = Node) ->
    Rs = [R || {_F, _L, _P, R} <- Node#node.members],
    reduce_values(Tree, Rs, true).


reduce_values(#tree{} = Tree, Values, Rereduce) when is_list(Values) ->
    #tree{reduce_fun = ReduceFun} = Tree,
    ReduceFun(Values, Rereduce).


%% collation functions

in_range(#tree{} = Tree, StartOfRange, Key, EndOfRange) ->
    greater_than_or_equal(Tree, Key, StartOfRange) andalso less_than_or_equal(Tree, Key, EndOfRange).


greater_than(#tree{} = Tree, A, B) ->
    not less_than_or_equal(Tree, A, B).


greater_than_or_equal(#tree{} = _Tree, A, A) ->
    true;

greater_than_or_equal(#tree{} = Tree, A, B) ->
    greater_than(Tree, A, B).


less_than(#tree{} = _Tree, A, A) ->
    false;

less_than(#tree{} = Tree, A, B) ->
    less_than_or_equal(Tree, A, B).


less_than_or_equal(#tree{} = _Tree, ?MIN, _B) ->
    true;

less_than_or_equal(#tree{} = _Tree, _A, ?MIN) ->
    false;

less_than_or_equal(#tree{} = _Tree, ?MAX, _B) ->
    false;

less_than_or_equal(#tree{} = _Tree, _A, ?MAX) ->
    true;

less_than_or_equal(#tree{} = Tree, A, B) ->
    #tree{collate_fun = CollateFun} = Tree,
    CollateFun(A, B).


umerge_members(#tree{} = Tree, List1, List2) ->
    #tree{collate_fun = CollateFun} = Tree,
    CollateWrapper = fun
        ({K1, _V1}, {K2, _V2}) ->
            CollateFun(K1, K2);
        ({_F1, L1, _V1, _R1}, {_F2, L2, _V2, _R2}) ->
            CollateFun(L1, L2)
    end,
    lists:umerge(CollateWrapper, List1, List2).


sort_keys(#tree{} = Tree, List) ->
    #tree{collate_fun = CollateFun} = Tree,
    lists:sort(CollateFun, List).


sort_nodes(#tree{} = Tree, List) ->
    #tree{collate_fun = CollateFun} = Tree,
    CollateWrapper = fun
        (#node{} = N1, #node{} = N2) ->
            CollateFun(first_key(N1), first_key(N2))
    end,
    lists:sort(CollateWrapper, List).


sort_members(#tree{} = Tree, List) ->
    #tree{collate_fun = CollateFun} = Tree,
    CollateWrapper = fun
        ({K1, _V1}, {K2, _V2}) ->
            CollateFun(K1, K2);
        ({_F1, L1, _V1, _R1}, {_F2, L2, _V2, _R2}) ->
            CollateFun(L1, L2)
    end,
    lists:sort(CollateWrapper, List).


usort_members(#tree{} = Tree, List) ->
    #tree{collate_fun = CollateFun} = Tree,
    CollateWrapper = fun
        ({K1, _V1}, {K2, _V2}) ->
            CollateFun(K1, K2);
        ({_F1, L1, _V1, _R1}, {_F2, L2, _V2, _R2}) ->
            CollateFun(L1, L2)
    end,
    lists:usort(CollateWrapper, List).


collate_raw(K1, K2) ->
    K1 =< K2.

%% encoding function

encode_erlang(encode, _Key, Value) ->
    term_to_binary(Value, [compressed, {minor_version, 2}]);


encode_erlang(decode, _Key, Value) ->
    binary_to_term(Value, [safe]).

%% private functions

init_order(#tree{} = Tree, Order)
  when is_integer(Order), Order > 2, Order rem 2 == 0 ->
    Tree#tree{
        min = Order div 2,
        max = Order
    }.


first_key(#node{} = Node) ->
    first_key(Node#node.members);

first_key(Members) when is_list(Members) ->
    element(1, hd(Members)).


last_key(#node{} = Node) ->
    last_key(Node#node.members);

last_key(Members) when is_list(Members) ->
    case lists:last(Members) of
        {K, _V} ->
            K;
        {_F, L, _P, _R} ->
            L
    end.


new_node_id(Tx, Tree) ->
    NextId = get_meta(Tx, Tree, ?META_NEXT_ID),
    set_meta(Tx, Tree, ?META_NEXT_ID, NextId + 1),
    NextId.


%% remove prev/next pointers for nonleaf nodes
remove_pointers_if_not_leaf(#node{level = 0} = Node) ->
    Node;

remove_pointers_if_not_leaf(#node{} = Node) ->
    Node#node{prev = undefined, next = undefined}.


print_node(#node{} = Node) ->
    io:format("#node{id = ~w, level = ~w, prev = ~w, next = ~w, members = ~w}~n~n",
        [Node#node.id, Node#node.level, Node#node.prev, Node#node.next, Node#node.members]).


%% tests

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

reduce_sum(KVs, false) ->
    {_, Vs} = lists:unzip(KVs),
    lists:sum(Vs);

reduce_sum(Rs, true) ->
    lists:sum(Rs).


reduce_count(KVs, false) ->
    length(KVs);

reduce_count(Rs, true) ->
    lists:sum(Rs).


reduce_stats(KVs, false) ->
    {_, Vs} = lists:unzip(KVs),
    {
        lists:sum(Vs),
        lists:min(Vs),
        lists:max(Vs),
        length(Vs),
        lists:sum([V * V || V <- Vs])
    };

reduce_stats(Rs, true) ->
    lists:foldl(
        fun({Sum, Min, Max, Count, SumSqr},
            {SumAcc, MinAcc, MaxAcc, CountAcc, SumSqrAcc}) ->
        {
            Sum + SumAcc,
            erlang:min(Min, MinAcc),
            erlang:max(Max, MaxAcc),
            Count + CountAcc,
            SumSqr + SumSqrAcc
        } end, hd(Rs), tl(Rs)).


collation_fun_test_() ->
    Tree = #tree{collate_fun = fun collate_raw/2},
    [
        ?_test(?assert(greater_than(Tree, 4, 3))),
        ?_test(?assertNot(greater_than(Tree, 3, 4))),
        ?_test(?assert(greater_than_or_equal(Tree, 3, 3))),
        ?_test(?assert(greater_than_or_equal(Tree, 3, 3))),
        ?_test(?assert(less_than(Tree, 3, 4))),
        ?_test(?assertNot(less_than(Tree, 3, 3))),
        ?_test(?assertNot(less_than(Tree, 4, 3))),
        ?_test(?assert(less_than_or_equal(Tree, 3, 3))),
        ?_test(?assert(less_than_or_equal(Tree, 3, 4))),
        ?_test(?assertNot(less_than_or_equal(Tree, 4, 3)))
    ].


lookup_test() ->
    Db = erlfdb_util:get_test_db([empty]),
    Tree = open(Db, <<1,2,3>>, 4),
    Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, 100)])],
    lists:foreach(fun(Key) -> insert(Db, Tree, Key, Key + 1) end, Keys),
    lists:foreach(fun(Key) -> ?assertEqual({Key, Key + 1}, lookup(Db, Tree, Key)) end, Keys),
    ?assertEqual(false, lookup(Db, Tree, 101)).


delete_test() ->
    Db = erlfdb_util:get_test_db([empty]),
    Tree = open(Db, <<1,2,3>>, 4),
    Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, 100)])],
    lists:foreach(fun(Key) -> insert(Db, Tree, Key, Key + 1) end, Keys),
    lists:foreach(fun(Key) -> ?assertEqual({Key, Key + 1}, lookup(Db, Tree, Key)) end, Keys),
    lists:foreach(fun(Key) -> delete(Db, Tree, Key) end, Keys),
    lists:foreach(fun(Key) -> ?assertEqual(false, lookup(Db, Tree, Key)) end, Keys).


range_after_delete_test() ->
    Db = erlfdb_util:get_test_db([empty]),
    Tree = open(Db, <<1,2,3>>, 4),
    Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, 100)])],
    lists:foreach(fun(Key) -> insert(Db, Tree, Key, Key + 1) end, Keys),
    lists:foreach(fun(Key) -> ?assertEqual({Key, Key + 1}, lookup(Db, Tree, Key)) end, Keys),
    lists:foreach(fun(Key) -> delete(Db, Tree, Key) end, lists:seq(1, 100, 2)),
    ?assertEqual(50, range(Db, Tree, 1, 100, fun(E, A) -> length(E) + A end, 0)),
    ?assertEqual(50, reverse_range(Db, Tree, 1, 100, fun(E, A) -> length(E) + A end, 0)).


full_reduce_test_() ->
    Db = erlfdb_util:get_test_db([empty]),
    Tree = open(Db, <<1,2,3>>, 4, [{reduce_fun, fun reduce_sum/2}]),
    TestFun = fun(Max) ->
        Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, Max)])],
        lists:foreach(fun(Key) -> insert(Db, Tree, Key, Key) end, Keys),
        ?assertEqual(round(Max * ((1 + Max) / 2)), full_reduce(Db, Tree))
    end,
    [
        ?_test(TestFun(4)),
        ?_test(TestFun(8))
    ].


full_reduce_after_delete_test() ->
    Db = erlfdb_util:get_test_db([empty]),
    Tree = open(Db, <<1,2,3>>, 4, [{reduce_fun, fun reduce_sum/2}]),
    Max = 100,
    Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, Max)])],
    lists:foreach(fun(Key) -> insert(Db, Tree, Key, Key) end, Keys),
    ?assertEqual(round(Max * ((1 + Max) / 2)), full_reduce(Db, Tree)),
    lists:foreach(fun(Key) -> delete(Db, Tree, Key) end, Keys),
    ?assertEqual(0, full_reduce(Db, Tree)).


count_reduce_test_() ->
    Db = erlfdb_util:get_test_db([empty]),
    Tree = open(Db, <<1,2,3>>, 4, [{reduce_fun, fun reduce_count/2}]),
    Max = 100,
    Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, Max)])],
    lists:foreach(fun(Key) -> insert(Db, Tree, Key, Key) end, Keys),
    Expected = fun(S, E) -> E - S + 1 end,
    [
        ?_test(?assertEqual(Expected(1, 5), reduce(Db, Tree, 1, 5))),
        ?_test(?assertEqual(Expected(50, 60), reduce(Db, Tree, 50, 60))),
        ?_test(?assertEqual(Expected(21, 83), reduce(Db, Tree, 21, 83))),
        ?_test(?assertEqual(Expected(1, 1), reduce(Db, Tree, 1, 1))),
        ?_test(?assertEqual(Expected(1, 100), reduce(Db, Tree, 0, 200))),
        ?_test(?assertEqual(Expected(5, 7), reduce(Db, Tree, 5, 7)))
    ].

sum_reduce_test_() ->
    Db = erlfdb_util:get_test_db([empty]),
    Tree = open(Db, <<1,2,3>>, 4, [{reduce_fun, fun reduce_sum/2}]),
    Max = 100,
    Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, Max)])],
    lists:foreach(fun(Key) -> insert(Db, Tree, Key, Key) end, Keys),
    Expected = fun(S, E) -> lists:sum(lists:seq(S, E)) end,
    [
        ?_test(?assertEqual(Expected(1, 5), reduce(Db, Tree, 1, 5))),
        ?_test(?assertEqual(Expected(50, 60), reduce(Db, Tree, 50, 60))),
        ?_test(?assertEqual(Expected(21, 83), reduce(Db, Tree, 21, 83))),
        ?_test(?assertEqual(Expected(1, 1), reduce(Db, Tree, 1, 1))),
        ?_test(?assertEqual(Expected(1, 100), reduce(Db, Tree, 0, 200))),
        ?_test(?assertEqual(Expected(5, 7), reduce(Db, Tree, 5, 7)))
    ].


stats_reduce_test_() ->
    Db = erlfdb_util:get_test_db([empty]),
    Tree = open(Db, <<1,2,3>>, 4, [{reduce_fun, fun reduce_stats/2}]),
    Max = 100,
    Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, Max)])],
    lists:foreach(fun(Key) -> insert(Db, Tree, Key, Key) end, Keys),
    [
        ?_test(?assertEqual({15,1,5,5,55}, reduce(Db, Tree, 1, 5))),
        ?_test(?assertEqual({605,50,60,11,33385}, reduce(Db, Tree, 50, 60))),
        ?_test(?assertEqual({3276,21,83,63,191184}, reduce(Db, Tree, 21, 83))),
        ?_test(?assertEqual({1,1,1,1,1}, reduce(Db, Tree, 1, 1))),
        ?_test(?assertEqual({5050,1,100,100,338350}, reduce(Db, Tree, 0, 200))),
        ?_test(?assertEqual({18,5,7,3,110}, reduce(Db, Tree, 5, 7)))
    ].


group_reduce_level_test_() ->
    Db = erlfdb_util:get_test_db([empty]),
    Tree = open(Db, <<1,2,3>>, 4, [{reduce_fun, fun reduce_sum/2}]),
    Max = 100,
    Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, Max)])],
    GroupKeyFun = fun(Key) -> lists:sublist(Key, 2) end,
    UserAccFun = fun({K,V}, Acc) -> Acc ++ [{K, V}] end,
    lists:foreach(fun(Key) -> insert(Db, Tree, [Key rem 4, Key rem 3, Key], Key) end, Keys),
    [
        ?_test(?assertEqual([{[1, 0], 408}, {[1, 1], 441}, {[1, 2], 376}],
            group_reduce(Db, Tree, [1], [2], GroupKeyFun, UserAccFun, []))),

        ?_test(?assertEqual([{[1, 0], 408}, {[1, 1], 441}, {[1, 2], 376}],
            group_reduce(Db, Tree, [1], [2], GroupKeyFun, UserAccFun, [], [{dir, fwd}]))),

        ?_test(?assertEqual([{[1, 2], 376}, {[1, 1], 441}, {[1, 0], 408}],
            group_reduce(Db, Tree, [1], [2], GroupKeyFun, UserAccFun, [], [{dir, rev}]))),

        ?_test(?assertEqual([{[0,0],432}, {[0,1],468}, {[0,2],400}, {[1,0],408}, {[1,1],441}, {[1,2],376},
            {[2,0],384}, {[2,1],416}, {[2,2],450}, {[3,0],459}, {[3,1],392}, {[3,2],424}],
            group_reduce(Db, Tree, ebtree:min(), ebtree:max(), GroupKeyFun, UserAccFun, [])))
    ].


group_reduce_int_test_() ->
    Db = erlfdb_util:get_test_db([empty]),
    Tree = open(Db, <<1,2,3>>, 4, [{reduce_fun, fun reduce_count/2}]),
    Max = 100,
    Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, Max)])],
    GroupKeyFun = fun(_Key) -> null end,
    UserAccFun = fun({K,V}, Acc) -> Acc ++ [{K, V}] end,
    lists:foreach(fun(Key) -> insert(Db, Tree, Key, Key) end, Keys),
    [
        ?_test(?assertEqual([{null, 100}], group_reduce(Db, Tree,
            ebtree:min(), ebtree:max(), GroupKeyFun, UserAccFun, []))),
        ?_test(?assertEqual([{null, 99}], group_reduce(Db, Tree, 2, ebtree:max(), GroupKeyFun, UserAccFun, []))),
        ?_test(?assertEqual([{null, 96}], group_reduce(Db, Tree, 3, 98, GroupKeyFun, UserAccFun, [])))
    ].


raw_collation_test() ->
    Db = erlfdb_util:get_test_db([empty]),
    Tree = open(Db, <<1,2,3>>, 4),
    insert(Db, Tree, null, null),
    insert(Db, Tree, 1, 1),
    ?assertEqual([{1, 1}, {null, null}], range(Db, Tree, 1, null, fun(E, A) -> A ++ E end, [])).


custom_collation_test() ->
    Db = erlfdb_util:get_test_db([empty]),
    CollateFun = fun(A, B) -> B =< A end,
    Tree = open(Db, <<1,2,3>>, 4, [{collate_fun, CollateFun}]),
    insert(Db, Tree, 1, 1),
    insert(Db, Tree, 2, 2),
    ?assertEqual([{2, 2}, {1, 1}], range(Db, Tree, 3, 0, fun(E, A) -> A ++ E end, [])).


intense_lookup_test_() ->
    [
        {timeout, 1000, fun() -> lookup_test_fun(1000, 20) end},
        {timeout, 1000, fun() -> lookup_test_fun(1000, 50) end},
        {timeout, 1000, fun() -> lookup_test_fun(1000, 500) end}
    ].


lookup_test_fun(Max, Order) ->
    Db = erlfdb_util:get_test_db([empty]),
    Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, Max, 2)])],
    T0 = erlang:monotonic_time(),
    Tree = lists:foldl(fun(Key, T) -> insert(Db, T, Key, Key + 1) end, open(Db, <<1,2,3>>, Order), Keys),
    T1 = erlang:monotonic_time(),
    lists:foreach(fun(Key) -> ?assertEqual({Key, Key + 1}, lookup(Db, Tree, Key)) end, Keys),
    T2 = erlang:monotonic_time(),
    ?debugFmt("~B order. ~B iterations. insert rate: ~.2f/s, lookup rate: ~.2f/s",
        [Order, Max, 1000 * (Max / msec(T1 - T0)), 1000 * (Max / msec(T2 - T1))]).


range_test_() ->
    {timeout, 1000, fun() ->
        Db = erlfdb_util:get_test_db([empty]),
        Max = 1000,
        Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, Max)])],
        Tree = lists:foldl(fun(Key, T) -> insert(Db, T, Key, Key + 1) end, open(Db, <<1,2,3>>, 10), Keys),
        lists:foreach(
            fun(_) ->
                [StartKey, EndKey] = lists:sort([rand:uniform(Max), rand:uniform(Max)]),
                ?assertEqual([{K, K + 1} || K <- lists:seq(StartKey, EndKey)],
                    range(Db, Tree, StartKey, EndKey, fun(E, A) -> A ++ E end, [])
                ) end,
        lists:seq(1, 1000))
    end}.


reverse_range_test_() ->
    {timeout, 1000, fun() ->
        Db = erlfdb_util:get_test_db([empty]),
        Max = 1000,
        Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, Max)])],
        Tree = lists:foldl(fun(Key, T) -> insert(Db, T, Key, Key + 1) end, open(Db, <<1,2,3>>, 10), Keys),
        lists:foreach(
            fun(_) ->
                [StartKey, EndKey] = lists:sort([rand:uniform(Max), rand:uniform(Max)]),
                ?assertEqual([{K, K + 1} || K <- lists:seq(EndKey, StartKey, -1)],
                    reverse_range(Db, Tree, StartKey, EndKey, fun(E, A) -> A ++ E end, [])
                ) end,
        lists:seq(1, 1000))
    end}.


custom_collation_range_test_() ->
    {timeout, 1000, fun() ->
        Db = erlfdb_util:get_test_db([empty]),
        Max = 1000,
        Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, Max)])],
        CollateFun = fun(A, B) -> B =< A end,
        Tree = open(Db, <<1,2,3>>, 10, [{collate_fun, CollateFun}]),
        lists:foldl(fun(Key, T) -> insert(Db, T, Key, Key + 1) end, Tree, Keys),
        lists:foreach(
            fun(_) ->
                [StartKey, EndKey] = sort_keys(Tree, [rand:uniform(Max), rand:uniform(Max)]),
                Seq = if
                    StartKey < EndKey ->
                        lists:seq(StartKey, EndKey);
                    true ->
                        lists:seq(StartKey, EndKey, -1)
                end,
                ?assertEqual([{K, K + 1} || K <- Seq],
                    range(Db, Tree, StartKey, EndKey, fun(E, A) -> A ++ E end, [])
                ) end,
        lists:seq(1, 1000))
    end}.


custom_collation_reverse_range_test_() ->
    {timeout, 1000, fun() ->
        Db = erlfdb_util:get_test_db([empty]),
        Max = 1000,
        Keys = [X || {_, X} <- lists:sort([ {rand:uniform(), N} || N <- lists:seq(1, Max)])],
        CollateFun = fun(A, B) -> B =< A end,
        Tree = open(Db, <<1,2,3>>, 10, [{collate_fun, CollateFun}]),
        lists:foldl(fun(Key, T) -> insert(Db, T, Key, Key + 1) end, Tree, Keys),
        lists:foreach(
            fun(_) ->
                [StartKey, EndKey] = sort_keys(Tree, [rand:uniform(Max), rand:uniform(Max)]),
                Seq = if
                    StartKey < EndKey ->
                        lists:seq(StartKey, EndKey);
                    true ->
                        lists:seq(StartKey, EndKey, -1)
                end,
                ?assertEqual([{K, K + 1} || K <- lists:reverse(Seq)],
                    reverse_range(Db, Tree, StartKey, EndKey, fun(E, A) -> A ++ E end, [])
                ) end,
        lists:seq(1, 1000))
    end}.


msec(Native) ->
    erlang:max(1, erlang:convert_time_unit(Native, native, millisecond)).

-endif.
