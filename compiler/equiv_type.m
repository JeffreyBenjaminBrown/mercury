%-----------------------------------------------------------------------------%
% Copyright (C) 1996-1999 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%

% This module contains a parse-tree to parse-tree transformation
% that expands equivalence types.

% main author: fjh

:- module equiv_type.
:- interface.
:- import_module bool, prog_data, list, io.

%-----------------------------------------------------------------------------%

	% equiv_type__expand_eqv_types(Items0, Items, CircularTypes, EqvMap).
	%
	% First it builds up a map from type_id to the equivalent type.
	% Then it traverses through the list of items, expanding all types. 
	% This has the effect of eliminating all the equivalence types
	% from the source code. Error messages are generated for any
	% circular equivalence types.
:- pred equiv_type__expand_eqv_types(list(item_and_context),
		list(item_and_context), bool, eqv_map, io__state, io__state).
:- mode equiv_type__expand_eqv_types(in, out, out, out, di, uo) is det.

	% Replace equivalence types in a given type.
:- pred equiv_type__replace_in_type(type, tvarset, eqv_map, type, tvarset).
:- mode equiv_type__replace_in_type(in, in, in, out, out) is det.

:- type eqv_map.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.
:- import_module bool, require, std_util, map.
:- import_module hlds_data, type_util, prog_data, prog_util, prog_out.
:- import_module term, varset.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

	% First we build up a mapping which records the equivalence type
	% definitions.  Then we go through the item list and replace
	% them.

equiv_type__expand_eqv_types(Items0, Items, CircularTypes, EqvMap) -->
	{ map__init(EqvMap0) },
	{ equiv_type__build_eqv_map(Items0, EqvMap0, EqvMap) },
	{ equiv_type__replace_in_item_list(Items0, EqvMap,
		Items, [], CircularTypeList0) },
	{ list__reverse(CircularTypeList0, CircularTypeList) },
	(
		{ CircularTypeList = [] }
	->
		{ CircularTypes = no }	
	;
		equiv_type__report_circular_types(CircularTypeList),
		{ CircularTypes = yes },
		io__set_exit_status(1)
	).

:- type eqv_type_body ---> eqv_type_body(tvarset, list(type_param), type).
:- type eqv_map == map(type_id, eqv_type_body).

:- pred equiv_type__build_eqv_map(list(item_and_context), eqv_map, eqv_map).
:- mode equiv_type__build_eqv_map(in, in, out) is det.

equiv_type__build_eqv_map([], EqvMap, EqvMap).
equiv_type__build_eqv_map([Item - _Context | Items], EqvMap0, EqvMap) :-
	( Item = type_defn(VarSet, eqv_type(Name, Args, Body), _Cond) ->
		list__length(Args, Arity),
		map__set(EqvMap0, Name - Arity,
			eqv_type_body(VarSet, Args, Body), EqvMap1)
	;
		EqvMap1 = EqvMap0
	),
	equiv_type__build_eqv_map(Items, EqvMap1, EqvMap).

	% The following predicate equiv_type__replace_in_item_list
	% performs substititution of equivalence types on a list
	% of items.  Similarly the replace_in_<foo> predicates that
	% follow perform substitution of equivalence types on <foo>s.

:- pred equiv_type__replace_in_item_list(list(item_and_context), eqv_map,
	list(item_and_context), list(item_and_context), list(item_and_context)).
:- mode equiv_type__replace_in_item_list(in, in, out, in, out) is det.

equiv_type__replace_in_item_list([], _, [], Circ, Circ).
equiv_type__replace_in_item_list([Item0 - Context | Items0], EqvMap,
		[Item - Context | Items], Circ0, Circ) :-
	( equiv_type__replace_in_item(Item0, EqvMap, Item1, ContainsCirc) ->
		Item = Item1,
		( ContainsCirc = yes ->
			Circ1 = [Item - Context | Circ0]
		;
			Circ1 = Circ0
		)
	;
		Item = Item0,
		Circ1 = Circ0
	),
	equiv_type__replace_in_item_list(Items0, EqvMap, Items, Circ1, Circ).

:- pred equiv_type__replace_in_item(item, eqv_map, item, bool).
:- mode equiv_type__replace_in_item(in, in, out, out) is semidet.

equiv_type__replace_in_item(type_defn(VarSet0, TypeDefn0, Cond),
		EqvMap, type_defn(VarSet, TypeDefn, Cond), ContainsCirc) :-
	equiv_type__replace_in_type_defn(TypeDefn0, VarSet0, EqvMap,
				TypeDefn, VarSet, ContainsCirc).

