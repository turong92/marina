// 마리나 Discord 봇 — 공식 Discord 플러그인이 못 받는 이벤트만 받는다(지금은 🛑 반응).
// 판단은 전부 파이썬(marina_discord_bot.py interrupt)에 맡긴다. 마리나 데몬이 띄우고, 데몬이 죽으면 따라 끝난다.
import { ActionRowBuilder, Client, Events, GatewayIntentBits, ModalBuilder, Partials, TextInputBuilder, TextInputStyle } from "discord.js";
import { execFile } from "node:child_process";

const guild = process.env.MARINA_GUILD ?? "";
const py = process.env.MARINA_PY ?? "python3";
const script = process.env.MARINA_BOT_PY ?? "";
const parent = Number(process.env.MARINA_PARENT_PID ?? 0);
// 파이썬은 토큰을 설정 파일에서 직접 읽는다 — 자식에게 토큰 env 를 물려주지 않는다
const childEnv = { ...process.env };
delete childEnv.DISCORD_BOT_TOKEN;

const client = new Client({
  intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessageReactions],
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

// #상태 대시보드의 [정지] 버튼 — 🛑 반응과 같은 처리. 결과는 누른 사람에게만 보인다
client.on(Events.InteractionCreate, async (it) => {
  if (!it.isButton() || !it.customId.startsWith("marina-stop:")) return;
  const channelId = it.customId.slice("marina-stop:".length);
  await it.deferReply({ ephemeral: true }).catch(() => {});
  execFile(py, [script, "interrupt", "--channel", channelId, "--user", it.user.id, "--message", ""],
    { timeout: 20000, env: childEnv }, (err, out, errOut) => {
      const msg = (out || errOut || String(err ?? "")).trim() || "처리 못 했어";
      console.log(new Date().toISOString(), "stop-button", channelId, msg);
      it.editReply(`<#${channelId}> ${msg}`).catch(() => {});
    });
});

// #상태 [보기] — 뒤에서 도는 셸 출력 끝·에이전트 마지막 말을 누른 사람에게만
client.on(Events.InteractionCreate, async (it) => {
  if (!it.isButton() || !it.customId.startsWith("marina-view:")) return;
  const channelId = it.customId.slice("marina-view:".length);
  await it.deferReply({ ephemeral: true }).catch(() => {});
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
  await it.deferReply({ ephemeral: true }).catch(() => {});
  execFile(py, [script, "say", "--channel", channelId, "--user", it.user.id, "--message", it.message.id],
    { timeout: 20000, env: childEnv }, (err, out, errOut) => {
      const msg = (out || errOut || String(err ?? "")).trim() || "처리 못 했어";
      it.editReply({ content: msg, allowedMentions: { parse: [] } }).catch(() => {});
    });
});

// 질문 버튼(봇 3): mq=단일 선택 버튼, mqm=다중 드롭다운, mqo=기타 입력 팝업 열기, mqt=팝업 제출
const askPy = script.replace(/marina_discord_bot\.py$/, "marina_discord_ask.py");
function answer(it: any, channelId: string, q: string, extra: string[]) {
  execFile(py, [askPy, "answer", "--channel", channelId, "--user", it.user.id, "--q", q, `--message=${it.message?.id ?? ""}`, ...extra],
    { timeout: 20000, env: childEnv }, (err, out, errOut) => {
      const msg = (out || errOut || String(err ?? "")).trim() || "처리 못 했어";
      it.editReply({ content: msg, allowedMentions: { parse: [] } }).catch(() => {});
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
    await it.deferReply({ ephemeral: true }).catch(() => {});
    answer(it, ch, q, ["--picks", o]);
    return;
  }
  if (it.isStringSelectMenu() && it.customId.startsWith("mqm:")) {
    const [, ch, q] = it.customId.split(":");
    await it.deferReply({ ephemeral: true }).catch(() => {});
    answer(it, ch, q, ["--picks", it.values.join(",")]);
    return;
  }
  if (it.isModalSubmit() && it.customId.startsWith("mqt:")) {
    const [, ch, q] = it.customId.split(":");
    await it.deferReply({ ephemeral: true }).catch(() => {});
    answer(it, ch, q, [`--text=${it.fields.getTextInputValue("text")}`]); // = 로 붙여 '-' 로 시작하는 글도 값으로
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
  await it.deferReply({ ephemeral: true }).catch(() => {});
  const ch = await sessionChannel(it);
  const value = it.options.getString("name") ?? it.options.getString("level") ?? "";
  const args = it.options.getString("args") ?? "";
  runPy(["slash-cmd", "--channel", ch, "--user", it.user.id, "--name", it.commandName, `--value=${value}`, `--args=${args}`],
    (out) => it.editReply({ content: out || "처리 못 했어", allowedMentions: { parse: [] } }).catch(() => {}));
});

// 권한 요청 [허용]/[거부](봇 4) — 기다리는 훅이 결과를 읽는다
client.on(Events.InteractionCreate, async (it) => {
  if (!it.isButton() || !it.customId.startsWith("mperm:")) return;
  const [, act, ch, token] = it.customId.split(":");
  await it.deferReply({ ephemeral: true }).catch(() => {});
  if (ch !== (await sessionChannel(it))) { it.editReply("이 채널의 요청이 아니야").catch(() => {}); return; }   // 위조 방어선
  runPy(["perm", "--channel", ch, "--user", it.user.id, "--token", token, ...(act === "a" ? ["--allow"] : [])],
    (out) => it.editReply({ content: out || "처리 못 했어", allowedMentions: { parse: [] } }).catch(() => {}));
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
