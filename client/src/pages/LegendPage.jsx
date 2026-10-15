import { useEffect, useState, Fragment } from 'react';
import { useParams, Link } from 'react-router-dom';
import { getLegend, COUNTRIES } from '../api';
import PlaceholderImage from '../components/PlaceholderImage.jsx';
import Breadcrumbs from '../components/Breadcrumbs.jsx';
import { getLibraries, addBookmark, removeBookmark, findLibrariesContaining } from '../lib/library.js';

const ENTITY_BUCKET_LABELS = {
  people: 'People',
  places: 'Places',
  other: 'Other Mentions',
};

function LegendPage() {
  const { country, title } = useParams();
  const [legend, setLegend] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [imgFailed, setImgFailed] = useState(false);
  const [bookmarked, setBookmarked] = useState(false);

  const countryLabel = COUNTRIES.find((c) => c.slug === country)?.label || country;

  useEffect(() => {
    setLoading(true);
    setError(null);
    setImgFailed(false);
    getLegend(country, title)
      .then((data) => {
        setLegend(data);
        setBookmarked(findLibrariesContaining(country, data.title).length > 0);
      })
      .catch((err) => setError(err.message))
      .finally(() => setLoading(false));
  }, [country, title]);

  function toggleBookmark() {
    if (!legend) return;
    if (bookmarked) {
      const libs = getLibraries();
      libs.forEach((lib) => removeBookmark(lib.id, country, legend.title));
      setBookmarked(false);
    } else {
      addBookmark('saved', { ...legend, country });
      setBookmarked(true);
    }
  }

  if (loading) return <p className="status-text">Loading...</p>;
  if (error) return <p className="status-text error">Error: {error}</p>;
  if (!legend) return null;

  const paragraphs = legend.text.split('\n').filter((p) => p.trim().length > 0);
  const wordCount = legend.text.split(/\s+/).filter(Boolean).length;
  const readingMinutes = Math.max(1, Math.round(wordCount / 200));

  return (
    <article className="legend-page">
      <Breadcrumbs
        items={[
          { label: 'Home', to: '/' },
          { label: countryLabel, to: `/${country}` },
          { label: legend.title },
        ]}
      />

      <div className="legend-header">
        {legend.image_url && !imgFailed ? (
          <img
            src={legend.image_url}
            alt={legend.title}
            className="legend-image"
            onError={() => setImgFailed(true)}
          />
        ) : (
          <PlaceholderImage categories={legend.categories} className="legend-image" />
        )}
        <div className="legend-title-block">
          <h1>{legend.title}</h1>
          {legend.native_title && (
            <p className="native-title">
              {legend.native_title}
              {legend.native_lang ? ` (${legend.native_lang})` : ''}
            </p>
          )}
          <button className={`bookmark-btn ${bookmarked ? 'active' : ''}`} onClick={toggleBookmark}>
            {bookmarked ? 'Saved' : 'Save to Library'}
          </button>
        </div>
      </div>

      <aside className="stat-block">
        <h3>Stat Block</h3>
        <dl>
          <dt>Country of Origin</dt>
          <dd>{countryLabel}</dd>

          {legend.categories && legend.categories.length > 0 && (
            <>
              <dt>Category</dt>
              <dd>
                <div className="stat-tags">
                  {legend.categories.map((c) => (
                    <span key={c} className="stat-tag">
                      {c}
                    </span>
                  ))}
                </div>
              </dd>
            </>
          )}

          {legend.entities &&
            Object.entries(legend.entities).map(([bucket, names]) => (
              <Fragment key={bucket}>
                <dt>{ENTITY_BUCKET_LABELS[bucket] || bucket}</dt>
                <dd>
                  <div className="stat-tags">
                    {names.map((name) => (
                      <Link
                        key={name}
                        to={`/${country}?search=${encodeURIComponent(name)}`}
                        className="stat-tag entity-tag"
                      >
                        {name}
                      </Link>
                    ))}
                  </div>
                </dd>
              </Fragment>
            ))}

          {legend.native_lang && (
            <>
              <dt>Native Language</dt>
              <dd>{legend.native_lang}</dd>
            </>
          )}

          <dt>Entry Length</dt>
          <dd>{wordCount.toLocaleString()} words</dd>

          <dt>Reading Time</dt>
          <dd>~{readingMinutes} min</dd>

          {legend.url && (
            <>
              <dt>Source</dt>
              <dd>
                <a href={legend.url} target="_blank" rel="noreferrer">
                  View original article
                </a>
              </dd>
            </>
          )}
        </dl>
      </aside>

      <div className="legend-body">
        {paragraphs.map((p, i) => (
          <p key={i}>{p}</p>
        ))}

        {legend.native_text && (
          <>
            <h3>Original text ({legend.native_lang})</h3>
            {legend.native_text
              .split('\n')
              .filter((p) => p.trim().length > 0)
              .map((p, i) => (
                <p key={`native-${i}`} className="native-text">
                  {p}
                </p>
              ))}
          </>
        )}
      </div>

      {legend.related && legend.related.length > 0 && (
        <div className="related-section">
          <h3>Related Legends</h3>
          <div className="related-grid">
            {legend.related.map((r) => (
              <Link
                key={r.title}
                to={`/${country}/${encodeURIComponent(r.title)}`}
                className="related-card"
              >
                {r.image_url ? (
                  <img src={r.image_url} alt={r.title} />
                ) : (
                  <PlaceholderImage />
                )}
                <span>{r.title}</span>
              </Link>
            ))}
          </div>
        </div>
      )}
    </article>
  );
}

export default LegendPage;
