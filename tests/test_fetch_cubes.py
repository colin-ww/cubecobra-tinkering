import io
import json
import urllib.error
from email.message import Message

import pandas as pd
import pytest

import fetch_cubes as fc


def card(name, oracle_id="auto", **extra):
    if oracle_id == "auto":
        oracle_id = f"oid-{name.lower()}"
    return {
        "name": name,
        "cardID": f"sid-{name.lower()}",
        "status": "Owned",
        "finish": "Non-foil",
        "tags": ["burn"],
        "notes": "",
        "addedTmsp": "2025-01-02T03:04:05.000Z",
        "details": {"name": name, "oracle_id": oracle_id, "set": "lea", "collector_number": "1",
                    "type": "Instant", "cmc": 1, "colors": ["R"]},
        **extra,
    }


CUBE = {
    "id": "c1",
    "shortId": "test",
    "name": "Test cube",
    "owner": {"username": "me"},
    "cardCount": 2,
    "dateLastUpdated": 1_700_000_000_000,
    "cards": {
        "mainboard": [card("Bolt"), card("Counterspell")],
        "maybeboard": [card("Bolt")],
        "basics": [card("Forest")],
    },
}


def http_error(code, retry_after=None):
    headers = Message()
    if retry_after is not None:
        headers["Retry-After"] = retry_after
    return urllib.error.HTTPError("http://x", code, "err", headers, None)


def test_card_rows_flattens_main_and_maybe_but_not_basics():
    rows = fc.card_rows(CUBE)
    assert [(r["board"], r["name"]) for r in rows] == [
        ("mainboard", "Bolt"), ("mainboard", "Counterspell"), ("maybeboard", "Bolt"),
    ]
    # same card on two boards -> same key, which is what the dupes report groups on
    assert rows[0]["card_key"] == rows[2]["card_key"] == "oid-bolt"


@pytest.mark.parametrize("oracle_id", ["custom-card", None])
def test_custom_cards_are_keyed_by_name(oracle_id):
    a, b = (fc.card_row("c1", "mainboard", card(n, oracle_id=oracle_id)) for n in ("Homebrew A", "Homebrew B"))
    assert (a["card_key"], b["card_key"]) == ("homebrew a", "homebrew b")


def test_load_config(tmp_path):
    good = tmp_path / "good.toml"
    good.write_text('[[cube]]\nid = "abc"\nuniques = true\n')
    assert fc.load_config(good) == [{"id": "abc", "uniques": True}]

    empty = tmp_path / "empty.toml"
    empty.write_text("# nothing here\n")
    with pytest.raises(SystemExit, match="no \\[\\[cube\\]\\] entries"):
        fc.load_config(empty)


def test_fetch_cube_retries_rate_limit_then_succeeds(monkeypatch):
    calls = []

    def fake_urlopen(req, timeout):
        calls.append(req.full_url)
        if len(calls) < 3:
            raise http_error(429, retry_after="0")
        return io.BytesIO(json.dumps(CUBE).encode())

    monkeypatch.setattr(fc.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(fc.time, "sleep", lambda s: None)
    assert fc.fetch_cube("c1")["name"] == "Test cube"
    assert len(calls) == 3


def test_fetch_cube_404_says_what_went_wrong(monkeypatch):
    def fake_urlopen(req, timeout):
        raise http_error(404)

    monkeypatch.setattr(fc.urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(ValueError, match="not found"):
        fc.fetch_cube("nope")


def test_main_writes_both_tables(tmp_path, monkeypatch, capsys):
    cfg = tmp_path / "cubes.toml"
    cfg.write_text('[[cube]]\nid = "c1"\nname = "Mine"\nuniques = true\n')
    monkeypatch.setattr(fc, "fetch_cube", lambda cube_id: CUBE)
    out = tmp_path / "out"

    fc.main(cfg, out)

    cubes = pd.read_parquet(out / "my_cubes.parquet")
    cards = pd.read_parquet(out / "my_cubes_cards.parquet")
    assert cubes.loc[0, ["label", "uniques", "n_main", "n_maybe", "owner"]].tolist() == ["Mine", True, 2, 1, "me"]
    assert len(cards) == 3
    assert cards["tags"].iloc[0].tolist() == ["burn"]
    assert str(cards["added"].dt.tz) == "UTC"
    assert "[OK]" in capsys.readouterr().out
