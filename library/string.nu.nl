%---------------------------------------------------------------------------%
% Copyright (C) 1995 University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%---------------------------------------------------------------------------%

% File: string.nu.nl.
% Main author: fjh.

%-----------------------------------------------------------------------------%

% In NU-Prolog, strings are represented as list of ASCII codes.

% To do this correctly, we really ought to check that the list of
% ints are all valid character codes (i.e. <= 255), and if not,
% call error/1.  But string__to_int_list is private to string.m
% anyway, so for efficiency we don't worry about that run-time type check.

string__to_int_list(S, S).

%-----------------------------------------------------------------------------%

string__to_float(String, Float) :-
	% ensure that the string has a decimal point followed by at least
	% one digit, by appending ".0" or "0" if necessary
	(
		append(_, [0'.|End], String)
	->
		( End = [] ->
			string__append(String, "0", FloatString)
		;
			FloatString = String
		)
	;
		string__append(String, ".0", FloatString)
	),
	% now invoke sread to parse the string as a term, and then check that
	% it really was a float
	sread(FloatString, Float),
	float(Float).

string__float_to_string(Float, String) :-
	sformat("~f", [Float], String).

%-----------------------------------------------------------------------------%
