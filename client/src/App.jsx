import { Routes, Route } from 'react-router-dom';
import NavBar from './components/NavBar.jsx';
import Home from './pages/Home.jsx';
import CountryPage from './pages/CountryPage.jsx';
import LegendPage from './pages/LegendPage.jsx';
import LibraryPage from './pages/LibraryPage.jsx';
import ChatWidget from './components/ChatWidget.jsx';
import GhostOverlay from './components/GhostOverlay.jsx';
import './App.css';

function App() {
  return (
    <div className="app-shell">
      <NavBar />

      <main className="site-main">
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/library" element={<LibraryPage />} />
          <Route path="/:country" element={<CountryPage />} />
          <Route path="/:country/:title" element={<LegendPage />} />
        </Routes>
      </main>

      <GhostOverlay />
      <ChatWidget />

      <footer className="site-footer">
        <p>Built for an NLP course project.</p>
      </footer>
    </div>
  );
}

export default App;