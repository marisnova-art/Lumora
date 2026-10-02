// POST /functions/v1/delete-account   { confirm: true }
// Deletes the caller's storage files and auth user. Table rows cascade (profiles, projects, favorites, ai_jobs);
// payment records keep amounts for accounting but user_id is set to NULL (anonymized) by FK rules.
import { adminClient, handle, HttpError, json, requireUser } from "../_shared/common.ts";

async function removeFolder(db: ReturnType<typeof adminClient>, bucket: string, prefix: string) {
  const stack = [prefix];
  while (stack.length) {
    const dir = stack.pop()!;
    for (let offset = 0; ; offset += 100) {
      const { data, error } = await db.storage.from(bucket).list(dir, { limit: 100, offset });
      if (error || !data?.length) break;
      const files = data.filter((o) => o.id).map((o) => `${dir}/${o.name}`);
      data.filter((o) => !o.id).forEach((o) => stack.push(`${dir}/${o.name}`));
      if (files.length) await db.storage.from(bucket).remove(files);
      if (data.length < 100) break;
    }
  }
}

Deno.serve(handle(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "POST only");
  const user = await requireUser(req);
  const body = await req.json().catch(() => ({}));
  if (body.confirm !== true) throw new HttpError(400, "confirm: true required");
  const db = adminClient();

  // Active paid subscriptions must be canceled at the provider first (handled in the billing portal).
  const { data: subs } = await db.from("subscriptions").select("id").eq("user_id", user.id).in("status", ["active", "trialing", "past_due"]).eq("is_test", false);
  if (subs?.length) throw new HttpError(409, "Cancel your active subscription in the billing portal before deleting the account");

  await removeFolder(db, "media", user.id);
  await removeFolder(db, "avatars", user.id);
  await db.from("usage_logs").insert({ event: "account.deleted", meta: {} }); // no personal data kept
  const { error } = await db.auth.admin.deleteUser(user.id);
  if (error) throw error;
  return json(req, { deleted: true });
}));
