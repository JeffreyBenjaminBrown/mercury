%---------------------------------------------------------------------------%
% Copyright (C) 1996-1999 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% This module generates the LLDS code that defines global variables
% to hold the type_ctor_info structures of the types defined by the
% current module.
%
% These global variables are needed only with when we are using the
% shared-one-or-two-cell way of representing type information.
% It is up to the caller to check this. (When using other representations,
% defining these global variables is harmless except for adding to
% compilation time and executable size.)
%
% See polymorphism.m for a description of the various ways to represent
% type information, including a description of the type_ctor_info structures.
%
% Author: zs.
%
%---------------------------------------------------------------------------%

:- module base_type_info.

:- interface.

:- import_module hlds_module, llds.
:- import_module list.

:- pred base_type_info__generate_hlds(module_info, module_info,
		io__state, io__state).
:- mode base_type_info__generate_hlds(in, out, di, uo) is det.

:- pred base_type_info__generate_llds(module_info, list(comp_gen_c_data)).
:- mode base_type_info__generate_llds(in, out) is det.

:- implementation.

:- import_module base_typeclass_info.
:- import_module prog_data, prog_util, prog_out.
:- import_module hlds_data, hlds_pred, hlds_out.
:- import_module code_util, special_pred, type_util, globals, options.

:- import_module bool, string, map, std_util, require.

%---------------------------------------------------------------------------%

base_type_info__generate_hlds(ModuleInfo0, ModuleInfo, IO0, IO) :-
	module_info_name(ModuleInfo0, ModuleName),
	module_info_types(ModuleInfo0, TypeTable),
	map__keys(TypeTable, TypeIds),
	base_type_info__gen_base_gen_infos(TypeIds, TypeTable, ModuleName,
		ModuleInfo0, BaseGenInfos, IO0, IO),
	module_info_set_base_gen_infos(ModuleInfo0, BaseGenInfos,
		ModuleInfo).

	% Given a list of the ids of all the types in the type table,
	% find the types defined in this module, and return a base_gen_info
	% for each.

:- pred base_type_info__gen_base_gen_infos(list(type_id), type_table,
	module_name, module_info, list(base_gen_info), io__state, io__state).
:- mode base_type_info__gen_base_gen_infos(in, in, in, in, out, di, uo) is det.

base_type_info__gen_base_gen_infos([], _, _, _, [], IO, IO).
base_type_info__gen_base_gen_infos([TypeId | TypeIds], TypeTable, ModuleName,
		ModuleInfo, BaseGenInfos, IO0, IO) :-
	base_type_info__gen_base_gen_infos(TypeIds, TypeTable, ModuleName,
		ModuleInfo, BaseGenInfos1, IO0, IO1),
	TypeId = SymName - TypeArity,
	(
		SymName = qualified(TypeModuleName, TypeName),
		( 
			TypeModuleName = ModuleName,
			\+ type_id_is_hand_defined(TypeId)
		->
			map__lookup(TypeTable, TypeId, TypeDefn),
			hlds_data__get_type_defn_status(TypeDefn, Status),
			special_pred_list(Specials, IO1, IO),
			module_info_globals(ModuleInfo, Globals),
			globals__have_static_code_addresses(Globals, 
				StaticCode),
			module_info_get_special_pred_map(ModuleInfo, SpecMap),
			base_type_info__gen_proc_list(Specials, SpecMap,
					TypeId, Procs),

			% If we can't store static code addresses,
			% replace the code addresses with null pointers.
			% later code will do this if we tell it they
			% have been eliminiated.

			( StaticCode = yes ->
				Elim = no
			;
				list__length(Specials, NumSpecials),
				Elim = yes(NumSpecials)
			),
			Info = base_gen_info(TypeId, ModuleName,
				TypeName, TypeArity, Status, Elim, Procs,
				TypeDefn),
			BaseGenInfos = [Info | BaseGenInfos1]
		;
			BaseGenInfos = BaseGenInfos1,
			IO = IO1
		)
	;
		SymName = unqualified(TypeName),
		string__append_list(["unqualified type ", TypeName,
			"found in type_ctor_info"], Msg),
		error(Msg)
	).

:- pred base_type_info__gen_proc_list(list(special_pred_id), special_pred_map,
	type_id, list(pred_proc_id)).
:- mode base_type_info__gen_proc_list(in, in, in, out) is det.

