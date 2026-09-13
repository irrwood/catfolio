const isEnglish = document.documentElement.lang === 'en';
function updateLanguageLinks() {
  document.querySelectorAll('[data-language-switch]').forEach(link => {
    link.href = (isEnglish ? 'index.html' : 'en.html') + location.hash;
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
function revealLinkedFeature() {
  const target = document.getElementById(location.hash.slice(1));
  if (target?.classList.contains('capability') && target.hidden) {
    filterCategory('all');
    target.scrollIntoView();
  }
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

// Switch between captured native states; the website does not calculate returns.
const interactions = isEnglish ? {
  range: ['chart-range', 'Two-finger interval selected on a demo portfolio chart', 'Two-finger interval · Native selection · Click to enlarge'],
  day: ['chart-selection', 'Single day selected on a demo portfolio chart', 'Single-day inspection · Native selection · Click to enlarge'],
  heatmap: ['heatmap', 'Dimensional portfolio heatmap', 'Portfolio heatmap · Collapsed · Click to enlarge'],
  expanded: ['heatmap-expanded', 'Expanded portfolio heatmap', 'Portfolio heatmap · Expanded · Click to enlarge'],
} : {
  range: ['chart-range', '演示组合曲线的双指区间选中状态', '双指区间测量 · 原生选中状态 · 点击放大'],
  day: ['chart-selection', '演示组合曲线的单日选中状态', '单指查看单日 · 原生选中状态 · 点击放大'],
  heatmap: ['heatmap', '收益页立体持仓热力图', '立体热力图 · 收起状态 · 点击放大'],
  expanded: ['heatmap-expanded', '展开后的完整持仓热力图', '持仓热力图 · 展开状态 · 点击放大'],
};
const interactionButtons = [...document.querySelectorAll('[data-interaction]')];
interactionButtons.forEach(button => button.addEventListener('click', () => {
  const [file, alt, caption] = interactions[button.dataset.interaction];
  const src = `assets/refresh/${file}.png`;
  interactionButtons.forEach(other => other.setAttribute('aria-pressed', String(other === button)));
  const image = document.querySelector('#interaction-image');
  image.src = src;
  image.alt = alt;
  document.querySelector('#interaction-original').href = src;
  document.querySelector('#interaction-caption').textContent = caption;
}));