equiv_type__replace_in_item(
		pred(TypeVarSet0, InstVarSet, ExistQVars, PredName,
			TypesAndModes0, Det, Cond, Purity, ClassContext0),
		EqvMap,
		pred(TypeVarSet, InstVarSet, ExistQVars, PredName,
			TypesAndModes, Det, Cond, Purity, ClassContext),
		no) :-
	equiv_type__replace_in_class_constraints(ClassContext0, TypeVarSet0, 
				EqvMap, ClassContext, TypeVarSet1),
	equiv_type__replace_in_tms(TypesAndModes0, TypeVarSet1, EqvMap, 
					TypesAndModes, TypeVarSet).

equiv_type__replace_in_item(
			func(TypeVarSet0, InstVarSet, ExistQVars, PredName,
				TypesAndModes0, RetTypeAndMode0, Det, Cond,
				Purity, ClassContext0),
			EqvMap,
			func(TypeVarSet, InstVarSet, ExistQVars, PredName,
				TypesAndModes, RetTypeAndMode, Det, Cond,
				Purity, ClassContext),
			no) :-
	equiv_type__replace_in_class_constraints(ClassContext0, TypeVarSet0, 
				EqvMap, ClassContext, TypeVarSet1),
	equiv_type__replace_in_tms(TypesAndModes0, TypeVarSet1, EqvMap,
				TypesAndModes, TypeVarSet2),
	equiv_type__replace_in_tm(RetTypeAndMode0, TypeVarSet2, EqvMap,
				RetTypeAndMode, TypeVarSet).

equiv_type__replace_in_item(
			typeclass(Constraints0, ClassName, Vars, 
				ClassInterface0, VarSet0),
			EqvMap,
			typeclass(Constraints, ClassName, Vars, 
				ClassInterface, VarSet),
			no) :-
	equiv_type__replace_in_class_constraint_list(Constraints0, VarSet0, 
				EqvMap, Constraints, VarSet),
	equiv_type__replace_in_class_interface(ClassInterface0,
				EqvMap, ClassInterface).

equiv_type__replace_in_item(
			instance(Constraints0, ClassName, Ts0, 
				InstanceBody, VarSet0),
			EqvMap,
			instance(Constraints, ClassName, Ts, 
				InstanceBody, VarSet),
			no) :-
	equiv_type__replace_in_class_constraint_list(Constraints0, VarSet0, 
				EqvMap, Constraints, VarSet1),
	equiv_type__replace_in_type_list(Ts0, VarSet1, EqvMap, Ts, VarSet, _).

:- pred equiv_type__replace_in_type_defn(type_defn, tvarset, eqv_map,
					type_defn, tvarset, bool).
:- mode equiv_type__replace_in_type_defn(in, in, in, out, out, out) is semidet.

equiv_type__replace_in_type_defn(eqv_type(TName, TArgs, TBody0), VarSet0,
		EqvMap, eqv_type(TName, TArgs, TBody), VarSet, ContainsCirc) :-
	list__length(TArgs, Arity),
	equiv_type__replace_in_type_2(TBody0, VarSet0, EqvMap, [TName - Arity],
			TBody, VarSet, ContainsCirc).

equiv_type__replace_in_type_defn(uu_type(TName, TArgs, TBody0), VarSet0,
		EqvMap, uu_type(TName, TArgs, TBody), VarSet, no) :-
	equiv_type__replace_in_uu(TBody0, VarSet0, EqvMap, TBody, VarSet).

equiv_type__replace_in_type_defn(du_type(TName, TArgs, TBody0, EqPred), VarSet0,
			EqvMap, du_type(TName, TArgs, TBody, EqPred), VarSet,
			no) :-
	equiv_type__replace_in_du(TBody0, VarSet0, EqvMap, TBody, VarSet).

%-----------------------------------------------------------------------------%

:- pred equiv_type__replace_in_class_constraints(class_constraints, 
			tvarset, eqv_map, class_constraints, tvarset).
:- mode equiv_type__replace_in_class_constraints(in, in, in, out, out) is det.

equiv_type__replace_in_class_constraints(Cs0, VarSet0, EqvMap, Cs, VarSet) :-
	Cs0 = constraints(UnivCs0, ExistCs0),
	Cs = constraints(UnivCs, ExistCs),
	equiv_type__replace_in_class_constraint_list(UnivCs0, VarSet0, EqvMap,
		UnivCs, VarSet1),
	equiv_type__replace_in_class_constraint_list(ExistCs0, VarSet1, EqvMap,
		ExistCs, VarSet).

