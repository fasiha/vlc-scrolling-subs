# app/ work plan

**Setup:** `./fetch-vlckit.sh` once (downloads VLCKit into gitignored `Vendor/`), then `./build-app.sh`.

Run: `cd app && ./build-app.sh && build/OperaSubs.app/Contents/MacOS/OperaSubs --subs SUBS VIDEO`
(e.g. `--subs video.en.vtt video.webm`, or
`--subs ../karaoke/work/clip/subs.json` with the same video, interesting around 10:30).

## Architecture (round 4 rewrite)

| File | Role |
|---|---|
| `SubtitleKit/` | Parsers (SRT, WebVTT incl. YouTube auto-VTT, word JSON) + `lastStarted(at:)`. Unit-tested. |
| `PlayerModel.swift` | VLC, playback-time model, pushes time to the column and the transport. |
| `Transcript.swift` | `TranscriptController`: the subtitle column (AppKit), styling, scroll state machine, click-to-seek. |
| `Views.swift` | SwiftUI shell: video pane, transport bar, column + Follow button. |
| `OperaSubsApp.swift` | App delegate (CLI args), single window, menus/shortcuts. |

### Playback time (single source of truth: `PlayerModel.currentTime`)
- Not observed by SwiftUI. While playing, a 30 Hz timer (only running while playing) extrapolates
  from the last VLC report and calls `transcript.update(time:)` plus `TransportClock.update`
  (publishes at 2 Hz, for the time label and slider).
- `seek(t)` sets `pendingSeek = t`, pushes `t` immediately, tells VLC. While pending, VLC reports
  are ignored unless within 1.5 s of the target (then it clears). VLC 3 sends no time while paused,
  so a paused seek stays pending until playback; it clears after 3 s of playing without confirmation.
- `skip(d)` is relative to `currentTime`, so repeated arrows while paused add up.

### Column
- One TextKit 1 `NSTextView` in an `NSScrollView` (wrapped by `NSViewRepresentable`). The whole
  transcript is one attributed string, one paragraph per cue. Character ranges for each line and
  word are computed once at load time. Not editable, not selectable.
- Everything is always laid out. Styling uses layout-manager *temporary attributes* (foreground color),
  so it never triggers layout. On each tick only changed ranges are repainted: lines between the old
  and new current line (as one range per state), or just the current line when the word changes.
  Current-line tint = rounded rect drawn in `drawBackground`.
- Shades: past = dimmed; current line = spoken words bright, unspoken words faint; future lines =
  the same faint "unspoken" shade. Word-by-word reveal is always on when word timings exist; lines
  without them are revealed as a whole.
- No column toggles (Center/Upcoming/Blur/Words were removed per user). Only the Follow button.
- Click: hit test → character → line → word → seek to the word start (line start when there are no
  word timings). Switches to `free` before seeking, so the view never moves on click.

- Transcripts may cover only part of the video (e.g. clip `subs.json`, 10:00–15:00). Before the
  first cue nothing is current and the first line sits faintly at the bottom; after the last cue
  ends every line is past (no highlight) and the last line stays at the bottom.
- Hover: the hovered word's start time (line start without word timings) is drawn small in the
  empty gap above that row. Drawn only, so layout never changes. Cleared on scroll and on mouse exit.

### Scroll state machine (`TranscriptController.mode`)
- `follow`: the current line is anchored at the **bottom** of the column. Future lines are below,
  off-screen, and can be read by scrolling down. Line change → 0.35 s ease scroll (jumps larger
  than 2 screens are instant). Top/bottom inset = column height so the first line can sit at the bottom.
- `free`: entered on user scroll (wheel/trackpad, scroller drag) or a click in the column.
  Never scrolls, except: when the playing line moves from a visible line to one that is not fully
  visible → follow resumes.
- Back to `follow`: Follow button, keyboard/slider seek, loading subtitles.

### Window
- Single window: File > New removed; external open events are routed to the existing window
  (`handlesExternalEvents`). Command-line file args are handled once in the app delegate.

## Verified (2026-11-07, driving the real app, screenshots of its window only)
With clip `subs.json` around 10:30 on the test-drama video:
- Click a word while paused → time 10:37, highlight on that word ("You hear" bright, rest faint),
  view did not move, Follow shown.
- Scroll up while playing: view held for 8+ s with the playing line off-screen.
- Follow button → scrolls back, current line at the bottom.
- Paused + Right ×3 → +15 s, held for 4 s, column followed.
- Click a line near the bottom while paused, then play: once the playing line ran off the bottom,
  follow resumed by itself.
- `swift test`: 5/5 pass.

CPU (`top -pid`, window frontmost, full test-drama VTT, playing):
- old SwiftUI column: ~35%
- new column: ~21%
- same video with **no subtitles**: ~20%. So the column now costs ~1%; the rest is VLC decode/render.

Round 5 (2026-11-07):
- Crash fixed: loading new subtitles (⇧⌘O on clip `subs.json` while the test-drama VTT was loaded)
  hit an out-of-range index. `load` relaid out the text while still holding the *old* current-line
  index, which was past the end of the shorter new transcript. Now the position is reset before
  relayout. Not a SubtitleKit bug, so no new unit test.
- Checked on screen by opening `subs.json` (Finder-style open event, same `openSubtitles` path)
  over the VTT: no crash; at 5:00 the first line sits faintly at the bottom; at 12:00 the current
  line is highlighted; at 16:00 everything is past. Hover label showed "14:43" above a row.

## Needs user
- Play/pause and window activation should feel instant now. Confirm.
- Check that the shades (past dim, future/unspoken faint) read well; tune if not.
- Font size ⌘+/⌘−, ⌘L hide column, Shift+arrows, slider drag: built but not re-checked on screen.
- Divider drag / live resize with the full VTT (relayout of the whole transcript on width change).
- Opening a second file via Finder/`open` while running should reuse the window. Not tested with Finder.
- ⇧⌘O itself (the file panel) wasn't driven by me, only the open-event path that calls the same code.
- Hover a word vs the line start: check the label changes per word.
- No text selection or copy in the column (clicks seek). Ask if copy is wanted.

## Decisions
- VLCKit 3.7.3 vendored xcframework as an SPM `binaryTarget`; pure SPM, `build-app.sh` bundles the .app.
- YouTube auto-VTT: keep only the newly introduced line of each cue, word starts from inline
  timestamps; drop 10 ms snapshot cues; collapse untimed repeats.
- TextKit 1 over TextKit 2: temporary attributes and glyph hit-testing are simple and reliable.
- Fullscreen = window fullscreen (green button / double-click video), so the column stays; ⌘L hides it.
- VLC's own subtitle track is disabled 0.5 s after open (hack).

## Agent status
- 20:29: agent testing finished; no agent-launched OperaSubs running.
