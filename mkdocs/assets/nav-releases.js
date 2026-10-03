// Sets Releases apart from the docs pages, reusing the header's repo icon rather than a copied SVG.
document$.subscribe(function () {
  var icon = document.querySelector(".md-source__icon svg");
  document.querySelectorAll('.md-nav--primary .md-nav__link[href$="/releases"]').forEach(function (link) {
    var item = link.closest(".md-nav__item");
    if (item.classList.contains("wiso-nav-releases")) return;
    item.classList.add("wiso-nav-releases");
    if (icon) link.prepend(icon.cloneNode(true));
  });
});
