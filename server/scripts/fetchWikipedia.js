// fetchWikipedia.js - pulls pages from given Wikipedia categories, fetches full article
// text + lead image for each, saves raw JSON per country for review before chunking
// Run: node scripts/fetchWikipedia.js

const fs = require('fs');
const path = require('path');

const WIKI_API = 'https://en.wikipedia.org/w/api.php';

// Wikimedia's API throttles requests without a descriptive User-Agent much more aggressively
const USER_AGENT = 'FolkloreRAGStudentProject/1.0 (Kennesaw State University course project; contact via KSU email)';

// Pulls from TWO categories per country where needed to get both general folklore/legends
// AND specific legendary creatures (a single category can miss entries)
const CATEGORY_GROUPS = {
  // Japan already fetched and saved successfully - left out here to avoid re-fetching
  // and re-risking a rate-limit block. Re-add only if you need to refresh it.
  // Japan: [
  //   'Category:Japanese urban legends',
  //   'Category:Japanese legendary creatures',
  //   'Category:YÃ…kai',
  //   'Category:Japanese ghosts',
  //   'Category:Japanese dragons',
  //   'Category:Japanese demons',
  //   'Category:Japanese giants',
  //   'Category:Japanese folklore',
  // ],
  India: [
    'Category:Indian folklore',
    'Category:Indian mythology',
    'Category:Legendary creatures of India',
  ],
  China: [
    'Category:Chinese folklore',
    'Category:Chinese mythology',
    'Category:Chinese dragons',
    'Category:Legendary creatures of China',
  ],
  Philippines: [
    'Category:Philippine urban legends',
    'Category:Philippine legendary creatures',
    'Category:Philippine mythology',
  ],
  Indonesia: [
    'Category:Indonesian folklore',
    'Category:Indonesian legendary creatures',
  ],
};

// Titles known from Wikipedia's "Folklore of Indonesia" genre lists that the categories
// above missed (e.g. Kuntilanak, Sundel Bolong). Fetched directly by title; missing
// articles are silently skipped, redirects resolve to their target.
const EXTRA_TITLES = {
  Indonesia: [
    'Kuntilanak', 'Wewe Gombel', 'Sundel Bolong', 'Calon Arang', 'Kuyang',
    'Orang Ikan', 'Kisut',
    'Malin Kundang', 'Sangkuriang', 'Rara Jonggrang', 'Aji Saka',
    'Banyuwangi', 'Sulanjana', 'Watu Gunung', 'Lanun',
    'Ande Ande Lumut', 'Jaka Tarub', 'Timun Mas', 'Roro Mendut',
    'Ciung Wanara', 'Damarwulan', 'Ken Arok and Ken Dedes',
    'Mundinglaya Dikusumah', 'Pangeran Katak', 'Panji Semirang',
    'Siliwangi', 'Si Pitung', 'Gurabesi', 'Leungli',
    // Mined from the "Folklore of Indonesia" regional breakdown (Sumatra/Sulawesi/Sunda)
    'Hang Tuah', 'Si Pahit Lidah', 'Putri Hijau', 'Sawerigading',
    'Nini Anteh', 'Si Kebayan', 'Telaga Warna', 'Situ Bagendit',
  ],
};

// General-context pages (themes, genres, history) - not individual legends, so kept
// separate rather than given a legend profile page on the site
const BACKGROUND_TITLES = {
  Indonesia: ['Folklore of Indonesia'],
};

// Native language per country, for fetching a second source article for enrichment input
const NATIVE_LANG = {
  Japan: 'ja',
  India: 'hi',
  China: 'zh',
  Philippines: 'tl',
  Indonesia: 'id',
};

const OUTPUT_DIR = path.join(__dirname, '..', 'data', 'raw');

// Temporarily off to cut request volume while the main English-text pull goes through cleanly
const FETCH_NATIVE_LANG = false;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function wikiFetch(params, retries = 5) {
  const url = new URL(WIKI_API);
  url.search = new URLSearchParams({
    format: 'json',
    origin: '*',
    ...params,
  }).toString();

  for (let attempt = 0; attempt <= retries; attempt++) {
    const res = await fetch(url, { headers: { 'User-Agent': USER_AGENT } });

    if (res.status === 429 || res.status === 403) {
      const waitMs = 10000 * Math.pow(2, attempt); // 10s, 20s, 40s, 80s, 160s
      console.log(`    (blocked with ${res.status}, waiting ${waitMs / 1000}s...)`);
      await sleep(waitMs);
      continue;
    }

    if (!res.ok) {
      throw new Error(`Wikipedia API error: ${res.status} ${res.statusText}`);
    }
    return res.json();
  }

  throw new Error('Wikipedia API error: too many retries, giving up');
}

// Fetch from a specific language's Wikipedia (e.g. id.wikipedia.org)
async function wikiFetchLang(lang, params, retries = 5) {
  const url = new URL(`https://${lang}.wikipedia.org/w/api.php`);
  url.search = new URLSearchParams({
    format: 'json',
    origin: '*',
    ...params,
  }).toString();

  for (let attempt = 0; attempt <= retries; attempt++) {
    const res = await fetch(url, { headers: { 'User-Agent': USER_AGENT } });

    if (res.status === 429) {
      const waitMs = 3000 * Math.pow(2, attempt);
      await sleep(waitMs);
      continue;
    }

    if (!res.ok) return null;
    return res.json();
  }

  return null;
}

