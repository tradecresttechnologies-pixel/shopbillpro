-- ════════════════════════════════════════════════════════════════════
-- 019_company_details.sql
-- Batch 018 — CIN Switch / Company Details (8 May 2026)
--
-- Creates a SINGLETON table holding TradeCrest's legal & contact
-- details. One row, id=1, enforced by check constraint.
--
-- Three RPCs:
--   sbp_admin_get_company_details(p_token)       — admin token gated
--   sbp_admin_update_company_details(p_token,p)  — admin token gated
--   sbp_get_company_details_public()             — anon, returns trimmed
--                                                   safe view for footers/
--                                                   legal pages/Schema.org
--
-- Seeded with values from MCA CoI (6 May 2026):
--   CIN U62099UP2026PTC247501, PAN AANCT1122A, TAN LKNT09100A
--   Registered office: Gorakhpur, Uttar Pradesh
--
-- Idempotent: safe to re-run. Existing seed values are NOT overwritten
-- on re-run (uses ON CONFLICT DO NOTHING).
-- ════════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────
-- 1. Table
-- ──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS sbp_company_details (
  id                  integer PRIMARY KEY DEFAULT 1,

  -- Legal identity
  legal_name          text NOT NULL,
  brand_name          text NOT NULL DEFAULT 'ShopBill Pro',
  cin                 text,
  pan                 text,
  tan                 text,
  gstin               text,                     -- nullable (post-launch)
  date_of_incorp      date,
  legal_form          text DEFAULT 'Private Limited Company',

  -- Registered office (matches MCA records)
  registered_address  text,
  state               text,
  state_code          text,                     -- GST state code, e.g. '09' = UP
  country             text DEFAULT 'India',
  pincode             text,

  -- Capital structure (informational; for show on legal pages if needed)
  authorized_capital  numeric,
  paid_up_capital     numeric,

  -- ROC / regulatory
  roc_office          text,                     -- e.g. 'Central Registration Centre, Manesar'

  -- Contact (all editable from admin panel — these are placeholders)
  registered_email    text,                     -- email on MCA record
  registered_phone    text,
  support_email       text,                     -- shown on bills/PSP/marketing
  support_phone       text,
  billing_email       text,                     -- Razorpay merchant email
  legal_email         text,                     -- T&C, contracts
  privacy_email       text,                     -- DPDP Data Fiduciary contact
  security_email      text,                     -- security disclosures
  general_email       text,                     -- hello@ for marketing site
  system_email        text,                     -- no-reply@ for outbound
  founder_email       text,                     -- founder direct line

  -- Web presence
  primary_domain      text DEFAULT 'shopbillpro.in',
  app_url             text DEFAULT 'https://app.shopbillpro.in',
  marketing_url       text DEFAULT 'https://shopbillpro.in',

  -- Bookkeeping
  updated_at          timestamptz DEFAULT now(),
  updated_by          text,                     -- 'admin' or future shop user id

  CONSTRAINT sbp_company_details_singleton CHECK (id = 1)
);

COMMENT ON TABLE sbp_company_details IS
  'Singleton (id=1) — TradeCrest Technologies Pvt Ltd legal & contact details. Edited via admin panel only. Read by: footers, T&C, Privacy Policy, Schema.org JSON-LD, bill templates.';

-- ──────────────────────────────────────────────
-- 2. Seed (initial values from MCA CoI)
-- ──────────────────────────────────────────────

