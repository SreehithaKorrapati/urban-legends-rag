const CATEGORY_ICONS = {
  Ghost: 'G',
  Creature: 'C',
  'Deity & Myth': 'D',
  Curse: 'X',
  'Death & Tragedy': 'T',
  'Urban Legend': 'U',
  'Folk Tale': 'F',
  Uncategorized: '?',
};

function PlaceholderImage({ categories = [], className = '' }) {
  const icon = CATEGORY_ICONS[categories[0]] || CATEGORY_ICONS.Uncategorized;
  return (
    <div className={`placeholder-image ${className}`}>
      <span>{icon}</span>
    </div>
  );
}

export default PlaceholderImage;
