/*
** Copyright (C) 1995 University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
*/

/*
** This module defines the register array and data regions of the
** execution algorithm.
** They are defined together here to allow us to control how they map
** onto direct mapped caches.
** We allocate a large arena, preferably aligned on a boundary that
** is a multiple of both the page size and the primary cache size.
**
** We then allocate the heap and the stacks in such a way that
**
**	the register array 
**	the bottom of the heap 
**	the bottom of the detstack 
**	the bottom of the nondstack 
**
** all start at different offsets from multiples of the primary cache size.
** This should reduce cache conflicts (especially for small programs).
**
** If the operating system of the machine supports the mprotect syscall,
** we also protect a chunk at the end of each area against access,
** thus detecting area overflow.
*/

/*---------------------------------------------------------------------------*/

#include "imp.h"
#include "conf.h"

#include <unistd.h>

#ifdef	HAVE_SIGINFO
#include	<sys/siginfo.h>
#endif 

#include <stdio.h>
#include <string.h>

#ifdef	HAVE_MPROTECT
#include <sys/mman.h>
#endif

#include <signal.h>

#ifdef	HAVE_UCONTEXT
#include <ucontext.h>
#endif
#ifdef	HAVE_SYS_UCONTEXT
#include <sys/ucontext.h>
#endif

#if defined(HAVE_SYSCONF) && defined(_SC_PAGESIZE)
#define	getpagesize()	sysconf(_SC_PAGESIZE)
#else
#ifndef	HAVE_GETPAGESIZE
#define	getpagesize()	8192
#endif
#endif

#ifdef	CONSERVATIVE_GC
#define memalign(a,s)   GC_MALLOC_UNCOLLECTABLE(s)
#else
#ifdef	HAVE_MEMALIGN
extern	void	*memalign(size_t, size_t);
#else
#define	memalign(a,s)	malloc(s)
#endif
#endif

/*
** DESCRIPTION
**  The function mprotect() changes the  access  protections  on
**  the mappings specified by the range [addr, addr + len) to be
**  that specified by prot.  Legitimate values for prot are  the
**  same  as  those  permitted  for  mmap  and  are  defined  in
**  <sys/mman.h> as:
**
** PROT_READ    page can be read
** PROT_WRITE   page can be written
** PROT_EXEC    page can be executed
** PROT_NONE    page can not be accessed
*/
#ifdef  HAVE_MPROTECT

#ifdef CONSERVATIVE_GC
	/*
	** The conservative garbage collectors scans through
	** all these areas, so we need to allow reads.
	** XXX This probably causes efficiency problems:
	** too much memory for the GC to scan, and it probably
	** all gets paged in.
	*/
#define MY_PROT PROT_READ
#else
#define MY_PROT PROT_NONE
#endif

/* The BSDI BSD/386 1.1 headers don't define PROT_NONE */
#ifndef PROT_NONE
#define PROT_NONE 0
#endif

#endif

/*---------------------------------------------------------------------------*/

#ifdef	HAVE_SIGINFO
static	void	complex_bushandler(int, siginfo_t *, void *);
static	void	complex_segvhandler(int, siginfo_t *, void *);
#else
static	void	simple_sighandler(int);
#endif

/*
** round_up(amount, align) returns `amount' rounded up to the nearest
** alignment boundary.  `align' must be a power of 2.
*/

#define round_up(amount, align) ((((amount) - 1) | ((align) - 1)) + 1)

static	void	setup_mprotect(void);
#ifdef	HAVE_SIGINFO
static	bool	try_munprotect(void *, void *);
static	char	*explain_context(ucontext_t *);
#endif

static	void	setup_signal(void);

Word	fake_reg[MAX_FAKE_REG];

Word	virtual_reg_map[MAX_REAL_REG] = VIRTUAL_REG_MAP_BODY;

unsigned long	num_uses[MAX_RN];

MemoryZone *zone_table;

MemoryZone *used_memory_zones;
MemoryZone *free_memory_zones;

MemoryZone *detstack_zone;
#ifndef	SPEED
MemoryZone *dumpstack_zone;
int	dumpindex;
#endif
MemoryZone *nondetstack_zone;
#ifndef CONSERVATIVE_GC
MemoryZone *heap_zone;
MemoryZone *solutions_heap_zone;
Word       *solutions_heap_pointer;
#endif

