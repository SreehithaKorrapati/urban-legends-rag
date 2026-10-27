# summarize_runs.py - compares saved DistilBERT runs side by side (accuracy, macro F1, per-class F1)
# and reports mean and standard deviation when several runs are given.
# Run: python scripts/ml/summarize_runs.py run5 run6 run6_s43

import argparse
import json
import os
import statistics

BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RESULTS_DIR = os.path.join(BASE_DIR, "data", "processed", "results")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("tags", nargs="+", help="Run tags, e.g. run5 run6")
    args = p.parse_args()

    runs = []
    for tag in args.tags:
        path = os.path.join(RESULTS_DIR, f"distilbert_results_{tag}.json")
        if not os.path.exists(path):
            print(f"[skip] {tag}: {path} not found")
            continue
        with open(path, "r", encoding="utf-8") as f:
            runs.append((tag, json.load(f)))
    if not runs:
        return

    classes = [c for c in runs[0][1]["per_class_report"] if c not in ("accuracy", "macro avg", "weighted avg")]
    print(f"{'Run':<12}{'Accuracy':>10}{'Macro F1':>10}{'Weighted F1':>13}")
    for tag, r in runs:
        print(f"{tag:<12}{r['accuracy']:>10.4f}{r['macro_f1']:>10.4f}{r['weighted_f1']:>13.4f}")

    print("\nPer-class F1")
    print(f"{'Category':<40}" + "".join(f"{t:>12}" for t, _ in runs))
    for c in classes:
        print(f"{c:<40}" + "".join(f"{r['per_class_report'][c]['f1-score']:>12.3f}" for _, r in runs))

    if len(runs) > 1:
        accs = [r["accuracy"] for _, r in runs]
        f1s = [r["macro_f1"] for _, r in runs]
        print(f"\nOver {len(runs)} runs: accuracy {statistics.mean(accs):.4f} +/- {statistics.stdev(accs):.4f}, "
              f"macro F1 {statistics.mean(f1s):.4f} +/- {statistics.stdev(f1s):.4f}")


if __name__ == "__main__":
    main()