base_type_info__gen_proc_list([], _, _, []).
base_type_info__gen_proc_list([Special | Specials], SpecMap, TypeId,
		[proc(PredId, ProcId) | Procs]) :-
	map__lookup(SpecMap, Special - TypeId, PredId),
	special_pred_mode_num(Special, ProcInt),
	proc_id_to_int(ProcId, ProcInt),
	base_type_info__gen_proc_list(Specials, SpecMap, TypeId, Procs).

%---------------------------------------------------------------------------%

base_type_info__generate_llds(ModuleInfo, CModules) :-
	module_info_base_gen_infos(ModuleInfo, BaseGenInfos),
	base_type_info__construct_type_ctor_infos(BaseGenInfos, ModuleInfo,
		CModules1),
	base_typeclass_info__generate_llds(ModuleInfo, CModules2),
		% XXX make this use an accumulator
	list__append(CModules1, CModules2, CModules).

:- pred base_type_info__construct_type_ctor_infos(list(base_gen_info),
	module_info, list(comp_gen_c_data)).
:- mode base_type_info__construct_type_ctor_infos(in, in, out) is det.

base_type_info__construct_type_ctor_infos([], _, []).
base_type_info__construct_type_ctor_infos([BaseGenInfo | BaseGenInfos],
		ModuleInfo, [CModule | CModules]) :-
	BaseGenInfo = base_gen_info(_TypeId, ModuleName, TypeName, TypeArity,
		_Status, Elim, Procs, HldsDefn),
	base_type_info__construct_pred_addrs(Procs, Elim, ModuleInfo, 
		PredAddrArgs),
	ArityArg = yes(const(int_const(TypeArity))),

/******
It would be more efficient if we could make type_ctor_infos local,
but linkage/2 in llds_out.m requires that we make them all exported
if any of them are exported, so that we can compute the linkage
from the data_name, for use in forward declarations.
	status_is_exported(Status, Exported),
******/
	Exported = yes,

	module_info_globals(ModuleInfo, Globals),
	globals__lookup_bool_option(Globals, type_layout, TypeLayoutOption),
	(
		TypeLayoutOption = yes
	->
		base_type_info__construct_layout(ModuleInfo, TypeName,
			TypeArity, LayoutArg),
		base_type_info__construct_functors(ModuleInfo, TypeName,
			TypeArity, FunctorsArg),
		base_type_info__construct_type_ctor_representation(HldsDefn,
			Globals, TypeCtorArg),
		prog_out__sym_name_to_string(ModuleName, ModuleNameString),
		NameArg = yes(const(string_const(TypeName))),
		ModuleArg = yes(const(string_const(ModuleNameString))),
		list__append(PredAddrArgs, [TypeCtorArg, FunctorsArg, LayoutArg,
			ModuleArg, NameArg], FinalArgs)
	;
		FinalArgs = PredAddrArgs
	),
	DataName = type_ctor(info, TypeName, TypeArity),
	CModule = comp_gen_c_data(ModuleName, DataName, Exported,
		[ArityArg | FinalArgs], uniform(no), Procs),
	base_type_info__construct_type_ctor_infos(BaseGenInfos, ModuleInfo,
		CModules).

:- pred	base_type_info__construct_layout(module_info, string, int, maybe(rval)).
:- mode	base_type_info__construct_layout(in, in, in, out) is det.
base_type_info__construct_layout(ModuleInfo, TypeName, TypeArity, Rval) :-
	module_info_name(ModuleInfo, ModuleName),
	Rval = yes(const(data_addr_const(data_addr(ModuleName, 
		type_ctor(layout, TypeName, TypeArity))))).

:- pred base_type_info__construct_functors(module_info, string, int, 
	maybe(rval)).
:- mode base_type_info__construct_functors(in, in, in, out) is det.
base_type_info__construct_functors(ModuleInfo, TypeName, TypeArity, Rval) :-
	module_info_name(ModuleInfo, ModuleName),
	Rval = yes(const(data_addr_const(data_addr(ModuleName, 
		type_ctor(functors, TypeName, TypeArity))))).

:- pred base_type_info__construct_pred_addrs(list(pred_proc_id), maybe(int), 
	module_info, list(maybe(rval))).
:- mode base_type_info__construct_pred_addrs(in, in, in, out) is det.

