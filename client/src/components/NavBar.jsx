import { Link, useLocation } from 'react-router-dom';
import { COUNTRIES } from '../api';

function NavBar() {
  const location = useLocation();

  return (
    <nav className="navbar">
      <Link to="/" className="navbar-brand">
        World Folklore Archive
      </Link>
      <div className="navbar-links">
        {COUNTRIES.map(({ slug, label }) => (
          <Link
            key={slug}
            to={`/${slug}`}
            className={`navbar-link ${location.pathname.startsWith(`/${slug}`) ? 'active' : ''}`}
          >
            {label}
          </Link>
        ))}
        <Link
          to="/library"
          className={`navbar-link navbar-library ${location.pathname === '/library' ? 'active' : ''}`}
        >
          My Library
        </Link>
      </div>
    </nav>
  );
}

export default NavBar;
