/**
* Contains the garbage collector configuration.
*
* Copyright: Copyright Digital Mars 2016
* License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
*/

module core.gc.config;

import core.stdc.stdio;
import core.internal.parseoptions;

__gshared Config config;

struct Config
{
    bool disable;            // start disabled
    ubyte profile;           // enable profiling with summary when terminating program
    string gc = "conservative"; // select gc implementation conservative|precise|manual

    size_t initReserve;      // initial reserve (in bytes)
    size_t minPoolSize = 1024 * 1024 * 1;  // initial and minimum pool size (in bytes)
    size_t maxPoolSize = 1024 * 1024 * 64; // maximum pool size (in bytes)
    size_t incPoolSize = 1024 * 1024 * 3;  // pool size increment (in bytes)
    uint parallel = 99;      // number of additional threads for marking (limited by cpuid.threadsPerCPU-1)
    float heapSizeFactor = 2.0; // heap size to used memory ratio
    string cleanup = "collect"; // select gc cleanup method none|collect|finalize

@nogc nothrow:

    bool initialize()
    {
        return initConfigOptions(this, "gcopt");
    }

    void help() @nogc nothrow
    {
        import core.gc.registry : registeredGCFactories;

        printf("GC options are specified as white space separated assignments:
    disable:0|1    - start disabled (%d)
    profile:0|1|2  - enable profiling with summary when terminating program (%d)
    gc:".ptr, disable, profile);
        foreach (i, entry; registeredGCFactories)
        {
            if (i) printf("|");
            printf("%.*s", cast(int) entry.name.length, entry.name.ptr);
        }
        printf(" - select gc implementation (default = conservative)

    initReserve:N  - initial memory to reserve in bytes (%lld)
    minPoolSize:N  - initial and minimum pool size in bytes (%lld)
    maxPoolSize:N  - maximum pool size in bytes (%lld)
    incPoolSize:N  - pool size increment bytes (%lld)
    parallel:N     - number of additional threads for marking (%lld)
    heapSizeFactor:N - targeted heap size to used memory ratio (%g)
    cleanup:none|collect|finalize - how to treat live objects when terminating (collect)
".ptr,
               cast(long)initReserve, cast(long)minPoolSize,
               cast(long)maxPoolSize, cast(long)incPoolSize,
               cast(long)parallel, heapSizeFactor);
    }

    string errorName() @nogc nothrow { return "GC"; }
}