base_type_info__construct_pred_addrs(Procs, Elim, ModuleInfo, PredAddrArgs) :-
	( 
		% dead_proc_elim has eliminated the procs, we
		% should just put some padding in.
	
		Elim = yes(ProcsLength)
	->
		module_info_globals(ModuleInfo, Globals),
		
			% If eliminated, make procs point to
			% private_builtin__unused.  (Or, if static code
			% addresses are not available, use NULL
			% pointers).
		(
			globals__have_static_code_addresses(Globals, yes)
		->
			hlds_pred__initial_proc_id(ProcId),
			mercury_private_builtin_module(MercuryBuiltin),
			PredAddrArg = yes(const(code_addr_const(
				imported(proc(MercuryBuiltin, predicate,
					MercuryBuiltin, "unused", 0,
						ProcId)))))
		;
			PredAddrArg = yes(const(int_const(0)))
		),
		list__duplicate(ProcsLength, PredAddrArg, PredAddrArgs)
	;
		base_type_info__construct_pred_addrs2(Procs, ModuleInfo, 
			PredAddrArgs)
	).

:- pred base_type_info__construct_pred_addrs2(list(pred_proc_id), module_info,
	list(maybe(rval))).
:- mode base_type_info__construct_pred_addrs2(in, in, out) is det.

base_type_info__construct_pred_addrs2([], _, []).
base_type_info__construct_pred_addrs2([proc(PredId, ProcId) | Procs],
		ModuleInfo, [PredAddrArg | PredAddrArgs]) :-
	code_util__make_entry_label(ModuleInfo, PredId, ProcId, no, PredAddr),
	PredAddrArg = yes(const(code_addr_const(PredAddr))),
	base_type_info__construct_pred_addrs2(Procs, ModuleInfo, PredAddrArgs).


:- type type_ctor_representation 
	--->	enum
	;	du
	;	notag
	;	equiv
	;	int
	;	char
	;	float
	;	string
	;	(pred)
	;	univ
	;	void
	;	c_pointer
	;	typeinfo
	;	typeclassinfo
	;	array
	;	unknown.

:- pred base_type_info__type_ctor_rep_to_int(type_ctor_representation::in,
	int::out) is det.
base_type_info__type_ctor_rep_to_int(enum, 0).
base_type_info__type_ctor_rep_to_int(du, 1).
base_type_info__type_ctor_rep_to_int(notag, 2).
base_type_info__type_ctor_rep_to_int(equiv, 3).
base_type_info__type_ctor_rep_to_int(int, 4).
base_type_info__type_ctor_rep_to_int(char, 5).
base_type_info__type_ctor_rep_to_int(float, 6).
base_type_info__type_ctor_rep_to_int(string, 7).
base_type_info__type_ctor_rep_to_int(pred, 8).
base_type_info__type_ctor_rep_to_int(univ, 9).
base_type_info__type_ctor_rep_to_int(void, 10).
base_type_info__type_ctor_rep_to_int(c_pointer, 11).
base_type_info__type_ctor_rep_to_int(typeinfo, 12).
base_type_info__type_ctor_rep_to_int(typeclassinfo, 13).
base_type_info__type_ctor_rep_to_int(array, 14).
base_type_info__type_ctor_rep_to_int(unknown, 15).


:- pred base_type_info__construct_type_ctor_representation(hlds_type_defn,
		globals, maybe(rval)).
:- mode base_type_info__construct_type_ctor_representation(in, in, out) is det.

base_type_info__construct_type_ctor_representation(HldsType, Globals, Rvals) :-
	hlds_data__get_type_defn_body(HldsType, TypeBody),
	(
		TypeBody = uu_type(_Alts),
		error("base_type_info__construct_type_ctor_representation: sorry, undiscriminated union unimplemented\n")
	;
		TypeBody = eqv_type(_Type),
		TypeCtorRep = equiv
	;
		TypeBody = abstract_type,
		TypeCtorRep = unknown
	;
		TypeBody = du_type(Ctors, _ConsTagMap, Enum, _EqualityPred),
		(
			Enum = yes,
			TypeCtorRep = enum
		;
			Enum = no,
			( 
				type_is_no_tag_type(Ctors, Globals, _Name,
						_TypeArg)
			->
				TypeCtorRep = notag
			;
				TypeCtorRep = du
			)
		)
	),
	base_type_info__type_ctor_rep_to_int(TypeCtorRep, TypeCtorRepInt),
	Rvals = yes(const(int_const(TypeCtorRepInt))).



