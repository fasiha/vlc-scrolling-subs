#!/usr/bin/env python
"""Karaoke subtitle pipeline. See README.md.

Stages (each writes a cached file into WORKDIR; rerun skips if present unless --force):
  extract    media -> audio.wav (16k mono)            [--ss/--t to cut a clip]
  vtt        YouTube auto-VTT -> vtt_words.json       (deduped, inline word times)
  context    LLM: keywords + corrected lines -> corrected.json
  transcribe stable-ts transcribe w/ initial_prompt=keywords -> asr.json
  diff       corrected vs asr -> diffs.json ; optional --adjudicate via LLM -> final.json
  align      stable-ts align final text -> aligned.json (word timings)
  export     aligned -> subs.json, subs.vtt, subs.ass, subs.srt
  all        run everything
"""
import os
# torch and numba (whisper DTW) each bundle libomp; without these, transcribe segfaults on macOS
os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
os.environ.setdefault("NUMBA_THREADING_LAYER", "workqueue")
import argparse, difflib, json, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
MAX_LINE = 42  # chars per subtitle line


def log(*a):
    print("[karaoke]", *a, file=sys.stderr, flush=True)


def jload(p):
    with open(p) as f:
        return json.load(f)


def jdump(obj, p):
    with open(p, "w") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False)


def norm(w):
    return re.sub(r"[^a-z0-9']", "", w.lower().replace("’", "'"))


# ---------------------------------------------------------------- extract
def stage_extract(a, W):
    out = os.path.join(W, "audio.wav")
    cmd = ["ffmpeg", "-loglevel", "error", "-y"]
    if a.ss: cmd += ["-ss", str(a.ss)]
    if a.t: cmd += ["-t", str(a.t)]
    cmd += ["-i", a.media, "-vn", "-ac", "1", "-ar", "16000", out]
    subprocess.run(cmd, check=True)
    return out


# ---------------------------------------------------------------- vtt
TS = r"(\d+):(\d\d):(\d\d)\.(\d{3})"


def ts2s(m):
    h, mi, s, ms = map(int, m)
    return h * 3600 + mi * 60 + s + ms / 1000


def stage_vtt(a, W):
    """YouTube auto-captions: each cue that has <c> tags contains the *new* words with
    inline timestamps; the following line repeats as a static 'rolling' copy. We keep only
    the timestamped lines, which naturally dedupes."""
    txt = open(a.vtt, encoding="utf-8").read()
    words = []
    for block in re.split(r"\n\n+", txt):
        lines = block.strip().split("\n")
        m = re.match(TS + r" --> " + TS, lines[0]) if lines else None
        if not m: continue
        g = m.groups()
        cstart, cend = ts2s(g[:4]), ts2s(g[4:])
        for ln in lines[1:]:
            if "<c>" not in ln and not (len(lines) == 2 and ln.strip() and cend - cstart > 0.05):
                continue
            # first word has cue start; others have <ts><c> word</c>
            parts = re.split(r"<(\d+:\d\d:\d\d\.\d{3})>", ln)
            t = cstart
            for i, p in enumerate(parts):
                if i % 2 == 1:
                    t = ts2s(re.match(TS, p).groups()); continue
                p = re.sub(r"</?c>", "", p).strip()
                for w in p.split():
                    words.append({"start": round(t, 3), "text": w})
    # dedupe pure-text cues that repeat timestamped ones
    out, seen = [], set()
    for w in words:
        k = (w["start"], w["text"])
        if k in seen: continue
        seen.add(k); out.append(w)
    out.sort(key=lambda w: w["start"])
    for i, w in enumerate(out):
        w["end"] = round(min(out[i + 1]["start"] if i + 1 < len(out) else w["start"] + 0.5, w["start"] + 2.0), 3)
    off, dur = a.ss or 0, a.t
    out = [dict(w, start=round(w["start"] - off, 3), end=round(w["end"] - off, 3)) for w in out
           if w["start"] >= off and (dur is None or w["start"] < off + dur)]
    p = os.path.join(W, "vtt_words.json"); jdump(out, p)
    log(f"vtt: {len(out)} words")
    return p


