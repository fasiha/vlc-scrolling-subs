# karaoke

Audio/video (+ optional YouTube auto-VTT) -> LLM-corrected, word-timed subtitles:
`subs.json` (schema below, consumed by `../app`), `subs.vtt` (YouTube-style inline word timestamps, also read by the app), `subs.ass` (`\kf` karaoke), `subs.srt`.

Requires: `python` with `stable-ts`, `ffmpeg`, and the `claude` CLI (`claude -p`).

## Usage

```sh
PY=python
# all stages, 5-minute clip starting at 10:00 (omit --ss/--t for the whole file)
$PY karaoke.py all -w work/clip --media movie.webm --vtt movie.en.vtt \
   --ss 600 --t 300 --context "radio adaptation of a 19th-century novel" --adjudicate
```

Each stage is also a subcommand sharing the workdir (`extract vtt context transcribe diff align export`);
`all` skips stages whose output exists (use `--force` to redo, or delete the file).

| Stage | Output | What |
|---|---|---|
| extract | audio.wav | ffmpeg, 16 kHz mono, optional `--ss/--t` cut |
| vtt | vtt_words.json | YouTube rolling captions deduped; inline word times kept (rough prior), shifted by `--ss` |
| context | corrected.json | LLM: keyword list + corrected, punctuated, line-broken transcript + `fixes` (with confidence). Guard warns if word similarity < 0.8 |
| transcribe | asr.json | stable-ts transcribe with `initial_prompt` = context + keywords |
| diff | diffs.json, final.json | word diff corrected vs Whisper; `--adjudicate` lets the LLM pick A/B/unsure per diff and applies B picks |
| align | aligned.json | stable-ts `model.align` of final text; words mapped back onto the LLM's lines |
| export | subs.json/.vtt/.ass/.srt | times shifted by `--ss` back to source-media time (`--clip-relative` to opt out; pass the same `--ss` when running export alone); long lines split (<=42 chars, prefer punctuation); monotonic times |

Without `--vtt`, `all` runs transcribe first and the LLM cleans the Whisper transcript.
Options: `--model` (default `medium`), `--name` (output basename).

JSON schema: `{"version":1,"lines":[{"start":1.23,"end":4.56,"text":"I love you","words":[{"start":1.23,"end":1.5,"text":"I"}]}]}`

Note: macOS torch+numba OpenMP clash is worked around via env vars set inside karaoke.py.