:- pred equiv_type__replace_in_class_constraint_list(list(class_constraint), 
			tvarset, eqv_map, list(class_constraint), tvarset).
:- mode equiv_type__replace_in_class_constraint_list(in, in, in, out, out)
			is det.

equiv_type__replace_in_class_constraint_list([], VarSet, _, [], VarSet).
equiv_type__replace_in_class_constraint_list([C0|C0s], VarSet0, EqvMap, 
				[C|Cs], VarSet) :-
	equiv_type__replace_in_class_constraint(C0, VarSet0, EqvMap, C,
		VarSet1),
	equiv_type__replace_in_class_constraint_list(C0s, VarSet1, EqvMap, Cs, 
		VarSet).

:- pred equiv_type__replace_in_class_constraint(class_constraint, tvarset, 
					eqv_map, class_constraint, tvarset).
:- mode equiv_type__replace_in_class_constraint(in, in, in, out, out) is det.

equiv_type__replace_in_class_constraint(Constraint0, VarSet0, EqvMap,
				Constraint, VarSet) :-
	Constraint0 = constraint(ClassName, Ts0),
	equiv_type__replace_in_type_list(Ts0, VarSet0, EqvMap, Ts1, VarSet, _),
	% we must maintain the invariant that types in class constraints
	% do not contain any info in their prog_context fields
	strip_prog_contexts(Ts1, Ts),
	Constraint = constraint(ClassName, Ts).

%-----------------------------------------------------------------------------%

:- pred equiv_type__replace_in_class_interface(class_interface,
					eqv_map, class_interface).
:- mode equiv_type__replace_in_class_interface(in, in, out) is det.

equiv_type__replace_in_class_interface(ClassInterface0, EqvMap,
				ClassInterface) :-
	list__map(equiv_type__replace_in_class_method(EqvMap),
		ClassInterface0, ClassInterface).

:- pred equiv_type__replace_in_class_method(eqv_map, class_method, 
					class_method).
:- mode equiv_type__replace_in_class_method(in, in, out) is det.

equiv_type__replace_in_class_method(EqvMap,
			pred(TypeVarSet0, InstVarSet, ExistQVars, PredName,
				TypesAndModes0, Det, Cond, ClassContext0,
				Context),
			pred(TypeVarSet, InstVarSet, ExistQVars, PredName,
				TypesAndModes, Det, Cond, ClassContext, Context)
			) :-
	equiv_type__replace_in_class_constraints(ClassContext0, TypeVarSet0, 
				EqvMap, ClassContext, TypeVarSet1),
	equiv_type__replace_in_tms(TypesAndModes0, TypeVarSet1, EqvMap, 
					TypesAndModes, TypeVarSet).

equiv_type__replace_in_class_method(EqvMap,
			func(TypeVarSet0, InstVarSet, ExistQVars, PredName,
				TypesAndModes0, RetTypeAndMode0, Det, Cond,
				ClassContext0, Context),
			func(TypeVarSet, InstVarSet, ExistQVars, PredName,
				TypesAndModes, RetTypeAndMode, Det, Cond,
				ClassContext, Context)
			) :-
	equiv_type__replace_in_class_constraints(ClassContext0, TypeVarSet0, 
				EqvMap, ClassContext, TypeVarSet1),
	equiv_type__replace_in_tms(TypesAndModes0, TypeVarSet1, EqvMap,
				TypesAndModes, TypeVarSet2),
	equiv_type__replace_in_tm(RetTypeAndMode0, TypeVarSet2, EqvMap,
				RetTypeAndMode, TypeVarSet).

equiv_type__replace_in_class_method(_,
			pred_mode(A,B,C,D,E,F),
			pred_mode(A,B,C,D,E,F)).

equiv_type__replace_in_class_method(_, 
			func_mode(A,B,C,D,E,F,G),
			func_mode(A,B,C,D,E,F,G)).

%-----------------------------------------------------------------------------%

:- pred equiv_type__replace_in_uu(list(type), tvarset, eqv_map,
					list(type), tvarset).
:- mode equiv_type__replace_in_uu(in, in, in, out, out) is det.

equiv_type__replace_in_uu(Ts0, VarSet0, EqvMap,
				Ts, VarSet) :-
	equiv_type__replace_in_type_list(Ts0, VarSet0, EqvMap,
					Ts, VarSet, _).

