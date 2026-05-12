// lib/website-builder.js  (v2 — 13 May 2026)
// AI Website Builder — pure Supabase RPC architecture, no /api/* endpoints.
// Pairs with: db/migrations/044_website_builder_v2.sql
//             supabase/functions/generate-ai-website/index.ts

(function(){
'use strict';

// ── state ──────────────────────────────────────────────────────────────
const state = {
  palette:    null,        // loaded from sbp_get_website_color_palette
  shop:       null,
  tier:       null,
  website:    null,
  selected:   {
    business_type:     '',
    design_style:      'modern',
    color_primary:     'orange',
    color_primary_hex: '#FF6B35',
    color_accent:      'navy',
    color_accent_hex:  '#001F3F',
    headline:          '',
    description:       ''
  }
};

// ── utility ────────────────────────────────────────────────────────────
function $(id){ return document.getElementById(id); }
function flatColors(){
  if (!state.palette) return [];
  return ['warm','cool','natural','vibrant']
    .flatMap(k => state.palette[k] || []);
}
function findColor(key){
  return flatColors().find(c => c.key === key);
}
function accentFor(key){
  const hex = state.palette?.accent_pairs?.[key];
  if (!hex) return { key:'navy', hex:'#001F3F' };
  // find the matching key by hex
  const match = flatColors().find(c => c.hex.toLowerCase() === hex.toLowerCase());
  return match || { key:'navy', name:'Navy', hex:'#001F3F' };
}

// ── init ──────────────────────────────────────────────────────────────
async function init(){
  if (!window._sb){ alert('Supabase client missing'); return; }

  // 1. Auth gate
  const { data:{ session } } = await window._sb.auth.getSession();
  if (!session){ window.location.href = 'index.html'; return; }

  // 2. Load palette
  const palResp = await window._sb.rpc('sbp_get_website_color_palette');
  if (palResp.error || !palResp.data?.ok){
    showAlert('Failed to load color palette: ' + (palResp.error?.message || 'unknown'), 'error');
    return;
  }
  state.palette = palResp.data;

  // 3. Load builder state (shop + tier + existing draft)
  const stResp = await window._sb.rpc('sbp_get_website_builder_state');
  if (stResp.error || !stResp.data?.ok){
    showAlert('Could not load your shop: ' + (stResp.error?.message || stResp.data?.error || 'unknown'), 'error');
    return;
  }
  state.shop    = stResp.data.shop;
  state.tier    = stResp.data.tier;
  state.website = stResp.data.website || null;

  // 4. Pre-fill form
  prefillForm();

  // 5. Render
  renderColorPalette();
  renderTierBanner();
  bindEvents();
  updatePreview();
}

// ── prefill form ──────────────────────────────────────────────────────
function prefillForm(){
  $('shop-name').value = state.shop.name || '';

  // business type — use saved value, then shop.shop_type, then ''
  let bizType = state.website?.business_type || mapShopTypeToBiz(state.shop.shop_type) || '';
  $('business-type').value = bizType;
  state.selected.business_type = bizType;

  if (state.website){
    $('website-headline').value    = state.website.headline    || '';
    $('website-description').value = state.website.description || '';
    const ds = state.website.design_style || 'modern';
    state.selected.design_style = ds;
    const radio = document.querySelector(`input[name="design_style"][value="${ds}"]`);
    if (radio) radio.checked = true;

    state.selected.color_primary     = state.website.color_primary;
    state.selected.color_primary_hex = state.website.color_primary_hex;
    state.selected.color_accent      = state.website.color_accent;
    state.selected.color_accent_hex  = state.website.color_accent_hex;

    state.selected.headline    = state.website.headline    || '';
    state.selected.description = state.website.description || '';
  }
}

// 76 shop_types → 8 biz_types (simplified mapping for color recommendations)
function mapShopTypeToBiz(shop_type){
  if (!shop_type) return '';
  const st = shop_type.toLowerCase();
  if (/(salon|beauty|spa|nail|barber|stylist)/.test(st))                 return 'salon';
  if (/(hotel|motel|resort|room|pg_hostel|hospitality)/.test(st))        return 'hospitality';
  if (/(restaurant|cafe|food|bakery|tiffin|sweet|dhaba|cloud_kitchen)/.test(st)) return 'food';
  if (/(clinic|pharmacy|medical|hospital|dental|optical|lab)/.test(st))  return 'healthcare';
  if (/(school|tuition|coaching|college|institute|library|education)/.test(st)) return 'education';
  if (/(plumber|electrician|repair|carpenter|service|laundry|cleaning|tailor|garage)/.test(st)) return 'services';
  if (/(online|d2c|ecommerce|brand)/.test(st))                            return 'online_brand';
  return 'retail';
}

// ── color palette UI ──────────────────────────────────────────────────
function renderColorPalette(){
  const grid = $('color-grid-desktop');
  const carousel = $('color-carousel-mobile');
  grid.innerHTML = '';
  carousel.innerHTML = '';

  flatColors().forEach(color => {
    grid.appendChild(buildSwatch(color, false));
    carousel.appendChild(buildSwatch(color, true));
  });

  // Highlight saved color (or default orange)
  highlightSelected(state.selected.color_primary);
  updateColorInfo();
  updateRecommendation();
}

function buildSwatch(color, isMobile){
  const wrap = document.createElement('label');
  wrap.className = 'wb-color-option';
  wrap.dataset.color = color.key;
  wrap.innerHTML = `
    <input type="radio" name="color_primary" value="${color.key}">
    <div class="wb-color-swatch" style="background:${color.hex}"></div>
    <div class="wb-color-name">${color.icon} ${color.name}</div>
  `;
  wrap.addEventListener('click', () => selectColor(color.key));
  return wrap;
}

function selectColor(key){
  const c = findColor(key); if (!c) return;
  const a = accentFor(key);
  state.selected.color_primary     = c.key;
  state.selected.color_primary_hex = c.hex;
  state.selected.color_accent      = a.key;
  state.selected.color_accent_hex  = a.hex;
  highlightSelected(key);
  updateColorInfo();
  updatePreview();
}

function highlightSelected(key){
  document.querySelectorAll('.wb-color-option').forEach(el => {
    el.classList.toggle('selected', el.dataset.color === key);
  });
}

function updateColorInfo(){
  const c = findColor(state.selected.color_primary);
  const a = findColor(state.selected.color_accent) || { name:'Navy' };
  if (!c){ $('color-info').textContent = ''; return; }
  $('color-info').innerHTML = `<strong>${c.name}</strong> + ${a.name}<br><span style="opacity:.7">${c.vibes || ''}</span>`;
}

function updateRecommendation(){
  const biz = state.selected.business_type;
  const recs = state.palette?.recommendations?.[biz] || [];
  document.querySelectorAll('.wb-color-option').forEach(el => {
    el.classList.toggle('recommended', recs.includes(el.dataset.color));
  });
  const label = recs.map(k => {
    const c = findColor(k);
    return c ? `${c.icon} ${c.name}` : '';
  }).filter(Boolean).join(', ');
  $('color-recommendation').innerHTML = biz
    ? `<span class="lang-en">✨ Recommended for ${biz}: ${label}</span><span class="lang-hi">✨ ${biz} के लिए: ${label}</span>`
    : `<span class="lang-en">Select a business type to see recommendations</span><span class="lang-hi">सुझाव देखने के लिए व्यवसाय चुनें</span>`;
}

// ── tier banner + button state ────────────────────────────────────────
function renderTierBanner(){
  const t = state.tier;
  const planLabels = {
    free:     `<span class="lang-en">Free</span><span class="lang-hi">मुफ़्त</span>`,
    pro:      `<span class="lang-en">Pro</span><span class="lang-hi">प्रो</span>`,
    business: `<span class="lang-en">Business</span><span class="lang-hi">बिज़नेस</span>`
  };

  $('tier-badge').innerHTML = (t.plan || 'free').toUpperCase();

  let limitTxt;
  if (t.plan === 'free'){
    limitTxt = `<span class="lang-en">Free plan — 1 AI website generation (${t.used_lifetime}/${t.lifetime_free_limit} used)</span>
                <span class="lang-hi">मुफ़्त — 1 AI वेबसाइट जनरेशन (${t.used_lifetime}/${t.lifetime_free_limit} उपयोग)</span>`;
  } else {
    limitTxt = `<span class="lang-en">${t.plan === 'pro' ? 'Pro' : 'Business'} — ${t.monthly_limit} generations/month (${t.used_this_month}/${t.monthly_limit} this month)</span>
                <span class="lang-hi">${t.plan === 'pro' ? 'प्रो' : 'बिज़नेस'} — ${t.monthly_limit} जनरेशन/माह (${t.used_this_month}/${t.monthly_limit} इस माह)</span>`;
  }
  $('plan-info').innerHTML = limitTxt;

  // Show upgrade prompt for free with no allowance left
  if (!t.can_generate){
    $('tier-restriction').style.display = 'block';
    if (t.plan === 'free' && t.used_lifetime >= t.lifetime_free_limit){
      $('tier-restriction-text').innerHTML = `
        <span class="lang-en"><strong>Upgrade to regenerate</strong><br>Pro: 2 generations/month • Business: 5/month</span>
        <span class="lang-hi"><strong>दोबारा बनाने के लिए अपग्रेड करें</strong><br>प्रो: 2 जनरेशन/माह • बिज़नेस: 5/माह</span>
      `;
    } else {
      $('tier-restriction-text').innerHTML = `
        <span class="lang-en"><strong>Monthly limit reached</strong><br>Resets on the 1st of next month</span>
        <span class="lang-hi"><strong>मासिक सीमा पूरी</strong><br>अगले माह की 1 तारीख को रीसेट होगा</span>
      `;
    }
    $('submit-btn').disabled = true;
  } else {
    $('tier-restriction').style.display = 'none';
    $('submit-btn').disabled = false;
  }

  // Show "View live site" if AI is published
  if (state.website?.ai_published && state.website?.slug){
    $('view-live').style.display = 'inline-block';
    $('view-live').href = `/s/${state.website.slug}`;
  }
}

// ── live preview ──────────────────────────────────────────────────────
function updatePreview(){
  const name     = $('shop-name').value || state.shop?.name || 'Your Shop';
  const headline = $('website-headline').value || 'Your headline appears here';
  const primary  = state.selected.color_primary_hex;
  const accent   = state.selected.color_accent_hex;

  $('preview-inner').style.background = primary;
  $('preview-name').textContent = name;
  $('preview-headline').textContent = headline;

  document.querySelectorAll('.wb-preview-btn').forEach(b => {
    b.style.color = primary;
    b.style.background = '#fff';
  });

  const pName = (findColor(state.selected.color_primary)||{}).name || '—';
  const aName = (findColor(state.selected.color_accent)||{}).name  || '—';
  $('preview-colors').textContent = `${pName} + ${aName}`;
}

// ── event binding ─────────────────────────────────────────────────────
function bindEvents(){
  $('shop-name').addEventListener('input', updatePreview);
  $('website-headline').addEventListener('input', e => {
    state.selected.headline = e.target.value; updatePreview();
  });
  $('website-description').addEventListener('input', e => {
    state.selected.description = e.target.value;
  });
  $('business-type').addEventListener('change', e => {
    state.selected.business_type = e.target.value;
    updateRecommendation();
  });
  document.querySelectorAll('input[name="design_style"]').forEach(el => {
    el.addEventListener('change', e => { state.selected.design_style = e.target.value; });
  });
  $('website-builder-form').addEventListener('submit', handleSubmit);
  $('save-draft-btn').addEventListener('click', handleSaveDraft);
  if ($('publish-toggle')){
    $('publish-toggle').addEventListener('click', handleTogglePublish);
  }
}

// ── save draft (no AI call) ───────────────────────────────────────────
async function handleSaveDraft(){
  $('save-draft-btn').disabled = true;
  $('save-draft-btn').textContent = 'Saving…';
  try {
    const resp = await window._sb.rpc('sbp_save_website_builder_draft', {
      p_payload: {
        design_style:      state.selected.design_style,
        color_primary:     state.selected.color_primary,
        color_primary_hex: state.selected.color_primary_hex,
        color_accent:      state.selected.color_accent,
        color_accent_hex:  state.selected.color_accent_hex,
        headline:          $('website-headline').value.trim(),
        description:       $('website-description').value.trim(),
        business_type:     $('business-type').value
      }
    });
    if (resp.error || !resp.data?.ok){
      showAlert('Failed to save draft: ' + (resp.error?.message || resp.data?.error), 'error');
    } else {
      showAlert('Draft saved ✓', 'success');
    }
  } catch(e){
    showAlert('Save failed: ' + e.message, 'error');
  } finally {
    $('save-draft-btn').disabled = false;
    $('save-draft-btn').textContent = 'Save Draft';
  }
}

// ── generate website (calls Edge Function) ────────────────────────────
async function handleSubmit(e){
  e.preventDefault();

  const errors = validate();
  if (errors.length){ showAlert(errors[0], 'error'); return; }

  $('loading-overlay').classList.add('active');

  try {
    const payload = {
      shop_name:         $('shop-name').value.trim(),
      business_type:     $('business-type').value,
      headline:          $('website-headline').value.trim(),
      description:       $('website-description').value.trim(),
      design_style:      state.selected.design_style,
      color_primary:     state.selected.color_primary,
      color_primary_hex: state.selected.color_primary_hex,
      color_accent:      state.selected.color_accent,
      color_accent_hex:  state.selected.color_accent_hex
    };

    const { data, error } = await window._sb.functions.invoke('generate-ai-website', {
      body: payload
    });

    if (error){
      showAlert('Generation failed: ' + error.message, 'error');
      return;
    }
    if (!data?.ok){
      const reason = data?.reason || data?.error || 'unknown';
      if (reason === 'quota_exhausted' || data?.error === 'quota_exhausted'){
        showAlert('You have reached your generation limit for this period.', 'error');
      } else {
        showAlert('Generation failed: ' + reason, 'error');
      }
      return;
    }

    showAlert('Website generated! 🎉 Reloading…', 'success');
    setTimeout(() => window.location.reload(), 1500);

  } catch(err){
    console.error(err);
    showAlert('Generation failed: ' + err.message, 'error');
  } finally {
    $('loading-overlay').classList.remove('active');
  }
}

// ── publish toggle ────────────────────────────────────────────────────
async function handleTogglePublish(){
  if (!state.website?.has_ai_draft){
    showAlert('Generate a website first before publishing.', 'error');
    return;
  }
  const newState = !state.website.ai_published;
  $('publish-toggle').disabled = true;

  const { data, error } = await window._sb.rpc('sbp_set_ai_website_published', {
    p_published: newState
  });

  $('publish-toggle').disabled = false;

  if (error || !data?.ok){
    showAlert('Publish toggle failed: ' + (error?.message || data?.error), 'error');
    return;
  }
  state.website.ai_published = newState;
  showAlert(newState ? 'Website published ✓' : 'Website unpublished', 'success');
  if (newState && data.slug){
    $('view-live').style.display = 'inline-block';
    $('view-live').href = `/s/${data.slug}`;
  }
  $('publish-toggle').textContent = newState ? 'Unpublish' : 'Publish';
}

// ── validation ────────────────────────────────────────────────────────
function validate(){
  const errs = [];
  if (!$('shop-name').value.trim())          errs.push('Shop name is required');
  if (!$('business-type').value)             errs.push('Business type is required');
  if (!$('website-headline').value.trim())   errs.push('Headline is required');
  if (!$('website-description').value.trim())errs.push('Description is required');
  if (!state.selected.color_primary)         errs.push('Please pick a color');
  return errs;
}

// ── alerts ────────────────────────────────────────────────────────────
function showAlert(msg, type){
  const el = $('alert-message');
  el.className = 'wb-alert ' + (type || 'info');
  el.textContent = msg;
  el.style.display = 'block';
  clearTimeout(showAlert._t);
  showAlert._t = setTimeout(()=>{ el.style.display='none'; }, 5000);
}

// ── boot ──────────────────────────────────────────────────────────────
if (document.readyState === 'loading'){
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}

})();
