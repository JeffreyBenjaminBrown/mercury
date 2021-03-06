%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% Copyright (C) 2000-2012 The University of Melbourne.
% Copyright (C) 2013-2018 The Mercury team.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% Output MLDS constructs exported to Java.
%
%---------------------------------------------------------------------------%

:- module ml_backend.mlds_to_java_export.
:- interface.

:- import_module ml_backend.mlds.
:- import_module ml_backend.mlds_to_java_util.
:- import_module ml_backend.mlds_to_target_util.

:- import_module io.
:- import_module list.

%---------------------------------------------------------------------------%

    % Exports are converted into forwarding methods that are given the
    % specified name. These simply call the exported procedure.
    %
    % NOTE: the forwarding methods must be declared public as they might
    % be referred to within foreign_procs that are inlined across module
    % boundaries.
    %
:- pred output_exports_for_java(java_out_info::in, indent::in,
    list(mlds_pragma_export)::in, io::di, io::uo) is det.

%---------------------------------------------------------------------------%

:- pred output_exported_enums_for_java(java_out_info::in, indent::in,
    list(mlds_exported_enum)::in, io::di, io::uo) is det.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- implementation.

:- import_module hlds.
:- import_module hlds.hlds_module.
:- import_module libs.
:- import_module libs.globals.
:- import_module ml_backend.ml_type_gen.   % for ml_gen_type_name
:- import_module ml_backend.mlds_to_java_data.
:- import_module ml_backend.mlds_to_java_func.
:- import_module ml_backend.mlds_to_java_name.
:- import_module ml_backend.mlds_to_java_type.
:- import_module parse_tree.
:- import_module parse_tree.prog_data.

:- import_module bool.
:- import_module char.
:- import_module int.
:- import_module maybe.
:- import_module require.
:- import_module string.
:- import_module term.

%---------------------------------------------------------------------------%

output_exports_for_java(Info, Indent, Exports, !IO) :-
    list.foldl(output_export_for_java(Info, Indent), Exports, !IO).

:- pred output_export_for_java(java_out_info::in, indent::in,
    mlds_pragma_export::in, io::di, io::uo) is det.

output_export_for_java(Info0, Indent, Export, !IO) :-
    Export = ml_pragma_export(Lang, ExportName, _, MLDS_Signature,
        UnivQTVars, _),
    expect(unify(Lang, lang_java), $pred,
        "foreign_export for language other than Java."),

    output_n_indents(Indent, !IO),
    io.write_string("public static ", !IO),
    output_generic_tvars(UnivQTVars, !IO),
    io.nl(!IO),
    output_n_indents(Indent, !IO),

    MLDS_Signature = mlds_func_params(Parameters, ReturnTypes),
    Info = (Info0 ^ joi_output_generics := do_output_generics)
                  ^ joi_univ_tvars := UnivQTVars,
    (
        ReturnTypes = [],
        io.write_string("void", !IO)
    ;
        ReturnTypes = [RetType],
        output_type_for_java(Info, RetType, !IO)
    ;
        ReturnTypes = [_, _ | _],
        % For multiple outputs, we return an array of objects.
        io.write_string("java.lang.Object []", !IO)
    ),
    io.write_string(" " ++ ExportName, !IO),
    ( if
        some [Param] (
            list.member(Param, Parameters),
            has_ptr_type(Param)
        )
    then
        (
            ( ReturnTypes = []
            ; ReturnTypes = [_]
            ),
            output_export_ref_out(Info, Indent, Export, !IO)
        ;
            ReturnTypes = [_, _ | _],
            unexpected($pred, "multiple return values")
        )
    else
        output_export_no_ref_out(Info, Indent, Export, !IO)
    ).

:- pred output_export_no_ref_out(java_out_info::in, indent::in,
    mlds_pragma_export::in, io::di, io::uo) is det.

output_export_no_ref_out(Info, Indent, Export, !IO) :-
    Export = ml_pragma_export(_Lang, _ExportName, QualFuncName, MLDS_Signature,
        _UnivQTVars, _Context),
    MLDS_Signature = mlds_func_params(Parameters, ReturnTypes),
    output_params_for_java(Info, Indent + 1, Parameters, !IO),
    io.nl(!IO),
    output_n_indents(Indent, !IO),
    io.write_string("{\n", !IO),
    output_n_indents(Indent + 1, !IO),
    (
        ReturnTypes = []
    ;
        ReturnTypes = [RetType],
        % The cast is required when the exported method uses generics but the
        % underlying method does not use generics (i.e. returns Object).
        io.write_string("return (", !IO),
        output_type_for_java(Info, RetType, !IO),
        io.write_string(") ", !IO)
    ;
        ReturnTypes = [_, _ | _],
        io.write_string("return ", !IO)
    ),
    write_export_call_for_java(QualFuncName, Parameters, !IO),
    output_n_indents(Indent, !IO),
    io.write_string("}\n", !IO).

:- pred output_export_ref_out(java_out_info::in, indent::in,
    mlds_pragma_export::in, io::di, io::uo) is det.