%-----------------------------------------------------------------------------%

:- pred equiv_type__replace_in_du(list(constructor), tvarset, eqv_map,
				list(constructor), tvarset).
:- mode equiv_type__replace_in_du(in, in, in, out, out) is det.

equiv_type__replace_in_du([], VarSet, _EqvMap, [], VarSet).
equiv_type__replace_in_du([T0|Ts0], VarSet0, EqvMap, [T|Ts], VarSet) :-
	equiv_type__replace_in_ctor(T0, VarSet0, EqvMap, T, VarSet1),
	equiv_type__replace_in_du(Ts0, VarSet1, EqvMap, Ts, VarSet).

:- pred equiv_type__replace_in_ctor(constructor, tvarset, eqv_map,
				constructor, tvarset).
:- mode equiv_type__replace_in_ctor(in, in, in, out, out) is det.

equiv_type__replace_in_ctor(ctor(ExistQVars, Constraints0, TName, Targs0),
		VarSet0, EqvMap,
		ctor(ExistQVars, Constraints, TName, Targs), VarSet) :-
	equiv_type__replace_in_ctor_arg_list(Targs0, VarSet0, EqvMap,
				Targs, VarSet1, _),
	equiv_type__replace_in_class_constraint_list(Constraints0, VarSet1, 
				EqvMap, Constraints, VarSet).

%-----------------------------------------------------------------------------%

:- pred equiv_type__replace_in_type_list(list(type), tvarset, eqv_map,
					list(type), tvarset, bool).
:- mode equiv_type__replace_in_type_list(in, in, in, out, out, out) is det.

equiv_type__replace_in_type_list(Ts0, VarSet0, EqvMap,
				Ts, VarSet, ContainsCirc) :-
	equiv_type__replace_in_type_list_2(Ts0, VarSet0, EqvMap, [],
					Ts, VarSet, no, ContainsCirc).

:- pred equiv_type__replace_in_type_list_2(list(type), tvarset, eqv_map,
			list(type_id), list(type), tvarset, bool, bool).
:- mode equiv_type__replace_in_type_list_2(in, in, in,
			in, out, out, in, out) is det.

equiv_type__replace_in_type_list_2([], VarSet, _EqvMap, _Seen,
				[], VarSet, ContainsCirc, ContainsCirc).
equiv_type__replace_in_type_list_2([T0 | Ts0], VarSet0, EqvMap, Seen,
				[T | Ts], VarSet, Circ0, Circ) :-
	equiv_type__replace_in_type_2(T0, VarSet0, EqvMap, Seen,
					T, VarSet1, ContainsCirc),
	bool__or(Circ0, ContainsCirc, Circ1),
	equiv_type__replace_in_type_list_2(Ts0, VarSet1, EqvMap, Seen,
					Ts, VarSet, Circ1, Circ).

%-----------------------------------------------------------------------------%

:- pred equiv_type__replace_in_ctor_arg_list(list(constructor_arg), tvarset,
				eqv_map, list(constructor_arg), tvarset, bool).
:- mode equiv_type__replace_in_ctor_arg_list(in, in, in, out, out, out) is det.

equiv_type__replace_in_ctor_arg_list(As0, VarSet0, EqvMap,
				As, VarSet, ContainsCirc) :-
	equiv_type__replace_in_ctor_arg_list_2(As0, VarSet0, EqvMap, [],
					As, VarSet, no, ContainsCirc).

:- pred equiv_type__replace_in_ctor_arg_list_2(list(constructor_arg), tvarset,
	eqv_map, list(type_id), list(constructor_arg), tvarset, bool, bool).
:- mode equiv_type__replace_in_ctor_arg_list_2(in, in, in,
			in, out, out, in, out) is det.

equiv_type__replace_in_ctor_arg_list_2([], VarSet, _EqvMap, _Seen,
				[], VarSet, ContainsCirc, ContainsCirc).
equiv_type__replace_in_ctor_arg_list_2([N - T0 | As0], VarSet0, EqvMap, Seen,
				[N - T | As], VarSet, Circ0, Circ) :-
	equiv_type__replace_in_type_2(T0, VarSet0, EqvMap, Seen,
					T, VarSet1, ContainsCirc),
	bool__or(Circ0, ContainsCirc, Circ1),
	equiv_type__replace_in_ctor_arg_list_2(As0, VarSet1, EqvMap, Seen,
					As, VarSet, Circ1, Circ).

