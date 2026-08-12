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
import { getAuthorizedCaller } from "../_shared/auth.ts";

interface SendRequest {
  kind: "quotation" | "invoice";
  documentId: string; // quotations.id or invoices.id (uuid)
  ccEmails?: string[];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const resendApiKey = Deno.env.get("RESEND_API_KEY")!;

    const auth = await getAuthorizedCaller(req, supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, ["admin", "sales"]);
    if (auth.response) return auth.response;
    const { caller } = auth;

    const { kind, documentId, ccEmails = [] } = (await req.json()) as SendRequest;
    const table = kind === "invoice" ? "invoices" : "quotations";
    const linesTable = kind === "invoice" ? "invoice_lines" : "quotation_lines";
    const fkColumn = kind === "invoice" ? "invoice_id" : "quotation_id";

    // RLS still applies here (this call uses the caller's own JWT, not the
    // service-role key) — the caller can only send documents they're already
    // allowed to see.
    const callerClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization")! } },
    });
    const { data: doc, error: docError } = await callerClient
      .from(table)
      .select("*, customers(name, email, contact_person), currencies(symbol)")
      .eq("id", documentId)
      .single();
    if (docError || !doc) {
      return new Response(JSON.stringify({ error: "Document not found" }), { status: 404, headers: corsHeaders });
    }
    const { data: lines, error: linesError } = await callerClient.from(linesTable).select("*").eq(fkColumn, documentId).order("line_no");
    if (linesError) {
      return new Response(JSON.stringify({ error: `Could not load line items: ${linesError.message}` }), { status: 500, headers: corsHeaders });
    }
    const customer = doc.customers;
    if (!customer?.email) {
      return new Response(JSON.stringify({ error: "No customer email on file" }), { status: 400, headers: corsHeaders });
    }

    // currency_code lives on the document itself, not a company-wide
    // assumption (see docs/architecture.md "Currency lives on the
    // transaction") — the symbol comes from the same currencies row
    // create_quotation already derived it from, never hardcoded.
    const symbol = doc.currencies?.symbol ?? doc.currency_code;
    const subject = `${kind === "invoice" ? "Invoice" : "Quotation"} ${doc.display_code} from SETVACO Holding Ltd`;
    const bodyLines = (lines ?? []).map((l) => `- ${l.description} x${l.qty} @ ${symbol} ${Number(l.unit_price).toLocaleString()}`);
    const text = `Dear ${customer.contact_person || "Customer"},\n\nPlease find below ${kind} ${doc.display_code}, total ${symbol} ${Number(doc.total).toLocaleString()}.\n\n${bodyLines.join("\n")}\n\nKind regards,\n${caller.name}\nSETVACO Holding Limited`;

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

    // The email has now actually sent — from here on, a failure shouldn't
    // be reported back as "sending failed" (it didn't), so audit-log and
    // status-update errors are logged rather than turned into a 5xx that
    // would mislead the caller into re-sending the email.
    const admin = createClient(supabaseUrl, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { error: auditError } = await admin.from("audit_log").insert({
      company_id: caller.companyId,
      actor_id: caller.userId,
      action: `Sent ${doc.display_code} to ${customer.email} (cc: ${ccEmails.join(", ") || "none"})`,
      module: "Communications",
      entity_type: kind,
      entity_id: documentId,
    });
    if (auditError) {
      console.error("send-document-email: audit_log insert failed", auditError);
    }
    if (kind === "quotation") {
      const { error: statusError } = await admin.from("quotations").update({ status: "Sent" }).eq("id", documentId).eq("status", "Quoted");
      if (statusError) {
        console.error("send-document-email: quotation status update failed", statusError);
      }
    }

    return new Response(JSON.stringify({ ok: true }), { headers: corsHeaders });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: corsHeaders });
  }
});
