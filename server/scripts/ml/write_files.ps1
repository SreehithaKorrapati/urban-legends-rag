$dir = "C:\Users\dell\urban-legends-rag\server\scripts\ml"

@'
# agreement_analysis.py
# Fleiss' kappa, per-category agreement, disagreement matrix, and annotator-combo
# breakdown for the 3-of-5 LLM ensemble annotations. Reads whichever rater keys
# are actually present per chunk (the 3 assigned raters vary per chunk).
# Run: python agreement_analysis.py

import json
import os
import re
from collections import Counter, defaultdict
from itertools import combinations

CATEGORY_RE = re.compile(r'"category"\s*:\s*"([^"]+)"')
CONFIDENCE_RE = re.compile(r'"confidence"\s*:\s*([0-9.]+)')

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SERVER_DIR = os.path.dirname(os.path.dirname(SCRIPT_DIR))
ANNOTATIONS_PATH = os.path.join(SERVER_DIR, "data", "processed", "annotations.json")
OUTPUT_PATH = os.path.join(SERVER_DIR, "data", "processed", "agreement_analysis_detailed.json")

NON_RATER_FIELDS = {"country", "article_title"}

CATEGORIES = [
    "Ghosts and Spirits",
    "Legendary Creatures",
    "Deities and Mythological Figures",
    "Legendary and Historical Figures",
    "Place-Based Legends",
    "Fairy Tales and Fables",
    "Cultural Superstitions and Practices",
]


def extract_vote(rater_data):
    # Pull {category, confidence, reasoning} out of one rater's entry.
    # A parse_error entry with a truncated raw_response can still have an intact
    # category before the cutoff, so recover it via regex instead of discarding it.
    if not isinstance(rater_data, dict):
        return None

    if "category" in rater_data:
        return {
            "category": rater_data["category"],
            "confidence": rater_data.get("confidence"),
            "reasoning": rater_data.get("reasoning"),
            "recovered": False,
        }

    if rater_data.get("parse_error") and rater_data.get("raw_response"):
        m = CATEGORY_RE.search(rater_data["raw_response"])
        if m:
            conf_match = CONFIDENCE_RE.search(rater_data["raw_response"])
            return {
                "category": m.group(1),
                "confidence": float(conf_match.group(1)) if conf_match else None,
                "reasoning": None,
                "recovered": True,
            }

    return None


def get_raters(record):
    # Annotator keys in this record with a recoverable vote
    return [
        field
        for field, val in record.items()
        if field not in NON_RATER_FIELDS and extract_vote(val) is not None
    ]


def fleiss_kappa(category_counts_per_item, n_raters, categories):
    N = len(category_counts_per_item)
    n = n_raters
    p_i_list = []
    for counts in category_counts_per_item:
        sq_sum = sum(counts.get(c, 0) ** 2 for c in categories)
        p_i = (sq_sum - n) / (n * (n - 1))
        p_i_list.append(p_i)
    p_bar = sum(p_i_list) / N

    total_assignments = N * n
    p_j = {}
    for c in categories:
        total_c = sum(counts.get(c, 0) for counts in category_counts_per_item)
        p_j[c] = total_c / total_assignments

    p_bar_e = sum(p_j[c] ** 2 for c in categories)
    if p_bar_e == 1:
        return 1.0
    return (p_bar - p_bar_e) / (1 - p_bar_e)


def interpret_kappa(k):
    if k < 0:
        return "poor (worse than chance)"
    elif k < 0.2:
        return "slight"
    elif k < 0.4:
        return "fair"
    elif k < 0.6:
        return "moderate"
    elif k < 0.8:
        return "substantial"
    else:
        return "almost perfect"


