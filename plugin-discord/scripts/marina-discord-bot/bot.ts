// 마리나 Discord 봇 — 공식 Discord 플러그인이 못 받는 이벤트만 받는다(지금은 🛑 반응).
// 판단은 전부 파이썬(marina_discord_bot.py interrupt)에 맡긴다. 마리나 데몬이 띄우고, 데몬이 죽으면 따라 끝난다.
import { ActionRowBuilder, Client, Events, GatewayIntentBits, MessageFlags, ModalBuilder, Partials, TextInputBuilder, TextInputStyle } from "discord.js";
import { execFile } from "node:child_process";

const guild = process.env.MARINA_GUILD ?? "";
const py = process.env.MARINA_PY ?? "python3";
const script = process.env.MARINA_BOT_PY ?? "";
const parent = Number(process.env.MARINA_PARENT_PID ?? 0);
// 파이썬은 토큰을 설정 파일에서 직접 읽는다 — 자식에게 토큰 env 를 물려주지 않는다
const childEnv = { ...process.env };
delete childEnv.DISCORD_BOT_TOKEN;

const client = new Client({
  // GuildMessages: 꺼진 방에 온 글을 알아채려고(특권 인텐트 아님). 글 내용은 안 읽는다 — MessageContent 는 선언하지 않는다
  intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessageReactions, GatewayIntentBits.GuildMessages],
  // 봇이 켜지기 전 메시지에 단 반응도 받으려면 partial 이 필요하다
  partials: [Partials.Message, Partials.Channel, Partials.Reaction, Partials.User],
});

client.on(Events.MessageReactionAdd, async (reaction, user) => {
  if (user.bot || user.id === client.user?.id || reaction.emoji.name !== "🛑") return; // 미리 단 🛑 는 봇 것
  const msg = reaction.message;
  if (msg.guildId !== guild) return;
  let channelId = msg.channelId;
  try {
    const ch = await client.channels.fetch(msg.channelId);
    if (ch?.isThread() && ch.parentId) channelId = ch.parentId; // 진행 스레드에서 눌러도 그 세션
  } catch {}
  execFile(py, [script, "interrupt", "--channel", channelId, "--user", user.id, "--message", msg.id],
    { timeout: 20000, env: childEnv }, (err, out, errOut) => {
      console.log(new Date().toISOString(), "stop", channelId, msg.id, (out || errOut || String(err ?? "")).trim());
    });
});

// 꺼진 방에 온 글 → 파이썬이 판단해 그 방 세션을 깨운다. 켜져 있으면 그 세션의 채널 플러그인이 직접 받으므로
// 파이썬이 "alive" 로 바로 돌아온다. 여기서는 채널·글쓴이·메시지 ID 만 넘긴다(본문은 파이썬이 필요할 때 REST 로).
const wakePy = script.replace(/marina_discord_bot\.py$/, "marina_discord_wake.py");
client.on(Events.MessageCreate, async (msg) => {
  if (!msg.author || msg.author.bot || msg.guildId !== guild) return;
  let channelId = msg.channelId;
  let thread = "";
  try {
    const ch = msg.channel ?? (await client.channels.fetch(msg.channelId));
    if (ch?.isThread() && ch.parentId) { thread = msg.channelId; channelId = ch.parentId; } // 스레드 글은 부모 채널의 방
  } catch {}
  execFile(py, [wakePy, "wake", "--channel", channelId, "--user", msg.author.id, "--message", msg.id, `--thread=${thread}`],
    { timeout: 120000, env: childEnv }, (err, out, errOut) => {
      const res = (out || errOut || String(err ?? "")).trim();
      if (res !== "alive" && !res.startsWith("ignored:")) console.log(new Date().toISOString(), "wake", channelId, msg.id, res.slice(0, 200));
    });
});

