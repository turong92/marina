    // ── 분할 레이아웃 공통 — 터미널과 대화가 **같은 표**를 쓴다 ──
    //
    // 왜 뽑았나: 값이 갈리면 버튼 개수와 칸 개수가 어긋난다. 터미널이 이미
    // `if (termFocus >= termSlotCount()) termFocus = 0` 으로 그 사고를 막고 있는데, 대화 쪽에
    // 표를 복사해 두면 같은 사고를 두 번 겪는다. 여기가 유일한 출처다. (스펙 §3.2)
    //
    // 순수 함수만 둔다 — DOM 도 상태도 없다. 그래야 노드에서 그대로 잰다.

    const SPLIT_LAYOUTS = {'1': [1, 1], 'lr': [2, 1], 'tb': [1, 2], '4': [2, 2]};
    // 칸 하나가 이보다 좁으면 읽을 수 없다. 한글 본문 기준 360px 아래로는 코드블록·표가
    // 가로 스크롤 지옥이 된다(스펙 §1). 높이는 대화가 몇 줄은 보여야 한다는 최소치다.
    const SPLIT_MIN_W = 360;
    const SPLIT_MIN_H = 320;
    // 고른 것이 안 들어갈 때 **내려앉는 순서**. 폭이 모자라면 열을 줄이고, 높이가 모자라면
    // 행을 줄인다 — 무엇이 모자란지에 따라 답이 다르므로 후보를 여럿 둔다.
    const SPLIT_FALLBACK = {'4': ['lr', 'tb', '1'], 'lr': ['1'], 'tb': ['1'], '1': []};

    function splitDims(layout) { return SPLIT_LAYOUTS[layout] || SPLIT_LAYOUTS['1']; }
    function splitSlotCount(layout) { const d = splitDims(layout); return d[0] * d[1]; }

    // 이 폭·높이에 이 레이아웃이 들어가나.
    function splitFits(layout, width, height, minW, minH) {
      const d = splitDims(layout);
      return (width / d[0]) >= (minW || SPLIT_MIN_W)
          && (height / d[1]) >= (minH || SPLIT_MIN_H);
    }

    // **고른 레이아웃과 그리는 레이아웃은 다르다**(스펙 §3.3). 창이 좁아지면 접어서 그리되,
    // 형이 고른 값은 그대로 둔다 — 안 그러면 창을 한 번 줄였다 늘렸을 때 설정이 영구히
    // 뭉개진다. 폴드를 펴면 아무것도 안 눌러도 원래대로 돌아오는 것이 이 함수 덕이다.
    function splitEffective(chosen, width, height, minW, minH) {
      const 후보 = [chosen].concat(SPLIT_FALLBACK[chosen] || []);
      for (const 것 of 후보) if (splitFits(것, width, height, minW, minH)) return 것;
      return '1';
    }

    // 배치 규칙 — 터미널 termPlace 와 **같다**. 주석에 형이 겪은 이유가 적혀 있다:
    // "4분할에 빈 칸이 셋이나 있는데도 세션을 누를 때마다 같은 칸을 덮어썼다."
    //   이미 떠 있으면 → 그 칸(옮기지 않는다)
    //   빈 칸이 있으면 → 거기(칸을 채워나가는 게 분할의 목적)
    //   없으면        → 지금 보고 있는 칸
    function splitPlace(slots, count, id, focus) {
      const 이미 = (slots || []).indexOf(id);
      if (이미 >= 0 && 이미 < count) return 이미;
      const 빈칸 = (slots || []).slice(0, count).indexOf(null);
      if (빈칸 >= 0) return 빈칸;
      const f = Number(focus) || 0;
      return Math.max(0, Math.min(count - 1, f));
    }

    // 구분선을 px 위치로 끌었을 때의 비율. **양쪽 다 최소치 아래로 못 간다** — 드래그로도
    // 못 깨야 규칙이 하나다. 컨테이너가 최소치의 두 배도 안 되면 반반이 최선이다.
    function splitFrac(px, total, minPx) {
      const 최소 = Math.min(minPx || SPLIT_MIN_W, total / 2);
      const a = Math.max(최소, Math.min(total - 최소, Number(px) || 0));
      return [a / total, 1 - a / total];
    }

    // 저장값이 깨져 있어도 없는 칸을 가리키면 안 된다 — 터미널이 겪은 그 버그다.
    function splitNormalize(saved) {
      const s = saved && typeof saved === 'object' ? saved : {};
      const layout = SPLIT_LAYOUTS[s.layout] ? s.layout : '1';
      const slots = [0, 1, 2, 3].map(i => (Array.isArray(s.slots) ? s.slots[i] : null) || null);
      const 칸수 = splitSlotCount(layout);
      let focus = Number.isFinite(s.focus) ? Math.floor(s.focus) : 0;
      if (focus < 0 || focus >= 칸수) focus = 0;
      const 비율 = (v) => (Array.isArray(v) && v.length === 2
        && v.every(x => Number.isFinite(x) && x > 0.05 && x < 0.95)) ? v.slice() : [0.5, 0.5];
      return {layout, slots, focus, frac: {col: 비율((s.frac || {}).col), row: 비율((s.frac || {}).row)}};
    }
