# The Coding Plan — Animated ASCII in Fastfetch

> A step-by-step implementation guide. Each step explains *what* to change,
> *where* in the existing code, and *why* it's done that way — so the choices
> are understood, not just copied.

---

## 0. The Core Idea (read this first)

Fastfetch already has a **dynamic refresh loop**. The `-w` / `--dynamic-interval`
flag sets `instance.state.dynamicInterval` (in milliseconds). When that value
is `> 0`, the `run()` function in `src/fastfetch.c` enters a `while(true)` loop
that:

1. Prints the system info
2. Clears to end-of-screen (`\e[J`)
3. Sleeps for `dynamicInterval` ms
4. Moves cursor home (`\e[H`)
5. Reprints everything — forever

The logo is printed **once**, *before* the loop, and cached in
`logoLineCache`. On subsequent ticks the cache is empty, so the old logo just
persists on screen visually while the info refreshes beside it.

**Our feature:** each tick, instead of reusing the frozen logo, we advance to
the **next frame** from a directory of `.txt` files and rebuild the cache.
The existing loop does all the screen management; we only feed it new frames.

**Design principle guiding this plan:**
> *Extension over modification.* We add a hook inside the existing loop. We do
> not rewrite the loop, the flag parsing, the signal handling, or the
> alternate-buffer logic. Those are proven and tested — we leave them closed
> and extend open.

---

## The Existing Pieces We Build On

| File | Existing responsibility | How we relate to it |
|------|------------------------|---------------------|
| `src/options/logo.h` | Defines `FFLogoType` enum + `FFOptionsLogo` struct | Add a new enum value `FF_LOGO_TYPE_ANIMATE` |
| `src/options/logo.c` | Parses `--logo-type`, `--logo`, JSON config | Teach it to recognize `"animate"` and treat `source` as a directory |
| `src/fastfetch.h` | Defines `FFstate` (holds `dynamicInterval`, `logoLineCache`, etc.) | Add animation state fields as siblings to `dynamicInterval` |
| `src/logo/logo.h` | Public logo API (`ffLogoPrint`, `ffLogoPrintChars`, etc.) | Declare our new `ffLogoPrintAnimateFrame()` |
| `src/logo/logo.c` | The rendering engine: `logoLineCacheBuild`, `ffLogoPrintChars`, `ffLogoPrintLine` | Add the frame-loading + cache-rebuild function |
| `src/fastfetch.c` `run()` | The dynamic loop | Insert **two hook points** (before loop + inside loop) |
| `src/common/impl/init.c` | Inits and destroys `FFstate` | Init/destroy our new state fields |

---

## Step 1 — Add the logo type to the enum

**File:** `src/options/logo.h`

**What:** Add one value to `FFLogoType`:

```c
FF_LOGO_TYPE_ANIMATE,   // directory of .txt frames, cycled on each dynamic tick
```

**Where:** In the enum, logically near `FF_LOGO_TYPE_FILE` since an animation
is conceptually "many files."

**Why here:** Every logo variant in fastfetch is an enum value. `FILE` loads
one text file; `FILE_RAW` loads one without color replacement; `IMAGE_*` load
images. `ANIMATE` is the natural sibling — "a directory of files cycled over
time." Putting it in the enum makes it flow through *all* existing plumbing:
CLI parsing, JSON config, the `logoTryKnownType()` dispatch, and the
`ffOptionsGenerateLogoJsonConfig` serializer. One enum value, free routing.

---

## Step 2 — Add animation state to `FFstate`

**File:** `src/fastfetch.h`

**What:** Add fields to the `FFstate` struct:

```c
// Animation state — persists across dynamic ticks (the cache is cleared each tick)
FFlist animateFrames;     // list of FFstrbuf, one per loaded frame
uint32_t animateIndex;    // current frame index, wraps around
bool animateReady;        // whether the directory has been scanned
```

**Why `FFstate` and not `FFOptionsLogo`:** This is the crucial distinction.
- `FFconfig` / `FFOptionsLogo` = **configuration** — what the user asked for
  (the directory path, the logo type). Set once, read many times.
- `FFstate` = **runtime state** — things that *change during execution*
  (`logoWidth`, `keysHeight`, `dynamicInterval`, `logoLineCache`).

The frame index advances every tick. The loaded frame list is built once and
reused. Both are runtime state, so they belong in `FFstate` — right next to
`dynamicInterval` and `logoLineCache`, which are their closest kin.

**Why `animateReady`:** Directory scanning is I/O. We don't want to scan on
every tick, nor do we want to scan at startup if the user never uses animation
(avoid slowing down the common case). A lazy-init flag lets us scan on first
use and skip afterward. This mirrors how `logoLineCache` is built lazily on
first print.

**Why a `FFlist` of `FFstrbuf`:** Each frame is arbitrary-length text (your
skulls are ~22 lines). `FFstrbuf` is fastfetch's native string type, used
everywhere in the codebase. `FFlist` is its native dynamic array. Using the
project's own types keeps memory management consistent — `ffListDestroy` and
`ffStrbufDestroy` are already wired into the init/destroy lifecycle.