output_export_ref_out(Info, Indent, Export, !IO) :-
    Export = ml_pragma_export(_Lang, _ExportName, QualFuncName, MLDS_Signature,
        _UnivQTVars, _Context),
    MLDS_Signature = mlds_func_params(Parameters, ReturnTypes),
    list.filter(has_ptr_type, Parameters, RefParams, NonRefParams),

    output_export_params_ref_out(Info, Indent, Parameters, !IO),
    io.nl(!IO),
    output_n_indents(Indent, !IO),
    io.write_string("{\n", !IO),
    output_n_indents(Indent + 1, !IO),
    io.write_string("java.lang.Object[] results = ", !IO),
    write_export_call_for_java(QualFuncName, NonRefParams, !IO),

    ( if ReturnTypes = [] then
        FirstRefArg = 0
    else if ReturnTypes = [mlds_native_bool_type] then
        % Semidet procedure.
        FirstRefArg = 1
    else
        unexpected($pred, "unexpected ReturnTypes")
    ),
    list.foldl2(assign_ref_output(Info, Indent + 1), RefParams,
        FirstRefArg, _, !IO),
    (
        FirstRefArg = 0
    ;
        FirstRefArg = 1,
        output_n_indents(Indent + 1, !IO),
        Stmt = "return ((java.lang.Boolean) results[0]).booleanValue();\n",
        io.write_string(Stmt, !IO)
    ),
    output_n_indents(Indent, !IO),
    io.write_string("}\n", !IO).

:- pred output_export_params_ref_out(java_out_info::in, indent::in,
    list(mlds_argument)::in, io::di, io::uo) is det.

output_export_params_ref_out(Info, Indent, Parameters, !IO) :-
    io.write_string("(", !IO),
    (
        Parameters = []
    ;
        Parameters = [_ | _],
        io.nl(!IO),
        io.write_list(Parameters, ",\n",
            output_export_param_ref_out(Info, Indent + 1), !IO)
    ),
    io.write_string(")", !IO).

:- pred output_export_param_ref_out(java_out_info::in, indent::in,
    mlds_argument::in, io::di, io::uo) is det.

output_export_param_ref_out(Info, Indent, Argument, !IO) :-
    Argument = mlds_argument(VarName, Type, _),
    output_n_indents(Indent, !IO),
    ( if Type = mlds_ptr_type(InnerType) then
        boxed_type_to_string_for_java(Info, InnerType, InnerTypeString),
        io.format("jmercury.runtime.Ref<%s> ", [s(InnerTypeString)], !IO)
    else
        output_type_for_java(Info, Type, !IO),
        io.write_string(" ", !IO)
    ),
    output_local_var_name_for_java(VarName, !IO).

:- pred write_export_call_for_java(qual_function_name::in,
    list(mlds_argument)::in, io::di, io::uo) is det.

write_export_call_for_java(QualFuncName, Parameters, !IO) :-
    QualFuncName = qual_function_name(ModuleName, FuncName),
    output_qual_name_prefix_java(ModuleName, module_qual, !IO),
    output_function_name_for_java(FuncName, !IO),
    io.write_char('(', !IO),
    io.write_list(Parameters, ", ", write_argument_name_for_java, !IO),
    io.write_string(");\n", !IO).

:- pred write_argument_name_for_java(mlds_argument::in, io::di, io::uo) is det.

write_argument_name_for_java(Arg, !IO) :-
    Arg = mlds_argument(VarName, _, _),
    output_local_var_name_for_java(VarName, !IO).

:- pred assign_ref_output(java_out_info::in, indent::in, mlds_argument::in,
    int::in, int::out, io::di, io::uo) is det.

assign_ref_output(Info, Indent, Arg, N, N + 1, !IO) :-
    Arg = mlds_argument(VarName, Type, _),
    output_n_indents(Indent, !IO),
    output_local_var_name_for_java(VarName, !IO),
    ( if Type = mlds_ptr_type(InnerType) then
        boxed_type_to_string_for_java(Info, InnerType, TypeString)
    else
        boxed_type_to_string_for_java(Info, Type, TypeString)
    ),
    io.format(".val = (%s) results[%d];\n", [s(TypeString), i(N)], !IO).

:- pred has_ptr_type(mlds_argument::in) is semidet.

has_ptr_type(mlds_argument(_, mlds_ptr_type(_), _)).

%---------------------------------------------------------------------------%

output_exported_enums_for_java(Info, Indent, ExportedEnums, !IO) :-
    list.foldl(output_exported_enum_for_java(Info, Indent),
        ExportedEnums, !IO).

:- pred output_exported_enum_for_java(java_out_info::in, indent::in,
    mlds_exported_enum::in, io::di, io::uo) is det.

output_exported_enum_for_java(Info, Indent, ExportedEnum, !IO) :-
    ExportedEnum = mlds_exported_enum(Lang, _, TypeCtor, ExportedConstants),
    (
        Lang = lang_java,
        ml_gen_type_name(TypeCtor, ClassName, ClassArity),
        MLDS_Type =
            mlds_class_type(mlds_class_id(ClassName, ClassArity, mlds_enum)),
        list.foldl(
            output_exported_enum_constant_for_java(Info, Indent, MLDS_Type),
            ExportedConstants, !IO)
    ;
        ( Lang = lang_c
        ; Lang = lang_csharp
        ; Lang = lang_erlang
        )
    ).

:- pred output_exported_enum_constant_for_java(java_out_info::in, indent::in,
    mlds_type::in, mlds_exported_enum_constant::in, io::di, io::uo) is det.

output_exported_enum_constant_for_java(Info, Indent, MLDS_Type,
        ExportedConstant, !IO) :-
    ExportedConstant = mlds_exported_enum_constant(Name, Initializer),
    output_n_indents(Indent, !IO),
    io.write_string("public static final ", !IO),
    output_type_for_java(Info, MLDS_Type, !IO),
    io.write_string(" ", !IO),
    io.write_string(Name, !IO),
    io.write_string(" = ", !IO),
    output_initializer_body_for_java(Info, Initializer, no, !IO),
    io.write_string(";\n", !IO).

%---------------------------------------------------------------------------%
:- end_module ml_backend.mlds_to_java_export.
%---------------------------------------------------------------------------%