# ---------------------------------------------------------------- LLM
def llm_json(prompt, schema_hint):
    full = prompt + "\n\nRespond with ONLY a JSON object (no prose, no code fences) shaped like:\n" + schema_hint
    for attempt in range(3):
        r = subprocess.run(["claude", "-p"], input=full, capture_output=True, text=True, timeout=900)
        s = r.stdout
        m = re.search(r"\{.*\}", s, re.S)
        if m:
            try: return json.loads(m.group(0))
            except json.JSONDecodeError: pass
        log(f"LLM output unparseable (attempt {attempt+1}): {s[:200]!r} {r.stderr[:200]!r}")
    raise RuntimeError("LLM failed")


def chunk_words(words, n=450):
    """Chunk at sentence ends near n words."""
    chunks, cur = [], []
    for w in words:
        cur.append(w)
        if len(cur) >= n and re.search(r"[.?!]$", w["text"]) or len(cur) >= n * 1.4:
            chunks.append(cur); cur = []
    if cur: chunks.append(cur)
    return chunks


def stage_context(a, W):
    vw = os.path.join(W, "vtt_words.json")
    words = jload(vw) if os.path.exists(vw) else []
    if not words:  # no VTT: use ASR as rough transcript
        words = [w for s in jload(os.path.join(W, "asr.json")) for w in s]
    # 1. keywords from context + start of transcript
    sample = " ".join(w["text"] for w in words[:1500])
    canon = llm_json(
        f"Context: {a.context or '(none)'}\n\n"
        "From your own knowledge of this work (NOT from any transcript), list the canonical spellings of "
        "character names, places and distinctive terms likely spoken in it (max 50).",
        '{"keywords": ["Mara", "Paul", "..."]}')["keywords"]
    res = llm_json(
        f"Context: {a.context or '(none)'}\nCanonical names: {', '.join(canon)}\n\n"
        f"Rough auto-generated (error-prone) transcript excerpt:\n{sample}\n\n"
        "Treat names in this transcript as SUSPECT mishearings. (a) Map each transcript word/phrase that is "
        "likely a mishearing of a canonical name to that name (e.g. a real-world word that sounds like a "
        "character name). Only map when the two SOUND alike (similar syllables/consonants); if unsure, omit. (b) List extra proper nouns from the transcript ONLY if they are genuinely part "
        "of this work and missing from the canonical list.",
        '{"mishearings": {"Mar": "Mara"}, "extra": []}')
    mish = res.get("mishearings", {})
    kw = canon + [k for k in res.get("extra", []) if k not in canon and k not in mish]
    log("keywords:", kw); log("mishearings:", mish)
    lines, flags = [], []
    for ci, ch in enumerate(chunk_words(words)):
        raw = " ".join(w["text"] for w in ch)
        res = llm_json(
            f"Context: {a.context or '(none)'}\nKeywords: {', '.join(kw)}\n"
            f"Known mishearings in this transcript (fix these): {json.dumps(mish)}\n\n"
            f"Below is an auto-generated speech transcript (may have mishearings, bad punctuation).\n"
            "Produce a corrected version for subtitles:\n"
            "- fix likely mishearings (esp. names/keywords), punctuation, capitalization\n"
            f"- split into subtitle lines of <= {MAX_LINE} chars (max ~2 lines' worth per entry is NOT allowed; one line each), "
            "breaking at punctuation/clause boundaries\n"
            "- DO NOT add, remove, summarize or reorder content. Keep every spoken word; drop only tags like [music].\n"
            "- list every non-trivial word change in 'fixes' with confidence high/low.\n\n"
            f"TRANSCRIPT:\n{raw}",
            '{"lines": ["Line one,", "line two."], "fixes": [{"from": "marra", "to": "Mara", "confidence": "high", "why": "character name"}]}')
        new = res["lines"]
        ratio = difflib.SequenceMatcher(None, [norm(w["text"]) for w in ch if not w["text"].startswith("[")],
                                        [norm(x) for l in new for x in l.split()]).ratio()
        log(f"context chunk {ci}: {len(ch)} words -> {len(new)} lines, word similarity {ratio:.2f}")
        if ratio < 0.8:
            log("  WARNING: low similarity, LLM may have invented/dropped content; flagged")
            flags.append({"chunk": ci, "similarity": ratio})
        lines += new
        flags += [dict(f, chunk=ci) for f in res.get("fixes", [])]
    p = os.path.join(W, "corrected.json")
    jdump({"keywords": kw, "mishearings": mish, "lines": lines, "fixes": flags}, p)
    return p


# ---------------------------------------------------------------- whisper
_model = None


def model(a):
    global _model
    if _model is None:
        import stable_whisper
        log(f"loading whisper model {a.model}")
        _model = stable_whisper.load_model(a.model)
    return _model


