import { Link } from 'react-router-dom';

function Breadcrumbs({ items }) {
  return (
    <nav className="breadcrumbs" aria-label="Breadcrumb">
      {items.map((item, i) => (
        <span key={i} className="breadcrumb-item">
          {item.to ? <Link to={item.to}>{item.label}</Link> : <span>{item.label}</span>}
          {i < items.length - 1 && <span className="breadcrumb-sep"> / </span>}
        </span>
      ))}
    </nav>
  );
}

export default Breadcrumbs;
