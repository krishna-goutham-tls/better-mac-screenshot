# mac-screenshot-tool

A free macOS menu bar app for screenshots. Working name.

- One shortcut captures a region and copies it to the clipboard, every time.
- Sensitive text (emails, phone numbers, API keys) blurs on its own, on the Mac, before the image is copied.
- Post mode adds a background, padding, rounded corners and a shadow, ready for X.
- Agent mode keeps the shot tight and lets you drop numbered notes on it, then paste the image and the notes into Claude Code, Codex or any coding agent in one go.

No network calls. Nothing leaves your Mac.

## Post mode

Every shot gets a soft background, padding, rounded corners and a shadow, so it is ready to paste into an X post. The canvas stays between 4:5 and 16:9, the shapes X shows uncropped in the feed. The pixels of the shot itself are copied as they are, never resampled. There are three backgrounds: sand, night and dusk (the default).

## Auto-blur

Before a shot reaches the clipboard or the screenshot folder, the app reads the text in it and blurs what looks sensitive:

- email addresses and phone numbers
- API keys and tokens: OpenAI, Anthropic, GitHub, AWS, Google, Slack, Stripe, JWTs, `Bearer` and `Authorization` values
- values of settings named like a key, secret, token or password (`API_KEY=...`, `client_secret: "..."`)
- card numbers that pass the checksum, and the first line of a private key
- long random strings that look like keys

Paths, URLs, git hashes, dates, version numbers and IP addresses stay readable. Apple's Vision framework reads the text and Core Image does the blur, both on the Mac. No image or text is sent anywhere. A key that wraps onto the next row is blurred on both rows. Reading and blurring takes about 300 ms on a 1600x1000 shot and under a second on a 5K one.

If the blur fails, the app covers the sensitive text with solid grey boxes. If that fails too, it copies and saves nothing, beeps, and writes a line to `~/Library/Logs/ScreenshotTool.log`.

Turn it off with "Blur sensitive text" in the menu bar menu.

## Editing a shot

Click the thumbnail in the bottom-right corner to open the last shot.

- Click a blur to remove it. Click the same spot again to put it back.
- Click one of the three dots under the shot to change the background. Later shots use the one you picked.
- Cmd+Z undoes the last change.
- Every change copies the new image and overwrites the same file in the screenshot folder.
- Esc or Cmd+W closes. Return copies again and closes.

Status: in development. See `TRACKER.md`.

MIT licence.
