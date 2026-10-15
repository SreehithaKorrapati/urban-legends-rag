$serverDir = "C:\Users\dell\urban-legends-rag\server"
$routesDir = "C:\Users\dell\urban-legends-rag\server\routes"

@'
// index.js - Express entry point for the MERN backend; connects to MongoDB Atlas,
// then serves the RAG chat route and the curated folklore corpus for the encyclopedia pages
// Run: npm run dev (nodemon) or node index.js

require('dotenv').config();
const express = require('express');
const mongoose = require('mongoose');
const cors = require('cors');

const chatRoutes = require('./routes/chat');
const legendsRoutes = require('./routes/legends');

const app = express();
app.use(cors());
app.use(express.json());

const PORT = process.env.PORT || 5000;

// Health check route
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', message: 'Server is running' });
});

app.use('/api/chat', chatRoutes);
app.use('/api/legends', legendsRoutes);

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: err.message || 'Internal server error' });
});

// Connect to MongoDB, then start server
mongoose.connect(process.env.MONGODB_URI)
  .then(() => {
    console.log('Connected to MongoDB Atlas');
    app.listen(PORT, () => {
      console.log(`Server running on http://localhost:${PORT}`);
    });
  })
  .catch((err) => {
    console.error('MongoDB connection error:', err.message);
  });
'@ | Set-Content -Encoding utf8 (Join-Path $serverDir "index.js")

@'
// chat.js - POST /api/chat, wraps the RAG pipeline (scripts/ragQuery.js)
// Body: { question, country? } (country overrides auto-detection)
// Response: { answer, sources: [{ country, article_title, article_url, score }] }

const express = require('express');
const router = express.Router();
const { ragAnswer } = require('../scripts/ragQuery');

router.post('/', async (req, res, next) => {
  try {
    const { question, country } = req.body;

    if (!question || typeof question !== 'string' || !question.trim()) {
      return res.status(400).json({ error: 'Missing required field: question (non-empty string)' });
    }

    const result = await ragAnswer(question.trim(), { country: country || null });
    res.json(result);
  } catch (err) {
    next(err);
  }
});

module.exports = router;
'@ | Set-Content -Encoding utf8 (Join-Path $routesDir "chat.js")

@'
// legends.js - serves the curated folklore corpus for the encyclopedia pages
// GET /api/legends/:country                -> list (title/url/image_url only, no full text)
// GET /api/legends/:country?search=&category= -> list filtered by title/text search or category
// GET /api/legends/:country/:title          -> full article + related legends + NER entities
// No database - reads curated JSON straight off disk, cached in memory per country

const express = require('express');
const router = express.Router();
const fs = require('fs');
const path = require('path');

const CURATED_DIR = path.join(__dirname, '..', 'data', 'curated');
const RELATED_PATH = path.join(__dirname, '..', 'data', 'processed', 'related_legends.json');
const ENTITIES_PATH = path.join(__dirname, '..', 'data', 'processed', 'entities.json');
const VALID_COUNTRIES = ['japan', 'china', 'india', 'philippines', 'indonesia'];

const cache = {};

let relatedLookup = {};
try {
  relatedLookup = JSON.parse(fs.readFileSync(RELATED_PATH, 'utf-8'));
  console.log(`Loaded embedding-based related legends for ${Object.keys(relatedLookup).length} articles.`);
} catch {
  console.warn('related_legends.json not found - falling back to keyword-based related legends.');
}

let entitiesLookup = {};
try {
  entitiesLookup = JSON.parse(fs.readFileSync(ENTITIES_PATH, 'utf-8'));
  console.log(`Loaded NER entities for ${Object.keys(entitiesLookup).length} articles.`);
} catch {
  console.warn('entities.json not found - legend pages will have no entity tags.');
}

