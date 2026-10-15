$dir = "C:\Users\dell\urban-legends-rag\server\scripts"

@'
// annotateWithLLMs.js - sends each chunk to 3 LLMs (via Groq) for independent category annotation
// Resumable: skips chunks already fully annotated on re-run
// Run: node scripts/annotateWithLLMs.js

require('dotenv').config();
const fs = require('fs');
const path = require('path');

const GROQ_API_URL = 'https://api.groq.com/openai/v1/chat/completions';

// Groq's model lineup changes over time - if any fail with 404/decommissioned, check
// https://api.groq.com/openai/v1/models for your account's current available models
const MODELS = [
  { key: 'gptoss120b', model: 'openai/gpt-oss-120b' },
  { key: 'allam7b', model: 'allam-2-7b' },
  { key: 'gptoss20b', model: 'openai/gpt-oss-20b' },
];

const CATEGORIES = [
  'Ghosts and Spirits',
  'Legendary Creatures',
  'Deities and Mythological Figures',
  'Legendary and Historical Figures',
  'Place-Based Legends',
  'Fairy Tales and Fables',
  'Cultural Superstitions and Practices',
];

const CHUNKS_PATH = path.join(__dirname, '..', 'data', 'processed', 'chunks_for_annotation.json');
const OUTPUT_PATH = path.join(__dirname, '..', 'data', 'processed', 'annotations.json');

const SYSTEM_PROMPT = `You are annotating short folklore text passages for a research project.
Classify the passage into EXACTLY ONE of these categories:
${CATEGORIES.map((c) => `- ${c}`).join('\n')}

Respond with ONLY valid JSON, no markdown fences, no commentary:
{"category": "<one of the categories above, exact text>", "confidence": <number 0.0-1.0>, "reasoning": "<one short sentence>"}`;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Per-model minimum spacing (ms), based on each model's real rate limits - gpt-oss models
// also generate hidden reasoning tokens that eat into the budget invisibly, so they need more room
const MIN_INTERVAL_MS = {
  'openai/gpt-oss-120b': 10000,
  'allam-2-7b': 5000,
  'openai/gpt-oss-20b': 10000,
};

const lastCallTime = {};

async function waitForModelSlot(model) {
  const minInterval = MIN_INTERVAL_MS[model] || 2200;
  const last = lastCallTime[model] || 0;
  const elapsed = Date.now() - last;
  if (elapsed < minInterval) {
    await sleep(minInterval - elapsed);
  }
  lastCallTime[model] = Date.now();
}

