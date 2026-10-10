// Canal direto pelo Telegram (Premium e Gemelar Premium) — webhook do bot.
//
// A paciente conversa em privado com o bot; cada mensagem é copiada para um tópico próprio
// (nome da paciente) no grupo privado da Dra. Morgana. A resposta dela, escrita no tópico,
// volta à paciente como mensagem do bot. Histórico em telegram_mensagens.
//
// Secrets da função (Supabase → Edge Functions → Secrets):
//   TELEGRAM_BOT_TOKEN       token do @BotFather
//   TELEGRAM_GROUP_ID        id do grupo privado (número negativo, começa com -100)
//   TELEGRAM_WEBHOOK_SECRET  texto qualquer, o mesmo passado no setWebhook (secret_token)
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem em toda Edge Function.
//
// Deploy com verificação de JWT desligada (o Telegram não envia JWT):
//   supabase functions deploy telegram-bot --no-verify-jwt
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const GROUP = Number(Deno.env.get("TELEGRAM_GROUP_ID") ?? "0");
const SECRET = Deno.env.get("TELEGRAM_WEBHOOK_SECRET") ?? "";
const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const PLANOS_COM_CANAL = ["premium", "gemelar_dc"];

const BOAS_VINDAS =
  "Olá! Este é o canal direto com a Dra. Morgana Kummer, do seu Acompanhamento Fetal MK.\n\n" +
  "• Respondemos em dias úteis, em horário comercial.\n" +
  "• Este canal NÃO é para urgências. Em caso de sangramento, perda de líquido, dor intensa, " +
  "diminuição dos movimentos do bebê ou qualquer sinal de alerta, procure a maternidade ou o seu obstetra.\n" +
  "• Ele vale até o parto e serve para dúvidas sobre os exames do acompanhamento.\n\n" +
  "Pode escrever sua mensagem aqui.";

