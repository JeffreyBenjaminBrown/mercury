/*
** Copyright (C) 1998-1999 The University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
*/

/*
** mercury_bootstrap.c -
**	Defintions that may be used for bootstrapping purposes.
**
**	Because the runtime is linked as a library, symbols can be
**	safely defined here -- if there is a duplicate symbol
**	generated by the compiler, it will not link this module into
**	the executable.  If the symbol is not generated by the compiler,
**	it will link with the definition in this file.
**	
**	Most of the time this file will	be empty.
**	It should not be used for more than one bootstrapping problem
**	at a time.
*/

#include "mercury_imp.h"

/*
** Bootstrapping the hand-definition of private_builtin:typeclass_info/1
** and private_builtin:base_typeclass_info/1
** means that the stage 1 compiler has a compiler generated definition,
** while stage 2 doesn't.
*/

Define_extern_entry(mercury____Unify___private_builtin__typeclass_info_1_0);
Define_extern_entry(mercury____Index___private_builtin__typeclass_info_1_0);
Define_extern_entry(mercury____Compare___private_builtin__typeclass_info_1_0);
#ifdef MR_USE_SOLVE_EQUAL
Define_extern_entry(mercury____SolveEqual___private_builtin__typeclass_info_1_0);
#endif

extern const struct
	mercury_data_private_builtin__type_ctor_layout_typeclass_info_1_struct 
	mercury_data_private_builtin__type_ctor_layout_typeclass_info_1;
extern const struct
	mercury_data_private_builtin__type_ctor_functors_typeclass_info_1_struct
	mercury_data_private_builtin__type_ctor_functors_typeclass_info_1;

MR_STATIC_CODE_CONST struct
mercury_data_private_builtin__type_ctor_info_base_typeclass_info_1_struct {
	Integer f1;
	Code *f2;
	Code *f3;
	Code *f4;
#ifdef MR_USE_SOLVE_EQUAL
	Code *f5;
#endif
	const Word *f6;
	const Word *f7;
	const Word *f8;
	const Word *f9;
	const Word *f10;
} mercury_data_private_builtin__type_ctor_info_base_typeclass_info_1 = {
	((Integer) 1),
	MR_MAYBE_STATIC_CODE(ENTRY(
		mercury____Unify___private_builtin__typeclass_info_1_0)),
	MR_MAYBE_STATIC_CODE(ENTRY(
		mercury____Index___private_builtin__typeclass_info_1_0)),
	MR_MAYBE_STATIC_CODE(ENTRY(
		mercury____Compare___private_builtin__typeclass_info_1_0)),
#ifdef MR_USE_SOLVE_EQUAL
	MR_MAYBE_STATIC_CODE(ENTRY(
		mercury____SolveEqual___private_builtin__typeclass_info_1_0)),
#endif
	(const Word *) &
	    mercury_data_private_builtin__type_ctor_layout_typeclass_info_1,
	(const Word *) &
	    mercury_data_private_builtin__type_ctor_functors_typeclass_info_1,
	(const Word *) &
	    mercury_data_private_builtin__type_ctor_layout_typeclass_info_1,
	(const Word *) string_const("private_builtin", 15),
	(const Word *) string_const("base_typeclass_info", 19)
};

MR_STATIC_CODE_CONST struct
mercury_data_private_builtin__type_ctor_info_typeclass_info_1_struct {
	Integer f1;
	Code *f2;
	Code *f3;
	Code *f4;
#ifdef MR_USE_SOLVE_EQUAL
	Code *f5;
#endif
	const Word *f6;
	const Word *f7;
	const Word *f8;
	const Word *f9;
	const Word *f10;
} mercury_data_private_builtin__type_ctor_info_typeclass_info_1 = {
	((Integer) 1),
	MR_MAYBE_STATIC_CODE(ENTRY(
		mercury____Unify___private_builtin__typeclass_info_1_0)),
	MR_MAYBE_STATIC_CODE(ENTRY(
		mercury____Index___private_builtin__typeclass_info_1_0)),
	MR_MAYBE_STATIC_CODE(ENTRY(
		mercury____Compare___private_builtin__typeclass_info_1_0)),
#ifdef MR_USE_SOLVE_EQUAL
	MR_MAYBE_STATIC_CODE(ENTRY(
		mercury____SolveEqual___private_builtin__typeclass_info_1_0)),
#endif
	(const Word *) &
	    mercury_data_private_builtin__type_ctor_layout_typeclass_info_1,
	(const Word *) &
	    mercury_data_private_builtin__type_ctor_functors_typeclass_info_1,
	(const Word *) &
	    mercury_data_private_builtin__type_ctor_layout_typeclass_info_1,
	(const Word *) string_const("private_builtin", 15),
	(const Word *) string_const("typeclass_info", 14)
};

const struct
mercury_data_private_builtin__type_ctor_layout_typeclass_info_1_struct {
	TYPE_LAYOUT_FIELDS
} mercury_data_private_builtin__type_ctor_layout_typeclass_info_1 = {
	make_typelayout_for_all_tags(TYPE_CTOR_LAYOUT_CONST_TAG, 
		mkbody(MR_TYPE_CTOR_LAYOUT_TYPECLASSINFO_VALUE))
};

const struct mercury_data_private_builtin__type_ctor_functors_typeclass_info_1_struct {
	Integer f1;
} mercury_data_private_builtin__type_ctor_functors_typeclass_info_1 = {
	MR_TYPE_CTOR_FUNCTORS_SPECIAL
};

BEGIN_MODULE(typeclass_info_module)
	init_entry(mercury____Unify___private_builtin__typeclass_info_1_0);
	init_entry(mercury____Index___private_builtin__typeclass_info_1_0);
	init_entry(mercury____Compare___private_builtin__typeclass_info_1_0);
#ifdef MR_USE_SOLVE_EQUAL
	init_entry(mercury____SolveEqual___private_builtin__typeclass_info_1_0);
#endif
BEGIN_CODE
Define_entry(mercury____Unify___private_builtin__typeclass_info_1_0);
{
	fatal_error("attempt to unify typeclass_info");
}

Define_entry(mercury____Index___private_builtin__typeclass_info_1_0);
	index_output = -1;
	proceed();

Define_entry(mercury____Compare___private_builtin__typeclass_info_1_0);
{
	fatal_error("attempt to compare typeclass_info");
}

#ifdef MR_USE_SOLVE_EQUAL
Define_entry(mercury____SolveEqual___private_builtin__typeclass_info_1_0);
{
	fatal_error("attempt to solve_equal typeclass_info");
}
#endif
END_MODULE

/* Ensure that the initialization code for the above module gets run. */
/*
INIT sys_init_typeclass_info_module
*/
extern ModuleFunc typeclass_info_module;
	/* suppress gcc -Wmissing-decl warning */
void sys_init_typeclass_info_module(void);
void sys_init_typeclass_info_module(void) {
	typeclass_info_module();
}
