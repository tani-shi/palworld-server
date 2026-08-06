import json
from unittest.mock import MagicMock

import pytest


@pytest.fixture
def posted(env, monkeypatch):
    sent = []
    monkeypatch.setattr(
        "urllib.request.urlopen",
        lambda request, timeout: MagicMock(
            close=lambda: sent.append(request.data.decode())
        ),
    )
    return sent


def test_a_short_answer_is_one_message(posted):
    from palworld_bot import interactions

    interactions.send_followup("app", "token", "short")
    assert len(posted) == 1
    assert '"short"' in posted[0]


def test_the_posted_body_disables_mention_resolution(posted):
    from palworld_bot import interactions

    interactions.send_followup("app", "token", "short")
    assert json.loads(posted[0])["allowed_mentions"] == {"parse": []}


def test_a_long_answer_is_split(posted):
    from palworld_bot import interactions

    interactions.send_followup("app", "token", "x" * 5000)
    assert len(posted) == 3


def test_every_chunk_fits_the_limit(posted):
    from palworld_bot import interactions

    interactions.send_followup("app", "token", "\n\n".join(["y" * 900] * 8))
    for body in posted:
        assert len(json.loads(body)["content"]) <= interactions.CONTENT_LIMIT


def test_paragraphs_are_kept_whole_when_they_fit(posted):
    from palworld_bot import interactions

    interactions.send_followup("app", "token", "\n\n".join(["z" * 1500] * 2))
    assert [len(json.loads(b)["content"]) for b in posted] == [1500, 1500]


def test_an_empty_answer_still_posts_something(posted):
    from palworld_bot import interactions

    interactions.send_followup("app", "token", "   ")
    assert len(posted) == 1


def test_chunks_are_posted_in_order(posted):
    from palworld_bot import interactions

    interactions.send_followup("app", "token", "\n\n".join(["z" * 1500] * 2))
    assert [json.loads(b)["content"][0] for b in posted] == ["z", "z"]


def test_a_realistic_long_answer_round_trips_within_the_limit(posted):
    import re

    from palworld_bot import interactions

    paragraphs = [f"short paragraph {i}." for i in range(3)]
    paragraphs.append("o" * 2500)  # longer than CONTENT_LIMIT, forces a hard cut
    paragraphs += [("word " * 200 + f"tail {i}").strip() for i in range(5)]
    answer = "\n\n".join(paragraphs)
    assert len(answer) > 6000

    interactions.send_followup("app", "token", answer)

    chunks = [json.loads(b)["content"] for b in posted]
    assert len(chunks) > 1
    for chunk in chunks:
        assert len(chunk) <= interactions.CONTENT_LIMIT

    # Splitting only ever removes whitespace at the cut points (paragraph and
    # line breaks are stripped, and a hard cut can land on a space); collapse
    # whitespace on both sides before comparing so the check isn't fooled by
    # those join seams while still catching dropped or reordered text.
    def collapse(text):
        return re.sub(r"\s+", "", text)

    assert collapse("".join(chunks)) == collapse(answer)
