// vim: ts=4 sw=4 expandtab ft=c

// Copyright (C) 1997-2003, 2005-2007, 2011 The University of Melbourne.
// Copyright (C) 2014-2016, 2018 The Mercury team.
// This file is distributed under the terms specified in COPYING.LIB.

// mercury_trace.h defines the interface by which the internal and external
// debuggers can control how the tracing subsystem treats events.
//
// The macros, functions and variables of this module are intended to be
// referred to only from code generated by the Mercury compiler, and from
// hand-written code in the Mercury runtime or the Mercury standard library,
// and even then only if at least some part of the program was compiled
// with some form of execution tracing.
//
// The parts of the tracing system that need to be present even when tracing
// is not enabled are in the module runtime/mercury_trace_base.

#ifndef MERCURY_TRACE_H
#define MERCURY_TRACE_H

#include "mercury_memory_zones.h"   // for MR_MAX_FAKE_REG
#include "mercury_types.h"          // for MR_Unsigned etc
#include "mercury_stack_trace.h"    // for MR_Level etc
#include "mercury_trace_base.h"     // for MR_TracePort
#include "mercury_std.h"            // for MR_bool

typedef MR_Unsigned MR_IgnoreCount;

// MR_EventInfo is used to hold the information for a trace event.
// One of these is built by MR_trace_event and is passed (by reference)
// throughout the tracing system.

typedef struct MR_EventInfo_Struct {
    MR_Unsigned             MR_event_number;
    MR_Unsigned             MR_call_seqno;
    MR_Unsigned             MR_call_depth;
    MR_TracePort            MR_trace_port;
    const MR_LabelLayout    *MR_event_sll;
    const char              *MR_event_path;
    MR_Word                 MR_saved_regs[MR_MAX_FAKE_REG];
    int                     MR_max_mr_num;
    MR_Float                MR_saved_f_regs[MR_MAX_VIRTUAL_F_REG];
    int                     MR_max_f_num;
} MR_EventInfo;

// The above declarations are part of the interface between MR_trace_real
// and the internal and external debuggers. Even though MR_trace_real is
// defined in mercury_trace.c, its prototype is not here. Instead, it is
// in runtime/mercury_init.h. This is necessary because the address of
// MR_trace_real may be taken in automatically generated <main>_init.c files,
// and we do not want to include mercury_trace.h in such files; we don't want
// them to refer to the trace directory at all unless debugging is enabled.
//
// MR_trace_real_decl is the version of MR_trace_real we use when gathering
// events for the annotated trace.
//
// MR_trace_real_decl_implicit_subtree is a specialized version of
// MR_trace_real_decl for events which are in implicit subtrees.

extern  MR_Code *MR_trace_real_decl(const MR_LabelLayout *);

extern  MR_Code *MR_trace_real_decl_implicit_subtree(const MR_LabelLayout *);

// Ideally, MR_trace_retry works by resetting the state of the stacks and
// registers to the state appropriate for the call to the selected ancestor,
// setting *jumpaddr to point to the start of the code for the selected
// ancestor, and returning MR_RETRY_OK_DIRECT.
//
// If resetting the stacks requires discarding the stack frame of a procedure
// whose evaluation method is memo or loopcheck, we must also reset the call
// table entry for that particular call to uninitialized. There are two reasons
// for this. The first is that the call table entry was uninitialized at the
// time of the first call, so if the retried call is to do what the original
// call did, it must find the call table entry in the same state. The second
// reason is that if we did not reset the call table entry, then the retried
// call would find the "call active" marker left by the original call, and
// since this normally indicates an infinite loop, it will generate a runtime
// abort.
//
// Unfortunately, resetting the call table entry to uninitialized does not work
// in general for procedures whose evaluation method is minimal model tabling.
// In such procedures, a subgoal can be a consumer as well as a generator,
// and control passes between consumers and generators in a complex fashion.
// There is no safe way to reset the state of such a system, except to wait
// for normal forward execution to execute the completion operation on an
// SCC of mutually dependent subgoals.
//
// If the stack segments between the current call and the call to be retried
// contain one or more such complete SCCs, then MR_trace_retry will return
// either MR_RETRY_OK_FINISH_FIRST or MR_RETRY_OK_FAIL_FIRST. The first
// indicates that the `retry' command should be executed only after a `finish'
// command on the selected call has made the state of the SCC quiescent.
// However, if the selected call is itself a generator, then reaching one of
// its exit ports is not enough to make its SCC quiescent; for that, one must
// wait for its failure. This is why in such cases, MR_trace_retry will ask
// for the `retry' command to be executed only after a `fail' command.
//
// If the fail command reaches an exception port on the selected call instead
// of the fail port, then the SCC cannot be made quiescent, and MR_trace_retry
// will return MR_RETRY_ERROR, putting a description of the error into
// *problem. It will also do this for other, more prosaic problems, such as
// when it finds that some of the stack frames it looks at lack debugging
// information.
//
// Retry across I/O is unsafe in general. It is therefore allowed only if one
// of the following is true.
//
// - If the retry is in a tabled region, and we believe that all I/O actions
//   are tabled, either because we are in a grade in which all I/O actions
//   really are tabled or because the caller tells us to assume so.
// - If across_io is MR_RETRY_IO_FORCE.
// - If across_io is MR_RETRY_IO_INTERACTIVE (in which case in_fp and out_fp
//   must both be non-NULL), and the user, when asked whether he/she wants
//   to perform the retry anyway, says yes.
//
// If across_io is set to MR_RETRY_IO_INTERACTIVE then the string pointed to by
// the retry_interactive_message argument will be used to ask the user
// whether they want to perform an unsafe retry or not.
//
// If an unsafe retry across IO is performed then the unsafe_retry argument
// will be set to MR_TRUE, otherwise it will be set to MR_FALSE.

