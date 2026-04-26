// Razorpay Webhook Handler — Supabase Edge Function
// Verifies HMAC signature, then forwards to process_razorpay_webhook RPC
//
// Deploy:
//   supabase functions deploy razorpay-webhook --no-verify-jwt
//
// Set webhook secret (must match what you enter in Razorpay dashboard webhook settings):
//   supabase secrets set RAZORPAY_WEBHOOK_SECRET="your-webhook-secret"
//
// Razorpay webhook URL to add in dashboard:
//   https://<your-project>.supabase.co/functions/v1/razorpay-webhook

// deno-lint-ignore-file no-explicit-any
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WEBHOOK_SECRET = Deno.env.get('RAZORPAY_WEBHOOK_SECRET') || '';

async function verifySignature(rawBody: string, signature: string, secret: string): Promise<boolean> {
  if (!signature || !secret) return false;
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(rawBody));
  const hex = Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, '0')).join('');
  // Constant-time compare
  if (hex.length !== signature.length) return false;
  let mismatch = 0;
  for (let i = 0; i < hex.length; i++) {
    mismatch |= hex.charCodeAt(i) ^ signature.charCodeAt(i);
  }
  return mismatch === 0;
}

serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }
  const rawBody = await req.text();
  const signature = req.headers.get('x-razorpay-signature') || '';

  let payload: any;
  try { payload = JSON.parse(rawBody); }
  catch { return new Response('Invalid JSON', { status: 400 }); }

  const sigOk = await verifySignature(rawBody, signature, WEBHOOK_SECRET);

  // Forward to Postgres regardless of signature — function logs the failure
  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
  const { data, error } = await sb.rpc('process_razorpay_webhook', {
    p_payload: payload,
    p_signature_ok: sigOk
  });

  if (error) {
    console.error('RPC error:', error);
    return new Response(JSON.stringify({ ok: false, error: error.message }), {
      status: 500,
      headers: { 'content-type': 'application/json' }
    });
  }
  return new Response(JSON.stringify({ ok: true, event_id: data, signature_ok: sigOk }), {
    status: sigOk ? 200 : 401,
    headers: { 'content-type': 'application/json' }
  });
});
