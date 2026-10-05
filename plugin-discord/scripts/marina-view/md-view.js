/* md-view.js — /v/<token>/ 의 md 렌더 페이지(marina-view/md-view.html). 원문은 #md-data JSON 으로 심겨 온다.
   marked 로 HTML 을 만들고 DOMPurify 로 정화한 뒤 넣는다. mermaid 블록이 있을 때만 mermaid 를 불러온다(SRI 고정). */
(function () {
  'use strict';
  var MERMAID = {
    src: 'https://cdnjs.cloudflare.com/ajax/libs/mermaid/10.9.1/mermaid.min.js',
    integrity: 'sha384-WmdflGW9aGfoBdHc4rRyWzYuAjEmDwMdGdiPNacbwfGKxBW/SO6guzuQ76qjnSlr'
  };
  var out = document.getElementById('md');
  var data;
  try { data = JSON.parse(document.getElementById('md-data').textContent); } catch (e) { out.textContent = '문서를 읽지 못했어'; return; }
  if (typeof marked === 'undefined' || typeof DOMPurify === 'undefined') {
    out.innerHTML = '<p class="md-err">렌더러(marked·DOMPurify)를 불러오지 못했어 — 원문을 보여 줄게</p>';
    var pre = document.createElement('pre'); pre.textContent = data.text; out.appendChild(pre); return;
  }
  out.innerHTML = DOMPurify.sanitize(marked.parse(data.text, { gfm: true, breaks: false }));

  function slug(t) { return t.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s+/g, '-'); }
  var used = {};
  Array.prototype.forEach.call(out.querySelectorAll('h1,h2,h3,h4,h5,h6'), function (h) {
    var s = slug(h.textContent) || 'section', n = used[s] = (used[s] || 0) + 1;
    h.id = n > 1 ? s + '-' + (n - 1) : s;
  });
  Array.prototype.forEach.call(out.querySelectorAll('table'), function (t) {   // 표는 가로 스크롤
    var w = document.createElement('div'); w.className = 'tbl'; t.parentNode.insertBefore(w, t); w.appendChild(t);
  });
  Array.prototype.forEach.call(out.querySelectorAll('a[href]'), function (a) {
    if (/^https?:/i.test(a.getAttribute('href'))) { a.target = '_blank'; a.rel = 'noopener noreferrer'; }
  });
  document.addEventListener('click', function (e) {                              // <base> 때문에 #앵커가 기준 주소로 가지 않게
    var a = e.target.closest && e.target.closest('a[href^="#"]');
    if (!a) return;
    var id = decodeURIComponent(a.getAttribute('href').slice(1)), t = id && document.getElementById(id);
    e.preventDefault();
    if (t) t.scrollIntoView(); else if (!id) window.scrollTo(0, 0);
  });

  var blocks = out.querySelectorAll('pre > code.language-mermaid');
  if (!blocks.length) return;
  var nodes = [];
  Array.prototype.forEach.call(blocks, function (code) {
    var d = document.createElement('div'); d.className = 'mermaid'; d.textContent = code.textContent;
    code.parentNode.parentNode.replaceChild(d, code.parentNode); nodes.push(d);
  });
  var s = document.createElement('script');
  s.src = MERMAID.src; s.integrity = MERMAID.integrity; s.crossOrigin = 'anonymous';
  s.onload = function () {
    var dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default' });
    mermaid.run({ nodes: nodes }).catch(function () {});
  };
  s.onerror = function () { nodes.forEach(function (d) { d.className = 'md-err'; d.textContent = '다이어그램 렌더러를 불러오지 못했어 — 원문:\n' + d.textContent; d.style.whiteSpace = 'pre-wrap'; }); };
  document.head.appendChild(s);
})();
