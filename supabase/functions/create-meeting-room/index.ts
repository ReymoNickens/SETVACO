// Meeting Room, Phase 1 — creates a Daily.co video call room and records it
// in `meetings`. Deliberately not building real-time video infrastructure
// from scratch: Daily's REST API handles the room, its prebuilt call UI
// (embedded client-side via iframe) handles the call itself.
//
// Runs as an Edge Function for one reason: Daily's API key is a secret
// that can never reach the browser. Everything else here runs as the
// CALLER's own JWT-scoped client, not the service-role key — RLS already
// allows an active user to insert a meeting they created themselves (see
// meetings_insert in 20260813082414_meetings.sql), so there's no need for
// elevated privileges beyond the one external API call.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";
import { getAuthorizedCaller } from "../_shared/auth.ts";

interface CreateMeetingRequest {
  title?: string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const dailyApiKey = Deno.env.get("DAILY_API_KEY");
    if (!dailyApiKey) {
      // Fails clearly rather than a confusing downstream error — this is
      // expected until the operator finishes Daily.co setup (see
      // docs/architecture.md's Meeting Room section).
      return new Response(JSON.stringify({ error: "not_configured", message: "Meeting Room isn't set up yet — ask your admin to finish the Daily.co configuration." }), { status: 503, headers: corsHeaders });
    }

    // Any active role can start a meeting — matches the "virtual office"
    // framing (meetings aren't an approval-gated action like finance/HR
    // records are). Listed explicitly rather than omitted, so the
    // shared helper's contract (an explicit allowlist) stays consistent
    // across every Edge Function that uses it.
    const auth = await getAuthorizedCaller(req, supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, ["admin", "sales", "warehouse", "procurement", "service", "finance", "hr"]);
    if (auth.response) return auth.response;
    const { caller } = auth;

    const { title } = (await req.json().catch(() => ({}))) as CreateMeetingRequest;

    const roomName = `setvaco-${crypto.randomUUID().slice(0, 8)}`;
    const dailyRes = await fetch("https://api.daily.co/v1/rooms", {
      method: "POST",
      headers: { Authorization: `Bearer ${dailyApiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        name: roomName,
        properties: {
          enable_chat: true,
          // Instant meeting rooms auto-expire rather than lingering
          // forever — a new one is created each time "Start a Meeting"
          // is used, so there's no cleanup job to build for Phase 1.
          exp: Math.floor(Date.now() / 1000) + 4 * 60 * 60,
        },
      }),
    });
    if (!dailyRes.ok) {
      return new Response(JSON.stringify({ error: `Could not create meeting room: ${await dailyRes.text()}` }), { status: 502, headers: corsHeaders });
    }
    const room = await dailyRes.json();

    const callerClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization")! } },
    });
    const { data: meeting, error: insertError } = await callerClient
      .from("meetings")
      .insert({
        title: (title || "").trim() || "Untitled meeting",
        daily_room_url: room.url,
        daily_room_name: room.name,
        created_by: caller.userId,
      })
      .select()
      .single();
    if (insertError) throw insertError;

    return new Response(JSON.stringify({ meeting }), { headers: corsHeaders });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: corsHeaders });
  }
});
