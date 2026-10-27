# relabel_without_annotator.py - recomputes the gold labels after removing one annotator's votes,
# reports how many labels change, recomputes agreement, and writes new split files that keep the
# SAME passages in train/val/test (only the labels change), so results stay comparable.
# Needs no GPU and no API key.
# Run: python scripts/ml/relabel_without_annotator.py --exclude allam7b

import argparse
import json
import os
from collections import Counter

BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROCESSED_DIR = os.path.join(BASE_DIR, "data", "processed")
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


def save_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)


def votes_of(rec):
    out = []
    for v in rec.get("individual_votes", []):
        if isinstance(v, dict) and v.get("category") in CATEGORIES:
            try:
                conf = float(v.get("confidence", 0) or 0)
            except (TypeError, ValueError):
                conf = 0.0
            out.append((v.get("model", "unknown"), v["category"], conf))
    return out


def majority(votes):
    # Category chosen most often. If tied, the vote with the highest confidence among the tied categories.
    counts = Counter(c for _, c, _ in votes)
    top = max(counts.values())
    tied = [c for c, n in counts.items() if n == top]
    if len(tied) == 1:
        return tied[0], False
    best = max((v for v in votes if v[1] in tied), key=lambda v: v[2])
    return best[1], True


def pairwise(cats):
    n = len(cats)
    if n < 2:
        return None
    counts = Counter(cats)
    return sum(k * (k - 1) / 2 for k in counts.values()) / (n * (n - 1) / 2)