static	size_t		unit;
static	size_t		page_size;

static MemoryZone	*get_zone(void);
static void		unget_zone(MemoryZone *zone);

	/*
	** We manage the handing out of offets through the cache by
	** computing the offsets once and storing them in an array
	** (in shared memory if necessary). We then maintain a global
	** counter used to index the array which we increment (modulo
	** the size of the array) after handing out each offset.
	*/

#define	CACHE_SLICES	8

static	size_t		*offset_vector;
static	int		*offset_counter;
static	SpinLock	*offset_lock;
size_t	next_offset(void);

static void init_memory_arena(void);
static void init_zones(void);

void init_memory(void)
{
	/*
	** Convert all the sizes are from kilobytes to bytes and
	** make sure they are multiples of the page and cache sizes.
	*/

	page_size = getpagesize();
	unit = max(page_size, pcache_size);

#ifdef CONSERVATIVE_GC
	heap_zone_size      = 0;
	heap_size	    = 0;
	solutions_heap_zone_size = 0;
	solutions_heap_size = 0;
#else
	heap_zone_size      = round_up(heap_zone_size * 1024, unit);
	heap_size           = round_up(heap_size * 1024, unit);
	solutions_heap_zone_size = round_up(solutions_heap_zone_size * 1024, 
		unit);
	solutions_heap_size = round_up(solutions_heap_size * 1024, unit);
#endif

	detstack_size       = round_up(detstack_size * 1024, unit);
	detstack_zone_size  = round_up(detstack_zone_size * 1024, unit);
	nondstack_size      = round_up(nondstack_size * 1024, unit);
	nondstack_zone_size = round_up(nondstack_zone_size * 1024, unit);

	/*
	** If the zone sizes were set to something too big, then
	** set them to a single unit.
	*/

#ifndef CONSERVATIVE_GC
	if (heap_zone_size >= heap_size)
		heap_zone_size = unit;
	if (solutions_heap_zone_size >= solutions_heap_size)
		solutions_heap_zone_size = unit;
#endif

	if (detstack_zone_size >= detstack_size)
		detstack_zone_size = unit;

	if (nondstack_zone_size >= nondstack_size)
		nondstack_zone_size = unit;


	init_memory_arena();
	init_zones();
}

/*
** init_memory_arena() allocates (if necessary) the top-level memory pool
** from which all allocations should come. If PARALLEL is defined, then
** this pool should be shared memory. In the absence of PARALLEL, it
** doesn't need to do anything, since with CONSERVATIVE_GC, the collector
** manages the heap, and without GC, we can allocate memory using memalign
** or malloc.
*/
static void init_memory_arena()
{
#ifdef	PARALLEL
#ifndef	CONSERVATIVE_GC
	if (numprocs > 1) {
		fatal_error("shared memory not implemented");
	}
#else
	if (numprocs > 1) {
		fatal_error("shared memory not implemented with conservative gc");
	}
#endif
#endif
}

static void init_zones()
{
	int i;
	size_t fake_reg_offset;

	/*
	** Allocate the MemoryZone table.
	*/
	zone_table = allocate_bytes(MAX_ZONES * sizeof(MemoryZone));

	/*
	** Initialize the MemoryZone table.
	*/
	used_memory_zones = NULL;
	free_memory_zones = zone_table;
	for(i = 0; i < MAX_ZONES; i++)
	{
		zone_table[i].name = "unused";
		zone_table[i].id = i;
		zone_table[i].bottom = NULL;
		zone_table[i].top = NULL;
		zone_table[i].min = NULL;
#ifndef SPEED
		zone_table[i].max = NULL;
#endif
#ifdef	HAVE_MPROTECT
#ifdef	HAVE_SIGINFO
		zone_table[i].redzone = NULL;
#endif
		zone_table[i].hardmax = NULL;
#endif
		if (i+1 < MAX_ZONES)
			zone_table[i].next = &(zone_table[i+1]);
		else
			zone_table[i].next = NULL;
	}

	offset_counter = allocate_object(int);
	*offset_counter = 0;

	offset_vector = allocate_array(size_t, CACHE_SLICES - 1);

	fake_reg_offset = (Unsigned) fake_reg % pcache_size;

	for (i = 0; i < CACHE_SLICES - 1; i++)
		offset_vector[i] =
			(fake_reg_offset + pcache_size / CACHE_SLICES)
			% pcache_size;
}


