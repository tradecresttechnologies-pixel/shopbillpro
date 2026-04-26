/* ══════════════════════════════════════════
   ShopBill Pro — Complete Hindi Language System
   Works on ALL pages automatically
   TradeCrest Technologies Pvt. Ltd.
══════════════════════════════════════════ */

const SBP_TRANSLATIONS = {
  en: {}, // English is default - no replacement needed
  hi: {
    // ── Navigation ──
    'Home': 'होम', 'Bills': 'बिल', 'Customers': 'ग्राहक',
    'More': 'अधिक', 'Settings': 'सेटिंग', 'Reports': 'रिपोर्ट',
    'Dashboard': 'डैशबोर्ड', 'New Bill': 'नया बिल',
    'Inventory': 'इन्वेंटरी', 'POS Admin': 'POS एडमिन',
    'WhatsApp': 'व्हाट्सएप', 'Cash Register': 'कैश रजिस्टर',
    'Suppliers': 'सप्लायर', 'Recurring': 'आवर्ती',
    'Templates': 'टेम्पलेट', 'Logout': 'लॉग आउट',

    // ── Dashboard ──
    "Today\'s Sales": 'आज की बिक्री',
    'Total Bills': 'कुल बिल',
    'Outstanding': 'बकाया',
    'GST Payable': 'GST देय',
    'Quick Actions': 'त्वरित कार्य',
    'Recent Bills': 'हाल के बिल',
    'Outstanding Customers': 'बकाया ग्राहक',
    'View All': 'सभी देखें',
    'Remind All': 'सभी को याद दिलाएं',
    'GST Report': 'GST रिपोर्ट',
    'Stock': 'स्टॉक',
    'Ledger': 'खाता बही',
    'POS Mode': 'POS मोड',
    'Good Morning': 'सुप्रभात',
    'Good Afternoon': 'शुभ दोपहर',
    'Good Evening': 'शुभ संध्या',

    // ── Billing ──
    'New Invoice': 'नया बिल',
    'Manual Bill': 'मैनुअल बिल',
    'POS — Quick Billing': 'POS — त्वरित बिलिंग',
    'Customer Name': 'ग्राहक का नाम',
    'Invoice No': 'बिल नंबर',
    'Invoice Date': 'बिल तिथि',
    'Due Date': 'देय तिथि',
    'Payment Mode': 'भुगतान विधि',
    'Add Item': 'आइटम जोड़ें',
    'Subtotal': 'उप-योग',
    'Discount': 'छूट',
    'Grand Total': 'कुल राशि',
    'GST Amount': 'GST राशि',
    'Bill Summary': 'बिल सारांश',
    'Save Bill': 'बिल सहेजें',
    'Preview': 'पूर्वावलोकन',
    'Print': 'प्रिंट',
    'Send WhatsApp': 'व्हाट्सएप भेजें',
    'Cash': 'नकद', 'UPI': 'UPI', 'Card': 'कार्ड', 'Cheque': 'चेक',
    'Credit': 'उधार', 'Paid': 'भुगतान हो गया',
    'Pending': 'लंबित', 'Partial': 'आंशिक',

    // ── Stock / Inventory ──
    'Products': 'उत्पाद',
    'Low Stock': 'कम स्टॉक',
    'Stock Value': 'स्टॉक मूल्य',
    'In Stock': 'स्टॉक में',
    'Out of Stock': 'स्टॉक खत्म',
    'Stock IN': 'स्टॉक IN',
    'Stock OUT': 'स्टॉक OUT',
    'Set Stock': 'स्टॉक सेट करें',
    'All Categories': 'सभी श्रेणियां',
    'Add Product': 'उत्पाद जोड़ें',
    'Product Name': 'उत्पाद का नाम',
    'Price': 'कीमत',
    'Category': 'श्रेणी',
    'Barcode': 'बारकोड',

    // ── Customers ──
    'Add Customer': 'ग्राहक जोड़ें',
    'Customer Type': 'ग्राहक प्रकार',
    'Phone': 'फोन',
    'WhatsApp No': 'व्हाट्सएप नं',
    'Address': 'पता',
    'City': 'शहर',
    'Balance': 'शेष राशि',
    'All Customers': 'सभी ग्राहक',

    // ── Bills ──
    'Bills & Settlement': 'बिल और निपटान',
    'Received': 'प्राप्त',
    'Due': 'देय',
    'All': 'सभी',
    'Overdue': 'अतिदेय',
    'Total Amount': 'कुल राशि',

    // ── Reports ──
    'Sales Report': 'बिक्री रिपोर्ट',
    'Top Customers': 'शीर्ष ग्राहक',
    'Top Items': 'शीर्ष आइटम',
    'Today': 'आज',
    'This Week': 'इस सप्ताह',
    'This Month': 'इस महीने',
    'Revenue': 'आय',
    'Profit': 'मुनाफा',

    // ── Settings ──
    'Shop Settings': 'दुकान सेटिंग',
    'Shop Name': 'दुकान का नाम',
    'Owner Name': 'मालिक का नाम',
    'Language': 'भाषा',
    'Theme': 'थीम',
    'Dark Mode': 'डार्क मोड',
    'Light Mode': 'लाइट मोड',
    'Session Timeout': 'सत्र समय सीमा',
    'Cloud Sync Status': 'क्लाउड सिंक स्थिति',
    'Backup Data': 'डेटा बैकअप',
    'Restore Data': 'डेटा पुनर्स्थापित करें',
    'Send Feedback': 'प्रतिक्रिया भेजें',
    'About ShopBill Pro': 'ShopBill Pro के बारे में',
    'Plan & Subscription': 'प्लान और सदस्यता',
    'Free Plan': 'मुफ्त प्लान',
    'Unlimited bills': 'असीमित बिल',
    'Upgrade to Pro': 'Pro में अपग्रेड करें',
    'Data & Cloud': 'डेटा और क्लाउड',
    'Logout from ShopBill Pro': 'ShopBill Pro से लॉग आउट',

    // ── Recurring ──
    'Recurring Bills': 'आवर्ती बिल',
    'No recurring bills': 'कोई आवर्ती बिल नहीं',
    'Create First Schedule': 'पहला शेड्यूल बनाएं',
    'Active': 'सक्रिय',
    'Paused': 'रोका गया',
    'Due Today': 'आज देय',

    // ── Supplier ──
    'Supplier Book': 'सप्लायर बुक',
    'Add Supplier': 'सप्लायर जोड़ें',
    'Payable': 'देय',
    'No suppliers yet': 'अभी कोई सप्लायर नहीं',

    // ── Cash Register ──
    'Open Register': 'रजिस्टर खोलें',
    'Close Register': 'रजिस्टर बंद करें',
    'Cash In': 'नकद अंदर',
    'Cash Out': 'नकद बाहर',
    'Opening Balance': 'शुरुआती बैलेंस',
    'Closing Balance': 'अंतिम बैलेंस',

    // ── WhatsApp ──
    'Send Message': 'संदेश भेजें',
    'Bill Reminder': 'बिल रिमाइंडर',
    'Payment Due': 'भुगतान देय',

    // ── Common ──
    'Search': 'खोजें',
    'Save': 'सहेजें',
    'Cancel': 'रद्द करें',
    'Delete': 'हटाएं',
    'Edit': 'संपादित करें',
    'Close': 'बंद करें',
    'Add': 'जोड़ें',
    'No data yet': 'अभी कोई डेटा नहीं',
    'Loading...': 'लोड हो रहा है...',
    'Version': 'संस्करण',
    'Date': 'तिथि',
    'Amount': 'राशि',
    'Name': 'नाम',
    'Mobile': 'मोबाइल',
    'Total': 'कुल',
    // ── Settings extra ──
    'Shop Details': 'दुकान की जानकारी',
    'Shop Management': 'दुकान प्रबंधन',
    'Inventory & Stock': 'इन्वेंटरी और स्टॉक',
    'POS Admin Panel': 'POS एडमिन पैनल',
    'Supplier Book': 'सप्लायर बुक',
    'WhatsApp Center': 'व्हाट्सएप केंद्र',
    'Bill Templates': 'बिल टेम्पलेट',
    'Settings & More': 'सेटिंग और अधिक',
    'Plan & Subscription': 'प्लान और सदस्यता',
    'Free Plan': 'मुफ्त प्लान',
    'Unlimited bills': 'असीमित बिल',
    'Free forever': 'हमेशा के लिए मुफ्त',
    'Upgrade to Pro': 'Pro में अपग्रेड करें',
    'Data & Cloud': 'डेटा और क्लाउड',
    'Cloud Sync': 'क्लाउड सिंक',
    'Backup Data': 'डेटा बैकअप',
    'Restore Data': 'डेटा पुनर्स्थापित करें',
    'Clear All Data': 'सभी डेटा हटाएं',
    'Send Feedback': 'प्रतिक्रिया भेजें',
    'About ShopBill Pro': 'ShopBill Pro के बारे में',
    'Version 1.0': 'संस्करण 1.0',
    'Made in India': 'भारत में बना',
    'Logout from ShopBill Pro': 'ShopBill Pro से लॉग आउट',
    'Session Timeout': 'सत्र समय सीमा',
    'Language': 'भाषा',
    'Theme': 'थीम',
    'Dark': 'डार्क',
    'Light': 'लाइट',
    'English': 'अंग्रेजी',
    'Hindi': 'हिंदी',
    'Admin': 'एडमिन',
    'Shop Name': 'दुकान का नाम',
    'Owner Name': 'मालिक का नाम',
    'Products, POS catalogue, stock levels': 'उत्पाद, POS, स्टॉक स्तर',
    'Products, categories, bulk import': 'उत्पाद, श्रेणियां, बल्क इम्पोर्ट',
    'Vendors, payables, payment tracking': 'वेंडर, देय, भुगतान ट्रैकिंग',
    'Daily opening & closing balance': 'दैनिक ओपनिंग और क्लोजिंग बैलेंस',
    'Message templates, quick & bulk send': 'मैसेज टेम्पलेट, त्वरित भेजें',
    'Save & reuse common bills in one tap': 'एक क्लिक में बिल सेव और पुनः उपयोग',
    'Name, address, GSTIN, UPI ID': 'नाम, पता, GSTIN, UPI ID',
  }
};

