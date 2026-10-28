// ragFaithFill.js - scores the faithfulness of the questions that rag_eval_checkpoint.json
// has with faithfulness = null, using the same judge prompt and model as ragEval.js.
// Retrieval ranks are not changed. Results go to rag_faithfulness_fill.json (resumable),
// including each answer and the judge reply so that a sample can be checked by hand.
// Run from the server folder:  node scripts/ragFaithFill.js
// Needs GROQ_API_KEY in the environment or in server/.env, same as ragEval.js.

const fs = require('fs');
const path = require('path');
const { retrieve, generateAnswer } = require('./ragQuery');

const RES = path.join(__dirname, '..', 'data', 'processed', 'results');
const CHECKPOINT = path.join(RES, 'rag_eval_checkpoint.json');
const OUT = path.join(RES, 'rag_faithfulness_fill.json');
const GROQ_API_URL = 'https://api.groq.com/openai/v1/chat/completions';
const JUDGE_MODEL = 'qwen/qwen3.8-27b';
const GAP_MS = 16000;

function loadApiKey() {
  if (process.env.GROQ_API_KEY) return process.env.GROQ_API_KEY;
  const envPath = path.join(__dirname, '..', '.env');
  for (const line of fs.readFileSync(envPath, 'utf-8').split('\n')) {
    if (line.startsWith('GROQ_API_KEY')) return line.split('=', 2)[1].trim().replace(/^"|"$/g, '');
  }
  throw new Error('GROQ_API_KEY not found in env or .env');
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function judge(question, answer, context, apiKey) {
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
      max_tokens: 400,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: userContent },
      ],
    }),
  });
  if (res.status === 429) throw new Error('RATE_LIMITED');
  if (!res.ok) throw new Error(`Groq error ${res.status}: ${await res.text()}`);
  const data = await res.json();
  const raw = (data.choices?.[0]?.message?.content || '').trim();
  const cleaned = raw.replace(/<think>[\s\S]*?<\/think>/g, '').trim();
  const m = cleaned.match(/\b(0\.5|1|0)\b/);
  return { raw, score: m ? parseFloat(m[1]) : null };
}

async function main() {
  const apiKey = loadApiKey();
  const checkpoint = JSON.parse(fs.readFileSync(CHECKPOINT, 'utf-8'));
  const done = fs.existsSync(OUT) ? JSON.parse(fs.readFileSync(OUT, 'utf-8')) : {};
  const todo = checkpoint.map((q, i) => [q, i]).filter(([q, i]) => q.faithfulness === null && !(i in done && done[i].score !== null));
  console.log(`${todo.length} questions to score.\n`);

  let n = 0;
  for (const [q, i] of todo) {
    try {
      const results = await retrieve(q.question, 10, q.detected_country);
      const top = results.slice(0, 5);
      const context = top.map((c, j) => `[${j + 1}] (${c.country} - "${c.article_title}")\n${c.text}`).join('\n\n');
      const answer = await generateAnswer(q.question, top, apiKey);
      await sleep(GAP_MS);
      const j = await judge(q.question, answer, context, apiKey);
      await sleep(GAP_MS);
      done[i] = { question: q.question, answer, judge_reply: j.raw, score: j.score };
      console.log(`  [${i + 1}/${checkpoint.length}] faithfulness=${j.score}`);
    } catch (err) {
      if (err.message === 'RATE_LIMITED' || err.message.includes('429') || err.message.includes('rate_limit')) {
        console.log('  rate limited, waiting 30s...');
        await sleep(30000);
        todo.push([q, i]); // try this question again at the end
        continue;
      }
      console.warn(`  question ${i + 1} failed: ${err.message}`);
      done[i] = { question: q.question, error: err.message, score: null };
    }
    n++;
    if (n % 5 === 0) fs.writeFileSync(OUT, JSON.stringify(done, null, 1), 'utf-8');
  }
  fs.writeFileSync(OUT, JSON.stringify(done, null, 1), 'utf-8');

  const old = checkpoint.map((q) => q.faithfulness).filter((f) => f !== null);
  const added = Object.values(done).map((d) => d.score).filter((s) => s !== null);
  const all = old.concat(added);
  const count = (arr, v) => arr.filter((s) => s === v).length;
  console.log('\n=== Faithfulness ===');
  console.log(`Earlier ${old.length} answers: mean ${(old.reduce((a, b) => a + b, 0) / old.length).toFixed(3)}`);
  if (added.length) {
    console.log(`New ${added.length} answers: mean ${(added.reduce((a, b) => a + b, 0) / added.length).toFixed(3)}  (1: ${count(added, 1)}, 0.5: ${count(added, 0.5)}, 0: ${count(added, 0)})`);
    console.log(`All ${all.length} answers: mean ${(all.reduce((a, b) => a + b, 0) / all.length).toFixed(3)}, fully supported ${(100 * count(all, 1) / all.length).toFixed(1)}%`);
  }
  const failed = Object.values(done).filter((d) => d.score === null).length;
  console.log(`Failed or unreadable: ${failed}`);
  console.log(`Saved to ${OUT}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
