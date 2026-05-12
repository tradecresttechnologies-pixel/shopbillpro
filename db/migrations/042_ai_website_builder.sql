-- Migration 042: AI Website Builder with Color Palette
-- Location: migrations/042_ai_website_builder.sql
-- Deploy: Run in Supabase SQL Editor in sequence

BEGIN;

DROP TABLE IF EXISTS websites CASCADE;

CREATE TABLE websites (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id UUID NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  
  -- Form data
  shop_name VARCHAR(100),
  business_type VARCHAR(100),
  website_headline VARCHAR(100) NOT NULL,
  website_description TEXT NOT NULL,
  design_style VARCHAR(50) NOT NULL,
  
  -- Color scheme (18 color palette)
  color_primary VARCHAR(50) NOT NULL,
  color_primary_hex VARCHAR(7) NOT NULL,
  color_accent VARCHAR(50) NOT NULL,
  color_accent_hex VARCHAR(7) NOT NULL,
  
  -- Website pages & content
  pages_count INT DEFAULT 1 CHECK (pages_count BETWEEN 1 AND 10),
  published_html LONGTEXT,
  published_url VARCHAR(255),
  published_at TIMESTAMP,
  
  -- Tier-based tracking
  tier VARCHAR(50) NOT NULL DEFAULT 'free',
  regenerations_used INT DEFAULT 0,
  regenerations_allowed INT DEFAULT 0,
  regeneration_reset_date TIMESTAMP,
  
  -- Admin-internal (not exposed to user API)
  _internal_generated_by_provider VARCHAR(50),
  _internal_generation_logs JSONB,
  _internal_fallback_used BOOLEAN DEFAULT false,
  _internal_ai_cost NUMERIC(10,4),
  _internal_generation_time_ms INT,
  _internal_form_data_submitted JSONB,
  
  -- Meta
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  last_regenerated_at TIMESTAMP,
  
  CONSTRAINT color_scheme_valid CHECK (color_primary != color_accent)
);

CREATE INDEX idx_websites_shop_id ON websites(shop_id);
CREATE INDEX idx_websites_tier ON websites(tier);
CREATE INDEX idx_websites_published_at ON websites(published_at);
CREATE INDEX idx_websites_created_at ON websites(created_at DESC);

-- RPC: Generate website with AI
CREATE OR REPLACE FUNCTION sbp_generate_website(
  p_form_data JSONB
) RETURNS JSONB AS $$
DECLARE
  v_shop_id UUID;
  v_tier VARCHAR;
  v_pages_allowed INT;
  v_regenerations_allowed INT;
  v_regenerations_used INT;
  v_result JSONB;
  v_active_provider VARCHAR;
  v_generated_html TEXT;
  v_website_id UUID;
