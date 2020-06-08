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

    //
    // Initializes a thread object which has no associated executable function.
    // This is used for the main thread initialized in thread_init().
    //
    this(size_t sz = 0) @safe pure nothrow @nogc
    {
        m_sz = sz;
        m_curr = &m_main;
    }
}
