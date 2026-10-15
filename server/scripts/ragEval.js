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
