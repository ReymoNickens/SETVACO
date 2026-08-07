// Sends a quotation/invoice to a customer by email. Replaces today's
// SendDocumentModal (index.html:954), which only builds a mailto: link — the
// one thing in this app that genuinely needs an outbound network call plus a
// secret credential, so it's an Edge Function rather than a Postgres RPC.
//
// Uses Resend (https://resend.com) via a plain fetch call; swap the fetch
// target/body below if a different provider is preferred later — nothing
// else in this function is Resend-specific.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

interface SendRequest {
  kind: "quotation" | "invoice";
  documentId: string; // quotations.id or invoices.id (uuid)
  ccEmails?: string[];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const resendApiKey = Deno.env.get("RESEND_API_KEY")!;

  const callerClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization")! } },
  });
  const { data: { user } } = await callerClient.auth.getUser();
  if (!user) {
    return new Response(JSON.stringify({ error: "Not authenticated" }), { status: 401, headers: corsHeaders });
  }
  const { data: profile } = await callerClient.from("profiles").select("name, role, status").eq("id", user.id).single();
  if (!profile || profile.status !== "Active" || !["admin", "sales"].includes(profile.role)) {
    return new Response(JSON.stringify({ error: "Not authorized to send documents" }), { status: 403, headers: corsHeaders });
  }

  const { kind, documentId, ccEmails = [] } = (await req.json()) as SendRequest;
  const table = kind === "invoice" ? "invoices" : "quotations";
  const linesTable = kind === "invoice" ? "invoice_lines" : "quotation_lines";
  const fkColumn = kind === "invoice" ? "invoice_id" : "quotation_id";

  // RLS still applies here (this call uses the caller's own JWT, not the
  // service-role key) — the caller can only send documents they're already
  // allowed to see.
  const { data: doc, error: docError } = await callerClient
    .from(table)
    .select("*, customers(name, email, contact_person)")
    .eq("id", documentId)
    .single();
  if (docError || !doc) {
    return new Response(JSON.stringify({ error: "Document not found" }), { status: 404, headers: corsHeaders });
  }
  const { data: lines } = await callerClient.from(linesTable).select("*").eq(fkColumn, documentId).order("line_no");
  const customer = doc.customers;
  if (!customer?.email) {
    return new Response(JSON.stringify({ error: "No customer email on file" }), { status: 400, headers: corsHeaders });
  }

  const subject = `${kind === "invoice" ? "Invoice" : "Quotation"} ${doc.display_code} from SETVACO Holding Ltd`;
  const bodyLines = (lines ?? []).map((l) => `- ${l.description} x${l.qty} @ GH₵ ${Number(l.unit_price).toLocaleString()}`);
  const text = `Dear ${customer.contact_person || "Customer"},\n\nPlease find below ${kind} ${doc.display_code}, total GH₵ ${Number(doc.total).toLocaleString()}.\n\n${bodyLines.join("\n")}\n\nKind regards,\n${profile.name}\nSETVACO Holding Limited`;

  const resendRes = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${resendApiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: "SETVACO Holding <no-reply@setvaco.com>",
      to: [customer.email],
      cc: ccEmails,
      subject,
      text,
    }),
  });
  if (!resendRes.ok) {
    return new Response(JSON.stringify({ error: `Email provider error: ${await resendRes.text()}` }), { status: 502, headers: corsHeaders });
  }

  const admin = createClient(supabaseUrl, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  await admin.from("audit_log").insert({
    actor_id: user.id,
    actor_name: profile.name,
    action: `Sent ${doc.display_code} to ${customer.email} (cc: ${ccEmails.join(", ") || "none"})`,
    module: "Communications",
    entity_type: kind,
    entity_id: documentId,
  });
  if (kind === "quotation") {
    await admin.from("quotations").update({ status: "Sent" }).eq("id", documentId).eq("status", "Quoted");
  }

  return new Response(JSON.stringify({ ok: true }), { headers: corsHeaders });
});
