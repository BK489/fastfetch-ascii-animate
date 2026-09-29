# Next Steps — Animated ASCII in Fastfetch

## Section 1 — Touch Ups (contribution-readiness)

The feature works, but "works" and "mergeable" are different bars. Upstream
fastfetch has conventions around memory discipline, code placement, error
handling, and respecting the existing architecture. This section is about
bringing our implementation up to that bar — not adding features, but making
what we have clean enough that a maintainer would accept it. The guiding
question for every item: *would someone who's never seen our code understand it
immediately, and does it match how the rest of the codebase solves the same
problem?*

Things to consider:

- **Memory lifecycle consistency** — our init/destroy additions are correct but
  bolted on. Verify they match the codebase's idiom for owned lists of strbufs
  (does `logoLineCache` use the same destroy pattern, or is there a helper?).
- **Failure-path correctness** — if `opendir` fails or the directory is empty,
  `animateReady` stays `false`, so every tick retries the scan forever. The
  lazy-init flag needs to distinguish "not scanned" from "scanned and failed."
- **Auto-normalize frame dimensions** — currently the user must pass
  `--logo-width` to steady the text column. The loader should pad frames to
  uniform width/height at load time so the feature works with no flags.
- **Code placement** — `ffLogoPrintAnimateFrame` sits among the print functions,
  which is right, but the comparator and the lazy-scan logic are doing different
  jobs. Consider whether the scan belongs in a separate helper or even a
  different file, matching how fastfetch separates I/O from rendering.
- **Error reporting** — we use `FF_DEBUG` for `opendir` but not for the
  empty-directory case. Match the codebase's error-logging conventions across
  all failure paths.
- **Reuse over reimplementation** — we hand-wrote the directory scan. Fastfetch
  already does `opendir`/`readdir` in `io_unix.c`. Check whether a shared helper
  exists or should be factored out, rather than duplicating the pattern.
- **Guard consistency** — every animate code path is guarded by
  `type == FF_LOGO_TYPE_ANIMATE`. Audit that no animate logic can fire when the
  type isn't set, including the fallback paths.
- **No magic numbers** — the `45` in our test command, the `200` interval, etc.
  should never appear in code. Verify no hardcoded values leaked into the
  implementation.
- **Thread-safety and reentrancy** — fastfetch can run modules in parallel. Our
  state mutations (`animateIndex`, `animateFrames`) happen in the main loop, but
  verify no module callback can reach the animate state concurrently.
- **Formatting and lint** — run `clang-format` and `clang-tidy` per the repo's
  config before any PR. This is non-negotiable for upstream and should be done
  last, after all logic is settled.
- **`dynamicInterval` JSON key** — the animation speed has no JSON home; the
  user must pass `--dynamic-interval` on the CLI every time. Add a key to
  `ffOptionsParseDisplayJsonConfig` (likely under `"display"` since
  `dynamicInterval` redraws the whole screen, not just the logo). Note:
  `dynamicInterval` lives in `instance.state`, not `instance.config` —
  decide whether to parse directly into state or move it to config.
- **Path expansion** — verify `~` and env vars work in `"source"` from JSON
  the same way `--logo` handles them on CLI. Both flow through
  `options->source` so it likely works, but untested.
- **Naming-convention separation** — upstream now has its own "animation"
  concept (`animationFrame`, `FF_LOGO_ANIMATION_FRAME_*`) for selecting
  frames inside a single image file (GIF/APNG), living entirely in
  `src/logo/image/image.c`. Our feature animates a *directory of `.txt`
  files* and lives in `src/logo/logo.c`. The two never share code, but they
  share the word "animate" — which is a readability trap. Audit our
  identifiers (`FF_LOGO_TYPE_ANIMATE`, `animateShuffle`, `animateFrames`,
  `animateIndex`, `animateReady`, `ffLogoPrintAnimateFrame`) and find a
  naming convention that makes the boundary obvious at a glance — e.g. a
  consistent prefix or suffix that distinguishes "text-frame cycling" from
  upstream's "image-frame selection." Start by surveying every symbol we
  added and grouping it, so the rename is one coherent pass, not a
  scatter of individual edits.

---

## Section 2 — Smudge Fix (trailing frame artifacts)

When animating, characters from the previous frame remain on screen after
the next frame renders, creating a "smudged" look. Only affects logo lines
printed **below** the info text. The bug is real, diagnosed, and the fix is
scoped — this is the next code task.

**Root cause:** `ffLogoPrintRemaining` (`src/logo/logo.c:796`) prints cached
logo lines raw — no space padding, no `\033[K` (clear to end of line). When
a new frame's line is shorter than the old frame's line, the old trailing
characters are never overwritten. `ffLogoPrintLine` (line 757) — the
interleaved path — has both protections (space padding at lines 775–777,
`\033[K` at line 789). So only the remaining-lines path smudges. Fewer info
modules = more lines through the unprotected path = more visible smudge.

**The fix:** auto-normalize frame widths in `ffLogoPrintAnimateFrame`,
inside the lazy scan, after frames are loaded (line 450), before
`animateReady = true` (line 452). Two passes:

1. **Find max line byte length** across all lines in all frames
2. **Pad each line** to that max with trailing spaces

After normalization, every line of every frame is the same width.
`ffLogoPrintRemaining`'s raw print overwrites cleanly — same width, same
position, no leftovers.

Things to consider:

- **Stays inside `ffLogoPrintAnimateFrame`** — no changes to existing
  fastfetch code. We normalize the input (frame content), not the renderer.
- **Runs once at load time** — zero cost per tick. Part of the lazy scan,
  not the render loop.
- **Byte length vs display width** — measuring byte length is simpler but
  imprecise for multi-byte UTF-8 chars (box-drawing chars are 3 bytes, 1
  column). May over-pad slightly. Upgrade to `ffUtf8CharLenWidth` if visual
  artifacts remain after testing.
