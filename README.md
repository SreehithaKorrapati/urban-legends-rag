# Urban Legends RAG — Southeast & East Asian Folklore Archive

NLP course project (CS7347) — Mini Hands-On Exercise 1, Option B.

Two parts:
1. **Text classification**: a curated, LLM-ensemble-annotated dataset of folklore
   legends from Japan, China, India, the Philippines, and Indonesia, with a
   fine-tuned DistilBERT classifier compared against a TF-IDF baseline and a
   zero-shot LLM baseline.
2. **RAG extension**: a retrieval-augmented chat/search system over the same
   corpus, delivered as a MERN web app ("World Folklore Archive").

## Repository structure

- `client/` : React front end of the web app
- `server/` : Express back end and data
- `server/scripts/ml/` : classification scripts (split, baselines, DistilBERT, analysis, demo)
- `server/data/processed/` : gold labels, train/validation/test splits, and saved results
- `requirements.txt` : Python packages for the classification scripts

## Setup

Requires Node.js 24 and Python 3.14 (the versions used for development), and a MongoDB Atlas connection string.

```powershell
# Backend
cd server
npm install
pip install -r ../requirements.txt   # Python packages for scripts/ml
copy .env.example .env            # then fill in MONGODB_URI and GROQ_API_KEY

# Frontend
cd ../client
npm install
```

## Running the app

Two terminals, both from the project root:

```powershell
# Terminal 1 — backend API (port 5000)
cd server
node index.js

# Terminal 2 — frontend (port 5173)
cd client
npm run dev
```

Open `http://localhost:5173`.

## Reproducing the pipeline

All data in `server/data/` is already included, so the app runs out of the box
without re-running any of this. These are the scripts that produced it, run
from `server/`, in order:

**Data collection & corpus curation**
```powershell
node scripts/fetchWikipedia.js
node scripts/cleanupCorpus.js
node scripts/curateCorpus.js
```

**LLM-ensemble annotation**
```powershell
node scripts/chunkForAnnotation.js
node scripts/annotateWithLLMs.js
node scripts/Reconcileannotations.js
node scripts/repairAnnotations.js
```

**Classification (Python, from `server/scripts/ml/`)**
```powershell
python split_data.py
python baseline_tfidf.py
python baseline_zeroshot.py
python finetune_distilbert.py
python error_analysis.py
python scenario_analysis.py
python agreement_analysis.py
python extract_entities.py
```

**RAG index + evaluation**
```powershell
node scripts/buildRagIndex.js
node scripts/computeRelatedEmbeddings.js
node scripts/embedCorpus.js
node scripts/buildEvalSet.js
node scripts/ragEval.js
```

## Results

See `server/data/processed/results/` for raw metric outputs, and
`report/` for the full written analysis (dataset statistics, model
comparison, confusion matrix, error analysis, RAG evaluation metrics).

## Reproducing the classification results (MHE 1)

Tested on Windows with Python 3.14.5 (torch 2.14.1, transformers 5.20.2, scikit-learn 1.9.1, numpy 2.5.4).
Run everything from the repository root.

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

Steps 1 to 5 need no API key and no GPU. They read the saved result files in `server/data/processed/`.

1. `python server\scripts\ml\split_data.py` : stratified split with seed 42 (767 train, 161 validation, 171 test)
2. `python server\scripts\ml\baseline_tfidf.py` : expected accuracy 0.6491, macro F1 0.5544
3. `python server\scripts\ml\error_analysis.py` : error analysis for DistilBERT run 5 (55 of 171 errors)
4. `python server\scripts\ml\scenario_analysis.py` : per-country results for the three methods
5. `python server\scripts\ml\agreement_analysis.py` : Fleiss kappa 0.5845 for the LLM annotations

Optional steps:

- `baseline_zeroshot.py` calls the Groq API and needs `GROQ_API_KEY` (set it as an environment variable or in `server/.env`; see `server/.env.example`). Saved output: `baseline_zeroshot_results.json` (accuracy 0.8187, macro F1 0.8141).
- `finetune_distilbert.py` retrains DistilBERT (10 epochs, CPU only, slow). Saved output for the reported model: `distilbert_results_run5.json`.
- `predict_demo.py` needs the trained weights, which are not stored in git. Download them once:

```powershell
Invoke-WebRequest -Uri https://github.com/sreehithakorrapati/urban-legends-rag/releases/download/weights-run5/model.safetensors -OutFile server\data\processed\distilbert_model_run5\model.safetensors
python server\scripts\ml\predict_demo.py --demo
python server\scripts\ml\predict_demo.py "text of a folklore passage to classify"
```

## Reproducing the classification results (MHE 1)

Tested on Windows with Python 3.14.5 (torch 2.14.1, transformers 5.20.2, scikit-learn 1.9.1, numpy 2.5.4).
Run everything from the repository root.

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

Steps 1 to 5 need no API key and no GPU. They read the saved result files in `server/data/processed/`.

1. `python server\scripts\ml\split_data.py` : stratified split with seed 42 (767 train, 161 validation, 171 test)
2. `python server\scripts\ml\baseline_tfidf.py` : expected accuracy 0.6491, macro F1 0.5544
3. `python server\scripts\ml\error_analysis.py` : error analysis for DistilBERT run 5 (55 of 171 errors)
4. `python server\scripts\ml\scenario_analysis.py` : per-country results for the three methods
5. `python server\scripts\ml\agreement_analysis.py` : Fleiss kappa 0.5845 for the LLM annotations

Optional steps:

- `baseline_zeroshot.py` calls the Groq API and needs `GROQ_API_KEY` (set it as an environment variable or in `server/.env`; see `server/.env.example`). Saved output: `baseline_zeroshot_results.json` (accuracy 0.8187, macro F1 0.8141).
- `finetune_distilbert.py` retrains DistilBERT (10 epochs, CPU only, slow). Saved output for the reported model: `distilbert_results_run5.json`.
- `predict_demo.py` needs the trained weights, which are not stored in git. Download them once:

```powershell
Invoke-WebRequest -Uri https://github.com/sreehithakorrapati/urban-legends-rag/releases/download/weights-run5/model.safetensors -OutFile server\data\processed\distilbert_model_run5\model.safetensors
python server\scripts\ml\predict_demo.py --demo
python server\scripts\ml\predict_demo.py "text of a folklore passage to classify"
```