void init_heap(void)
{
#ifndef CONSERVATIVE_GC
	heap_zone = construct_zone("heap", 1, heap_size, next_offset(),
			heap_zone_size, default_handler);

	restore_transient_registers();
	hp = heap_zone->min;
	save_transient_registers();

	solutions_heap_zone = construct_zone("solutions_heap", 1,
			solutions_heap_size, next_offset(),
			solutions_heap_zone_size, default_handler);

#endif
}

MemoryZone *get_zone(void)
{
	MemoryZone *zone;

	/*
	** unlink the first zone on the free-list,
	** link it onto the used-list and return it.
	*/
	zone = free_memory_zones;
	if (zone == NULL)
	{
		fatal_error("no more memory zones");
	}
	free_memory_zones = free_memory_zones->next;

	zone->next = used_memory_zones;
	used_memory_zones = zone;

	return zone;
}

void unget_zone(MemoryZone *zone)
{
	MemoryZone *prev, *tmp;

	/*
	** Find the zone on the used list, and unlink it from
	** the list, then link it onto the start of the free-list.
	*/
	for(prev = NULL, tmp = used_memory_zones;
		tmp && tmp != zone; prev = tmp, tmp = tmp->next) ;
	if (tmp == NULL)
		fatal_error("memory zone not found!");
	if (prev == NULL)
	{
		used_memory_zones = used_memory_zones->next;
	}
	else
	{
		prev->next = tmp->next;
	}

	zone->next = free_memory_zones;
	free_memory_zones = zone;
}

/*
** successive calls to next_offset return offsets modulo the primary
** cache size (carefully avoiding ever giving an offset that clashes
** with fake_reg_array). This is used to give different memory zones
** different starting points across the caches so that it is better
** utilized.
** An alternative implementation would be to increment the offset by
** a fixed amount (eg 2Kb) so that as primary caches get bigger, we
** allocate more offsets across them.
*/
size_t	next_offset(void)
{
	size_t offset;

	get_lock(offset_lock);

	offset = offset_vector[*offset_counter];

	*offset_counter = (*offset_counter + 1) % (CACHE_SLICES - 1);

	release_lock(offset_lock);

	return offset;
}

MemoryZone *create_zone(const char *name, int id, size_t size,
		size_t offset, size_t redsize,
		bool ((*handler)(Word *addr, MemoryZone *zone, void *context)))
{
	Word		*base;
	size_t		total_size;

		/*
		** total allocation is:
		**	unit		(roundup to page boundary)
		**	size		(including redzone)
		**	unit		(an extra page for protection if
		**			 mprotect is being used)
		*/
#ifdef	HAVE_MPROTECT
	total_size = size + 2 * unit;
#else
	total_size = size + unit;
#endif

#ifndef	PARALLEL
	base = memalign(unit, total_size);
	if (base == NULL)
	{
		char buf[2560];
		sprintf(buf, "unable allocate memory zone: %s#%d", name, id);
		fatal_error(buf);
	}
#else
#error	"allocation in shared memory not supported yet"
#endif

	return construct_zone(name, id, base, size, offset, redsize, handler);
}

