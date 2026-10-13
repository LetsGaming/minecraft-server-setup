# Chunk prune benchmarks

Baseline for the scan, so a change can be judged against numbers instead of estimates.

## Run

```
node tests/bench/bench-prune.cjs --chunks=200000              # synthetic world, removed afterwards
node tests/bench/bench-prune.cjs --chunks=1000000 --keep      # keep it to scan again
node tests/bench/bench-prune.cjs --world=/path/to/server      # a real world, read only
```

`--padding` sets the chunk size, `--seed` the layout. The harness only scans; it never
applies, so a real world is safe. Output is one JSON object: `scanMs`, `phasesMs`
(read, header, inflate, nbt, classify, buffer, slotBytes, assemble), `counts`,
`chunksPerSecond`, `peakRssMb`. `prune-chunks.js --scan --profile` gives the same
phases for a world the script already knows.

## Baseline (single thread, 16 logical cores, Node 24, Windows, SSD)

Synthetic world, 30 % of chunks used, small chunks (about one sector each), so the
inflate and NBT shares are lower bounds for real worlds.

| chunks | scan | chunks/s | read | inflate | nbt | other | peak RSS |
|---|---|---|---|---|---|---|---|
| 20,000 | 174 ms | 115k | 30 ms | 96 ms | 26 ms | 10 ms | 157 MB |
| 200,000 | 1.7 s | 116k | 336 ms | 1,024 ms | 263 ms | 55 ms | 278 MB |

Inflate is about 60 % of the scan, file reads 20 %, the NBT walk 15 %. Real worlds have
larger chunks, so expect lower chunks/s; run the harness against the real world and
add its numbers here before starting engine changes that depend on the split.

## Engine v2 (record cache, worker threads, per-region buffer)

Same synthetic world, 200,000 chunks, cold cache unless noted. Time is reading plus the
decision, as `prune-chunks.js --scan` does it.

| run | time |
|---|---|
| baseline, single thread, no cache | 1.8 s |
| single thread, writes the cache | 2.2 s |
| 4 worker threads (the default on a 5 core host or more) | 0.76 s |
| 8 worker threads | 0.58 s |
| repeat scan, nothing changed (`--cache`) | 0.18 s |

The repeat scan is about 10 % of a full scan. `--workers=<n>` on `prune-chunks.js` and on
the bench sets the thread count; the default is the core count minus one, at most 4.
Changing a threshold, radius, buffer or zone recomputes over the cached records and reads
no region file.
