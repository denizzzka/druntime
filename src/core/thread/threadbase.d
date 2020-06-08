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
import core.sync.mutex;
import core.stdc.stdlib : realloc;

private import core.internal.traits : classInstanceAlignment;
private enum mutexAlign = classInstanceAlignment!Mutex;
private enum mutexClassInstanceSize = __traits(classInstanceSize, Mutex);

package(core.thread) abstract class ThreadBase
{
    //
    // Standard thread data
    //
    Callable m_call; /// The thread function.
    size_t m_sz; /// The stack size for this thread.
    StackContext m_main;
    StackContext* m_curr;

    //
    // Local storage
    //
    /* private FIXME!*/ static ThreadBase sm_this;

    ///////////////////////////////////////////////////////////////////////////
    // Storage of Active Thread
    ///////////////////////////////////////////////////////////////////////////
    /* private FIXME! */ public void*               m_tlsgcdata;
    bool m_lock;

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

    //
    // All use of the global thread lists/array should synchronize on this lock.
    //
    // Careful as the GC acquires this lock after the GC lock to suspend all
    // threads any GC usage with slock held can result in a deadlock through
    // lock order inversion.
    @property static Mutex slock() nothrow @nogc
    {
        return cast(Mutex)_slock.ptr;
    }

    @property static Mutex criticalRegionLock() nothrow @nogc
    {
        return cast(Mutex)_criticalRegionLock.ptr;
    }

    __gshared align(mutexAlign) void[mutexClassInstanceSize] _slock;
    __gshared align(mutexAlign) void[mutexClassInstanceSize] _criticalRegionLock;

    __gshared ThreadBase  sm_tbeg;
    __gshared size_t      sm_tlen;

    //
    // Used for ordering threads in the global thread list.
    //
    public ThreadBase              prev; //FIXME: remove public
    public ThreadBase              next;

    __gshared StackContext*  sm_cbeg;

    // can't use core.internal.util.array in public code
    __gshared ThreadBase* pAboutToStart;
    __gshared size_t nAboutToStart;

    ///////////////////////////////////////////////////////////////////////////
    // Global Context List Operations
    ///////////////////////////////////////////////////////////////////////////

    //
    // Add a context to the global context list.
    //
    static void add( StackContext* c ) nothrow @nogc
    in
    {
        assert( c );
        assert( !c.next && !c.prev );
    }
    do
    {
        slock.lock_nothrow();
        scope(exit) slock.unlock_nothrow();
        assert(!suspendDepth); // must be 0 b/c it's only set with slock held

        if (sm_cbeg)
        {
            c.next = sm_cbeg;
            sm_cbeg.prev = c;
        }
        sm_cbeg = c;
    }

    //
    // Remove a context from the global context list.
    //
    // This assumes slock being acquired. This isn't done here to
    // avoid double locking when called from remove(Thread)
    static void remove( StackContext* c ) nothrow @nogc
    in
    {
        assert( c );
        assert( c.next || c.prev );
    }
    do
    {
        if ( c.prev )
            c.prev.next = c.next;
        if ( c.next )
            c.next.prev = c.prev;
        if ( sm_cbeg == c )
            sm_cbeg = c.next;
        // NOTE: Don't null out c.next or c.prev because opApply currently
        //       follows c.next after removing a node.  This could be easily
        //       addressed by simply returning the next node from this
        //       function, however, a context should never be re-added to the
        //       list anyway and having next and prev be non-null is a good way
        //       to ensure that.
    }

    ///////////////////////////////////////////////////////////////////////////
    // Global Thread List Operations
    ///////////////////////////////////////////////////////////////////////////

    //
    // Add a thread to the global thread list.
    //
    static void add( ThreadBase t, bool rmAboutToStart = true ) nothrow @nogc
    in
    {
        assert( t );
        assert( !t.next && !t.prev );
    }
    do
    {
        slock.lock_nothrow();
        scope(exit) slock.unlock_nothrow();
        assert(t.isRunning); // check this with slock to ensure pthread_create already returned
        assert(!suspendDepth); // must be 0 b/c it's only set with slock held

        if (rmAboutToStart)
        {
            size_t idx = -1;
            foreach (i, thr; pAboutToStart[0 .. nAboutToStart])
            {
                if (thr is t)
                {
                    idx = i;
                    break;
                }
            }
            assert(idx != -1);
            import core.stdc.string : memmove;
            memmove(pAboutToStart + idx, pAboutToStart + idx + 1, threadClassSize * (nAboutToStart - idx - 1));
            pAboutToStart =
                cast(ThreadBase*)realloc(pAboutToStart, threadClassSize * --nAboutToStart);
        }

        if (sm_tbeg)
        {
            t.next = sm_tbeg;
            sm_tbeg.prev = t;
        }
        sm_tbeg = t;
        ++sm_tlen;
    }

    //
    // Remove a thread from the global thread list.
    //
    static void remove( ThreadBase t ) nothrow @nogc
    in( t )
    {
        // Thread was already removed earlier, might happen b/c of thread_detachInstance
        if (!t.next && !t.prev && (sm_tbeg !is t))
            return;

        slock.lock_nothrow();
        {
            // NOTE: When a thread is removed from the global thread list its
            //       main context is invalid and should be removed as well.
            //       It is possible that t.m_curr could reference more
            //       than just the main context if the thread exited abnormally
            //       (if it was terminated), but we must assume that the user
            //       retains a reference to them and that they may be re-used
            //       elsewhere.  Therefore, it is the responsibility of any
            //       object that creates contexts to clean them up properly
            //       when it is done with them.
            remove( &t.m_main );

            if ( t.prev )
                t.prev.next = t.next;
            if ( t.next )
                t.next.prev = t.prev;
            if ( sm_tbeg is t )
                sm_tbeg = t.next;
            t.prev = t.next = null;
            --sm_tlen;
        }
        // NOTE: Don't null out t.next or t.prev because opApply currently
        //       follows t.next after removing a node.  This could be easily
        //       addressed by simply returning the next node from this
        //       function, however, a thread should never be re-added to the
        //       list anyway and having next and prev be non-null is a good way
        //       to ensure that.
        slock.unlock_nothrow();
    }

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

    ///////////////////////////////////////////////////////////////////////////
    // Thread Accessors
    ///////////////////////////////////////////////////////////////////////////

    /**
     * Provides a reference to the calling thread.
     *
     * Returns:
     *  The thread object representing the calling thread.  The result of
     *  deleting this object is undefined.  If the current thread is not
     *  attached to the runtime, a null reference is returned.
     */
    static ThreadBase getThis() @safe nothrow @nogc
    {
        // NOTE: This function may not be called until thread_init has
        //       completed.  See thread_suspendAll for more information
        //       on why this might occur.
        return sm_this;
    }

    bool isRunning() nothrow @nogc;
}

