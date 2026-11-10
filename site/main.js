// Glint landing page: mobile navigation, copy buttons, one lane reveal.
// No dependencies, no tracking.
(function () {
  "use strict";
  var root = document.documentElement;
  root.classList.add("js");

  // Mobile navigation
  var toggle = document.querySelector(".nav-toggle");
  var nav = document.getElementById("site-nav");
  if (toggle && nav) {
    var label = toggle.querySelector(".nav-toggle-label");
    var setOpen = function (open, returnFocus) {
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
      nav.classList.toggle("is-open", open);
      if (label) label.textContent = open ? "Close" : "Menu";
      if (!open && returnFocus) toggle.focus();
    };
    toggle.addEventListener("click", function () {
      setOpen(toggle.getAttribute("aria-expanded") !== "true", false);
    });
    nav.addEventListener("click", function (e) {
      if (e.target.closest("a")) setOpen(false, false);
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && toggle.getAttribute("aria-expanded") === "true") setOpen(false, true);
    });
    document.addEventListener("click", function (e) {
      if (toggle.getAttribute("aria-expanded") === "true" && !nav.contains(e.target) && !toggle.contains(e.target)) setOpen(false, false);
    });
    var wide = window.matchMedia("(min-width: 961px)");
    var onWide = function () { if (wide.matches) setOpen(false, false); };
    if (wide.addEventListener) wide.addEventListener("change", onWide);
  }

  // Copy buttons
  var live = document.createElement("div");
  live.className = "visually-hidden";
  live.setAttribute("aria-live", "polite");
  live.style.cssText = "position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;";
  document.body.appendChild(live);

  var fallbackCopy = function (text) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.cssText = "position:fixed;top:-1000px;opacity:0;";
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand("copy"); } catch (err) { ok = false; }
    document.body.removeChild(ta);
    return ok ? Promise.resolve() : Promise.reject(new Error("copy failed"));
  };

  Array.prototype.forEach.call(document.querySelectorAll(".copy-btn"), function (btn) {
    btn.setAttribute("aria-label", "Copy commands");
    btn.addEventListener("click", function () {
      var target = document.getElementById(btn.getAttribute("data-copy-target"));
      if (!target) return;
      var text = target.textContent;
      var p = (navigator.clipboard && window.isSecureContext)
        ? navigator.clipboard.writeText(text).catch(function () { return fallbackCopy(text); })
        : fallbackCopy(text);
      p.then(function () {
        btn.textContent = "Copied";
        live.textContent = "Commands copied to the clipboard.";
      }, function () {
        btn.textContent = "Select and copy";
        live.textContent = "Couldn't copy automatically. Select the text and copy it.";
      });
      clearTimeout(btn._t);
      btn._t = setTimeout(function () { btn.textContent = "Copy"; }, 2000);
    });
  });

  // Lane reveal (CSS skips it under reduced motion)
  var lanes = document.querySelector(".lanes");
  if (lanes) {
    if ("IntersectionObserver" in window) {
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            lanes.classList.add("is-visible");
            io.disconnect();
          }
        });
      }, { threshold: 0.25 });
      io.observe(lanes);
    } else {
      lanes.classList.add("is-visible");
    }
  }
})();