- **Can't pad in-place** — inserting spaces into an `FFstrbuf` shifts
  subsequent characters. Build a new `FFstrbuf` per frame, copy line by
  line with padding, then `ffStrbufSet` to swap.
- **Tools** — `ffStrbufNextIndexC(&buf, start, '\n')` to find next
  newline, `ffStrbufAppendNC(&buf, count, ' ')` to pad,
  `FF_STRBUF_AUTO_DESTROY` for the replacement buffer.
- **Result** — frames don't need to be uniform in the `.txt` files. The
  program normalizes them at load. No `--logo-width` flag needed.
- **Workaround until fixed** — use a config with enough info modules that
  all logo lines interleave through the protected `ffLogoPrintLine` path.
  The full module config in `animate-config.jsonc` does this.

---

## Section 3 — Random Frame Selection

Right now the animation cycles frames in sorted order — skull01, skull02,
skull03, skull04, repeat. That's clean and predictable, but for certain art
styles a shuffled playback feels more alive. Random selection picks a frame
at random each tick instead of advancing sequentially. It's a small change
to the advance logic, but it raises design questions about determinism,
user control, and how random interacts with the existing state.

The change itself is tiny — swap the modulo increment for a random index —
but the interesting decisions are around UX: should random be opt-in via a
flag or JSON key, should it be a separate logo type (`animate-random`) or a
modifier on the existing `animate` type, and should the user be able to
seed it for reproducibility?

Things to consider:

- **Where the change lives** — Phase 4 (ADVANCE) in
  `ffLogoPrintAnimateFrame`. Currently `animateIndex = (animateIndex + 1) %
  length`. Random mode would pick `animateIndex = rand() % length` instead.
  One line, but the mode needs to be selectable.
- **How to expose it** — a new logo type `animate-random` in the enum, or a
  modifier on `animate` (e.g. `"shuffle": true` in JSON, `--logo-shuffle`
  on CLI). A modifier is cleaner — one type, one code path, a bool toggles
  the advance strategy.
- **Random source** — `rand()` is fine for this use case (no security
  needs), but check whether fastfetch already uses a random function
  elsewhere and match it. Seed with `srand(time(NULL))` in `initState` or
  on first animate call.
- **No-repeat constraint** — pure random can pick the same frame twice in
  a row, which looks like a stutter. Consider a shuffle-bag (pick without
  replacement until all frames seen, then reshuffle) for smoother
  randomness. More code, but better visual result.
- **JSON config** — if we go the modifier route, `"shuffle": true` inside
  the `"logo"` object. Needs a new key in `ffOptionsParseLogoJsonConfig`
  and a new field in `FFOptionsLogo`.
- **CLI flag** — `--logo-shuffle` or similar, parsed in
  `ffOptionsParseLogoCommandLine`.
- **State impact** — shuffle-bag needs state (which frames have been
  seen). That's more than a bool in `FFstate` — a list or bitmask of
  seen indices, reset when all frames are exhausted. Think about whether
  this belongs in `FFstate` (runtime, like `animateIndex`) — yes, it does.
- **Backward compatibility** — default stays sequential. Random is opt-in.
  Zero-cost when inactive, same as the rest of the feature.

### Completed — Random Frame Selection (shuffle)

Implemented as a modifier on the existing `animate` type, not a separate
logo type. One bool field, one parse entry per path (CLI + JSON), one
`if` in Phase 4, and a `srand` seed in `initState`. Default is sequential
(off); shuffle is opt-in via `--logo-shuffle true` or `"shuffle": true` in
JSON. Pure `rand()` is used — no shuffle-bag, so the same frame can repeat
twice in a row. That's acceptable for the glitch aesthetic; a shuffle-bag
can be added later if the stutter becomes visually distracting.

Changes made:

- **`src/options/logo.h`** — added `bool animateShuffle;` to
  `FFOptionsLogo` struct, next to `recache`.
- **`src/options/logo.c`** — init `options->animateShuffle = false` in
  `ffOptionsInitLogo`. Parsed `--logo-shuffle` in
  `ffOptionsParseLogoCommandLine` (mirrors `--logo-recache` pattern via
  `ffOptionParseBoolean`). Parsed `"shuffle"` in
  `ffOptionsParseLogoJsonConfig` (mirrors `"recache"` pattern via
  `yyjson_get_bool`).
- **`src/logo/logo.c`** — Phase 4 of `ffLogoPrintAnimateFrame` now checks
  `options->animateShuffle`: if true, `animateIndex = rand() % length`;
  if false, the original sequential modulo increment.
- **`src/common/impl/init.c`** — added `#include <stdlib.h>` and
  `#include <time.h>`, and `srand((unsigned) time(NULL))` in `initState`
  so the random sequence differs across runs.

Usage:

- CLI: `--logo-shuffle true` (or `false` to explicitly disable)
- JSON: `"shuffle": true` inside the `"logo"` object
- Default: `false` (sequential cycling, unchanged behavior)
- The `ffdev` fish function has `--logo-shuffle true` prebaked

Notes:

- Pure `rand()` can repeat the same frame consecutively — looks like a
  stutter. A shuffle-bag (pick without replacement, reshuffle when empty)
  would fix this but needs state in `FFstate` (a seen-indices list). Not
  implemented; test the glitch aesthetic first.
- `srand` is called once in `initState`, not per animate call. Calling it
  per tick would re-seed every frame and defeat the randomness.
- The modifier approach (one bool, one code path) was chosen over a
  separate `FF_LOGO_TYPE_ANIMATE_RANDOM` enum value to avoid duplicating
  the entire lazy-scan + render pipeline. One `if` toggles the strategy.
