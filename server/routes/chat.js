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
