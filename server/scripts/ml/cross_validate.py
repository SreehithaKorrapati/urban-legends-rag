# cross_validate.py - stratified k-fold cross-validation over all 1,099 passages, so every passage
# (including all 26 Place-Based Legends passages) is predicted exactly once by a model that never saw it.
# Saves after every fold and can resume if interrupted (run the same command again).
#
# Examples (run from the repository root):
#   python server/scripts/ml/cross_validate.py --method tfidf_check          (checks the TF-IDF settings, seconds)
#   python server/scripts/ml/cross_validate.py --method tfidf --folds 3
#   python server/scripts/ml/cross_validate.py --method distilbert --folds 3 --epochs 6 --tag cv3_base
#   python server/scripts/ml/cross_validate.py --method distilbert --folds 3 --epochs 6 --oversample 100 --tag cv3_over
#
# Protocol note: there is no separate validation set in the folds, so no checkpoint selection is used.
# DistilBERT is trained for a fixed number of epochs on the other folds. This differs from the main
# experiments (which keep the lowest-validation-loss checkpoint), and the report says so.

import argparse
import json
import os
import gc
import tempfile

import numpy as np

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


def run_tfidf(train_t, train_y, test_t, seed):
    from sklearn.feature_extraction.text import TfidfVectorizer
    from sklearn.linear_model import LogisticRegression
    vec = TfidfVectorizer(ngram_range=(1, 2), max_features=5000, stop_words="english")
    xtr = vec.fit_transform(train_t)
    xte = vec.transform(test_t)
    clf = LogisticRegression(max_iter=1000, class_weight="balanced", random_state=seed)
    clf.fit(xtr, train_y)
    return list(clf.predict(xte))


def run_distilbert(train_t, train_y, test_t, test_y, args, seed):
    import torch
    from transformers import (DistilBertTokenizerFast, DistilBertForSequenceClassification,
                              Trainer, TrainingArguments)
    import finetune_distilbert as ft

    tr_ids = [ft.LABEL2ID[y] for y in train_y]
    te_ids = [ft.LABEL2ID[y] for y in test_y]
    if args.oversample > 0:
        train_t, tr_ids = ft.oversample(train_t, tr_ids, args.oversample, seed)
    weights = None
    if args.class_weights != "none":
        weights = ft.compute_class_weights(tr_ids, args.class_weights)

    tok = DistilBertTokenizerFast.from_pretrained(ft.MODEL_NAME)
    model = DistilBertForSequenceClassification.from_pretrained(
        ft.MODEL_NAME, num_labels=len(ft.CATEGORIES), id2label=ft.ID2LABEL, label2id=ft.LABEL2ID)
    train_ds = ft.FolkloreDataset(train_t, tr_ids, tok)
    test_ds = ft.FolkloreDataset(test_t, te_ids, tok)

    with tempfile.TemporaryDirectory() as tmp:
        targs = TrainingArguments(
            output_dir=tmp, num_train_epochs=args.epochs,
            per_device_train_batch_size=ft.BATCH_SIZE, per_device_eval_batch_size=ft.BATCH_SIZE,
            learning_rate=args.lr, eval_strategy="no", save_strategy="no",
            logging_strategy="epoch", seed=seed, report_to="none")
        kwargs = dict(model=model, args=targs, train_dataset=train_ds)
        trainer = ft.WeightedTrainer(class_weights=weights, **kwargs) if weights is not None else Trainer(**kwargs)
        trainer.train()
        logits = trainer.predict(test_ds).predictions
    preds = [ft.ID2LABEL[int(i)] for i in np.argmax(logits, axis=-1)]
    del trainer, model
    gc.collect()
    return preds


