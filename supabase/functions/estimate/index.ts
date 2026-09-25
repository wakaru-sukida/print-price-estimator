// Supabase Edge Function: estimate
// Computes customer prices on the server from public.rate_card (customer cost).
// Only totals are returned — per-item cost rates never leave the server.
// Deploy: supabase functions deploy estimate --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-device-id",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const TYPES: Record<string, any[]> = {"offset":[{"id":"box","shape":"box"},{"id":"bag","shape":"bag"},{"id":"sticker","shape":"flat"},{"id":"label","shape":"flat"},{"id":"tag","shape":"flat"},{"id":"bizcard","shape":"flat"},{"id":"folder","shape":"flat"},{"id":"card","shape":"flat"},{"id":"envelope","shape":"flat"},{"id":"book","shape":"book"},{"id":"calendar","shape":"book"},{"id":"brochure","shape":"flat"},{"id":"catalog","shape":"book"},{"id":"other","shape":"flat"}],"flexible":[{"id":"opp","shape":"pouch","seal":"3side"},{"id":"hanger","shape":"pouch","seal":"3side","hanger":true},{"id":"center","shape":"pouch","seal":"center"},{"id":"gusset","shape":"pouch","seal":"center","needD":true},{"id":"vacuum","shape":"pouch","seal":"3side"},{"id":"standup","shape":"pouch","seal":"standup","needD":true},{"id":"4side","shape":"pouch","seal":"4side"},{"id":"filmlabel","shape":"cyl"},{"id":"foilroll","shape":"roll"},{"id":"diecut","shape":"pouch","seal":"4side","diecut":true}],"gravure":[{"id":"shrink","shape":"cyl","sleeve":true},{"id":"center","shape":"pouch","seal":"center"},{"id":"standup","shape":"pouch","seal":"standup","needD":true},{"id":"3side","shape":"pouch","seal":"3side"},{"id":"autoroll","shape":"roll"},{"id":"wrap","shape":"cyl"},{"id":"zip","shape":"pouch","seal":"standup","needD":true,"zip":true}]};
const PAPERS: any[] = [{"id":"pond","min":60,"max":120,"def":80},{"id":"greenread","min":60,"max":80,"def":70},{"id":"artgloss","min":80,"max":160,"def":128},{"id":"artmatt","min":80,"max":160,"def":128},{"id":"artcard1","min":200,"max":400,"def":300},{"id":"artcard2","min":190,"max":360,"def":260},{"id":"ivory","min":210,"max":400,"def":300},{"id":"fancy","min":200,"max":300,"def":250},{"id":"duplex","min":210,"max":500,"def":350},{"id":"kraftbox","min":150,"max":450,"def":250},{"id":"eflute","min":0,"max":0,"def":0,"m2":true},{"id":"kraft","min":125,"max":300,"def":150},{"id":"st_gloss","min":0,"max":0,"def":0,"m2":true},{"id":"st_matt","min":0,"max":0,"def":0,"m2":true},{"id":"st_ppw","min":0,"max":0,"def":0,"m2":true},{"id":"st_ppc","min":0,"max":0,"def":0,"m2":true},{"id":"st_holo","min":0,"max":0,"def":0,"m2":true},{"id":"st_kraft","min":0,"max":0,"def":0,"m2":true}];
const STAMP_IDS: string[] = ["gold","silver","color","emboss","deboss","diecut"];
const COAT_IDS: Record<string, string[]> = {"offset":["varnish","uvfull","uvspot","pvcgloss","pvcmatt","matt"],"flexible":["mattv"],"gravure":["mattv","glossv"]};

