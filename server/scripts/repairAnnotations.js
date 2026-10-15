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
