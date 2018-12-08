---
title: "Linux Memory Alert Caused By Slab"
date: 2018-11-27
draft: false
comments: true 
showpagemeta: true
showcomments: true
---

*Note: English is not my primary language. If you find the content confusing, you can email me for explanation.*

> `buff/cache` of `free` is not same as `Buffer` + `Cached` from `/proc/meminfo`. And the way we used to measure `memory acutal usage percent` is problematic.

# Background

Recently I encountered a colleague's feedback:

> 'Memory usage percent greater than 90%' are reported by an alert, but we find that the actual usage is only 50%.

The "50%" came from `free -g`:

```bash
# free - g
            total   used    free    shared  buff/cache  available
Mem:        31      17      0       0       13          6    
Swap:       0       0       0
```
It seems that 13 GB of the memory is `buff/cache`, and **this part can be reclaimed when needed**。In the alert rule，we calculate the `memory actual usage percent` by the following formula(same as [Sigar](https://github.com/hyperic/sigar) and [Alibaba CloudMonitor](https://help.aliyun.com/knowledge_detail/38842.html))：

```
(MemTotal - (MemFree + Buffers + Cached)) / MemTotal
```

According to the output of `free`, we *should* get 60% for this formula, why did the alert fire?

# `buff/cache` is not only `Buffer` + `Cached`

Output of `/proc/meminfo` gave me the answer:

```bash
# cat /proc/meminfo
MemTotal:       32780412 kB
MemFree:          715188 kB
MemAvailable:    7264108 kB
Buffers:           16708 kB
Cached:           799300 kB
SwapCached:            0 kB
Active:         17793344 kB
Inactive:         375212 kB
Active(anon):   17354764 kB
Inactive(anon):     1132 kB
Active(file):     438580 kB
Inactive(file):   374080 kB
Unevictable:           0 kB
Mlocked:               0 kB
SwapTotal:             0 kB
SwapFree:              0 kB
Dirty:               832 kB
Writeback:             0 kB
AnonPages:      17352688 kB
Mapped:           146796 kB
Shmem:              3328 kB
Slab:           13096500 kB
SReclaimable:    6139152 kB
SUnreclaim:      6957348 kB
KernelStack:       58912 kB
PageTables:       100304 kB
NFS_Unstable:          0 kB
Bounce:                0 kB
WritebackTmp:          0 kB
CommitLimit:    16390204 kB
Committed_AS:   37371552 kB
VmallocTotal:   34359738367 kB
VmallocUsed:      299088 kB
VmallocChunk:   34359282792 kB
HardwareCorrupted:     0 kB
AnonHugePages:   8628224 kB
HugePages_Total:       0
HugePages_Free:        0
HugePages_Rsvd:        0
HugePages_Surp:        0
Hugepagesize:       2048 kB
DirectMap4k:      460672 kB
DirectMap2M:    22607872 kB
DirectMap1G:    12582912 kB
```
**`SLAB` used up to 13 GB of the memory**, while the sum of `Buffer` and `Cached` is 400+ MB：

![memory-graph](/img/memory/memory-graph.png)

Apparently, `buff/cache` of `free` command is not equal to `Buffer` plus `Cached` from `/proc/meminfo`. `free`'s man page explains why:

```
       buffers
              Memory used by kernel buffers (Buffers in /proc/meminfo)
 
       cache  Memory used by the page cache and slabs (Cached and Slab in /proc/meminfo)
 
       buff/cache
              Sum of buffers and cache
 
       available
              Estimation of how much memory is available for starting new applications, without swapping. Unlike the data provided by the cache or free fields, this  field  takes  into
              account  page  cache and also that not all reclaimable memory slabs will be reclaimed due to items being in use (MemAvailable in /proc/meminfo, available on kernels 3.14,
              emulated on kernels 2.6.27+, otherwise the same as free)
```
In addtion to its name, `buff/cache` also includes the `SLAB`. But `SLAB` is not considered in our nice formula. `free` fools you, problem solved.

Is that true?

Not exactly. Part of the `SLAB` is reclaimable, so acutally the server had more "available" memory space than our alert rule indicated. In `/proc/meminfo`, `SReclaimable` and `SUnreclaim` represents the reclaimable `SLAB` size and the un-reclaimable `SLAB` size. We had around 6 GB relaimable `SLAB` in that case. 

It's the formula used in our alert rule fools us. 

# So, How can we imporve?

Enter `MemAvailable`.

`MemAvailable` also presents in the output of `free`:
```
available
          Estimation of how much memory is available for starting new applications, without swapping. Unlike the data provided by the cache or free fields, this  field  takes  into
          account  page  cache and also that not all reclaimable memory slabs will be reclaimed due to items being in use (MemAvailable in /proc/meminfo, available on kernels 3.14,
          emulated on kernels 2.6.27+, otherwise the same as free)
```

The sounds reasonable, but before we alter the alert rule, we should first clarify how `MemAvailable` calculated. [This pull request](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=34e431b0ae398fc54ea69ff85ec700722c9da773) shows the idea:

```C
+   for_each_zone(zone)
+       wmark_low += zone->watermark[WMARK_LOW];
+
+   /*
+    * Estimate the amount of memory available for userspace allocations,
+    * without causing swapping.
+    *
+    * Free memory cannot be taken below the low watermark, before the
+    * system starts swapping.
+    */
+   available = i.freeram - wmark_low;
+
+   /*
+    * Not all the page cache can be freed, otherwise the system will
+    * start swapping. Assume at least half of the page cache, or the
+    * low watermark worth of cache, needs to stay.
+    */
+   pagecache = pages[LRU_ACTIVE_FILE] + pages[LRU_INACTIVE_FILE];
+   pagecache -= min(pagecache / 2, wmark_low);
+   available += pagecache;
+
+   /*
+    * Part of the reclaimable swap consists of items that are in use,
+    * and cannot be freed. Cap this estimate at the low watermark.
+    */
+   available += global_page_state(NR_SLAB_RECLAIMABLE) -
+            min(global_page_state(NR_SLAB_RECLAIMABLE) / 2, wmark_low);
+
+   if (available < 0)
+       available = 0;
+
    /*
     * Tagged format, for easy grepping and expansion.
     */
    seq_printf(m,
        "MemTotal:       %8lu kB\n"
        "MemFree:        %8lu kB\n"
+       "MemAvailable:   %8lu kB\n"
```
It is important that we **cannot safely relaim all of the memory spaces used by `page cache` and `SlabReclaimable`**, which is also opposite to the assumption of the first formula(we think OS can reclaim all the page cache when needed). The reason is that Linux server will suffer poor performance by lacking of enough `page cache` or `slab`. The `MemAvailable` **estimate** that page cache / 2 and slab_reclaimable / 2 are not reclaimable.

# Solution

Finally, we change our formula to `(MemTotal - MemAvailable) / MemTotal`. Now we can easily explain to our engineers that "verify the alert by the 'available' part of `free -m`", and the memory alert is more urgent and useful for us.

But this estimation is not perfect, consider that:

* we have a kafka broker running on the server, kafka use page cache heavily, it is dangerous to estimate that we can reclaim 1/2 of the page cache;
* we have an `Apache Storm` node, which used a large amount of `dentry_cache` due to frequent file operations. Restricting 1/2 `SlabReclaimable` to be reclaim is conservative, which leads to "fake alert";

Maybe we will tune the alert rule according to the properties of different service in the future. But remember that `alert` is best effort, tuning alert rule for different service can be complicated and hard to maintain. Keep "MemAvailable is an estimation" in mind is good for debugging, and use this estimation as an general alert condition is good enough for alerting.

## References

[Interpreting /proc/meminfo and free output for Red Hat Enterprise Linux 5, 6 and 7](https://access.redhat.com/solutions/406773)

[Measure Linux web server memory usage correctly](https://haydenjames.io/measure-web-server-memory-usage-correctly/)