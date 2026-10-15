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
