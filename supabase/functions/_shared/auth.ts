// Shared caller-authorization check for Edge Functions. Both admin-manage-
// user and send-document-email independently repeated this exact block,
// which is why they drifted (different profiles-select columns, different
// role-check messages) — factored out once other functions need it too.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "./cors.ts";

export interface AuthorizedCaller {
  userId: string;
  companyId: string;
  role: string;
  name: string;
}

// Verifies the request's Authorization header belongs to an Active profile
// holding one of allowedRoles. Uses the caller's own JWT-scoped client —
// RLS still applies to this lookup, this never uses the service-role key.
// Returns either the verified caller, or a ready-to-return Response for the
// 401/403 case.
export async function getAuthorizedCaller(
  req: Request,
  supabaseUrl: string,
  anonKey: string,
  allowedRoles: string[],
): Promise<{ caller: AuthorizedCaller; response?: undefined } | { caller?: undefined; response: Response }> {
  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: req.headers.get("Authorization")! } },
  });
  const { data: { user } } = await callerClient.auth.getUser();
  if (!user) {
    return { response: new Response(JSON.stringify({ error: "Not authenticated" }), { status: 401, headers: corsHeaders }) };
  }
  const { data: profile } = await callerClient
    .from("profiles")
    .select("name, role, status, company_id")
    .eq("id", user.id)
    .single();
  if (!profile || profile.status !== "Active" || !allowedRoles.includes(profile.role)) {
    return { response: new Response(JSON.stringify({ error: "Not authorized" }), { status: 403, headers: corsHeaders }) };
  }
  return { caller: { userId: user.id, companyId: profile.company_id, role: profile.role, name: profile.name } };
}