/* Apply language across the page */
function sbpApplyLang() {
  var lang = localStorage.getItem('sbp_lang') || 'en';
  document.documentElement.lang = lang;

  if (lang !== 'hi') return;
  var dict = SBP_TRANSLATIONS.hi;

  // FIX #59 — sort keys longest-first (avoid "Pay" matching inside "Payment")
  var keys = Object.keys(dict).sort(function(a,b){return b.length - a.length;});

  function applyTranslations(root){
    if(!root) return;
    function walkNode(node) {
      if (node.nodeType === 3) {
        var text = node.nodeValue;
        if (!text || !text.trim()) return;
        var changed = false;
        // FIX #58 — plain string replacement (no regex compile per node)
        for (var i=0; i<keys.length; i++) {
          var key = keys[i];
          if (text.indexOf(key) !== -1) {
            text = text.split(key).join(dict[key]);
            changed = true;
          }
        }
        if(changed) node.nodeValue = text;
      } else if (node.nodeType === 1) {
        var tag = node.tagName;
        if (tag === 'SCRIPT' || tag === 'STYLE') return;
        if ((tag === 'INPUT' || tag === 'TEXTAREA') && node.placeholder) {
          var ph = node.placeholder;
          for (var k=0; k<keys.length; k++) {
            if (ph.indexOf(keys[k]) !== -1) ph = ph.split(keys[k]).join(dict[keys[k]]);
          }
          if(ph !== node.placeholder) node.placeholder = ph;
        }
        for (var c = 0; c < node.childNodes.length; c++) {
          walkNode(node.childNodes[c]);
        }
      }
    }
    walkNode(root);
  }

  // FIX #60 — handle BOTH cases: script loaded before AND after DOMContentLoaded
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() { applyTranslations(document.body); });
  } else {
    applyTranslations(document.body);
  }
}

// Run immediately
(function(){
  var lang = localStorage.getItem('sbp_lang') || 'en';
  document.documentElement.lang = lang;
  sbpApplyLang();
})();

window.sbpApplyLang = sbpApplyLang;
window.SBP_TRANSLATIONS = SBP_TRANSLATIONS;
