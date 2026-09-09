# Progress Update — Animated ASCII in Fastfetch

## Status: Steps 1–7 complete — feature working

---

## What is done

### Step 1 — Enum value (`src/options/logo.h`)
- Added `FF_LOGO_TYPE_ANIMATE` to `FFLogoType` enum (line 13, after `FF_LOGO_TYPE_FILE`).
- Numeric value: `4` (AUTO=0, BUILTIN=1, SMALL=2, FILE=3, ANIMATE=4).

### Step 2 — State fields (`src/fastfetch.h`)
- Added three fields to `FFstate` struct (lines 38–41):
  - `FFlist animateFrames` — list of `FFstrbuf`, one per loaded frame
  - `uint32_t animateIndex` — current frame index, wraps via modulo
  - `bool animateReady` — lazy-init flag, false until first scan
- **Not yet init'd/destroyed** — Step 6 (init.c) is pending.

### Step 3 — Parsing (`src/options/logo.c`)
- Added `{ "animate", FF_LOGO_TYPE_ANIMATE }` to:
  - CLI lookup table (line 59)
  - JSON config lookup table (line 254)
  - JSON config generator switch (line 453, case writes `"type": "animate"`)
- Both `--logo-type animate` (CLI) and `"type": "animate"` (JSON config) now work.

### Step 4 — Frame loader (`src/logo/logo.c`)
- **Comparator** `compareFileNames` (lines 293–295): wraps `ffStrbufComp` for sorting.
- **Function** `ffLogoPrintAnimateFrame` (lines 411–469): four phases:
  1. **Lazy scan** (runs once): opens directory, collects `.txt` filenames, sorts them, reads each file's contents into `state->animateFrames`, sets `animateReady = true`.
  2. **Select**: `FF_LIST_GET` picks the frame at `animateIndex`.
  3. **Render**: `logoApplyColors(logoGetBuiltinDetected(FF_LOGO_SIZE_NORMAL), true)` fills the color palette from the detected OS logo (respecting `--logo-color-1`–`--logo-color-9` overrides), then `ffLogoPrintChars(frame->chars, true)` — reuses existing renderer.
  4. **Advance**: `animateIndex = (animateIndex + 1) % animateFrames.length` — wraps around.
- **Moved** below `logoGetBuiltinDetected` (line 470) so both `logoApplyColors` and `logoGetBuiltinDetected` are defined before use — no forward declarations needed.
- **Declared** in `src/logo/logo.h` (line 31).
- **Includes added** to `logo.c`: `common/debug.h` (line 5), `<dirent.h>` (line 14).

### Hook A — Before the loop (`src/fastfetch.c:794-800`)
- Added guard: if `type == FF_LOGO_TYPE_ANIMATE`, call `ffLogoPrintAnimateFrame()` instead of `ffLogoPrint()`.
- Prints frame 0 before the dynamic loop starts.

---

## What is NOT done

_(All steps complete — see "Completion" below.)_

---

## Completion

All seven steps of the coding plan are implemented and verified end-to-end. The
`animate` logo type cycles a directory of `.txt` frames on each dynamic tick,
interleaved with live system info, reusing the existing `ffLogoPrintChars`
renderer and the proven dynamic loop — no rewrite of either.

**What was finished in the final pass:**

- **Hook B** (`src/fastfetch.c:823–825`): the rebuild hook inside the dynamic
  loop, placed after `keysHeight = 0` and before the loop body reprints. This
  was the missing piece that caused frame 0 to render once but never cycle —
  the cache was cleared each tick by `ffLogoPrintRemaining` and never rebuilt.
  The hook restores the cache with frame N+1 each tick, completing the
  lifecycle: clear → sleep → reset → **rebuild** → reprint.
- **Step 6 — init/destroy** (`src/common/impl/init.c`): `initState` now
  initializes `animateFrames` (via `ffListInit`), `animateIndex`, and
  `animateReady`. `destroyState` frees each `FFstrbuf` in `animateFrames`
  (inside-out: leaves first via `FF_LIST_FOR_EACH`, then the container via
  `ffListDestroy`). This removes the undefined-behavior risk of reading
  uninitialized state on the first call.
- **Verified working**: `--dynamic-interval 200` (milliseconds, raw — *not*
  `-w`, which treats its value as seconds and multiplies by 1000) produces a
  ~5fps animation. `--logo-width 45` steadies the info-text column against
  frames of varying width (39–45 chars) by fixing `logoWidth` regardless of
  per-frame content.
- **Color support** (`src/logo/logo.c:465`): added
  `logoApplyColors(logoGetBuiltinDetected(FF_LOGO_SIZE_NORMAL), true)` in Phase 3
  before `ffLogoPrintChars`. This fills `options->colors[]` from the detected
  OS logo's palette (green for CachyOS), respecting `--logo-color-1`–
  `--logo-color-9` overrides. Mirrors exactly how `--logo <file>` gets its
  default color via `logoPrintData` (line 518). The `carryColor` mechanism in
  `logoLineCacheBuild` then emits the color at the start of every line, so the
  whole skull is colored without any `$N` tokens in the frame files.
- **Function relocation**: `ffLogoPrintAnimateFrame` moved from line 297 to
  line 411 (after `logoGetBuiltinDetected` at line 427). Both `logoApplyColors`
  and `logoGetBuiltinDetected` are now defined before use — no forward
  declarations needed. Verified: default green renders, `--logo-color-1 31`
  overrides to red.

**Design principles held throughout:**
- *Extension over modification* — two guarded hooks in the existing loop, no
  rewrite of the loop, signal handling, or alternate-buffer logic.
- *Zero-cost when inactive* — every new code path is guarded by
  `type == FF_LOGO_TYPE_ANIMATE`, so the 99% non-animated case is untouched.
- *Reuse over rewrite* — `ffLogoPrintChars` does the rendering; we only feed
  it new frame strings.

**Remaining (non-code):** frame dimension normalization is a content task
(pad frames to uniform line count + width) to eliminate trailing artifacts
from in-place overwrites. The engine is correct either way.

---

## Debug setup
- `launch.json` has "Debug Fastfetch Custom" config with args:
  `["--logo-type", "animate", "--logo", "src/logo/animate-ascii/sloppy/", "-w", "200"]`
- Breakpoint in `ffLogoPrintAnimateFrame` works — verified frames load into `state->animateFrames`.
- Inspect frames in Debug Console: `p ((FFstrbuf*)state->animateFrames.data)[0].chars`

## Test command
```fish
cmake --build build-debug
./build-debug/fastfetch --logo-type animate --logo src/logo/animate-ascii/sloppy/ -w 200
```
