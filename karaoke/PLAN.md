# Karaoke pipeline plan

## Checklist
- [x] Clip test data (work/clip.wav = 600-900s of test-drama, 16k mono)
- [x] Write karaoke.py (stages: extract, vtt, context, transcribe, diff[+adjudicate], align, export)
- [x] Run on 5-min clip
- [x] Evaluate: LLM corrections, timing spot-check, runtime
- [x] README, .gitignore, git init
- [ ] Full 2.25h run (not done; est. ~1.5h CPU with medium)
- [ ] Improvements: filter keyword noise, re-align zero-duration words, merge ASR-only insertions better

## Decisions
- Single script, subcommand per stage, cached JSON intermediates in a workdir.
- VTT dedupe: keep only lines with inline `<c>` timestamps (the new words); rolling copies dropped.
- LLM via `claude -p`, chunks of ~450 words, JSON reply; similarity guard (<0.8 word-level ratio flags invented/dropped content).
- Whisper model default `medium` (already cached locally).
- Align maps stable-ts words back to LLM lines via difflib so line breaks survive.

## Blockers / open questions
- RESOLVED: stable-ts transcribe segfaulted (torch + numba both load libomp). Fix: env KMP_DUPLICATE_LIB_OK=TRUE + NUMBA_THREADING_LAYER=workqueue, set at top of karaoke.py.

## Findings
- VTT parse: 665 words in clip; LLM context pass 21s, word-similarity guard 0.93/0.98 (no invention).
- Keyword list includes some noise (Mar, Iv, Verna — mishearings echoed back from the VTT).
- Runtime (5 min clip, CPU, medium): context LLM 21s, transcribe 133s, adjudicate 3.5s, align 57s; ~3.5 min total (~0.7x realtime).
- Good LLM fixes: Iv->Ivy, Mar/Mafa->Mara, 'hat in my house'->'haint' (low conf), 'cowh hard hide'->cowhide, 'Them boys'.
- Bad: keyword list echoed 'Ghana' (mishearing of Garner) and LLM kept it; adjudicator also picked 'Ghana' over Whisper's 'Garner'.
- 25 VTT-vs-Whisper diffs; adjudicator took Whisper for 9 (e.g. 'sir.'->'Mara.', added missing 'I was', 'prayer.').
- Timing: 614 words matched against YouTube VTT word starts: median offset -0.02s, p90 |offset| 0.16s. 37/641 words have ~0 duration (align gaps/fill).
- FIXED: export now adds `--ss` back so json/ass/srt are in source-media time (`--clip-relative` opts out). Clip re-exported: first line at 600.04s. Note: standalone `export` needs the same `--ss`.

## Round 2 fixes (coordinator: Ghana/Garner bug)
- Keywords now come in two steps: (1) canonical names from LLM world knowledge only (no transcript); (2) transcript names treated as suspect and mapped to canonical names ("mishearings"), and only real names from the work are added. VTT junk like Mar/Iv/Verna is no longer in the list.
- The new mapper still mapped Ghana->Georgia, so a prompt alone was not enough. Added a deterministic **name-acoustic rule** to the adjudicator: if Whisper's variant contains a canonical name and sounds more like the raw YouTube word (string similarity >=0.5 and +0.2 better than the LLM's), pick Whisper. Raw "Ghana": Garner 0.55 vs Georgia 0.31, so Garner wins.
- The adjudicator prompt now also gets canonical names, the mishearing map, and the raw YouTube words within ±3s of each diff.
- `--ss/--t` are saved to `<workdir>/meta.json`; later stages (including standalone `export`) reuse them, with a warning if they conflict.
- Before -> after (clip): "Ghana, it costs too much." -> "Garner, it costs too much." (~10:34); "It's They're all the same." -> "They're all the same."; "When it closed, and made a tree." -> "When it closed, it made a tree."; "Chokecherry tree: trunk, branches," fixed spelling.
- Regressions/new issues: "Talking about a tree, Mara." -> "...sir." (the LLM now keeps "sir"; ambiguous in the audio). An ASR-only "be." got attached to the start of the next line ("be. Mara led Ivy..."), because insertions attach to the following word. Diff agreement went from 0.866 to 0.934.

## Round 3: insertion merge fix
- Bug: words that only Whisper heard and the adjudicator accepted were always attached to the *following* word, e.g. "or leave us." / "be. Mara led Ivy...". An insertion at the very end of the text was also silently dropped.
- Fix: `merge_choices()` (unit-tested in `test_merge.py`). An insertion attaches to whichever neighbor has the smaller silence gap (diff now stores `gap_prev`/`gap_next` from Whisper timings). When it is appended to the previous word, that word's terminal punctuation moves to the end of the insertion ("us." + "be." -> "us be."). When it is prepended, the following word is lower-cased unless it is a name, "I", or "I'm"-style.
- Adjudicator verdicts are cached in `adjudications.json`, so re-merging doesn't re-ask the LLM.
- All 6 accepted insertions on the clip checked: "Who owns this house?", "or leave us be." / "Mara led Ivy into the keeping room", "It grows there still.", "I hadn't stopped nursing her", "...kneeling in prayer." (previously dropped), "this child a half..." (same line, unaffected).
- Footgun: `diff` without `--adjudicate` writes final.json with no Whisper merges.
