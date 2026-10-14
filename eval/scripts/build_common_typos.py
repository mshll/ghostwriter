"""Writes eval/data/typos-common.jsonl: well-known English misspellings in short messages.

Random keyboard slips (build_typo_set.py) are rare in a language model's training text; these misspellings
are common there, so a model finds them more plausible. Rows end right after the misspelled word.
"""
import json
from pathlib import Path

ROWS = [
    ("I recieve", "recieve", "receive", "the invoices every Monday."),
    ("Please keep these two lists", "seperate", "separate", "from each other."),
    ("I will", "definately", "definitely", "be there on time."),
    ("The error", "occured", "occurred", "after the last deploy."),
    ("Let's wait", "untill", "until", "the build finishes."),
    ("Which one do you prefer,", "wich", "which", "one is cheaper?"),
    ("I don't", "beleive", "believe", "that's right."),
    ("See you", "tommorow", "tomorrow", "at the office."),
    ("Can we", "accomodate", "accommodate", "two more guests?"),
    ("The new", "goverment", "government", "policy starts in May."),
    ("Set up the test", "enviroment", "environment", "before Friday."),
    ("At the", "begining", "beginning", "of the call she mentioned it."),
    ("That sounds", "wierd", "weird", "to me."),
    ("I'm", "truely", "truly", "sorry about the delay."),
    ("We had an", "arguement", "argument", "about the budget."),
    ("It is not", "neccessary", "necessary", "to reply."),
    ("She works as an", "independant", "independent", "consultant."),
    ("Thanks for the", "recomendation", "recommendation", "on the restaurant."),
    ("Please", "acknowlege", "acknowledge", "the request."),
    ("The meeting is on", "wensday", "Wednesday", "afternoon."),
    ("I have a", "calender", "calendar", "conflict at three."),
    ("This is a", "noticable", "noticeable", "improvement."),
    ("Our", "buisness", "business", "hours changed."),
    ("I'll send the", "adress", "address", "later today."),
    ("Thanks for your", "patiance", "patience", "with this."),
    ("It was an", "embarassing", "embarrassing", "mistake."),
    ("We need to", "maintainance", "maintenance", "the servers tonight."),
    ("She is", "familar", "familiar", "with the codebase."),
    ("That's a", "garantee", "guarantee", "from the vendor."),
    ("Let's", "persue", "pursue", "the second option."),
    ("I", "realy", "really", "appreciate it."),
    ("The", "commitee", "committee", "meets on Thursday."),
    ("It's", "posible", "possible", "that we ship early."),
    ("I'm not", "suprised", "surprised", "at all."),
    ("This is my", "frist", "first", "week here."),
    ("I", "thnk", "think", "we should wait."),
    ("Let me know", "becuase", "because", "I need to plan."),
    ("What", "abotu", "about", "next week?"),
    ("Sounds good,", "thier", "their", "team will handle it."),
]


def main() -> None:
    out = Path(__file__).resolve().parents[1] / "data" / "typos-common.jsonl"
    with out.open("w") as handle:
        for index, (before, typed, truth, _) in enumerate(ROWS, start=1):
            row = {
                "id": f"common-en-{index:03d}", "kind": "typo", "operation": "common", "lang": "en",
                "app": "Messages", "field": "chat", "truth": truth, "before": f"{before} {typed} ", "typed": typed,
            }
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"wrote {len(ROWS)} rows to {out}")


if __name__ == "__main__":
    main()