INSERT INTO sbp_company_details (
  id,
  legal_name,
  brand_name,
  cin,
  pan,
  tan,
  date_of_incorp,
  legal_form,
  registered_address,
  state,
  state_code,
  country,
  pincode,
  authorized_capital,
  paid_up_capital,
  roc_office,
  registered_phone,
  support_phone,
  -- Email placeholders use shopbillpro.in standard set; admin can edit
  support_email,
  billing_email,
  legal_email,
  privacy_email,
  security_email,
  general_email,
  system_email,
  founder_email,
  registered_email,
  primary_domain,
  app_url,
  marketing_url,
  updated_by
) VALUES (
  1,
  'TRADECREST TECHNOLOGIES PRIVATE LIMITED',
  'ShopBill Pro',
  'U62099UP2026PTC247501',
  'AANCT1122A',
  'LKNT09100A',
  '2026-05-06',
  'Private Limited Company',
  '529, Harsewakpur No 2, Harsewakpur, Jangle Dhushar, Sadar, Gorakhpur',
  'Uttar Pradesh',
  '09',
  'India',
  '273014',
  1000000,                                      -- ₹10,00,000 authorized
  100000,                                       -- ₹1,00,000 paid-up
  'Central Registration Centre, Manesar',
  '+91-7800766561',                             -- founder personal until business line
  '+91-7800766561',                             -- founder personal until business line
  'support@shopbillpro.in',
  'billing@shopbillpro.in',
  'legal@shopbillpro.in',
  'privacy@shopbillpro.in',
  'security@shopbillpro.in',
  'hello@shopbillpro.in',
  'no-reply@shopbillpro.in',
  'vinay@shopbillpro.in',
  'support@shopbillpro.in',                     -- placeholder until separate filed email
  'shopbillpro.in',
  'https://app.shopbillpro.in',
  'https://shopbillpro.in',
  'system_seed_batch_018'
)
ON CONFLICT (id) DO NOTHING;                    -- idempotent — won't clobber edits

-- ──────────────────────────────────────────────
-- 3. RLS
-- ──────────────────────────────────────────────

ALTER TABLE sbp_company_details ENABLE ROW LEVEL SECURITY;

-- No direct read/write from anon or authenticated. All access goes via
-- the RPCs below (which check admin token or return safe public view).
DROP POLICY IF EXISTS sbp_company_details_no_direct ON sbp_company_details;
CREATE POLICY sbp_company_details_no_direct
  ON sbp_company_details
  FOR ALL
  TO authenticated, anon
  USING (false)
  WITH CHECK (false);

-- Service role bypasses RLS automatically — used by the RPCs.

