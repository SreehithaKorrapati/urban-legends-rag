# category_disagreement.py - per-category analysis of LLM annotator disagreement, and how
# that disagreement relates to the DistilBERT errors on the test set.
# Reads only saved files, so it needs no GPU, no API key, and no training.
# Run: python scripts/ml/category_disagreement.py [--model distilbert_results_run5.json]

import argparse
import json
import os
from collections import Counter, defaultdict

BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROCESSED_DIR = os.path.join(BASE_DIR, "data", "processed")
GOLD_PATH = os.path.join(PROCESSED_DIR, "gold_labeled_dataset.json")
TEST_PATH = os.path.join(PROCESSED_DIR, "splits", "test.json")
RESULTS_DIR = os.path.join(PROCESSED_DIR, "results")

CATEGORIES = [
    "Ghosts and Spirits",
    "Legendary Creatures",
    "Deities and Mythological Figures",
    "Legendary and Historical Figures",
    "Place-Based Legends",
    "Fairy Tales and Fables",
    "Cultural Superstitions and Practices",
]


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def valid_votes(record):
    votes = []
    for v in record.get("individual_votes", []):
        if isinstance(v, dict) and v.get("category") in CATEGORIES:
            votes.append((v.get("model", "unknown"), v["category"]))
    return votes


def pairwise_agreement(categories):
    n = len(categories)
    if n < 2:
        return None
    counts = Counter(categories)
    agree_pairs = sum(c * (c - 1) / 2 for c in counts.values())
    return agree_pairs / (n * (n - 1) / 2)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", default="distilbert_results_run5.json",
                   help="Results file used for the link to classifier errors.")
    args = p.parse_args()

    gold = load_json(GOLD_PATH)
    print(f"Loaded {len(gold)} gold-labeled chunks")

    per_cat = defaultdict(lambda: {"n": 0, "unanimous": 0, "with_dissent": 0, "pair_sum": 0.0, "pair_n": 0})
    dissent_pairs = Counter()
    per_model = defaultdict(lambda: {"votes": 0, "match_gold": 0})
    chunk_unanimous = {}
    chunk_agreement_type = {}

    for rec in gold:
        votes = valid_votes(rec)
        cats = [c for _, c in votes]
        g = rec["gold_category"]
        chunk_agreement_type[rec["id"]] = rec.get("agreement_type", "unknown")
        if len(cats) < 2:
            continue
        unanimous = len(set(cats)) == 1
        chunk_unanimous[rec["id"]] = unanimous
        s = per_cat[g]
        s["n"] += 1
        s["unanimous"] += int(unanimous)
        s["with_dissent"] += int(not unanimous)
        pa = pairwise_agreement(cats)
        s["pair_sum"] += pa
        s["pair_n"] += 1
        for model, c in votes:
            per_model[model]["votes"] += 1
            per_model[model]["match_gold"] += int(c == g)
            if c != g:
                dissent_pairs[(g, c)] += 1

    print("\n=== Agreement by gold category (lowest pairwise agreement first) ===")
    print(f"{'Category':<40}{'Chunks':>8}{'Unanimous':>11}{'Pairwise':>10}")
    rows = []
    for cat, s in per_cat.items():
        pair = s["pair_sum"] / s["pair_n"] if s["pair_n"] else 0.0
        rows.append((cat, s["n"], s["unanimous"], pair))
    rows.sort(key=lambda r: r[3])
    for cat, n, un, pair in rows:
        print(f"{cat:<40}{n:>8}{un / n:>10.1%}{pair:>10.3f}")

    print("\n=== Most common annotator dissent (gold category -> category the dissenting LLM chose) ===")
    top = dissent_pairs.most_common(10)
    for (g, c), k in top:
        print(f"  {k:>4}x  {g}  ->  {c}")

    print("\n=== Agreement of each annotator with the gold label ===")
    for model, s in sorted(per_model.items()):
        print(f"  {model:<14} votes={s['votes']:>5}  matches gold={s['match_gold'] / s['votes']:.1%}")

    # Link to classifier errors on the test set
    link = None
    results_path = os.path.join(RESULTS_DIR, args.model)
    if os.path.exists(results_path) and os.path.exists(TEST_PATH):
        test = load_json(TEST_PATH)
        res = load_json(results_path)
        preds = res.get("predictions", [])
        if len(preds) != len(test):
            print(f"\n[skip] {args.model}: {len(preds)} predictions but {len(test)} test examples.")
        else:
            groups = defaultdict(lambda: {"n": 0, "errors": 0})
            for item, pred in zip(test, preds):
                key = "unanimous (3 of 3 agree)" if chunk_unanimous.get(item["id"]) else "split vote (2 of 3 or less)"
                groups[key]["n"] += 1
                groups[key]["errors"] += int(pred != item["gold_category"])
            print(f"\n=== Classifier error rate by annotator agreement ({args.model}) ===")
            for key, s in groups.items():
                print(f"  {key:<30} n={s['n']:>4}  errors={s['errors']:>3}  error rate={s['errors'] / s['n']:.1%}")
            link = {k: dict(v) for k, v in groups.items()}
            try:
                from scipy.stats import fisher_exact
                u = groups["unanimous (3 of 3 agree)"]
                s_ = groups["split vote (2 of 3 or less)"]
                table = [[u["errors"], u["n"] - u["errors"]], [s_["errors"], s_["n"] - s_["errors"]]]
                odds, pval = fisher_exact(table)
                print(f"  Fisher exact test: p = {pval:.4f}")
                link["fisher_exact_p"] = pval
            except (ImportError, KeyError):
                pass

    out = {
        "per_category": {c: {"chunks": n, "unanimous_rate": un / n, "mean_pairwise_agreement": pair}
                         for c, n, un, pair in rows},
        "top_dissent_pairs": [{"gold": g, "dissent": c, "count": k} for (g, c), k in top],
        "per_annotator_agreement_with_gold": {m: s["match_gold"] / s["votes"] for m, s in per_model.items()},
        "classifier_error_by_agreement": link,
    }
    out_path = os.path.join(RESULTS_DIR, "category_disagreement.json")
    os.makedirs(RESULTS_DIR, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
    print(f"\nSaved to {out_path}")


if __name__ == "__main__":
    main()
