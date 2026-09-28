const isEnglish = document.documentElement.lang === 'en';
function updateLanguageLinks() {
  document.querySelectorAll('[data-language-switch]').forEach(link => {
    link.href = link.getAttribute('href').split('#')[0] + location.hash;
  });
}
updateLanguageLinks();
window.addEventListener('hashchange', updateLanguageLinks);
const dialog = document.querySelector('#download-dialog');
document.querySelectorAll('[data-download]').forEach(button => button.addEventListener('click', () => dialog.showModal()));
document.querySelector('.close').addEventListener('click', () => dialog.close());
document.querySelector('#download-done').addEventListener('click', () => dialog.close());
dialog.addEventListener('click', event => { if (event.target === dialog) { const r = dialog.getBoundingClientRect(); if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) dialog.close(); } });

const cards = [...document.querySelectorAll('.capability')];
const categoryButtons = [...document.querySelectorAll('[data-category]')];
function filterCategory(category) {
  categoryButtons.forEach(other => other.setAttribute('aria-pressed', String(other.dataset.category === category)));
  cards.forEach(card => { card.hidden = category !== 'all' && card.dataset.group !== category; });
  document.querySelector('#feature-count').textContent = `${cards.filter(card => !card.hidden).length} ${isEnglish ? "features" : "项功能"}`;
}
categoryButtons.forEach(button => button.addEventListener('click', () => filterCategory(button.dataset.category)));
// Keep previously shared section links working after consolidating the page.
const sectionAliases = {
  interactions: 'capability-chart-range', latest: 'features',
  'today-returns': 'capability-today', 'portfolio-xray': 'capability-today',
  'returns-review': 'capability-contributors', 'earnings-research': 'capability-management-delivery',
  'stock-research': 'capability-detail', 'your-ai': 'capability-ai',
  'all-accounts': 'capability-accounts', 'account-comparison': 'capability-account-comparison',
  'cash-history': 'capability-history', 'currency-language': 'capability-currency',
  'capability-security': 'privacy', 'capability-portfolio-xray': 'capability-today',
  'capability-automatic-fx': 'capability-currency',
};
function revealLinkedFeature() {
  const alias = sectionAliases[location.hash.slice(1)];
  if (alias) {
    history.replaceState(null, '', '#' + alias);
    updateLanguageLinks();
  }
  const target = document.getElementById(location.hash.slice(1));
  if (target?.classList.contains('capability') && target.hidden) {
    filterCategory('all');
    target.scrollIntoView();
  }
  if (alias && target) target.scrollIntoView();
}
window.addEventListener('hashchange', revealLinkedFeature);
revealLinkedFeature();
const screenshotDialog = document.querySelector('#screenshot-dialog');
let selectedCard;
function displayScreenshot(card) {
  selectedCard = card;
  const visibleCards = cards.filter(item => !item.hidden && item.querySelector("[data-shot]"));
  const original = card.querySelector('img');
  const image = document.querySelector('#expanded-screenshot');
  image.src = original.getAttribute('src');
  image.alt = original.alt;
  document.querySelector('#screenshot-title').textContent = card.querySelector('.capability-label').textContent;
  document.querySelector('#screenshot-note').textContent = card.querySelector('.capability-note').textContent;
  document.querySelector('#screenshot-position').textContent = `${visibleCards.indexOf(card) + 1} / ${visibleCards.length}`;
  screenshotDialog.scrollTop = 0;
}
function stepScreenshot(direction) {
  const visibleCards = cards.filter(item => !item.hidden && item.querySelector("[data-shot]"));
  displayScreenshot(visibleCards[(visibleCards.indexOf(selectedCard) + direction + visibleCards.length) % visibleCards.length]);
}
document.querySelectorAll('[data-shot]').forEach(button => button.addEventListener('click', () => {
  displayScreenshot(button.closest('.capability'));
  document.body.classList.add('screenshot-open');
  screenshotDialog.showModal();
}));
document.querySelector('#screenshot-close').addEventListener('click', () => screenshotDialog.close());
screenshotDialog.addEventListener('close', () => document.body.classList.remove('screenshot-open'));
document.querySelector('#previous-screenshot').addEventListener('click', () => stepScreenshot(-1));
document.querySelector('#next-screenshot').addEventListener('click', () => stepScreenshot(1));
screenshotDialog.addEventListener('keydown', event => {
  if(event.key === 'ArrowLeft' || event.key === 'ArrowRight') { event.preventDefault(); stepScreenshot(event.key === 'ArrowRight' ? 1 : -1); }
});
screenshotDialog.addEventListener('click', event => {
  if(event.target !== screenshotDialog) return;
  const r = screenshotDialog.getBoundingClientRect();
  if(event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) screenshotDialog.close();
});