async function callModel(model, chunkText, retries = 4) {
  await waitForModelSlot(model);

  for (let attempt = 0; attempt <= retries; attempt++) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 30000); // 30s timeout

    let res;
    try {
      res = await fetch(GROQ_API_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${process.env.GROQ_API_KEY}`,
        },
        body: JSON.stringify({
          model,
          temperature: 0.1,
          max_tokens: 150,
          messages: [
            { role: 'system', content: SYSTEM_PROMPT },
            { role: 'user', content: chunkText.slice(0, 1200) },
          ],
        }),
        signal: controller.signal,
      });
    } catch (err) {
      clearTimeout(timeoutId);
      const reason = err.name === 'AbortError' ? 'timed out after 30s' : `network error (${err.message})`;
      console.log(`    (${model} ${reason}, retrying...)`);
      await sleep(3000);
      continue;
    }
    clearTimeout(timeoutId);

    if (res.status === 429) {
      const waitMs = 5000 * Math.pow(2, attempt);
      console.log(`    (${model} rate limited, waiting ${waitMs / 1000}s...)`);
      await sleep(waitMs);
      continue;
    }

    if (!res.ok) {
      const errText = await res.text();
      throw new Error(`Groq error ${res.status} for ${model}: ${errText}`);
    }

    const data = await res.json();
    const raw = data.choices[0].message.content.trim();
    const cleaned = raw.replace(/^```json\s*/i, '').replace(/```\s*$/, '');

    try {
      const parsed = JSON.parse(cleaned);
      if (!CATEGORIES.includes(parsed.category)) {
        return { category: parsed.category, confidence: parsed.confidence || 0, reasoning: parsed.reasoning || '', invalid_category: true };
      }
      return parsed;
    } catch (err) {
      return { parse_error: true, raw_response: raw };
    }
  }

  throw new Error(`Too many retries for ${model}`);
}

function loadExisting() {
  if (fs.existsSync(OUTPUT_PATH)) {
    return JSON.parse(fs.readFileSync(OUTPUT_PATH, 'utf-8'));
  }
  return {};
}

function saveProgress(annotations) {
  fs.writeFileSync(OUTPUT_PATH, JSON.stringify(annotations, null, 2), 'utf-8');
}

async function main() {
  if (!process.env.GROQ_API_KEY) {
    console.error('GROQ_API_KEY not found in .env - aborting.');
    process.exit(1);
  }

  const chunks = JSON.parse(fs.readFileSync(CHUNKS_PATH, 'utf-8'));
  console.log(`Loaded ${chunks.length} chunks to annotate`);

  const annotations = loadExisting();
  const alreadyDone = Object.keys(annotations).length;
  console.log(`Resuming: ${alreadyDone} already annotated, ${chunks.length - alreadyDone} remaining`);

  let processedThisRun = 0;

  // Annotate every chunk not already fully done, one model at a time
  for (const chunk of chunks) {
    if (annotations[chunk.id]) continue; // already fully annotated

    const result = { country: chunk.country, article_title: chunk.article_title };

    for (const { key, model } of MODELS) {
      try {
        result[key] = await callModel(model, chunk.text);
      } catch (err) {
        console.error(`  ERROR on chunk ${chunk.id}, model ${key}: ${err.message}`);
        result[key] = { error: err.message };
      }
      await sleep(300); // per-model pacing (waitForModelSlot) handles the real rate limits now
    }

    annotations[chunk.id] = result;
    processedThisRun++;

    if (processedThisRun % 10 === 0) {
      saveProgress(annotations);
      console.log(`  annotated ${Object.keys(annotations).length}/${chunks.length} total (saved progress)`);
    }
  }

  saveProgress(annotations);
  console.log(`\nDone. Total annotated: ${Object.keys(annotations).length}/${chunks.length}`);
  console.log(`Saved to ${OUTPUT_PATH}`);
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
'@ | Set-Content -Encoding utf8 (Join-Path $dir "annotateWithLLMs.js")

@'
// buildEvalSet.js - builds a labeled query set for RAG evaluation (Recall@k, MRR)
// Samples chunks per country, has an LLM write one question each sampled chunk answers
// (without naming the article title, so it cant trivially string-match), and uses that
// chunk's id as ground truth. Resumable, same pattern as buildRagIndex.js.
// Run: node scripts/buildEvalSet.js

const fs = require('fs');
const path = require('path');

const INDEX_PATH = path.join(__dirname, '..', 'data', 'processed', 'rag_index.json');
const OUTPUT_PATH = path.join(__dirname, '..', 'data', 'processed', 'results', 'rag_eval_set.json');
const GROQ_API_URL = 'https://api.groq.com/openai/v1/chat/completions';
const MODEL = 'qwen/qwen3.8-27b';

const SAMPLES_PER_COUNTRY = 20; // 20 x 5 countries = 100 eval questions
const MIN_INTERVAL_MS = 6000; // mirrors baseline_zeroshot.py's pacing for this model

function loadApiKey() {
  let apiKey = process.env.GROQ_API_KEY;
  if (apiKey) return apiKey;
  const envPath = path.join(__dirname, '..', '.env');
  const envContent = fs.readFileSync(envPath, 'utf-8');
  for (const line of envContent.split('\n')) {
    if (line.startsWith('GROQ_API_KEY')) {
      return line.split('=', 2)[1].trim().replace(/^"|"$/g, '');
    }
  }
  throw new Error('GROQ_API_KEY not found in env or .env');
}

function sampleChunks(index) {
  const byCountry = {};
  index.forEach((c) => {
    if (!byCountry[c.country]) byCountry[c.country] = [];
    byCountry[c.country].push(c);
  });

  const sampled = [];
  for (const [country, chunks] of Object.entries(byCountry)) {
    const shuffled = [...chunks].sort(() => Math.random() - 0.5);
    sampled.push(...shuffled.slice(0, SAMPLES_PER_COUNTRY));
  }
  return sampled;
}

async function generateQuestion(chunk, apiKey) {
  const systemPrompt = `You write evaluation questions for a retrieval system test.
Given a passage, write ONE natural question that a curious reader would ask, which this
passage directly answers. Rules:
- Do NOT include the article title or any proper noun that appears ONLY in the title.
- The question should be answerable from the passage's content alone.
- Respond with ONLY the question text, nothing else (no quotes, no "Question:" prefix).`;

  const res = await fetch(GROQ_API_URL, {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: MODEL,
      temperature: 0.3,
      max_tokens: 80,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: chunk.text.slice(0, 1200) },
      ],
    }),
  });

  if (res.status === 429) {
    throw new Error('RATE_LIMITED');
  }
  if (!res.ok) {
    throw new Error(`Groq error ${res.status}: ${await res.text()}`);
  }

  const data = await res.json();
  return data.choices[0].message.content.trim();
}

function loadExisting() {
  if (!fs.existsSync(OUTPUT_PATH)) return [];
  try {
    return JSON.parse(fs.readFileSync(OUTPUT_PATH, 'utf-8'));
  } catch {
    return [];
  }
}

async function main() {
  const index = JSON.parse(fs.readFileSync(INDEX_PATH, 'utf-8'));
  console.log(`Loaded RAG index: ${index.length} chunks`);

  const apiKey = loadApiKey();
  const sampled = sampleChunks(index);
  console.log(`Sampled ${sampled.length} chunks (${SAMPLES_PER_COUNTRY} per country) to generate questions for.`);

  const existing = loadExisting();
  const doneIds = new Set(existing.map((e) => e.expected_chunk_id));
  const remaining = sampled.filter((c) => !doneIds.has(c.id));
  console.log(`Already have ${existing.length} questions, ${remaining.length} remaining.\n`);

  const results = existing;
  fs.mkdirSync(path.dirname(OUTPUT_PATH), { recursive: true });

  // Generate one question per sampled chunk, with rate-limit retry
  for (let i = 0; i < remaining.length; i++) {
    const chunk = remaining[i];
    let question;
    try {
      question = await generateQuestion(chunk, apiKey);
    } catch (err) {
      if (err.message === 'RATE_LIMITED') {
        console.log('  rate limited, waiting 30s...');
        await new Promise((r) => setTimeout(r, 30000));
        i--; // retry this one
        continue;
      }
      console.warn(`  skipping chunk ${chunk.id}: ${err.message}`);
      continue;
    }

    results.push({
      question,
      expected_chunk_id: chunk.id,
      expected_country: chunk.country,
      expected_article_title: chunk.article_title,
    });

    console.log(`  [${existing.length + i + 1}/${sampled.length}] (${chunk.country}) "${question}"`);

    if ((results.length) % 10 === 0) {
      fs.writeFileSync(OUTPUT_PATH, JSON.stringify(results, null, 2), 'utf-8');
    }

    await new Promise((r) => setTimeout(r, MIN_INTERVAL_MS));
  }

  fs.writeFileSync(OUTPUT_PATH, JSON.stringify(results, null, 2), 'utf-8');
  console.log(`\nSaved ${results.length} eval questions to ${OUTPUT_PATH}`);
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
'@ | Set-Content -Encoding utf8 (Join-Path $dir "buildEvalSet.js")

@'
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
'@ | Set-Content -Encoding utf8 (Join-Path $dir "buildRagIndex.js")

@'
// chunkForAnnotation.js - chunks curated articles from all 5 countries into paragraph-level
// passages for the 3-LLM annotation step
// Run: node scripts/chunkForAnnotation.js

const fs = require('fs');
const path = require('path');

const COUNTRIES = ['japan', 'china', 'india', 'philippines', 'indonesia'];
const CURATED_DIR = path.join(__dirname, '..', 'data', 'curated');
const OUTPUT_DIR = path.join(__dirname, '..', 'data', 'processed');
const OUTPUT_PATH = path.join(OUTPUT_DIR, 'chunks_for_annotation.json');

const CHUNK_WORD_TARGET = 250;
const MIN_TEXT_WORDS = 5;

// Same chunking logic as embedCorpus.js: paragraph-boundary-aware, never drops a short
// article to zero chunks
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

function main() {
  if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  }

  const allChunks = [];
  const perCountryCount = {};

  // Chunk every curated article, country by country
  for (const country of COUNTRIES) {
    const curatedPath = path.join(CURATED_DIR, `${country}.json`);
    if (!fs.existsSync(curatedPath)) {
      console.warn(`Skipping ${country}: no curated file found at ${curatedPath}`);
      continue;
    }

    const articles = JSON.parse(fs.readFileSync(curatedPath, 'utf-8'));
    let countryChunkCount = 0;
    let emptyCount = 0;

    for (const article of articles) {
      const pieces = chunkText(article.text || '');
      if (pieces.length === 0) {
        emptyCount++;
        continue;
      }

      pieces.forEach((chunkText, idx) => {
        allChunks.push({
          id: `${country}_${allChunks.length}`,
          country,
          article_title: article.title,
          article_url: article.url,
          image_url: article.image_url || null,
          chunk_index: idx,
          text: chunkText,
        });
        countryChunkCount++;
      });
    }

    perCountryCount[country] = { articles: articles.length, chunks: countryChunkCount, emptyArticles: emptyCount };
    console.log(`${country}: ${articles.length} articles -> ${countryChunkCount} chunks (${emptyCount} had no usable text)`);
  }

  console.log(`\nTotal chunks before sampling: ${allChunks.length}`);

  // Downsample to a manageable target for 3-LLM annotation, keeping each country's
  // proportional share of the total intact (stratified sampling)
  const TARGET_TOTAL = 1100;
  let finalChunks = allChunks;

  if (allChunks.length > TARGET_TOTAL) {
    const byCountry = {};
    allChunks.forEach((c) => {
      if (!byCountry[c.country]) byCountry[c.country] = [];
      byCountry[c.country].push(c);
    });

    finalChunks = [];
    for (const [country, chunks] of Object.entries(byCountry)) {
      const share = Math.round((chunks.length / allChunks.length) * TARGET_TOTAL);
      // Shuffle then take the first `share` chunks
      const shuffled = [...chunks].sort(() => Math.random() - 0.5);
      const sampled = shuffled.slice(0, share);
      finalChunks = finalChunks.concat(sampled);
      console.log(`  ${country}: sampled ${sampled.length} of ${chunks.length} chunks`);
    }
  }

  fs.writeFileSync(OUTPUT_PATH, JSON.stringify(finalChunks, null, 2), 'utf-8');

  console.log(`\nFinal chunk count for annotation: ${finalChunks.length}`);
  console.log(`Saved to ${OUTPUT_PATH}`);
}

main();
'@ | Set-Content -Encoding utf8 (Join-Path $dir "chunkForAnnotation.js")

@'
// cleanupCorpus.js - first-pass cleanup across all 5 countries: drops generic/admin pages,
// hand-picked off-topic entries, and cross-country duplicates (kept under the first country
// in COUNTRY_PRIORITY order). Not fine-grained curation, just removes clear noise and dupes.
// Run: node scripts/cleanupCorpus.js

const fs = require('fs');
const path = require('path');

const RAW_DIR = path.join(__dirname, '..', 'data', 'raw');
const CURATED_DIR = path.join(__dirname, '..', 'data', 'curated');

const COUNTRY_PRIORITY = ['japan', 'china', 'india', 'philippines', 'indonesia'];

// Generic/administrative page patterns to drop everywhere
const GENERIC_PATTERNS = [
  /^List of /i,
  /^Template:/i,
  /^Category:/i,
];

// Country-level overview pages (about the folklore tradition itself, not a specific legend)
const OVERVIEW_TITLES = new Set([
  'Japanese folklore', 'Japanese folktales', 'Chinese folklore', 'Chinese mythology',
  'Chinese dragon', 'Indian folklore', 'Folklore of India', 'Philippine mythology',
  'Folklore of Indonesia', 'Malay folklore', 'Ghosts in Malay culture',
  'Punjabi folklore', 'Meitei folklore', 'Telugu folk literature',
  'Philippine folk literature', 'Philippine epic poetry',
]);

// Hand-picked off-topic entries found during review
const OFF_TOPIC = new Set([
  'Siopao', 'Robinsons Galleria', 'Judiel Nieva', 'Spoliarium (Eraserheads song)',
  'List of Filipino inventions and discoveries', 'Piracy', 'UFO sightings in Indonesia',
  'UFO sightings in China', 'UFO sightings in India', 'Banyuwangi (town)',
  'The Twelve Dancing Princesses', 'The Water of Life (German fairy tale)',
  'Customs and etiquette in Indian dining', 'Goan soup', 'Saraca asoca',
  'Reinwardtia', 'Gynostemma pentaphyllum', "May you live in interesting times",
  'Egg balancing', 'Southern Shaolin Monastery', 'Southern Dragon kung fu',
  'Zhou Tong (archer)', 'Wong Kei-ying', 'Hong Xiguan', 'Fong Sai-yuk',
  'Ten Tigers of Canton', '18 Warriors of Sui-Tang Transition',
  'Red Lanterns (Boxer Uprising)', 'Imperial examination in Chinese mythology',
  'LGBTQ themes in Chinese mythology', 'Timeline of Chinese mythology',
  'Adivasi Lok Kala Academy', 'Karadi Tales', 'Bagani (TV series)',
  'The Mythology Class', 'Maddock Horror Comedy Universe',
]);

function isGeneric(title) {
  return GENERIC_PATTERNS.some((pattern) => pattern.test(title));
}

function main() {
  if (!fs.existsSync(CURATED_DIR)) {
    fs.mkdirSync(CURATED_DIR, { recursive: true });
  }

  const seenGlobally = new Set();
  const summary = [];

  // Filter each country's raw pages, country by country, in priority order
  for (const country of COUNTRY_PRIORITY) {
    const rawPath = path.join(RAW_DIR, `${country}.json`);
    if (!fs.existsSync(rawPath)) {
      console.warn(`Skipping ${country}: no raw file found`);
      continue;
    }

    const raw = JSON.parse(fs.readFileSync(rawPath, 'utf-8'));
    const keptOverview = [];
    const curated = raw.filter((page) => {
      if (isGeneric(page.title)) return false;
      if (OFF_TOPIC.has(page.title)) return false;
      if (OVERVIEW_TITLES.has(page.title)) {
        keptOverview.push(page.title);
        return false;
      }
      if (seenGlobally.has(page.title)) return false; // cross-country dedupe
      seenGlobally.add(page.title);
      return true;
    });

    const outPath = path.join(CURATED_DIR, `${country}.json`);
    fs.writeFileSync(outPath, JSON.stringify(curated, null, 2), 'utf-8');

    summary.push({ country, raw: raw.length, curated: curated.length, overviewDropped: keptOverview.length });
    console.log(`${country}: ${raw.length} raw -> ${curated.length} curated (dropped ${keptOverview.length} overview pages)`);
  }

  const total = summary.reduce((sum, s) => sum + s.curated, 0);
  console.log(`\nTotal curated articles across all countries: ${total}`);
  console.log('\nReview data/curated/*.json - if this total needs to grow toward 1000,');
  console.log('we can loosen the OFF_TOPIC/OVERVIEW exclusions or add more categories.');
}

main();
'@ | Set-Content -Encoding utf8 (Join-Path $dir "cleanupCorpus.js")

@'
// computeRelatedEmbeddings.js - computes per-article "related legends" by averaging each
// article's chunk embeddings and ranking cosine similarity within the same country
// Run: node scripts/computeRelatedEmbeddings.js

const fs = require('fs');
const path = require('path');

const RAG_INDEX_PATH = path.join(__dirname, '..', 'data', 'processed', 'rag_index.json');
const OUTPUT_PATH = path.join(__dirname, '..', 'data', 'processed', 'related_legends.json');
const TOP_K = 4;

function cosineSimilarity(a, b) {
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  return dot / (Math.sqrt(normA) * Math.sqrt(normB));
}

function averageVectors(vectors) {
  const dim = vectors[0].length;
  const avg = new Array(dim).fill(0);
  for (const v of vectors) {
    for (let i = 0; i < dim; i++) avg[i] += v[i];
  }
  for (let i = 0; i < dim; i++) avg[i] /= vectors.length;
  return avg;
}

function main() {
  console.log('Loading rag_index.json...');
  const chunks = JSON.parse(fs.readFileSync(RAG_INDEX_PATH, 'utf-8'));
  console.log(`Loaded ${chunks.length} chunks.`);

  // Group chunk embeddings by article, then average into one vector per article
  const articleMap = new Map();
  for (const chunk of chunks) {
    const key = `${chunk.country}/${chunk.article_title}`;
    if (!articleMap.has(key)) {
      articleMap.set(key, { country: chunk.country, title: chunk.article_title, embeddings: [] });
    }
    articleMap.get(key).embeddings.push(chunk.embedding);
  }

  console.log(`Found ${articleMap.size} unique articles.`);

  const articles = [];
  for (const [key, data] of articleMap.entries()) {
    articles.push({
      key,
      country: data.country,
      title: data.title,
      vector: averageVectors(data.embeddings),
    });
  }

  // For each article, rank every other same-country article by cosine similarity
  const related = {};
  for (let i = 0; i < articles.length; i++) {
    const a = articles[i];
    const scored = [];
    for (let j = 0; j < articles.length; j++) {
      if (i === j) continue;
      const b = articles[j];
      if (b.country !== a.country) continue;
      const score = cosineSimilarity(a.vector, b.vector);
      scored.push({ title: b.title, country: b.country, score });
    }
    scored.sort((x, y) => y.score - x.score);
    related[a.key] = scored.slice(0, TOP_K);

    if ((i + 1) % 200 === 0) {
      console.log(`Processed ${i + 1}/${articles.length} articles...`);
    }
  }

  fs.writeFileSync(OUTPUT_PATH, JSON.stringify(related, null, 2));
  console.log(`Saved related legends for ${Object.keys(related).length} articles to ${OUTPUT_PATH}`);
}

main();
'@ | Set-Content -Encoding utf8 (Join-Path $dir "computeRelatedEmbeddings.js")

@'
// curateCorpus.js - filters raw per-country JSON (from fetchWikipedia.js) down to the
// curated keep-list, saves to data/curated/{country}.json
// Run: node scripts/curateCorpus.js

const fs = require('fs');
const path = require('path');

const RAW_DIR = path.join(__dirname, '..', 'data', 'raw');
const CURATED_DIR = path.join(__dirname, '..', 'data', 'curated');

// Titles to exclude per country. Everything NOT in this list is kept.
// Japan: category was already clean, only the overview page is excluded.
const EXCLUDE = {
  indonesia: [
    'Folklore of Indonesia',
    'Malay folklore',
    'Ghosts in Malay culture',
    'UFO sightings in Indonesia',
    'Piracy',
    'Banyuwangi (town)',
  ],
};

function curateCountry(country) {
  const rawPath = path.join(RAW_DIR, `${country}.json`);
  if (!fs.existsSync(rawPath)) {
    console.warn(`Skipping ${country}: raw file not found at ${rawPath}`);
    return;
  }

  const raw = JSON.parse(fs.readFileSync(rawPath, 'utf-8'));
  const excludeSet = new Set(EXCLUDE[country] || []);

  const curated = raw.filter((page) => !excludeSet.has(page.title));

  if (!fs.existsSync(CURATED_DIR)) {
    fs.mkdirSync(CURATED_DIR, { recursive: true });
  }

  const outPath = path.join(CURATED_DIR, `${country}.json`);
  fs.writeFileSync(outPath, JSON.stringify(curated, null, 2), 'utf-8');

  console.log(`${country}: kept ${curated.length} of ${raw.length} pages -> ${outPath}`);
  curated.forEach((p) => console.log(`  - ${p.title}`));
}

function main() {
  curateCountry('indonesia');
}

main();
'@ | Set-Content -Encoding utf8 (Join-Path $dir "curateCorpus.js")

@'
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
'@ | Set-Content -Encoding utf8 (Join-Path $dir "embedCorpus.js")

@'
// fetchWikipedia.js - pulls pages from given Wikipedia categories, fetches full article
// text + lead image for each, saves raw JSON per country for review before chunking
// Run: node scripts/fetchWikipedia.js

const fs = require('fs');
const path = require('path');

const WIKI_API = 'https://en.wikipedia.org/w/api.php';

// Wikimedia's API throttles requests without a descriptive User-Agent much more aggressively
const USER_AGENT = 'FolkloreRAGStudentProject/1.0 (Kennesaw State University course project; contact via KSU email)';

// Pulls from TWO categories per country where needed to get both general folklore/legends
// AND specific legendary creatures (a single category can miss entries)
const CATEGORY_GROUPS = {
  // Japan already fetched and saved successfully - left out here to avoid re-fetching
  // and re-risking a rate-limit block. Re-add only if you need to refresh it.
  // Japan: [
  //   'Category:Japanese urban legends',
  //   'Category:Japanese legendary creatures',
  //   'Category:YÅkai',
  //   'Category:Japanese ghosts',
  //   'Category:Japanese dragons',
  //   'Category:Japanese demons',
  //   'Category:Japanese giants',
  //   'Category:Japanese folklore',
  // ],
  India: [
    'Category:Indian folklore',
    'Category:Indian mythology',
    'Category:Legendary creatures of India',
  ],
  China: [
    'Category:Chinese folklore',
    'Category:Chinese mythology',
    'Category:Chinese dragons',
    'Category:Legendary creatures of China',
  ],
  Philippines: [
    'Category:Philippine urban legends',
    'Category:Philippine legendary creatures',
    'Category:Philippine mythology',
  ],
  Indonesia: [
    'Category:Indonesian folklore',
    'Category:Indonesian legendary creatures',
  ],
};

// Titles known from Wikipedia's "Folklore of Indonesia" genre lists that the categories
// above missed (e.g. Kuntilanak, Sundel Bolong). Fetched directly by title; missing
// articles are silently skipped, redirects resolve to their target.
const EXTRA_TITLES = {
  Indonesia: [
    'Kuntilanak', 'Wewe Gombel', 'Sundel Bolong', 'Calon Arang', 'Kuyang',
    'Orang Ikan', 'Kisut',
    'Malin Kundang', 'Sangkuriang', 'Rara Jonggrang', 'Aji Saka',
    'Banyuwangi', 'Sulanjana', 'Watu Gunung', 'Lanun',
    'Ande Ande Lumut', 'Jaka Tarub', 'Timun Mas', 'Roro Mendut',
    'Ciung Wanara', 'Damarwulan', 'Ken Arok and Ken Dedes',
    'Mundinglaya Dikusumah', 'Pangeran Katak', 'Panji Semirang',
    'Siliwangi', 'Si Pitung', 'Gurabesi', 'Leungli',
    // Mined from the "Folklore of Indonesia" regional breakdown (Sumatra/Sulawesi/Sunda)
    'Hang Tuah', 'Si Pahit Lidah', 'Putri Hijau', 'Sawerigading',
    'Nini Anteh', 'Si Kebayan', 'Telaga Warna', 'Situ Bagendit',
  ],
};

// General-context pages (themes, genres, history) - not individual legends, so kept
// separate rather than given a legend profile page on the site
const BACKGROUND_TITLES = {
  Indonesia: ['Folklore of Indonesia'],
};

// Native language per country, for fetching a second source article for enrichment input
const NATIVE_LANG = {
  Japan: 'ja',
  India: 'hi',
  China: 'zh',
  Philippines: 'tl',
  Indonesia: 'id',
};

const OUTPUT_DIR = path.join(__dirname, '..', 'data', 'raw');

// Temporarily off to cut request volume while the main English-text pull goes through cleanly
const FETCH_NATIVE_LANG = false;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function wikiFetch(params, retries = 5) {
  const url = new URL(WIKI_API);
  url.search = new URLSearchParams({
    format: 'json',
    origin: '*',
    ...params,
  }).toString();

  for (let attempt = 0; attempt <= retries; attempt++) {
    const res = await fetch(url, { headers: { 'User-Agent': USER_AGENT } });

    if (res.status === 429 || res.status === 403) {
      const waitMs = 10000 * Math.pow(2, attempt); // 10s, 20s, 40s, 80s, 160s
      console.log(`    (blocked with ${res.status}, waiting ${waitMs / 1000}s...)`);
      await sleep(waitMs);
      continue;
    }

    if (!res.ok) {
      throw new Error(`Wikipedia API error: ${res.status} ${res.statusText}`);
    }
    return res.json();
  }

  throw new Error('Wikipedia API error: too many retries, giving up');
}

// Fetch from a specific language's Wikipedia (e.g. id.wikipedia.org)
async function wikiFetchLang(lang, params, retries = 5) {
  const url = new URL(`https://${lang}.wikipedia.org/w/api.php`);
  url.search = new URLSearchParams({
    format: 'json',
    origin: '*',
    ...params,
  }).toString();

  for (let attempt = 0; attempt <= retries; attempt++) {
    const res = await fetch(url, { headers: { 'User-Agent': USER_AGENT } });

    if (res.status === 429) {
      const waitMs = 3000 * Math.pow(2, attempt);
      await sleep(waitMs);
      continue;
    }

    if (!res.ok) return null;
    return res.json();
  }

  return null;
}

// Given an English title, find the equivalent article in another language via langlinks,
// then fetch its plain-text extract. Returns null if no equivalent article exists.
async function getNativeText(englishTitle, lang) {
  try {
    const linkData = await wikiFetch({
      action: 'query',
      titles: englishTitle,
      prop: 'langlinks',
      lllang: lang,
      redirects: '1',
    });

    const pages = linkData.query.pages;
    let nativeTitle = null;
    for (const pageId in pages) {
      const links = pages[pageId].langlinks;
      if (links && links.length > 0) nativeTitle = links[0]['*'];
    }
    if (!nativeTitle) return null;

    const textData = await wikiFetchLang(lang, {
      action: 'query',
      titles: nativeTitle,
      prop: 'extracts',
      explaintext: '1',
      redirects: '1',
    });
    if (!textData) return null;

    const nPages = textData.query.pages;
    for (const pageId in nPages) {
      if (nPages[pageId].missing !== undefined) continue;
      return { title: nativeTitle, text: nPages[pageId].extract || '' };
    }
    return null;
  } catch (err) {
    return null;
  }
}

// Get all page titles under a category (paginated; subcategories are skipped for now)
async function getCategoryMembers(category) {
  let members = [];
  let cmcontinue = undefined;

  do {
    const data = await wikiFetch({
      action: 'query',
      list: 'categorymembers',
      cmtitle: category,
      cmlimit: '100',
      cmtype: 'page', // exclude subcategories; handled separately if needed
      ...(cmcontinue ? { cmcontinue } : {}),
    });

    members = members.concat(data.query.categorymembers.map((m) => m.title));
    cmcontinue = data.continue ? data.continue.cmcontinue : undefined;
  } while (cmcontinue);

  return members;
}

// Fetch full plain-text extract + lead image for a list of titles, plus a native-language
// extract when available. Resumable: skips titles already attempted, saves every 15.
async function getPageDetails(titles, nativeLang, country) {
  const outPath = path.join(OUTPUT_DIR, `${country.toLowerCase()}.json`);
  const progressPath = path.join(OUTPUT_DIR, `${country.toLowerCase()}_attempted.json`);

  let results = fs.existsSync(outPath) ? JSON.parse(fs.readFileSync(outPath, 'utf-8')) : [];
  let attempted = fs.existsSync(progressPath) ? new Set(JSON.parse(fs.readFileSync(progressPath, 'utf-8'))) : new Set();

  const remaining = titles.filter((t) => !attempted.has(t));
  console.log(`  Resuming: ${attempted.size} already attempted, ${remaining.length} remaining`);

  for (let i = 0; i < remaining.length; i++) {
    const title = remaining[i];

    const data = await wikiFetch({
      action: 'query',
      prop: 'extracts|pageimages|info',
      explaintext: '1',
      piprop: 'original',
      inprop: 'url',
      redirects: '1',
      titles: title,
    });

    const pages = data.query.pages;
    for (const pageId in pages) {
      const page = pages[pageId];
      if (page.missing !== undefined) continue;

      let native = null;
      if (nativeLang) {
        native = await getNativeText(page.title, nativeLang);
      }

      results.push({
        title: page.title,
        url: page.fullurl,
        image_url: page.original ? page.original.source : null,
        text: page.extract || '',
        native_lang: nativeLang || null,
        native_title: native ? native.title : null,
        native_text: native ? native.text : null,
      });
    }

    attempted.add(title);

    if ((i + 1) % 15 === 0 || i === remaining.length - 1) {
      fs.writeFileSync(outPath, JSON.stringify(results, null, 2), 'utf-8');
      fs.writeFileSync(progressPath, JSON.stringify([...attempted], null, 2), 'utf-8');
      console.log(`    fetched ${i + 1}/${remaining.length} (saved progress)`);
    }

    await sleep(1500); // slower pacing after hitting a 403 robot-policy block
  }

  return results;
}

async function main() {
  if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  }

  for (const [country, categories] of Object.entries(CATEGORY_GROUPS)) {
    console.log(`\n=== ${country} ===`);

    let allTitles = [];
    for (const category of categories) {
      const titles = await getCategoryMembers(category);
      console.log(`  ${category}: ${titles.length} pages`);
      allTitles = allTitles.concat(titles);
    }

    const extras = EXTRA_TITLES[country] || [];
    console.log(`  Extra hand-picked titles: ${extras.length}`);
    allTitles = allTitles.concat(extras);

    // Dedupe titles across categories/extras (some pages appear in both)
    const uniqueTitles = [...new Set(allTitles)];
    console.log(`Total unique input titles: ${uniqueTitles.length}`);

    const pages = await getPageDetails(uniqueTitles, FETCH_NATIVE_LANG ? NATIVE_LANG[country] : null, country);

    // Redirects can resolve two different input titles to the same article - dedupe by final title
    const seen = new Set();
    const dedupedPages = pages.filter((p) => {
      if (seen.has(p.title)) return false;
      seen.add(p.title);
      return true;
    });

    console.log(`Resolved to ${dedupedPages.length} unique articles:`);
    dedupedPages.forEach((p) => console.log(`  - ${p.title}`));

    const outPath = path.join(OUTPUT_DIR, `${country.toLowerCase()}.json`);
    fs.writeFileSync(outPath, JSON.stringify(dedupedPages, null, 2), 'utf-8');
    console.log(`Saved ${dedupedPages.length} articles to ${outPath}`);

    // Fetch and save background documents separately
    const backgroundTitles = BACKGROUND_TITLES[country] || [];
    if (backgroundTitles.length > 0) {
      const bgPages = await getPageDetails(backgroundTitles, null, `${country}_background`);
      const bgOutPath = path.join(OUTPUT_DIR, `${country.toLowerCase()}_background.json`);
      fs.writeFileSync(bgOutPath, JSON.stringify(bgPages, null, 2), 'utf-8');
      console.log(`Saved ${bgPages.length} background documents to ${bgOutPath}`);
    }
  }

  console.log('\nDone. Review the title lists above and the JSON files before proceeding to chunking/embedding.');
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
'@ | Set-Content -Encoding utf8 (Join-Path $dir "fetchWikipedia.js")

@'
// generateSummaries.js - generates a 2-3 sentence summary per curated article via Groq
// Resumable: skips articles that already have a summary
// Run: node scripts/generateSummaries.js

const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

const CURATED_DIR = path.join(__dirname, '..', 'data', 'curated');
const OUTPUT_PATH = path.join(__dirname, '..', 'data', 'processed', 'summaries.json');
const COUNTRIES = ['japan', 'china', 'india', 'philippines', 'indonesia'];

const GROQ_MODEL = 'qwen/qwen3.8-27b';
const MAX_INPUT_CHARS = 2000;
const MIN_INTERVAL_MS = 10000; // conservative spacing to stay under Groq's free-tier ITPM cap
const SAVE_EVERY = 10;
const MAX_RATE_LIMIT_RETRIES = 3;

function loadExisting() {
  try {
    return JSON.parse(fs.readFileSync(OUTPUT_PATH, 'utf-8'));
  } catch {
    return {};
  }
}

function save(summaries) {
  fs.mkdirSync(path.dirname(OUTPUT_PATH), { recursive: true });
  fs.writeFileSync(OUTPUT_PATH, JSON.stringify(summaries, null, 2));
}

async function generateSummary(apiKey, title, text) {
  const truncated = text.slice(0, MAX_INPUT_CHARS);

  const res = await fetch('https://api.groq.com/openai/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: GROQ_MODEL,
      messages: [
        {
          role: 'system',
          content:
            'You summarize folklore encyclopedia articles in exactly 2-3 sentences, in a clear, neutral encyclopedic tone. Output only the summary text, nothing else - no preamble, no title restatement as the first words, no quotation marks.',
        },
        {
          role: 'user',
          content: `Title: ${title}\n\nArticle:\n${truncated}`,
        },
      ],
      temperature: 0.4,
      max_tokens: 150,
    }),
  });

  if (res.status === 429) {
    throw new Error('RATE_LIMITED');
  }
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Groq error ${res.status}: ${body}`);
  }

  const data = await res.json();
  return data.choices[0].message.content.trim();
}

async function main() {
  const apiKey = process.env.GROQ_API_KEY;
  if (!apiKey) {
    console.error('GROQ_API_KEY not found in .env');
    process.exit(1);
  }

  const summaries = loadExisting();
  console.log(`Resuming with ${Object.keys(summaries).length} existing summaries.`);

  let processedSinceSave = 0;
  let lastCallTime = 0;

  // Summarize every curated article not already done, country by country
  for (const country of COUNTRIES) {
    const filePath = path.join(CURATED_DIR, `${country}.json`);
    if (!fs.existsSync(filePath)) {
      console.log(`Skipping ${country} - no curated file found.`);
      continue;
    }

    const articles = JSON.parse(fs.readFileSync(filePath, 'utf-8'));
    console.log(`Processing ${articles.length} articles for ${country}...`);

    for (let i = 0; i < articles.length; i++) {
      const article = articles[i];
      const key = `${country}/${article.title}`;

      if (summaries[key]) {
        continue;
      }

      const elapsed = Date.now() - lastCallTime;
      if (elapsed < MIN_INTERVAL_MS) {
        await new Promise((r) => setTimeout(r, MIN_INTERVAL_MS - elapsed));
      }

      let attempts = 0;
      let done = false;
      while (!done) {
        try {
          lastCallTime = Date.now();
          const summary = await generateSummary(apiKey, article.title, article.text || '');
          summaries[key] = summary;
          done = true;
        } catch (err) {
          if (err.message === 'RATE_LIMITED') {
            attempts++;
            if (attempts >= MAX_RATE_LIMIT_RETRIES) {
              console.warn(`  [${key}] gave up after ${attempts} rate-limit retries, skipping for now.`);
              done = true;
            } else {
              console.log(`  [${key}] rate limited, waiting 30s (attempt ${attempts})...`);
              await new Promise((r) => setTimeout(r, 30000));
            }
          } else {
            console.warn(`  [${key}] error: ${err.message}`);
            done = true;
          }
        }
      }

      processedSinceSave++;
      if (processedSinceSave >= SAVE_EVERY) {
        save(summaries);
        processedSinceSave = 0;
        console.log(`  Saved progress: ${Object.keys(summaries).length} summaries so far.`);
      }

      if ((i + 1) % 50 === 0) {
        console.log(`  ${country}: ${i + 1}/${articles.length}`);
      }
    }
  }

  save(summaries);
  console.log(`Done. Saved ${Object.keys(summaries).length} summaries to ${OUTPUT_PATH}`);
}

main();
'@ | Set-Content -Encoding utf8 (Join-Path $dir "generateSummaries.js")

@'
// index.js - Express entry point for the MERN backend; serves the RAG chat route and
// the curated folklore corpus for the encyclopedia pages
// Run: node index.js

require('dotenv').config();
const express = require('express');
const cors = require('cors');

const chatRoutes = require('./routes/chat');
const legendsRoutes = require('./routes/legends');

const app = express();
const PORT = process.env.PORT || 5000;

app.use(cors());
app.use(express.json());

// Simple request log - helpful while developing against the React app
app.use((req, res, next) => {
  console.log(`${req.method} ${req.path}`);
  next();
});

app.use('/api/chat', chatRoutes);
app.use('/api/legends', legendsRoutes);

app.get('/api/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: err.message || 'Internal server error' });
});

app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
'@ | Set-Content -Encoding utf8 (Join-Path $dir "index.js")

@'
// ragEval.js - RAGAS-style evaluation of the RAG pipeline (separate from the classifier's
// own eval): Recall@k (k=1,3,5,10), MRR, and an LLM-judged faithfulness score.
// Retrieval is scored two ways - "naive" (no country filter) vs "country_aware" (the
// detectCountry() filter from ragQuery.js) - to quantify a retrieval bug found in testing.
// Resumable (checkpoints every 5 questions).
// Run: node scripts/ragEval.js [--skip-faithfulness]

const fs = require('fs');
const path = require('path');
const { retrieve, generateAnswer, detectCountry } = require('./ragQuery');

const EVAL_SET_PATH = path.join(__dirname, '..', 'data', 'processed', 'results', 'rag_eval_set.json');
const OUTPUT_PATH = path.join(__dirname, '..', 'data', 'processed', 'results', 'rag_eval_results.json');
const GROQ_API_URL = 'https://api.groq.com/openai/v1/chat/completions';
const JUDGE_MODEL = 'qwen/qwen3.8-27b';
const RETRIEVAL_K = 10; // retrieve top-10 so Recall@10 is measurable; Recall@1/3/5 are sub-slices
// Each question costs 2 Groq calls; 16s spacing keeps sustained throughput under the
// free-tier token/min cap (6s spacing was triggering repeated 429s)
const MIN_INTERVAL_MS = 16000;

function loadApiKey() {
  let apiKey = process.env.GROQ_API_KEY;
  if (apiKey) return apiKey;
  const envPath = path.join(__dirname, '..', '.env');
  const envContent = fs.readFileSync(envPath, 'utf-8');
  for (const line of envContent.split('\n')) {
    if (line.startsWith('GROQ_API_KEY')) {
      return line.split('=', 2)[1].trim().replace(/^"|"$/g, '');
    }
  }
  throw new Error('GROQ_API_KEY not found in env or .env');
}

function rankOf(expectedId, rankedIds) {
  const idx = rankedIds.indexOf(expectedId);
  return idx === -1 ? null : idx + 1; // 1-indexed rank, null if not found
}

function recallAtK(ranks, k, total) {
  const hits = ranks.filter((r) => r !== null && r <= k).length;
  return hits / total;
}

function meanReciprocalRank(ranks) {
  const reciprocals = ranks.map((r) => (r === null ? 0 : 1 / r));
  return reciprocals.reduce((a, b) => a + b, 0) / reciprocals.length;
}

async function judgeFaithfulness(question, answer, context, apiKey) {
  const systemPrompt = `You are a strict fact-checker. Given retrieved context passages and a generated answer,
