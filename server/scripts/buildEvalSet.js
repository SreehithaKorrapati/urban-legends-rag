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
