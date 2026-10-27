# finetune_distilbert.py - fine-tunes DistilBERT as the primary classifier, evaluates
# on the held-out test set with the same metrics as the baselines for a fair comparison.
# Supports tagged runs (--tag) so different runs don't overwrite each other.
# Defaults reproduce the reported run5 setup (no class weights, no oversampling, seed 42).
#
# Examples (run from the repository root):
#   python server/scripts/ml/finetune_distilbert.py --tag run5 --epochs 10 --lr 2e-5
#   python server/scripts/ml/finetune_distilbert.py --tag run6 --class-weights sqrt
#   python server/scripts/ml/finetune_distilbert.py --tag run7 --oversample 100
#   python server/scripts/ml/finetune_distilbert.py --tag smoke --limit 64 --epochs 1   (quick check)

import argparse
import json
import os
import random
from collections import Counter

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
    p.add_argument("--epochs", type=int, default=10, help="Number of training epochs (default: 10).")
    p.add_argument("--lr", type=float, default=2e-5, help="Learning rate (default: 2e-5).")
    p.add_argument("--tag", type=str, default="run1", help="Suffix for output files/dirs, e.g. 'run6'.")
    p.add_argument("--seed", type=int, default=42, help="Training seed (initialisation and data order). The data split stays fixed.")
    p.add_argument("--class-weights", choices=["none", "sqrt", "balanced"], default="none",
                   help="Weight the loss by class frequency. 'balanced' = N/(K*n_c); 'sqrt' = its square root (gentler).")
    p.add_argument("--oversample", type=int, default=0,
                   help="If > 0, repeat random training passages of rare classes until each class has this many.")
    p.add_argument("--limit", type=int, default=0,
                   help="If > 0, use only this many examples per split (quick smoke test; do not report these results).")
    return p.parse_args()


def load_split(name):
    path = os.path.join(SPLITS_DIR, f"{name}.json")
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    texts = [item["text"] for item in data]
    labels = [LABEL2ID[item["gold_category"]] for item in data]
    return texts, labels


def limit_split(texts, labels, n, seed):
    if n <= 0 or n >= len(texts):
        return texts, labels
    idx = random.Random(seed).sample(range(len(texts)), n)
    return [texts[i] for i in idx], [labels[i] for i in idx]


def oversample(texts, labels, target, seed):
    # Repeats randomly chosen passages of classes below `target` until they reach it.
    # Only the training split is touched; validation and test stay as they are.
    rng = random.Random(seed)
    by_class = {}
    for i, y in enumerate(labels):
        by_class.setdefault(y, []).append(i)
    new_texts, new_labels = list(texts), list(labels)
    for y, idxs in by_class.items():
        for _ in range(max(0, target - len(idxs))):
            i = rng.choice(idxs)
            new_texts.append(texts[i])
            new_labels.append(y)
    return new_texts, new_labels


def compute_class_weights(labels, mode):
    counts = Counter(labels)
    n, k = len(labels), len(CATEGORIES)
    w = []
    for c in range(k):
        base = n / (k * counts[c]) if counts[c] else 0.0
        w.append(base ** 0.5 if mode == "sqrt" else base)
    return torch.tensor(w, dtype=torch.float)


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


class WeightedTrainer(Trainer):
    # Same as Trainer, but the cross-entropy loss is weighted per class.
    def __init__(self, *args, class_weights=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.class_weights = class_weights

    def compute_loss(self, model, inputs, return_outputs=False, num_items_in_batch=None):
        labels = inputs["labels"]
        model_inputs = {k: v for k, v in inputs.items() if k != "labels"}
        outputs = model(**model_inputs)
        logits = outputs.logits
        weight = self.class_weights.to(logits.device) if self.class_weights is not None else None
        loss = torch.nn.functional.cross_entropy(logits, labels, weight=weight)
        return (loss, outputs) if return_outputs else loss


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

    print(f"=== Run tag: {tag} | epochs={num_epochs} | lr={learning_rate} | seed={args.seed} "
          f"| class_weights={args.class_weights} | oversample={args.oversample} ===")

    # Load the fixed train/val/test split
    print("Loading data...")
    train_texts, train_labels = load_split("train")
    val_texts, val_labels = load_split("val")
    test_texts, test_labels = load_split("test")
    if args.limit > 0:
        print(f"WARNING: --limit {args.limit} is set. This is a smoke test, not a reportable run.")
        train_texts, train_labels = limit_split(train_texts, train_labels, args.limit, args.seed)
        val_texts, val_labels = limit_split(val_texts, val_labels, args.limit, args.seed)
        test_texts, test_labels = limit_split(test_texts, test_labels, args.limit, args.seed)
    if args.oversample > 0:
        before = Counter(train_labels)
        train_texts, train_labels = oversample(train_texts, train_labels, args.oversample, args.seed)
        after = Counter(train_labels)
        print("Training passages per class (before -> after oversampling):")
        for c in range(len(CATEGORIES)):
            print(f"  {ID2LABEL[c]:<40}{before[c]:>5} -> {after[c]:>5}")
    print(f"Train: {len(train_texts)}, Val: {len(val_texts)}, Test: {len(test_texts)}")

    class_weights = None
    if args.class_weights != "none":
        class_weights = compute_class_weights(train_labels, args.class_weights)
        print("Class weights:")
        for c in range(len(CATEGORIES)):
            print(f"  {ID2LABEL[c]:<40}{class_weights[c].item():.3f}")

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
        seed=args.seed,
        report_to="none",
    )

    loss_callback = LossHistoryCallback()

    trainer_kwargs = dict(
        model=model,
        args=training_args,
        train_dataset=train_dataset,
        eval_dataset=val_dataset,
        compute_metrics=compute_metrics,
        callbacks=[loss_callback],
    )
    if class_weights is not None:
        trainer = WeightedTrainer(class_weights=class_weights, **trainer_kwargs)
    else:
        trainer = Trainer(**trainer_kwargs)

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
        "hyperparameters": {
            "epochs": num_epochs,
            "learning_rate": learning_rate,
            "batch_size": BATCH_SIZE,
            "seed": args.seed,
            "class_weights": args.class_weights,
            "oversample_target": args.oversample,
        },
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