MemoryZone *construct_zone(const char *name, int id, Word *base,
		size_t size, size_t offset, size_t redsize,
		bool ((*handler)(Word *addr, MemoryZone *zone, void *context)))
{
	MemoryZone	*zone;
	size_t		total_size;

	if (base == NULL)
		fatal_error("construct_zone called with NULL pointer");

	zone = get_zone();

	zone->name = name;
	zone->id = id;

#if	defined(HAVE_MPROTECT) && defined(HAVE_SIGINFO)
	zone->handler = handler;
#endif

	zone->bottom = base;

#ifdef 	HAVE_MPROTECT
	total_size = size + unit;
#else
	total_size = size;
#endif

	zone->top = (Word *) ((char *)base+total_size);
	zone->min = (Word *) ((char *)base+offset);
#ifndef SPEED
	zone->max = zone->min;
#endif

	/*
	** setup the redzone+hardzone
	*/
#ifdef	HAVE_MPROTECT
#ifdef	HAVE_SIGINFO
	zone->redzone_base = zone->redzone = (Word *)
			round_up((Unsigned)base + size - redsize, unit);
	if (mprotect((char *)zone->redzone, redsize + unit, MY_PROT) < 0)
	{
		char buf[2560];
		sprintf(buf, "unable to set %s#%d redzone\n"
			"base=%p, redzone=%p",
			zone->name, zone->id, zone->bottom, zone->redzone);
		fatal_error(buf);
	}
#else	/* !HAVE_SIGINFO */
	zone->hardmax = (Word *) ((char *)zone->top-unit);
	if (mprotect((char *)zone->hardmax, unit, MY_PROT) < 0)
	{
		char buf[2560];
		sprintf(buf, "unable to set %s#%d hardmax\n"
			"base=%p, hardmax=%p",
			zone->name, zone->id, zone->bottom, zone->hardmax);
		fatal_error(buf);
	}
#endif	/* HAVE_SIGINFO */
#endif	/* HAVE_MPROTECT */

	return zone;
}

void reset_zone(MemoryZone *zone)
{
#if	defined(HAVE_MPROTECT) && defined(HAVE_SIGINFO)
	zone->redzone = zone->redzone_base;

	if (mprotect((char *)zone->redzone,
		((char *)zone->top) - ((char *) zone->redzone), MY_PROT) < 0)
	{
		char buf[2560];
		sprintf(buf, "unable to reset %s#%d redzone\n"
			"base=%p, redzone=%p",
			zone->name, zone->id, zone->bottom, zone->redzone);
		fatal_error(buf);
	}
#endif
}

#if defined(HAVE_MPROTECT) && defined(HAVE_SIGINFO)
	/* try_munprotect is only useful if we have SIGINFO */

#define STDERR 2

#ifdef	SPEED

static void print_dump_stack(void)
{
	const char *msg = "You can get a stack dump by using grade debug\n";
	write(STDERR, msg, strlen(msg));
}

#else /* !SPEED */

static void print_dump_stack(void)
{
	int	i;
	int	start;
	int	count;
	char	buf[2560];

	strcpy(buf, "A dump of the det stack follows\n\n");
	write(STDERR, buf, strlen(buf));

	i = 0;
	while (i < dumpindex)
	{
		start = i;
		count = 1;
		i++;

		while (i < dumpindex &&
			strcmp(((char **)(dumpstack_zone->min))[i],
				((char **)(dumpstack_zone->min))[start]) == 0)
		{
			count++;
			i++;
		}

		if (count > 1)
			sprintf(buf, "%s * %d\n",
				((char **)(dumpstack_zone->min))[start], count);
		else
			sprintf(buf, "%s\n",
				((char **)(dumpstack_zone->min))[start]);

		write(STDERR, buf, strlen(buf));
	}

	strcpy(buf, "\nend of stack dump\n");
	write(STDERR, buf, strlen(buf));

}

#endif /* SPEED */

/*
** fatal_abort() prints an error message, possibly a stack dump, and then exits.
** It is like fatal_error(), except that it is safe to call
** from a signal handler.
*/

static void fatal_abort(void *context, const char *main_msg, int dump)
{
	char	*context_msg;

	context_msg = explain_context((ucontext_t *) context);
	write(STDERR, main_msg, strlen(main_msg));
	write(STDERR, context_msg, strlen(context_msg));

	if (dump)
		print_dump_stack();

	_exit(1);
}

static bool try_munprotect(void *addr, void *context)
{
	Word *    fault_addr;
	Word *    new_zone;
	MemoryZone *zone;

	fault_addr = (Word *) addr;

	zone = used_memory_zones;

	if (memdebug)
		fprintf(stderr, "caught fault at %p\n", (void *)addr);

	while(zone != NULL)
	{
		if (memdebug)
		{
			fprintf(stderr, "checking %s#%d: %p - %p\n",
				zone->name, zone->id, (void *) zone->redzone,
				(void *) zone->top);
		}

		if (zone->redzone <= fault_addr && fault_addr <= zone->top)
		{

			if (memdebug)
				fprintf(stderr, "address is in %s#%d redzone\n",
					zone->name, zone->id);

			return zone->handler(fault_addr, zone, context);
		}
		zone = zone->next;
	}

	if (memdebug)
	fprintf(stderr, "address not in any redzone.\n");

	return FALSE;
}