def fleiss_kappa(items, n):
    N = len(items)
    if N == 0 or n < 2:
        return None
    totals = Counter()
    p_sum = 0.0
    for cats in items:
        counts = Counter(cats)
        totals.update(counts)
        p_sum += (sum(k * k for k in counts.values()) - n) / (n * (n - 1))
    p_bar = p_sum / N
    pe = sum((t / (N * n)) ** 2 for t in totals.values())
    if pe == 1:
        return None
    return (p_bar - pe) / (1 - pe)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exclude", default="allam7b", help="Annotator name (as in the data files) to remove.")
    ap.add_argument("--splits-in", default="splits", help="Existing split folder under data/processed.")
    args = ap.parse_args()
    ex = args.exclude
    tag = f"no_{ex}"

    gold = load_json(os.path.join(PROCESSED_DIR, "gold_labeled_dataset.json"))
    print(f"Loaded {len(gold)} gold-labeled chunks. Removing votes from: {ex}")

    new_label = {}
    changed = Counter()
    n_with_ex = n_changed = n_tie = n_single = 0
    grpA, grpB_orig, grpB_new = [], [], []
    pair_before, pair_after = [], []
    new_records = []

    for rec in gold:
        votes = votes_of(rec)
        rest = [v for v in votes if v[0] != ex]
        had = len(rest) < len(votes)
        old = rec["gold_category"]
        new = old
        if had and rest:
            n_with_ex += 1
            new, tie = majority(rest)
            n_tie += int(tie)
            n_single += int(len(rest) == 1)
            if new != old:
                n_changed += 1
                changed[(old, new)] += 1
        new_label[rec["id"]] = new
        r2 = dict(rec)
        r2["gold_category_original"] = old
        r2["gold_category"] = new
        r2["votes_used"] = len(rest) if had else len(votes)
        new_records.append(r2)
        if len(votes) == 3 and not had:
            grpA.append([c for _, c, _ in votes])
        if len(votes) == 3 and had and len(rest) == 2:
            grpB_orig.append([c for _, c, _ in votes])
            grpB_new.append([c for _, c, _ in rest])
        pa = pairwise([c for _, c, _ in votes])
        pb = pairwise([c for _, c, _ in (rest if had else votes)])
        if pa is not None:
            pair_before.append(pa)
        if pb is not None:
            pair_after.append(pb)

    def f(x):
        return "n/a" if x is None else f"{x:.4f}"

    print(f"\nChunks where {ex} voted: {n_with_ex} of {len(gold)} ({n_with_ex / len(gold):.1%})")
    print(f"Gold label changed after removing its votes: {n_changed} ({n_changed / max(1, n_with_ex):.1%} of those, "
          f"{n_changed / len(gold):.1%} of all chunks)")
    print(f"  ties between the remaining votes resolved by confidence: {n_tie}; chunks left with a single vote: {n_single}")
    print("  most common label changes (old -> new):")
    for (o, n_), k in changed.most_common(8):
        print(f"    {k:>3}x  {o}  ->  {n_}")
    print("\nAgreement")
    print(f"  Fleiss kappa, chunks without {ex} (3 votes, n={len(grpA)}):        {f(fleiss_kappa(grpA, 3))}")
    print(f"  Fleiss kappa, chunks with {ex}, all 3 votes (n={len(grpB_orig)}):  {f(fleiss_kappa(grpB_orig, 3))}")
    print(f"  Fleiss kappa, same chunks, remaining 2 votes:             {f(fleiss_kappa(grpB_new, 2))}")
    print(f"  Mean pairwise agreement, all chunks: before {sum(pair_before) / len(pair_before):.4f}, "
          f"after {sum(pair_after) / len(pair_after):.4f}")
    print("  (kappa values with 2 votes and with 3 votes are not strictly comparable; pairwise agreement is the fairer comparison)")

    save_json(os.path.join(PROCESSED_DIR, f"gold_labeled_dataset_{tag}.json"), new_records)

    # New split files: same passages in each split, new labels
    out_dir = os.path.join(PROCESSED_DIR, f"splits_{tag}")
    print(f"\nWriting split files with new labels to {out_dir}")
    split_stats = {}
    new_test = None
    for name in ("train", "val", "test"):
        items = load_json(os.path.join(PROCESSED_DIR, args.splits_in, f"{name}.json"))
        ch = 0
        out = []
        for it in items:
            r = dict(it)
            r["gold_category_original"] = it["gold_category"]
            r["gold_category"] = new_label.get(it["id"], it["gold_category"])
            ch += int(r["gold_category"] != it["gold_category"])
            out.append(r)
        save_json(os.path.join(out_dir, f"{name}.json"), out)
        dist = Counter(r["gold_category"] for r in out)
        split_stats[name] = {"n": len(out), "labels_changed": ch, "place_based": dist["Place-Based Legends"]}
        print(f"  {name:<5} n={len(out):>4}  labels changed={ch:>3}  Place-Based Legends passages={dist['Place-Based Legends']}")
        if name == "test":
            new_test = out

    # How does the existing main model score against the new test labels?
    cmp = None
    res_path = os.path.join(RESULTS_DIR, "distilbert_results_run5.json")
    if new_test is not None and os.path.exists(res_path):
        preds = load_json(res_path).get("predictions", [])
        if len(preds) == len(new_test):
            from sklearn.metrics import accuracy_score, f1_score
            old_y = [r["gold_category_original"] for r in new_test]
            new_y = [r["gold_category"] for r in new_test]
            cmp = {
                "run5_vs_original_labels": {"accuracy": accuracy_score(old_y, preds), "macro_f1": f1_score(old_y, preds, average="macro")},
                "run5_vs_new_labels": {"accuracy": accuracy_score(new_y, preds), "macro_f1": f1_score(new_y, preds, average="macro")},
            }
            print("\nExisting run5 predictions (model trained on the ORIGINAL labels):")
            print(f"  against original test labels: accuracy {cmp['run5_vs_original_labels']['accuracy']:.4f}, macro F1 {cmp['run5_vs_original_labels']['macro_f1']:.4f}")
            print(f"  against new test labels:      accuracy {cmp['run5_vs_new_labels']['accuracy']:.4f}, macro F1 {cmp['run5_vs_new_labels']['macro_f1']:.4f}")

    save_json(os.path.join(RESULTS_DIR, f"relabel_summary_{tag}.json"), {
        "excluded": ex, "chunks": len(gold), "chunks_with_excluded": n_with_ex, "labels_changed": n_changed,
        "ties_resolved_by_confidence": n_tie, "single_vote_chunks": n_single,
        "top_changes": [{"old": o, "new": n_, "count": k} for (o, n_), k in changed.most_common(15)],
        "kappa_without_excluded_3votes": fleiss_kappa(grpA, 3),
        "kappa_with_excluded_3votes": fleiss_kappa(grpB_orig, 3),
        "kappa_with_excluded_remaining_2votes": fleiss_kappa(grpB_new, 2),
        "pairwise_before": sum(pair_before) / len(pair_before), "pairwise_after": sum(pair_after) / len(pair_after),
        "splits": split_stats, "run5_comparison": cmp,
    })
    print(f"\nSaved summary to {os.path.join(RESULTS_DIR, f'relabel_summary_{tag}.json')}")


if __name__ == "__main__":
    main()