---

## Step 3 — Parse the `animate` logo type

**File:** `src/options/logo.c`

**What:** In **two** places, add `"animate"` to the enum lookup tables:

1. `ffOptionsParseLogoCommandLine` (the `--logo-type` enum list, ~line 54)
2. `ffOptionsParseLogoJsonConfig` (the JSON `"type"` enum list, ~line 248)

And in `ffOptionsGenerateLogoJsonConfig` (~line 438), add the `case` for
round-tripping the config.

**Why two places:** Fastfetch parses CLI args *and* JSON config files
(`config.jsonc`). Both paths need to recognize `"animate"` so the user can do
either:

```sh
fastfetch --logo-type animate --logo ~/frames/ -w 200
```

or in `~/.config/fastfetch/config.jsonc`:
```jsonc
{ "logo": { "type": "animate", "source": "~/frames/" } }
```

**What `source` means for animate:** For `FF_LOGO_TYPE_FILE`, `source` is a
file path. For `FF_LOGO_TYPE_ANIMATE`, `source` is a **directory path**. The
path-resolution logic in `updateLogoPath()` (`logo.c:453`) checks
`ffPathExists(..., FF_PATHTYPE_FILE)` — we'll need a directory variant
(`FF_PATHTYPE_FOLDER`) when we implement loading. This is the one place we
diverge from the file-logo pattern.

**No new flag needed:** We deliberately reuse `-w` / `--dynamic-interval` for
the tick speed. One frame advances per tick. Simpler UX, zero new flag
plumbing. If the user wants 200ms animation, they pass `-w 200` — same flag
that already controls the refresh.

---

## Step 4 — Implement the frame loader + cache rebuilder

**File:** `src/logo/logo.c` (and declare in `src/logo/logo.h`)

**What:** A new function:

```c
void ffLogoPrintAnimateFrame(void);
```

Its job, in order:

1. **Lazy scan (first call only):** If `!instance.state.animateReady`, scan
   `options->source` directory. Read every `*.txt` file into a `FFstrbuf`,
   push into `instance.state.animateFrames`. Sort by filename so frame order
   is deterministic (skull01 → skull02 → ...). Set `animateReady = true`.
   If the directory is empty or missing, fall back to `ffLogoPrintDetected()`.

2. **Select frame:** `index = instance.state.animateIndex`

