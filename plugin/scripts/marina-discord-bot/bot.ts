// 마리나 Discord 봇 — 공식 Discord 플러그인이 못 받는 이벤트만 받는다(지금은 🛑 반응).
// 판단은 전부 파이썬(marina_discord_bot.py interrupt)에 맡긴다. 마리나 데몬이 띄우고, 데몬이 죽으면 따라 끝난다.
import { Client, Events, GatewayIntentBits, Partials } from "discord.js";
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

client.once(Events.ClientReady, (c) => console.log(new Date().toISOString(), "ready", c.user.tag));
if (parent > 0) {
  setInterval(() => {
    try { process.kill(parent, 0); } catch { process.exit(0); } // 데몬이 재시작되면 새 데몬이 다시 띄운다
  }, 10000);
}
client.login(process.env.DISCORD_BOT_TOKEN);
