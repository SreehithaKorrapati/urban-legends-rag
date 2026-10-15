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
