import { Link } from 'react-router-dom';
import { COUNTRIES } from '../api';

const COUNTRY_BLURBS = {
  japan: 'Yokai, onryo, and urban legends from the cities and countryside of Japan.',
  china: 'Ghost stories, spirits, and myth cycles spanning centuries of Chinese folklore.',
  india: 'Regional legends, deities, and supernatural tales from across India.',
  philippines: 'Aswang, engkanto, and ghost stories woven into everyday Filipino life.',
  indonesia: 'Pontianak, kuntilanak, and island-to-island variations of Indonesian horror folklore.',
};

function Home() {
  return (
    <section className="home-grid">
      <h1>Choose a country</h1>
      <div className="country-cards">
        {COUNTRIES.map(({ slug, label }) => (
          <Link to={`/${slug}`} key={slug} className="country-card">
            <h2>{label}</h2>
            <p>{COUNTRY_BLURBS[slug]}</p>
          </Link>
        ))}
      </div>
    </section>
  );
}

export default Home;