determine whether EVERY factual claim in the answer is actually supported by the context (no outside
knowledge, no invented details). Respond with ONLY a single number: 1 if fully supported, 0.5 if
partially supported (some claims unsupported), or 0 if mostly or entirely unsupported. No other text.`;

  const userContent = `Context passages:\n${context}\n\nQuestion: ${question}\n\nGenerated answer: ${answer}\n\nFaithfulness score (1, 0.5, or 0):`;

  const res = await fetch(GROQ_API_URL, {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: JUDGE_MODEL,
      temperature: 0,
      max_tokens: 10,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: userContent },
      ],
    }),
  });

  if (res.status === 429) throw new Error('RATE_LIMITED');
  if (!res.ok) throw new Error(`Groq error ${res.status}: ${await res.text()}`);

  const data = await res.json();
  const raw = data.choices[0].message.content.trim();
  const match = raw.match(/[01](\.5)?/);
  return match ? parseFloat(match[0]) : null;
}

const CHECKPOINT_PATH = path.join(__dirname, '..', 'data', 'processed', 'results', 'rag_eval_checkpoint.json');

function loadCheckpoint() {
  if (!fs.existsSync(CHECKPOINT_PATH)) return [];
  try {
    return JSON.parse(fs.readFileSync(CHECKPOINT_PATH, 'utf-8'));
  } catch {
    return [];
  }
}

function saveCheckpoint(perQuestion) {
  fs.writeFileSync(CHECKPOINT_PATH, JSON.stringify(perQuestion), 'utf-8');
}

async function main() {
  const skipFaithfulness = process.argv.includes('--skip-faithfulness');

  const evalSet = JSON.parse(fs.readFileSync(EVAL_SET_PATH, 'utf-8'));
  console.log(`Loaded ${evalSet.length} eval questions.\n`);

  const apiKey = loadApiKey();

  const perQuestion = loadCheckpoint();
  if (perQuestion.length > 0) {
    console.log(`Resuming: ${perQuestion.length} questions already done, ${evalSet.length - perQuestion.length} remaining.\n`);
  }

  // Score each question: retrieve naive + country-aware, then judge faithfulness
  for (let i = perQuestion.length; i < evalSet.length; i++) {
    const item = evalSet[i];

    // Naive: search the full corpus, no country filter
    const naiveResults = await retrieve(item.question, RETRIEVAL_K, null);
    const naiveIds = naiveResults.map((c) => c.id);
    const naiveRank = rankOf(item.expected_chunk_id, naiveIds);

    // Country-aware: apply the detected-country filter, same as production ragAnswer()
    const detected = detectCountry(item.question);
    const caResults = await retrieve(item.question, RETRIEVAL_K, detected);
    const caIds = caResults.map((c) => c.id);
    const caRank = rankOf(item.expected_chunk_id, caIds);

    let faithfulness = null;
    if (!skipFaithfulness) {
      try {
        const context = caResults
          .slice(0, 5)
          .map((c, j) => `[${j + 1}] (${c.country} - "${c.article_title}")\n${c.text}`)
          .join('\n\n');
        const answer = await generateAnswer(item.question, caResults.slice(0, 5), apiKey);
        await new Promise((r) => setTimeout(r, MIN_INTERVAL_MS));
        faithfulness = await judgeFaithfulness(item.question, answer, context, apiKey);
        await new Promise((r) => setTimeout(r, MIN_INTERVAL_MS));
      } catch (err) {
        // generateAnswer throws "Groq error 429: ..." (not the literal string
        // 'RATE_LIMITED', which only judgeFaithfulness throws) - check the status
        // code in the message too so both calls retry on rate limit
        if (err.message === 'RATE_LIMITED' || err.message.includes('429') || err.message.includes('rate_limit')) {
          console.log('  rate limited, waiting 30s...');
          await new Promise((r) => setTimeout(r, 30000));
          i--; // retry this question
          continue;
        }
        console.warn(`  faithfulness check failed for question ${i}: ${err.message}`);
      }
    }

    perQuestion.push({
      question: item.question,
      expected_country: item.expected_country,
      detected_country: detected,
      naive_rank: naiveRank,
      country_aware_rank: caRank,
      faithfulness,
    });

    console.log(
      `  [${i + 1}/${evalSet.length}] (${item.expected_country}) naive_rank=${naiveRank ?? 'not found'} ` +
      `country_aware_rank=${caRank ?? 'not found'}` +
      (faithfulness !== null ? ` faithfulness=${faithfulness}` : '')
    );

    if (perQuestion.length % 5 === 0 || i === evalSet.length - 1) {
      saveCheckpoint(perQuestion);
    }
  }

  const total = evalSet.length;
  const naiveRanks = perQuestion.map((q) => q.naive_rank);
  const countryAwareRanks = perQuestion.map((q) => q.country_aware_rank);
  const faithfulnessScores = perQuestion.map((q) => q.faithfulness).filter((f) => f !== null);

  const summary = {
    total_questions: total,
    retrieval_k: RETRIEVAL_K,
    naive: {
      recall_at_1: recallAtK(naiveRanks, 1, total),
      recall_at_3: recallAtK(naiveRanks, 3, total),
      recall_at_5: recallAtK(naiveRanks, 5, total),
      recall_at_10: recallAtK(naiveRanks, 10, total),
      mrr: meanReciprocalRank(naiveRanks),
    },
    country_aware: {
      recall_at_1: recallAtK(countryAwareRanks, 1, total),
      recall_at_3: recallAtK(countryAwareRanks, 3, total),
      recall_at_5: recallAtK(countryAwareRanks, 5, total),
      recall_at_10: recallAtK(countryAwareRanks, 10, total),
      mrr: meanReciprocalRank(countryAwareRanks),
    },
    faithfulness: faithfulnessScores.length > 0
      ? {
          mean: faithfulnessScores.reduce((a, b) => a + b, 0) / faithfulnessScores.length,
          n: faithfulnessScores.length,
          fully_supported_pct: faithfulnessScores.filter((s) => s === 1).length / faithfulnessScores.length,
        }
      : null,
  };

  console.log('\n=== RAG Evaluation Summary ===');
  console.log(`Questions evaluated: ${total}\n`);
  console.log('Retrieval (naive, no country filter):');
  console.log(`  Recall@1:  ${summary.naive.recall_at_1.toFixed(3)}`);
  console.log(`  Recall@3:  ${summary.naive.recall_at_3.toFixed(3)}`);
  console.log(`  Recall@5:  ${summary.naive.recall_at_5.toFixed(3)}`);
  console.log(`  Recall@10: ${summary.naive.recall_at_10.toFixed(3)}`);
  console.log(`  MRR:       ${summary.naive.mrr.toFixed(3)}`);
  console.log('\nRetrieval (country-aware filter applied):');
  console.log(`  Recall@1:  ${summary.country_aware.recall_at_1.toFixed(3)}`);
  console.log(`  Recall@3:  ${summary.country_aware.recall_at_3.toFixed(3)}`);
  console.log(`  Recall@5:  ${summary.country_aware.recall_at_5.toFixed(3)}`);
  console.log(`  Recall@10: ${summary.country_aware.recall_at_10.toFixed(3)}`);
  console.log(`  MRR:       ${summary.country_aware.mrr.toFixed(3)}`);
  if (summary.faithfulness) {
    console.log(`\nFaithfulness: mean=${summary.faithfulness.mean.toFixed(3)} ` +
      `(${summary.faithfulness.n} answers judged, ${(summary.faithfulness.fully_supported_pct * 100).toFixed(1)}% fully supported)`);
  }

  fs.writeFileSync(OUTPUT_PATH, JSON.stringify({ summary, per_question: perQuestion }, null, 2), 'utf-8');
  console.log(`\nFull results saved to ${OUTPUT_PATH}`);
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
'@ | Set-Content -Encoding utf8 (Join-Path $dir "ragEval.js")

@'
// ragQuery.js - core RAG retrieval + generation; used both as a CLI tool and as the
// module the Express chat route imports.
// Retrieval: embeds the query with the same model used in buildRagIndex.js (bge-small-en-v1.5),
// ranks every chunk in rag_index.json by cosine similarity, returns top-k.
// Generation: feeds the top-k chunks + question to Groq, answers only from retrieved context.
// CLI: node scripts/ragQuery.js "your question here"

const fs = require('fs');
const path = require('path');
const { pipeline } = require('@xenova/transformers');

const INDEX_PATH = path.join(__dirname, '..', 'data', 'processed', 'rag_index.json');
const EMBEDDING_MODEL = 'Xenova/bge-small-en-v1.5';
const GROQ_API_URL = 'https://api.groq.com/openai/v1/chat/completions';
const GENERATION_MODEL = 'qwen/qwen3.8-27b';
const TOP_K = 5;

// Country auto-detection: pure embedding similarity doesn't reliably stay within one
// country even when the query names it explicitly, so when a country name/adjective
// appears in the query, retrieval is restricted to that country's chunks.
const COUNTRY_ALIASES = {
  japan: ['japan', 'japanese'],
  china: ['china', 'chinese'],
  india: ['india', 'indian'],
  philippines: ['philippines', 'philippine', 'filipino', 'filipina'],
  indonesia: ['indonesia', 'indonesian'],
};

function detectCountry(query) {
  const lower = query.toLowerCase();
  for (const [country, aliases] of Object.entries(COUNTRY_ALIASES)) {
    if (aliases.some((alias) => lower.includes(alias))) return country;
  }
  return null;
}

let _index = null;
let _extractor = null;

function loadIndex() {
  if (_index) return _index;
  if (!fs.existsSync(INDEX_PATH)) {
    throw new Error(`rag_index.json not found at ${INDEX_PATH} - run buildRagIndex.js first.`);
  }
  _index = JSON.parse(fs.readFileSync(INDEX_PATH, 'utf-8'));
  console.log(`Loaded RAG index: ${_index.length} chunks`);
  return _index;
}

async function getExtractor() {
  if (_extractor) return _extractor;
  _extractor = await pipeline('feature-extraction', EMBEDDING_MODEL);
  return _extractor;
}

function cosineSimilarity(a, b) {
  let dot = 0;
  for (let i = 0; i < a.length; i++) dot += a[i] * b[i];
  return dot; // embeddings are already L2-normalized, so dot product == cosine similarity
}

async function embedQuery(text) {
  const extractor = await getExtractor();
  const output = await extractor(text, { pooling: 'mean', normalize: true });
  return Array.from(output.data);
}

// Retrieval only - returns top-k chunks with their similarity scores. Optional `country`
// filter restricts to one country's chunks (used by the per-country legend page search).
async function retrieve(query, k = TOP_K, country = null) {
  const index = loadIndex();
  const queryEmbedding = await embedQuery(query);

  const pool = country ? index.filter((c) => c.country === country) : index;

  const scored = pool.map((chunk) => ({
    ...chunk,
    score: cosineSimilarity(queryEmbedding, chunk.embedding),
  }));

  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, k).map(({ embedding, ...rest }) => rest); // drop embedding from output
}

async function generateAnswer(query, retrievedChunks, apiKey) {
  const context = retrievedChunks
    .map((c, i) => `[${i + 1}] (${c.country} - "${c.article_title}")\n${c.text}`)
    .join('\n\n');

  const systemPrompt = `You are a knowledgeable guide to Asian folklore (Japan, China, India, Philippines, Indonesia).
