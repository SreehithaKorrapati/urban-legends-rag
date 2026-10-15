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
