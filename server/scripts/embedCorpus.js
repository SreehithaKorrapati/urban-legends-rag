// embedCorpus.js - chunks curated legends into passages and embeds every chunk with 3
// different models (for the embedding-model comparison study)
// Run: node scripts/embedCorpus.js

const fs = require('fs');
const path = require('path');
const { pipeline } = require('@xenova/transformers');

const CURATED_PATH = path.join(__dirname, '..', 'data', 'curated', 'indonesia.json');
const OUTPUT_DIR = path.join(__dirname, '..', 'data', 'processed');
const OUTPUT_PATH = path.join(OUTPUT_DIR, 'chunks_with_embeddings.json');

const CHUNK_WORD_TARGET = 250; // ~200-300 words per chunk
const MIN_TEXT_WORDS = 5; // only skip an article if it's essentially empty

const MODELS = [
  { key: 'minilm', name: 'Xenova/all-MiniLM-L6-v2' },
  { key: 'e5', name: 'Xenova/multilingual-e5-small' },
  { key: 'bge', name: 'Xenova/bge-small-en-v1.5' },
];

// Split article text into ~250-word chunks on paragraph boundaries. Every non-empty
// article keeps at least one chunk, however short.
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

  // Fold a tiny trailing chunk into the previous one rather than leaving an orphan
  if (chunks.length > 1) {
    const lastWordCount = chunks[chunks.length - 1].split(/\s+/).length;
    if (lastWordCount < MIN_TEXT_WORDS) {
      const last = chunks.pop();
      chunks[chunks.length - 1] += '\n' + last;
    }
  }

  return chunks;
}

// Cosine-similarity-ready embeddings: mean-pooled, L2-normalized
async function embedText(extractor, text) {
  const output = await extractor(text, { pooling: 'mean', normalize: true });
  return Array.from(output.data);
}

async function main() {
  if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  }

  const legends = JSON.parse(fs.readFileSync(CURATED_PATH, 'utf-8'));
  console.log(`Loaded ${legends.length} legends`);

  // Step 1: chunk everything first (cheap, do it once)
  const allChunks = [];
  let emptyCount = 0;
  for (const legend of legends) {
    const pieces = chunkText(legend.text);
    if (pieces.length === 0) {
      emptyCount++;
      console.warn(`  WARNING: no usable text for "${legend.title}" (empty or near-empty extract)`);
      continue;
    }
    pieces.forEach((chunkText, idx) => {
      allChunks.push({
        legend_title: legend.title,
        legend_url: legend.url,
        image_url: legend.image_url,
        chunk_index: idx,
        text: chunkText,
      });
    });
  }
  console.log(`Created ${allChunks.length} chunks from ${legends.length - emptyCount} legends (${emptyCount} had no usable text)`);

  // Step 2: load all 3 models once, then embed every chunk with each
  for (const model of MODELS) {
    console.log(`\nLoading model: ${model.name} ...`);
    const extractor = await pipeline('feature-extraction', model.name);

    console.log(`Embedding ${allChunks.length} chunks with ${model.key} ...`);
    for (let i = 0; i < allChunks.length; i++) {
      const embedding = await embedText(extractor, allChunks[i].text);
      allChunks[i][`embedding_${model.key}`] = embedding;

      if ((i + 1) % 20 === 0 || i === allChunks.length - 1) {
        console.log(`  [${model.key}] ${i + 1}/${allChunks.length}`);
      }
    }
  }

  fs.writeFileSync(OUTPUT_PATH, JSON.stringify(allChunks, null, 2), 'utf-8');
  console.log(`\nSaved ${allChunks.length} embedded chunks to ${OUTPUT_PATH}`);
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