bool default_handler(Word *fault_addr, MemoryZone *zone, void *context)
{
    Word *new_zone;
    size_t zone_size;

    new_zone = (Word *) round_up((Unsigned) fault_addr + sizeof(Word), unit);

    if (new_zone <= zone->hardmax)
    {
	zone_size = (char *)new_zone - (char *)zone->redzone;

	if (memdebug)
	{
	    fprintf(stderr, "trying to unprotect %s#%d from %p to %p (%x)\n",
	    zone->name, zone->id, (void *) zone->redzone, (void *) new_zone,
	    (int)zone_size);
	}
	if (mprotect((char *)zone->redzone, zone_size,
	    PROT_READ|PROT_WRITE) < 0)
	{
	    char buf[2560];
	    sprintf(buf, "Mercury runtime: cannot unprotect %s#%d zone",
		zone->name, zone->id);
	    perror(buf);
	    exit(1);
	}

	zone->redzone = new_zone;

	if (memdebug)
	{
	    fprintf(stderr, "successful: %s#%d redzone now %p to %p\n",
		zone->name, zone->id, (void *) zone->redzone,
		(void *) zone->top);
	}
	return TRUE;
    }
    else
    {
	if (memdebug)
	{
	    fprintf(stderr, "can't unprotect last page of %s#%d\n",
		zone->name, zone->id);
	    fflush(stdout);
	}

	{
	    char buf[2560];
	    sprintf(buf,
		    "\nMercury runtime: memory zone %s#%d overflowed\n",
		    zone->name, zone->id);
	    fatal_abort(context, buf, FALSE);
	}
    }

    return FALSE;
}

bool null_handler(Word *fault_addr, MemoryZone *zone, void *context)
{
	return FALSE;
}

#else
/* not HAVE_MPROTECT || not HAVE_SIGINFO */

static bool try_munprotect(void *addr, void *context)
{
	return FALSE;
}

bool default_handler(Word *fault_addr, MemoryZone *zone, void *context)
{
	return FALSE;
}

bool null_handler(Word *fault_addr, MemoryZone *zone, void *context)
{
	return FALSE;
}

#endif /* not HAVE_MPROTECT || not HAVE_SIGINFO */

#ifdef	HAVE_SIGINFO

static void setup_signal(void)
{
	struct sigaction	act;

	act.sa_flags = SA_SIGINFO | SA_RESTART;
	if (sigemptyset(&act.sa_mask) != 0)
	{
		perror("Mercury runtime: cannot set clear signal mask");
		exit(1);
	}

	act.SIGACTION_FIELD = complex_bushandler;
	if (sigaction(SIGBUS, &act, NULL) != 0)
	{
		perror("Mercury runtime: cannot set SIGBUS handler");
		exit(1);
	}

	act.SIGACTION_FIELD = complex_segvhandler;
	if (sigaction(SIGSEGV, &act, NULL) != 0)
	{
		perror("Mercury runtime: cannot set SIGSEGV handler");
		exit(1);
	}
}

static void complex_bushandler(int sig, siginfo_t *info, void *context)
{
	fflush(stdout);

	if (sig != SIGBUS || !info || info->si_signo != SIGBUS)
	{
		fprintf(stderr, "\n*** Mercury runtime: ");
		fprintf(stderr, "caught strange bus error ***\n");
		exit(1);
	}

	fprintf(stderr, "\n*** Mercury runtime: ");
	fprintf(stderr, "caught bus error ***\n");

	if (info->si_code > 0)
	{
		fprintf(stderr, "cause: ");
		switch (info->si_code)
		{

	case BUS_ADRALN:
			fprintf(stderr, "invalid address alignment\n");
			break;

	case BUS_ADRERR:
			fprintf(stderr, "non-existent physical address\n");
			break;

	case BUS_OBJERR:
			fprintf(stderr, "object specific hardware error\n");
			break;

	default:
			fprintf(stderr, "unknown\n");
			break;

		}

		fprintf(stderr, "%s", explain_context((ucontext_t *) context));
		fprintf(stderr, "address involved: %p\n",
			(void *) info->si_addr);
	}

	dump_prev_locations();
	fprintf(stderr, "exiting from signal handler\n");
	exit(1);
}