def summarize(records, folds_done, k):
    from sklearn.metrics import accuracy_score, f1_score, classification_report
    idx, pred = [], []
    per_fold = []
    for fi in sorted(folds_done, key=int):
        fd = folds_done[fi]
        idx += fd["indices"]
        pred += fd["predictions"]
        per_fold.append((fd["accuracy"], fd["macro_f1"]))
    true = [records[i]["gold_category"] for i in idx]
    out = {
        "folds_completed": len(folds_done), "folds_total": k, "passages_predicted": len(idx),
        "pooled_accuracy": accuracy_score(true, pred),
        "pooled_macro_f1": f1_score(true, pred, average="macro"),
        "per_fold_accuracy_mean": float(np.mean([a for a, _ in per_fold])),
        "per_fold_macro_f1_mean": float(np.mean([m for _, m in per_fold])),
        "per_fold_macro_f1_sd": float(np.std([m for _, m in per_fold], ddof=1)) if len(per_fold) > 1 else None,
        "per_class": classification_report(true, pred, output_dict=True, zero_division=0),
    }
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--method", choices=["tfidf", "tfidf_check", "distilbert"], required=True)
    ap.add_argument("--folds", type=int, default=3)
    ap.add_argument("--epochs", type=int, default=6)
    ap.add_argument("--lr", type=float, default=2e-5)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--oversample", type=int, default=0)
    ap.add_argument("--class-weights", choices=["none", "sqrt", "balanced"], default="none")
    ap.add_argument("--gold", default="gold_labeled_dataset.json", help="Gold file under data/processed (e.g. the relabeled one).")
    ap.add_argument("--limit", type=int, default=0, help="Smoke test only: keep about this many passages (balanced per category).")
    ap.add_argument("--tag", default=None)
    args = ap.parse_args()

    if args.method == "tfidf_check":
        from sklearn.metrics import accuracy_score, f1_score
        tr = load_json(os.path.join(PROCESSED_DIR, "splits", "train.json"))
        te = load_json(os.path.join(PROCESSED_DIR, "splits", "test.json"))
        pred = run_tfidf([r["text"] for r in tr], [r["gold_category"] for r in tr], [r["text"] for r in te], args.seed)
        y = [r["gold_category"] for r in te]
        print(f"TF-IDF check on the original split: accuracy {accuracy_score(y, pred):.4f}, macro F1 {f1_score(y, pred, average='macro'):.4f}")
        print("Reported values: accuracy 0.6491, macro F1 0.5544. If these match, the settings here equal the reported baseline.")
        return

    from sklearn.model_selection import StratifiedKFold
    records = load_json(os.path.join(PROCESSED_DIR, args.gold))
    if args.limit > 0:
        import random
        rng = random.Random(args.seed)
        per = max(args.folds, args.limit // len(CATEGORIES))
        keep = []
        for c in CATEGORIES:
            idxs = [i for i, r in enumerate(records) if r["gold_category"] == c]
            keep += rng.sample(idxs, min(per, len(idxs)))
        records = [records[i] for i in sorted(keep)]
        print(f"WARNING: --limit set. Using {len(records)} passages. Smoke test only; do not report these results.")
    labels = [r["gold_category"] for r in records]
    skf = StratifiedKFold(n_splits=args.folds, shuffle=True, random_state=args.seed)
    folds = list(skf.split(np.zeros(len(labels)), labels))

    tag = args.tag or f"{args.method}_{args.folds}fold"
    out_path = os.path.join(RESULTS_DIR, f"cv_{tag}.json")
    config = {"method": args.method, "folds": args.folds, "epochs": args.epochs, "lr": args.lr, "seed": args.seed,
              "oversample": args.oversample, "class_weights": args.class_weights, "gold": args.gold, "limit": args.limit}
    state = {"config": config, "folds": {}}
    if os.path.exists(out_path):
        old = load_json(out_path)
        if old.get("config") == config:
            state = old
            print(f"Resuming: folds already done: {sorted(state['folds'].keys(), key=int)}")
        else:
            print(f"WARNING: {out_path} exists with a different configuration. Choose another --tag.")
            return

    os.makedirs(RESULTS_DIR, exist_ok=True)
    from sklearn.metrics import accuracy_score, f1_score
    for fi, (tr_idx, te_idx) in enumerate(folds):
        if str(fi) in state["folds"]:
            continue
        print(f"\n=== Fold {fi + 1} of {args.folds}: train {len(tr_idx)}, test {len(te_idx)} ({args.method}) ===", flush=True)
        tr_t = [records[i]["text"] for i in tr_idx]
        tr_y = [labels[i] for i in tr_idx]
        te_t = [records[i]["text"] for i in te_idx]
        te_y = [labels[i] for i in te_idx]
        if args.method == "tfidf":
            pred = run_tfidf(tr_t, tr_y, te_t, args.seed)
        else:
            pred = run_distilbert(tr_t, tr_y, te_t, te_y, args, args.seed)
        acc = accuracy_score(te_y, pred)
        mf1 = f1_score(te_y, pred, average="macro")
        pb_true = [i for i, y in enumerate(te_y) if y == "Place-Based Legends"]
        pb_found = sum(1 for i in pb_true if pred[i] == "Place-Based Legends")
        print(f"Fold {fi + 1}: accuracy {acc:.4f}, macro F1 {mf1:.4f}, Place-Based found {pb_found} of {len(pb_true)}", flush=True)
        state["folds"][str(fi)] = {"indices": [int(i) for i in te_idx], "predictions": pred, "accuracy": acc,
                                   "macro_f1": mf1, "place_based_found": pb_found, "place_based_total": len(pb_true)}
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2, ensure_ascii=False)

    summ = summarize(records, state["folds"], args.folds)
    state["summary"] = summ
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
    print(f"\n=== Cross-validation summary ({tag}) ===")
    print(f"Pooled over {summ['passages_predicted']} passages: accuracy {summ['pooled_accuracy']:.4f}, macro F1 {summ['pooled_macro_f1']:.4f}")
    sd = summ["per_fold_macro_f1_sd"]
    print(f"Per-fold macro F1: mean {summ['per_fold_macro_f1_mean']:.4f}" + (f", sd {sd:.4f}" if sd is not None else ""))
    print(f"{'Category':<40}{'precision':>10}{'recall':>8}{'F1':>8}{'support':>9}")
    for c in CATEGORIES:
        r = summ["per_class"].get(c)
        if r:
            print(f"{c:<40}{r['precision']:>10.3f}{r['recall']:>8.3f}{r['f1-score']:>8.3f}{int(r['support']):>9}")
    print(f"\nSaved to {out_path}")


if __name__ == "__main__":
    main()
