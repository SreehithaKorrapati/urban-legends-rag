# inspect_insufficient.py - shows which chunks were excluded from the gold dataset
# (zero valid annotations) and why each model failed on them
# Run: python scripts/ml/inspect_insufficient.py

import json
import os

BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ANNOTATIONS_PATH = os.path.join(BASE_DIR, "data", "processed", "annotations.json")
GOLD_PATH = os.path.join(BASE_DIR, "data", "processed", "gold_labeled_dataset.json")


def main():
    with open(ANNOTATIONS_PATH, "r", encoding="utf-8") as f:
        annotations = json.load(f)

    with open(GOLD_PATH, "r", encoding="utf-8") as f:
        gold = json.load(f)

    # Chunks present in annotations but missing from the gold dataset
    gold_ids = set(item["id"] for item in gold)
    missing_ids = [cid for cid in annotations if cid not in gold_ids]

    print(f"Total chunks excluded as 'insufficient': {len(missing_ids)}\n")

    # Print each missing chunk's per-rater failure reason
    for cid in missing_ids:
        entry = annotations[cid]
        print(f"--- {cid} ({entry.get('country')}, \"{entry.get('article_title')}\") ---")
        for key, val in entry.items():
            if key in ("country", "article_title"):
                continue
            if isinstance(val, dict):
                if val.get("error"):
                    print(f"  {key}: ERROR - {val['error']}")
                elif val.get("parse_error"):
                    print(f"  {key}: PARSE ERROR - response was cut off or malformed")
                elif val.get("invalid_category"):
                    print(f"  {key}: INVALID CATEGORY - returned \"{val.get('category')}\" (not in our 7 categories)")
                else:
                    print(f"  {key}: {val.get('category')} (confidence {val.get('confidence')})")
        print()


if __name__ == "__main__":
    main()