Answer the user's question using ONLY the numbered context passages below. If the passages don't contain
enough information to answer, say so plainly instead of guessing or using outside knowledge.
When you use a passage, cite it with its bracket number, e.g. [1]. Keep the answer concise (2-5 sentences)
unless the question clearly asks for more detail.

Context:
${context}`;

  const res = await fetch(GROQ_API_URL, {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: GENERATION_MODEL,
      temperature: 0.2,
      max_tokens: 400,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: query },
      ],
    }),
  });

  if (!res.ok) {
    throw new Error(`Groq error ${res.status}: ${await res.text()}`);
  }

  const data = await res.json();
  return data.choices[0].message.content.trim();
}

// Full RAG pipeline: retrieve then generate. This is what the Express chat route calls.
async function ragAnswer(query, { k = TOP_K, country = null, apiKey = null } = {}) {
  const key = apiKey || process.env.GROQ_API_KEY;
  if (!key) throw new Error('GROQ_API_KEY not set (pass apiKey or set the env var)');

  // Auto-detect a country from the query text if the caller didn't pin one explicitly
  const effectiveCountry = country || detectCountry(query);

  const retrieved = await retrieve(query, k, effectiveCountry);
  const answer = await generateAnswer(query, retrieved, key);

  return {
    query,
    answer,
    detectedCountry: effectiveCountry,
    sources: retrieved.map((c) => ({
      country: c.country,
      article_title: c.article_title,
      article_url: c.article_url,
      score: c.score,
    })),
  };
}

module.exports = { retrieve, generateAnswer, ragAnswer, detectCountry };

// CLI entry point for quick manual testing
if (require.main === module) {
  const query = process.argv.slice(2).join(' ');
  if (!query) {
    console.log('Usage: node scripts/ragQuery.js "your question here"');
    process.exit(1);
  }

  (async () => {
    let apiKey = process.env.GROQ_API_KEY;
    if (!apiKey) {
      const envPath = path.join(__dirname, '..', '.env');
      const envContent = fs.readFileSync(envPath, 'utf-8');
      for (const line of envContent.split('\n')) {
        if (line.startsWith('GROQ_API_KEY')) {
          apiKey = line.split('=', 2)[1].trim().replace(/^"|"$/g, '');
          break;
        }
      }
    }

    console.log(`\nQuery: ${query}\n`);
    const result = await ragAnswer(query, { apiKey });

    if (result.detectedCountry) {
      console.log(`[country filter auto-applied: ${result.detectedCountry}]\n`);
    }

    console.log('=== Answer ===');
    console.log(result.answer);
    console.log('\n=== Sources ===');
    result.sources.forEach((s, i) => {
      console.log(`[${i + 1}] (${s.country}) "${s.article_title}" - score=${s.score.toFixed(4)}`);
      console.log(`    ${s.article_url}`);
    });
  })().catch((err) => {
    console.error('Error:', err.message);
    process.exit(1);
  });
}
'@ | Set-Content -Encoding utf8 (Join-Path $dir "ragQuery.js")

@'
// reconcileAnnotations.js - majority-vote reconciliation of the 3-LLM annotations into
// the final gold-labeled dataset, plus an inter-annotator agreement report.
// Falls back to 2-way agreement, or flags "insufficient", for chunks with fewer than
// 3 valid annotations (due to free-tier quota issues during collection).
// Run: node scripts/reconcileAnnotations.js

const fs = require('fs');
const path = require('path');

const ANNOTATIONS_PATH = path.join(__dirname, '..', 'data', 'processed', 'annotations.json');
const CHUNKS_PATH = path.join(__dirname, '..', 'data', 'processed', 'chunks_for_annotation.json');
const OUTPUT_PATH = path.join(__dirname, '..', 'data', 'processed', 'gold_labeled_dataset.json');
const REPORT_PATH = path.join(__dirname, '..', 'data', 'processed', 'agreement_report.json');

function getValidVotes(entry) {
  const modelKeys = Object.keys(entry).filter((k) => k !== 'country' && k !== 'article_title');
  return modelKeys
    .map((k) => ({ model: k, ...entry[k] }))
    .filter((v) => v.category && !v.error && !v.parse_error && !v.invalid_category);
}

function majorityVote(votes) {
  const counts = {};
  votes.forEach((v) => {
    counts[v.category] = (counts[v.category] || 0) + 1;
  });

  const sorted = Object.entries(counts).sort((a, b) => b[1] - a[1]);
  const topCount = sorted[0][1];
  const topCategories = sorted.filter(([, count]) => count === topCount);

  if (topCategories.length === 1 && topCount > votes.length / 2) {
    return { label: topCategories[0][0], agreement: 'majority', voteCount: topCount, totalVotes: votes.length };
  }

  if (topCategories.length === 1 && votes.length === 2 && topCount === 2) {
    return { label: topCategories[0][0], agreement: 'full_2of2', voteCount: topCount, totalVotes: votes.length };
  }

  // No clear majority - break the tie using the highest-confidence vote
  const byConfidence = [...votes].sort((a, b) => (b.confidence || 0) - (a.confidence || 0));
  return {
    label: byConfidence[0].category,
    agreement: 'tiebreak_by_confidence',
    voteCount: 1,
    totalVotes: votes.length,
  };
}

function main() {
  const annotations = JSON.parse(fs.readFileSync(ANNOTATIONS_PATH, 'utf-8'));
  const chunks = JSON.parse(fs.readFileSync(CHUNKS_PATH, 'utf-8'));
  const chunkById = {};
  chunks.forEach((c) => { chunkById[c.id] = c; });

  const goldDataset = [];
  const agreementStats = { full_agreement: 0, majority: 0, full_2of2: 0, tiebreak_by_confidence: 0, insufficient: 0 };
  const pairwiseAgreement = {}; // for Fleiss'-kappa-style reporting
  let pairCount = 0;
  let pairAgreeCount = 0;

  // Reconcile every annotated chunk into one gold label
  for (const id in annotations) {
    const entry = annotations[id];
    const votes = getValidVotes(entry);
    const chunk = chunkById[id];

    if (votes.length === 0 || !chunk) {
      agreementStats.insufficient++;
      continue;
    }

    const result = majorityVote(votes);

    // Track whether ALL valid votes agreed (for "full_agreement" stat)
    const allSameCategory = votes.every((v) => v.category === votes[0].category);
    if (allSameCategory && votes.length >= 2) {
      agreementStats.full_agreement++;
    } else {
      agreementStats[result.agreement] = (agreementStats[result.agreement] || 0) + 1;
    }

    // Pairwise agreement count (for a simple agreement % metric)
    for (let i = 0; i < votes.length; i++) {
      for (let j = i + 1; j < votes.length; j++) {
        pairCount++;
        if (votes[i].category === votes[j].category) pairAgreeCount++;
      }
    }

    goldDataset.push({
      id,
      country: chunk.country,
      article_title: chunk.article_title,
      article_url: chunk.article_url,
      image_url: chunk.image_url,
      text: chunk.text,
      gold_category: result.label,
      agreement_type: allSameCategory ? 'full_agreement' : result.agreement,
      vote_count: result.voteCount,
      total_votes: result.totalVotes,
      individual_votes: votes.map((v) => ({ model: v.model, category: v.category, confidence: v.confidence, reasoning: v.reasoning })),
    });
  }

  const pairwiseAgreementPct = pairCount > 0 ? (pairAgreeCount / pairCount) * 100 : 0;

  // Category distribution in the final gold dataset
  const categoryDistribution = {};
  goldDataset.forEach((d) => {
    categoryDistribution[d.gold_category] = (categoryDistribution[d.gold_category] || 0) + 1;
  });

  // Per-country breakdown
  const countryDistribution = {};
  goldDataset.forEach((d) => {
    countryDistribution[d.country] = (countryDistribution[d.country] || 0) + 1;
  });

  const report = {
    total_chunks_processed: Object.keys(annotations).length,
    total_gold_labels: goldDataset.length,
    excluded_insufficient: agreementStats.insufficient,
    agreement_breakdown: agreementStats,
    pairwise_agreement_percent: Math.round(pairwiseAgreementPct * 100) / 100,
    category_distribution: categoryDistribution,
    country_distribution: countryDistribution,
  };

  fs.writeFileSync(OUTPUT_PATH, JSON.stringify(goldDataset, null, 2), 'utf-8');
  fs.writeFileSync(REPORT_PATH, JSON.stringify(report, null, 2), 'utf-8');

  console.log('=== Reconciliation Report ===');
  console.log(JSON.stringify(report, null, 2));
  console.log(`\nGold dataset saved to ${OUTPUT_PATH}`);
  console.log(`Agreement report saved to ${REPORT_PATH}`);
}

main();
'@ | Set-Content -Encoding utf8 (Join-Path $dir "Reconcileannotations.js")

@'
// repairAnnotations.js - re-queries only the broken rater slots in annotations.json
// (parse_error/error/invalid_category) rather than re-annotating whole chunks, using
// each slot's original model so repaired votes stay comparable to the clean ones.
// Run: node scripts/repairAnnotations.js

const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

const GROQ_API_URL = 'https://api.groq.com/openai/v1/chat/completions';

// Every rater key in annotations.json, mapped to its exact Groq model ID (confirmed
// against the live /models list)
//
// Rater keys to skip this run, set via env var (no file edit needed), e.g. when a
// model hits Groq's daily quota and would just burn time on guaranteed failures:
//   $env:SKIP_KEYS="gptoss_safeguard20b"; node repairAnnotations.js
const SKIP_KEYS = new Set(
  (process.env.SKIP_KEYS || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
);

const MODEL_BY_KEY = {
  gptoss120b: 'openai/gpt-oss-120b',
  gptoss20b: 'openai/gpt-oss-20b',
  allam7b: 'allam-2-7b',
  qwen27b: 'qwen/qwen3.8-27b',
  gptoss_safeguard20b: 'openai/gpt-oss-safeguard-20b',
};

const CATEGORIES = [
  'Ghosts and Spirits',
  'Legendary Creatures',
  'Deities and Mythological Figures',
  'Legendary and Historical Figures',
  'Place-Based Legends',
  'Fairy Tales and Fables',
  'Cultural Superstitions and Practices',
];

const SYSTEM_PROMPT = `You are annotating short folklore text passages for a research project.
Classify the passage into EXACTLY ONE of these categories:
${CATEGORIES.map((c) => `- ${c}`).join('\n')}

