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
