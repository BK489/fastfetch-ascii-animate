# Project Info

## Repo Layout
```
origin    → BK489/fastfetch-ascii-animate   (your fork, push here)
upstream  → fastfetch-cli/fastfetch          (official, fetch only)
branch    → dev (tracks origin/dev)
```

## Git — Part 1: Local work → fork

Everyday changes (frames, config, code) from your machine to GitHub.

1. **Look first** — `git status` / `git diff --stat` / `git diff`. Never commit blind. One feature = one commit.
2. **Stage + commit** — `git add <files>` then `git commit -m "<msg>"`. Match the tone of `git log --oneline -5`. Subject says *what*, body says *why*.
3. **Push** — `git push origin dev`. `origin` is your fork (`BK489/fastfetch-ascii-animate`).

**Auth (token, not password):** GitHub killed password auth in 2021.
- Classic token → needs `repo` scope. Fine-grained → Contents: read+write on the repo.
- Store it: `git remote set-url origin https://<TOKEN>@github.com/BK489/fastfetch-ascii-animate` (plaintext in `.git/config`, fine for personal machine), or `git config --global credential.helper store` then paste once.
- `401 Bad credentials` = bad token. `403 Permission denied` = token valid but no write scope — widen it.

---

## Git — Part 2: Upstream → your fork

Sync official fastfetch into dev. Do this periodically (weekly / before new work).

1. **Commit first** — working tree must be clean. If the merge goes wrong, your work is already safe on `origin/dev`.
2. **Fetch** — `git fetch upstream` (read-only, always safe, updates refs only).
3. **Merge** — `git merge upstream/dev`. Clean → skip to step 7. Conflicts → continue.
4. **See conflicts** — `git diff --diff-filter=U` (or `-- <file>` for one at a time). Markers: `<<<<<<< HEAD` (yours) / `=======` / `>>>>>>> upstream/dev` (theirs).
5. **Resolve** — for each region, read both halves, delete the markers, write the final content. The judgment call:
   - **Independent additions** (different things in the same area) → keep both.
   - **Upstream reworked a feature you touched** → adopt *their* version, preserve only your *independent* additions on top. Don't keep your obsolete copy — it's dead code. (First real merge: upstream replaced `bool recache` with `FFLogoCacheStrategy cache`; we dropped `recache`, kept `animateShuffle`.)
6. **Mark resolved + verify** — `git add <files>`, then `git status` (Unmerged paths must be empty) and `rg '^<<<<<<<|^=======|^>>>>>>>' <files>` (no stray markers).
7. **Commit the merge** — `git commit` (pre-filled message, save as-is).
8. **Build before pushing** — `cmake --build build-debug`. Don't push broken merges.
9. **Push** — `git push origin dev`.
10. **Confirm** — `git log --oneline -5` (merge commit on top), `git status -sb` (clean).

---

## Git principles

- **Merge, don't rebase, after pushing** — keeps history honest, avoids force-push.
- **Commit before merging** — if the merge breaks, your work is safe on `origin/dev`.
- **Read before commit, build before push** — catches 90% of mistakes.
- **Adopt upstream's shared features; keep your independent additions** — "keep both" makes dead code when upstream reworked the same thing.

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
