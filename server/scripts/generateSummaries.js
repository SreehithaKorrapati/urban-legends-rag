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
