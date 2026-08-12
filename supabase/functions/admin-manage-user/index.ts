// Creates, suspends, or reactivates a staff login. Replaces today's "Users &
// Access -> create account" UI action (index.html UsersAccess, isSuperUser
// gate at index.html:1697), which only ever touched local React state.
//
// Runs with the service-role key because creating an auth.users row (and
// force-signing-out a suspended user's active sessions) requires the Auth
// Admin API, which the anon/authenticated client can never be given access
// to. The caller's own admin-ness is checked explicitly below — the
// service-role key itself bypasses RLS, so that check is this function's job,
// not the database's.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";
import { getAuthorizedCaller } from "../_shared/auth.ts";

type Action =
  | { action: "create"; name: string; email: string; username: string; role: string }
  | { action: "suspend"; userId: string }
  | { action: "reactivate"; userId: string };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const auth = await getAuthorizedCaller(req, supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, ["admin"]);
    if (auth.response) return auth.response;
    const { caller } = auth;

    const admin = createClient(supabaseUrl, serviceRoleKey);
    const body = (await req.json()) as Action;

    if (body.action === "create") {
      // Validate against the live roles table rather than a hardcoded list,
      // so a new role (e.g. an 'hr' role added for the HR module) doesn't
      // need this function edited to become assignable.
      const { data: roleRow } = await admin.from("roles").select("key").eq("key", body.role).single();
      if (!roleRow) {
        return new Response(JSON.stringify({ error: `Unknown role: ${body.role}` }), { status: 400, headers: corsHeaders });
      }

      const { data, error } = await admin.auth.admin.createUser({
        email: body.email,
        email_confirm: true,
        password: crypto.randomUUID(), // temp password; user resets via the standard Supabase reset-password flow
        user_metadata: { name: body.name, username: body.username },
        // handle_new_auth_user (the on_auth_user_created trigger) reads
        // company_id from here and raises if it's missing — this is what
        // makes self-serve signup impossible even with Supabase's "Allow
        // signups" toggle left on. Always the CALLER's own company_id, never
        // client-suppliable, so an admin can only ever provision accounts
        // inside their own tenant.
        app_metadata: { company_id: caller.companyId },
      });
      if (error) throw error;

      // The on_auth_user_created trigger always assigns the least-privileged
      // 'sales' role (it never trusts client-supplied signup metadata for
      // this). Escalate it here instead, now that the caller has already
      // been verified as an active admin above. If this fails, the
      // auth.users row from createUser above would otherwise be left
      // orphaned (a working login stuck at 'sales', with the caller told
      // the whole operation failed) — clean it up rather than leave that
      // half-done state behind.
      const { error: roleError } = await admin.from("profiles").update({ role: body.role }).eq("id", data.user!.id);
      if (roleError) {
        await admin.auth.admin.deleteUser(data.user!.id);
        throw roleError;
      }

      const { error: auditError } = await admin.from("audit_log").insert({
        company_id: caller.companyId,
        actor_id: caller.userId,
        action: `Created user account for ${body.name} (${body.role})`,
        module: "Access",
        entity_type: "profile",
        entity_id: data.user!.id,
      });
      if (auditError) {
        // The account itself was created successfully and correctly roled —
        // don't roll that back or fail the response over a secondary audit
        // write, just surface it for investigation.
        console.error("admin-manage-user: audit_log insert failed", auditError);
      }
      return new Response(JSON.stringify({ userId: data.user!.id }), { headers: corsHeaders });
    }

    if (body.action === "suspend" || body.action === "reactivate") {
      // admin.* runs on the service-role key, which bypasses RLS entirely —
      // so this tenant check has to happen here in code, or an admin from
      // one company could suspend/reactivate a login belonging to a
      // different company by userId alone.
      const { data: targetProfile } = await admin.from("profiles").select("company_id").eq("id", body.userId).single();
      if (!targetProfile || targetProfile.company_id !== caller.companyId) {
        return new Response(JSON.stringify({ error: "User not found in your company" }), { status: 404, headers: corsHeaders });
      }

      const status = body.action === "suspend" ? "Suspended" : "Active";
      const { error: updateError } = await admin.from("profiles").update({ status }).eq("id", body.userId);
      if (updateError) throw updateError;
      if (body.action === "suspend") {
        // Force out any live sessions immediately, rather than waiting for the
        // JWT to expire naturally.
        await admin.auth.admin.signOut(body.userId, "global");
      }
      const { error: auditError } = await admin.from("audit_log").insert({
        company_id: caller.companyId,
        actor_id: caller.userId,
        action: `${body.action === "suspend" ? "Suspended" : "Reactivated"} user account`,
        module: "Access",
        entity_type: "profile",
        entity_id: body.userId,
      });
      if (auditError) {
        console.error("admin-manage-user: audit_log insert failed", auditError);
      }
      return new Response(JSON.stringify({ ok: true }), { headers: corsHeaders });
    }

    return new Response(JSON.stringify({ error: "Unknown action" }), { status: 400, headers: corsHeaders });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: corsHeaders });
  }
});