3. **Rebuild the cache:** Call the *existing* `ffLogoPrintChars(frame, true)`.
   This is the beauty — `ffLogoPrintChars` already does color replacement,
   width calculation, padding, and `logoLineCacheBuild`. We reuse it verbatim.
   For `LEFT` position it only builds the cache (doesn't print), which is
   exactly what we want.

4. **Advance:** `animateIndex = (animateIndex + 1) % animateFrames.length`

**Why reuse `ffLogoPrintChars`:** This function is 60 lines of careful logic —
UTF-8 width handling, ANSI escape passthrough, `$1`-`$9` color replacement,
carry-color tracking, padding. Rewriting any of it would be both wasteful and
bug-prone. Our frame is just a string; `ffLogoPrintChars` already knows how to
turn a string into a cached logo. We hand it the string and step back.

**Why sort:** `readdir` returns entries in filesystem order — not alphabetical.
Without sorting, `skull04` might play before `skull01`. A simple
`qsort`/`ffStrbufCompare` on filenames gives deterministic playback. This is
the kind of detail that "works on my machine" until it doesn't.

**Directory scanning utility:** Fastfetch already uses `opendir`/`readdir` in
`src/common/impl/io_unix.c:260-277`. We follow that pattern. The existing
`ffAppendFileBuffer` (used by `logoPrintFileIfExists` at `logo.c:505`) reads a
file into a `FFstrbuf` — we reuse it for each frame file.

---

## Step 5 — Hook into the dynamic loop

**File:** `src/fastfetch.c`, function `run()`

**Two hook points — this is the heart of the change:**

### Hook A — Before the loop (first frame)

Currently (`fastfetch.c:793-795`):
```c
if (!data->resultDoc) {
    ffLogoPrint();
}
```

Change to:
```c
if (!data->resultDoc) {
    if (instance.config.logo.type == FF_LOGO_TYPE_ANIMATE) {
        ffLogoPrintAnimateFrame();  // prints frame 0, builds cache
    } else {
        ffLogoPrint();
    }
}
```

**Why:** The first frame must be printed before the loop, so the info lines
have a logo to interleave with on the very first tick. This mirrors exactly
what `ffLogoPrint()` does for static logos — we just swap in our function.

### Hook B — Inside the loop, after cursor reset

Currently (`fastfetch.c:810-816`):
```c
if (instance.state.dynamicInterval > 0) {
    ffLogoPrintRemaining();
    fputs("\e[J", stdout);
    fflush(stdout);
    ffTimeSleep(instance.state.dynamicInterval);
    fputs("\e[H", stdout);
    instance.state.keysHeight = 0;
}
```

Add **after** `\e[H` and `keysHeight = 0`, **before** the loop continues:
```c
    if (instance.config.logo.type == FF_LOGO_TYPE_ANIMATE) {
        ffLogoPrintAnimateFrame();  // rebuild cache with next frame
    }
```

**Why this exact position — the most important reasoning in this plan:**

Trace the sequence at this point in the loop:
1. `ffLogoPrintRemaining()` — prints leftover logo lines, **clears the cache**
2. `\e[J` — wipes residual characters off-screen
3. sleep
4. `\e[H` — cursor home, ready to overwrite
5. `keysHeight = 0` — info line counter reset
6. **→ OUR HOOK ←** rebuild cache with frame N+1
7. loop continues → `ffPrintJsonConfig` → each info line calls
   `ffLogoPrintLine()` which now *interleaves the new frame's lines*,
   overwriting the old frame on screen

If we placed the hook *before* `ffLogoPrintRemaining()`, the cache we just
built would be immediately cleared by it. If we placed it *after* the info
reprint began, the info would print with an empty cache (cursor-right only)
and the logo would never update. The position is forced by the cache
lifecycle: **clear → sleep → reset → rebuild → reprint**.

**Why a guarded `if` and not always-on:** When the user isn't using animation
(the 99% case), `ffLogoPrintAnimateFrame()` must never run — it does I/O and
mutates state. The `type == FF_LOGO_TYPE_ANIMATE` guard makes the feature
zero-cost when inactive. This is the open-closed principle in practice: the
loop is unchanged for everyone else.

---

## Step 6 — Init and destroy the new state

**File:** `src/common/impl/init.c`

**What:**
- In `initState()` (~line 26): `ffListInit(&state->animateFrames); state->animateIndex = 0; state->animateReady = false;`
- In `destroyState()` (~line 177): destroy each `FFstrbuf` in `animateFrames`, then `ffListDestroy(&state->animateFrames);`

**Why:** Every `FFlist`/`FFstrbuf` in fastfetch has a matched init/destroy
pair — this is the project's memory discipline. The `logoLineCache` itself
follows this exact pattern (`logoLineCacheClear` destroys its strbufs, the
list is destroyed in state teardown). We mirror it. Skipping destroy leaks
memory on exit; fastfetch is careful about this, and we should be too.

---

## Step 7 — Build and test

**Build:** Use the existing debug build you've already configured:
```fish
cd /home/beckl/Projects/Skull_Animation/fastfetch
cmake --build build-debug
```

**Test sequence (incremental):**
1. `./build-debug/fastfetch` — confirm nothing broke (static logo still works)
2. `./build-debug/fastfetch --logo-type animate --logo src/logo/animate-ascii/sloppy/ -w 200`
   — should cycle skull01→02→03→04→01... at 5fps
3. `Ctrl-C` — confirm clean exit (alternate buffer restored, cursor visible)
4. Test with JSON config to verify the config-file path works
5. Test error cases: empty directory, missing directory, non-txt files

**Frame normalization note:** Your four skulls are 22-23 lines and may differ
slightly in width. Since the loop overwrites in place, mismatched dimensions
leave trailing artifacts from the previous frame. Before testing, normalize
all four frames to identical line count and width (pad with spaces). This is
a content fix, not a code fix — the engine is correct either way, but the
*visual* result demands uniform frames.

---

## Summary of Changes by File

| File | Lines touched | Nature |
|------|--------------|--------|
| `src/options/logo.h` | +1 enum value | additive |
| `src/fastfetch.h` | +3 fields in `FFstate` | additive |
| `src/options/logo.c` | +3 entries (2 parse tables, 1 gen case) | additive |
| `src/logo/logo.h` | +1 declaration | additive |
| `src/logo/logo.c` | +1 function (~40 lines) | additive, reuses existing |
| `src/fastfetch.c` | +2 guarded hooks in `run()` | minimal, guarded |
| `src/common/impl/init.c` | +init, +destroy | matches existing pattern |

**Total: ~7 files, all additive, no existing logic rewritten.**

The existing dynamic loop, signal handling, alternate-buffer management,
cursor reset, and line-interleaving all remain untouched. We add a frame
source and two hook points. That's the whole feature.

---

## What This Plan Deliberately Does NOT Do

- **No new flag for animation speed.** Reuses `-w`. One frame per tick.
- **No background thread.** The dynamic loop *is* the background process.
- **No embedded/built-in frames.** Frames load from a directory at runtime.
- **No sub-multiple frame timing.** Frame rate = tick rate. Keeps it simple;
  can be added later by dividing tick count by a frame-skip factor.
- **No modification to `ffLogoPrintLine` or `logoLineCacheBuild`.** These are
  the rendering primitives — we use them, we don't change them.

Each "not doing" is a scope boundary. If a future version needs finer control
(different frame speed, built-in art, threaded loading), the extension points
are clean because we didn't bake assumptions into the core.
