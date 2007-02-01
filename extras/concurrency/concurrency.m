%---------------------------------------------------------------------------%
% Copyright (C) 2002, 2006-2007 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%---------------------------------------------------------------------------%

:- module concurrency.
:- interface.

    % The "concurrency" library package consists of the following modules.
    %	
:- import_module global.
:- import_module spawn.
:- import_module stream.

    % These modules have been moved to the standard library.
    %
% :- import_module channel.
% :- import_module mvar.
% :- import_module semaphore.
