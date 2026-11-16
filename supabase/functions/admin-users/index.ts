// Eagle Eye user management. Lets an admin create logins, reset passwords and remove users
// from inside the app, without anyone needing access to the Supabase dashboard.
// Deploy once: Supabase > Edge Functions > Deploy a new function > Via Editor, name it "admin-users".
import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// readable temporary passwords: no 0/O or 1/l/I to mix up when read out or typed from a message
function tempPassword(): string {
  const chars = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(12));
  return Array.from(bytes, (b) => chars[b % chars.length]).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SECRET_KEY");
    if (!key) return reply({ error: "server key missing" }, 500);
    const db = createClient(Deno.env.get("SUPABASE_URL")!, key, { auth: { persistSession: false, autoRefreshToken: false } });

    // only a logged-in admin may use this
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: who, error: whoErr } = await db.auth.getUser(token);
    if (whoErr || !who?.user) return reply({ error: "not signed in" }, 401);
    const { data: me } = await db.from("profiles").select("role").eq("id", who.user.id).maybeSingle();
    if (me?.role !== "admin") return reply({ error: "admins only" }, 403);

    const body = await req.json();
    const target = body.id
      ? (await db.from("profiles").select("id,is_developer").eq("id", body.id).maybeSingle()).data
      : null;

    if (body.action === "create") {
      const email = String(body.email ?? "").trim().toLowerCase();
      const role = String(body.role ?? "");
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return reply({ error: "invalid email" }, 400);
      if (!["admin", "inspector", "customer"].includes(role)) return reply({ error: "invalid role" }, 400);
      if (role === "customer" && !body.customer_id) return reply({ error: "customer required" }, 400);
      const password = tempPassword();
      const { data, error } = await db.auth.admin.createUser({
        email, password, email_confirm: true, user_metadata: { must_change: true },
      });
      if (error) return reply({ error: error.message }, 400);
      // the login trigger has already made a "pending" profile; give it the chosen role
      const { error: pErr } = await db.from("profiles").upsert({
        id: data.user.id, email, name: String(body.name ?? "").trim() || null, role,
        customer_id: role === "customer" ? body.customer_id : null,
      });
      if (pErr) return reply({ error: pErr.message }, 400);
      return reply({ id: data.user.id, email, password });
    }

    if (body.action === "reset") {
      if (!target) return reply({ error: "user not found" }, 404);
      // otherwise any admin could take over the developer account by resetting its password
      if (target.is_developer && target.id !== who.user.id) return reply({ error: "the developer account is protected" }, 403);
      const password = tempPassword();
      const { error } = await db.auth.admin.updateUserById(target.id, { password, user_metadata: { must_change: true } });
      if (error) return reply({ error: error.message }, 400);
      return reply({ id: target.id, password });
    }

    if (body.action === "delete") {
      if (!target) return reply({ error: "user not found" }, 404);
      if (target.is_developer) return reply({ error: "the developer account is protected" }, 403);
      if (target.id === who.user.id) return reply({ error: "you cannot remove yourself" }, 400);
      const { error } = await db.auth.admin.deleteUser(target.id);
      if (error) return reply({ error: error.message }, 400);
      return reply({ id: target.id, deleted: true });
    }

    return reply({ error: "unknown action" }, 400);
  } catch (e) {
    return reply({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