def stage_transcribe(a, W):
    kwp = os.path.join(W, "corrected.json")
    kw = jload(kwp)["keywords"] if os.path.exists(kwp) else []
    prompt = (a.context + ". " if a.context else "") + ", ".join(kw)
    r = model(a).transcribe(os.path.join(W, "audio.wav"), language="en", initial_prompt=prompt or None,
                            verbose=None)
    segs = [[{"start": w.start, "end": w.end, "text": w.word.strip()} for w in s.words] for s in r.segments]
    p = os.path.join(W, "asr.json"); jdump(segs, p)
    return p


PUNCT = re.compile(r"([.,;:?!…]+[\"'”’)]*)$")


def merge_choices(lines, diffs, choices, names=()):
    """Apply Whisper ('B') choices to the corrected lines at word level, keeping line structure.
    Insertions (i1 == i2) attach to the temporally closer neighbor (gap_prev vs gap_next); when
    appended to the previous word its terminal punctuation moves to the end of the insert
    ("us." + "be." -> "us be.")."""
    ct = [(li, w) for li, l in enumerate(lines) for w in l.split()]
    toks = [[w] for _, w in ct]  # per corrected word: list of output words
    for d in diffs:
        if choices.get(d["id"]) != "B": continue
        ins = d["asr"].split()
        i1, i2 = d["i1"], d["i2"]
        if i1 != i2:  # replace / delete
            for i in range(i1, i2): toks[i] = []
            toks[i1] = ins
            continue
        if not ins: continue
        gp, gn = d.get("gap_prev"), d.get("gap_next")
        to_prev = i1 >= len(ct) or (i1 > 0 and (gn is None or (gp is not None and gp <= gn)))
        if to_prev:
            tgt = toks[i1 - 1]
            if tgt:
                m = PUNCT.search(tgt[-1])
                if m and m.start() > 0:
                    tgt[-1] = tgt[-1][:m.start()]
                    if not PUNCT.search(ins[-1]): ins[-1] += m.group(1)
            tgt += ins
        else:
            nxt = toks[i1]
            if nxt and not PUNCT.search(ins[-1]):  # "I" + "Hadn't" -> "I hadn't" (unless a name / "I")
                w0 = nxt[0]
                if w0[:1].isupper() and w0[1:2].islower() and norm(w0) not in names and not w0.startswith("I'"):
                    nxt[0] = w0[0].lower() + w0[1:]
            nxt[0:0] = ins
    out = [[] for _ in lines]
    for (li, _), ws in zip(ct, toks): out[li] += ws
    return [" ".join(l) for l in out if l]


