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
