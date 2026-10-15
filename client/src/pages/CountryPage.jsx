import { useEffect, useState } from 'react';
import { useParams, useSearchParams, Link } from 'react-router-dom';
import { getLegends, COUNTRIES } from '../api';
import PlaceholderImage from '../components/PlaceholderImage.jsx';
import Breadcrumbs from '../components/Breadcrumbs.jsx';

const PAGE_SIZE = 24;

function CountryPage() {
  const { country } = useParams();
  const [searchParams] = useSearchParams();
  const [legends, setLegends] = useState([]);
  const [search, setSearch] = useState(searchParams.get('search') || '');
  const [activeCategory, setActiveCategory] = useState(null);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const countryLabel = COUNTRIES.find((c) => c.slug === country)?.label || country;

  useEffect(() => {
    const fromUrl = searchParams.get('search');
    if (fromUrl && fromUrl !== search) {
      setSearch(fromUrl);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchParams]);

  useEffect(() => {
    setLoading(true);
    setError(null);
    setPage(1);
    const timeout = setTimeout(() => {
      getLegends(country, search)
        .then((data) => setLegends(data))
        .catch((err) => setError(err.message))
        .finally(() => setLoading(false));
    }, 250);

    return () => clearTimeout(timeout);
  }, [country, search]);

  const allCategories = Array.from(new Set(legends.flatMap((l) => l.categories || []))).sort();

  const filtered = activeCategory
    ? legends.filter((l) => (l.categories || []).includes(activeCategory))
    : legends;

  const totalPages = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const pageItems = filtered.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);

  function goToPage(p) {
    setPage(Math.min(Math.max(1, p), totalPages));
  }

  return (
    <section className={`country-page country-${country}`}>
      <Breadcrumbs items={[{ label: 'Home', to: '/' }, { label: countryLabel }]} />
      <h1>{countryLabel} Folklore</h1>

      <input
        className="search-box"
        type="text"
        placeholder={`Search ${countryLabel} legends...`}
        value={search}
        onChange={(e) => setSearch(e.target.value)}
      />

      {allCategories.length > 0 && (
        <div className="category-chips">
          <button
            className={`chip ${activeCategory === null ? 'active' : ''}`}
            onClick={() => {
              setActiveCategory(null);
              setPage(1);
            }}
          >
            All
          </button>
          {allCategories.map((cat) => (
            <button
              key={cat}
              className={`chip ${activeCategory === cat ? 'active' : ''}`}
              onClick={() => {
                setActiveCategory(cat);
                setPage(1);
              }}
            >
              {cat}
            </button>
          ))}
        </div>
      )}

      {loading && <p className="status-text">Loading...</p>}
      {error && <p className="status-text error">Error: {error}</p>}
      {!loading && !error && filtered.length === 0 && (
        <p className="status-text">No legends found.</p>
      )}

      <div className="legend-grid">
        {pageItems.map((legend) => (
          <Link
            to={`/${country}/${encodeURIComponent(legend.title)}`}
            key={legend.title}
            className="legend-card"
          >
            {legend.image_url ? (
              <img
                src={legend.image_url}
                alt={legend.title}
                loading="lazy"
                onError={(e) => {
                  e.target.style.display = 'none';
                  e.target.nextSibling.style.display = 'flex';
                }}
              />
            ) : null}
            <div style={{ display: legend.image_url ? 'none' : 'flex' }}>
              <PlaceholderImage categories={legend.categories} />
            </div>
            <h3>{legend.title}</h3>
            {legend.categories && legend.categories[0] && (
              <span className="card-tag">{legend.categories[0]}</span>
            )}
          </Link>
        ))}
      </div>

      {totalPages > 1 && (
        <div className="pagination">
          <button onClick={() => goToPage(page - 1)} disabled={page === 1}>
            Prev
          </button>
          <span>
            Page {page} of {totalPages}
          </span>
          <button onClick={() => goToPage(page + 1)} disabled={page === totalPages}>
            Next
          </button>
        </div>
      )}
    </section>
  );
}

export default CountryPage;