async function tg(metodo: string, corpo: Record<string, unknown>) {
  const r = await fetch(`https://api.telegram.org/bot${TOKEN}/${metodo}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(corpo),
  });
  const j = await r.json().catch(() => ({}));
  if (!j.ok) console.error("[telegram]", metodo, JSON.stringify(j));
  return j;
}

async function registrar(gestacao_id: number, direcao: string, texto: string | null, tipo: string) {
  const { error } = await db.from("telegram_mensagens").insert({ gestacao_id, direcao, texto, tipo });
  if (error) console.error("[log]", error.message);
}

function tipoDe(m: Record<string, unknown>): string {
  for (const k of ["photo", "voice", "audio", "video", "video_note", "document", "sticker", "contact", "location"]) {
    if (m[k]) return k;
  }
  return "text";
}

// Elegível = gestação ativa, não excluída, de plano Premium / Gemelar Premium.
async function elegivel(gestacao_id: number): Promise<{ ok: boolean; nome: string }> {
  const { data } = await db.from("gestacoes")
    .select("status, excluido_em, acompanhamento, patients(nome)")
    .eq("id", gestacao_id).maybeSingle();
  // deno-lint-ignore no-explicit-any
  const g = data as any;
  const nome = (Array.isArray(g?.patients) ? g.patients[0]?.nome : g?.patients?.nome) ?? "Paciente";
  const ok = !!g && g.status === "ativa" && !g.excluido_em && PLANOS_COM_CANAL.includes(g.acompanhamento);
  return { ok, nome };
}

async function bloquear(v: { gestacao_id: number; chat_id: number | null; topic_id: number | null }, avisar: boolean) {
  await db.from("telegram_vinculos")
    .update({ bloqueado: true, bloqueado_em: new Date().toISOString() })
    .eq("gestacao_id", v.gestacao_id);
  if (v.topic_id) await tg("closeForumTopic", { chat_id: GROUP, message_thread_id: v.topic_id });
  if (avisar && v.chat_id) {
    await tg("sendMessage", {
      chat_id: v.chat_id,
      text: "Este canal direto foi encerrado, pois o acompanhamento não inclui mais essa modalidade. " +
        "Para qualquer assunto, fale com a clínica pelos canais de atendimento.",
    });
  }
  await registrar(v.gestacao_id, "bot", "Canal encerrado (plano encerrado ou modalidade sem canal direto).", "sistema");
}

// Varre os vínculos ativos e bloqueia quem perdeu a elegibilidade (plano encerrado, troca de modalidade).
async function varrer() {
  const { data } = await db.from("telegram_vinculos")
    .select("gestacao_id, chat_id, topic_id")
    .eq("bloqueado", false).not("chat_id", "is", null);
  for (const v of data ?? []) {
    if (!(await elegivel(v.gestacao_id)).ok) await bloquear(v, true);
  }
}

async function privado(m: Record<string, any>) {
  const chat_id: number = m.chat.id;
  const texto: string = m.text ?? "";

  // /start <codigo>: vincula (uso único) ou reapresenta.
  if (texto.startsWith("/start")) {
    const codigo = texto.split(/\s+/)[1]?.trim();
    if (!codigo) {
      await tg("sendMessage", { chat_id, text: "Para ativar o canal, use o QR code do seu contrato do acompanhamento." });
      return;
    }
    const { data: v } = await db.from("telegram_vinculos").select("*").eq("codigo", codigo).maybeSingle();
    if (!v || v.bloqueado) {
      await tg("sendMessage", { chat_id, text: "Código inválido ou já encerrado. Fale com a clínica para receber um novo QR code." });
      return;
    }
    if (v.chat_id && v.chat_id !== chat_id) {
      await tg("sendMessage", { chat_id, text: "Este código já foi utilizado por outro contato. Fale com a clínica." });
      return;
    }
    const el = await elegivel(v.gestacao_id);
    if (!el.ok) {
      await tg("sendMessage", { chat_id, text: "Seu acompanhamento não inclui o canal direto. Fale com a clínica." });
      return;
    }
    if (!v.chat_id) {
      const t = await tg("createForumTopic", { chat_id: GROUP, name: el.nome.slice(0, 120) });
      const topic_id = t.result?.message_thread_id;
      if (!topic_id) {
        await tg("sendMessage", { chat_id, text: "Não consegui ativar agora. Tente de novo em alguns minutos ou fale com a clínica." });
        return;
      }
      await db.from("telegram_vinculos")
        .update({ chat_id, topic_id, vinculado_em: new Date().toISOString() })
        .eq("gestacao_id", v.gestacao_id);
      await tg("sendMessage", { chat_id: GROUP, message_thread_id: topic_id, text: `Canal ativado: ${el.nome}.` });
      await registrar(v.gestacao_id, "bot", "Canal ativado.", "sistema");
    }
    await tg("sendMessage", { chat_id, text: BOAS_VINDAS });
    return;
  }

  // Mensagem comum: acha o vínculo desta conversa.
  const { data: v } = await db.from("telegram_vinculos").select("*")
    .eq("chat_id", chat_id).order("criado_em", { ascending: false }).limit(1).maybeSingle();
  if (!v) {
    await tg("sendMessage", { chat_id, text: "Para usar este canal, ative-o pelo QR code do seu contrato do acompanhamento." });
    return;
  }
  if (v.bloqueado || !(await elegivel(v.gestacao_id)).ok) {
    if (!v.bloqueado) await bloquear(v, false);
    await tg("sendMessage", { chat_id, text: "Este canal direto está encerrado. Fale com a clínica pelos canais de atendimento." });
    return;
  }
  const r = await tg("copyMessage", {
    chat_id: GROUP, message_thread_id: v.topic_id, from_chat_id: chat_id, message_id: m.message_id,
  });
  if (!r.ok) {
    await tg("sendMessage", { chat_id, text: "Não consegui entregar sua mensagem agora. Tente novamente em instantes." });
    return;
  }
  await registrar(v.gestacao_id, "paciente", m.text ?? m.caption ?? null, tipoDe(m));
}

async function grupo(m: Record<string, any>) {
  if (m.from?.is_bot) return; // não reflete as próprias cópias do bot
  const topic_id = m.message_thread_id;
  if (!topic_id) return; // tópico "Geral": ignora
  const { data: v } = await db.from("telegram_vinculos").select("*").eq("topic_id", topic_id).maybeSingle();
  if (!v || !v.chat_id) return;
  if (v.bloqueado) return;
  if (!(await elegivel(v.gestacao_id)).ok) { await bloquear(v, true); return; }
  const r = await tg("copyMessage", { chat_id: v.chat_id, from_chat_id: GROUP, message_id: m.message_id });
  if (!r.ok) return; // mensagem de serviço do Telegram (tópico criado/fechado etc.)
  await registrar(v.gestacao_id, "medica", m.text ?? m.caption ?? null, tipoDe(m));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  if (!SECRET || req.headers.get("x-telegram-bot-api-secret-token") !== SECRET) {
    return new Response("forbidden", { status: 403 });
  }
  try {
    const u = await req.json();
    const m = u.message;
    if (m) {
      if (m.chat?.type === "private") await privado(m);
      else if (m.chat?.id === GROUP) await grupo(m);
    }
    await varrer();
  } catch (e) {
    console.error("[telegram-bot]", e);
  }
  return new Response("ok"); // sempre 200, senão o Telegram reenvia
});