%-----------------------------------------------------------------------------%

equiv_type__replace_in_type(Type0, VarSet0, EqvMap, Type, VarSet) :-
	equiv_type__replace_in_type_2(Type0, VarSet0, EqvMap,
			[], Type, VarSet, _).

	% Replace all equivalence types in a given type, detecting  
	% any circularities.
:- pred equiv_type__replace_in_type_2(type, tvarset, eqv_map,
				list(type_id), type, tvarset, bool).
:- mode equiv_type__replace_in_type_2(in, in, in, in, out, out, out) is det.

equiv_type__replace_in_type_2(term__variable(V), VarSet, _EqvMap,
		_Seen, term__variable(V), VarSet, no).
equiv_type__replace_in_type_2(Type0, VarSet0, EqvMap,
		TypeIdsAlreadyExpanded, Type, VarSet, Circ) :- 

	Type0 = term__functor(_, _, Context),
	(
		type_to_type_id(Type0, EqvTypeId, TArgs0)
	->
		equiv_type__replace_in_type_list_2(TArgs0, VarSet0, EqvMap,
			TypeIdsAlreadyExpanded, TArgs1, VarSet1, no, Circ0),

		( list__member(EqvTypeId, TypeIdsAlreadyExpanded) ->
			Circ1 = yes
		;
			Circ1 = no
		),
		(	
			map__search(EqvMap, EqvTypeId,
				eqv_type_body(EqvVarSet, Args0, Body0)),
			varset__merge(VarSet1, EqvVarSet, [Body0 | Args0],
					VarSet2, [Body | Args]),
			Circ0 = no,
			Circ1 = no
		->
			term__term_list_to_var_list(Args, ArgVars),
			term__substitute_corresponding(ArgVars, TArgs1,
							Body, Type1),
			equiv_type__replace_in_type_2(Type1, VarSet2,
				EqvMap, [EqvTypeId | TypeIdsAlreadyExpanded],
				Type, VarSet, Circ)
		;
			VarSet = VarSet1,
			construct_type(EqvTypeId, TArgs1, Context, Type),
			bool__or(Circ0, Circ1, Circ)
		)
	;
		VarSet = VarSet0,
		Type = Type0,
		Circ = no
	).

%-----------------------------------------------------------------------------%

:- pred equiv_type__replace_in_tms(list(type_and_mode), tvarset, eqv_map,
			list(type_and_mode), tvarset).
:- mode equiv_type__replace_in_tms(in, in, in, out, out) is det.

equiv_type__replace_in_tms([], VarSet, _EqvMap, [], VarSet).
equiv_type__replace_in_tms([TM0|TMs0], VarSet0, EqvMap, [TM|TMs], VarSet) :-
	equiv_type__replace_in_tm(TM0, VarSet0, EqvMap, TM, VarSet1),
	equiv_type__replace_in_tms(TMs0, VarSet1, EqvMap, TMs, VarSet).

:- pred equiv_type__replace_in_tm(type_and_mode, tvarset, eqv_map,
				type_and_mode, tvarset).
:- mode equiv_type__replace_in_tm(in, in, in, out, out) is det.

equiv_type__replace_in_tm(type_only(Type0), VarSet0, EqvMap,
				type_only(Type), VarSet) :-
	equiv_type__replace_in_type(Type0, VarSet0, EqvMap, Type, VarSet).

equiv_type__replace_in_tm(type_and_mode(Type0, Mode), VarSet0, EqvMap,
			type_and_mode(Type, Mode), VarSet) :-
	equiv_type__replace_in_type(Type0, VarSet0, EqvMap, Type, VarSet).

%-----------------------------------------------------------------------------%

:- pred equiv_type__report_circular_types(list(item_and_context)::in,
		io__state::di, io__state::uo) is det.

equiv_type__report_circular_types([]) --> [].
equiv_type__report_circular_types([Circ | Circs]) -->
	(
		{ Circ = type_defn(_, TypeDefn, _) - Context },
		{ TypeDefn = eqv_type(SymName, Params, _) }
	->
		{ list__length(Params, Arity) },
		prog_out__write_context(Context),
		io__write_string("Error: circular equivalence type `"),
		prog_out__write_sym_name(SymName),
		io__write_string("'/"),
		io__write_int(Arity),
		io__write_string(".\n"),
		equiv_type__report_circular_types(Circs)
	;
		{ error("equiv_type__report_circular_types: invalid item") }
	).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
