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