typedef enum {
    MR_RETRY_IO_FORCE,
    MR_RETRY_IO_INTERACTIVE,
    MR_RETRY_IO_ONLY_IF_SAFE
} MR_RetryAcrossIo;

typedef enum {
    MR_RETRY_OK_DIRECT,
    MR_RETRY_OK_FINISH_FIRST,
    MR_RETRY_OK_FAIL_FIRST,
    MR_RETRY_ERROR
} MR_RetryResult;

extern  MR_RetryResult  MR_trace_retry(MR_EventInfo *event_info,
                            MR_Level ancestor_level,
                            MR_RetryAcrossIo across_io,
                            MR_bool assume_all_io_is_tabled,
                            const char *retry_interactive_message,
                            MR_bool *unsafe_retry, const char **problem,
                            FILE *in_fp, FILE *out_fp, MR_Code **jumpaddr);

// MR_trace_cmd says what mode the tracer is in, i.e. how events should be
// treated.
//
// If MR_trace_cmd == MR_CMD_COLLECT, the event handler calls
// MR_COLLECT_filter() until the end of the execution is reached or until
// the `stop_collecting' variable is set to MR_TRUE. It is the tracer mode
// after a `collect' request.
//
// If MR_trace_cmd == MR_CMD_STEP, the event handler will stop at the next
// event.
//
// If MR_trace_cmd == MR_CMD_GOTO, the event handler will stop at the next
// event whose event number is equal to or greater than MR_trace_stop_event.
// In own stack minimal model grades, the MR_trace_stop_generator has to match
// the current context as well, the matching being defined by the
// MR_cur_generator_is_named() macro
//
// If MR_trace_cmd == MR_CMD_NEXT, the event handler will stop at the next
// event at depth MR_trace_stop_depth.
//
// If MR_trace_cmd == MR_CMD_FINISH, the event handler will stop at the next
// event at depth MR_trace_stop_depth and whose port is EXIT or FAIL or
// EXCEPTION.
//
// If MR_trace_cmd == MR_CMD_FAIL, the event handler will stop at the next
// event at depth MR_trace_stop_depth and whose port is FAIL or EXCEPTION.
//
// If MR_trace_cmd == MR_CMD_RESUME_FORWARD, the event handler will stop at
// the next event of any call whose port is *not* REDO or FAIL or EXCEPTION.
//
// If MR_trace_cmd == MR_CMD_RETURN, the event handler will stop at
// the next event of any call whose port is *not* EXIT.
//
// If MR_trace_cmd == MR_CMD_USER, the event handler will stop at the
// next user-defined event.
//
// If MR_trace_cmd == MR_CMD_MIN_DEPTH, the event handler will stop at
// the next event of any call whose depth is at least MR_trace_stop_depth.
//
// If MR_trace_cmd == MR_CMD_MAX_DEPTH, the event handler will stop at
// the next event of any call whose depth is at most MR_trace_stop_depth.
//
// If MR_trace_cmd == MR_CMD_TO_END, the event handler will not stop
// until the end of the program.
//
// If the event handler does not stop at an event, it will print the
// summary line for the event if MR_trace_print_intermediate is true.

typedef enum {
    MR_CMD_COLLECT,
    MR_CMD_STEP,
    MR_CMD_GOTO,
    MR_CMD_NEXT,
    MR_CMD_FINISH,
    MR_CMD_FAIL,
    MR_CMD_RESUME_FORWARD,
    MR_CMD_EXCP,
    MR_CMD_RETURN,
    MR_CMD_USER,
    MR_CMD_MIN_DEPTH,
    MR_CMD_MAX_DEPTH,
    MR_CMD_TO_END
} MR_TraceCmdType;

