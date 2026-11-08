# vlc-opera-subs

Two experiments in better subtitles:

1. **Opera-style scrolling subtitles**: a resizable side column that shows the last few lines (and optionally the next few), synced to the video, like surtitles at the opera.
2. **Word-by-word ("karaoke") subtitles**: words appear as they're spoken, so a line can't give away the punchline before it lands. They're generated automatically from audio, with an LLM layer that fixes speech-to-text errors and adds punctuation and line breaks.

For now: English audio with English subtitles.

## Layout

| Dir | What |
|---|---|
| `app/` | SwiftUI player built on VLCKit. **macOS first**; iPad target later. |
| `karaoke/` | Python pipeline: video/audio + (optional) YouTube auto-VTT → LLM-corrected, word-timed subtitles (ASS karaoke, WebVTT with timestamps inside each line, JSON). |

## Why not a VLC plugin? (research notes, 2026-11)

- **Desktop VLC** has no API for adding custom windows. The playlist and media-info windows are built into the interface module, and the macOS interface is a separate Cocoa codebase. Lua extensions can open basic dialog boxes but have no timer, so continuous redraw is a hack. C modules can do anything, e.g. a video filter that widens each frame and draws the subtitles in the new strip, but they have to be built against VLC's source for each platform. The wiki (wiki.videolan.org/Getting_Started_At_Coding) is from the 2019–21 era. Its only suggestion for custom UI is "build an app against libVLC."
- **Baking the scroll into a generated ASS file** works in every player but was rejected: it's drawn over the video, it isn't a real sidecar panel, and it can't be resized.
- **A companion window next to VLC** (polling VLC's web interface) was rejected: juggling two windows is bad UX and it can't work on iOS.
- **VLC for iOS** is an ordinary open-source app (Swift/Objective-C) built on **VLCKit**, a library wrapper around VLC's playback engine. Nothing has to be plugged into it. You either build your own app on VLCKit or fork vlc-ios.

## The vlc-ios community (for eventual upstreaming)

- GitHub (`videolan/vlc-ios`) is a mirror. Real development happens on **code.videolan.org/videolan/vlc-ios** (GitLab merge requests and issues).
- It has essentially one maintainer: Felix Kühne (`fkuehne`) authored 81 of the last 100 merge requests. Outside merge requests do land, e.g. a recent player-buttons redesign.
- The README says "Pull requests are more than welcome." It asks for good commit messages (Subject / body / `Closes #N`) and has a "Beginner friendly" label.
- Subtitle issues are active (sizing, positioning, letterbox drawing, #2449, #2270), but nobody has asked for a scrolling transcript.
- vlc-ios builds iOS/tvOS only, not macOS. Desktop VLC for Mac is a separate codebase. On Apple Silicon, iPad apps also run on the Mac ("Designed for iPad").

## Plan

1. **A: our own VLCKit app** (`app/`). macOS first, then iPad. Video on one side, a resizable scrolling subtitle column on the other. Play/pause/seek stay in sync; tap a line to seek; the current line can be pinned at the bottom or in the middle; a spoiler toggle blurs upcoming lines. We parse SRT/VTT/ASS ourselves. (Embedded MKV subtitle tracks come later; for now, extract them with `ffmpeg -i in.mkv out.srt`.)
2. Live with it. Record demos, collect feedback.
3. Open a GitLab issue on vlc-ios with the demo. Ask whether they'd want it and in what form (a setting, iPad only, off by default).
4. **B: if they say yes**, port it into vlc-ios as small, reviewable merge requests (subtitle model, then panel UI, then settings). Keep the subtitle model and scroll view in A as separate components so they carry over.

## Karaoke pipeline ideas (`karaoke/`)

- Input: an audio/video file, plus optionally a YouTube auto-generated VTT and/or a context hint ("a discussion of a particular novel") or a keyword list.
- **LLM before transcription**: build a vocabulary list (names, jargon: "Bowser", not "browser") from the hint, the video title, or a first-pass transcript. Feed it to Whisper/stable-ts as `initial_prompt`/hotwords.
- **Transcription / alignment**: stable-ts (`python`), either transcribing directly or aligning a corrected transcript to the audio to get per-word timestamps.
- **LLM review**: find likely mistranscriptions (low word confidence + implausible in context), propose fixes, and re-align the fixed text. Add punctuation, casing, and sensible line breaks.
- Output: ASS with `\k` karaoke tags, WebVTT with timestamps inside each line, and word-level JSON (which the app can render natively).

## Findings (2026-11-07)

- **Word-by-word reveal is the breakthrough.** Testing on a 2¼-hour radio drama, the app's reveal of each word as it's spoken mattered far more than transcript accuracy.
- **YouTube auto-generated VTTs are good enough as-is.** They already carry per-word timestamps (`<00:10:03.120><c> word</c>`), which the app parses directly, so no pipeline is needed for YouTube downloads. They occasionally skip a word or mishear a name (Ghana/Garner), but that's a minor annoyance next to the reveal.
- **The karaoke pipeline's main use is word-timing ordinary SRT/VTT files** (human-made subs with no per-word times) via stable-ts alignment. The LLM cleanup (names, punctuation, Whisper adjudication) is a nice-to-have, deprioritized.
