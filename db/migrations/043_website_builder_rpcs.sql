-- Migration 043: RPC Helper Functions for Website Builder
-- Location: migrations/043_website_builder_rpcs.sql

BEGIN;

-- RPC: Get color recommendations by business type
CREATE OR REPLACE FUNCTION sbp_get_color_recommendations(p_business_type VARCHAR)
RETURNS JSONB AS $$
BEGIN
  RETURN jsonb_build_object(
    'ok', true,
    'business_type', p_business_type,
    'recommended_colors', CASE p_business_type
      WHEN 'retail' THEN '["orange", "blue", "navy", "gold"]'::JSONB
      WHEN 'food' THEN '["orange", "red", "coral", "green"]'::JSONB
      WHEN 'salon' THEN '["pink", "purple", "gold", "magenta"]'::JSONB
      WHEN 'hospitality' THEN '["navy", "gold", "teal", "taupe"]'::JSONB
      WHEN 'healthcare' THEN '["teal", "blue", "green", "sage"]'::JSONB
      WHEN 'services' THEN '["blue", "navy", "orange", "charcoal"]'::JSONB
      WHEN 'education' THEN '["blue", "navy", "purple", "green"]'::JSONB
      WHEN 'online_brand' THEN '["indigo", "magenta", "cyan", "gold"]'::JSONB
      ELSE '["orange", "blue", "navy", "gold"]'::JSONB
    END
  );
END;
$$ LANGUAGE plpgsql;

-- RPC: Get all colors (18 palette)
CREATE OR REPLACE FUNCTION sbp_get_color_palette() RETURNS JSONB AS $$
BEGIN
  RETURN jsonb_build_object('ok', true, 'total_colors', 18,
    'warm', jsonb_build_array(
      jsonb_build_object('name', 'Orange', 'hex', '#FF6B35', 'icon', '🟠'),
      jsonb_build_object('name', 'Red', 'hex', '#E63946', 'icon', '🔴'),
      jsonb_build_object('name', 'Pink', 'hex', '#FF006E', 'icon', '💗'),
      jsonb_build_object('name', 'Coral', 'hex', '#FF7F50', 'icon', '🪸'),
      jsonb_build_object('name', 'Gold', 'hex', '#FFD700', 'icon', '✨')
    ),
    'cool', jsonb_build_array(
      jsonb_build_object('name', 'Blue', 'hex', '#0066CC', 'icon', '🔵'),
      jsonb_build_object('name', 'Navy', 'hex', '#001F3F', 'icon', '🌊'),
      jsonb_build_object('name', 'Cyan', 'hex', '#00D9FF', 'icon', '💫'),
      jsonb_build_object('name', 'Teal', 'hex', '#20B2AA', 'icon', '🏞️'),
      jsonb_build_object('name', 'Purple', 'hex', '#9D4EDD', 'icon', '💜')
    ),
    'natural', jsonb_build_array(
      jsonb_build_object('name', 'Green', 'hex', '#2D6A4F', 'icon', '🌿'),
      jsonb_build_object('name', 'Sage', 'hex', '#9CAF88', 'icon', '🍃'),
      jsonb_build_object('name', 'Brown', 'hex', '#8B4513', 'icon', '🏠'),
      jsonb_build_object('name', 'Charcoal', 'hex', '#36454F', 'icon', '⚫'),
      jsonb_build_object('name', 'Taupe', 'hex', '#B38B6D', 'icon', '🤎')
    ),
    'vibrant', jsonb_build_array(
      jsonb_build_object('name', 'Magenta', 'hex', '#FF10F0', 'icon', '🎆'),
      jsonb_build_object('name', 'Lime', 'hex', '#00FF00', 'icon', '🍋'),
      jsonb_build_object('name', 'Indigo', 'hex', '#4B0082', 'icon', '💎')
    )
  );
END;
$$ LANGUAGE plpgsql;

-- RPC: Validate form
CREATE OR REPLACE FUNCTION sbp_validate_website_form(p_form_data JSONB)
RETURNS JSONB AS $$
DECLARE v_errors JSONB := '[]'::JSONB;
BEGIN
  IF (p_form_data->>'shop_name')::TEXT IS NULL OR TRIM(p_form_data->>'shop_name') = '' THEN
    v_errors := v_errors || jsonb_build_array('Shop name is required');
  END IF;
  IF (p_form_data->>'business_type')::TEXT IS NULL THEN
    v_errors := v_errors || jsonb_build_array('Business type is required');
  END IF;
  IF (p_form_data->>'website_headline')::TEXT IS NULL THEN
    v_errors := v_errors || jsonb_build_array('Headline is required');
  END IF;
  IF (p_form_data->>'website_description')::TEXT IS NULL THEN
    v_errors := v_errors || jsonb_build_array('Description is required');
  END IF;
  
  RETURN CASE WHEN jsonb_array_length(v_errors) > 0 
    THEN jsonb_build_object('ok', false, 'errors', v_errors)
    ELSE jsonb_build_object('ok', true) 
  END;