def stage_diff(a, W):
    c = jload(os.path.join(W, "corrected.json"))
    lines = c["lines"]
    ct = [(li, wi, w) for li, l in enumerate(lines) for wi, w in enumerate(l.split())]
    asr = [w for s in jload(os.path.join(W, "asr.json")) for w in s]
    sm = difflib.SequenceMatcher(None, [norm(x[2]) for x in ct], [norm(w["text"]) for w in asr], autojunk=False)
    diffs = []
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == "equal": continue
        ctx_l = ct[max(i1 - 4, 0):i1]
        diffs.append({"id": len(diffs), "op": op,
                      "corrected": " ".join(x[2] for x in ct[i1:i2]),
                      "asr": " ".join(w["text"] for w in asr[j1:j2]),
                      "before": " ".join(x[2] for x in ctx_l),
                      "after": " ".join(x[2] for x in ct[i2:i2 + 4]),
                      "i1": i1, "i2": i2,
                      # silence before/after the Whisper-only span: tells an insertion which neighbor it hugs
                      "gap_prev": round(asr[j1]["start"] - asr[j1 - 1]["end"], 3) if 0 < j1 < len(asr) and j2 > j1 else None,
                      "gap_next": round(asr[j2]["start"] - asr[j2 - 1]["end"], 3) if j1 < j2 < len(asr) else None,
                      "time": asr[j1]["start"] if j1 < len(asr) else None})
    log(f"diff: {len(diffs)} disagreements; agreement {sm.ratio():.3f}")
    jdump(diffs, os.path.join(W, "diffs.json"))
    final = list(lines)
    if a.adjudicate and diffs:
        # only substantive diffs (skip ones whose words differ only by punctuation/hyphen)
        vtt = jload(os.path.join(W, "vtt_words.json")) if os.path.exists(os.path.join(W, "vtt_words.json")) else []
        cand = [d for d in diffs if norm(d["corrected"].replace("-", "")) != norm(d["asr"].replace("-", ""))]
        def vtt_near(t):
            return " ".join(w["text"] for w in vtt if t is not None and t - 3 <= w["start"] <= t + 3)
        choices = {}
        # cache of earlier verdicts keyed by diff content, so re-running the merge doesn't re-ask the LLM
        cache_p = os.path.join(W, "adjudications.json")
        cache = jload(cache_p) if os.path.exists(cache_p) else {}
        dkey = lambda d: f'{d["before"]}|{d["corrected"]}|{d["asr"]}|{d["after"]}'
        for d in diffs:
            if dkey(d) in cache: choices[d["id"]] = cache[dkey(d)]
        # Deterministic name rule: Whisper and the raw YouTube text are two independent acoustic witnesses.
        # If Whisper's variant contains a canonical name and sounds more like the raw YouTube word than the
        # LLM's replacement does, trust the acoustics (e.g. raw "Ghana": Whisper "Garner" beats LLM "Georgia").
        kwtok = {norm(t) for k in c["keywords"] for t in k.split() if t[:1].isupper() and len(t) > 2}
        sim = lambda x, y: difflib.SequenceMatcher(None, norm(x), norm(y)).ratio()
        for d in diffs:
            bt = [t for t in d["asr"].split() if norm(t) in kwtok]
            if not bt or norm(d["corrected"]) == norm(d["asr"]) or d["time"] is None: continue
            raw = [w["text"] for w in vtt if abs(w["start"] - d["time"]) <= 1.5]
            if not raw: continue
            sb = max(sim(d["asr"], r) for r in raw)
            sa = max(sim(d["corrected"], r) for r in raw) if d["corrected"] else 0
            if sb >= 0.5 and sb > sa + 0.2:
                choices[d["id"]] = "B"; d["rule"] = f"name-acoustic {sb:.2f}>{sa:.2f}"
                log(f"  name rule: {d['corrected']!r} -> {d['asr']!r} (raw {raw})")
        for k in range(0, len(cand), 60):
            batch = [d for d in cand[k:k + 60] if d["id"] not in choices]
            if not batch: continue
            items = "\n".join(f'{d["id"]}: text: ...{d["before"]} [A: "{d["corrected"]}" | B: "{d["asr"]}"] {d["after"]}...\n'
                              f'    raw YouTube words near here: "{vtt_near(d["time"])}"' for d in batch)
            res = llm_json(
                f"Context: {a.context}\nCanonical names in this work: {', '.join(c['keywords'])}\n"
                f"Known YouTube mishearings: {json.dumps(c.get('mishearings', {}))}\n"
                "Two speech recognizers disagree. A = YouTube captions after LLM cleanup (the LLM may have kept "
                "a YouTube mishearing; raw YouTube text shown), B = Whisper (independent; prompted with the names). "
                "If B is a canonical name/word of this work and A is a real-world word that merely sounds similar "
                "(e.g. a country instead of a character's surname), pick B. "
                "For each, pick which is more likely what was actually said (A, B), or 'U' if unsure. "
                "Prefer correct names/spellings; don't pick B just because it's more grammatical if A is plausible.\n\n" + items,
                '{"choices": {"0": "A", "3": "B"}}')
            choices.update({int(k2): v for k2, v in res["choices"].items() if int(k2) not in choices})
        cache.update({dkey(d): choices[d["id"]] for d in diffs if d["id"] in choices}); jdump(cache, cache_p)
        # apply B choices on word level, preserving line structure
        nb = sum(v == "B" for v in choices.values())
        log(f"adjudicate: {nb} switched to Whisper, {sum(v=='U' for v in choices.values())} unsure")
        names = {norm(t) for k in c["keywords"] for t in k.split()}
        final = merge_choices(lines, diffs, choices, names)
        for d in diffs: d["choice"] = choices.get(d["id"])
        jdump(diffs, os.path.join(W, "diffs.json"))
    p = os.path.join(W, "final.json"); jdump({"lines": final}, p)
    return p


