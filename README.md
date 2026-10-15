# Urban Legends RAG — Southeast & East Asian Folklore Archive

NLP course project (CS7347) — Mini Hands-On Exercise 1, Option B.

Two parts:
1. **Text classification**: a curated, LLM-ensemble-annotated dataset of folklore
   legends from Japan, China, India, the Philippines, and Indonesia, with a
   fine-tuned DistilBERT classifier compared against a TF-IDF baseline and a
   zero-shot LLM baseline.
2. **RAG extension**: a retrieval-augmented chat/search system over the same
   corpus, delivered as a MERN web app ("World Folklore Archive").

## Repo structures

## Setup

Requires Node.js 18+, Python 3.10+, and a MongoDB Atlas connection string.

```powershell
# Backend
cd server
npm install
pip install -r requirements.txt   # if present; otherwise see scripts/ml for the packages used
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
