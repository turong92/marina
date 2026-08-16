// marina 서비스워커 — 폰이 잠겨 있어도 알림을 띄우는 유일한 통로.
//
// 왜 내용을 안 받고 물으러 가나. 마리나는 **내용 없는 푸시**를 보낸다(암호 라이브러리 0 의존).
// 그래서 여기서 깨어난 뒤 마리나에 "뭐 있었어?"를 물어 무엇을 띄울지 정한다.
// 덤으로 알림 내용이 애플·구글 서버를 지나가지 않는다.
//
// 규칙 하나만 지킨다: **형이 이미 그 대화를 보고 있으면 울리지 않는다.** 서버는 누가 무엇을
// 보는지 모르므로 이 판단은 여기서만 할 수 있다.

const ALERT_ENDPOINT = "/mobile/api/alerts";
const NOTIFICATION_ICON = "/mobile/icon.png";   // 로그인 없이 받아지는 공개 자산
const LAST_SEEN_KEY = "marina-last-alert-ts";

// 마지막으로 처리한 알림 시각 — 같은 알림을 두 번 띄우지 않으려고 캐시에 적어 둔다
// (서비스워커는 죽었다 살아나므로 전역 변수로는 못 기억한다).
async function lastSeen() {
  try {
    const cache = await caches.open("marina-sw");
    const hit = await cache.match(LAST_SEEN_KEY);
    return hit ? Number(await hit.text()) || 0 : 0;
  } catch (e) { return 0; }
}
async function rememberSeen(ts) {
  try {
    const cache = await caches.open("marina-sw");
    await cache.put(LAST_SEEN_KEY, new Response(String(ts)));
  } catch (e) { /* 캐시가 막혀도 알림 자체는 떠야 한다 */ }
}

// 지금 이 대화를 눈으로 보고 있나 — 보이는 창 중에 해당 세션을 연 것이 있으면 울리지 않는다.
async function watchingSession(session) {
  const clientList = await self.clients.matchAll({type: "window", includeUncontrolled: true});
  return clientList.some(client =>
    client.visibilityState === "visible" && String(client.url || "").includes(encodeURIComponent(session)));
}

self.addEventListener("install", event => { self.skipWaiting(); });
self.addEventListener("activate", event => { event.waitUntil(self.clients.claim()); });

self.addEventListener("push", event => {
  event.waitUntil((async () => {
    const since = await lastSeen();
    let alerts = [];
    try {
      // 같은 출처라 세션 쿠키가 그대로 실린다 — 별도 인증 배관이 필요 없다.
      const response = await fetch(`${ALERT_ENDPOINT}?since=${encodeURIComponent(since)}`,
                                   {credentials: "include", cache: "no-store"});
      if (response.ok) alerts = (await response.json()).alerts || [];
    } catch (e) { alerts = []; }
    if (!alerts.length) {
      // 물어봤는데 없다 = 이미 다른 창이 처리했다. iOS 는 push 마다 알림을 요구하므로
      // 조용히 넘기면 구독이 해지될 수 있어, 아주 낮은 소음으로 하나만 띄운다.
      await self.registration.showNotification("마리나", {
        body: "새 소식이 있어요", tag: "marina-fallback", silent: true, icon: NOTIFICATION_ICON,
      });
      return;
    }
    let newest = since;
    for (const alert of alerts) {
      newest = Math.max(newest, Number(alert.ts) || 0);
      if (alert.session && await watchingSession(alert.session)) continue;   // 보고 있으면 안 울린다
      await self.registration.showNotification(alert.title || "마리나", {
        body: alert.body || "",
        icon: NOTIFICATION_ICON,                       // 없으면 브라우저 기본 아이콘이라 뭔지 모른다
        badge: NOTIFICATION_ICON,                      // 안드로이드 상태표시줄의 작은 아이콘
        tag: alert.tag || alert.session || "marina",   // 같은 자리에 덮어써 알림이 쌓이지 않게
        renotify: alert.kind === "question",           // 질문은 답을 기다리므로 다시 울려도 된다
        // 질문은 형이 답할 때까지 일이 멈춰 있다 — 데스크톱에서 몇 초 만에 사라지면 놓친다.
        requireInteraction: alert.kind === "question",
        timestamp: Math.round(Number(alert.ts) * 1000) || undefined,
        data: {session: alert.session || "", root: alert.root || ""},
      });
    }
    await rememberSeen(newest);
  })());
});

// 알림을 누르면 그 대화를 연다 — 이미 열린 창이 있으면 새 탭을 만들지 않고 그걸 쓴다.
self.addEventListener("notificationclick", event => {
  event.notification.close();
  const session = (event.notification.data && event.notification.data.session) || "";
  const target = session ? `/mobile?session=${encodeURIComponent(session)}` : "/mobile";
  event.waitUntil((async () => {
    const clientList = await self.clients.matchAll({type: "window", includeUncontrolled: true});
    for (const client of clientList) {
      if (String(client.url || "").includes("/mobile")) {
        await client.focus();
        try { client.postMessage({type: "marina-open-session", session}); } catch (e) {}
        return;
      }
    }
    await self.clients.openWindow(target);
  })());
});
