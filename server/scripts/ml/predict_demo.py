# Classify passages with the fine-tuned DistilBERT (run5) model.
import os, sys, glob, json
import torch
from transformers import AutoTokenizer, AutoModelForSequenceClassification

HERE = os.path.dirname(os.path.abspath(__file__))
PROC = os.path.join(HERE, "..", "..", "data", "processed")
MODEL_ROOT = os.path.join(PROC, "distilbert_model_run5")

def find_model_dir():
    # Pick a folder holding config.json and the weights (final model first, checkpoint second)
    for cfg in [os.path.join(MODEL_ROOT, "config.json")] + sorted(glob.glob(os.path.join(MODEL_ROOT, "**", "config.json"), recursive=True)):
        d = os.path.dirname(cfg)
        if os.path.exists(os.path.join(d, "model.safetensors")) or os.path.exists(os.path.join(d, "pytorch_model.bin")):
            return d
    sys.exit("No model weights found under " + MODEL_ROOT)

def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)

model_dir = find_model_dir()
tok = AutoTokenizer.from_pretrained(model_dir)
model = AutoModelForSequenceClassification.from_pretrained(model_dir)
model.eval()

# Label order: use real names from the config, else the sorted category names used in training
train = load_json(os.path.join(PROC, "splits", "train.json"))
cats = sorted({x["gold_category"] for x in train})
names = list(model.config.id2label.values())
labels = names if all(n in cats for n in names) else cats

def predict(text):
    # Tokenize at the training length (256) and return the label ranking
    enc = tok(text, truncation=True, max_length=256, return_tensors="pt")
    with torch.no_grad():
        probs = torch.softmax(model(**enc).logits, dim=-1)[0]
    order = torch.argsort(probs, descending=True)
    return [(labels[i], float(probs[i])) for i in order]

def show(title, text, true=None):
    # Print the top 3 categories for one passage
    print(title)
    print(text[:300].replace("\n", " ") + ("..." if len(text) > 300 else ""))
    if true:
        print("TRUE LABEL :", true)
    for name, p in predict(text)[:3]:
        print("  %-40s %.1f%%" % (name, 100 * p))

if len(sys.argv) > 1 and sys.argv[1] != "--demo":
    show("New passage", " ".join(sys.argv[1:]))
else:
    test = load_json(os.path.join(PROC, "splits", "test.json"))
    results = [(x, predict(x["text"])[0][0]) for x in test]
    acc = sum(p == x["gold_category"] for x, p in results) / len(results)
    print("Test accuracy over %d passages: %.1f%% (report: 67.8%%)" % (len(results), 100 * acc))
    right = [(x, p) for x, p in results if p == x["gold_category"]][:2]
    wrong = [(x, p) for x, p in results if x["gold_category"] == "Place-Based Legends"][:1]
    for x, p in right:
        show("CORRECT: " + x["article_title"], x["text"], x["gold_category"])
    for x, p in wrong:
        show("FAILURE (Place-Based Legends): " + x["article_title"], x["text"], x["gold_category"])
