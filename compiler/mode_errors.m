%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

% File: mode_errors.nl.
% Main author: fjh.

% This module contains all the error-reporting routines for the
% mode-checker.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- module mode_errors.
:- interface.
:- import_module set, hlds, prog_io.
:- import_module mode_info.

%-----------------------------------------------------------------------------%

:- type merge_context
	---> disj
	;    if_then_else.

:- type merge_errors == assoc_list(var, list(inst)).

:- type delayed_goal
	--->	delayed_goal(
			set(var),	% The vars it's waiting on
			mode_error_info,% The reason it can't be scheduled
			hlds__goal	% The goal itself
		).

:- type mode_error
	--->	mode_error_disj(merge_context, merge_errors)
			% different arms of a disjunction result in
			% different insts for some non-local variables
	;	mode_error_var_has_inst(var, inst, inst)
			% call to a predicate with an insufficiently
			% instantiated variable (for preds with one mode)
	;	mode_error_no_matching_mode(list(var), list(inst))
			% call to a predicate with an insufficiently
			% instantiated variable (for preds with >1 mode)
	;	mode_error_bind_var(var, inst, inst)
			% attempt to bind a non-local variable inside
			% a negated context
	;	mode_error_unify_var_var(var, var, inst, inst)
			% attempt to unify two free variables
	;	mode_error_unify_var_functor(var, const, list(term),
							inst, list(inst))
			% attempt to unify a free var with a functor containing
			% free arguments
	;	mode_error_conj(list(delayed_goal))
			% a conjunction contains one or more unscheduleable
			% goals
	;	mode_error_final_inst(int, var, inst, inst, final_inst_error).
			% one of the head variables did not have the
			% expected final inst on exit from the proc

:- type final_inst_error
	--->	too_instantiated
	;	not_instantiated_enough
	;	wrongly_instantiated.	% a catchall for anything that doesn't
					% fit into the above two categories.

:- type mode_error_info
	---> mode_error_info(
		set(var),	% the variables which caused the error
				% (we will attempt to reschedule the goal
				% if the one of these variables becomes
				% more instantiated)
		mode_error,	% the nature of the error
		term__context,	% where the error occurred
		mode_context	% where the error occurred
	).

%-----------------------------------------------------------------------------%

	% print an error message describing a mode error

:- pred report_mode_error(mode_error, mode_info, io__state, io__state).
:- mode report_mode_error(in, mode_info_no_io, di, uo) is det.

	% initialize the mode_context.

