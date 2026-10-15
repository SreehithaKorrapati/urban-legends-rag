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
