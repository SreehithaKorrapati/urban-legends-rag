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
