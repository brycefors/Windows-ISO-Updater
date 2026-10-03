// Material shrinks a diagram to the content column, so give each one a full-window view.
function setMaximized(wrapper, on) {
  wrapper.classList.toggle("wiso-diagram--max", on);
  document.documentElement.classList.toggle("wiso-noscroll", on);
  var button = wrapper.querySelector(".wiso-diagram__toggle");
  button.textContent = on ? "Close" : "Maximize";
  button.setAttribute("aria-expanded", String(on));
}

// Matches both the source <pre> and the <div> Material swaps in, whichever exists by now.
document$.subscribe(function () {
  document.documentElement.classList.remove("wiso-noscroll");
  document.querySelectorAll(".md-typeset .mermaid").forEach(function (diagram) {
    if (diagram.parentElement.classList.contains("wiso-diagram")) return;
    var wrapper = document.createElement("div");
    wrapper.className = "wiso-diagram";
    var button = document.createElement("button");
    button.type = "button";
    button.className = "wiso-diagram__toggle";
    button.addEventListener("click", function () {
      setMaximized(wrapper, !wrapper.classList.contains("wiso-diagram--max"));
    });
    diagram.before(wrapper);
    wrapper.append(button, diagram);
    setMaximized(wrapper, false);
  });
});

document.addEventListener("keydown", function (event) {
  if (event.key !== "Escape") return;
  document.querySelectorAll(".wiso-diagram--max").forEach(function (wrapper) {
    setMaximized(wrapper, false);
  });
});
