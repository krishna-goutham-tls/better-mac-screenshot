# Tracker

One milestone a day. The agent builds and tests on the Mac; Krishna does the hands-on test and records the clip for the day's X post. How the app works is in the project context (`../brainstorming/build-plan.md` in tls-context).

## Now: build

- [ ] Day 1. Menu bar app, Cmd+Shift+2, frozen-frame region capture (ScreenCaptureKit), PNG to the clipboard and `~/Pictures/<app>`, 4-second corner preview. Pass: 10 shots in 10 seconds, each pastes into Slack in turn, 10 files in the folder
- [ ] Day 2. Post mode: padding, background, rounded corners, shadow; fits the X feed. Pass: pasted into an X draft, it looks finished with no editing
- [ ] Day 3. Auto-blur in both modes before the clipboard; click a blur in the editor to remove it. Pass: fake API key, email and phone all blurred; under 300 ms in the selftest
- [ ] Day 4. Agent mode: Cmd+Shift+1, tight crop, click for a numbered marker and note, drag for a box, Cmd+Z. Pass: a UI bug marked up in under 15 seconds
- [ ] Day 5. Agent handoff: PNG plus path-and-notes text on the clipboard. Pass: one Cmd+V in Claude Code (terminal and desktop) and Codex, each sees the image and both notes
- [ ] Day 6. Ship: menu settings, first-run permission screen, release zip, README install steps. Pass: fresh install, day 1-5 tests pass again
- [ ] Day 7. Page at thelaunch.space/tools/<app> and a launch video
