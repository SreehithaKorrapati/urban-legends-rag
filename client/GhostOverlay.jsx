import { useEffect, useState } from 'react';
import './GhostOverlay.css';

const GHOST_COUNT = 6;
const BAT_COUNT = 5;

const PHRASES = [
  'Boo! \u{1F47B}',
  'Just passing through the archive...',
  'Shh, the deities are sleeping.',
  'Not all ghosts bite.',
  '\u{5E7D}\u{9748} says hello.',
  'Even I have a category tag.',
  'Spooky season has arrived!',
  'Caught me!',
];

const PUMPKIN_SPOTS = [
  { top: '20vh', left: '3vw', swayDuration: 5.5 },
  { top: '56vh', right: '4vw', swayDuration: 6.5 },
];

function randomBetween(min, max) {
  return min + Math.random() * (max - min);
}

function makeGhost(id) {
  const duration = randomBetween(24, 40);
  return {
    id,
    top: randomBetween(8, 64),
    size: randomBetween(80, 130),
    duration,
    delay: -randomBetween(0, duration), // negative delay staggers starting position
    bobDuration: randomBetween(2.8, 4.4),
    reverse: Math.random() < 0.5,
    phrase: PHRASES[id % PHRASES.length],
  };
}

function makeBat(id) {
  const duration = randomBetween(9, 16);
  return {
    id,
    top: randomBetween(5, 50),
    size: randomBetween(34, 54),
    duration,
    delay: -randomBetween(0, duration),
    reverse: Math.random() < 0.5,
  };
}

function Ghost({ ghost, onPop, isFound, isFading }) {
  const style = {
    '--top': `${ghost.top}vh`,
    '--size': `${ghost.size}px`,
    '--drift-duration': `${ghost.duration}s`,
    '--drift-delay': `${ghost.delay}s`,
    '--bob-duration': `${ghost.bobDuration}s`,
  };
  const gradId = `ghostGradient-${ghost.id}`;

  return (
    <div
      className={`ghost-track${ghost.reverse ? ' reverse' : ''}${isFound ? ' paused' : ''}`}
      style={style}
    >
      <button
        type="button"
        className={`ghost${isFading ? ' fading' : ''}`}
        onClick={() => !isFound && onPop(ghost.id)}
        aria-label="A friendly ghost"
        disabled={isFound}
      >
        {isFound && (
          <span className="ghost-speech">{ghost.phrase}</span>
        )}
        <svg viewBox="0 0 100 120" className="ghost-svg" aria-hidden="true">
          <defs>
            <radialGradient id={gradId} cx="38%" cy="30%" r="75%">
              <stop offset="0%" stopColor="#ffffff" />
              <stop offset="65%" stopColor="#f6f3f7" />
              <stop offset="100%" stopColor="#ddd5e0" />
            </radialGradient>
          </defs>

          <ellipse className="ghost-arm" cx="10" cy="68" rx="7" ry="15" transform="rotate(-18 10 68)" fill={`url(#${gradId})`} />
          <ellipse className="ghost-arm" cx="90" cy="68" rx="7" ry="15" transform="rotate(18 90 68)" fill={`url(#${gradId})`} />

          <path
            className="ghost-body"
            fill={`url(#${gradId})`}
            d="M10,60 C10,20 30,0 50,0 C70,0 90,20 90,60
               L90,100
               C90,100 85,92 80,100 C75,108 70,92 65,100 C60,108 55,92 50,100
               C45,108 40,92 35,100 C30,108 25,92 20,100 C15,108 10,100 10,100
               L10,60 Z"
          />

          <ellipse className="ghost-cheek" cx="24" cy="63" rx="7" ry="4.5" />
          <ellipse className="ghost-cheek" cx="76" cy="63" rx="7" ry="4.5" />

          <ellipse className="ghost-eye" cx="35" cy="49" rx="6.5" ry="9" />
          <ellipse className="ghost-eye" cx="65" cy="49" rx="6.5" ry="9" />
          <circle className="ghost-eye-shine" cx="37.5" cy="45" r="1.8" />
          <circle className="ghost-eye-shine" cx="67.5" cy="45" r="1.8" />

          <path className="ghost-mouth" d="M43,67 Q50,74 57,67 Q50,71 43,67 Z" />

          <path
            className="ghost-sparkle"
            d="M85,4 L87.5,11 L95,13.5 L87.5,16 L85,23 L82.5,16 L75,13.5 L82.5,11 Z"
          />
        </svg>
      </button>
    </div>
  );
}

function Bat({ bat }) {
  const style = {
    '--top': `${bat.top}vh`,
    '--size': `${bat.size}px`,
    '--bat-duration': `${bat.duration}s`,
    '--bat-delay': `${bat.delay}s`,
  };
  return (
    <div className={`bat-track${bat.reverse ? ' reverse' : ''}`} style={style}>
      <svg viewBox="0 0 60 30" className="bat-svg" aria-hidden="true">
        <path className="bat-wing bat-wing-left" d="M30,15 C20,6 4,9 1,17 C10,15 21,17 30,18 Z" />
        <ellipse className="bat-body" cx="30" cy="16" rx="4" ry="5.5" />
        <path className="bat-wing bat-wing-right" d="M30,15 C40,6 56,9 59,17 C50,15 39,17 30,18 Z" />
        <path className="bat-ear" d="M27,11 L26,6 L29,10 Z" />
        <path className="bat-ear" d="M33,11 L34,6 L31,10 Z" />
      </svg>
    </div>
  );
}

