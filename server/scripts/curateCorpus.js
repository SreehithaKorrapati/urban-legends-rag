// curateCorpus.js - filters raw per-country JSON (from fetchWikipedia.js) down to the
// curated keep-list, saves to data/curated/{country}.json
// Run: node scripts/curateCorpus.js

const fs = require('fs');
const path = require('path');

const RAW_DIR = path.join(__dirname, '..', 'data', 'raw');
const CURATED_DIR = path.join(__dirname, '..', 'data', 'curated');

// Titles to exclude per country. Everything NOT in this list is kept.
// Japan: category was already clean, only the overview page is excluded.
const EXCLUDE = {
  indonesia: [
    'Folklore of Indonesia',
    'Malay folklore',
    'Ghosts in Malay culture',
    'UFO sightings in Indonesia',
    'Piracy',
    'Banyuwangi (town)',
  ],
};

function curateCountry(country) {
  const rawPath = path.join(RAW_DIR, `${country}.json`);
  if (!fs.existsSync(rawPath)) {
    console.warn(`Skipping ${country}: raw file not found at ${rawPath}`);
    return;
  }

  const raw = JSON.parse(fs.readFileSync(rawPath, 'utf-8'));
  const excludeSet = new Set(EXCLUDE[country] || []);

  const curated = raw.filter((page) => !excludeSet.has(page.title));

  if (!fs.existsSync(CURATED_DIR)) {
    fs.mkdirSync(CURATED_DIR, { recursive: true });
  }

  const outPath = path.join(CURATED_DIR, `${country}.json`);
  fs.writeFileSync(outPath, JSON.stringify(curated, null, 2), 'utf-8');

  console.log(`${country}: kept ${curated.length} of ${raw.length} pages -> ${outPath}`);
  curated.forEach((p) => console.log(`  - ${p.title}`));
}

function main() {
  curateCountry('indonesia');
}

main();
