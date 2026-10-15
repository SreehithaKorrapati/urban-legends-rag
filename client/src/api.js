const API_BASE = 'http://localhost:5000/api';

async function request(path, options = {}) {
  const res = await fetch(`${API_BASE}${path}`, {
    headers: { 'Content-Type': 'application/json' },
    ...options,
  });

  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.error || `Request failed: ${res.status}`);
  }

  return res.json();
}

export function getLegends(country, search = '') {
  const query = search ? `?search=${encodeURIComponent(search)}` : '';
  return request(`/legends/${country}${query}`);
}

export function getLegend(country, title) {
  return request(`/legends/${country}/${encodeURIComponent(title)}`);
}

export function askChat(question, country = null) {
  return request('/chat', {
    method: 'POST',
    body: JSON.stringify({ question, country }),
  });
}

export const COUNTRIES = [
  { slug: 'japan', label: 'Japan' },
  { slug: 'china', label: 'China' },
  { slug: 'india', label: 'India' },
  { slug: 'philippines', label: 'Philippines' },
  { slug: 'indonesia', label: 'Indonesia' },
];