-- ──────────────────────────────────────────────
-- 4. RPC: sbp_admin_get_company_details(p_token)
--   Returns full row as jsonb. Admin-token gated.
-- ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_admin_get_company_details(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row sbp_company_details%ROWTYPE;
BEGIN
  IF NOT public.admin_verify_token(p_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT * INTO v_row FROM sbp_company_details WHERE id = 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_seeded');
  END IF;

  RETURN jsonb_build_object('ok', true, 'data', to_jsonb(v_row));
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_admin_get_company_details(text) TO authenticated, anon;

-- ──────────────────────────────────────────────
-- 5. RPC: sbp_admin_update_company_details(p_token, payload)
--   Updates whitelisted fields from payload jsonb. Admin-token gated.
--   Whitelisted: any field except id and date_of_incorp/cin/pan/tan
--   (those are MCA-issued and should not change without ROC filing).
-- ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_admin_update_company_details(
  p_token   text,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row sbp_company_details%ROWTYPE;
BEGIN
  IF NOT public.admin_verify_token(p_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_payload');
  END IF;

  -- Whitelisted COALESCE update — fields the admin is allowed to edit.
  -- Immutable from UI: id, cin, pan, tan, date_of_incorp (MCA-issued).
  -- Editable: legal_name (in case of name change), all contact + brand
  --           + GSTIN (when issued) + capital + addresses + URLs.
  UPDATE sbp_company_details SET
    legal_name         = COALESCE(p_payload->>'legal_name', legal_name),
    brand_name         = COALESCE(p_payload->>'brand_name', brand_name),
    gstin              = COALESCE(p_payload->>'gstin', gstin),
    legal_form         = COALESCE(p_payload->>'legal_form', legal_form),
    registered_address = COALESCE(p_payload->>'registered_address', registered_address),
    state              = COALESCE(p_payload->>'state', state),
    state_code         = COALESCE(p_payload->>'state_code', state_code),
    country            = COALESCE(p_payload->>'country', country),
    pincode            = COALESCE(p_payload->>'pincode', pincode),
    authorized_capital = COALESCE((p_payload->>'authorized_capital')::numeric, authorized_capital),
    paid_up_capital    = COALESCE((p_payload->>'paid_up_capital')::numeric, paid_up_capital),
    roc_office         = COALESCE(p_payload->>'roc_office', roc_office),
    registered_email   = COALESCE(p_payload->>'registered_email', registered_email),
    registered_phone   = COALESCE(p_payload->>'registered_phone', registered_phone),
    support_email      = COALESCE(p_payload->>'support_email', support_email),
    support_phone      = COALESCE(p_payload->>'support_phone', support_phone),
    billing_email      = COALESCE(p_payload->>'billing_email', billing_email),
    legal_email        = COALESCE(p_payload->>'legal_email', legal_email),
    privacy_email      = COALESCE(p_payload->>'privacy_email', privacy_email),
    security_email     = COALESCE(p_payload->>'security_email', security_email),
    general_email      = COALESCE(p_payload->>'general_email', general_email),
    system_email       = COALESCE(p_payload->>'system_email', system_email),
    founder_email      = COALESCE(p_payload->>'founder_email', founder_email),
    primary_domain     = COALESCE(p_payload->>'primary_domain', primary_domain),
    app_url            = COALESCE(p_payload->>'app_url', app_url),
    marketing_url      = COALESCE(p_payload->>'marketing_url', marketing_url),
    updated_at         = now(),
    updated_by         = 'admin'
  WHERE id = 1
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_seeded');
  END IF;

  RETURN jsonb_build_object('ok', true, 'data', to_jsonb(v_row));
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_admin_update_company_details(text, jsonb) TO authenticated, anon;

-- ──────────────────────────────────────────────
-- 6. RPC: sbp_get_company_details_public()
--   Anon-callable. Returns ONLY the trimmed safe fields needed for
--   public footers, legal pages, and Schema.org. NEVER returns the
--   admin/audit fields.
-- ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_get_company_details_public()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row sbp_company_details%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM sbp_company_details WHERE id = 1;

  IF NOT FOUND THEN
    -- Graceful fallback so footers don't break before seed
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'not_seeded',
      'data', jsonb_build_object(
        'legal_name', 'TradeCrest Technologies Private Limited',
        'brand_name', 'ShopBill Pro'
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'legal_name',         v_row.legal_name,
      'brand_name',         v_row.brand_name,
      'cin',                v_row.cin,
      'gstin',              v_row.gstin,
      'date_of_incorp',     v_row.date_of_incorp,
      'legal_form',         v_row.legal_form,
      'registered_address', v_row.registered_address,
      'state',              v_row.state,
      'country',            v_row.country,
      'pincode',            v_row.pincode,
      'support_email',      v_row.support_email,
      'support_phone',      v_row.support_phone,
      'legal_email',        v_row.legal_email,
      'privacy_email',      v_row.privacy_email,
      'security_email',     v_row.security_email,
      'general_email',      v_row.general_email,
      'primary_domain',     v_row.primary_domain,
      'app_url',            v_row.app_url,
      'marketing_url',      v_row.marketing_url
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_get_company_details_public() TO authenticated, anon;

-- ──────────────────────────────────────────────
-- 7. Verification queries (run after deploy)
-- ──────────────────────────────────────────────

-- (1) Confirm seed landed:
--   SELECT cin, pan, registered_address FROM sbp_company_details;
--
-- (2) Test public RPC (anon):
--   SELECT sbp_get_company_details_public();
--
-- (3) Test admin RPC:
--   SELECT sbp_admin_get_company_details('SBP_ADMIN_2024_SECURE');
--
-- (4) Confirm RLS denies direct read:
--   SET ROLE authenticated;
--   SELECT * FROM sbp_company_details;  -- should return 0 rows
--   RESET ROLE;

-- ────────────────────────── End of 019_company_details.sql ──────────────────────────
