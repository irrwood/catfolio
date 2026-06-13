// Scroll-spy for the audit report's Claude-style section nav.
// Highlights the nav link whose section is currently in view.
(function () {
  const nav = document.querySelector(".report-nav");
  if (!nav) return;
  const links = Array.from(nav.querySelectorAll('a[href^="#"]'));
  const items = links
    .map((a) => ({ a, sec: document.querySelector(a.getAttribute("href")) }))
    .filter((x) => x.sec);
  if (!items.length) return;

  function update() {
    let current = items[0];
    for (const item of items) {
      // viewport-relative, so it works no matter which element scrolls
      if (item.sec.getBoundingClientRect().top <= 140) current = item;
    }
    links.forEach((a) => a.classList.remove("active"));
    current.a.classList.add("active");
  }

  // The page may scroll on window or on the .v4-content container — listen to both.
  const scroller = document.querySelector(".v4-content");
  window.addEventListener("scroll", update, { passive: true });
  if (scroller) scroller.addEventListener("scroll", update, { passive: true });
  links.forEach((a) => a.addEventListener("click", () => setTimeout(update, 250)));
  update();
})();
