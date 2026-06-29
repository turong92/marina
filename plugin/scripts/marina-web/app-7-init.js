    // 탭이 안 보이면 폴링 정지 (백그라운드 탭 서버 부하 0), 복귀 시 즉시 1회 갱신 후 재개
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) { stopPolling(); return; }
      load({passive: true}).catch(console.error);
      loadWorktrees().catch(console.error);
      loadUpdateStatus().catch(console.error);
      startPolling();
    });

    load().catch(alert);
    loadWorktrees().catch(console.error);
    loadUpdateStatus().catch(console.error);
    startPolling();
