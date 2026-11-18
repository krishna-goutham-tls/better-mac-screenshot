# Tracker

## Updates

- [x] In-app updater (2026-11-18, not released): daily GitHub check, update window, one-click install with a Developer ID check, "Check for updates…" in the menu. Tested against the real GitHub release
- [ ] First release with the updater (needs Krishna's go). Copies from before it never update themselves

One milestone a day. The agent builds and tests on the Mac; Krishna does the hands-on test and records the clip for the day's X post. How the app works is in the project context (`../brainstorming/build-plan.md` in tls-context).

## Now: build

- [x] Day 1. Menu bar app, Cmd+Shift+2, frozen-frame region capture (ScreenCaptureKit), PNG to the clipboard and the macOS screenshot folder (Desktop by default), 4-second corner preview. Pass: 10 shots in 10 seconds, each pastes in turn into any chat or doc, 10 files in the folder. Done 2026-11-04: selftest 10 real captures in 0.74 s, Krishna pasted a shot with Cmd+V. Also shipped: open at login, app icon, shutter sound with a menu toggle
- [ ] Day 2. Post mode: padding, background, rounded corners, shadow; fits the X feed. Pass: pasted into an X draft, it looks finished with no editing. Built 2026-11-10: every shot gets the Post look (sand, night, dusk), picked in the editor. Selftest: 4 shapes x 3 backgrounds keep the ratio in 4:5..16:9 with shot pixels unchanged, render 1600x1000 in 24 ms. Still to do: Krishna's hands-on test (paste into an X draft)
- [ ] Day 3. Auto-blur in both modes before the clipboard; click a blur in the editor to remove it. Pass: fake API key, email and phone all blurred; under 300 ms in the selftest. Built 2026-11-10: blur before the clipboard and the file, menu toggle, warm-up at launch, editor opens from the corner thumbnail (click a blur to remove or restore it, Cmd+Z, background swatches, every change re-copies and overwrites the same file). Selftest: key, email and phone covered 99% each, OCR reads none of them after the blur, detect + blur 128 ms warm, full pipeline (detect, blur, Post, PNG) 211 ms warm on 1600x1000, 10 real captures in 2.3 s. 2026-11-11: blur rebuilt for large and wrapped text, tiles sized to the text so Vision reads small text on 5K shots, and a drawn benchmark (`--redact-bench`, 351 cases of terminal, IDE window, editor and chat). Benchmark: 26 of 226 cases fail (from 131; 28 before the 2026-11-11 edge fix), 1 secret missed and 6 partly readable; text under 7 px x-height is reported apart, median 309 ms at 1600x1000 and 734 ms at 5107x2866. Known gaps: editor line numbers and some proportional chat text get over-blurred, a window shot at 5107x2866 takes about 2 s. Agent mode is not built yet, so "both modes" waits for Day 4. Still to do: Krishna's hands-on test in the editor
- [ ] Drawn blur (2026-11-11): drag on the shot in the editor to blur what auto-blur missed; a flat drag snaps to the text line, a tall drag is a box, Cmd+Z takes it off, a click removes it. Built; `--demo <dir> --draw-test` checks the snap. Still to do: Krishna's hands-on test
- [ ] Day 4. Agent mode: Cmd+Shift+1, tight crop, click for a numbered marker and note, drag for a box, Cmd+Z. Pass: a UI bug marked up in under 15 seconds
- [ ] Day 5. Agent handoff: PNG plus path-and-notes text on the clipboard. Pass: one Cmd+V in Claude Code (terminal and desktop) and Codex, each sees the image and both notes
- [ ] Day 6. Ship: menu settings, first-run permission screen, release zip, README install steps. Pass: fresh install, day 1-5 tests pass again
- [ ] Day 7. Page at thelaunch.space/tools/<app> and a launch video
