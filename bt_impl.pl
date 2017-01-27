:- module(bt_impl, [
	      bad_thing_happened/0,
	      reset_nodes_for_module/1,
	      set_current_bt_module/0,
	      def_node/4,   % node(+Head, +Oper, +Args, +Children)
	      start_context/3, % start_context(+Root, +Context, +Time)
%	      end_context/1, % end_context(+Context),
	      start_simulation/4, % start_simulation(+StartTime, +TimeUnit, +TickLength, +External)
	      end_simulation/0,
%	      bt_time/1, % get the time of the global clock
%	      bt_context_time/2, % get the time of the context clock
	      check_nodes/0, % check_nodes
	      make_cn/2,
	      emit/1
	 ]).
/** <module> run time support for bt
 *
 * "If you have done something twice, you are likely to do it again."
 *
 * Brian Kernighan and Bob Pike
 *
 * Agent based version
*/
user:file_search_path(nodes, 'nodes/').
user:file_search_path(simgen, '.').
user:file_search_path(examples, 'examples/').

:- use_module(simgen(clocks)).
:- use_module(simgen(valuator)).
:- use_module(simgen(print_system)).
:- use_module(nodes(random_selector)).
:- use_module(nodes(pdq)).
:- use_module(nodes(check_guard)).
:- use_module(nodes(wait_guard)).
:- use_module(nodes(set_guard)).
:- use_module(nodes(clear_guard)).
:- use_module(nodes(sequence)).
:- use_module(nodes(random_sequence)).
:- use_module(nodes(try_decorator)).
:- use_module(nodes(fail_decorator)).
:- use_module(nodes(not_decorator)).
:- use_module(nodes(dur)).
:- use_module(nodes(pin_decorator)).
:- use_module(nodes(parallel)).
:- use_module(nodes(paraselect)).
:- use_module(nodes(repeat_decorator)).

		 /*******************************
		 * Compilation support          *
		 *******************************/

:- dynamic node_/5.   % node_(Module, Head, Operator, Args, Children)

:- module_transparent set_current_bt_module/0.

%!	set_current_bt_module is det
%
%	module_transparent predicate that
%	records the calling module.
%	def_node/4 uses this info
%
%	Users usually won't call this.
%	It's for the compiler
%
set_current_bt_module :-
	bt_debug(bt(compile, node), 'in set_current_bt_module\n', []),
	context_module(Module),
	nb_setval(current_bt_module, Module).

%!	reset_nodes_for_module(+Module:atom) is det
%
%	reset ALL nodes - for the moment we dont have modules
%
%       Users usually won't call this, it's for the compiler
%
reset_nodes_for_module(_Module) :-
	retractall(bt_impl:node_(_, _, _, _, _)).

%! def_node(+Head:atom, +Oper:atom, +Args:args, +Children:list) is det
%
%	Define a node.
%	A _node_ is a cell in an behavior tree
%
%	@arg Head the name of the node, an atom
%	@arg Oper the name of the operation type for the node
%	@arg Args a single item or list of items. Meaning depends on
%	Oper
%	@arg Children a list of
%	@tbd change this to a term_expansion
%
%    Users would usually not call this directly. def_node/4 calls are
%    generated by use_bt
%
def_node(Head, _, _, _) :-
	node_(_, Head, _, _, _),
	gtrace,
	!,
	line_count(current_input, Line),
	bt_debug(error(compile, multiply_defined_node),
	      '~w is multiply defined on line ~d.', [Head, Line]).
def_node(Head, Oper, Args, Children) :-
	\+ node_(_, Head, _, _, _),
	bt_debug(bt(compile, node), 'node ~w ~w ~w ~w~n',
	      [Head, Oper, Args, Children]),
	nb_getval(current_bt_module, Module),
	assertz(node_(Module, Head, Oper, Args, Children)),
	bt_debug(bt(compile, node), 'asserted~n', []).

%!	check_nodes is semidet
%
%	Succeeds if all referenced nodes are defined
%	emits messages if not.
%
%       Called at end of module compilation
%
check_nodes :-
	\+ node_(_, _, _, _, _),
	!.
check_nodes :-
	setof(Node, a_used_node(Node), Used),
	maplist(check_def, Used).

a_used_node(Node) :-
	node_(_, _, _, _, Children),
	member(Node, Children).

check_def(Node) :- node_(_, Node, _, _, _).
check_def(Node) :-
	(   setof(Head, M^O^A^(node_(M, Head, O, A, Children), member(Node, Children)), Heads)
	; Heads = []),
	maplist(print_no_def(Node), Heads).

