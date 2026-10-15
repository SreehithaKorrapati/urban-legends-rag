# scenario_analysis.py - per-country (scenario) breakdown of classifier performance.
# Reads the test split (carries a "country" field per example) plus whichever result
# files exist; predictions/true_labels in each results file line up by index with
# test.json, which is what lets us attach a country to each prediction.
# Run: python scripts/ml/scenario_analysis.py

import json
import os
from collections import defaultdict

from sklearn.metrics import accuracy_score, f1_score

BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPLITS_DIR = os.path.join(BASE_DIR, "data", "processed", "splits")
RESULTS_DIR = os.path.join(BASE_DIR, "data", "processed", "results")

RESULT_FILES = [
    ("TF-IDF + Logistic Regression", "baseline_tfidf_results.json"),
    ("Zero-shot LLM prompting", "baseline_zeroshot_results.json"),
    ("Fine-tuned DistilBERT (run1)", "distilbert_results_run1.json"),
    ("Fine-tuned DistilBERT (run1)", "distilbert_results.json"),  # fallback if not re-run with the new tag
    ("Fine-tuned DistilBERT (primary)", "distilbert_results_run5.json"),
]


def load_json(path):
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def main():
    test_data = load_json(os.path.join(SPLITS_DIR, "test.json"))
    if test_data is None:
        print("Could not find data/processed/splits/test.json - run split_data.py first.")
        return
    countries = [item["country"] for item in test_data]

    seen_models = set()
    all_rows = []

    # Score every available result file, broken out by country
    for model_label, fname in RESULT_FILES:
        if model_label in seen_models:
            continue
        path = os.path.join(RESULTS_DIR, fname)
        results = load_json(path)
        if results is None:
            continue
        seen_models.add(model_label)

        preds = results["predictions"]
        trues = results["true_labels"]
        if len(preds) != len(countries):
            print(f"[skip] {fname}: {len(preds)} predictions but test.json has {len(countries)} examples "
                  f"(order/length mismatch - skipping to avoid misleading numbers).")
            continue

        by_country_pred = defaultdict(list)
        by_country_true = defaultdict(list)
        for c, p, t in zip(countries, preds, trues):
            by_country_pred[c].append(p)
            by_country_true[c].append(t)

        print(f"\n=== {model_label} ({fname}) - per-country breakdown ===")
        for country in sorted(by_country_true.keys()):
            yp = by_country_pred[country]
            yt = by_country_true[country]
            acc = accuracy_score(yt, yp)
            macro_f1 = f1_score(yt, yp, average="macro", zero_division=0)
            n = len(yt)
            print(f"  {country:12s}  n={n:4d}  accuracy={acc:.4f}  macro_f1={macro_f1:.4f}")
            all_rows.append({
                "model": model_label,
                "country": country,
                "n": n,
                "accuracy": acc,
                "macro_f1": macro_f1,
            })

        overall_acc = accuracy_score(trues, preds)
        overall_f1 = f1_score(trues, preds, average="macro", zero_division=0)
        print(f"  {'OVERALL':12s}  n={len(trues):4d}  accuracy={overall_acc:.4f}  macro_f1={overall_f1:.4f}")

    if not all_rows:
        print("\nNo result files found yet - run the baseline/fine-tune scripts first.")
        return

    # Save full per-country breakdown for the report
    out_path = os.path.join(RESULTS_DIR, "scenario_analysis.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(all_rows, f, indent=2, ensure_ascii=False)
    print(f"\nSaved full breakdown to {out_path}")


if __name__ == "__main__":
    main()
