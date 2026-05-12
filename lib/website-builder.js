// lib/website-builder.js
// Complete website builder with 18-color palette, real-time preview, tier management

const COLOR_PALETTE = {
  warm: [
    { name: 'Orange', hex: '#FF6B35', icon: '🟠', vibes: 'Bold, Modern, Energetic' },
    { name: 'Red', hex: '#E63946', icon: '🔴', vibes: 'Premium, Luxury, Powerful' },
    { name: 'Pink', hex: '#FF006E', icon: '💗', vibes: 'Playful, Trendy, Beauty' },
    { name: 'Coral', hex: '#FF7F50', icon: '🪸', vibes: 'Friendly, Warm, Inviting' },
    { name: 'Gold', hex: '#FFD700', icon: '✨', vibes: 'Premium, Luxury, Elegant' }
  ],
  cool: [
    { name: 'Blue', hex: '#0066CC', icon: '🔵', vibes: 'Professional, Trust' },
    { name: 'Navy', hex: '#001F3F', icon: '🌊', vibes: 'Formal, Corporate, Serious' },
    { name: 'Cyan', hex: '#00D9FF', icon: '💫', vibes: 'Modern, Tech, Fresh' },
    { name: 'Teal', hex: '#20B2AA', icon: '🏞️', vibes: 'Calm, Balanced, Natural' },
    { name: 'Purple', hex: '#9D4EDD', icon: '💜', vibes: 'Creative, Premium' }
  ],
  natural: [
    { name: 'Green', hex: '#2D6A4F', icon: '🌿', vibes: 'Eco-friendly, Health' },
    { name: 'Sage', hex: '#9CAF88', icon: '🍃', vibes: 'Wellness, Calm, Organic' },
    { name: 'Brown', hex: '#8B4513', icon: '🏠', vibes: 'Earthy, Traditional' },
    { name: 'Charcoal', hex: '#36454F', icon: '⚫', vibes: 'Minimalist, Sophisticated' },
    { name: 'Taupe', hex: '#B38B6D', icon: '🤎', vibes: 'Elegant, Timeless' }
  ],
  vibrant: [
    { name: 'Magenta', hex: '#FF10F0', icon: '🎆', vibes: 'Bold, Trendy, Eye-catching' },
    { name: 'Lime', hex: '#00FF00', icon: '🍋', vibes: 'Energetic, Fun, Youth' },
    { name: 'Indigo', hex: '#4B0082', icon: '💎', vibes: 'Luxury, Mystical' }
  ]
};

// Accent color pairings (complementary colors)
const ACCENT_PAIRS = {
  'orange': { name: 'Navy', hex: '#001F3F' },
  'red': { name: 'Gold', hex: '#FFD700' },
  'pink': { name: 'Purple', hex: '#9D4EDD' },
  'coral': { name: 'Teal', hex: '#20B2AA' },
  'gold': { name: 'Navy', hex: '#001F3F' },
  'blue': { name: 'Cyan', hex: '#00D9FF' },
  'navy': { name: 'Gold', hex: '#FFD700' },
  'cyan': { name: 'Navy', hex: '#001F3F' },
  'teal': { name: 'Coral', hex: '#FF7F50' },
  'purple': { name: 'Gold', hex: '#FFD700' },
  'green': { name: 'Sage', hex: '#9CAF88' },
  'sage': { name: 'Teal', hex: '#20B2AA' },
  'brown': { name: 'Cream', hex: '#FFFDD0' },
  'charcoal': { name: 'Cyan', hex: '#00D9FF' },
  'taupe': { name: 'Gold', hex: '#FFD700' },
  'magenta': { name: 'Navy', hex: '#001F3F' },
  'lime': { name: 'Navy', hex: '#001F3F' },
  'indigo': { name: 'Gold', hex: '#FFD700' }
};

// Color recommendations by business type
const COLOR_RECOMMENDATIONS = {
  'retail': ['orange', 'blue', 'navy', 'gold'],
  'food': ['orange', 'red', 'coral', 'green'],
  'salon': ['pink', 'purple', 'gold', 'magenta'],
  'hospitality': ['navy', 'gold', 'teal', 'taupe'],
  'healthcare': ['teal', 'blue', 'green', 'sage'],
  'services': ['blue', 'navy', 'orange', 'charcoal'],
  'education': ['blue', 'navy', 'purple', 'green'],
  'online_brand': ['indigo', 'magenta', 'cyan', 'gold']
};

// Tier configuration
const TIER_CONFIG = {
  free: {
    pages_allowed: 1,
    regenerations_allowed: 0,
    can_regenerate: false
  },
  pro: {
    pages_allowed: 2,
    regenerations_allowed: 2,
    can_regenerate: true
  },
  business: {
    pages_allowed: 10,
    regenerations_allowed: 5,
    can_regenerate: true
  }
};