static void explain_segv(siginfo_t *info, void *context)
{
	fflush(stdout);

	fprintf(stderr, "\n*** Mercury runtime: ");
	fprintf(stderr, "caught segmentation violation ***\n");

	if (!info) return;

	if (info->si_code > 0)
	{
		fprintf(stderr, "cause: ");
		switch (info->si_code)
		{

	case SEGV_MAPERR:
			fprintf(stderr, "address not mapped to object\n");
			break;

	case SEGV_ACCERR:
			fprintf(stderr, "bad permissions for mapped object\n");
			break;

	default:
			fprintf(stderr, "unknown\n");
			break;

		}

		fprintf(stderr, "%s", explain_context((ucontext_t *) context));
		fprintf(stderr, "address involved: %p\n",
			(void *) info->si_addr);

	}
}

static void complex_segvhandler(int sig, siginfo_t *info, void *context)
{
	if (sig != SIGSEGV || !info || info->si_signo != SIGSEGV)
	{
		fprintf(stderr, "\n*** Mercury runtime: ");
		fprintf(stderr, "caught strange segmentation violation ***\n");
		exit(1);
	}

	/*
	** If we're debugging, print the segv explanation messages
	** before we call try_munprotect.  But if we're not debugging,
	** only print them if try_munprotect fails.
	*/

	if (memdebug)
		explain_segv(info, context);

	if (try_munprotect(info->si_addr, context))
	{
		if (memdebug)
			fprintf(stderr, "returning from signal handler\n\n");

		return;
	}

	if (!memdebug)
		explain_segv(info, context);

	dump_prev_locations();
	fprintf(stderr, "exiting from signal handler\n");
	exit(1);
}

static char *explain_context(ucontext_t *context)
{
	static	char	buf[100];

#ifdef PC_ACCESS
#ifdef PC_ACCESS_GREG
	sprintf(buf, "PC at signal: %ld (%lx)\n",
		(long) context->uc_mcontext.gregs[PC_ACCESS],
		(long) context->uc_mcontext.gregs[PC_ACCESS]);
#else
	sprintf(buf, "PC at signal: %ld (%lx)\n",
		(long) context->uc_mcontext.PC_ACCESS,
		(long) context->uc_mcontext.PC_ACCESS);
#endif
#else
	/* if PC_ACCESS is not set, we don't know the context */
	/* therefore we return an empty string to be printed  */
	buf[0] = '\0';
#endif

	return buf;
}

#else

static void setup_signal(void)
{
	if (signal(SIGBUS, simple_sighandler) == SIG_ERR)
	{
		perror("cannot set SIGBUS handler");
		exit(1);
	}

	if (signal(SIGSEGV, simple_sighandler) == SIG_ERR)
	{
		perror("cannot set SIGSEGV handler");
		exit(1);
	}
}

static void simple_sighandler(int sig)
{
	fflush(stdout);
	fprintf(stderr, "*** Mercury runtime: ");

	switch (sig)
	{

case SIGBUS:
		fprintf(stderr, "caught bus error ***\n");
		break;

case SIGSEGV: 	fprintf(stderr, "caught segmentation violation ***\n");
		break;

default:	fprintf(stderr, "caught unknown signal %d ***\n", sig);
		break;

	}

	dump_prev_locations();
	fprintf(stderr, "exiting from signal handler\n");
	exit(1);
}

#endif

#ifdef	CONSERVATIVE_GC

void *allocate_bytes(size_t numbytes)
{
	void	*tmp;

	tmp = GC_MALLOC(numbytes);
	
	if (tmp == NULL)
		fatal_error("could not allocate memory");

	return tmp;
}

#else

#ifdef	PARALLEL
#error "shared memory not implemented"
#endif

void *allocate_bytes(size_t numbytes)
{
	void	*tmp;

	tmp = malloc(numbytes);
	
	if (tmp == NULL)
		fatal_error("could not allocate memory");

	return tmp;
}

#endif

void deallocate_memory(void *ptr)
{
#ifdef CONSERVATIVE_GC
	GC_FREE(ptr);
#elif	PARALLEL
#error	"shared memory not implemented"
#else
	free(ptr);
#endif
}
