const dialog = document.querySelector('#download-dialog');
document.querySelectorAll('[data-download]').forEach(button => button.addEventListener('click', () => dialog.showModal()));
document.querySelector('.close').addEventListener('click', () => dialog.close());
document.querySelector('#download-done').addEventListener('click', () => dialog.close());
dialog.addEventListener('click', event => { if (event.target === dialog) { const r = dialog.getBoundingClientRect(); if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) dialog.close(); } });

const cards = [...document.querySelectorAll('.capability')];
const categoryButtons = [...document.querySelectorAll('[data-category]')];
categoryButtons.forEach(button => button.addEventListener('click', () => {
  categoryButtons.forEach(other => other.setAttribute('aria-pressed', String(other === button)));
  cards.forEach(card => { card.hidden = button.dataset.category !== 'all' && card.dataset.group !== button.dataset.category; });
  document.querySelector('#feature-count').textContent = `${cards.filter(card => !card.hidden).length} 项功能`;
}));
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