function Pumpkin({ spot, index }) {
  const style = {
    '--sway-duration': `${spot.swayDuration}s`,
    top: spot.top,
    left: spot.left,
    right: spot.right,
  };
  const clipId = `pumpkinClip-${index}`;
  return (
    <div className="pumpkin" style={style}>
      <svg viewBox="0 0 80 70" className="pumpkin-svg" aria-hidden="true">
        <defs>
          <clipPath id={clipId}>
            <ellipse cx="40" cy="40" rx="34" ry="26" />
          </clipPath>
        </defs>
        <rect className="pumpkin-stem" x="36" y="4" width="8" height="12" rx="3" />
        <ellipse className="pumpkin-body" cx="40" cy="40" rx="34" ry="26" />
        <g clipPath={`url(#${clipId})`}>
          <path className="pumpkin-ridge" d="M18,18 Q40,10 62,18" />
          <path className="pumpkin-ridge" d="M14,40 Q40,32 66,40" />
          <path className="pumpkin-ridge" d="M18,62 Q40,70 62,62" />
          <polygon className="pumpkin-eye" points="24,34 34,34 29,44" />
          <polygon className="pumpkin-eye" points="46,34 56,34 51,44" />
          <path className="pumpkin-mouth" d="M22,50 L28,44 L34,50 L40,44 L46,50 L52,44 L58,50 L58,55 L22,55 Z" />
        </g>
      </svg>
    </div>
  );
}

export default function GhostOverlay() {
  const [ghosts] = useState(() =>
    Array.from({ length: GHOST_COUNT }, (_, i) => makeGhost(i))
  );
  const [bats] = useState(() =>
    Array.from({ length: BAT_COUNT }, (_, i) => makeBat(i))
  );
  const [foundIds, setFoundIds] = useState(() => new Set());
  const [fadingIds, setFadingIds] = useState(() => new Set());
  const [showSurprise, setShowSurprise] = useState(false);

  const handlePop = (id) => {
    setFoundIds((prev) => new Set(prev).add(id));

    setTimeout(() => {
      setFadingIds((prev) => new Set(prev).add(id));
    }, 1500);
  };

  useEffect(() => {
    if (foundIds.size === GHOST_COUNT) {
      const t = setTimeout(() => setShowSurprise(true), 2200);
      return () => clearTimeout(t);
    }
  }, [foundIds]);

  const allFound = foundIds.size === GHOST_COUNT;

  return (
    <div className="ghost-overlay" aria-hidden={false}>
      <div className="moon-wrap">
        <div className="moon" />
      </div>

      <svg className="spiderweb spiderweb-left" viewBox="0 0 100 100" aria-hidden="true">
        <line x1="0" y1="0" x2="100" y2="15" />
        <line x1="0" y1="0" x2="100" y2="45" />
        <line x1="0" y1="0" x2="100" y2="75" />
        <line x1="0" y1="0" x2="75" y2="100" />
        <line x1="0" y1="0" x2="45" y2="100" />
        <line x1="0" y1="0" x2="15" y2="100" />
        <polyline points="35,5.25 35,15.75 35,26.25 26.25,35 15.75,35 5.25,35" />
        <polyline points="65,9.75 65,29.25 65,48.75 48.75,65 29.25,65 9.75,65" />
        <polyline points="90,13.5 90,40.5 90,67.5 67.5,90 40.5,90 13.5,90" />
      </svg>
      <svg className="spiderweb spiderweb-right" viewBox="0 0 100 100" aria-hidden="true">
        <line x1="0" y1="0" x2="100" y2="15" />
        <line x1="0" y1="0" x2="100" y2="45" />
        <line x1="0" y1="0" x2="100" y2="75" />
        <line x1="0" y1="0" x2="75" y2="100" />
        <line x1="0" y1="0" x2="45" y2="100" />
        <line x1="0" y1="0" x2="15" y2="100" />
        <polyline points="35,5.25 35,15.75 35,26.25 26.25,35 15.75,35 5.25,35" />
        <polyline points="65,9.75 65,29.25 65,48.75 48.75,65 29.25,65 9.75,65" />
        <polyline points="90,13.5 90,40.5 90,67.5 67.5,90 40.5,90 13.5,90" />
      </svg>

      {bats.map((bat) => (
        <Bat key={bat.id} bat={bat} />
      ))}

      {PUMPKIN_SPOTS.map((spot, i) => (
        <Pumpkin key={i} spot={spot} index={i} />
      ))}

      {ghosts.map((ghost) => (
        <Ghost
          key={ghost.id}
          ghost={ghost}
          onPop={handlePop}
          isFound={foundIds.has(ghost.id)}
          isFading={fadingIds.has(ghost.id)}
        />
      ))}

      {!allFound && foundIds.size > 0 && (
        <div className="ghost-tally">
          {'\u{1F47B}'} {foundIds.size}/{GHOST_COUNT} spirits found
        </div>
      )}

      {showSurprise && (
        <div className="ghost-surprise-backdrop" onClick={() => setShowSurprise(false)}>
          <div className="ghost-surprise-card" onClick={(e) => e.stopPropagation()}>
            {Array.from({ length: 24 }).map((_, i) => (
              <span
                key={i}
                className="confetti-piece"
                style={{
                  '--cx': `${randomBetween(0, 100)}%`,
                  '--cdelay': `${randomBetween(0, 1.2)}s`,
                  '--cduration': `${randomBetween(2.2, 3.6)}s`,
                  '--chue': i % 3,
                }}
              />
            ))}
            <h2>You found every spirit! {'\u{1F383}'}</h2>
            <p>
              From Japan's y\u016brei to India's bhoot, China's gu\u01d0, the
              Philippines' multo, and Indonesia's kuntilanak \u2014 every
              tradition in this archive has its ghosts.
            </p>
            <p className="ghost-surprise-sub">Happy Halloween from the Asian Folklore Project.</p>
            <button type="button" className="ghost-surprise-close" onClick={() => setShowSurprise(false)}>
              Back to exploring
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