const CUTS: Record<number, [number, number]> = { 1: [1,1], 2: [2,1], 3: [3,1], 4: [2,2], 6: [3,2], 8: [4,2], 9: [3,3], 16: [4,4] };
const sheetDefault = (id: string) => id === "eflute" ? '100x120 (1,2,4)' : /^st_/.test(id) ? '50x70 (1,2,4)' : '31x43" (1,2,4); 24x35" (1,2)';
function parseSheets(txt: string) {
  const out: any[] = [];
  String(txt || "").split(/[;\n|]+/).forEach((tok) => {
    const m = tok.trim().match(/^(\d+(?:\.\d+)?)\s*[x×*]\s*(\d+(?:\.\d+)?)\s*("|in|นิ้ว)?\s*(?:\(([^)]*)\))?/i); if (!m) return;
    const f = m[3] ? 2.54 : 1, a = +m[1] * f, b = +m[2] * f, L = Math.max(a, b), Sh = Math.min(a, b);
    let cuts = m[4] ? m[4].split(/[,\s]+/).map(Number).filter((n) => CUTS[n]) : [1]; if (!cuts.length) cuts = [1];
    cuts.forEach((n) => { const [dl, ds] = CUTS[n], w = Sh / ds, h = L / dl; out.push({ w: Math.min(w, h), h: Math.max(w, h), m2: w * h / 1e4 }); });
  });
  return out;
}
let SHEET_CFG: Record<string, string> = {};
const sheetsFor = (id: string) => { const v = SHEET_CFG[id]; const p = parseSheets(v && v.trim() ? v : sheetDefault(id)); return p.length ? p : parseSheets(sheetDefault(id)); };
const fitUps = (pw: number, ph: number, S: any) => { const uw = S.w - 2, uh = S.h - 2, a = pw + 0.6, b = ph + 0.6; if (a <= 0.6 || b <= 0.6) return 0; return Math.max(Math.floor(uw/a)*Math.floor(uh/b), Math.floor(uw/b)*Math.floor(uh/a)); };
const DIE_TYPES = ["box","bag","sticker","label","tag","folder","envelope"];
const num = (v: unknown) => { const n = parseFloat(String(v)); return isFinite(n) ? n : 0; };
const clamp = (v: number, a: number, b: number) => Math.min(b, Math.max(a, v));
const r2 = (v: number) => Math.round(v * 100) / 100;
function daysUntil(s: unknown) {
  const b = Date.parse(String(s)); if (isNaN(b)) return 99;
  const today = Date.parse(new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10)); // Asia/Bangkok
  return Math.round((b - today) / 864e5);
}

function calc(P: string, f: any, R: (id: string) => number, qIn?: number, mPct = 0) {
  const list = TYPES[P]; if (!list) throw new Error("invalid process");
  const ty = list.find((x) => x.id === f?.type) || list[0], sh = ty.shape;
  const W = clamp(num(f.w), 0, 1000), H = clamp(num(f.h), 0, 1000), D = clamp(num(f.d), 0, 1000);
  const q = Math.max(1, Math.min(1e8, Math.round(qIn || num(f.qty))));
  const colors = clamp(Math.round(num(f.colors)) || 1, 1, 12);
  let cost = 0, tool = 0; const add = (a: number) => { cost += Math.max(0, a || 0); }; const TL = (a: number) => { tool += Math.max(0, a || 0); return a; };
  if (P === "offset") {
    const pa = PAPERS.find((p) => p.id === f.paper) || PAPERS[0];
    const gsm = pa.m2 ? 0 : clamp(num(f.gsm) || pa.def, pa.min, pa.max);
    const pages = Math.max(4, Math.min(2000, Math.round(num(f.pages)))), sides = f.sides == 2 ? 2 : 1;
    const book = sh === "book";
    const fw = sh === "box" ? 2*W+2*D+1.5 : sh === "bag" ? 2*W+2*D+2 : W, fh = sh === "box" ? H+2*D+3 : sh === "bag" ? H+D*0.75+4 : H;
    const wMr = R("waste.offset.mr"), wRun = R("waste.offset.run") / 100, pImp = R("press.offset.k") / 1000;
    const pick = (pw: number, ph: number, rateId: string, g: number, need: number, sd: number, perSheet?: (u: number) => number) => {
      let best: any = null;
      for (const S of sheetsFor(rateId.replace("paper.", ""))) {
        const ups = fitUps(pw, ph, S); if (ups < 1) continue;
        const per = perSheet ? perSheet(ups) : ups, net = Math.ceil(need / per), forms = book && perSheet ? Math.ceil(pages / (2 * ups)) : 1;
        const gross = net + wMr * forms + Math.ceil(net * wRun);
        const cst = gross * S.m2 * (g ? g / 1000 : 1) * R(rateId) + gross * sd * colors * pImp;
        if (!best || cst < best.cst) best = { S, ups, net, forms, gross, cst };
      }
      if (!best) { const net = Math.ceil(need); best = { S: { m2: (pw + 2.6) * (ph + 2.6) / 1e4 }, ups: 1, net, forms: 1, gross: net + wMr + Math.ceil(net * wRun), cst: 0 }; }
      return best;
    };
    const B = book ? pick(W, H, "paper." + pa.id, gsm, q * pages, 2, (u) => 2 * u) : pick(fw, fh, "paper." + pa.id, gsm, q, sides);
    add(B.gross * B.S.m2 * (pa.m2 ? 1 : gsm / 1000) * R("paper." + pa.id));
    let C: any = null;
    if (book) { const cw = 2*W + pages*0.006 + 0.6; C = pick(cw, H, "paper.artcard2", 260, q, 1); add(C.gross * C.S.m2 * 0.26 * R("paper.artcard2")); }
    const forms = B.forms + (book ? 1 : 0);
    add(TL(colors * sides * R("plate.offset") * forms));
    add(R("mr.offset") * forms);
    add((B.gross * (book ? 2 : sides) * colors + (C ? C.gross * colors : 0)) / 1000 * R("press.offset.k"));
    const st: string[] = Array.isArray(f.stamps) ? f.stamps.filter((x: string) => STAMP_IDS.includes(x)) : [];
    st.forEach((id) => add(TL(R("fin." + id + ".set")) + R("fin." + id) * q));
    if (DIE_TYPES.includes(ty.id) && !st.includes("diecut")) add(TL(R("fin.diecut.set")) + R("fin.diecut") * q);
    if (f.coat && COAT_IDS.offset.includes(f.coat)) { const X = C || B; add(TL(R("coat.offset." + f.coat + ".set")) + X.gross * X.S.m2 * R("coat.offset." + f.coat)); }
    if (sh === "box") add(R("conv.boxglue") * q);
    if (sh === "bag") add(R("conv.bag") * q);
    if (book) add((R("conv.bind") + R("conv.bindpage") * pages) * q);
  } else {
    let mats: string[] = Array.isArray(f.mats) ? f.mats.slice(0, 3).map(String) : [];
    if (!mats.length) mats = ["BOPP"];
    const area = sh === "pouch" ? (ty.seal === "center" ? 2*W + (ty.needD ? 2*D : 0) + 2 : 2*W) * H + (ty.seal === "standup" ? 2*D*W : 0) : sh === "cyl" ? (W + 0.8) * H : W * H;
    const m2 = area / 1e4, rate = mats.reduce((a, m) => a + R("film." + m), 0);
    const pw = sh === "pouch" ? (ty.seal === "center" ? 2*W + (ty.needD ? 2*D : 0) + 2 : 2*W) : sh === "cyl" ? W + 0.8 : W;
    const wk = P === "flexible" ? "flexo" : "gravure", maxWeb = R("web." + wk) || (P === "flexible" ? 60 : 110);
    const lanes = Math.max(1, Math.floor(maxWeb / Math.max(pw, 0.1))), web = Math.max(pw, Math.min(maxWeb, lanes * pw));
    const Aeff = m2 * q * (1 + R("waste." + wk + ".run") / 100) + R("waste." + wk + ".mr") * web / 100;
    add(Aeff * rate);
    if (mats.length > 1) add(Aeff * R("conv.lam") * (mats.length - 1));
    const nc = colors + (f.white ? 1 : 0);
    if (P === "flexible") { add(TL(nc * R("plate.flexo"))); add(R("mr.flexo")); add(Aeff * nc * R("press.flexo")); }
    else { add(TL(nc * R("cyl.gravure"))); add(R("mr.gravure")); add(Aeff * nc * R("press.gravure")); }
    if (f.coat && (COAT_IDS[P] || []).includes(f.coat)) add(Aeff * R("coat." + P + "." + f.coat));
    if (sh === "pouch") {
      const pk = ty.needD && ty.seal === "center" ? "gusset" : ty.seal;
      add(R("conv.pouch." + pk) * q);
      if (ty.zip) add(R("conv.zip") * q);
      if (ty.hanger) add(R("conv.hanger") * q);
      if (ty.diecut) add(TL(R("conv.thomson.set")) + R("conv.thomson") * q);
    } else if (sh === "cyl") add(R(ty.sleeve ? "conv.sleeve" : "conv.labelcut") * q);
    else add(R("conv.slit") * q);
  }
  const days = daysUntil(f.date), rushPct = days < 3 ? 0.3 : days < 7 ? 0.15 : 0;
  const rush = cost * rushPct, marginAmt = (cost + rush) * clamp(mPct, 0, 100) / 100, subtotal = cost + rush + marginAmt, vat = subtotal * 0.07;
  return { subtotal: r2(subtotal), vat: r2(vat), total: r2(subtotal + vat), unit: Math.round(subtotal / q * 10000) / 10000, rush: r2(rush), rushPct, q, tooling: r2(tool * (1 + rushPct) * (1 + clamp(mPct, 0, 100) / 100)) };
}

async function notifyLine(row: any, summary: any) {
  const token = Deno.env.get("LINE_TOKEN"), to = (Deno.env.get("LINE_TO") || "").split(",").map((s) => s.trim()).filter(Boolean);
  if (!token || !to.length) return;
  const money = (v: number) => "฿" + Number(v || 0).toLocaleString("en-US", { maximumFractionDigits: 0 });
  const sp = summary || {};
  const lines = [
    (row.kind === "order" ? "🏭 คำสั่งผลิตใหม่ " : "🧾 ใบเสนอราคาใหม่ ") + row.quote_no,
    row.contact_name + (row.company ? " · " + row.company : ""),
    String(row.process || "").toUpperCase() + (sp.title ? " · " + sp.title : "") + (sp.size ? " · " + sp.size : "") + " · " + Number(row.qty || 0).toLocaleString("en-US") + " ชิ้น",
    sp.mat ? "วัสดุ: " + sp.mat : "",
    sp.print ? "พิมพ์: " + sp.print : "",
    sp.fin && sp.fin !== "—" ? "งานหลังพิมพ์: " + sp.fin : "",
    row.spec?.date ? "ต้องการ: " + row.spec.date : "",
    "ยอดรวม " + money(row.total) + " (รวม VAT)",
    row.phone ? "โทร " + row.phone : "",
    row.email ? "อีเมล " + row.email : "",
    row.notes ? "หมายเหตุ: " + String(row.notes).slice(0, 300) : "",
  ].filter(Boolean).join("\n");
  await Promise.all(to.map((id) => fetch("https://api.line.me/v2/bot/message/push", {
    method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + token },
    body: JSON.stringify({ to: id, messages: [{ type: "text", text: lines.slice(0, 4900) }] }),
  }).then((r) => { if (!r.ok) return r.text().then((t) => console.error("LINE push failed", r.status, t)); }).catch((e) => console.error("LINE push error", e))));
}

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
const str = (v: unknown, n: number) => (v == null || v === "" ? null : String(v).trim().slice(0, n) || null);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data, error } = await sb.from("rate_card").select("id,cust_cost");
    if (error) throw error;
    const rates: Record<string, number> = {};
    (data || []).forEach((r: any) => { rates[r.id] = num(r.cust_cost); });
    const R = (id: string) => rates[id] || 0;
    const ms = await sb.from("material_sheets").select("id,sizes");
    SHEET_CFG = {}; if (!ms.error) (ms.data || []).forEach((r: any) => { SHEET_CFG[r.id] = String(r.sizes || ""); });

    if (body.action === "quote") {
      const q = body.quote || {};
      if (q.consent !== true) return json({ error: "consent required" }, 400);
      const name = str(q.contact_name, 200); if (!name) return json({ error: "contact_name required" }, 400);
      const email = str(q.email, 200), phone = str(q.phone, 50);
      if (!email && !phone) return json({ error: "email or phone required" }, 400);
      const form = q.form && typeof q.form === "object" ? q.form : {};
      let margin = 0;
      if (num(q.margin) > 0) {
        const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
        const u = token ? await sb.auth.getUser(token) : null;
        const uid = u?.data?.user?.id;
        if (uid) {
          const p = await sb.from("staff_profiles").select("role").eq("id", uid).maybeSingle();
          if (p.data && (p.data.role === "admin" || p.data.role === "staff")) margin = num(q.margin);
        }
      }
      const r = calc(String(q.process), form, R, num(q.qty), margin);
      const row = {
        quote_no: str(q.quote_no, 40) || "RMX-" + Date.now(), kind: q.kind === "order" ? "order" : "quote",
        process: String(q.process), product_type: String(form.type || ""), spec: { ...form, summary: q.summary ?? null },
        qty: r.q, subtotal: r.subtotal, vat: r.vat, total: r.total,
        contact_name: name, company: str(q.company, 200), email, phone, notes: str(q.notes, 2000),
        consent: true, device_id: str(q.device_id, 80),
      };
      const ins = await sb.from("quotes").insert(row);
      if (ins.error) return json({ error: ins.error.message }, 400);
      try { await notifyLine(row, q.summary); } catch (e) { console.error(e); }
      return json({ ok: true, quote_no: row.quote_no, ...r });
    }

    const items = Array.isArray(body.items) ? body.items.slice(0, 40) : [];
    const results = items.map((it: any) => { try { return calc(String(it.process), it.form || {}, R, num(it.qty)); } catch { return null; } });
    return json({ results });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