Respond with ONLY valid JSON, no markdown fences, no commentary:
{"category": "<one of the categories above, exact text>", "confidence": <number 0.0-1.0>, "reasoning": "<one short sentence>"}`;

const CHUNKS_PATH = path.join(__dirname, '..', 'data', 'processed', 'chunks_for_annotation.json');
const ANNOTATIONS_PATH = path.join(__dirname, '..', 'data', 'processed', 'annotations.json');

const MIN_INTERVAL_MS = {
  'openai/gpt-oss-120b': 10000,
  'openai/gpt-oss-20b': 10000,
  'openai/gpt-oss-safeguard-20b': 10000,
  'allam-2-7b': 5000,
  'qwen/qwen3.8-27b': 10000,
};

const MAX_TOKENS_BY_MODEL = {
  'openai/gpt-oss-120b': 700,
  'openai/gpt-oss-20b': 700,
  'openai/gpt-oss-safeguard-20b': 700,
  'allam-2-7b': 150,
  'qwen/qwen3.8-27b': 150,
};

const lastCallTime = {};

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForModelSlot(model) {
  const minInterval = MIN_INTERVAL_MS[model] || 5000;
  const last = lastCallTime[model] || 0;
  const elapsed = Date.now() - last;
  if (elapsed < minInterval) {
    await sleep(minInterval - elapsed);
  }
  lastCallTime[model] = Date.now();
}

function isCleanVote(v) {
  return (
    v &&
    typeof v === 'object' &&
    typeof v.category === 'string' &&
    CATEGORIES.includes(v.category) &&
    !v.error &&
    !v.parse_error &&
    !v.invalid_category
  );
}

async function callModel(model, chunkText, retries = 4) {
  await waitForModelSlot(model);

  for (let attempt = 0; attempt <= retries; attempt++) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 30000);

    let res;
    try {
      res = await fetch(GROQ_API_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${process.env.GROQ_API_KEY}`,
        },
        body: JSON.stringify({
          model,
          temperature: 0.1,
          max_tokens: MAX_TOKENS_BY_MODEL[model] || 150,
          messages: [
            { role: 'system', content: SYSTEM_PROMPT },
            { role: 'user', content: chunkText.slice(0, 1200) },
          ],
        }),
        signal: controller.signal,
      });
    } catch (err) {
      clearTimeout(timeoutId);
      const reason = err.name === 'AbortError' ? 'timed out after 30s' : `network error (${err.message})`;
      console.log(`    (${model} ${reason}, retrying...)`);
      await sleep(3000);
      continue;
    }
    clearTimeout(timeoutId);

    if (res.status === 429) {
      const waitMs = 5000 * Math.pow(2, attempt);
      console.log(`    (${model} rate limited, waiting ${waitMs / 1000}s...)`);
      await sleep(waitMs);
      continue;
    }

    if (!res.ok) {
      const errText = await res.text();
      throw new Error(`Groq error ${res.status} for ${model}: ${errText}`);
    }

    const data = await res.json();
    const raw = data.choices[0].message.content.trim();
    const cleaned = raw.replace(/^```json\s*/i, '').replace(/```\s*$/, '');

    try {
      const parsed = JSON.parse(cleaned);
      if (!CATEGORIES.includes(parsed.category)) {
        return { category: parsed.category, confidence: parsed.confidence || 0, reasoning: parsed.reasoning || '', invalid_category: true };
      }
      return parsed;
    } catch (err) {
      return { parse_error: true, raw_response: raw };
    }
  }

  throw new Error(`Too many retries for ${model}`);
}