BEGIN
  -- Extract shop_id from form
  v_shop_id := (p_form_data->>'shop_id')::UUID;
  
  -- Validate shop ownership
  IF NOT sbp_check_shop_owner(v_shop_id) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'shop_access_denied'
    );
  END IF;
  
  -- Get user tier
  SELECT plan INTO v_tier FROM sbp_shop WHERE id = v_shop_id;
  
  -- Tier-based limits
  CASE v_tier
    WHEN 'free' THEN
      v_pages_allowed := 1;
      v_regenerations_allowed := 0;
    WHEN 'pro' THEN
      v_pages_allowed := 2;
      v_regenerations_allowed := 2;
    WHEN 'business' THEN
      v_pages_allowed := 10;
      v_regenerations_allowed := 5;
  END CASE;
  
  -- Check if website already exists
  SELECT id, regenerations_used INTO v_website_id, v_regenerations_used
  FROM websites
  WHERE shop_id = v_shop_id
  LIMIT 1;
  
  -- If regenerating, check quota
  IF v_website_id IS NOT NULL THEN
    IF v_regenerations_used >= v_regenerations_allowed THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'regeneration_limit_exceeded',
        'message', 'You have used all regenerations for this month',
        'used', v_regenerations_used,
        'allowed', v_regenerations_allowed
      );
    END IF;
  END IF;
  
  -- Get active AI provider
  SELECT setting_value INTO v_active_provider
  FROM admin_settings
  WHERE setting_key = 'active_ai_provider';
  
  v_active_provider := COALESCE(v_active_provider, 'claude');
  
  -- Call AI provider via Edge Function
  v_generated_html := _sbp_generate_website_html(p_form_data, v_active_provider);
  
  -- Create or update website
  INSERT INTO websites (
    shop_id,
    shop_name,
    business_type,
    website_headline,
    website_description,
    design_style,
    color_primary,
    color_primary_hex,
    color_accent,
    color_accent_hex,
    pages_count,
    published_html,
    tier,
    regenerations_used,
    regenerations_allowed,
    regeneration_reset_date,
    _internal_generated_by_provider,
    _internal_form_data_submitted
  ) VALUES (
    v_shop_id,
    p_form_data->>'shop_name',
    p_form_data->>'business_type',
    p_form_data->>'website_headline',
    p_form_data->>'website_description',
    p_form_data->>'design_style',
    p_form_data->>'color_primary',
    p_form_data->>'color_primary_hex',
    p_form_data->>'color_accent',
    p_form_data->>'color_accent_hex',
    (p_form_data->>'pages_count')::INT,
    v_generated_html,
    v_tier,
    CASE WHEN v_website_id IS NOT NULL THEN v_regenerations_used + 1 ELSE 0 END,
    v_regenerations_allowed,
    CASE WHEN v_regenerations_allowed > 0 
      THEN DATE_TRUNC('month', NOW()) + INTERVAL '1 month'
      ELSE NULL 
    END,
    v_active_provider,
    p_form_data
  )
  ON CONFLICT (shop_id) DO UPDATE SET
    shop_name = EXCLUDED.shop_name,
    website_headline = EXCLUDED.website_headline,
    website_description = EXCLUDED.website_description,
    design_style = EXCLUDED.design_style,
    color_primary = EXCLUDED.color_primary,
    color_primary_hex = EXCLUDED.color_primary_hex,
    color_accent = EXCLUDED.color_accent,
    color_accent_hex = EXCLUDED.color_accent_hex,
    pages_count = EXCLUDED.pages_count,
    published_html = EXCLUDED.published_html,
    regenerations_used = websites.regenerations_used + 1,
    last_regenerated_at = NOW(),
    updated_at = NOW(),
    _internal_generated_by_provider = EXCLUDED._internal_generated_by_provider,
    _internal_form_data_submitted = EXCLUDED._internal_form_data_submitted
  RETURNING id
  INTO v_website_id;
  
  RETURN jsonb_build_object(
    'ok', true,
    'website_id', v_website_id,
    'message', 'Website generated successfully'
  );
  
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'ok', false,
    'error', 'generation_failed',
    'message', SQLERRM
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RPC: Publish website
CREATE OR REPLACE FUNCTION sbp_publish_website(
  p_website_id UUID,
  p_published_url VARCHAR
) RETURNS JSONB AS $$
DECLARE
  v_shop_id UUID;
BEGIN
  SELECT shop_id INTO v_shop_id FROM websites WHERE id = p_website_id;
  
  IF NOT sbp_check_shop_owner(v_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'access_denied');
  END IF;
  
  UPDATE websites
  SET published_url = p_published_url, published_at = NOW(), updated_at = NOW()
  WHERE id = p_website_id;
  
  RETURN jsonb_build_object(
    'ok', true,
    'website_id', p_website_id,
    'message', 'Website published successfully'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RPC: Get website (user-safe)
CREATE OR REPLACE FUNCTION sbp_get_website() RETURNS JSONB AS $$
DECLARE
  v_shop_id UUID;
  v_website RECORD;
BEGIN
  v_shop_id := auth.uid();
  
  SELECT * INTO v_website FROM websites
  WHERE shop_id = (SELECT id FROM sbp_shop WHERE owner_id = v_shop_id LIMIT 1)
  LIMIT 1;
  
  IF v_website IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  
  RETURN jsonb_build_object(
    'ok', true,
    'website', jsonb_build_object(
      'id', v_website.id,
      'shop_name', v_website.shop_name,
      'website_headline', v_website.website_headline,
      'website_description', v_website.website_description,
      'design_style', v_website.design_style,
      'color_primary', v_website.color_primary,
      'color_primary_hex', v_website.color_primary_hex,
      'color_accent', v_website.color_accent,
      'color_accent_hex', v_website.color_accent_hex,
      'pages_count', v_website.pages_count,
      'published_url', v_website.published_url,
      'published_at', v_website.published_at,
      'tier', v_website.tier,
      'regenerations_used', v_website.regenerations_used,
      'regenerations_allowed', v_website.regenerations_allowed,
      'regenerations_remaining', v_website.regenerations_allowed - v_website.regenerations_used
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Helper function
CREATE OR REPLACE FUNCTION _sbp_generate_website_html(
  p_form_data JSONB,
  p_provider VARCHAR
) RETURNS TEXT AS $$
DECLARE
  v_html TEXT;
BEGIN
  -- TODO: Call Edge Function to invoke Claude/Groq API
  -- For now, return placeholder HTML
  v_html := FORMAT(
    '<html><head><style>body{background:%s;color:#000}</style></head><body><h1>%s</h1><p>%s</p></body></html>',
    p_form_data->>'color_primary_hex',
    p_form_data->>'shop_name',
    p_form_data->>'website_headline'
  );
  RETURN v_html;
END;
$$ LANGUAGE plpgsql;

NOTIFY pgrst, 'reload schema';
COMMIT;