:- pred mode_context_init(mode_context).
:- mode mode_context_init(out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.
:- import_module list, mode_info, io, prog_out, mercury_to_mercury, std_util.
:- import_module map, hlds, term_io, term, hlds_out.
:- import_module options, globals, require.

	% just dispatch on the diffferent sorts of mode errors

report_mode_error(mode_error_disj(MergeContext, ErrorList), ModeInfo) -->
	report_mode_error_disj(ModeInfo, MergeContext, ErrorList).
report_mode_error(mode_error_var_has_inst(Var, InstA, InstB), ModeInfo) -->
	report_mode_error_var_has_inst(ModeInfo, Var, InstA, InstB).
report_mode_error(mode_error_bind_var(Var, InstA, InstB), ModeInfo) -->
	report_mode_error_bind_var(ModeInfo, Var, InstA, InstB).
report_mode_error(mode_error_unify_var_var(VarA, VarB, InstA, InstB),
		ModeInfo) -->
	report_mode_error_unify_var_var(ModeInfo, VarA, VarB, InstA, InstB).
report_mode_error(mode_error_unify_var_functor(Var, Name, Args, Inst,
			ArgInsts), ModeInfo) -->
	report_mode_error_unify_var_functor(ModeInfo, Var, Name, Args, Inst,
			ArgInsts).
report_mode_error(mode_error_conj(Errors), ModeInfo) -->
	report_mode_error_conj(ModeInfo, Errors).
report_mode_error(mode_error_no_matching_mode(Vars, Insts), ModeInfo) -->
	report_mode_error_no_matching_mode(ModeInfo, Vars, Insts).
report_mode_error(mode_error_final_inst(ArgNum, Var, VarInst, Inst, Reason),
		ModeInfo) -->
	report_mode_error_final_inst(ModeInfo, ArgNum, Var, VarInst, Inst,
		Reason).

%-----------------------------------------------------------------------------%

:- pred report_mode_error_conj(mode_info, list(delayed_goal),
				io__state, io__state).
:- mode report_mode_error_conj(mode_info_no_io, in, di, uo) is det.

report_mode_error_conj(ModeInfo, Errors) -->
	{ mode_info_get_context(ModeInfo, Context) },
	{ mode_info_get_varset(ModeInfo, VarSet) },
	{ find_important_errors(Errors, ImportantErrors, OtherErrors) },
	globals__lookup_option(verbose_errors, bool(VerboseErrors)),
	( { VerboseErrors = yes } ->
		mode_info_write_context(ModeInfo),
		prog_out__write_context(Context),
		io__write_string("  mode error in conjunction. The next "),
		{ list__length(Errors, NumErrors) },
		io__write_int(NumErrors),
		io__write_string(" error messages\n"),
		prog_out__write_context(Context),
		io__write_string("  indicate possible causes of this error.\n"),
		report_mode_error_conj_2(ImportantErrors, VarSet, Context,
			ModeInfo),
		report_mode_error_conj_2(OtherErrors, VarSet, Context, ModeInfo)
	;
		% in the normal case, only report the first error
		{ ImportantErrors = [FirstImportantError | _] }
	->
		report_mode_error_conj_2([FirstImportantError], VarSet, Context,
			ModeInfo)
	;
		{ OtherErrors = [FirstOtherError | _] }
	->
		report_mode_error_conj_2([FirstOtherError], VarSet, Context,
			ModeInfo)
	;
		% There wasn't any error to report!  This can't happen.
		{ error("report_mode_error_conj") }
	).

:- pred find_important_errors(list(delayed_goal), list(delayed_goal),
			list(delayed_goal)).
:- mode find_important_errors(in, out, out) is det.

find_important_errors([], [], []).
find_important_errors([Error | Errors], ImportantErrors, OtherErrors) :-
	Error = delayed_goal(_, mode_error_info(_, _, _, ModeContext), _),
	(
		% an error is important iff it is not a head unification
		(
		  ModeContext = unify_arg(unify_context(head(_), _), _, _, _)
		;
		  ModeContext = unify(unify_context(head(_), _), _)
		)
	->
		ImportantErrors1 = ImportantErrors,
		OtherErrors = [Error | OtherErrors1]
	;
		ImportantErrors = [Error | ImportantErrors1],
		OtherErrors1 = OtherErrors
	),
	find_important_errors(Errors, ImportantErrors1, OtherErrors1).

:- pred report_mode_error_conj_2(list(delayed_goal), varset, term__context,
				mode_info, io__state, io__state).
:- mode report_mode_error_conj_2(in, in, in, mode_info_no_io, di, uo) is det.

report_mode_error_conj_2([], _, _, _) --> [].
report_mode_error_conj_2([delayed_goal(Vars, Error, Goal) | Rest],
			VarSet, Context, ModeInfo) -->
	globals__lookup_option(debug_modes, bool(Debug)),
	( { Debug = yes } ->
		prog_out__write_context(Context),
		io__write_string("Floundered goal, waiting on { "),
		{ set__to_sorted_list(Vars, VarList) },
		mercury_output_vars(VarList, VarSet),
		io__write_string(" } :\n")
	;
		[]
	),
	globals__lookup_option(very_verbose, bool(VeryVerbose)),
	( { VeryVerbose = yes } ->
		io__write_string("\t\t"),
		{ mode_info_get_module_info(ModeInfo, ModuleInfo) },
		hlds_out__write_goal(Goal, ModuleInfo, VarSet, 2),
		io__write_string(".\n")
	;
		[]
	),
	{ Error = mode_error_info(_, ModeError, Context, ModeContext) },
	{ mode_info_set_context(Context, ModeInfo, ModeInfo1) },
	{ mode_info_set_mode_context(ModeContext, ModeInfo1, ModeInfo2) },
	report_mode_error(ModeError, ModeInfo2),
	report_mode_error_conj_2(Rest, VarSet, Context, ModeInfo).

%-----------------------------------------------------------------------------%

:- pred report_mode_error_disj(mode_info, merge_context, merge_errors,
				io__state, io__state).
:- mode report_mode_error_disj(mode_info_no_io, in, in, di, uo) is det.

report_mode_error_disj(ModeInfo, MergeContext, ErrorList) -->
	{ mode_info_get_context(ModeInfo, Context) },
	mode_info_write_context(ModeInfo),
	prog_out__write_context(Context),
	io__write_string("  mode mismatch in "),
	write_merge_context(MergeContext),
	io__write_string(".\n"),
	write_merge_error_list(ErrorList, ModeInfo).

:- pred write_merge_error_list(merge_errors, mode_info, io__state, io__state).
:- mode write_merge_error_list(in, mode_info_no_io, di, uo) is det.

write_merge_error_list([], _) --> [].
write_merge_error_list([Var - Insts | Errors], ModeInfo) -->
	{ mode_info_get_context(ModeInfo, Context) },
	{ mode_info_get_varset(ModeInfo, VarSet) },
	{ mode_info_get_instvarset(ModeInfo, InstVarSet) },
	prog_out__write_context(Context),
	io__write_string("  `"),
	mercury_output_var(Var, VarSet),
	io__write_string("' :: "),
	mercury_output_inst_list(Insts, InstVarSet),
	io__write_string(".\n"),
	write_merge_error_list(Errors, ModeInfo).

:- pred write_merge_context(merge_context, io__state, io__state).
:- mode write_merge_context(in, di, uo) is det.

write_merge_context(disj) -->
	io__write_string("disjunction").
write_merge_context(if_then_else) -->
	io__write_string("if-then-else").

%-----------------------------------------------------------------------------%

:- pred report_mode_error_bind_var(mode_info, var, inst, inst,
					io__state, io__state).
:- mode report_mode_error_bind_var(in, in, in, in, di, uo) is det.

report_mode_error_bind_var(ModeInfo, Var, VarInst, Inst) -->
	{ mode_info_get_context(ModeInfo, Context) },
	{ mode_info_get_varset(ModeInfo, VarSet) },
	{ mode_info_get_instvarset(ModeInfo, InstVarSet) },
	mode_info_write_context(ModeInfo),
	prog_out__write_context(Context),
	io__write_string(
		"  scope error: attempt to bind variable inside a negation.\n"),
	prog_out__write_context(Context),
	io__write_string("  Variable `"),
	mercury_output_var(Var, VarSet),
	io__write_string("' has instantiatedness `"),
	mercury_output_inst(VarInst, InstVarSet),
	io__write_string("',\n"),
	prog_out__write_context(Context),
	io__write_string("  expected instantiatedness was `"),
	mercury_output_inst(Inst, InstVarSet),
	io__write_string("'.\n"),
	globals__lookup_option(verbose_errors, bool(VerboseErrors)),
	( { VerboseErrors = yes } ->
		io__write_string("\tA negation is only allowed to bind variables which are local to the\n"),
		io__write_string("\tnegation, i.e. those which are implicitly existentially quantified\n"),
		io__write_string("\tinside the scope of the negation.\n"),
		io__write_string("\tNote that the condition of an if-then-else is implicitly\n"),
		io__write_string("\tnegated in the \"else\" part, so the condition can only bind\n"),
		io__write_string("\tvariables in the \"then\" part.\n")
	;
		[]
	).

%-----------------------------------------------------------------------------%

:- pred report_mode_error_no_matching_mode(mode_info, list(var), list(inst),
					io__state, io__state).
:- mode report_mode_error_no_matching_mode(in, in, in, di, uo) is det.

report_mode_error_no_matching_mode(ModeInfo, Vars, Insts) -->
	{ mode_info_get_context(ModeInfo, Context) },
	{ mode_info_get_varset(ModeInfo, VarSet) },
	{ mode_info_get_instvarset(ModeInfo, InstVarSet) },
	mode_info_write_context(ModeInfo),
	prog_out__write_context(Context),
	io__write_string("  mode error: arguments `"),
	mercury_output_vars(Vars, VarSet),
	io__write_string("'\n"),
	prog_out__write_context(Context),
	io__write_string("  have insts `"),
	mercury_output_inst_list(Insts, InstVarSet),
	io__write_string("',\n"),
	prog_out__write_context(Context),
	io__write_string("  which does not match any of the modes for `"),
	{ mode_info_get_mode_context(ModeInfo, call(PredId, _)) },
	hlds_out__write_pred_call_id(PredId),
	io__write_string("'.\n").

:- pred report_mode_error_var_has_inst(mode_info, var, inst, inst,
					io__state, io__state).
:- mode report_mode_error_var_has_inst(in, in, in, in, di, uo) is det.

report_mode_error_var_has_inst(ModeInfo, Var, VarInst, Inst) -->
	{ mode_info_get_context(ModeInfo, Context) },
	{ mode_info_get_varset(ModeInfo, VarSet) },
	{ mode_info_get_instvarset(ModeInfo, InstVarSet) },
	mode_info_write_context(ModeInfo),
	prog_out__write_context(Context),
	io__write_string("  mode error: variable `"),
	mercury_output_var(Var, VarSet),
	io__write_string("' has instantiatedness `"),
	mercury_output_inst(VarInst, InstVarSet),
	io__write_string("',\n"),
	prog_out__write_context(Context),
	io__write_string("  expected instantiatedness was `"),
	mercury_output_inst(Inst, InstVarSet),
	io__write_string("'.\n").

%-----------------------------------------------------------------------------%

:- pred report_mode_error_unify_var_var(mode_info, var, var, inst, inst,
					io__state, io__state).
:- mode report_mode_error_unify_var_var(in, in, in, in, in, di, uo) is det.

report_mode_error_unify_var_var(ModeInfo, X, Y, InstX, InstY) -->
	{ mode_info_get_context(ModeInfo, Context) },
	{ mode_info_get_varset(ModeInfo, VarSet) },
	{ mode_info_get_instvarset(ModeInfo, InstVarSet) },
	mode_info_write_context(ModeInfo),
	prog_out__write_context(Context),
	io__write_string("  mode error in unification of `"),
	mercury_output_var(X, VarSet),
	io__write_string("' and `"),
	mercury_output_var(Y, VarSet),
	io__write_string("'.\n"),
	prog_out__write_context(Context),
	io__write_string("  Variable `"),
	mercury_output_var(X, VarSet),
	io__write_string("' has instantiatedness `"),
	mercury_output_inst(InstX, InstVarSet),
	io__write_string("',\n"),
	prog_out__write_context(Context),
	io__write_string("  variable `"),
	mercury_output_var(Y, VarSet),
	io__write_string("' has instantiatedness `"),
	mercury_output_inst(InstY, InstVarSet),
	io__write_string("'.\n").

%-----------------------------------------------------------------------------%

:- pred report_mode_error_unify_var_functor(mode_info, var, const, list(term),
					inst, list(inst), io__state, io__state).
:- mode report_mode_error_unify_var_functor(in, in, in, in, in, in, di, uo)
	is det.

report_mode_error_unify_var_functor(ModeInfo, X, Name, Args, InstX, ArgInsts)
		-->
	{ mode_info_get_context(ModeInfo, Context) },
	{ mode_info_get_varset(ModeInfo, VarSet) },
	{ mode_info_get_instvarset(ModeInfo, InstVarSet) },
	{ Term = term__functor(Name, Args, Context) },
	mode_info_write_context(ModeInfo),
	prog_out__write_context(Context),
	io__write_string("  mode error in unification of `"),
	mercury_output_var(X, VarSet),
	io__write_string("' and `"),
	term_io__write_term(VarSet, Term),
	io__write_string("'.\n"),
	prog_out__write_context(Context),
	io__write_string("  Variable `"),
	mercury_output_var(X, VarSet),
	io__write_string("' has instantiatedness `"),
	mercury_output_inst(InstX, InstVarSet),
	io__write_string("',\n"),
	prog_out__write_context(Context),
	io__write_string("  term `"),
	term_io__write_term(VarSet, Term),
	( { Args \= [] } ->
		io__write_string("'\n"),
		prog_out__write_context(Context),
		io__write_string("  has instantiatedness `"),
		term_io__write_constant(Name),
		io__write_string("("),
		mercury_output_inst_list(ArgInsts, InstVarSet),
		io__write_string(")")
	;
		io__write_string("' has instantiatedness `"),
		term_io__write_constant(Name)
	),
	io__write_string("'.\n").

%-----------------------------------------------------------------------------%

:- pred mode_info_write_context(mode_info, io__state, io__state).
:- mode mode_info_write_context(mode_info_no_io, di, uo) is det.

mode_info_write_context(ModeInfo) -->
	{ mode_info_get_module_info(ModeInfo, ModuleInfo) },
	{ mode_info_get_context(ModeInfo, Context) },
	{ mode_info_get_predid(ModeInfo, PredId) },
	{ mode_info_get_procid(ModeInfo, ProcId) },
	{ module_info_preds(ModuleInfo, Preds) },
	{ map__lookup(Preds, PredId, PredInfo) },
	{ pred_info_procedures(PredInfo, Procs) },
	{ map__lookup(Procs, ProcId, ProcInfo) },
	{ proc_info_argmodes(ProcInfo, ArgModes) },
	{ pred_info_name(PredInfo, PredName) },
	{ mode_info_get_instvarset(ModeInfo, InstVarSet) },

	prog_out__write_context(Context),
	io__write_string("In clause for `"),
	io__write_string(PredName),
	( { ArgModes \= [] } ->
		io__write_string("("),
		mercury_output_mode_list(ArgModes, InstVarSet),
		io__write_string(")")
	;
		[]
	),
	io__write_string("':\n"),
	{ mode_info_get_mode_context(ModeInfo, ModeContext) },
	write_mode_context(ModeContext, Context).

%-----------------------------------------------------------------------------%

:- pred report_mode_error_final_inst(mode_info, int, var, inst, inst,
				final_inst_error, io__state, io__state).
:- mode report_mode_error_final_inst(in, in, in, in, in, in, di, uo) is det.

report_mode_error_final_inst(ModeInfo, ArgNum, Var, VarInst, Inst, Reason) -->
	{ mode_info_get_context(ModeInfo, Context) },
	{ mode_info_get_varset(ModeInfo, VarSet) },
	{ mode_info_get_instvarset(ModeInfo, InstVarSet) },
	mode_info_write_context(ModeInfo),
	prog_out__write_context(Context),
	io__write_string("  mode error: argument "),
	io__write_int(ArgNum),
	( { Reason = too_instantiated } ->
		io__write_string(" became too instantiated")
	; { Reason = not_instantiated_enough } ->
		io__write_string(" did not get sufficiently instantiated")
	;
		% I don't think this can happen.  But just in case...
		io__write_string(" had the wrong instantiatedness")
	),
	io__write_string(".\n"),

	prog_out__write_context(Context),
	io__write_string("  Final instantiatedness of `"),
	mercury_output_var(Var, VarSet),
	io__write_string("' was `"),
	mercury_output_inst(VarInst, InstVarSet),
	io__write_string("',\n"),

	prog_out__write_context(Context),
	io__write_string("  expected final instantiatedness was `"),
	mercury_output_inst(Inst, InstVarSet),
	io__write_string("'.\n").


%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

mode_context_init(uninitialized).

%-----------------------------------------------------------------------------%

	% XXX some parts of the mode context never get set up

:- pred write_mode_context(mode_context, term__context, io__state, io__state).
:- mode write_mode_context(in, in, di, uo) is det.

write_mode_context(uninitialized, _Context) -->
	[].

write_mode_context(call(PredId, _ArgNum), Context) -->
	prog_out__write_context(Context),
	io__write_string("  in call to predicate `"),
	hlds_out__write_pred_call_id(PredId),
	io__write_string("':\n").

write_mode_context(unify(UnifyContext, _Side), Context) -->
	hlds_out__write_unify_context(UnifyContext, Context).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
