// 터미널 넘기기 페이지 — 0.7초마다 화면을 받아 그리고, 입력은 keys 로 보낸다. 값은 textContent 로만 넣는다(XSS).
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var screenEl = $("screen"), statusEl = $("status"), timer = null, last = null, expired = false;

  function poll() {
    timer = null;
    if (document.hidden) return;                                   // 탭이 안 보이면 멈춘다(visibilitychange 가 다시 켠다)
    fetch("screen", { cache: "no-store", credentials: "same-origin" }).then(function (r) {
      if (r.status === 404 || r.status === 403) {                    // 만료됐거나 지워진 링크 — 다시 두드려 봐야 소용없다
        statusEl.textContent = "만료됐어 — 이 링크는 더 쓸 수 없어";
        expired = true;
        return null;
      }
      if (!r.ok) throw new Error(String(r.status));
      return r.json();
    }).then(function (j) {
      if (!j) return;
      $("why").textContent = j.why ? "🖥 " + j.why : "";
      $("cmd").textContent = j.command ? "$ " + j.command : "";
      if (j.screen !== last) {
        var stick = screenEl.scrollTop + screenEl.clientHeight >= screenEl.scrollHeight - 8;
        screenEl.textContent = j.screen;
        last = j.screen;
        if (stick) screenEl.scrollTop = screenEl.scrollHeight;
      }
      $("done").hidden = !j.done;                                    // 끝난 뒤에도 화면은 계속 본다(폴링 유지)
      if (j.done) $("done").textContent = "✅ 명령이 끝났어 — Discord 로 돌아가도 돼";
      $("shareRow").hidden = $("share").hidden = !j.done;            // 화면은 사람이 넘길 때만 세션에 간다
      statusEl.textContent = j.alive ? "연결됨" : "터미널이 끝났어(세션 없음)";
      if (j.alive) schedule();
    }).catch(function (e) {
      statusEl.textContent = "연결이 끊겼어 — 다시 시도 중";
      schedule(3000);
    });
  }
  function schedule(ms) { if (!expired && !timer && !document.hidden) timer = setTimeout(poll, ms || 700); }

  function send(body) {
    return fetch("keys", { method: "POST", credentials: "same-origin", headers: { "content-type": "application/json" }, body: JSON.stringify(body) })
      .then(function (r) { if (!r.ok) statusEl.textContent = (r.status === 404 || r.status === 403) ? "만료됐어 — 이 링크는 더 쓸 수 없어" : "보내지 못했어(" + r.status + ")"; if (!expired) poll(); });
  }

  $("f").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var v = $("t").value;
    if (!v) return;
    $("t").value = "";
    send({ text: v });
  });
  $("share").addEventListener("click", function () {
    var msg = $("shareMsg");
    fetch("share", { method: "POST", credentials: "same-origin" }).then(function (r) {
      if (!r.ok) throw new Error(String(r.status));
      return r.json();
    }).then(function (j) {
      msg.textContent = j.ok ? "넘겼어" : (j.reason === "asleep" ? "세션이 잠들어 있어 — Discord 에 글을 써서 깨운 뒤 다시 눌러" : "넘기지 못했어");
      if (j.ok) $("share").textContent = "다시 넘기기";
    }).catch(function () { msg.textContent = "넘기지 못했어"; });
  });
  Array.prototype.forEach.call(document.querySelectorAll("button[data-key]"), function (b) {
    b.addEventListener("click", function () { send({ key: b.getAttribute("data-key") }); });
  });
  document.addEventListener("visibilitychange", function () { if (!document.hidden) { clearTimeout(timer); timer = null; poll(); } });
  poll();
})();