// #상태 대시보드의 [정지] 버튼 — 🛑 반응과 같은 처리. 결과는 누른 사람에게만 보인다
client.on(Events.InteractionCreate, async (it) => {
  if (!it.isButton() || !it.customId.startsWith("marina-stop:")) return;
  const channelId = it.customId.slice("marina-stop:".length);
  await it.deferUpdate().catch(() => {});      // 비밀 답장 없음(형 결정) — 결과는 ⏹️ 반응·#상태가 보여 준다
  execFile(py, [script, "interrupt", "--channel", channelId, "--user", it.user.id, "--message", ""],
    { timeout: 20000, env: childEnv }, (err, out, errOut) => {
      const msg = (out || errOut || String(err ?? "")).trim() || "처리 못 했어";
      console.log(new Date().toISOString(), "stop-button", channelId, msg);
      if (msg !== "멈췄어") it.followUp({ content: `<#${channelId}> ${msg}`, allowedMentions: { parse: [] } }).catch(() => {});
    });
});

// #상태 [보기] — 뒤에서 도는 셸 출력 끝·에이전트 마지막 말을 누른 사람에게만
client.on(Events.InteractionCreate, async (it) => {
  if (!it.isButton() || !it.customId.startsWith("marina-view:")) return;
  const channelId = it.customId.slice("marina-view:".length);
  await it.deferReply().catch(() => {});        // #상태는 형만 보는 채널 — 공개로
  execFile(py, [script, "view", "--channel", channelId, "--user", it.user.id],
    { timeout: 20000, env: childEnv }, (err, out, errOut) => {
      const msg = (out || errOut || String(err ?? "")).trim() || "못 읽었어";
      it.editReply({ content: `<#${channelId}>\n${msg}`.slice(0, 2000), allowedMentions: { parse: [] } }).catch(() => {});
    });
});

// 답장 밑 [▶ 추천] — 누르면 세션 입력창에(한 번만). 결과는 누른 사람에게만
client.on(Events.InteractionCreate, async (it) => {
  if (!it.isButton() || !it.customId.startsWith("marina-say:")) return;
  const channelId = it.customId.slice("marina-say:".length);
  await it.deferUpdate().catch(() => {});   // 비밀 답장 대신 — 결과는 버튼 자리에 '✓ 보냄: …' 으로 남는다
  execFile(py, [script, "say", "--channel", channelId, "--user", it.user.id, "--message", it.message.id],
    { timeout: 20000, env: childEnv }, (err, out, errOut) => {
      const msg = (out || errOut || String(err ?? "")).trim();
      if (msg !== "입력할게") it.followUp({ content: msg || "처리 못 했어", allowedMentions: { parse: [] } }).catch(() => {});   // 안 됐을 때만 알림
    });
});

