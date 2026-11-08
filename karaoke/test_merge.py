"""Run: python -m pytest test_merge.py  (or python test_merge.py)"""
from karaoke import merge_choices


def ins(i, asr, gp, gn, id=0):
    return {"id": id, "i1": i, "i2": i, "asr": asr, "corrected": "", "gap_prev": gp, "gap_next": gn}


def test_insert_attaches_to_prev_and_moves_punct():
    lines = ["or leave us.", "Mara led Ivy"]
    out = merge_choices(lines, [ins(3, "be.", 0.0, 0.8)], {0: "B"})
    assert out == ["or leave us be.", "Mara led Ivy"]


def test_insert_without_punct_takes_prev_punct():
    out = merge_choices(["Who owns this?", "No moving."], [ins(3, "house", 0.02, 0.6)], {0: "B"})
    assert out == ["Who owns this house?", "No moving."]


def test_insert_attaches_to_next_when_closer():
    out = merge_choices(["for my baby girl.", "Hadn't stopped"], [ins(4, "I", 0.9, 0.05)], {0: "B"})
    assert out == ["for my baby girl.", "I hadn't stopped"]


def test_insert_at_end_and_replace_and_unchosen():
    lines = ["kneeling in", "it grows"]
    diffs = [ins(4, "prayer.", 0.1, None, id=0),
             {"id": 1, "i1": 2, "i2": 3, "asr": "and", "corrected": "it"},
             ins(0, "Oh", 0.0, 0.0, id=2)]
    assert merge_choices(lines, diffs, {0: "B", 1: "B", 2: "A"}) == ["kneeling in", "and grows prayer."]


def test_prepend_keeps_name_capitalized():
    out = merge_choices(["Mara slid"], [ins(0, "and", 0.9, 0.0)], {0: "B"}, names={"mara"})
    assert out == ["and Mara slid"]


if __name__ == "__main__":
    for n, f in list(globals().items()):
        if n.startswith("test_"): f(); print("ok", n)
