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

type Action =
  | { action: "create"; name: string; email: string; username: string; role: string }
  | { action: "suspend"; userId: string }
  | { action: "reactivate"; userId: string };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Client scoped to the caller's own JWT, used only to verify they're an
  // active admin — never used to perform the privileged action itself.
  const callerClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization")! } },
  });
  const { data: { user } } = await callerClient.auth.getUser();
  if (!user) {
    return new Response(JSON.stringify({ error: "Not authenticated" }), { status: 401, headers: corsHeaders });
  }
  const { data: callerProfile } = await callerClient
    .from("profiles")
    .select("role, status")
    .eq("id", user.id)
    .single();
  if (!callerProfile || callerProfile.role !== "admin" || callerProfile.status !== "Active") {
    return new Response(JSON.stringify({ error: "Admin role required" }), { status: 403, headers: corsHeaders });
  }

  const admin = createClient(supabaseUrl, serviceRoleKey);
  const body = (await req.json()) as Action;

  try {
    if (body.action === "create") {
      const { data, error } = await admin.auth.admin.createUser({
        email: body.email,
        email_confirm: true,
        password: crypto.randomUUID(), // temp password; user resets via the standard Supabase reset-password flow
        user_metadata: { name: body.name, username: body.username },
      });
      if (error) throw error;

      // The on_auth_user_created trigger always assigns the least-privileged
      // 'sales' role (it never trusts client-supplied signup metadata for
      // this). Escalate it here instead, now that the caller has already
      // been verified as an active admin above.
      const { error: roleError } = await admin.from("profiles").update({ role: body.role }).eq("id", data.user!.id);
      if (roleError) throw roleError;

      await admin.from("audit_log").insert({
        actor_id: user.id,
        actor_name: callerProfile.role,
        action: `Created user account for ${body.name} (${body.role})`,
        module: "Access",
        entity_type: "profile",
        entity_id: data.user!.id,
      });
      return new Response(JSON.stringify({ userId: data.user!.id }), { headers: corsHeaders });
    }

    if (body.action === "suspend" || body.action === "reactivate") {
      const status = body.action === "suspend" ? "Suspended" : "Active";
      const { error: updateError } = await admin.from("profiles").update({ status }).eq("id", body.userId);
      if (updateError) throw updateError;
      if (body.action === "suspend") {
        // Force out any live sessions immediately, rather than waiting for the
        // JWT to expire naturally.
        await admin.auth.admin.signOut(body.userId, "global");
      }
      await admin.from("audit_log").insert({
        actor_id: user.id,
        actor_name: callerProfile.role,
        action: `${body.action === "suspend" ? "Suspended" : "Reactivated"} user account`,
        module: "Access",
        entity_type: "profile",
        entity_id: body.userId,
      });
      return new Response(JSON.stringify({ ok: true }), { headers: corsHeaders });
    }

    return new Response(JSON.stringify({ error: "Unknown action" }), { status: 400, headers: corsHeaders });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: corsHeaders });
  }
});
