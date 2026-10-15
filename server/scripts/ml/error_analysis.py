# error_analysis.py - confusion matrix, top confusion pairs, misclassified examples, and
# error rates by country/category for a saved classifier results file.
# Run: python scripts/ml/error_analysis.py [--model distilbert_results_run5.json] [--samples 15]

import argparse
import json
import os
from collections import Counter, defaultdict

BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPLITS_DIR = os.path.join(BASE_DIR, "data", "processed", "splits")
RESULTS_DIR = os.path.join(BASE_DIR, "data", "processed", "results")

DEFAULT_CANDIDATES = [
    "distilbert_results_run2.json",
    "distilbert_results_run1.json",
    "distilbert_results.json",
]


def load_json(path):
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def resolve_model_file(explicit):
    if explicit:
        path = os.path.join(RESULTS_DIR, explicit)
        if os.path.exists(path):
            return explicit
        print(f"Requested file {explicit} not found in {RESULTS_DIR}")
        return None
    for name in DEFAULT_CANDIDATES:
        if os.path.exists(os.path.join(RESULTS_DIR, name)):
            return name
    return None


def parse_args():
    p = argparse.ArgumentParser(description="Error analysis for a saved classifier results file.")
    p.add_argument("--model", type=str, default=None,
                    help="Results filename in data/processed/results/ (default: auto-detect best DistilBERT run).")
    p.add_argument("--samples", type=int, default=10, help="Number of misclassified examples to print.")
    return p.parse_args()


def main():
    args = parse_args()

    test_data = load_json(os.path.join(SPLITS_DIR, "test.json"))
    if test_data is None:
        print("Could not find data/processed/splits/test.json - run split_data.py first.")
        return

    fname = resolve_model_file(args.model)
    if fname is None:
        print(f"No results file found. Looked for: {args.model or DEFAULT_CANDIDATES}")
        return

    results = load_json(os.path.join(RESULTS_DIR, fname))
    preds = results["predictions"]
    trues = results["true_labels"]

    # predictions/true_labels must align by index with test_data
    if len(preds) != len(test_data):
        print(f"Length mismatch: {len(preds)} predictions vs {len(test_data)} test examples - "
              f"can't align by index, aborting.")
        return

    print(f"=== Error analysis for {results.get('model', fname)} ({fname}) ===")
    n_total = len(trues)
    n_correct = sum(1 for p, t in zip(preds, trues) if p == t)
    print(f"Overall: {n_correct}/{n_total} correct ({n_correct / n_total:.1%}), "
          f"{n_total - n_correct} errors\n")

    # 1. Confusion matrix
    categories = sorted(set(trues) | set(preds))
    confusion = {t: Counter() for t in categories}
    for p, t in zip(preds, trues):
        confusion[t][p] += 1

    print("Confusion matrix (rows = true, cols = predicted):")
    header = "true\\pred".ljust(22) + "".join(c[:10].rjust(12) for c in categories)
    print(header)
    for t in categories:
        row = t.ljust(22) + "".join(str(confusion[t][p]).rjust(12) for p in categories)
        print(row)

    # 2. Most common confusion pairs (excluding correct predictions)
    pair_counts = Counter()
    for p, t in zip(preds, trues):
        if p != t:
            pair_counts[(t, p)] += 1

    print("\nTop confusion pairs (true -> predicted):")
    for (t, p), count in pair_counts.most_common(10):
        print(f"  {count:3d}x  {t}  ->  {p}")

    # 3. Sample misclassified examples with real text
    print(f"\nSample misclassified examples (showing up to {args.samples}):")
    misclassified = []
    for item, p, t in zip(test_data, preds, trues):
        if p != t:
            misclassified.append({
                "id": item.get("id"),
                "country": item.get("country"),
                "article_title": item.get("article_title"),
                "true": t,
                "predicted": p,
                "text_snippet": (item.get("text") or "")[:300],
            })

    for ex in misclassified[:args.samples]:
        print(f"\n  [{ex['country']}] \"{ex['article_title']}\" (id={ex['id']})")
        print(f"    true: {ex['true']}  |  predicted: {ex['predicted']}")
        print(f"    text: {ex['text_snippet']}...")

    # 4. Error rate by country
    by_country_total = Counter()
    by_country_errors = Counter()
    for item, p, t in zip(test_data, preds, trues):
        c = item.get("country")
        by_country_total[c] += 1
        if p != t:
            by_country_errors[c] += 1

    print("\nError rate by country:")
    for c in sorted(by_country_total):
        total = by_country_total[c]
        errs = by_country_errors[c]
        print(f"  {c:12s}  {errs}/{total} errors ({errs / total:.1%})")

    # 5. Error rate by true category (connects errors to class imbalance / support)
    by_cat_total = Counter(trues)
    by_cat_errors = Counter()
    for p, t in zip(preds, trues):
        if p != t:
            by_cat_errors[t] += 1

    print("\nError rate by true category (support = how many test examples of that category):")
    for cat in sorted(by_cat_total, key=lambda c: -by_cat_total[c]):
        total = by_cat_total[cat]
        errs = by_cat_errors[cat]
        print(f"  {cat:40s}  support={total:4d}  errors={errs:4d}  ({errs / total:.1%})")

    # Save full dump for the report appendix
    out_path = os.path.join(RESULTS_DIR, "error_analysis.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({
            "model_file": fname,
            "overall_accuracy": n_correct / n_total,
            "confusion_matrix": {t: dict(confusion[t]) for t in categories},
            "top_confusion_pairs": [{"true": t, "predicted": p, "count": c} for (t, p), c in pair_counts.most_common(20)],
            "all_misclassified": misclassified,
            "error_rate_by_country": {c: by_country_errors[c] / by_country_total[c] for c in by_country_total},
            "error_rate_by_category": {c: by_cat_errors[c] / by_cat_total[c] for c in by_cat_total},
        }, f, indent=2, ensure_ascii=False)
    print(f"\nFull error analysis saved to {out_path}")


if __name__ == "__main__":
    main()
