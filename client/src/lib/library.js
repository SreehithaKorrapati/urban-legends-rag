const STORAGE_KEY = 'folklore_libraries_v1';
const DEFAULT_LIBRARY = { id: 'saved', name: 'Saved', legends: [] };

function readAll() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return [structuredCloneSafe(DEFAULT_LIBRARY)];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) && parsed.length > 0 ? parsed : [structuredCloneSafe(DEFAULT_LIBRARY)];
  } catch {
    return [structuredCloneSafe(DEFAULT_LIBRARY)];
  }
}

function structuredCloneSafe(obj) {
  return JSON.parse(JSON.stringify(obj));
}

function writeAll(libraries) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(libraries));
}

export function getLibraries() {
  return readAll();
}

export function createLibrary(name) {
  const libraries = readAll();
  const id = `lib_${Date.now()}`;
  libraries.push({ id, name: name.trim() || 'Untitled Library', legends: [] });
  writeAll(libraries);
  return libraries;
}

export function deleteLibrary(id) {
  if (id === 'saved') return readAll();
  const libraries = readAll().filter((l) => l.id !== id);
  writeAll(libraries);
  return libraries;
}

export function addBookmark(libraryId, legend) {
  const libraries = readAll();
  const lib = libraries.find((l) => l.id === libraryId);
  if (!lib) return libraries;

  const key = `${legend.country}/${legend.title}`;
  if (!lib.legends.some((l) => `${l.country}/${l.title}` === key)) {
    lib.legends.push({
      title: legend.title,
      country: legend.country,
      image_url: legend.image_url || null,
      savedAt: new Date().toISOString(),
    });
  }
  writeAll(libraries);
  return libraries;
}

export function removeBookmark(libraryId, country, title) {
  const libraries = readAll();
  const lib = libraries.find((l) => l.id === libraryId);
  if (!lib) return libraries;

  lib.legends = lib.legends.filter((l) => !(l.country === country && l.title === title));
  writeAll(libraries);
  return libraries;
}

export function isBookmarked(country, title) {
  const libraries = readAll();
  return libraries.some((lib) => lib.legends.some((l) => l.country === country && l.title === title));
}

export function findLibrariesContaining(country, title) {
  const libraries = readAll();
  return libraries
    .filter((lib) => lib.legends.some((l) => l.country === country && l.title === title))
    .map((l) => l.id);
}