typedef enum {
    MR_PRINT_LEVEL_NONE,    // no events at all
    MR_PRINT_LEVEL_SOME,    // events matching an active spy point
    MR_PRINT_LEVEL_ALL      // all events
} MR_TracePrintLevel;

// The type of pointers to filter/4 procedures for collect request.

typedef void    (*MR_FilterFuncPtr)(MR_Integer, MR_Integer, MR_Integer,
                    MR_Word, MR_Word, MR_String, MR_String, MR_String,
                    MR_Integer, MR_Integer, MR_Word, MR_Integer, MR_String,
                    MR_Integer, MR_Word, MR_Word *, MR_Char *);

typedef struct {
    MR_TraceCmdType         MR_trace_cmd;
                            // The MR_trace_stop_depth field is meaningful
                            // if MR_trace_cmd is MR_CMD_NEXT or MR_CMD_FINISH.

    MR_Unsigned             MR_trace_stop_depth;
                            // The MR_trace_stop_event field is meaningful
                            // if MR_trace_cmd is MR_CMD_GOTO.
                            //
                            // The MR_trace_stop_generator field is meaningful
                            // if MR_trace_cmd is MR_CMD_GOTO and the grade
                            // is own stack minimal model.

    MR_Unsigned             MR_trace_stop_event;
    const char              *MR_trace_stop_generator;
    MR_bool                 MR_trace_print_level_specified;
    MR_TracePrintLevel      MR_trace_print_level;
    MR_bool                 MR_trace_strict;
#ifdef  MR_TRACE_CHECK_INTEGRITY
    MR_bool                 MR_trace_check_integrity;
#endif

                            // The next field is an optimization;
                            // it must be set to !MR_trace_strict ||
                            // MR_trace_print_level != MR_PRINT_LEVEL_NONE
                            // || MR_trace_check_integrity (the last only
                            // if defined, of course).

    MR_bool                 MR_trace_must_check;

                            // The MR_filter_ptr field points to the filter/4
                            // procedure during a collect request.

    MR_FilterFuncPtr        MR_filter_ptr;
} MR_TraceCmdInfo;

// The data structure that tells MR_trace_real and MR_trace_real_decl
// what to do. Exported only for use by mercury_trace_declarative.c.

extern  MR_TraceCmdInfo     MR_trace_ctrl;

// MR_cur_generator_is_named(genname) succeeds if the current context
// belongs to a generator named `genname' (using either MR_gen_addr_short_name
// or MR_gen_subgoal), or genname is NULL or the empty string and the current
// context does not belong to a generator.

#ifdef  MR_USE_MINIMAL_MODEL_OWN_STACKS
  #define   MR_cur_generator_is_named(genname)                              \
    (                                                                       \
        (MR_ENGINE(MR_eng_this_context) != NULL)                            \
    &&                                                                      \
        (                                                                   \
            (                                                               \
                (MR_ENGINE(MR_eng_this_context)->MR_ctxt_owner_generator    \
                    == NULL)                                                \
            &&                                                              \
                ((genname) == NULL || MR_streq((genname), ""))              \
            )                                                               \
        ||                                                                  \
            (                                                               \
                (MR_ENGINE(MR_eng_this_context)->MR_ctxt_owner_generator    \
                    != NULL)                                                \
            &&                                                              \
                ((genname) != NULL)                                         \
            &&                                                              \
                (                                                           \
                    MR_streq((genname),                                     \
                        MR_gen_addr_short_name(                             \
                            MR_ENGINE(MR_eng_this_context)->                \
                            MR_ctxt_owner_generator))                       \
                ||                                                          \
                    MR_streq((genname),                                     \
                        MR_gen_subgoal(                                     \
                            MR_ENGINE(MR_eng_this_context)->                \
                            MR_ctxt_owner_generator))                       \
                )                                                           \
            )                                                               \
        )                                                                   \
    )
#else   // MR_USE_MINIMAL_MODEL_OWN_STACKS
  #define   MR_cur_generator_is_named(genname)      MR_TRUE
#endif   // MR_USE_MINIMAL_MODEL_OWN_STACKS

#ifdef  MR_TRACE_CHECK_INTEGRITY
  #define MR_init_trace_check_integrity(cmd)                            \
    do { (cmd)->MR_trace_check_integrity = MR_FALSE; } while (0)
#else
  #define MR_init_trace_check_integrity(cmd)    ((void) 0)
#endif

#define MR_port_is_final(port)      ((port) == MR_PORT_EXIT || \
                                     (port) == MR_PORT_FAIL || \
                                     (port) == MR_PORT_EXCEPTION)

#define MR_port_is_interface(port)  ((port) <= MR_PORT_EXCEPTION)

#define MR_port_is_entry(port)      ((port) == MR_PORT_CALL)

extern  void    MR_trace_init_modules(void);

#endif // MERCURY_TRACE_H
