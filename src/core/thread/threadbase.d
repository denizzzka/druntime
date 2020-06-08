/**
 * The threadbase module provides OS-independent code
 * for thread storage and management.
 *
 * Copyright: Copyright Sean Kelly 2005 - 2012.
 * License: Distributed under the
 *      $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0).
 *    (See accompanying file LICENSE)
 * Authors:   Sean Kelly, Walter Bright, Alex Rønne Petersen, Martin Nowak
 * Source:    $(DRUNTIMESRC core/thread/threadbase.d)
 */

module core.thread.threadbase;

import core.thread.context;

abstract class ThreadBase
{
package(core.thread):
    //
    // Standard thread data
    //
    Callable m_call; /// The thread function.
    size_t m_sz; /// The stack size for this thread.
    StackContext m_main;
    StackContext* m_curr;

    ///////////////////////////////////////////////////////////////////////////
    // Storage of Active Thread
    ///////////////////////////////////////////////////////////////////////////
    /* private FIXME! */ public void*               m_tlsgcdata;

    ///////////////////////////////////////////////////////////////////////////
    // GC Scanning Support
    ///////////////////////////////////////////////////////////////////////////


    // NOTE: The GC scanning process works like so:
    //
    //          1. Suspend all threads.
    //          2. Scan the stacks of all suspended threads for roots.
    //          3. Resume all threads.
    //
    //       Step 1 and 3 require a list of all threads in the system, while
    //       step 2 requires a list of all thread stacks (each represented by
    //       a Context struct).  Traditionally, there was one stack per thread
    //       and the Context structs were not necessary.  However, Fibers have
    //       changed things so that each thread has its own 'main' stack plus
    //       an arbitrary number of nested stacks (normally referenced via
    //       m_curr).  Also, there may be 'free-floating' stacks in the system,
    //       which are Fibers that are not currently executing on any specific
    //       thread but are still being processed and still contain valid
    //       roots.
    //
    //       To support all of this, the Context struct has been created to
    //       represent a stack range, and a global list of Context structs has
    //       been added to enable scanning of these stack ranges.  The lifetime
    //       (and presence in the Context list) of a thread's 'main' stack will
    //       be equivalent to the thread's lifetime.  So the Ccontext will be
    //       added to the list on thread entry, and removed from the list on
    //       thread exit (which is essentially the same as the presence of a
    //       Thread object in its own global list).  The lifetime of a Fiber's
    //       context, however, will be tied to the lifetime of the Fiber object
    //       itself, and Fibers are expected to add/remove their Context struct
    //       on construction/deletion.

    __gshared ThreadBase  sm_tbeg;
    __gshared size_t      sm_tlen;

    //
    // Used for ordering threads in the global thread list.
    //
    public ThreadBase              prev; //FIXME: remove public
    public ThreadBase              next;

    this(size_t sz = 0) @safe pure nothrow @nogc
    {
        m_sz = sz;
        m_curr = &m_main;
    }

    this( void function() fn, size_t sz = 0 ) @safe pure nothrow @nogc
    in( fn )
    {
        this(sz);
        m_call = fn;
    }

    this( void delegate() dg, size_t sz = 0 ) @safe pure nothrow @nogc
    in( dg )
    {
        this(sz);
        m_call = dg;
    }

    void tlsGCdataInit() nothrow @nogc
    {
        m_tlsgcdata = rt_tlsgc_init();
    }

    void dataStorageInit() nothrow
    {
        assert( m_curr is &m_main );

        m_main.bstack = getStackBottom();
        m_main.tstack = m_main.bstack;
        tlsGCdataInit();
    }

    void dataStorageDestroy() nothrow @nogc
    {
        rt_tlsgc_destroy( m_tlsgcdata );
        m_tlsgcdata = null;
    }

    void dataStorageDestroyIfAvail() nothrow @nogc
    {
        if( m_tlsgcdata )
            dataStorageDestroy();
    }
}

extern (C) void* getStackBottom() nothrow @nogc;

alias IsMarkedDg = int delegate( void* addr ) nothrow; /// The isMarked callback function.

/**
 * This routine allows the runtime to process any special per-thread handling
 * for the GC.  This is needed for taking into account any memory that is
 * referenced by non-scanned pointers but is about to be freed.  That currently
 * means the array append cache.
 *
 * Params:
 *  isMarked = The function used to check if $(D addr) is marked.
 *
 * In:
 *  This routine must be called just prior to resuming all threads.
 */
extern(C) void thread_processGCMarks( scope IsMarkedDg isMarked ) nothrow
{
    for ( ThreadBase t = ThreadBase.sm_tbeg; t; t = t.next )
    {
        /* Can be null if collection was triggered between adding a
         * thread and calling rt_tlsgc_init.
         */
        if (t.m_tlsgcdata !is null)
            rt_tlsgc_processGCMarks(t.m_tlsgcdata, isMarked);
    }
}

private
{
    // interface to rt.tlsgc
    import core.internal.traits : externDFunc;

    alias rt_tlsgc_init = externDFunc!("rt.tlsgc.init", void* function() nothrow @nogc);
    alias rt_tlsgc_destroy = externDFunc!("rt.tlsgc.destroy", void function(void*) nothrow @nogc);

    alias ScanDg = void delegate(void* pstart, void* pend) nothrow;
    alias rt_tlsgc_scan =
        externDFunc!("rt.tlsgc.scan", void function(void*, scope ScanDg) nothrow);

    alias rt_tlsgc_processGCMarks =
        externDFunc!("rt.tlsgc.processGCMarks", void function(void*, scope IsMarkedDg) nothrow);
}
