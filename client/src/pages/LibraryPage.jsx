import { useState, useEffect } from 'react';
import { Link } from 'react-router-dom';
import { getLibraries, createLibrary, deleteLibrary, removeBookmark } from '../lib/library.js';
import PlaceholderImage from '../components/PlaceholderImage.jsx';
import Breadcrumbs from '../components/Breadcrumbs.jsx';

function LibraryPage() {
  const [libraries, setLibraries] = useState([]);
  const [newName, setNewName] = useState('');

  useEffect(() => {
    setLibraries(getLibraries());
  }, []);

  function handleCreate(e) {
    e.preventDefault();
    if (!newName.trim()) return;
    setLibraries(createLibrary(newName));
    setNewName('');
  }

  function handleDeleteLibrary(id) {
    if (!window.confirm('Delete this library and all its bookmarks?')) return;
    setLibraries(deleteLibrary(id));
  }

  function handleRemoveBookmark(libraryId, country, title) {
    setLibraries(removeBookmark(libraryId, country, title));
  }

  return (
    <section className="library-page">
      <Breadcrumbs items={[{ label: 'Home', to: '/' }, { label: 'My Library' }]} />
      <h1>My Library</h1>
      <p className="status-text">
        Saved on this browser only - bookmarks won't follow you to another device.
      </p>

      <form className="new-library-form" onSubmit={handleCreate}>
        <input
          type="text"
          placeholder="New library name (e.g. Favorites, For the report)"
          value={newName}
          onChange={(e) => setNewName(e.target.value)}
        />
        <button type="submit">Create</button>
      </form>

      {libraries.map((lib) => (
        <div key={lib.id} className="library-section">
          <div className="library-section-header">
            <h2>{lib.name}</h2>
            {lib.id !== 'saved' && (
              <button className="delete-library-btn" onClick={() => handleDeleteLibrary(lib.id)}>
                Delete library
              </button>
            )}
          </div>

          {lib.legends.length === 0 ? (
            <p className="status-text">Nothing saved here yet.</p>
          ) : (
            <div className="legend-grid">
              {lib.legends.map((item) => (
                <div key={`${item.country}/${item.title}`} className="legend-card bookmark-card">
                  <Link to={`/${item.country}/${encodeURIComponent(item.title)}`}>
                    {item.image_url ? (
                      <img src={item.image_url} alt={item.title} />
                    ) : (
                      <PlaceholderImage />
                    )}
                    <h3>{item.title}</h3>
                  </Link>
                  <button
                    className="remove-bookmark-btn"
                    onClick={() => handleRemoveBookmark(lib.id, item.country, item.title)}
                  >
                    Remove
                  </button>
                </div>
              ))}
            </div>
          )}
        </div>
      ))}
    </section>
  );
}

export default LibraryPage;