// Given an English title, find the equivalent article in another language via langlinks,
// then fetch its plain-text extract. Returns null if no equivalent article exists.
async function getNativeText(englishTitle, lang) {
  try {
    const linkData = await wikiFetch({
      action: 'query',
      titles: englishTitle,
      prop: 'langlinks',
      lllang: lang,
      redirects: '1',
    });

    const pages = linkData.query.pages;
    let nativeTitle = null;
    for (const pageId in pages) {
      const links = pages[pageId].langlinks;
      if (links && links.length > 0) nativeTitle = links[0]['*'];
    }
    if (!nativeTitle) return null;

    const textData = await wikiFetchLang(lang, {
      action: 'query',
      titles: nativeTitle,
      prop: 'extracts',
      explaintext: '1',
      redirects: '1',
    });
    if (!textData) return null;

    const nPages = textData.query.pages;
    for (const pageId in nPages) {
      if (nPages[pageId].missing !== undefined) continue;
      return { title: nativeTitle, text: nPages[pageId].extract || '' };
    }
    return null;
  } catch (err) {
    return null;
  }
}

// Get all page titles under a category (paginated; subcategories are skipped for now)
async function getCategoryMembers(category) {
  let members = [];
  let cmcontinue = undefined;

  do {
    const data = await wikiFetch({
      action: 'query',
      list: 'categorymembers',
      cmtitle: category,
      cmlimit: '100',
      cmtype: 'page', // exclude subcategories; handled separately if needed
      ...(cmcontinue ? { cmcontinue } : {}),
    });

    members = members.concat(data.query.categorymembers.map((m) => m.title));
    cmcontinue = data.continue ? data.continue.cmcontinue : undefined;
  } while (cmcontinue);

  return members;
}

// Fetch full plain-text extract + lead image for a list of titles, plus a native-language
// extract when available. Resumable: skips titles already attempted, saves every 15.
async function getPageDetails(titles, nativeLang, country) {
  const outPath = path.join(OUTPUT_DIR, `${country.toLowerCase()}.json`);
  const progressPath = path.join(OUTPUT_DIR, `${country.toLowerCase()}_attempted.json`);

  let results = fs.existsSync(outPath) ? JSON.parse(fs.readFileSync(outPath, 'utf-8')) : [];
  let attempted = fs.existsSync(progressPath) ? new Set(JSON.parse(fs.readFileSync(progressPath, 'utf-8'))) : new Set();

  const remaining = titles.filter((t) => !attempted.has(t));
  console.log(`  Resuming: ${attempted.size} already attempted, ${remaining.length} remaining`);

  for (let i = 0; i < remaining.length; i++) {
    const title = remaining[i];

    const data = await wikiFetch({
      action: 'query',
      prop: 'extracts|pageimages|info',
      explaintext: '1',
      piprop: 'original',
      inprop: 'url',
      redirects: '1',
      titles: title,
    });

    const pages = data.query.pages;
    for (const pageId in pages) {
      const page = pages[pageId];
      if (page.missing !== undefined) continue;

      let native = null;
      if (nativeLang) {
        native = await getNativeText(page.title, nativeLang);
      }

      results.push({
        title: page.title,
        url: page.fullurl,
        image_url: page.original ? page.original.source : null,
        text: page.extract || '',
        native_lang: nativeLang || null,
        native_title: native ? native.title : null,
        native_text: native ? native.text : null,
      });
    }

    attempted.add(title);

    if ((i + 1) % 15 === 0 || i === remaining.length - 1) {
      fs.writeFileSync(outPath, JSON.stringify(results, null, 2), 'utf-8');
      fs.writeFileSync(progressPath, JSON.stringify([...attempted], null, 2), 'utf-8');
      console.log(`    fetched ${i + 1}/${remaining.length} (saved progress)`);
    }

    await sleep(1500); // slower pacing after hitting a 403 robot-policy block
  }

  return results;
}

async function main() {
  if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  }

  for (const [country, categories] of Object.entries(CATEGORY_GROUPS)) {
    console.log(`\n=== ${country} ===`);

    let allTitles = [];
    for (const category of categories) {
      const titles = await getCategoryMembers(category);
      console.log(`  ${category}: ${titles.length} pages`);
      allTitles = allTitles.concat(titles);
    }

    const extras = EXTRA_TITLES[country] || [];
    console.log(`  Extra hand-picked titles: ${extras.length}`);
    allTitles = allTitles.concat(extras);

    // Dedupe titles across categories/extras (some pages appear in both)
    const uniqueTitles = [...new Set(allTitles)];
    console.log(`Total unique input titles: ${uniqueTitles.length}`);

    const pages = await getPageDetails(uniqueTitles, FETCH_NATIVE_LANG ? NATIVE_LANG[country] : null, country);

    // Redirects can resolve two different input titles to the same article - dedupe by final title
    const seen = new Set();
    const dedupedPages = pages.filter((p) => {
      if (seen.has(p.title)) return false;
      seen.add(p.title);
      return true;
    });

    console.log(`Resolved to ${dedupedPages.length} unique articles:`);
    dedupedPages.forEach((p) => console.log(`  - ${p.title}`));

    const outPath = path.join(OUTPUT_DIR, `${country.toLowerCase()}.json`);
    fs.writeFileSync(outPath, JSON.stringify(dedupedPages, null, 2), 'utf-8');
    console.log(`Saved ${dedupedPages.length} articles to ${outPath}`);

    // Fetch and save background documents separately
    const backgroundTitles = BACKGROUND_TITLES[country] || [];
    if (backgroundTitles.length > 0) {
      const bgPages = await getPageDetails(backgroundTitles, null, `${country}_background`);
      const bgOutPath = path.join(OUTPUT_DIR, `${country.toLowerCase()}_background.json`);
      fs.writeFileSync(bgOutPath, JSON.stringify(bgPages, null, 2), 'utf-8');
      console.log(`Saved ${bgPages.length} background documents to ${bgOutPath}`);
    }
  }

  console.log('\nDone. Review the title lists above and the JSON files before proceeding to chunking/embedding.');
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
