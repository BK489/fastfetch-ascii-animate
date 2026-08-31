# Project Info

## Repo Layout
```
origin    → BK489/fastfetch-ascii-animate   (your fork, push here)
upstream  → fastfetch-cli/fastfetch          (official, fetch only)
branch    → dev (tracks origin/dev)
```

## Git Flow — syncing with upstream
1. `git fetch upstream` — pull latest from official (read-only, safe)
2. `git merge upstream/dev` — bring upstream commits into your dev branch
3. Resolve conflicts if any (your changes are small + isolated, should be rare)
4. `git push origin dev` — push merged result to your fork

Never rebase after pushing — merge keeps history honest and avoids force-push.
Commit your work to dev before merging so nothing gets clobbered.

## Key Architectural Reminders
- **`FFstate` vs `FFOptionsLogo`:** config = what the user asked for (set once);
  state = what changes during execution (mutated per tick). Frame index is state.
- **The dynamic loop is the background process.** No threads needed. `-w` sets
  `instance.state.dynamicInterval`; the `while(true)` in `run()` does the rest.
- **Cache lifecycle per tick:** clear → sleep → reset cursor → rebuild → reprint.
  The frame-rebuild hook must sit after reset, before reprint.
- **`ffLogoPrintChars` is the rendering primitive.** Reuse it, don't rewrite it.
  It handles UTF-8 width, color replacement, padding, and cache building.
- **All changes additive.** Guard new behavior with `type == FF_LOGO_TYPE_ANIMATE`
  so the feature is zero-cost when inactive.
- **Frames must be uniform dimensions** (same line count + width) or the
  in-place overwrite leaves trailing artifacts from the previous frame.