// Lightweight keyword-based category tagging (used for list filtering and as the
// related-legends fallback when no embedding-based lookup is available)
const CATEGORY_KEYWORDS = {
  Ghost: ['ghost', 'spirit', 'yurei', 'phantom', 'specter', 'spectre', 'haunt', 'apparition'],
  Creature: ['creature', 'monster', 'demon', 'beast', 'yokai', 'cryptid', 'shapeshifter'],
  'Deity & Myth': ['god', 'goddess', 'deity', 'shrine', 'temple', 'myth', 'mythology'],
  Curse: ['curse', 'cursed', 'hex', 'jinx'],
  'Death & Tragedy': ['death', 'died', 'suicide', 'murder', 'killed', 'tragedy'],
  'Urban Legend': ['urban legend', 'rumor', 'rumour', 'modern legend'],
  'Folk Tale': ['folktale', 'folk tale', 'fable', 'tale of', 'once upon'],
};

function detectCategories(text) {
  const lower = (text || '').toLowerCase();
  const matches = Object.entries(CATEGORY_KEYWORDS)
    .filter(([, keywords]) => keywords.some((k) => lower.includes(k)))
    .map(([category]) => category);
  return matches.length ? matches : ['Uncategorized'];
}

// Load + tag + cache one country's curated articles
function loadCountry(country) {
  if (cache[country]) return cache[country];
  const filePath = path.join(CURATED_DIR, `${country}.json`);
  if (!fs.existsSync(filePath)) return null;
  const data = JSON.parse(fs.readFileSync(filePath, 'utf-8'));
  const withCategories = data.map((a) => ({ ...a, categories: detectCategories(a.text) }));
  cache[country] = withCategories;
  return withCategories;
}

router.get('/:country', (req, res) => {
  const country = req.params.country.toLowerCase();
  if (!VALID_COUNTRIES.includes(country)) {
    return res.status(404).json({ error: `Unknown country "${country}". Valid: ${VALID_COUNTRIES.join(', ')}` });
  }

  const articles = loadCountry(country);
  if (!articles) {
    return res.status(404).json({ error: `No curated data found for ${country}` });
  }

  const { search, category } = req.query;
  let results = articles;

  if (search) {
    const q = search.toLowerCase();
    results = results.filter((a) => a.title.toLowerCase().includes(q) || (a.text && a.text.toLowerCase().includes(q)));
  }

  if (category) {
    results = results.filter((a) => a.categories.includes(category));
  }

  // Strip full text for the list view - keeps the payload light for an index page
  res.json(
    results.map((a) => ({
      title: a.title,
      url: a.url,
      image_url: a.image_url,
      categories: a.categories,
      country,
    }))
  );
});

router.get('/:country/:title', (req, res) => {
  const country = req.params.country.toLowerCase();
  if (!VALID_COUNTRIES.includes(country)) {
    return res.status(404).json({ error: `Unknown country "${country}". Valid: ${VALID_COUNTRIES.join(', ')}` });
  }

  const articles = loadCountry(country);
  if (!articles) {
    return res.status(404).json({ error: `No curated data found for ${country}` });
  }

  const requestedTitle = decodeURIComponent(req.params.title).toLowerCase();
  const article = articles.find((a) => a.title.toLowerCase() === requestedTitle);

  if (!article) {
    return res.status(404).json({ error: `No article titled "${req.params.title}" found in ${country}` });
  }

  // Related legends: prefer the embedding-based lookup, fall back to same-category
  // keyword matching (or just any other article) if that's not available
  const lookupKey = `${country}/${article.title}`;
  let related;

  if (relatedLookup[lookupKey]) {
    related = relatedLookup[lookupKey].map((r) => {
      const match = articles.find((a) => a.title === r.title);
      return {
        title: r.title,
        image_url: match ? match.image_url : null,
        score: r.score,
      };
    });
  } else {
    const sameCategory = articles.filter(
      (a) => a.title !== article.title && a.categories.some((c) => article.categories.includes(c))
    );
    const pool = sameCategory.length > 0 ? sameCategory : articles.filter((a) => a.title !== article.title);
    related = [...pool]
      .sort(() => Math.random() - 0.5)
      .slice(0, 4)
      .map((a) => ({ title: a.title, image_url: a.image_url }));
  }

  const entities = entitiesLookup[lookupKey] || null;

  res.json({ ...article, country, related, entities });
});

module.exports = router;
'@ | Set-Content -Encoding utf8 (Join-Path $routesDir "legends.js")

Write-Output "All 3 core server files written"