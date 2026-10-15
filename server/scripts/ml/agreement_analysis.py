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