extern (C) void* getStackBottom() nothrow @nogc;
extern (C) size_t threadClassSize() pure nothrow @nogc;

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
    public /* FIXME */ alias rt_tlsgc_scan =
        externDFunc!("rt.tlsgc.scan", void function(void*, scope ScanDg) nothrow);

    alias rt_tlsgc_processGCMarks =
        externDFunc!("rt.tlsgc.processGCMarks", void function(void*, scope IsMarkedDg) nothrow);
}


/**
 * Indicates the kind of scan being performed by $(D thread_scanAllType).
 */
enum ScanType
{
    stack, /// The stack and/or registers are being scanned.
    tls, /// TLS data is being scanned.
}

alias ScanAllThreadsFn = void delegate(void*, void*) nothrow; /// The scanning function.
alias ScanAllThreadsTypeFn = void delegate(ScanType, void*, void*) nothrow; /// ditto

/**
 * The main entry point for garbage collection.  The supplied delegate
 * will be passed ranges representing both stack and register values.
 *
 * Params:
 *  scan        = The scanner function.  It should scan from p1 through p2 - 1.
 *
 * In:
 *  This routine must be preceded by a call to thread_suspendAll.
 */
extern (C) void thread_scanAllType( scope ScanAllThreadsTypeFn scan ) nothrow
in
{
    assert( suspendDepth > 0 );
}
do
{
    callWithStackShell(sp => scanAllTypeImpl(scan, sp));
}

