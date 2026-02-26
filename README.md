# TrackedAllocator — Shuriken Library

A wrapper allocator for Zig that tracks memory usage, allocation statistics, and lifetime metrics without interfering with the underlying allocator.

## Requirements

- Zig `0.15` or later

## Installation

### Using `build.zig.zon`

Add the dependency to your `build.zig.zon`:

```zig
.dependencies = .{
    .tracked_allocator = .{
        .path = "path/to/tracked_allocator",
    },
},
```

Then in your `build.zig`:

```zig
const tracked_allocator = b.dependency("tracked_allocator", .{});
exe.root_module.addImport("tracked_allocator", tracked_allocator.module("tracked_allocator"));
```

## Importing

```zig
const TrackedAllocator = @import("tracked_allocator").TrackedAllocator;
```

## Quick Start

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();

var tracked = TrackedAllocator.init(gpa.allocator());
defer tracked.memory_logs.deinit();

const allocator = tracked.allocator();

const buf = try allocator.alloc(u8, 1024);
defer allocator.free(buf);

std.debug.print("Current bytes: {d}\n", .{tracked.getCurrentUsage()});
```

## API

### Initialization

```zig
pub fn init(parent: std.mem.Allocator) TrackedAllocator
pub fn allocator(self: *TrackedAllocator) std.mem.Allocator
```

`TrackedAllocator` wraps any `std.mem.Allocator`. Always call `tracked.memory_logs.deinit()` before the parent allocator is deinitialized.

### Stats

| Function | Description |
|---|---|
| `getCurrentUsage()` | Current bytes actively allocated |
| `getTotalBytes()` | Total bytes allocated over the lifetime |
| `getPeakUsage()` | Highest `current_bytes` ever reached |
| `getBytesFreed()` | Total bytes freed |
| `getTotalAllocAndFrees()` | Tuple of total allocations and deallocations |
| `getAvgAlloc()` | Average allocation size in bytes |
| `getAvgDealloc()` | Average deallocation size in bytes |
| `getAvgLifeTime()` | Average time in ms an allocation lives before being freed |
| `getChurnRate()` | Average time in ms between allocations |
| `getFragRatio()` | Ratio of current to total bytes, indicates fragmentation |
| `getEfficiency()` | Percentage of allocated bytes that have been freed |
| `getTopAlloc()` | Size of the largest allocation ever made |
| `getActiveAlloc()` | Number of currently live allocations |
| `percentileMemory(pct)` | Percentile of active allocation sizes |

### Histograms

```zig
tracked.makeAllocHistogram(); // logs allocation count per size bucket
tracked.makeByteHistogram();  // logs byte usage per size bucket
```

Size buckets: `Tiny` (1–64), `Small` (65–256), `Medium` (257–4096), `Large` (4097–65536), `Giant` (65537+).

### Logging

```zig
try tracked.logAllStats(); // logs all stats, histograms, and active memory entries
```

## Notes

- Zero byte allocations are not tracked.
- `TrackedAllocator` is not thread-safe by default. If sharing a single instance across threads, wrap vtable calls with a `std.Thread.Mutex`.
- `percentileMemory` operates only on **active** allocations present in `memory_logs`, not historical ones.
- `memory_logs.deinit()` must be called before the parent allocator deinits to avoid use-after-free.
