import { useState, useRef, useEffect } from 'react';
import { Link } from 'react-router-dom';
import { askChat, COUNTRIES } from '../api';

const HISTORY_KEY = 'folklore_chat_history_v1';

function loadHistory() {
  try {
    const raw = localStorage.getItem(HISTORY_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

function saveHistory(messages) {
  try {
    localStorage.setItem(HISTORY_KEY, JSON.stringify(messages));
  } catch {}
}

const DEFAULT_MESSAGES = [
  { role: 'bot', text: 'Ask me about any legend, ghost, or myth in the archive.' },
];

function ChatWidget() {
  const [open, setOpen] = useState(false);
  const [messages, setMessages] = useState(() => loadHistory() || DEFAULT_MESSAGES);
  const [input, setInput] = useState('');
  const [country, setCountry] = useState('');
  const [sending, setSending] = useState(false);
  const scrollRef = useRef(null);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: 'smooth' });
  }, [messages, open]);

  useEffect(() => {
    saveHistory(messages);
  }, [messages]);

  async function handleSend(e) {
    e.preventDefault();
    const question = input.trim();
    if (!question || sending) return;

    setMessages((prev) => [...prev, { role: 'user', text: question }]);
    setInput('');
    setSending(true);

    try {
      const result = await askChat(question, country || null);
      setMessages((prev) => [
        ...prev,
        {
          role: 'bot',
          text: result.answer,
          sources: result.sources || [],
          detectedCountry: result.detectedCountry,
        },
      ]);
    } catch (err) {
      setMessages((prev) => [
        ...prev,
        { role: 'bot', text: `Something went wrong: ${err.message}` },
      ]);
    } finally {
      setSending(false);
    }
  }

  function handleClear() {
    setMessages(DEFAULT_MESSAGES);
  }

  return (
    <div className={`chat-widget ${open ? 'open' : ''}`}>
      {open && (
        <div className="chat-panel">
          <div className="chat-panel-header">
            <span>Folklore Assistant</span>
            <div className="chat-panel-header-actions">
              <button onClick={handleClear} className="chat-clear-btn" title="Clear history">
                Clear
              </button>
              <button onClick={() => setOpen(false)} aria-label="Close chat">
                x
              </button>
            </div>
          </div>

          <div className="chat-country-row">
            <label htmlFor="chat-country-select">Scope:</label>
            <select
              id="chat-country-select"
              value={country}
              onChange={(e) => setCountry(e.target.value)}
            >
              <option value="">Auto-detect</option>
              {COUNTRIES.map(({ slug, label }) => (
                <option key={slug} value={slug}>
                  {label}
                </option>
              ))}
            </select>
          </div>

          <div className="chat-messages" ref={scrollRef}>
            {messages.map((m, i) => (
              <div key={i} className={`chat-message ${m.role}`}>
                <p>{m.text}</p>
                {m.sources && m.sources.length > 0 && (
                  <div className="chat-sources">
                    {m.sources.slice(0, 3).map((s, j) => (
                      <Link
                        key={j}
                        to={`/${s.country}/${encodeURIComponent(s.article_title)}`}
                        className="chat-source-link"
                        onClick={() => setOpen(false)}
                      >
                        {s.article_title} ({s.country})
                      </Link>
                    ))}
                  </div>
                )}
              </div>
            ))}
            {sending && <div className="chat-message bot typing">Thinking...</div>}
          </div>

          <form className="chat-input-row" onSubmit={handleSend}>
            <input
              type="text"
              placeholder="Ask about a legend..."
              value={input}
              onChange={(e) => setInput(e.target.value)}
              disabled={sending}
            />
            <button type="submit" disabled={sending || !input.trim()}>
              Send
            </button>
          </form>
        </div>
      )}

      <button className="chat-toggle" onClick={() => setOpen((o) => !o)}>
        {open ? 'Close' : 'Ask the Archive'}
      </button>
    </div>
  );
}

export default ChatWidget;
