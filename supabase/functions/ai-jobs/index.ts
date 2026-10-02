// POST /functions/v1/ai-jobs
//   { task, input_path, params }          → create job (checks ai_enabled, plan, monthly credits) and start provider prediction
//   { action: 'status', job_id }          → refresh job status from provider; stores result in media/<uid>/ai/
// Provider: Replicate-compatible HTTP API (swap callProvider/pollProvider for another vendor or a self-hosted model server).
// Model versions are configured per task with secrets AI_MODEL_<TASK> (e.g. AI_MODEL_REMOVE_BG=<version hash>).
import { adminClient, getSetting, handle, HttpError, json, requireUser } from "../_shared/common.ts";

const TASKS = ["illustration", "painting", "watercolor", "oil", "sketch", "anime", "abstract", "remove_bg", "outpaint", "upscale", "object_remove"];
const STYLE_PROMPTS: Record<string, string> = {
  illustration: "clean digital illustration", painting: "fine art painting", watercolor: "loose watercolor painting",
  oil: "impasto oil painting", sketch: "graphite pencil sketch", anime: "cel animation style", abstract: "abstract expressionist reinterpretation",
};
const API = Deno.env.get("AI_API_BASE") ?? "https://api.replicate.com/v1";
const TOKEN = Deno.env.get("AI_API_TOKEN") ?? "";

async function callProvider(task: string, imageUrl: string, prompt: string) {
  const version = Deno.env.get(`AI_MODEL_${task.toUpperCase()}`);
  if (!TOKEN) throw new HttpError(503, "AI provider token (AI_API_TOKEN) is not configured");
  if (!version) throw new HttpError(503, `No model configured for task "${task}" (AI_MODEL_${task.toUpperCase()})`);
  const input: Record<string, unknown> = { image: imageUrl };
  if (STYLE_PROMPTS[task]) input.prompt = [STYLE_PROMPTS[task], prompt].filter(Boolean).join(", ");
  else if (prompt) input.prompt = prompt;
  const r = await fetch(`${API}/predictions`, { method: "POST", headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" }, body: JSON.stringify({ version, input }) });
  const j = await r.json();
  if (!r.ok) throw new HttpError(502, j.detail ?? "Provider error");
  return j as { id: string; status: string };
}
async function pollProvider(id: string) {
  const r = await fetch(`${API}/predictions/${id}`, { headers: { Authorization: `Bearer ${TOKEN}` } });
  const j = await r.json();
  if (!r.ok) throw new HttpError(502, j.detail ?? "Provider error");
  return j as { status: string; output?: string | string[]; error?: string };
}

Deno.serve(handle(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "POST only");
  const user = await requireUser(req);
  const db = adminClient();
  const body = await req.json().catch(() => ({}));

  if (body.action === "status") {
    const { data: job } = await db.from("ai_jobs").select("*").eq("id", body.job_id).eq("user_id", user.id).maybeSingle();
    if (!job) throw new HttpError(404, "Job not found");
    if (!["queued", "processing"].includes(job.status) || !job.provider_job_id) return json(req, { job });
    const p = await pollProvider(job.provider_job_id);
    if (p.status === "succeeded") {
      const outUrl = Array.isArray(p.output) ? p.output[p.output.length - 1] : p.output;
      if (!outUrl) throw new HttpError(502, "Provider returned no output");
      const file = await fetch(outUrl);
      const type = file.headers.get("content-type") ?? "image/png";
      const path = `${user.id}/ai/${job.id}-result.${type.includes("jpeg") ? "jpg" : "png"}`;
      const up = await db.storage.from("media").upload(path, await file.arrayBuffer(), { contentType: type, upsert: true });
      if (up.error) throw up.error;
      const { data: signed } = await db.storage.from("media").createSignedUrl(path, 60 * 60 * 24 * 7);
      await db.from("ai_jobs").update({ status: "succeeded", result_path: path, result_url: signed?.signedUrl ?? null }).eq("id", job.id);
    } else if (p.status === "failed" || p.status === "canceled") {
      await db.from("ai_jobs").update({ status: p.status === "failed" ? "failed" : "canceled", error_message: p.error ?? "Provider failed" }).eq("id", job.id);
      // refund the credit
      const { data: prof } = await db.from("profiles").select("ai_credits_used").eq("id", user.id).single();
      await db.from("profiles").update({ ai_credits_used: Math.max(0, (prof?.ai_credits_used ?? 1) - job.credits) }).eq("id", user.id);
    } else {
      await db.from("ai_jobs").update({ status: "processing" }).eq("id", job.id);
    }
    const { data: fresh } = await db.from("ai_jobs").select("*").eq("id", job.id).single();
    return json(req, { job: fresh });
  }

  // ---------- create job
  const task = String(body.task ?? "");
  const inputPath = String(body.input_path ?? "");
  if (!TASKS.includes(task)) throw new HttpError(400, "Unknown task");
  if (!inputPath.startsWith(`${user.id}/`)) throw new HttpError(403, "Input must be in your own media folder");
  if (!(await getSetting<boolean>(db, "ai_enabled", false))) throw new HttpError(503, "AI features are disabled by the administrator");

  const { data: prof } = await db.from("profiles").select("subscription_plan, subscription_status, account_status, ai_credits_used, ai_credits_period").eq("id", user.id).single();
  if (prof?.account_status === "suspended") throw new HttpError(403, "Account suspended");
  if (prof?.subscription_plan !== "ai_premium") throw new HttpError(402, "AI Premium plan required");
  const plans = await getSetting<Record<string, { ai_credits?: number }>>(db, "plans", {});
  const monthly = plans.ai_premium?.ai_credits ?? 200;
  const period = new Date().toISOString().slice(0, 7);
  const used = prof.ai_credits_period === period ? prof.ai_credits_used : 0;
  if (used >= monthly) throw new HttpError(429, `Monthly AI credits used (${monthly})`);

  const { data: job, error } = await db.from("ai_jobs").insert({ user_id: user.id, task, params: body.params ?? {}, input_path: inputPath, provider: "replicate", status: "queued" }).select("*").single();
  if (error) throw error;
  await db.from("profiles").update({ ai_credits_used: used + 1, ai_credits_period: period }).eq("id", user.id);

  try {
    const { data: signed } = await db.storage.from("media").createSignedUrl(inputPath, 60 * 60);
    if (!signed?.signedUrl) throw new HttpError(404, "Input file not found");
    const pred = await callProvider(task, signed.signedUrl, String(body.params?.prompt ?? "").slice(0, 300));
    await db.from("ai_jobs").update({ status: "processing", provider_job_id: pred.id }).eq("id", job.id);
  } catch (e) {
    await db.from("ai_jobs").update({ status: "failed", error_message: (e as Error).message }).eq("id", job.id);
    await db.from("profiles").update({ ai_credits_used: used }).eq("id", user.id);
    throw e;
  }
  return json(req, { job_id: job.id });
}));
