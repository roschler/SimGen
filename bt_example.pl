:- module(bt_example, [test/2, test/3]).
/** <module> Examples that define some test behaviors
 *
 * wawei
 *
 * Each context is one of two types.
 *
 * Type a speed is 500 - P - T
 * Type b speed is 500 + time - P - T
 *
 * Type b fails after a random time
 *
 * generator
 *
 * This example simulates in-service failure control of a gas powered
 * generator set.
 *
 * A manufacturer of gas powered generators runs the devices for
 * a 24 hour period to eliminate those that will fail within the first
 * 24 hours of use,
 *
 * Doing this is expensive for the manufacturer. They'd like to identify
 * failures before they happen to save gasoline, reduce
 * in-house wear on units, and be able to rework the bad generators
 * instead of scrapping them.
 */
:- use_module(behavior_tree).

/* no quasiquotes til I have time to wrassle with them
{|bt||
huawei ~?
 type_a,
 type_b.

type_a !
 p = 100,
 t = 100;
 p := levy_flight(p, 0, 200),
 t := wander(t, 0, 200, 3),
 speed = 500 - p - t.

type_b !
 p = 100,
 t = 100;
 p := levy_flight(p, 0, 200),
 t := wander(t, 0, 200, 3),
 speed = 500 + clock() - p - t.
|}.
*/

:- writeln('after quasiquote').

% :- use_bt(huawei2).

%!	test(+Root:atom, +N:integer) is nondet
%
%	run the test.bt test file, making n contexts
%	with root Root
%
test(Root, N) :-
	test(Root, tests, N).

test(Root, File, N) :-
	use_bt(File),
	% TODO put this in a catch
	open('tests.csv', write, Stream),
	b_setval(test_stream, Stream),
	b_setval(test_root, Root),
	!, % sanity measure,
	start_simulation(
	    0, 60_000_000_000, 1,
	   extern{
		  next_context: N,
		  add_context_on_tick: 0
	   }),
	close(Stream).

:- listen(tick(Extern, Tick, NewExtern),
	  consider_adding_context(Extern, Tick, NewExtern)).

consider_adding_context(Extern, Tick, Extern) :-
	Extern.add_context_on_tick > Tick,
	!.
consider_adding_context(Extern, _, Extern) :-
	Extern.next_context = 0,
	!,
	end_simulation.

consider_adding_context(Extern, Tick, NewExtern) :-
	nb_getval(test_root, Root),
	Extern.add_context_on_tick =< Tick,
	succ(NN, Extern.next_context),
	random_between(1, 20, R),
	NewTick is R + Tick,
	NewExtern  = extern{
			 next_context: NN,
			 add_context_on_tick: NewTick
		     },
	start_context(Root, Extern.next_context, 0).

:- listen(reading(Time, _, Context, Type, Value),
	  write_event(reading, Time, Context, Type, Value)).

:- listen(starting(Context-Type),
	  (   get_clock(simgen, Time),
	      write_event(text, Time, Context, Type, start)
	  )
	 ).

:- use_module(clocks).
% TBD - should we reexport get_clock/2 in behavior_tree?

:- listen(stopped(Context-Type, done),
	  (   get_clock(simgen, Time),
	      write_event(text, Time, Context, Type, success)
	  )
	 ).

:- listen(stopped(Context-Type, fail),
	  (   get_clock(simgen, Time),
	      write_event(text, Time, Context, Type, fail)
	  )
	 ).

write_event(Class, Time, Context, Type, Value) :-
	Nanos is Time * 60_000_000_000,
	b_getval(test_stream, Stream),
	format(Stream, 'unit,~d,~d,~w,~w,~w~n',
	       [Context, Nanos, Class, Type, Value]).