END;
$$ LANGUAGE plpgsql;

-- RPC: Get tier info
CREATE OR REPLACE FUNCTION sbp_get_website_tier_info() RETURNS JSONB AS $$
DECLARE
  v_shop_id UUID;
  v_tier VARCHAR;
  v_website RECORD;
BEGIN
  v_shop_id := (SELECT id FROM sbp_shop WHERE owner_id = auth.uid() LIMIT 1);
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;
  
  SELECT plan INTO v_tier FROM sbp_shop WHERE id = v_shop_id;
  SELECT * INTO v_website FROM websites WHERE shop_id = v_shop_id LIMIT 1;
  
  RETURN jsonb_build_object(
    'ok', true,
    'tier', v_tier,
    'pages_allowed', CASE v_tier WHEN 'free' THEN 1 WHEN 'pro' THEN 2 ELSE 10 END,
    'regenerations_allowed', CASE v_tier WHEN 'free' THEN 0 WHEN 'pro' THEN 2 ELSE 5 END,
    'website_exists', v_website.id IS NOT NULL
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RPC: Get accent color pair
CREATE OR REPLACE FUNCTION sbp_get_accent_color(p_primary_color VARCHAR)
RETURNS JSONB AS $$
DECLARE v_accent JSONB;
BEGIN
  v_accent := CASE LOWER(p_primary_color)
    WHEN 'orange' THEN jsonb_build_object('name', 'Navy', 'hex', '#001F3F')
    WHEN 'red' THEN jsonb_build_object('name', 'Gold', 'hex', '#FFD700')
    WHEN 'pink' THEN jsonb_build_object('name', 'Purple', 'hex', '#9D4EDD')
    WHEN 'coral' THEN jsonb_build_object('name', 'Teal', 'hex', '#20B2AA')
    WHEN 'gold' THEN jsonb_build_object('name', 'Navy', 'hex', '#001F3F')
    WHEN 'blue' THEN jsonb_build_object('name', 'Cyan', 'hex', '#00D9FF')
    WHEN 'navy' THEN jsonb_build_object('name', 'Gold', 'hex', '#FFD700')
    WHEN 'cyan' THEN jsonb_build_object('name', 'Navy', 'hex', '#001F3F')
    WHEN 'teal' THEN jsonb_build_object('name', 'Coral', 'hex', '#FF7F50')
    WHEN 'purple' THEN jsonb_build_object('name', 'Gold', 'hex', '#FFD700')
    WHEN 'green' THEN jsonb_build_object('name', 'Sage', 'hex', '#9CAF88')
    WHEN 'sage' THEN jsonb_build_object('name', 'Teal', 'hex', '#20B2AA')
    WHEN 'brown' THEN jsonb_build_object('name', 'Cream', 'hex', '#FFFDD0')
    WHEN 'charcoal' THEN jsonb_build_object('name', 'Cyan', 'hex', '#00D9FF')
    WHEN 'taupe' THEN jsonb_build_object('name', 'Gold', 'hex', '#FFD700')
    WHEN 'magenta' THEN jsonb_build_object('name', 'Navy', 'hex', '#001F3F')
    WHEN 'lime' THEN jsonb_build_object('name', 'Navy', 'hex', '#001F3F')
    WHEN 'indigo' THEN jsonb_build_object('name', 'Gold', 'hex', '#FFD700')
    ELSE jsonb_build_object('name', 'Navy', 'hex', '#001F3F')
  END;
  
  RETURN jsonb_build_object('ok', true, 'primary', LOWER(p_primary_color), 'accent', v_accent);
END;
$$ LANGUAGE plpgsql;

-- RPC: Check regeneration quota
CREATE OR REPLACE FUNCTION sbp_can_regenerate_website() RETURNS JSONB AS $$
DECLARE
  v_shop_id UUID;
  v_tier VARCHAR;
  v_website RECORD;
  v_allowed INT;
BEGIN
  v_shop_id := (SELECT id FROM sbp_shop WHERE owner_id = auth.uid() LIMIT 1);
  IF v_shop_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found'); END IF;
  
  SELECT plan INTO v_tier FROM sbp_shop WHERE id = v_shop_id;
  SELECT * INTO v_website FROM websites WHERE shop_id = v_shop_id;
  
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'no_website'); END IF;
  
  v_allowed := CASE v_tier WHEN 'free' THEN 0 WHEN 'pro' THEN 2 ELSE 5 END;
  
  RETURN jsonb_build_object(
    'ok', true,
    'can_regenerate', v_website.regenerations_used < v_allowed,
    'used', v_website.regenerations_used,
    'allowed', v_allowed,
    'remaining', v_allowed - v_website.regenerations_used
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

NOTIFY pgrst, 'reload schema';
COMMIT;