function loadJSON(p) {
  return JSON.parse(fs.readFileSync(p, 'utf-8'));
}

function saveAnnotations(annotations) {
  fs.writeFileSync(ANNOTATIONS_PATH, JSON.stringify(annotations, null, 2), 'utf-8');
}

async function main() {
  if (!process.env.GROQ_API_KEY) {
    console.error('GROQ_API_KEY not found in .env - aborting.');
    process.exit(1);
  }

  const chunks = loadJSON(CHUNKS_PATH);
  const chunkById = {};
  chunks.forEach((c) => {
    chunkById[c.id] = c;
  });

  const annotations = loadJSON(ANNOTATIONS_PATH);
  const chunkIds = Object.keys(annotations);
  console.log(`Loaded ${chunkIds.length} chunks from annotations.json`);
  if (SKIP_KEYS.size > 0) {
    console.log(`Skipping these rater keys this run: ${[...SKIP_KEYS].join(', ')}`);
  }

  // Count broken slots before doing any work, for a clear before/after
  let totalBrokenSlots = 0;
  const brokenByKey = {};
  for (const id of chunkIds) {
    const entry = annotations[id];
    const raterKeys = Object.keys(entry).filter((k) => k !== 'country' && k !== 'article_title');
    for (const key of raterKeys) {
      if (!isCleanVote(entry[key])) {
        totalBrokenSlots++;
        brokenByKey[key] = (brokenByKey[key] || 0) + 1;
      }
    }
  }
  console.log(`Found ${totalBrokenSlots} broken rater slots to repair.`);
  console.log(`Breakdown by rater key: ${JSON.stringify(brokenByKey)}`);

  let repaired = 0;
  let stillBroken = 0;
  let noChunkText = 0;
  let unknownKey = 0;
  let processedSinceSave = 0;
  const SAVE_EVERY = 10;

  // Re-query only the broken slots, chunk by chunk
  for (const id of chunkIds) {
    const entry = annotations[id];
    const chunk = chunkById[id];
    const raterKeys = Object.keys(entry).filter((k) => k !== 'country' && k !== 'article_title');

    let touchedThisChunk = false;

    for (const key of raterKeys) {
      if (isCleanVote(entry[key])) continue;
      if (SKIP_KEYS.has(key)) continue;

      if (!chunk || !chunk.text) {
        noChunkText++;
        continue;
      }

      const model = MODEL_BY_KEY[key];
      if (!model) {
        console.warn(`  [${id}/${key}] unknown rater key, no model mapping - skipping.`);
        unknownKey++;
        continue;
      }

      try {
        const result = await callModel(model, chunk.text);
        entry[key] = result;
        touchedThisChunk = true;
        if (isCleanVote(result)) {
          repaired++;
        } else {
          stillBroken++;
          console.log(`  [${id}/${key}] still broken after retry (${result.parse_error ? 'parse_error' : result.invalid_category ? 'invalid_category' : 'unknown'}).`);
        }
      } catch (err) {
        console.error(`  [${id}/${key}] ERROR: ${err.message}`);
        stillBroken++;
      }
    }

    if (touchedThisChunk) {
      processedSinceSave++;
      if (processedSinceSave >= SAVE_EVERY) {
        saveAnnotations(annotations);
        processedSinceSave = 0;
        console.log(`  Saved progress: ${repaired} repaired, ${stillBroken} still broken so far.`);
      }
    }
  }

  saveAnnotations(annotations);

  console.log('\n=== Repair Summary ===');
  console.log(`Total broken slots found: ${totalBrokenSlots}`);
  console.log(`Repaired: ${repaired}`);
  console.log(`Still broken after retry: ${stillBroken}`);
  console.log(`Skipped (no chunk text found): ${noChunkText}`);
  console.log(`Skipped (unknown rater key): ${unknownKey}`);
  console.log(`\nSaved back to ${ANNOTATIONS_PATH}`);
  console.log('Next: re-run node scripts/reconcileAnnotations.js, then python scripts/ml/agreement_analysis.py');
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
'@ | Set-Content -Encoding utf8 (Join-Path $dir "repairAnnotations.js")

Write-Output "All 15 JS files written to $dir"