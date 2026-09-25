// Supabase Edge Function: line-webhook
// Replies with the chat's groupId / userId when someone types "id" — used once to find LINE_TO.
// Deploy: supabase functions deploy line-webhook --no-verify-jwt
// Secrets: LINE_TOKEN (Channel access token), LINE_SECRET (Channel secret, optional but recommended)

async function validSig(body: string, sig: string | null) {
  const secret = Deno.env.get("LINE_SECRET"); if (!secret) return true;
  if (!sig) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)));
  return btoa(String.fromCharCode(...mac)) === sig;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  const body = await req.text();
  const sigOk = await validSig(body, req.headers.get("x-line-signature"));
  console.log("line-webhook", { sigOk, hasToken: !!Deno.env.get("LINE_TOKEN"), body: body.slice(0, 500) });
  if (!sigOk) return new Response("bad signature", { status: 401 });
  const token = Deno.env.get("LINE_TOKEN");
  let data: any = {}; try { data = JSON.parse(body); } catch { /* ignore */ }
  for (const ev of data.events || []) {
    const txt = String(ev?.message?.text || "").trim().toLowerCase().replace(/@\S+\s*/g, "").trim();
    if (ev.type === "join" || (ev.type === "message" && /^(id|ไอดี|groupid)$/.test(txt))) {
      if (!token || !ev.replyToken) { console.error("missing LINE_TOKEN or replyToken"); continue; }
      const s = ev.source || {}, id = s.groupId || s.roomId || s.userId;
      const kind = s.groupId ? "groupId" : s.roomId ? "roomId" : "userId";
      const r = await fetch("https://api.line.me/v2/bot/message/reply", {
        method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + token },
        body: JSON.stringify({ replyToken: ev.replyToken, messages: [{ type: "text", text: kind + ":\n" + id + "\n\nนำค่านี้ไปใส่ใน Supabase Secret ชื่อ LINE_TO" }] }),
      });
      if (!r.ok) console.error("LINE reply failed", r.status, await r.text());
    }
  }
  return new Response("ok");
});