// State
let formData = {
  shop_name: '',
  business_type: '',
  website_headline: '',
  website_description: '',
  design_style: 'modern',
  color_primary: 'orange',
  color_primary_hex: '#FF6B35',
  color_accent: 'navy',
  color_accent_hex: '#001F3F',
  pages_count: 1
};

let currentTier = 'free';
let selectedColor = null;

// Initialize on page load
document.addEventListener('DOMContentLoaded', async () => {
  await initializeForm();
  await loadUserData();
  renderColorPalette();
  setupEventListeners();
  updatePreview();
});

// Initialize form with auto-filled data
async function initializeForm() {
  try {
    // Fetch user's shop data
    const response = await fetch('/api/shop', {
      method: 'GET',
      headers: { 'Content-Type': 'application/json' }
    });

    if (response.ok) {
      const data = await response.json();
      const shop = data.data;
      
      // Auto-fill form
      document.getElementById('shop-name').value = shop.shop_name || '';
      document.getElementById('business-type').value = shop.shop_type || '';
      
      // Set tier
      currentTier = shop.plan || 'free';
      updateTierDisplay();

      formData.shop_name = shop.shop_name || '';
      formData.business_type = shop.shop_type || '';
      
      // Trigger color recommendations based on business type
      onBusinessTypeChange();
    }
  } catch (error) {
    console.error('Error loading shop data:', error);
  }
}

// Load existing website if any
async function loadUserData() {
  try {
    const response = await fetch('/api/website', {
      method: 'GET',
      headers: { 'Content-Type': 'application/json' }
    });

    if (response.ok) {
      const data = await response.json();
      if (data.website) {
        const website = data.website;
        
        // Populate form with existing data
        document.getElementById('website-headline').value = website.website_headline || '';
        document.getElementById('website-description').value = website.website_description || '';
        document.querySelector(`input[name="design_style"][value="${website.design_style}"]`).checked = true;
        
        // Select saved color
        const colorName = website.color_primary.toLowerCase();
        selectColor(colorName);
        
        formData.website_headline = website.website_headline || '';
        formData.website_description = website.website_description || '';
        formData.design_style = website.design_style || 'modern';
      }
    }
  } catch (error) {
    console.log('No existing website found, creating new one');
  }
}

// Render 18-color palette
function renderColorPalette() {
  const gridDesktop = document.getElementById('color-grid-desktop');
  const carouselMobile = document.getElementById('color-carousel-mobile');
  
  gridDesktop.innerHTML = '';
  carouselMobile.innerHTML = '';

  Object.values(COLOR_PALETTE).flat().forEach(color => {
    const colorHtml = createColorOption(color);
    
    // Desktop grid
    gridDesktop.appendChild(createColorOptionElement(color, false));
    
    // Mobile carousel
    carouselMobile.appendChild(createColorOptionElement(color, true));
  });
}

// Create color option element
function createColorOptionElement(color, isMobile = false) {
  const option = document.createElement('label');
  option.className = 'wb-color-option';
  option.dataset.color = color.name.toLowerCase();
  
  option.innerHTML = `
    <input type="radio" name="color_primary" value="${color.name.toLowerCase()}" onchange="selectColor('${color.name.toLowerCase()}')">
    <div class="wb-color-swatch" style="background: ${color.hex}"></div>
    <div class="wb-color-name">${color.name}</div>
  `;
  
  return option;
}

// Select color and update preview
function selectColor(colorName) {
  const colorName_lower = colorName.toLowerCase();
  const colorObj = Object.values(COLOR_PALETTE).flat().find(c => c.name.toLowerCase() === colorName_lower);
  
  if (!colorObj) return;

  // Get accent color
  const accentKey = colorName_lower;
  const accentObj = ACCENT_PAIRS[accentKey];

  // Update form state
  formData.color_primary = colorName_lower;
  formData.color_primary_hex = colorObj.hex;
  formData.color_accent = accentObj.name.toLowerCase();
  formData.color_accent_hex = accentObj.hex;

  // Visual feedback
  document.querySelectorAll('.wb-color-option').forEach(opt => {
    opt.classList.remove('selected');
  });
  document.querySelector(`[data-color="${colorName_lower}"]`).classList.add('selected');

  // Update color info
  document.getElementById('color-info').innerHTML = `
    <strong>${colorObj.name}</strong> + ${accentObj.name} 
    <br>${colorObj.vibes}
  `;

  // Update preview
  updatePreview();
}