// 질문 버튼(봇 3): mq=단일 선택 버튼, mqm=다중 드롭다운, mqo=기타 입력 팝업 열기, mqt=팝업 제출
const askPy = script.replace(/marina_discord_bot\.py$/, "marina_discord_ask.py");
function answer(it: any, channelId: string, q: string, extra: string[]) {
  execFile(py, [askPy, "answer", "--channel", channelId, "--user", it.user.id, "--q", q, `--message=${it.message?.id ?? ""}`, ...extra],
    { timeout: 20000, env: childEnv }, (err, out, errOut) => {
      const msg = (out || errOut || String(err ?? "")).trim() || "처리 못 했어";
      // 잘 됐으면 질문 메시지 자체가 바뀐다 — 안 됐을 때만 공개로 알린다(비밀 답장 없음)
      if (!["골랐어", "다 골랐어 — 세션에 입력할게"].includes(msg)) it.followUp({ content: msg, allowedMentions: { parse: [] } }).catch(() => {});
    });
}
client.on(Events.InteractionCreate, async (it) => {
  if (it.isButton() && it.customId.startsWith("mqo:")) {
    const [, ch, q] = it.customId.split(":");
    const modal = new ModalBuilder().setCustomId(`mqt:${ch}:${q}`).setTitle("직접 입력");
    const input = new TextInputBuilder().setCustomId("text").setLabel("답").setStyle(TextInputStyle.Short).setMaxLength(2000).setRequired(true);
    modal.addComponents(new ActionRowBuilder<TextInputBuilder>().addComponents(input));
    await it.showModal(modal).catch(() => {});
    return;
  }
  if (it.isButton() && it.customId.startsWith("mq:")) {
    const [, ch, q, o] = it.customId.split(":");
    await it.deferUpdate().catch(() => {});
    answer(it, ch, q, ["--picks", o]);
    return;
  }
  if (it.isStringSelectMenu() && it.customId.startsWith("mqm:")) {
    const [, ch, q] = it.customId.split(":");
    await it.deferUpdate().catch(() => {});
    answer(it, ch, q, ["--picks", it.values.join(",")]);
    return;
  }
  if (it.isModalSubmit() && it.customId.startsWith("mqt:")) {
    const [, ch, q] = it.customId.split(":");
    if (it.isFromMessage()) await it.deferUpdate().catch(() => {}); else await it.deferReply().catch(() => {});
    answer(it, ch, q, [`--text=${it.fields.getTextInputValue("text")}`]); // = 로 붙여 '-' 로 시작하는 글도 값으로
  }
});

// 로비 고정 패널 [🛠 새 작업 열기](marina-new:<프로젝트>) → 칸 하나 모달(marina-newt) → 제출하면 파이썬이 워크트리·채널·세션을 연다
client.on(Events.InteractionCreate, async (it) => {
  if (it.isButton() && it.customId.startsWith("marina-new:")) {
    const project = it.customId.slice("marina-new:".length);
    const modal = new ModalBuilder().setCustomId(`marina-newt:${project}`).setTitle("새 작업 열기");
    const input = new TextInputBuilder().setCustomId("text").setLabel("뭐 할 거야?").setStyle(TextInputStyle.Paragraph)
      .setPlaceholder("예) 결제 페이지 환불 버그 고치기 (dev 에서 시작하려면 'dev에서')")
      .setMinLength(1).setMaxLength(500).setRequired(true);
    modal.addComponents(new ActionRowBuilder<TextInputBuilder>().addComponents(input));
    await it.showModal(modal).catch(() => {});
    return;
  }
  if (it.isModalSubmit() && it.customId.startsWith("marina-newt:")) {
    const project = it.customId.slice("marina-newt:".length);
    await it.deferReply({ flags: MessageFlags.Ephemeral }).catch(() => {});   // 열리는 데 시간이 걸린다 — 먼저 받아 두고 결과는 누른 사람에게만
    const text = it.fields.getTextInputValue("text");
    const who = it.user.globalName || it.user.username;
    execFile(py, [script, "new-from-text", "--project", project, "--user", it.user.id, "--channel", it.channelId ?? "", `--name=${who}`,
                  `--text=${text}`],   // = 로 붙여 '-' 로 시작하는 글도 값으로
      { timeout: 600000, env: childEnv }, (err, out, errOut) => {
        // 사용자에겐 파이썬이 다듬은 한 줄(성공·알려줄 실패)만 — 비정상 종료·시간 초과는 고정 문구, 자세한 건 로그에
        const msg = err ? "" : (out || "").trim();
        console.log(new Date().toISOString(), "new-task", project, err ? `error ${String(err)} ${(errOut || "").slice(0, 300)}` : msg.slice(0, 200));
        it.editReply({ content: (msg || "못 열었어 — 마리나 로그를 확인해 줘").slice(0, 2000), allowedMentions: { parse: [] } }).catch(() => {});
      });
  }
});

