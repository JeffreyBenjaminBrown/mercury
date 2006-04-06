% This test case is from Bart Demoen, whose mail reporting it said:
%
% the following program shows a coup, i.e. a change of leader;
% the generated program loops

:- module coup.

:- interface.
:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.

:- import_module int, list.
:- import_module solutions.

main(!IO) :-
	solutions(p, Solns),
	io__write(Solns, !IO),
	io__write_string("\n", !IO).

:- pragma minimal_model(p/1).
:- pred p(int).
:- mode p(out) is nondet.

p(X) :-
	q(X).
p(X) :-
	X = 1.

:- pragma minimal_model(q/1).
:- pred q(int).
:- mode q(out) is nondet.

q(3) :- q(_).
q(4) :- p(_).