extern (C) void callWithStackShell(scope void delegate(void* sp) nothrow fn) nothrow;

// Used for suspendAll/resumeAll below.
package __gshared uint suspendDepth = 0;

private void scanAllTypeImpl( scope ScanAllThreadsTypeFn scan, void* curStackTop ) nothrow
{
    ThreadBase  thisThread  = null;
    void*   oldStackTop = null;

    if ( ThreadBase.sm_tbeg )
    {
        thisThread  = ThreadBase.getThis();
        if ( !thisThread.m_lock )
        {
            oldStackTop = thisThread.m_curr.tstack;
            thisThread.m_curr.tstack = curStackTop;
        }
    }

    scope( exit )
    {
        if ( ThreadBase.sm_tbeg )
        {
            if ( !thisThread.m_lock )
            {
                thisThread.m_curr.tstack = oldStackTop;
            }
        }
    }

    // NOTE: Synchronizing on Thread.slock is not needed because this
    //       function may only be called after all other threads have
    //       been suspended from within the same lock.
    if (ThreadBase.nAboutToStart)
        scan(ScanType.stack, ThreadBase.pAboutToStart, ThreadBase.pAboutToStart + ThreadBase.nAboutToStart);

    for ( StackContext* c = ThreadBase.sm_cbeg; c; c = c.next )
    {
        version (StackGrowsDown)
        {
            // NOTE: We can't index past the bottom of the stack
            //       so don't do the "+1" for StackGrowsDown.
            if ( c.tstack && c.tstack < c.bstack )
                scan( ScanType.stack, c.tstack, c.bstack );
        }
        else
        {
            if ( c.bstack && c.bstack < c.tstack )
                scan( ScanType.stack, c.bstack, c.tstack + 1 );
        }
    }

    for ( ThreadBase t = ThreadBase.sm_tbeg; t; t = t.next )
        tls_gc_scan(scan, t);
}

extern (C) void tls_gc_scan(scope ScanAllThreadsTypeFn scan, ThreadBase t) nothrow;

/**
 * Suspend all threads but the calling thread for "stop the world" garbage
 * collection runs.  This function may be called multiple times, and must
 * be followed by a matching number of calls to thread_resumeAll before
 * processing is resumed.
 *
 * Throws:
 *  ThreadError if the suspend operation fails for a running thread.
 */
extern (C) void thread_suspendAll() nothrow
{
    // NOTE: We've got an odd chicken & egg problem here, because while the GC
    //       is required to call thread_init before calling any other thread
    //       routines, thread_init may allocate memory which could in turn
    //       trigger a collection.  Thus, thread_suspendAll, thread_scanAll,
    //       and thread_resumeAll must be callable before thread_init
    //       completes, with the assumption that no other GC memory has yet
    //       been allocated by the system, and thus there is no risk of losing
    //       data if the global thread list is empty.  The check of
    //       Thread.sm_tbeg below is done to ensure thread_init has completed,
    //       and therefore that calling Thread.getThis will not result in an
    //       error.  For the short time when Thread.sm_tbeg is null, there is
    //       no reason not to simply call the multithreaded code below, with
    //       the expectation that the foreach loop will never be entered.
    if ( !multiThreadedFlag && ThreadBase.sm_tbeg )
    {
        if ( ++suspendDepth == 1 )
            thread_suspend( ThreadBase.getThis() );

        return;
    }

    ThreadBase.slock.lock_nothrow();
    {
        if ( ++suspendDepth > 1 )
            return;

        ThreadBase.criticalRegionLock.lock_nothrow();
        scope (exit) ThreadBase.criticalRegionLock.unlock_nothrow();
        size_t cnt;
        auto t = ThreadBase.sm_tbeg;
        while (t)
        {
            auto tn = t.next;
            if (thread_suspend(t))
                ++cnt;
            t = tn;
        }

        threads_wait_for_suspend(cnt);
    }
}

extern (C) bool thread_suspend(ThreadBase t) nothrow;
extern (C) void threads_wait_for_suspend(size_t cnt) nothrow;
package __gshared bool multiThreadedFlag = false; // Used for needLock
