/* lib/website-builder-fields.js
 * ============================================================
 * DESIGN_04 F2 — vertical-aware form field config (ALL MACROS)
 *
 * Macros covered:
 *   • food         — restaurants, cafes, qsr
 *   • beauty       — salon, spa, gym, yoga
 *   • healthcare   — clinic, dentist, vet, lab
 *   • services     — handyman, repair, photographer
 *   • retail       — kirana, garments, jewellery
 *   • education    — coaching, art class, library
 *   • wholesale    — distributor, mandi, importer
 *   • online       — D2C, marketplace, handmade
 *
 * Macros that render the DEFAULT form (no entry):
 *   • hospitality (hotel)  — current form is already hotel-shaped
 *   • property             — real estate; defers to later phase
 *   • subscription         — recurring services; defers to later phase
 * ============================================================
 */
(function (root) {
  'use strict';

  const FIELDS_BY_MACRO = {

    // ─── FOOD ──────────────────────────────────────────────
    food: {
      hideSections: ['sec-rooms'],
      relabelSections: {
        'sec-services': {
          en: '3. Your Menu',
          hi: '3. आपका मेनू',
          sub_en: 'Add your dishes with prices — mark signature items with ⭐',
          sub_hi: 'अपने व्यंजन और मूल्य जोड़ें — विशेष पर ⭐'
        },
        'sec-amenities': {
          en: '5. Restaurant Features',
          hi: '5. रेस्टोरेंट सुविधाएँ',
          sub_en: 'Tick what you offer — AI uses these to describe your restaurant',
          sub_hi: 'जो सुविधाएँ हैं वो चुनें'
        }
      },
      amenityGroups: [
        { label_en: 'Dining Options', label_hi: 'भोजन विकल्प',
          items: ['Dine-in','Takeaway','Home Delivery','Outdoor Seating','Family Section','AC Seating'] },
        { label_en: 'Food Service', label_hi: 'खाद्य सेवा',
          items: ['Pure Veg','Veg & Non-Veg','Jain Food Available','Live Counter','Buffet','À la carte'] },
        { label_en: 'Payment & Tech', label_hi: 'भुगतान',
          items: ['UPI Accepted','Cards Accepted','Free WiFi','Online Ordering','Table Reservation'] },
        { label_en: 'Special', label_hi: 'विशेष',
          items: ['Birthday Celebrations','Group Bookings','Catering Service','Parking Available','Wheelchair Accessible'] }
      ]
    },

    // ─── BEAUTY ────────────────────────────────────────────
    beauty: {
      hideSections: ['sec-rooms'],
      showSections: ['sec-stylists'],
      relabelSections: {
        'sec-services': {
          en: '3. Your Services & Treatments',
          hi: '3. आपकी सेवाएँ',
          sub_en: 'Add services with prices — mark signature treatments with ⭐',
          sub_hi: 'सेवाएँ और मूल्य जोड़ें — विशेष पर ⭐'
        },
        'sec-amenities': {
          en: '5. Salon / Studio Features',
          hi: '5. सैलून सुविधाएँ',
          sub_en: 'Tick what you offer — AI uses these on your website',
          sub_hi: 'जो सुविधाएँ हैं वो चुनें'
        }
      },
      amenityGroups: [
        { label_en: 'Services Available', label_hi: 'सेवाएँ',
          items: ['Hair','Skin','Nails','Makeup','Bridal','Spa & Massage','Threading','Waxing'] },
        { label_en: 'Booking & Visit', label_hi: 'बुकिंग',
          items: ['Appointments','Walk-ins Welcome','Home Service','Late Hours','Sunday Open','Private Booth'] },
        { label_en: 'For Clients', label_hi: 'ग्राहकों के लिए',
          items: ['AC','Free WiFi','Refreshments','Parking','Kids Friendly','Wheelchair Accessible'] },
        { label_en: 'Payment & Trust', label_hi: 'भुगतान',
          items: ['UPI Accepted','Cards Accepted','Certified Staff','Single-use Tools','Skin Patch Test','Brand-name Products'] }
      ]
    },

    // ─── HEALTHCARE ────────────────────────────────────────
    healthcare: {
      hideSections: ['sec-rooms'],
      showSections: ['sec-doctors'],
      relabelSections: {
        'sec-services': {
          en: '3. Treatments & Procedures',
          hi: '3. उपचार और प्रक्रियाएँ',
          sub_en: 'Add procedures with consultation fees — mark common ones with ⭐',
          sub_hi: 'उपचार और शुल्क जोड़ें'
        },
        'sec-amenities': {
          en: '5. Clinic Features',
          hi: '5. क्लिनिक सुविधाएँ',
          sub_en: 'Tick what your clinic offers — patients see this on your website',
          sub_hi: 'जो सुविधाएँ हैं वो चुनें'
        }
      },
      amenityGroups: [
        { label_en: 'Patient Care', label_hi: 'रोगी देखभाल',
          items: ['Appointments','Walk-ins Welcome','Emergency Care','Home Visit','Online Consultation','Female Doctor Available'] },
        { label_en: 'Facilities', label_hi: 'सुविधाएँ',
          items: ['In-house Pharmacy','Diagnostic Lab','X-Ray','Ultrasound','Operation Theatre','Day-Care Procedures'] },
        { label_en: 'For Visitors', label_hi: 'आगंतुकों के लिए',
          items: ['AC Waiting Room','Free WiFi','Drinking Water','Parking','Wheelchair Accessible','Kids Play Area'] },
        { label_en: 'Payment & Insurance', label_hi: 'भुगतान',
          items: ['UPI Accepted','Cards Accepted','Cashless Insurance','EMI Available','Senior Discount','Free First Consultation'] }
      ]
    },

    // ─── SERVICES ──────────────────────────────────────────
    services: {
      hideSections: ['sec-rooms'],
      relabelSections: {
        'sec-services': {
          en: '3. Services & Pricing',
          hi: '3. सेवाएँ और मूल्य',
          sub_en: 'Add what you offer with starting prices — mark popular services with ⭐',
          sub_hi: 'अपनी सेवाएँ और मूल्य जोड़ें'
        },
        'sec-amenities': {
          en: '5. Service Details',
          hi: '5. सेवा विवरण',
          sub_en: 'Tick what describes your service — customers see this on your website',
          sub_hi: 'अपनी सेवा का विवरण चुनें'
        }
      },
      amenityGroups: [
        { label_en: 'Service Area', label_hi: 'सेवा क्षेत्र',
          items: ['Same City Only','Within 25km','Within 50km','State-wide','Pan-India','On-site Visit'] },
        { label_en: 'Availability', label_hi: 'उपलब्धता',
          items: ['Same-day Service','Next-day Service','Sunday Open','24/7 Emergency','Advance Booking','Free Site Visit'] },
        { label_en: 'Pricing Model', label_hi: 'मूल्य',
          items: ['Fixed Price','Hourly Rate','Quote on Site','Free Estimate','Cost+Materials','Annual Contracts'] },
        { label_en: 'Trust & Payment', label_hi: 'विश्वास और भुगतान',
          items: ['UPI Accepted','Cards Accepted','GST Invoice','Certified Workers','Insured Service','Warranty Provided'] }
      ]
    },

    // ─── RETAIL ────────────────────────────────────────────
    retail: {
      hideSections: ['sec-rooms'],
      relabelSections: {
        'sec-services': {
          en: '3. Your Products',
          hi: '3. आपके उत्पाद',
          sub_en: 'Add featured products with prices — mark bestsellers with ⭐',
          sub_hi: 'उत्पाद और मूल्य जोड़ें — बेस्टसेलर पर ⭐'
        },
        'sec-amenities': {
          en: '5. Shop Features',
          hi: '5. दुकान की विशेषताएँ',
          sub_en: 'Tick what your shop offers — AI uses these on your website',
          sub_hi: 'दुकान की सुविधाएँ चुनें'
        }
      },
      amenityGroups: [
        { label_en: 'Shopping Options', label_hi: 'खरीदारी विकल्प',
          items: ['In-store','Home Delivery','WhatsApp Orders','Phone Orders','Online Catalog','Pickup Available'] },
        { label_en: 'In Stock', label_hi: 'उपलब्ध',
          items: ['Branded Products','Local Brands','Imported Items','Fresh Stock Daily','Bulk Quantities','Festival Specials'] },
        { label_en: 'Shop Comfort', label_hi: 'दुकान सुविधा',
          items: ['AC Showroom','Free WiFi','Parking','Trial Room','Kids Friendly','Wheelchair Accessible'] },
        { label_en: 'Payment & Service', label_hi: 'भुगतान और सेवा',
          items: ['UPI Accepted','Cards Accepted','EMI Available','GST Invoice','Returns Accepted','Free Gift Wrapping'] }
      ]
    },

    // ─── EDUCATION ─────────────────────────────────────────
    education: {
      hideSections: ['sec-rooms'],
      relabelSections: {
        'sec-services': {
          en: '3. Courses & Programs',
          hi: '3. पाठ्यक्रम',
          sub_en: 'Add courses with fees — mark flagship programs with ⭐',
          sub_hi: 'पाठ्यक्रम और शुल्क जोड़ें'
        },
        'sec-amenities': {
          en: '5. Institute Features',
          hi: '5. संस्थान विशेषताएँ',
          sub_en: 'Tick what describes your institute — students see this on your website',
          sub_hi: 'संस्थान की विशेषताएँ चुनें'
        }
      },
      amenityGroups: [
        { label_en: 'Mode of Teaching', label_hi: 'शिक्षण विधि',
          items: ['Classroom','Online Classes','Hybrid (Online + Offline)','One-on-One','Group Batches','Home Tuition'] },
        { label_en: 'For Whom', label_hi: 'किसके लिए',
          items: ['Kids (Below 12)','Teens (13-18)','College Students','Working Professionals','Senior Citizens','Beginners Welcome'] },
        { label_en: 'Facilities', label_hi: 'सुविधाएँ',
          items: ['AC Classrooms','Free WiFi','Library Access','Doubt Sessions','Mock Tests','Study Material Provided'] },
        { label_en: 'Trust & Fees', label_hi: 'विश्वास और शुल्क',
          items: ['Free Demo Class','Money-back Guarantee','Certified Faculty','EMI on Fees','Scholarships','Job Placement Help'] }
      ]
    },

    // ─── WHOLESALE ─────────────────────────────────────────
    wholesale: {
      hideSections: ['sec-rooms'],
      relabelSections: {
        'sec-services': {
          en: '3. Your Catalogue',
          hi: '3. कैटलॉग',
          sub_en: 'Add product categories with starting prices — mark top categories with ⭐',
          sub_hi: 'उत्पाद श्रेणियाँ जोड़ें'
        },
        'sec-amenities': {
          en: '5. Business Details',
          hi: '5. व्यवसाय विवरण',
          sub_en: 'Tick what describes your wholesale business — retailers see this on your website',
          sub_hi: 'व्यवसाय का विवरण चुनें'
        }
      },
      amenityGroups: [
        { label_en: 'Order & Supply', label_hi: 'ऑर्डर और आपूर्ति',
          items: ['Minimum Order Required','Bulk Orders Only','Same-day Dispatch','Next-day Dispatch','Door Delivery','Logistics Tied-up'] },
        { label_en: 'Coverage', label_hi: 'क्षेत्र',
          items: ['City-wide','District-wide','State-wide','Pan-India','Export Available','Local Pickup Only'] },
        { label_en: 'Business Type', label_hi: 'व्यवसाय प्रकार',
          items: ['Manufacturer','Distributor','Importer','Stockist','C&F Agent','Direct from Mandi'] },
        { label_en: 'Payment & Compliance', label_hi: 'भुगतान',
          items: ['Credit Days Available','UPI Accepted','RTGS / NEFT','GST Invoice','TDS Friendly','Authorized Dealer'] }
      ]
    },

    // ─── ONLINE / D2C ──────────────────────────────────────
    online: {
      hideSections: ['sec-rooms'],
      relabelSections: {
        'sec-services': {
          en: '3. Your Shop',
          hi: '3. आपकी दुकान',
          sub_en: 'Add featured products with prices — mark bestsellers with ⭐',
          sub_hi: 'उत्पाद जोड़ें — बेस्टसेलर पर ⭐'
        },
        'sec-amenities': {
          en: '5. Brand Features',
          hi: '5. ब्रांड विशेषताएँ',
          sub_en: 'Tick what describes your brand — customers see this on your website',
          sub_hi: 'ब्रांड की विशेषताएँ चुनें'
        }
      },
      amenityGroups: [
        { label_en: 'Where to Buy', label_hi: 'खरीदारी',
          items: ['Own Website','Instagram','Amazon','Flipkart','Meesho','Direct WhatsApp'] },
        { label_en: 'Product Story', label_hi: 'उत्पाद कहानी',
          items: ['Handmade','Hand-painted','Made in India','Limited Edition','Custom Orders','Personalized Items'] },
        { label_en: 'Shipping', label_hi: 'शिपिंग',
          items: ['Pan-India Shipping','International Shipping','Free Shipping ₹999+','Same-day in City','COD Available','Express Delivery'] },
        { label_en: 'Trust', label_hi: 'विश्वास',
          items: ['Returns Accepted','Replacements','Quality Tested','Brand Authenticity','Eco-friendly Packaging','Gift Wrapping'] }
      ]
    }

    // hospitality, property, subscription — no entry, render default.
  };

  // ──────────────────────────────────────────────────────────
  // Public API (unchanged from F1)
  // ──────────────────────────────────────────────────────────

  function getConfigForMacro(macro) {
    if (!macro || typeof macro !== 'string') return null;
    return FIELDS_BY_MACRO[macro] || null;
  }

  function macroFor(shopType) {
    if (!shopType) return 'other';
    if (root.SBPSidebar && typeof root.SBPSidebar.macroFor === 'function') {
      return root.SBPSidebar.macroFor(shopType) || 'other';
    }
    const FOOD_TYPES = ['restaurant','cafe','qsr','ice_cream','cloud_kitchen',
                        'tiffin','catering','bar_lounge','food_other','food'];
    if (FOOD_TYPES.indexOf(String(shopType).toLowerCase()) >= 0) return 'food';
    return 'other';
  }

  function applyConfigToForm(macro) {
    const cfg = getConfigForMacro(macro);
    if (!cfg) return { applied: false, macro: macro || 'unknown' };

    if (Array.isArray(cfg.hideSections)) {
      cfg.hideSections.forEach(function (id) {
        const el = document.getElementById(id);
        if (el) {
          el.style.display = 'none';
          el.setAttribute('data-sbp-hidden-by-vertical', macro);
        }
      });
    }

    // F4: showSections — unhide sections that were hidden by default
    // in the markup (e.g. sec-stylists, sec-doctors). Idempotent.
    if (Array.isArray(cfg.showSections)) {
      cfg.showSections.forEach(function (id) {
        const el = document.getElementById(id);
        if (el) {
          el.style.display = '';
          el.setAttribute('data-sbp-shown-by-vertical', macro);
        }
      });
    }

    if (cfg.relabelSections) {
      Object.keys(cfg.relabelSections).forEach(function (id) {
        const el = document.getElementById(id);
        if (!el) return;
        const r = cfg.relabelSections[id];
        const h2en  = el.querySelector('.sec-hd h2 .lang-en');
        const h2hi  = el.querySelector('.sec-hd h2 .lang-hi');
        const suben = el.querySelector('.sec-hd .sub .lang-en');
        const subhi = el.querySelector('.sec-hd .sub .lang-hi');
        if (h2en  && r.en)     h2en.textContent  = r.en;
        if (h2hi  && r.hi)     h2hi.textContent  = r.hi;
        if (suben && r.sub_en) suben.textContent = r.sub_en;
        if (subhi && r.sub_hi) subhi.textContent = r.sub_hi;
      });
    }

    if (Array.isArray(cfg.amenityGroups)) {
      const grid = document.getElementById('amenity-grid');
      if (grid) {
        const previouslyChecked = new Set();
        grid.querySelectorAll('input[type="checkbox"]:checked').forEach(function (cb) {
          previouslyChecked.add(cb.value);
        });

        let html = '';
        cfg.amenityGroups.forEach(function (g) {
          html += '<div class="amenity-group-lbl">' +
                  '<span class="lang-en">' + escapeHtml(g.label_en) + '</span>' +
                  '<span class="lang-hi">' + escapeHtml(g.label_hi || g.label_en) + '</span>' +
                  '</div>';
          (g.items || []).forEach(function (item) {
            const checked = previouslyChecked.has(item) ? ' checked' : '';
            html += '<label class="amenity-chip">' +
                    '<input type="checkbox" value="' + escapeHtml(item) + '"' + checked + '> ' +
                    escapeHtml(item) +
                    '</label>';
          });
        });
        grid.innerHTML = html;
      }
    }

    return { applied: true, macro: macro };
  }

  function escapeHtml(s) {
    if (s == null) return '';
    return String(s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  root.SBPBuilderFields = {
    FIELDS_BY_MACRO:   FIELDS_BY_MACRO,
    getConfigForMacro: getConfigForMacro,
    macroFor:          macroFor,
    applyConfigToForm: applyConfigToForm
  };

})(typeof window !== 'undefined' ? window : this);