def main():
    with open(ANNOTATIONS_PATH, "r", encoding="utf-8") as f:
        annotations = json.load(f)

    print(f"Loaded {len(annotations)} annotated chunks.")

    category_counts_per_item = []
    per_category_total = Counter()
    per_category_full_agreement = Counter()
    disagreement_pair_counts = Counter()
    disagreement_examples = []
    combo_counts = Counter()
    combo_full_agreement = Counter()

    total_pairs_compared = 0
    total_pairs_agreed = 0
    skipped = 0

    skipped_examples = []
    raw_key_count_hist = Counter()
    recovered_count = 0

    # Walk every chunk and tally votes per rater combo
    for chunk_id, record in annotations.items():
        raw_keys = [f for f in record.keys() if f not in NON_RATER_FIELDS]
        raw_key_count_hist[len(raw_keys)] += 1

        raters = get_raters(record)
        if len(raters) < 2:
            skipped += 1
            if len(skipped_examples) < 5:
                skipped_examples.append({"chunk_id": chunk_id, "raw_record": record})
            continue

        vote_info = {r: extract_vote(record[r]) for r in raters}
        votes = [vote_info[r]["category"] for r in raters]
        recovered_count += sum(1 for r in raters if vote_info[r]["recovered"])
        n_raters = len(votes)

        counts = Counter(votes)
        category_counts_per_item.append(dict(counts))

        combo_key = "+".join(sorted(raters))
        combo_counts[combo_key] += 1

        majority_category, majority_n = counts.most_common(1)[0]
        per_category_total[majority_category] += 1
        if majority_n == n_raters:
            per_category_full_agreement[majority_category] += 1
            combo_full_agreement[combo_key] += 1

        for v1, v2 in combinations(votes, 2):
            total_pairs_compared += 1
            if v1 == v2:
                total_pairs_agreed += 1

        if majority_n < n_raters:
            unique_cats = set(votes)
            if len(unique_cats) >= 2:
                for c1, c2 in combinations(sorted(unique_cats), 2):
                    disagreement_pair_counts[f"{c1} vs {c2}"] += 1

            disagreement_examples.append(
                {
                    "chunk_id": chunk_id,
                    "country": record.get("country"),
                    "article_title": record.get("article_title"),
                    "votes": {
                        r: {
                            "category": vote_info[r]["category"],
                            "confidence": vote_info[r]["confidence"],
                            "reasoning": vote_info[r]["reasoning"],
                            "recovered_from_truncated_json": vote_info[r]["recovered"],
                        }
                        for r in raters
                    },
                }
            )

    print(f"Valid chunks (>=2 raters): {len(category_counts_per_item)}, skipped: {skipped}")
    print(f"Votes recovered from truncated/parse-error JSON via regex: {recovered_count}")
    print(f"Raw rater-key-count histogram (excluding country/article_title): {dict(raw_key_count_hist)}")
    if skipped_examples:
        print("\n--- Sample skipped records (up to 5) ---")
        for ex in skipped_examples:
            print(json.dumps(ex, indent=2, ensure_ascii=False)[:1500])
            print("---")

    n_raters_per_item = [sum(c.values()) for c in category_counts_per_item]
    rater_count_breakdown = Counter(n_raters_per_item)
    print(f"Rater-count breakdown among valid chunks: {dict(rater_count_breakdown)}")

    # Fleiss' kappa per rater-count subgroup (3-rater and 2-rater chunks are not comparable)
    kappa_by_rater_count = {}
    for n in sorted(rater_count_breakdown):
        if n < 2:
            continue
        subset = [c for c, nr in zip(category_counts_per_item, n_raters_per_item) if nr == n]
        k = fleiss_kappa(subset, n_raters=n, categories=CATEGORIES)
        kappa_by_rater_count[str(n)] = {
            "n_chunks": len(subset),
            "kappa": round(k, 4),
            "interpretation": interpret_kappa(k),
        }
        print(f"  Fleiss' kappa for {n}-rater chunks (n={len(subset)}): {k:.4f} ({interpret_kappa(k)})")

    # Headline kappa = 3-rater subset (the proposal's design); 2-rater is a degraded
    # fallback reported for transparency only, not used as headline
    if "3" in kappa_by_rater_count:
        dominant_n = 3
    else:
        dominant_n = rater_count_breakdown.most_common(1)[0][0]
    kappa = kappa_by_rater_count[str(dominant_n)]["kappa"]

    per_category_agreement_rate = {
        cat: {
            "total": per_category_total.get(cat, 0),
            "full_agreement": per_category_full_agreement.get(cat, 0),
            "full_agreement_rate": round(
                per_category_full_agreement.get(cat, 0) / per_category_total[cat], 3
            )
            if per_category_total.get(cat, 0) > 0
            else None,
        }
        for cat in CATEGORIES
    }

    overall_pairwise_agreement_percent = round(100 * total_pairs_agreed / total_pairs_compared, 1)

    combo_breakdown = {
        combo: {
            "count": combo_counts[combo],
            "full_agreement": combo_full_agreement.get(combo, 0),
            "full_agreement_rate": round(combo_full_agreement.get(combo, 0) / combo_counts[combo], 3),
        }
        for combo in combo_counts
    }

    top_disagreement_pairs = disagreement_pair_counts.most_common(15)

    examples_by_pair = defaultdict(list)
    for ex in disagreement_examples:
        cats = sorted(set(v["category"] for v in ex["votes"].values()))
        if len(cats) >= 2:
            for c1, c2 in combinations(cats, 2):
                examples_by_pair[f"{c1} vs {c2}"].append(ex)

    sampled_examples = {}
    for pair, _ in top_disagreement_pairs[:8]:
        sampled_examples[pair] = examples_by_pair[pair][:2]

    result = {
        "total_chunks_with_valid_annotations": len(category_counts_per_item),
        "skipped_chunks": skipped,
        "fleiss_kappa": round(kappa, 4) if kappa is not None else None,
        "fleiss_kappa_interpretation": interpret_kappa(kappa) if kappa is not None else None,
        "fleiss_kappa_headline_rater_count": dominant_n,
        "fleiss_kappa_by_rater_count": kappa_by_rater_count,
        "rater_count_breakdown": dict(rater_count_breakdown),
        "votes_recovered_from_truncated_json": recovered_count,
        "overall_pairwise_agreement_percent": overall_pairwise_agreement_percent,
        "annotator_combo_breakdown": combo_breakdown,
        "per_category_agreement": per_category_agreement_rate,
        "top_disagreement_category_pairs": [
            {"pair": pair, "count": count} for pair, count in top_disagreement_pairs
        ],
        "disagreement_examples_by_pair": sampled_examples,
    }

    # Save full breakdown for the report
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print(f"Fleiss' kappa: {kappa:.4f} ({interpret_kappa(kappa)})" if kappa is not None else "Fleiss' kappa: N/A")
    print(f"Overall pairwise agreement: {overall_pairwise_agreement_percent}%")
    print(f"Saved detailed agreement analysis to {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
'@ | Set-Content -Encoding utf8 (Join-Path $dir "agreement_analysis.py")

@'
# baseline_tfidf.py - TF-IDF + Logistic Regression baseline classifier
# Trains on the fixed train split, evaluates on test, reports accuracy/macro-F1/per-class breakdown
# Run: python scripts/ml/baseline_tfidf.py

import json
import os

from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import classification_report, accuracy_score, f1_score, confusion_matrix

BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPLITS_DIR = os.path.join(BASE_DIR, "data", "processed", "splits")
RESULTS_DIR = os.path.join(BASE_DIR, "data", "processed", "results")


def load_split(name):
    path = os.path.join(SPLITS_DIR, f"{name}.json")
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    texts = [item["text"] for item in data]
    labels = [item["gold_category"] for item in data]
    return texts, labels


def main():
    os.makedirs(RESULTS_DIR, exist_ok=True)

    # Load the fixed train/test split
    train_texts, train_labels = load_split("train")
    test_texts, test_labels = load_split("test")

    print(f"Train: {len(train_texts)} examples, Test: {len(test_texts)} examples")

    # Vectorize and fit
    vectorizer = TfidfVectorizer(max_features=5000, ngram_range=(1, 2), stop_words="english")
    X_train = vectorizer.fit_transform(train_texts)
    X_test = vectorizer.transform(test_texts)

    clf = LogisticRegression(max_iter=1000, class_weight="balanced", random_state=42)
    clf.fit(X_train, train_labels)

    # Evaluate on held-out test set
    predictions = clf.predict(X_test)

    accuracy = accuracy_score(test_labels, predictions)
    macro_f1 = f1_score(test_labels, predictions, average="macro")
    weighted_f1 = f1_score(test_labels, predictions, average="weighted")

    report = classification_report(test_labels, predictions, output_dict=True, zero_division=0)
    report_text = classification_report(test_labels, predictions, zero_division=0)

    print("\n=== TF-IDF + Logistic Regression Results ===")
    print(f"Accuracy: {accuracy:.4f}")
    print(f"Macro F1: {macro_f1:.4f}")
    print(f"Weighted F1: {weighted_f1:.4f}")
    print("\nPer-class report:")
    print(report_text)

    # Save results for downstream analysis scripts
    results = {
        "model": "TF-IDF + Logistic Regression",
        "accuracy": accuracy,
        "macro_f1": macro_f1,
        "weighted_f1": weighted_f1,
        "per_class_report": report,
        "predictions": list(predictions),
        "true_labels": test_labels,
    }

    out_path = os.path.join(RESULTS_DIR, "baseline_tfidf_results.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)

    print(f"\nResults saved to {out_path}")


if __name__ == "__main__":
    main()
'@ | Set-Content -Encoding utf8 (Join-Path $dir "baseline_tfidf.py")

@'
# baseline_zeroshot.py - zero-shot LLM prompting classifier (no training)
# Uses the SAME test split as baseline_tfidf.py for a fair comparison
# Run: python scripts/ml/baseline_zeroshot.py

import json
import os
import time
import requests
from sklearn.metrics import classification_report, accuracy_score, f1_score

BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPLITS_DIR = os.path.join(BASE_DIR, "data", "processed", "splits")
RESULTS_DIR = os.path.join(BASE_DIR, "data", "processed", "results")

GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions"
MODEL = "qwen/qwen3.8-27b"  # non-reasoning model - avoids gpt-oss hidden reasoning token issue
MIN_INTERVAL_SEC = 6
DEBUG_FIRST_N = 5  # print raw responses for the first N calls to sanity-check before committing

CATEGORIES = [
    "Ghosts and Spirits",
    "Legendary Creatures",
    "Deities and Mythological Figures",
    "Legendary and Historical Figures",
    "Place-Based Legends",
    "Fairy Tales and Fables",
    "Cultural Superstitions and Practices",
]

SYSTEM_PROMPT = f"""You are classifying short folklore text passages.
Classify the passage into EXACTLY ONE of these categories:
{chr(10).join('- ' + c for c in CATEGORIES)}

Respond with ONLY the category name, exactly as written above. No other text."""


def load_split(name):
    path = os.path.join(SPLITS_DIR, f"{name}.json")
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def classify(text, api_key, retries=4):
    # Call Groq, with backoff on rate limits and a few network retries
    for attempt in range(retries + 1):
        try:
            res = requests.post(
                GROQ_API_URL,
                headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                json={
                    "model": MODEL,
                    "temperature": 0.1,
                    "max_tokens": 60,
                    "messages": [
                        {"role": "system", "content": SYSTEM_PROMPT},
                        {"role": "user", "content": text[:1200]},
                    ],
                },
                timeout=30,
            )
        except requests.exceptions.RequestException as e:
            print(f"    network error ({e}), retrying...")
            time.sleep(3)
            continue

        if res.status_code == 429:
            wait = 5 * (2 ** attempt)
            print(f"    rate limited, waiting {wait}s...")
            time.sleep(wait)
            continue

        if not res.ok:
            raise RuntimeError(f"Groq error {res.status_code}: {res.text}")

        content = res.json()["choices"][0]["message"]["content"].strip()
        return content

    raise RuntimeError("too many retries")


def main():
    api_key = os.environ.get("GROQ_API_KEY")
    if not api_key:
        # Fallback: read from .env manually if not exported as an env var
        env_path = os.path.join(BASE_DIR, ".env")
        with open(env_path, "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("GROQ_API_KEY"):
                    api_key = line.split("=", 1)[1].strip().strip('"')
                    break

    if not api_key:
        print("GROQ_API_KEY not found - set it as an environment variable or check .env")
        return

    test_data = load_split("test")
    print(f"Classifying {len(test_data)} test examples with zero-shot prompting ({MODEL})...")

    predictions = []
    true_labels = []

    # Classify every test example one at a time (rate-limited)
    for i, item in enumerate(test_data):
        raw = classify(item["text"], api_key)

        # Match response to closest known category (models sometimes add punctuation/variation)
        matched = next((c for c in CATEGORIES if c.lower() in raw.lower()), raw)

        if i < DEBUG_FIRST_N:
            print(f"  [DEBUG] raw response: {raw!r} -> matched: {matched!r} (gold: {item['gold_category']!r})")

        predictions.append(matched)
        true_labels.append(item["gold_category"])

        if (i + 1) % 10 == 0:
            print(f"  {i + 1}/{len(test_data)}")

        time.sleep(MIN_INTERVAL_SEC)

    # Compute and report metrics
    accuracy = accuracy_score(true_labels, predictions)
    macro_f1 = f1_score(true_labels, predictions, average="macro")
    weighted_f1 = f1_score(true_labels, predictions, average="weighted")
    report = classification_report(true_labels, predictions, output_dict=True, zero_division=0)
    report_text = classification_report(true_labels, predictions, zero_division=0)

    print("\n=== Zero-Shot LLM Prompting Results ===")
    print(f"Accuracy: {accuracy:.4f}")
    print(f"Macro F1: {macro_f1:.4f}")
    print(f"Weighted F1: {weighted_f1:.4f}")
    print("\nPer-class report:")
    print(report_text)

    os.makedirs(RESULTS_DIR, exist_ok=True)
    results = {
        "model": f"Zero-shot prompting ({MODEL})",
        "accuracy": accuracy,
        "macro_f1": macro_f1,
        "weighted_f1": weighted_f1,
        "per_class_report": report,
        "predictions": predictions,
        "true_labels": true_labels,
    }
    out_path = os.path.join(RESULTS_DIR, "baseline_zeroshot_results.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)

    print(f"\nResults saved to {out_path}")


if __name__ == "__main__":
    main()
'@ | Set-Content -Encoding utf8 (Join-Path $dir "baseline_zeroshot.py")

@'
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
'@ | Set-Content -Encoding utf8 (Join-Path $dir "error_analysis.py")

@'
# extract_entities.py - pulls named entities (people/places/other) per article via spaCy,
# used by the "related legends" feature in the web app
# Run: python extract_entities.py

import json
import os
import spacy
from collections import Counter

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SERVER_DIR = os.path.dirname(os.path.dirname(SCRIPT_DIR))
CURATED_DIR = os.path.join(SERVER_DIR, "data", "curated")
OUTPUT_PATH = os.path.join(SERVER_DIR, "data", "processed", "entities.json")

COUNTRIES = ["japan", "china", "india", "philippines", "indonesia"]

LABEL_BUCKETS = {
    "PERSON": "people",
    "GPE": "places",
    "LOC": "places",
    "FAC": "places",
    "NORP": "other",
    "ORG": "other",
}

MAX_PER_BUCKET = 8
MIN_MENTIONS = 1
MIN_LENGTH = 3


def extract_entities(nlp, text):
    # Run NER and bucket the results into people/places/other
    doc = nlp(text[:100000])
    counts = {"people": Counter(), "places": Counter(), "other": Counter()}

    for ent in doc.ents:
        bucket = LABEL_BUCKETS.get(ent.label_)
        if not bucket:
            continue
        name = ent.text.strip()
        if len(name) < MIN_LENGTH or name.lower() in ("the", "a", "an"):
            continue
        counts[bucket][name] += 1

    # Keep only the top mentions per bucket
    result = {}
    for bucket, counter in counts.items():
        top = [name for name, n in counter.most_common(MAX_PER_BUCKET) if n >= MIN_MENTIONS]
        if top:
            result[bucket] = top
    return result


def main():
    print("Loading spaCy model (en_core_web_sm)...")
    nlp = spacy.load("en_core_web_sm", disable=["lemmatizer"])

    all_entities = {}
    total = 0

    # Process every curated article, country by country
    for country in COUNTRIES:
        path = os.path.join(CURATED_DIR, f"{country}.json")
        if not os.path.exists(path):
            print(f"Skipping {country} - no curated file found.")
            continue

        with open(path, "r", encoding="utf-8") as f:
            articles = json.load(f)

        print(f"Processing {len(articles)} articles for {country}...")
        for i, article in enumerate(articles):
            key = f"{country}/{article['title']}"
            all_entities[key] = extract_entities(nlp, article.get("text", ""))
            total += 1
            if (i + 1) % 100 == 0:
                print(f"  {country}: {i + 1}/{len(articles)}")

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(all_entities, f, ensure_ascii=False, indent=2)

    print(f"Saved entities for {total} articles to {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
'@ | Set-Content -Encoding utf8 (Join-Path $dir "extract_entities.py")

@'
# finetune_distilbert.py - fine-tunes DistilBERT as the primary classifier, evaluates
# on the held-out test set with the same metrics as the baselines for a fair comparison.
# Supports tagged runs (--tag) so different hyperparameter runs don't overwrite each other.
# Run: python scripts/ml/finetune_distilbert.py --tag run5 --epochs 10 --lr 2e-5

import argparse
import json
import os

import numpy as np
import torch
from torch.utils.data import Dataset
from transformers import (
    DistilBertTokenizerFast,
    DistilBertForSequenceClassification,
    Trainer,
    TrainingArguments,
    TrainerCallback,
)
from sklearn.metrics import classification_report, accuracy_score, f1_score

BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPLITS_DIR = os.path.join(BASE_DIR, "data", "processed", "splits")
RESULTS_DIR = os.path.join(BASE_DIR, "data", "processed", "results")
MODEL_OUT_BASE = os.path.join(BASE_DIR, "data", "processed", "distilbert_model")

MODEL_NAME = "distilbert-base-uncased"
BATCH_SIZE = 32

CATEGORIES = [
    "Ghosts and Spirits",
    "Legendary Creatures",
    "Deities and Mythological Figures",
    "Legendary and Historical Figures",
    "Place-Based Legends",
    "Fairy Tales and Fables",
    "Cultural Superstitions and Practices",
]
LABEL2ID = {c: i for i, c in enumerate(CATEGORIES)}
ID2LABEL = {i: c for i, c in enumerate(CATEGORIES)}


def parse_args():
    p = argparse.ArgumentParser(description="Fine-tune DistilBERT (supports multiple tagged runs).")
    p.add_argument("--epochs", type=int, default=10, help="Number of training epochs (default: 10, matches run1).")
    p.add_argument("--lr", type=float, default=2e-5, help="Learning rate (default: 2e-5, matches run1).")
    p.add_argument("--tag", type=str, default="run1", help="Suffix for output files/dirs, e.g. 'run2' (default: run1).")
    return p.parse_args()


def load_split(name):
    path = os.path.join(SPLITS_DIR, f"{name}.json")
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    texts = [item["text"] for item in data]
    labels = [LABEL2ID[item["gold_category"]] for item in data]
    return texts, labels


class FolkloreDataset(Dataset):
    def __init__(self, texts, labels, tokenizer, max_length=256):
        self.encodings = tokenizer(texts, truncation=True, padding=True, max_length=max_length)
        self.labels = labels

    def __len__(self):
        return len(self.labels)

    def __getitem__(self, idx):
        item = {k: torch.tensor(v[idx]) for k, v in self.encodings.items()}
        item["labels"] = torch.tensor(self.labels[idx])
        return item


class LossHistoryCallback(TrainerCallback):
    # Captures train/validation loss at each epoch for plotting the training curve
    def __init__(self):
        self.history = []

    def on_log(self, args, state, control, logs=None, **kwargs):
        if logs is None:
            return
        entry = {"epoch": state.epoch, "step": state.global_step}
        if "loss" in logs:
            entry["train_loss"] = logs["loss"]
        if "eval_loss" in logs:
            entry["eval_loss"] = logs["eval_loss"]
        self.history.append(entry)


def compute_metrics(eval_pred):
    logits, labels = eval_pred
    predictions = np.argmax(logits, axis=-1)
    accuracy = accuracy_score(labels, predictions)
    macro_f1 = f1_score(labels, predictions, average="macro")
    return {"accuracy": accuracy, "macro_f1": macro_f1}


def main():
    args = parse_args()
    num_epochs = args.epochs
    learning_rate = args.lr
    tag = args.tag

    model_out_dir = f"{MODEL_OUT_BASE}_{tag}"

    os.makedirs(RESULTS_DIR, exist_ok=True)

    print(f"=== Run tag: {tag} | epochs={num_epochs} | lr={learning_rate} ===")

    # Load the fixed train/val/test split
    print("Loading data...")
    train_texts, train_labels = load_split("train")
    val_texts, val_labels = load_split("val")
    test_texts, test_labels = load_split("test")
    print(f"Train: {len(train_texts)}, Val: {len(val_texts)}, Test: {len(test_texts)}")

    # Load tokenizer + model
    print(f"Loading tokenizer and model ({MODEL_NAME})...")
    tokenizer = DistilBertTokenizerFast.from_pretrained(MODEL_NAME)
    model = DistilBertForSequenceClassification.from_pretrained(
        MODEL_NAME, num_labels=len(CATEGORIES), id2label=ID2LABEL, label2id=LABEL2ID
    )

    train_dataset = FolkloreDataset(train_texts, train_labels, tokenizer)
    val_dataset = FolkloreDataset(val_texts, val_labels, tokenizer)
    test_dataset = FolkloreDataset(test_texts, test_labels, tokenizer)

    training_args = TrainingArguments(
        output_dir=os.path.join(model_out_dir, "checkpoints"),
        num_train_epochs=num_epochs,
        per_device_train_batch_size=BATCH_SIZE,
        per_device_eval_batch_size=BATCH_SIZE,
        learning_rate=learning_rate,
        eval_strategy="epoch",
        save_strategy="epoch",
        save_total_limit=1,
        logging_strategy="epoch",
        load_best_model_at_end=True,
        metric_for_best_model="eval_loss",
        seed=42,
        report_to="none",
    )

    loss_callback = LossHistoryCallback()

    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=train_dataset,
        eval_dataset=val_dataset,
        compute_metrics=compute_metrics,
        callbacks=[loss_callback],
    )

    # Train
    print(f"\nTraining for {num_epochs} epochs at lr={learning_rate}...")
    trainer.train()

    # Save training curve data
    curve_path = os.path.join(RESULTS_DIR, f"distilbert_training_curve_{tag}.json")
    with open(curve_path, "w", encoding="utf-8") as f:
        json.dump(loss_callback.history, f, indent=2)
    print(f"Training curve data saved to {curve_path}")

    # Evaluate on held-out test set
    print("\nEvaluating on test set...")
    predictions_output = trainer.predict(test_dataset)
    predictions = np.argmax(predictions_output.predictions, axis=-1)

    pred_labels = [ID2LABEL[p] for p in predictions]
    true_labels_text = [ID2LABEL[t] for t in test_labels]

    accuracy = accuracy_score(true_labels_text, pred_labels)
    macro_f1 = f1_score(true_labels_text, pred_labels, average="macro")
    weighted_f1 = f1_score(true_labels_text, pred_labels, average="weighted")
    report = classification_report(true_labels_text, pred_labels, output_dict=True, zero_division=0)
    report_text = classification_report(true_labels_text, pred_labels, zero_division=0)

    print(f"\n=== Fine-Tuned DistilBERT Results ({tag}) ===")
    print(f"Accuracy: {accuracy:.4f}")
    print(f"Macro F1: {macro_f1:.4f}")
    print(f"Weighted F1: {weighted_f1:.4f}")
    print("\nPer-class report:")
    print(report_text)

    # Save results and model
    results = {
        "model": f"Fine-tuned {MODEL_NAME} ({tag})",
        "hyperparameters": {"epochs": num_epochs, "learning_rate": learning_rate, "batch_size": BATCH_SIZE},
        "accuracy": accuracy,
        "macro_f1": macro_f1,
        "weighted_f1": weighted_f1,
        "per_class_report": report,
        "predictions": pred_labels,
        "true_labels": true_labels_text,
    }
    out_path = os.path.join(RESULTS_DIR, f"distilbert_results_{tag}.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)
    print(f"\nResults saved to {out_path}")

    model.save_pretrained(model_out_dir)
    tokenizer.save_pretrained(model_out_dir)
    print(f"Model saved to {model_out_dir}")


if __name__ == "__main__":
    main()
'@ | Set-Content -Encoding utf8 (Join-Path $dir "finetune_distilbert.py")

@'
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
'@ | Set-Content -Encoding utf8 (Join-Path $dir "inspect_insufficient.py")

@'
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
'@ | Set-Content -Encoding utf8 (Join-Path $dir "scenario_analysis.py")

@'
# split_data.py - fixed, seeded, stratified 70/15/15 train/val/test split by category
# Reused by every baseline and the fine-tuned classifier so comparisons are fair
# Run: python scripts/ml/split_data.py

import json
import os
import random
from collections import defaultdict

SEED = 42
TRAIN_FRAC = 0.70
VAL_FRAC = 0.15
# TEST_FRAC is the remainder (0.15)

BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INPUT_PATH = os.path.join(BASE_DIR, "data", "processed", "gold_labeled_dataset.json")
OUTPUT_DIR = os.path.join(BASE_DIR, "data", "processed", "splits")


def main():
    random.seed(SEED)

    with open(INPUT_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)

    print(f"Loaded {len(data)} gold-labeled examples")

    # Group by category for stratified sampling
    by_category = defaultdict(list)
    for item in data:
        by_category[item["gold_category"]].append(item)

    train, val, test = [], [], []

    print("\nPer-category split sizes:")
    for category, items in by_category.items():
        shuffled = items[:]
        random.shuffle(shuffled)

        n = len(shuffled)
        n_train = max(1, int(n * TRAIN_FRAC))
        n_val = max(1, int(n * VAL_FRAC)) if n >= 3 else 0

        cat_train = shuffled[:n_train]
        cat_val = shuffled[n_train:n_train + n_val]
        cat_test = shuffled[n_train + n_val:]

        # Guarantee at least one test example per category when possible
        if len(cat_test) == 0 and len(cat_val) > 1:
            cat_test.append(cat_val.pop())

        train.extend(cat_train)
        val.extend(cat_val)
        test.extend(cat_test)

        print(f"  {category}: total={n}, train={len(cat_train)}, val={len(cat_val)}, test={len(cat_test)}")

    random.shuffle(train)
    random.shuffle(val)
    random.shuffle(test)

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Write each split to its own file
    for name, split in [("train", train), ("val", val), ("test", test)]:
        path = os.path.join(OUTPUT_DIR, f"{name}.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(split, f, indent=2, ensure_ascii=False)

    print(f"\nTotal: train={len(train)}, val={len(val)}, test={len(test)}")
    print(f"Saved splits to {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
'@ | Set-Content -Encoding utf8 (Join-Path $dir "split_data.py")

Write-Output "All 9 files written to $dir"