// Handle business type change
function onBusinessTypeChange() {
  const businessType = document.getElementById('business-type').value;
  formData.business_type = businessType;

  // Get recommended colors
  const recommendedColors = COLOR_RECOMMENDATIONS[businessType] || [];
  
  // Highlight recommended colors
  document.querySelectorAll('.wb-color-option').forEach(option => {
    const colorName = option.dataset.color;
    if (recommendedColors.some(r => r.toLowerCase() === colorName.toLowerCase())) {
      option.classList.add('recommended');
    } else {
      option.classList.remove('recommended');
    }
  });

  // Show recommendation message
  const recommendedNames = recommendedColors
    .map(c => {
      const obj = Object.values(COLOR_PALETTE).flat().find(x => x.name.toLowerCase() === c.toLowerCase());
      return obj ? `${obj.icon} ${obj.name}` : '';
    })
    .filter(Boolean)
    .join(', ');

  document.getElementById('color-recommendation').innerHTML = 
    `✨ Recommended for "${businessType}": ${recommendedNames}`;
}

// Update live preview
function updatePreview() {
  const shopName = document.getElementById('shop-name').value || 'Your Shop';
  const headline = document.getElementById('website-headline').value || 'Your website headline appears here';

  // Update preview
  document.getElementById('preview-inner').style.background = formData.color_primary_hex;
  document.getElementById('preview-name').textContent = shopName;
  document.getElementById('preview-headline').textContent = headline;
  document.getElementById('preview-colors').textContent = 
    `${formData.color_primary.charAt(0).toUpperCase() + formData.color_primary.slice(1)} + ${formData.color_accent.charAt(0).toUpperCase() + formData.color_accent.slice(1)}`;

  // Update buttons in preview
  const buttons = document.querySelectorAll('.wb-preview-btn');
  buttons.forEach(btn => {
    btn.style.color = formData.color_primary_hex;
  });
}

// Setup real-time preview
function setupEventListeners() {
  document.getElementById('shop-name').addEventListener('input', (e) => {
    formData.shop_name = e.target.value;
    updatePreview();
  });

  document.getElementById('website-headline').addEventListener('input', (e) => {
    formData.website_headline = e.target.value;
    updatePreview();
  });

  document.getElementById('website-description').addEventListener('input', (e) => {
    formData.website_description = e.target.value;
  });

  document.getElementById('business-type').addEventListener('change', onBusinessTypeChange);

  document.querySelectorAll('input[name="design_style"]').forEach(input => {
    input.addEventListener('change', (e) => {
      formData.design_style = e.target.value;
    });
  });

  // Form submission
  document.getElementById('website-builder-form').addEventListener('submit', handleFormSubmit);
}

// Update tier display
function updateTierDisplay() {
  const tierNames = { free: 'FREE', pro: 'PRO', business: 'BUSINESS' };
  const planTexts = {
    free: 'Your plan: Free (1 page, no regenerations)',
    pro: 'Your plan: Pro (2 pages, 2 regenerations/month)',
    business: 'Your plan: Business (Up to 10 pages, 5 regenerations/month)'
  };

  document.getElementById('tier-badge').textContent = tierNames[currentTier];
  document.getElementById('plan-info').textContent = planTexts[currentTier];

  // Show/hide tier restriction
  if (currentTier === 'free') {
    document.getElementById('tier-restriction').style.display = 'block';
  }

  // Set pages count based on tier
  formData.pages_count = TIER_CONFIG[currentTier].pages_allowed;
}

// Validate form
function validateForm() {
  const errors = [];

  if (!formData.shop_name.trim()) errors.push('Shop name is required');
  if (!formData.business_type) errors.push('Business type is required');
  if (!formData.website_headline.trim()) errors.push('Website headline is required');
  if (!formData.website_description.trim()) errors.push('Website description is required');
  if (!formData.color_primary) errors.push('Color scheme is required');

  return errors;
}

// Show alert
function showAlert(message, type = 'error') {
  const alert = document.getElementById('alert-message');
  alert.className = `wb-alert ${type}`;
  alert.textContent = message;
  setTimeout(() => alert.className = 'wb-alert', 5000);
}

// Handle form submission
async function handleFormSubmit(e) {
  e.preventDefault();

  // Validate
  const errors = validateForm();
  if (errors.length > 0) {
    showAlert(errors[0], 'error');
    return;
  }

  // Show loading
  document.getElementById('loading-overlay').classList.add('active');

  try {
    // Call API to generate website
    const response = await fetch('/api/generate-website', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        ...formData,
        shop_id: currentTier // placeholder, should be actual shop_id
      })
    });

    const data = await response.json();

    if (data.ok) {
      showAlert('Website generated successfully! 🎉', 'success');
      setTimeout(() => {
        window.location.href = '/dashboard?tab=website';
      }, 2000);
    } else {
      showAlert(data.error || 'Failed to generate website', 'error');
    }
  } catch (error) {
    console.error('Error:', error);
    showAlert('An error occurred. Please try again.', 'error');
  } finally {
    document.getElementById('loading-overlay').classList.remove('active');
  }
}

// Export for testing
if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    COLOR_PALETTE,
    COLOR_RECOMMENDATIONS,
    selectColor,
    updatePreview,
    formData
  };
}