def stage_align(a, W):
    fp = os.path.join(W, "final.json")
    lines = jload(fp if os.path.exists(fp) else os.path.join(W, "corrected.json"))["lines"]
    text = " ".join(lines)
    r = model(a).align(os.path.join(W, "audio.wav"), text, language="en", original_split=False)
    aw = [w for s in r.segments for w in s.words]
    # map aligned words back to our lines by sequence-matching normalized tokens
    toks = [(li, w) for li, l in enumerate(lines) for w in l.split()]
    sm = difflib.SequenceMatcher(None, [norm(t[1]) for t in toks], [norm(w.word) for w in aw], autojunk=False)
    times = [None] * len(toks)
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == "equal" or (op == "replace" and i2 - i1 == j2 - j1):
            for k in range(i2 - i1): times[i1 + k] = (aw[j1 + k].start, aw[j1 + k].end)
        elif op == "replace" and j2 > j1:  # spread span time evenly
            s, e = aw[j1].start, aw[j2 - 1].end
            n = i2 - i1
            for k in range(n): times[i1 + k] = (s + (e - s) * k / n, s + (e - s) * (k + 1) / n)
    # fill gaps by interpolation
    for i, t in enumerate(times):
        if t is None:
            prev = next((times[j][1] for j in range(i - 1, -1, -1) if times[j]), 0.0)
            times[i] = (prev, prev + 0.01)
    out = [{"text": lines[li], "words": []} for li in range(len(lines))]
    for (li, w), (s, e) in zip(toks, times):
        out[li]["words"].append({"start": round(s, 3), "end": round(max(e, s + 0.01), 3), "text": w})
    out = [l for l in out if l["words"]]
    for l in out:
        l["start"], l["end"] = l["words"][0]["start"], l["words"][-1]["end"]
    p = os.path.join(W, "aligned.json"); jdump(out, p)
    log(f"align: {len(out)} lines, {len(toks)} words")
    return p


# ---------------------------------------------------------------- export
def split_long(line):
    """Split a line dict whose text exceeds MAX_LINE at punctuation (else near middle)."""
    ws = line["words"]
    if len(line["text"]) <= MAX_LINE or len(ws) < 2: return [line]
    best, bscore = None, 1e9
    total = len(line["text"])
    acc = 0
    for i in range(len(ws) - 1):
        acc += len(ws[i]["text"]) + 1
        score = abs(acc - total / 2) - (25 if re.search(r"[,.;:?!—-]$", ws[i]["text"]) else 0)
        if score < bscore: best, bscore = i + 1, score
    mk = lambda ww: {"start": ww[0]["start"], "end": ww[-1]["end"], "text": " ".join(w["text"] for w in ww), "words": ww}
    return split_long(mk(ws[:best])) + split_long(mk(ws[best:]))


def fmt_srt(t):
    ms = int(round(t * 1000)); h, ms = divmod(ms, 3600000); m, ms = divmod(ms, 60000); s, ms = divmod(ms, 1000)
    return f"{h:02}:{m:02}:{s:02},{ms:03}"


def fmt_ass(t):
    cs = int(round(t * 100)); h, cs = divmod(cs, 360000); m, cs = divmod(cs, 6000); s, cs = divmod(cs, 100)
    return f"{h}:{m:02}:{s:02}.{cs:02}"


