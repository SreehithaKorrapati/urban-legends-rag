// buildRagIndex.js - builds the retrieval index for the RAG extension, across the full
// 769-article 5-country corpus (not the 1099-chunk stratified sample used for classification)
// Resumable (saves progress every SAVE_EVERY chunks) and batches embedding calls for speed
// Run: node scripts/buildRagIndex.js

const fs = require('fs');
const path = require('path');
const { pipeline } = require('@xenova/transformers');

const COUNTRIES = ['japan', 'china', 'india', 'philippines', 'indonesia'];
const CURATED_DIR = path.join(__dirname, '..', 'data', 'curated');
const OUTPUT_DIR = path.join(__dirname, '..', 'data', 'processed');
const OUTPUT_PATH = path.join(OUTPUT_DIR, 'rag_index.json');

const CHUNK_WORD_TARGET = 250;
const MIN_TEXT_WORDS = 5;
const BATCH_SIZE = 16;
const SAVE_EVERY = 100; // chunks, not batches

const EMBEDDING_MODEL = 'Xenova/bge-small-en-v1.5';

function chunkText(text) {
  const paragraphs = text
    .split(/\n+/)
    .map((p) => p.trim())
    .filter((p) => p.length > 0);

  if (paragraphs.length === 0) return [];

  const chunks = [];
  let current = [];
  let currentWordCount = 0;

  for (const para of paragraphs) {
    const paraWordCount = para.split(/\s+/).length;

    if (currentWordCount + paraWordCount > CHUNK_WORD_TARGET && current.length > 0) {
      chunks.push(current.join('\n'));
      current = [];
      currentWordCount = 0;
    }

    current.push(para);
    currentWordCount += paraWordCount;
  }

  if (current.length > 0) {
    chunks.push(current.join('\n'));
  }

  if (chunks.length > 1) {
    const lastWordCount = chunks[chunks.length - 1].split(/\s+/).length;
    if (lastWordCount < MIN_TEXT_WORDS) {
      const last = chunks.pop();
      chunks[chunks.length - 1] += '\n' + last;
    }
  }

  return chunks;
}

function buildAllChunks() {
  const allChunks = [];
  for (const country of COUNTRIES) {
    const curatedPath = path.join(CURATED_DIR, `${country}.json`);
    if (!fs.existsSync(curatedPath)) {
      console.warn(`Skipping ${country}: no curated file found at ${curatedPath}`);
      continue;
    }

    const articles = JSON.parse(fs.readFileSync(curatedPath, 'utf-8'));
    let countryChunkCount = 0;

    for (const article of articles) {
      const pieces = chunkText(article.text || '');
      pieces.forEach((chunk, idx) => {
        allChunks.push({
          id: `${country}_${allChunks.length}`,
          country,
          article_title: article.title,
          article_url: article.url,
          image_url: article.image_url || null,
          chunk_index: idx,
          text: chunk,
        });
        countryChunkCount++;
      });
    }

    console.log(`${country}: ${articles.length} articles -> ${countryChunkCount} chunks`);
  }
  return allChunks;
}

function loadExistingProgress() {
  if (!fs.existsSync(OUTPUT_PATH)) return new Map();
  try {
    const existing = JSON.parse(fs.readFileSync(OUTPUT_PATH, 'utf-8'));
    const byId = new Map(existing.map((c) => [c.id, c]));
    console.log(`Resuming: found ${byId.size} already-embedded chunks in ${OUTPUT_PATH}`);
    return byId;
  } catch (e) {
    console.warn(`Could not parse existing ${OUTPUT_PATH} (${e.message}) - starting fresh.`);
    return new Map();
  }
}

function saveProgress(doneMap) {
  const arr = Array.from(doneMap.values());
  fs.writeFileSync(OUTPUT_PATH, JSON.stringify(arr), 'utf-8');
}

async function embedBatch(extractor, texts) {
  const output = await extractor(texts, { pooling: 'mean', normalize: true });
  // output.dims = [batchSize, hiddenSize]; output.data is a flat Float32Array
  const hiddenSize = output.dims[output.dims.length - 1];
  const vectors = [];
  for (let i = 0; i < texts.length; i++) {
    vectors.push(Array.from(output.data.slice(i * hiddenSize, (i + 1) * hiddenSize)));
  }
  return vectors;
}

async function main() {
  if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  }

  const allChunks = buildAllChunks();
  console.log(`\nTotal chunks (full corpus): ${allChunks.length}`);

  const done = loadExistingProgress();
  const remaining = allChunks.filter((c) => !done.has(c.id));
  console.log(`Remaining to embed: ${remaining.length}\n`);

  if (remaining.length === 0) {
    console.log('Nothing left to do - index is already complete.');
    return;
  }

  console.log(`Loading embedding model: ${EMBEDDING_MODEL} ...`);
  const extractor = await pipeline('feature-extraction', EMBEDDING_MODEL);

  const startTime = Date.now();
  let embeddedSinceLastSave = 0;
  let totalDoneSoFar = done.size;

  // Embed in batches, checkpointing progress along the way
  for (let i = 0; i < remaining.length; i += BATCH_SIZE) {
    const batch = remaining.slice(i, i + BATCH_SIZE);
    const texts = batch.map((c) => c.text);
    const vectors = await embedBatch(extractor, texts);

    batch.forEach((chunk, j) => {
      done.set(chunk.id, { ...chunk, embedding: vectors[j] });
    });

    totalDoneSoFar += batch.length;
    embeddedSinceLastSave += batch.length;

    if (embeddedSinceLastSave >= SAVE_EVERY || i + BATCH_SIZE >= remaining.length) {
      saveProgress(done);
      embeddedSinceLastSave = 0;
      const elapsedMin = (Date.now() - startTime) / 60000;
      const rate = (totalDoneSoFar - (allChunks.length - remaining.length)) / Math.max(elapsedMin, 0.01);
      const remainingCount = allChunks.length - totalDoneSoFar;
      const etaMin = rate > 0 ? (remainingCount / rate).toFixed(1) : '?';
      console.log(
        `  saved checkpoint: ${totalDoneSoFar}/${allChunks.length} ` +
        `(${rate.toFixed(1)} chunks/min, ~${etaMin} min remaining)`
      );
    }
  }

  console.log(`\nDone. Saved ${done.size} embedded chunks to ${OUTPUT_PATH}`);
  console.log(`Embedding model used: ${EMBEDDING_MODEL} (record this for the report's RAG methodology section)`);
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