print_no_def(Node, Head) :-
	format(atom(Msg), 'Node ~w is used in node ~w but is not defined', [Node, Head]),
	bt_print_message(error, error(existance_error(procedure, Node),
					      context(node:Head, Msg))).

		 /*******************************
		 *          User API            *
		 *******************************/

%!     start_simulation(
%! +StartTime:number, +TimeUnit:number, +TickLength:number,
%! +External:term) is det
%
%	run a new simulation
%
%	@arg StartTime time in user units to run the first tick at
%	@arg TimeUnit how long is one user unit in nanos?
%	@arg TickLength how long is a tick in user units?
%	@arg external data for use by event listeners
%
start_simulation(StartTime, TimeUnit, TickLength, External) :-
	unlisten(_-_, _, _),
	abolish_clocks(_),
	clock_units(TimeUnit, TickLength),
	new_clock(simgen, StartTime),
	empty_queues,
	broadcast(simulation_starting),
	(   do_ticks(External)
	;   bt_debug(error(simulation, simulation_failed),
		  'simulation failed', [])
	),
	!.  % make it steadfast

%!	end_simulation is det
%
%	Stop a running simulation at the
%	end of the tick
%
%   Must be called from the simulation thread
%   (usually a message listener)
%
end_simulation :-
	thread_send_message(simgen, end_simulation).

start_context(Root, Context, Time) :-
	new_clock(Context, Time),
	% direct call above
	% needed to cure timing bug where we broadcast values on
	% nonexistant clock
	thread_send_message(simgen, start_node(Context-Root)).

		 /*******************************
		 * Support for User API         *
		 *******************************/

		 /*******************************
		 *	   Simulator            *
		 *******************************/

/*
 * See the document agentbased.md that should have come
 * with this file for information about the design of this code.
 */

/*
 *  Queue to send messages into the simulator during simulation
 */
:- initialization (  message_queue_property(_, alias(simgen)),
		     message_queue_destroy(simgen)
		  ;
		     true
		  ),
		  message_queue_create(_, [alias(simgen)]).

/*
Queue to buffer messages to make agent-like behavior
*/

:- initialization (  message_queue_property(_, alias(u)),
		     message_queue_destroy(u)
		  ;
		     true
		  ),
		  message_queue_create(_, [alias(u)]).

empty_queues :-
	thread_get_message(u, _, [timeout(0)]),
	empty_queues.
empty_queues :-
	thread_get_message(simgen, _, [timeout(0)]),
	empty_queues.
empty_queues.

do_ticks(_External) :-
	end_simulation_message_exists.
do_ticks(External) :-
	get_clock(simgen, Time),
	% this is for external prolog
	ignore(broadcast_request(tick(External, Time, NewExtern))),
	% this is *from* external prolog
	empty_simgen_queue,
	cycle_values,
	do_tick_start,
	empty_u_queue,
	valuator,
	do_tick_end,
	empty_u_queue,
	broadcast_values,
	update_clocks,
	show_debug,
	do_ticks(NewExtern).

empty_simgen_queue :-
	thread_get_message(simgen, new_clock(Name, Start), [timeout(0)]),
	!,
	new_clock(Name, Start),
	empty_simgen_queue.
empty_simgen_queue :-
	thread_get_message(simgen, start_node(Context-Root), [timeout(0)]),
	!,
        make_cn(Context-Root, Context-'$none$'),
	empty_simgen_queue.
empty_simgen_queue.

do_tick_start :-
	broadcast(tick_start).

do_tick_end :-
	broadcast(tick_end).

empty_u_queue :-
	thread_get_message(u, Msg, [timeout(0)]),
	!,
	broadcast(Msg),
	empty_u_queue.
empty_u_queue.

end_simulation_message_exists :-
	thread_get_message(simgen, end_simulation, [timeout(0)]).

:- multifile bt_impl:make_cn_impl/3.

make_cn(C-N, CParent-NParent) :-
	node_(_M, N, O, _A, _C),
	make_cn_impl(O, C-N, CParent-NParent).

emit(Msg) :-
	thread_send_message(u, Msg).

		 /*******************************
		 * Dev Support
		 *******************************/

% whenever we're in trouble we call this, so there's a convenient place
% to stick a gtrace
bad_thing_happened :-
	true.

show_debug :-
	get_clock(simgen, Time),
	bt_debug(bt(ticks, tick), '@@@@@ Tick! ~w', [Time]).