// 슬래시 명령(봇 1): 켜질 때 길드 명령으로 등록. 목록은 파이썬이 정한다(한 곳에서)
function runPy(args: string[], cb: (out: string) => void) {
  execFile(py, [script, ...args], { timeout: 20000, env: childEnv }, (err, out, errOut) => cb((out || errOut || String(err ?? "")).trim()));
}
async function sessionChannel(it: any): Promise<string> {
  try {
    const ch = it.channel ?? (await client.channels.fetch(it.channelId));
    if (ch?.isThread() && ch.parentId) return ch.parentId;
  } catch {}
  return it.channelId;
}
const MODELS = ["opus", "sonnet", "haiku", "fable", "opusplan", "default"];
client.on(Events.InteractionCreate, async (it) => {
  if (it.isAutocomplete()) {
    const focused = it.options.getFocused(true);
    const q = String(focused.value ?? "").toLowerCase();
    if (it.commandName === "model") {
      await it.respond(MODELS.filter((m) => m.includes(q)).map((m) => ({ name: m, value: m }))).catch(() => {});
      return;
    }
    if (it.commandName === "skill") {
      const ch = await sessionChannel(it);
      runPy(["skills", "--channel", ch, "--query", q], (out) => {
        let names: string[] = [];
        try { names = JSON.parse(out); } catch {}
        it.respond(names.slice(0, 25).map((n) => ({ name: n.slice(0, 100), value: n.slice(0, 100) }))).catch(() => {});
      });
    }
    return;
  }
  if (!it.isChatInputCommand()) return;
  if (!["compact", "model", "effort", "stop", "skill"].includes(it.commandName)) return;
  await it.deferReply().catch(() => {});        // 공개 — "○○님이 /skill 을 사용함" 밑 이 답에 ⚙️ → ✅/⚠️ 가 붙는다
  const reply = await it.fetchReply().catch(() => null);
  const ch = await sessionChannel(it);
  const value = it.options.getString("name") ?? it.options.getString("level") ?? "";
  const args = it.options.getString("args") ?? "";
  runPy(["slash-cmd", "--channel", ch, "--user", it.user.id, "--name", it.commandName, `--value=${value}`, `--args=${args}`,
         `--message=${reply?.id ?? ""}`],
    (out) => it.editReply({ content: out || "처리 못 했어", allowedMentions: { parse: [] } }).catch(() => {}));
});

// 권한 요청 [허용]/[거부](봇 4) — 기다리는 훅이 결과를 읽는다
client.on(Events.InteractionCreate, async (it) => {
  if (!it.isButton() || !it.customId.startsWith("mperm:")) return;
  const [, act, ch, token] = it.customId.split(":");
  await it.deferUpdate().catch(() => {});      // 결과는 요청 메시지 자체가 '✅ 허용함/⛔ 거부함' 으로 바뀐다
  if (ch !== (await sessionChannel(it))) { it.followUp("이 채널의 요청이 아니야").catch(() => {}); return; }   // 위조 방어선
  runPy(["perm", "--channel", ch, "--user", it.user.id, "--token", token, ...(act === "a" ? ["--allow"] : [])],
    (out) => { if (!["허용했어", "거부했어"].includes(out)) it.followUp({ content: out || "처리 못 했어", allowedMentions: { parse: [] } }).catch(() => {}); });
});

client.once(Events.ClientReady, (c) => {
  console.log(new Date().toISOString(), "ready", c.user.tag);
  runPy(["commands"], (out) => {
    try {
      c.application.commands.set(JSON.parse(out), guild)
        .then((r) => console.log(new Date().toISOString(), "commands", r.size))
        .catch((e) => console.log("commands failed", String(e)));
    } catch (e) { console.log("commands parse failed", String(e)); }
  });
});
if (parent > 0) {
  setInterval(() => {
    try { process.kill(parent, 0); } catch { process.exit(0); } // 데몬이 재시작되면 새 데몬이 다시 띄운다
  }, 10000);
}
client.login(process.env.DISCORD_BOT_TOKEN);
