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
