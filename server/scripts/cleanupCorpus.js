// cleanupCorpus.js - first-pass cleanup across all 5 countries: drops generic/admin pages,
// hand-picked off-topic entries, and cross-country duplicates (kept under the first country
// in COUNTRY_PRIORITY order). Not fine-grained curation, just removes clear noise and dupes.
// Run: node scripts/cleanupCorpus.js

const fs = require('fs');
const path = require('path');

const RAW_DIR = path.join(__dirname, '..', 'data', 'raw');
const CURATED_DIR = path.join(__dirname, '..', 'data', 'curated');

const COUNTRY_PRIORITY = ['japan', 'china', 'india', 'philippines', 'indonesia'];

// Generic/administrative page patterns to drop everywhere
const GENERIC_PATTERNS = [
  /^List of /i,
  /^Template:/i,
  /^Category:/i,
];

// Country-level overview pages (about the folklore tradition itself, not a specific legend)
const OVERVIEW_TITLES = new Set([
  'Japanese folklore', 'Japanese folktales', 'Chinese folklore', 'Chinese mythology',
  'Chinese dragon', 'Indian folklore', 'Folklore of India', 'Philippine mythology',
  'Folklore of Indonesia', 'Malay folklore', 'Ghosts in Malay culture',
  'Punjabi folklore', 'Meitei folklore', 'Telugu folk literature',
  'Philippine folk literature', 'Philippine epic poetry',
]);

// Hand-picked off-topic entries found during review
const OFF_TOPIC = new Set([
  'Siopao', 'Robinsons Galleria', 'Judiel Nieva', 'Spoliarium (Eraserheads song)',
  'List of Filipino inventions and discoveries', 'Piracy', 'UFO sightings in Indonesia',
  'UFO sightings in China', 'UFO sightings in India', 'Banyuwangi (town)',
  'The Twelve Dancing Princesses', 'The Water of Life (German fairy tale)',
  'Customs and etiquette in Indian dining', 'Goan soup', 'Saraca asoca',
  'Reinwardtia', 'Gynostemma pentaphyllum', "May you live in interesting times",
  'Egg balancing', 'Southern Shaolin Monastery', 'Southern Dragon kung fu',
  'Zhou Tong (archer)', 'Wong Kei-ying', 'Hong Xiguan', 'Fong Sai-yuk',
  'Ten Tigers of Canton', '18 Warriors of Sui-Tang Transition',
  'Red Lanterns (Boxer Uprising)', 'Imperial examination in Chinese mythology',
  'LGBTQ themes in Chinese mythology', 'Timeline of Chinese mythology',
  'Adivasi Lok Kala Academy', 'Karadi Tales', 'Bagani (TV series)',
  'The Mythology Class', 'Maddock Horror Comedy Universe',
]);

function isGeneric(title) {
  return GENERIC_PATTERNS.some((pattern) => pattern.test(title));
}

function main() {
  if (!fs.existsSync(CURATED_DIR)) {
    fs.mkdirSync(CURATED_DIR, { recursive: true });
  }

  const seenGlobally = new Set();
  const summary = [];

  // Filter each country's raw pages, country by country, in priority order
  for (const country of COUNTRY_PRIORITY) {
    const rawPath = path.join(RAW_DIR, `${country}.json`);
    if (!fs.existsSync(rawPath)) {
      console.warn(`Skipping ${country}: no raw file found`);
      continue;
    }

    const raw = JSON.parse(fs.readFileSync(rawPath, 'utf-8'));
    const keptOverview = [];
    const curated = raw.filter((page) => {
      if (isGeneric(page.title)) return false;
      if (OFF_TOPIC.has(page.title)) return false;
      if (OVERVIEW_TITLES.has(page.title)) {
        keptOverview.push(page.title);
        return false;
      }
      if (seenGlobally.has(page.title)) return false; // cross-country dedupe
      seenGlobally.add(page.title);
      return true;
    });

    const outPath = path.join(CURATED_DIR, `${country}.json`);
    fs.writeFileSync(outPath, JSON.stringify(curated, null, 2), 'utf-8');

    summary.push({ country, raw: raw.length, curated: curated.length, overviewDropped: keptOverview.length });
    console.log(`${country}: ${raw.length} raw -> ${curated.length} curated (dropped ${keptOverview.length} overview pages)`);
  }

  const total = summary.reduce((sum, s) => sum + s.curated, 0);
  console.log(`\nTotal curated articles across all countries: ${total}`);
  console.log('\nReview data/curated/*.json - if this total needs to grow toward 1000,');
  console.log('we can loosen the OFF_TOPIC/OVERVIEW exclusions or add more categories.');
}

main();
