%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et wm=0 tw=0
%-----------------------------------------------------------------------------%
% Copyright (C) 1999, 2006, 2009-2010 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% lazy.m - provides support for optional lazy evaluation.
%
% Author: fjh.
% Stability: medium.
%
% This module provides the data type `lazy(T)' and the functions
% `val', `delay', and `force', which can be used to emulate lazy
% evaluation.
%
% Note that laziness is most useful for recursive data types,
% and for that case, you can't just use e.g. `lazy(list(T))',
% since that would only be lazy at the top-level; instead
% you need to define a new recursive data type lazy_list(T)
% which uses lazy(T) for the recursion.  See the module
% `lazy_list.m' for an example of how to do this.
%
% See the file README in this directory for additional documentation.
%
%-----------------------------------------------------------------------------%

:- module lazy.
:- interface.

    % A lazy(T) is a value of type T which will only be evaluated on
    % demand.
    %
:- type lazy(T).
% :- inst lazy(I).

    % Convert a value from type T to lazy(T)
    %
:- func val(T) = lazy(T).

    % Construct a lazily-evaluated lazy(T) from a closure
    %
:- func delay((func) = T) = lazy(T).

    % Force the evaluation of a lazy(T), and return the result as type T.
    % Note that if the type T may itself contains subterms of type lazy(T),
    % as is the case when T is a recursive type like the lazy_list(T) type
    % defined in lazy_list.m, those subterms will not be evaluated --
    % force/1 only forces evaluation of the lazy/1 term at the top level.
    %
:- func force(lazy(T)) = T.

%-----------------------------------------------------------------------------%
%
% The declarative semantics of the above constructs are given by the
% following equations:
%
%   val(X) = delay((func) = X).
%
%   force(delay(F)) = apply(F).
%
% The operational semantics satisfy the following:
%
% - val/1 and delay/1 both take O(1) time and use O(1) additional space.
%   In particular, delay/1 does not evaluate its argument using apply/1.
%
% - When force/1 is first called for a given term, it uses apply/1 to
%   evaluate the term, and then saves the result computed by destructively
%   modifying its argument; subsequent calls to force/1 on the same term
%   will return the same result.  So the time to evaluate force(X), where
%   X = delay(F), is O(the time to evaluate apply(F)) for the first call,
%   and O(1) time for subsequent calls.
%
% - Equality on values of type lazy(T) is implemented by calling force/1
%   on both arguments and comparing the results.  So if X and Y have type
%   lazy(T), and both X and Y are ground, then the time to evaluate X = Y
%   is O(the time to evaluate (X1 = force(X)) + the time to evaluate
%   (Y1 = force(Y)) + the time to unify X1 and Y1).
%
%-----------------------------------------------------------------------------%

:- implementation.
:- interface.
    
    % Note that we use a user-defined equality predicate to ensure
    % that unifying two lazy(T) values will do the right thing.
    %
:- type lazy(T) ---> value(T) ; closure((func) = T)
    where equality is equal_values.
    
:- inst lazy(I)
    --->    value(I)
    ;       closure(((func) = out(I) is det)).

:- pred equal_values(lazy(T)::in, lazy(T)::in) is semidet.

:- implementation.

equal_values(X, Y) :-
    force(X) = force(Y).

%-----------------------------------------------------------------------------%

val(X) = value(X).
delay(F) = closure(F).

    % If the compiler were to evaluate calls to delay/1 at compile time,
    % it could put the resulting closure/1 term in read-only memory,
    % which would make destructively updating it rather dangerous.
    % So we'd better not let the compiler inline delay/1.
    %
:- pragma no_inline(delay/1).

%-----------------------------------------------------------------------------%

    % The promise_equivalent_solutions scope is needed to tell the compiler
    % that force will return equal answers given arguments that are equal
    % but that have different representations.
    %
force(Lazy) = Value :-
    promise_pure (
        promise_equivalent_solutions [Value]
        (
            Lazy = value(Value)
        ;
            Lazy = closure(Func),
            Value = apply(Func),

            % Destructively update the Lazy cell with the value to avoid
            % having to recompute the same result next time.
            impure update_in_place(Lazy, value(Value))
        )
    ).

    % Note that the implementation of this impure predicate relies on
    % some details of the Mercury implementation.
    %
:- impure pred update_in_place(lazy(T)::in, lazy(T)::in) is det.

:- pragma foreign_proc("C", 
    update_in_place(HeapCell::in, NewValue::in),
    [will_not_call_mercury],
"
    /* strip off tag bits */
    MR_Word *ptr = (MR_Word *) MR_strip_tag(HeapCell);
    /* destructively update value */
    *ptr = NewValue;
").

%-----------------------------------------------------------------------------%