def stage_export(a, W):
    lines = [x for l in jload(os.path.join(W, "aligned.json")) for x in split_long(l)]
    # monotonic fixup: a line must not start before previous ends
    for i in range(1, len(lines)):
        if lines[i]["start"] < lines[i - 1]["end"]:
            lines[i - 1]["end"] = max(lines[i - 1]["start"] + 0.01, lines[i]["start"])
    off = 0 if a.clip_relative else (a.ss or 0)  # report times in source-media time
    if off:
        for l in lines:
            l["start"], l["end"] = round(l["start"] + off, 3), round(l["end"] + off, 3)
            l["words"] = [dict(w, start=round(w["start"] + off, 3), end=round(w["end"] + off, 3)) for w in l["words"]]
    base = os.path.join(W, a.name)
    jdump({"version": 1, "lines": [{k: l[k] for k in ("start", "end", "text", "words")} for l in lines]}, base + ".json")
    with open(base + ".srt", "w") as f:
        for i, l in enumerate(lines, 1):
            end = max(l["end"], min(l["start"] + 1.0, lines[i]["start"] if i < len(lines) else 1e9))
            f.write(f"{i}\n{fmt_srt(l['start'])} --> {fmt_srt(end)}\n{l['text']}\n\n")
    with open(base + ".vtt", "w") as f:  # WebVTT with inline per-word timestamps (YouTube-style)
        f.write("WEBVTT\n\n")
        for i, l in enumerate(lines, 1):
            end = max(l["end"], min(l["start"] + 1.0, lines[i]["start"] if i < len(lines) else 1e9))
            ws = l["words"] or [{"start": l["start"], "text": l["text"]}]
            body = ws[0]["text"] + "".join(f"<{fmt_srt(w['start']).replace(',', '.')}> {w['text']}" for w in ws[1:])
            f.write(f"{fmt_srt(l['start']).replace(',', '.')} --> {fmt_srt(end).replace(',', '.')}\n{body}\n\n")
    with open(base + ".ass", "w") as f:
        f.write("[Script Info]\nScriptType: v4.00+\nPlayResX: 1280\nPlayResY: 720\n\n[V4+ Styles]\n"
                "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, "
                "Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
                "Style: Default,Arial,44,&H0000FFFF,&H00FFFFFF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,40,40,40,1\n\n"
                "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n")
        for i, l in enumerate(lines):
            lead = 0.3  # show line slightly early so the sweep is visible from first word
            st = max(l["start"] - lead, lines[i - 1]["end"] if i else 0)
            nxt = lines[i + 1]["start"] if i + 1 < len(lines) else l["end"] + 2
            en = max(l["end"], min(l["end"] + 1.0, nxt - 0.3 if nxt - 0.3 > l["end"] else l["end"]))
            parts, cur = [], st
            for w in l["words"]:
                gap = w["start"] - cur
                if gap > 0.01: parts.append(f"{{\\k{int(round(gap*100))}}}")
                parts.append(f"{{\\kf{max(1, int(round((w['end']-max(w['start'],cur))*100)))}}}{w['text']} ")
                cur = max(cur, w["end"])
            f.write(f"Dialogue: 0,{fmt_ass(st)},{fmt_ass(en)},Default,,0,0,0,,{''.join(parts).rstrip()}\n")
    log(f"export: {len(lines)} lines -> {base}.{{json,vtt,ass,srt}}")
    return base + ".json"


STAGES = ["extract", "vtt", "context", "transcribe", "diff", "align", "export"]
OUTPUTS = {"extract": "audio.wav", "vtt": "vtt_words.json", "context": "corrected.json", "transcribe": "asr.json",
           "diff": "final.json", "align": "aligned.json", "export": None}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stage", choices=STAGES + ["all"])
    ap.add_argument("-w", "--workdir", required=True)
    ap.add_argument("--media", help="audio/video input (extract)")
    ap.add_argument("--vtt", help="YouTube auto-generated .vtt (optional)")
    ap.add_argument("--ss", type=float, help="clip start seconds (applies to extract & vtt)")
    ap.add_argument("--t", type=float, help="clip duration seconds")
    ap.add_argument("--context", default="", help='e.g. "radio adaptation of a 19th-century novel"')
    ap.add_argument("--model", default="medium", help="whisper model (default medium)")
    ap.add_argument("--adjudicate", action="store_true", help="let LLM resolve VTT-vs-Whisper diffs")
    ap.add_argument("--name", default="subs", help="output basename")
    ap.add_argument("--clip-relative", action="store_true", help="export: keep times relative to the --ss cut")
    ap.add_argument("--force", action="store_true", help="recompute even if cached")
    a = ap.parse_args()
    W = a.workdir; os.makedirs(W, exist_ok=True)
    meta_p = os.path.join(W, "meta.json"); meta = jload(meta_p) if os.path.exists(meta_p) else {}
    if a.ss is None and a.t is None and "ss" in meta:
        a.ss, a.t = meta["ss"], meta.get("t")
        log(f"using saved --ss {a.ss} --t {a.t} from meta.json")
    elif a.ss is not None or a.t is not None:
        if meta.get("ss", a.ss) != a.ss: log(f"WARNING: --ss {a.ss} differs from saved {meta['ss']}")
        jdump({"ss": a.ss, "t": a.t}, meta_p)
    todo = STAGES if a.stage == "all" else [a.stage]
    if a.stage == "all" and not a.vtt:  # no prior: transcribe first, then LLM cleans ASR
        todo = ["extract", "transcribe", "context", "diff", "align", "export"]
    for st in todo:
        if st == "vtt" and not a.vtt: continue
        out = OUTPUTS[st]
        if a.stage == "all" and out and os.path.exists(os.path.join(W, out)) and not a.force:
            log(f"{st}: cached"); continue
        t0 = time.time()
        globals()["stage_" + st](a, W)
        log(f"{st}: {time.time()-t0:.1f}s")


if __name__ == "__main__":
    main()
