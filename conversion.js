/* ══════════════════════════════════════════════════════════
   ShopBill Pro — Smart Conversion System
   7 Popups · Right Time · Right Message · Hinglish Copy
   TradeCrest Technologies Pvt. Ltd.
══════════════════════════════════════════════════════════ */

(function(){
  'use strict';

  /* ── Helpers ── */
  function isPro(){
    const s=JSON.parse(localStorage.getItem('sbp_shop')||'{}');
    // BATCH 1B-E: active beta signups have full features unlocked — suppress upsells
    // (covers both the active period and the 7-day grace window)
    if(s.is_beta_signup === true){
      const now = new Date();
      const expires = s.plan_expires_at ? new Date(s.plan_expires_at) : null;
      const grace   = s.beta_grace_until ? new Date(s.beta_grace_until) : null;
      if(expires && expires > now) return true;
      if(grace && grace > now) return true;
    }
    // Paid plans (legacy 'enterprise' is normalized to 'business' elsewhere)
    return s.plan==='pro' || s.plan==='enterprise' || s.plan==='business';
  }
  function getLang(){ return localStorage.getItem('sbp_lang')||'en'; }
  function hi(){ return getLang()==='hi'; }
  function getBillCount(){
    const bills=JSON.parse(localStorage.getItem('sbp_bills')||'[]');
    const ym=new Date().toISOString().slice(0,7);
    return bills.filter(b=>(b.invoice_date||b.created_at||'').startsWith(ym)).length;
  }
  function getTotalBills(){
    return (JSON.parse(localStorage.getItem('sbp_bills')||'[]')).length;
  }
  function getUsageDays(){
    const first=localStorage.getItem('sbp_first_use');
    if(!first) return 0;
    return Math.floor((Date.now()-parseInt(first))/(1000*60*60*24));
  }
  function markFirstUse(){
    if(!localStorage.getItem('sbp_first_use'))
      localStorage.setItem('sbp_first_use',Date.now().toString());
  }
  function popupShownRecently(key, hours){
    const last=parseInt(localStorage.getItem('sbp_popup_'+key)||'0');
    return Date.now()-last < hours*60*60*1000;
  }
  function markPopupShown(key){
    localStorage.setItem('sbp_popup_'+key,Date.now().toString());
  }
  function getShop(){
    return JSON.parse(localStorage.getItem('sbp_shop')||'{}');
  }
  function openSubscriptionPage(){
    window.location.href='subscription.html';
  }

  /* ── Core popup renderer ── */
  function showPopup(opts){
    // Remove existing
    const existing=document.getElementById('sbp-conversion-popup');
    if(existing) existing.remove();

    const overlay=document.createElement('div');
    overlay.id='sbp-conversion-popup';
    overlay.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.75);z-index:99999;display:flex;align-items:flex-end;justify-content:center;animation:sbpFadeIn .2s ease';

    const style=document.createElement('style');
    style.textContent=`@keyframes sbpFadeIn{from{opacity:0}to{opacity:1}}@keyframes sbpSlideUp{from{transform:translateY(100%)}to{transform:translateY(0)}}`;
    document.head.appendChild(style);

    overlay.innerHTML=`
    <div style="background:var(--surf,#13131C);border-radius:24px 24px 0 0;width:100%;max-width:520px;overflow:hidden;animation:sbpSlideUp .32s cubic-bezier(.4,0,.2,1)">
      ${opts.topBanner?`<div style="background:${opts.topBannerColor||'linear-gradient(135deg,#F5A623,#FF8A00)'};padding:16px 20px 14px;text-align:center">
        <div style="font-size:28px;margin-bottom:6px">${opts.topBannerIcon||'🚀'}</div>
        <div style="font-family:'Outfit',sans-serif;font-size:17px;font-weight:900;color:#fff;line-height:1.3">${opts.topBanner}</div>
        ${opts.topBannerSub?`<div style="font-size:12px;color:rgba(255,255,255,.75);margin-top:4px">${opts.topBannerSub}</div>`:''}
      </div>`:''}
      <div style="padding:20px 20px 8px">
        ${opts.emoji?`<div style="font-size:36px;text-align:center;margin-bottom:10px">${opts.emoji}</div>`:''}
        ${opts.title?`<div style="font-family:'Outfit',sans-serif;font-size:19px;font-weight:900;color:var(--text,#F0EFF8);text-align:center;margin-bottom:8px;line-height:1.3">${opts.title}</div>`:''}
        ${opts.body?`<div style="font-size:13px;color:var(--t2,#8A8AA8);text-align:center;line-height:1.7;margin-bottom:16px">${opts.body}</div>`:''}
        ${opts.bullets?`<div style="display:flex;flex-direction:column;gap:8px;margin-bottom:16px;background:rgba(245,166,35,.06);border-radius:12px;padding:14px">
          ${opts.bullets.map(b=>`<div style="display:flex;align-items:center;gap:10px;font-size:13px"><span>${b.ic}</span><span style="color:var(--text,#F0EFF8)">${b.text}</span></div>`).join('')}
        </div>`:''}
        ${opts.priceBlock?`<div style="text-align:center;margin-bottom:16px;background:rgba(245,166,35,.08);border-radius:14px;padding:14px 10px">
          <div style="font-size:11px;color:var(--t2,#8A8AA8);text-transform:uppercase;letter-spacing:.8px;font-weight:700;margin-bottom:4px">${opts.priceBlock.label}</div>
          <div style="font-family:'Outfit',sans-serif;font-size:36px;font-weight:900;background:linear-gradient(135deg,#FF8A00,#F5A623);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text">${opts.priceBlock.price}</div>
          <div style="font-size:11px;color:var(--acc3,#10B981);font-weight:700;margin-top:2px">${opts.priceBlock.sub}</div>
        </div>`:''}
        <button id="sbp-popup-cta" style="width:100%;padding:15px;border-radius:14px;background:linear-gradient(135deg,#F5A623,#FF8A00);border:none;color:#0A0E1A;font-family:'Outfit',sans-serif;font-size:16px;font-weight:800;cursor:pointer;margin-bottom:10px;letter-spacing:.3px;box-shadow:0 4px 20px rgba(245,166,35,.4)">
          ${opts.ctaText||'🚀 Upgrade Now'}
        </button>
        <button id="sbp-popup-dismiss" style="width:100%;padding:12px;border-radius:14px;background:transparent;border:none;color:var(--t2,#8A8AA8);font-size:13px;cursor:pointer;margin-bottom:16px">
          ${opts.dismissText||(hi()?'बाद में देखूंगा':'Maybe Later')}
        </button>
      </div>
    </div>`;

    document.body.appendChild(overlay);

    document.getElementById('sbp-popup-cta').addEventListener('click',function(){
      overlay.remove();
      if(opts.onCta) opts.onCta();
      else openSubscriptionPage();
    });
    document.getElementById('sbp-popup-dismiss').addEventListener('click',function(){
      overlay.remove();
      if(opts.onDismiss) opts.onDismiss();
    });
    overlay.addEventListener('click',function(e){
      if(e.target===overlay) overlay.remove();
    });
  }

  /* ── POPUP 1: After 10-20 bills — Data Safety Warning ── */
  function checkBillMilestone(){
    if(isPro()) return;
    if(popupShownRecently('milestone',72)) return;
    const count=getTotalBills();
    if(count<10||count>100) return;
    markPopupShown('milestone');
    showPopup({
      topBannerIcon: '⚠️',
      topBanner: hi()?'Aapka data sirf is phone mein hai!':'Your shop data is only on this phone!',
      topBannerSub: hi()?'Phone kho gaya toh sab chala jayega 😟':'If phone is lost, all your records are gone 😟',
      topBannerColor: 'linear-gradient(135deg,#EF4444,#DC2626)',
      title: hi()?`${count} billon ka data risk mein hai`:`${count} bills at risk`,
      body: hi()
        ?'Aapne itni mehnat se itne bill banaye. Ek baar phone kho gaya ya toota — sab khatam. Cloud backup se apna business safe rakho.'
        :'You\'ve worked hard to build these records. One phone loss — everything gone. Protect your business with cloud backup.',
      bullets: hi()?[
        {ic:'☁️',text:'Cloud backup — kabhi bhi, kahin bhi access karo'},
        {ic:'🔒',text:'Data encrypted aur safe rahega'},
        {ic:'📱',text:'Naye phone pe bhi sab data wapas milega'},
      ]:[
        {ic:'☁️',text:'Cloud backup — access from any device'},
        {ic:'🔒',text:'Encrypted & secure data storage'},
        {ic:'📱',text:'Get all data back on a new phone instantly'},
      ],
      priceBlock:{
        label: hi()?'sirf':'just',
        price: '₹99/month',
        sub: hi()?'₹3/day — ek chai se bhi sasta! ☕':'₹3/day — less than a cup of chai! ☕'
      },
      ctaText: hi()?'🔒 Abhi Cloud Backup Enable Karein':'🔒 Enable Cloud Backup Now',
      dismissText: hi()?'Abhi nahi, baad mein dekhta hoon':'Not now, I\'ll risk it'
    });
  }

  /* ── POPUP 2: After 50+ bills — Strong fear-based ── */
  function checkHeavyUser(){
    if(isPro()) return;
    if(popupShownRecently('heavyuser',120)) return;
    const total=getTotalBills();
    if(total<50) return;
    markPopupShown('heavyuser');
    showPopup({
      emoji: '😟',
      title: hi()
        ?'Zara sochiye... ek second mein sab gone?'
        :'Imagine losing all this in one second...',
      body: hi()
        ?`Aapke ${total} bills, saare customers, poori inventory — ek phone damage se sab khatam. Koi record nahi, koi history nahi, koi business data nahi.\n\nYe risk mat lo.`
        :`Your ${total} bills, all customer records, full inventory — one phone damage and everything is gone. No records. No history. No business data.\n\nDon't take this risk.`,
      bullets: hi()?[
        {ic:'❌',text:'Koi record nahi — koi proof nahi'},
        {ic:'❌',text:'Customer history — sab khatam'},
        {ic:'❌',text:'GST data — CA ko doge kya?'},
        {ic:'✅',text:'Cloud backup se sab safe — kabhi nahi jayega'},
      ]:[
        {ic:'❌',text:'No billing records — no proof'},
        {ic:'❌',text:'Customer history — completely gone'},
        {ic:'❌',text:'GST data — nothing to share with CA'},
        {ic:'✅',text:'Cloud backup keeps everything safe forever'},
      ],
      priceBlock:{
        label:'Secure everything for',
        price:'₹99/month',
        sub:hi()?'Sirf ₹3/day · Cancel anytime':'Only ₹3/day · Cancel anytime'
      },
      ctaText:hi()?'✅ Haan, Data Safe Karo':'✅ Yes, Keep My Data Safe',
    });
  }

  /* ── POPUP 3: Dashboard soft banner (daily) ── */
  function showDashboardBanner(){
    if(isPro()) return;
    if(popupShownRecently('dashbanner',24)) return;
    const days=getUsageDays();
    if(days<3) return;
    markPopupShown('dashbanner');
    const banner=document.createElement('div');
    banner.id='sbp-soft-banner';
    banner.style.cssText='background:linear-gradient(135deg,rgba(245,166,35,.12),rgba(255,138,0,.08));border:1px solid rgba(245,166,35,.2);border-radius:14px;padding:12px 16px;margin:12px 16px 0;display:flex;align-items:center;gap:12px;cursor:pointer;animation:sbpFadeIn .3s ease';
    banner.innerHTML=`
      <span style="font-size:22px;flex-shrink:0">🔒</span>
      <div style="flex:1">
        <div style="font-family:'Outfit',sans-serif;font-size:13px;font-weight:700;color:var(--text,#F0EFF8)">${hi()?'Aapka data protect nahi hai':'Your shop data is not protected'}</div>
        <div style="font-size:11px;color:var(--t2,#8A8AA8);margin-top:2px">${hi()?'₹3/day mein cloud backup enable karo':'Enable cloud backup for ₹3/day'}</div>
      </div>
      <div style="font-family:'Outfit',sans-serif;font-size:11px;font-weight:800;color:var(--acc,#F5A623);background:rgba(245,166,35,.12);border:1px solid rgba(245,166,35,.2);border-radius:8px;padding:5px 10px;flex-shrink:0;white-space:nowrap">${hi()?'Upgrade →':'Upgrade →'}</div>
      <span onclick="event.stopPropagation();this.closest('#sbp-soft-banner').remove()" style="font-size:14px;color:var(--t3,#4A4A60);cursor:pointer;padding:2px 4px">✕</span>
    `;
    banner.addEventListener('click',openSubscriptionPage);
    // Insert after topbar
    const sb=document.querySelector('.sb')||document.getElementById('app');
    const topbar=document.querySelector('.topbar');
    if(topbar&&topbar.nextSibling) topbar.parentNode.insertBefore(banner,topbar.nextSibling);
    else if(sb) sb.prepend(banner);
  }

  /* ── POPUP 4: WhatsApp send attempt — context popup ── */
  window.sbpCheckWhatsAppTrigger=function(){
    if(isPro()) return true; // allow
    if(popupShownRecently('wa_trigger',48)) return true;
    markPopupShown('wa_trigger');
    showPopup({
      topBannerIcon:'📲',
      topBanner:hi()?'Bill bhejne se pehle...':'Before you send this bill...',
      topBannerSub:hi()?'Aapka data abhi sirf is phone mein hai':'Your data exists only on this phone',
      title:hi()?'Aap bills bhej rahe ho...':'You\'re sending bills to customers...',
      body:hi()
        ?'Aapka business grow ho raha hai! Lekin aapka data safe nahi hai. Agar phone kho gaya toh in sabhi customers ka record bhi khatam.\n\nCloud backup se sab safe rakho — sirf ₹3/day mein.'
        :'Your business is growing! But your data isn\'t safe. If your phone is damaged, all these customer records are gone.\n\nKeep everything safe with cloud backup — just ₹3/day.',
      bullets:hi()?[
        {ic:'📲',text:'Bills bhejte raho — befikr hokar'},
        {ic:'☁️',text:'Sab data cloud pe automatically save hoga'},
        {ic:'💰',text:'Customer payment history kabhi nahi jayegi'},
      ]:[
        {ic:'📲',text:'Keep sending bills — worry-free'},
        {ic:'☁️',text:'All data auto-saves to cloud'},
        {ic:'💰',text:'Customer payment history always safe'},
      ],
      priceBlock:{label:'protect everything for',price:'₹99/month',sub:hi()?'₹3/day — abhi upgrade karo':'₹3/day — upgrade now'},
      ctaText:hi()?'☁️ Cloud Backup Enable Karo':'☁️ Enable Cloud Backup',
      dismissText:hi()?'Risk leke bhejta hoon':'Send without backup',
      onDismiss:function(){return true;} // allow WA send
    });
    return false; // pause WA send
  };

  /* ── POPUP 5: Settings page — trust builder ── */
  window.sbpShowSettingsTrust=function(){
    if(isPro()) return;
    if(popupShownRecently('settings_trust',24)) return;
    markPopupShown('settings_trust');
    const bills=getTotalBills();
    const el=document.getElementById('storage-location-detail');
    if(el){
      el.innerHTML=`<div style="margin-top:8px;padding:10px 12px;background:rgba(239,68,68,.08);border:1px solid rgba(239,68,68,.2);border-radius:10px;display:flex;align-items:center;gap:8px;cursor:pointer" onclick="window.location.href='subscription.html'">
        <span style="font-size:16px">⚠️</span>
        <div style="flex:1">
          <div style="font-size:12px;font-weight:700;color:#FCA5A5">${hi()?'Last Backup: ❌ Secured nahi hai':'Last Backup: ❌ Not Secured'}</div>
          <div style="font-size:11px;color:var(--t2,#8A8AA8);margin-top:1px">${bills>0?(hi()?`Aapke ${bills} bills abhi tak cloud pe nahi hain`:`${bills} bills not backed up to cloud`):(hi()?'Cloud backup enable karo':'Enable cloud backup')}</div>
        </div>
        <div style="font-size:11px;font-weight:700;color:var(--acc,#F5A623);white-space:nowrap">${hi()?'Fix Karo →':'Fix Now →'}</div>
      </div>`;
    }
  };

  /* ── POPUP 6: After 3-5 days of use — habit-based ── */
  function checkHabitTrigger(){
    if(isPro()) return;
    if(popupShownRecently('habit',120)) return;
    const days=getUsageDays();
    if(days<3||days>30) return;
    markPopupShown('habit');
    showPopup({
      emoji:'🏪',
      title:hi()?`${days} din se ShopBill Pro use kar rahe ho!`:`You've been using ShopBill Pro for ${days} days!`,
      body:hi()
        ?'Bahut achha! Aapka business digitally manage ho raha hai. Ab ek kadam aur — apna data cloud pe safe karo. Kal agar phone kuch ho gaya toh sab mehnat barbaad nahi hogi.'
        :'Great progress! Your business is going digital. Take one more step — back up your data to the cloud. If anything happens to your phone tomorrow, your hard work is safe.',
      bullets:hi()?[
        {ic:'📱',text:`${days} din ka data abhi sirf is device pe hai`},
        {ic:'☁️',text:'Cloud backup = business ki safety net'},
        {ic:'₹',text:'Sirf ₹99/month = ₹3/day'},
      ]:[
        {ic:'📱',text:`${days} days of data exists only on this device`},
        {ic:'☁️',text:'Cloud backup = your business safety net'},
        {ic:'₹',text:'Only ₹99/month = ₹3/day'},
      ],
      priceBlock:{label:'Start protecting today for',price:'₹99/month',sub:'Cancel anytime · No hidden charges'},
      ctaText:hi()?'🔒 Haan, Business Protect Karo':'🔒 Yes, Protect My Business',
    });
  }

  /* ── POPUP 7: Referral popup (show after successful upgrade flow) ── */
  window.sbpShowReferralPopup=function(){
    showPopup({
      topBannerIcon:'🎁',
      topBanner:hi()?'Dosto ko bhi faayda do!':'Share the benefit with friends!',
      topBannerColor:'linear-gradient(135deg,#10B981,#059669)',
      title:hi()?'3 dost = 1 mahina FREE Cloud!':'3 Friends = 1 Month FREE Cloud!',
      body:hi()
        ?'Apne dost dukandaaron ko ShopBill Pro ke baare mein batao. Unke upgrade karne ke baad aapko 1 mahina FREE cloud backup milega!'
        :'Tell your shopkeeper friends about ShopBill Pro. When they upgrade, you get 1 month FREE cloud backup!',
      bullets:hi()?[
        {ic:'1️⃣',text:'Apna referral link copy karo'},
        {ic:'2️⃣',text:'WhatsApp pe dosto ko bhejo'},
        {ic:'3️⃣',text:'3 log join karein → 1 mahina FREE milega'},
      ]:[
        {ic:'1️⃣',text:'Copy your referral link'},
        {ic:'2️⃣',text:'Share via WhatsApp with shopkeeper friends'},
        {ic:'3️⃣',text:'3 friends join → you get 1 month FREE'},
      ],
      ctaText:hi()?'📲 Referral Link Copy Karo':'📲 Copy Referral Link',
      dismissText:hi()?'Baad mein':'Maybe Later',
      onCta:function(){
        const link='https://app.shopbillpro.in/?ref='+encodeURIComponent(getShop().name||'friend');
        if(navigator.clipboard) navigator.clipboard.writeText(link).then(()=>alert('Link copied!'));
        else alert('Share: '+link);
      }
    });
  };

  /* ── Auto-triggers ── */
  function runTriggers(){
    markFirstUse();
    const page=window.location.pathname.split('/').pop()||'dashboard.html';
    // Only trigger on app pages, not on login
    if(page==='index.html') return;
    if(isPro()) return;

    // Stagger triggers to not overwhelm user
    setTimeout(()=>{
      if(page==='dashboard.html') showDashboardBanner();
    },2000);

    setTimeout(()=>{
      checkBillMilestone();
    },3500);

    setTimeout(()=>{
      checkHeavyUser();
    },5000);

    setTimeout(()=>{
      checkHabitTrigger();
    },7000);

    // Settings page trigger
    if(page==='settings.html'){
      setTimeout(()=>{ if(window.sbpShowSettingsTrust) window.sbpShowSettingsTrust(); },1500);
    }
  }

  // Run after DOM ready
  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',runTriggers);
  } else {
    setTimeout(runTriggers,500);
  }

  // Expose manual triggers
  window.SBPConversion={
    showBillMilestone:checkBillMilestone,
    showHeavyUser:checkHeavyUser,
    showDashboardBanner:showDashboardBanner,
    showReferral:window.sbpShowReferralPopup,
    checkWATrigger:window.sbpCheckWhatsAppTrigger,
    openPlans:openSubscriptionPage,
  };

})();
