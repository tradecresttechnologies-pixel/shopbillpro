/* ══════════════════════════════════════════════════════════════
   ShopBill Pro — Universal Barcode Scanner v2.0
   TradeCrest Technologies Pvt. Ltd.

   Fixes:
   1. ZXing JS fallback when BarcodeDetector unavailable
   2. Clear camera permission UX with instructions
   3. openAdminScanner() for pos-admin product code field
   4. Product matching: code + hsn_code + name (barcode field removed)
   5. Hardware Bluetooth scanner — global keydown buffer
   6. iOS Safari stream cleanup fix
   7. Torch/flashlight toggle on supported devices
══════════════════════════════════════════════════════════════ */

(function(global){
'use strict';

/* ── ZXing loader (lazy — only loads when camera opens) ── */
let _zxingReader = null;
let _zxingLoading = false;
let _zxingLoaded = false;

function _loadZXing(cb){
  if(_zxingLoaded){ cb(); return; }
  if(_zxingLoading){ setTimeout(()=>_loadZXing(cb), 200); return; }
  _zxingLoading = true;
  const s = document.createElement('script');
  s.src = 'https://cdn.jsdelivr.net/npm/@zxing/library@0.20.0/umd/index.min.js';
  s.onload = ()=>{ _zxingLoaded=true; _zxingLoading=false; cb(); };
  s.onerror = ()=>{ _zxingLoading=false; cb(); }; // fail silently, manual fallback still works
  document.head.appendChild(s);
}

/* ── Core scanner state ── */
let _stream    = null;
let _scanTimer = null;
let _torchOn   = false;
let _torchTrack= null;
let _onResult  = null; // callback(code)
let _statusEl  = null;
let _videoEl   = null;

/* ── Open scanner in a given modal ── */
// modalIds: { modal, video, status, manualInp, torchBtn }
// onResult: function(code) called when scan succeeds
function open(opts){
  _onResult  = opts.onResult;
  _statusEl  = document.getElementById(opts.statusId);
  _videoEl   = document.getElementById(opts.videoId);
  const modal = document.getElementById(opts.modalId);
  if(!modal) return;
  modal.style.display = 'flex';
  if(_statusEl) _statusEl.textContent = '📷 Starting camera...';
  const manualInp = document.getElementById(opts.manualInputId);
  if(manualInp) manualInp.value = '';
  _torchOn = false;
  _startCamera(opts);
}

/* ── Close scanner, release all resources ── */
function close(opts){
  if(opts){
    const modal = document.getElementById(opts.modalId);
    if(modal) modal.style.display = 'none';
  }
  _stopAll();
}

function _stopAll(){
  clearInterval(_scanTimer); _scanTimer = null;
  // iOS fix: explicitly stop each track before nulling stream
  if(_stream){
    try{ _stream.getTracks().forEach(t=>{ t.stop(); }); }catch(e){}
    _stream = null;
  }
  if(_videoEl){ try{ _videoEl.srcObject=null; }catch(e){} }
  _torchOn=false; _torchTrack=null;
}

async function _startCamera(opts){
  try {
    // Request back camera
    _stream = await navigator.mediaDevices.getUserMedia({
      video:{ facingMode:{ ideal:'environment' }, width:{ ideal:1280 }, height:{ ideal:720 } }
    });
    _videoEl.srcObject = _stream;
    await _videoEl.play();

    // Store torch track
    _torchTrack = _stream.getVideoTracks()[0];

    // Show torch button if supported
    const torchBtn = opts.torchBtnId ? document.getElementById(opts.torchBtnId) : null;
    if(torchBtn){
      const caps = _torchTrack?.getCapabilities?.() || {};
      torchBtn.style.display = caps.torch ? 'flex' : 'none';
    }

    if(_statusEl) _statusEl.textContent = '📷 Scanning... aim at barcode';

    // Try native BarcodeDetector first (fast, zero overhead)
    if('BarcodeDetector' in window){
      _startNativeDetector();
    } else {
      // Load ZXing as fallback
      if(_statusEl) _statusEl.textContent = '⏳ Loading scanner...';
      _loadZXing(()=>{
        if(typeof window.ZXing !== 'undefined'){
          _startZXing();
        } else {
          // Both unavailable
          if(_statusEl) _statusEl.textContent = '⚠️ Camera open — type code below if auto-scan fails';
          const manualInp = opts.manualInputId ? document.getElementById(opts.manualInputId) : null;
          if(manualInp) setTimeout(()=>manualInp.focus(), 300);
        }
      });
    }

  } catch(err){
    _stopAll();
    const isDenied = err.name === 'NotAllowedError' || err.name === 'PermissionDeniedError';
    const isNotFound = err.name === 'NotFoundError';

    let msg = '❌ Camera error — type code below';
    if(isDenied){
      msg = '🔒 Camera blocked';
      // Show instructions popup
      _showPermissionHelp();
    } else if(isNotFound){
      msg = '📵 No camera found — type code below';
    }
    if(_statusEl) _statusEl.textContent = msg;

    const manualInp = opts.manualInputId ? document.getElementById(opts.manualInputId) : null;
    if(manualInp) setTimeout(()=>manualInp.focus(), 300);
  }
}

function _startNativeDetector(){
  const det = new BarcodeDetector({
    formats:['ean_13','ean_8','code_128','code_39','qr_code','upc_a','upc_e','itf','codabar']
  });
  _scanTimer = setInterval(async()=>{
    if(!_videoEl || _videoEl.readyState < 2) return;
    try{
      const results = await det.detect(_videoEl);
      if(results.length > 0) _onScanSuccess(results[0].rawValue);
    }catch(e){}
  }, 300);
}

function _startZXing(){
  try{
    const hints = new Map();
    const formats = [
      ZXing.BarcodeFormat.EAN_13, ZXing.BarcodeFormat.EAN_8,
      ZXing.BarcodeFormat.CODE_128, ZXing.BarcodeFormat.CODE_39,
      ZXing.BarcodeFormat.UPC_A, ZXing.BarcodeFormat.UPC_E,
      ZXing.BarcodeFormat.QR_CODE, ZXing.BarcodeFormat.ITF,
    ];
    hints.set(ZXing.DecodeHintType.POSSIBLE_FORMATS, formats);
    _zxingReader = new ZXing.MultiFormatReader();
    _zxingReader.setHints(hints);

    if(_statusEl) _statusEl.textContent = '📷 Scanning... aim at barcode';

    const canvas = document.createElement('canvas');
    const ctx = canvas.getContext('2d');

    _scanTimer = setInterval(()=>{
      if(!_videoEl || _videoEl.readyState < 2 || _videoEl.videoWidth === 0) return;
      try{
        canvas.width  = _videoEl.videoWidth;
        canvas.height = _videoEl.videoHeight;
        ctx.drawImage(_videoEl, 0, 0);
        const imgData = ctx.getImageData(0,0,canvas.width,canvas.height);
        const lum = ZXing.RGBLuminanceSource ?
          new ZXing.RGBLuminanceSource(imgData.data, canvas.width, canvas.height) :
          null;
        if(!lum) return;
        const bmp = new ZXing.BinaryBitmap(new ZXing.HybridBinarizer(lum));
        const result = _zxingReader.decode(bmp);
        if(result) _onScanSuccess(result.getText());
      }catch(e){
        // ZXing throws NotFoundException normally — ignore
      }
    }, 400);

  }catch(e){
    if(_statusEl) _statusEl.textContent = '📷 Camera open — type code below';
  }
}

function _onScanSuccess(code){
  if(!code || !code.trim()) return;
  _stopAll();
  if(_onResult) _onResult(code.trim());
}

/* ── Torch toggle ── */
function toggleTorch(){
  if(!_torchTrack) return;
  _torchOn = !_torchOn;
  try{
    _torchTrack.applyConstraints({ advanced:[{ torch: _torchOn }] });
  }catch(e){ _torchOn=!_torchOn; }
}

/* ── Camera permission help modal ── */
function _showPermissionHelp(){
  const existing = document.getElementById('sbp-cam-help');
  if(existing) existing.remove();

  const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent);
  const instructions = isIOS
    ? 'Safari mein Settings → Websites → Camera → Allow karein, phir wapas aayein.'
    : 'Chrome mein address bar ke paas 🔒 icon tap karein → Camera → Allow karein.';

  const div = document.createElement('div');
  div.id = 'sbp-cam-help';
  div.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.85);z-index:99999;display:flex;align-items:center;justify-content:center;padding:24px';
  div.innerHTML = `
    <div style="background:#13131C;border-radius:20px;padding:24px;max-width:320px;width:100%;text-align:center;border:1px solid #2A2A3A">
      <div style="font-size:44px;margin-bottom:12px">📷</div>
      <div style="font-family:'Outfit',sans-serif;font-size:17px;font-weight:800;color:#F0EFF8;margin-bottom:8px">Camera Permission Chahiye</div>
      <div style="font-size:13px;color:#8A8AA8;line-height:1.6;margin-bottom:20px">${instructions}</div>
      <div style="background:rgba(245,166,35,.1);border:1px solid rgba(245,166,35,.3);border-radius:12px;padding:12px;margin-bottom:16px;font-size:12px;color:#FF8A00;text-align:left">
        Ya fir neeche manually barcode type karein — kaam karega.
      </div>
      <button onclick="document.getElementById('sbp-cam-help').remove()" 
        style="width:100%;padding:13px;border-radius:12px;background:linear-gradient(135deg,#F5A623,#FF8A00);border:none;color:#0A0E1A;font-family:'Outfit',sans-serif;font-size:15px;font-weight:700;cursor:pointer">
        Samajh Gaya
      </button>
    </div>`;
  document.body.appendChild(div);
}

/* ── Hardware Bluetooth/USB scanner support ── */
// Barcode scanners type fast (< 50ms between chars) and press Enter
let _hwBuf = '', _hwTmr = null;
let _hwCallback = null; // set by each page

function setHardwareScanCallback(cb){
  _hwCallback = cb;
}

document.addEventListener('keydown', function(e){
  const active = document.activeElement;
  // If user is typing in an input, don't intercept
  // Exception: scan-manual and stock-scan-inp — those are for manual barcode entry
  const isScanInput = active && (
    active.id === 'scan-manual' ||
    active.id === 'stock-scan-inp' ||
    active.id === 'admin-scan-inp'
  );
  if(active && (active.tagName==='INPUT'||active.tagName==='TEXTAREA') && !isScanInput) return;
  if(e.ctrlKey||e.altKey||e.metaKey) return;

  if(e.key === 'Enter'){
    if(_hwBuf.length >= 3){
      const code = _hwBuf;
      _hwBuf = '';
      clearTimeout(_hwTmr);
      if(_hwCallback) _hwCallback(code);
    }
    _hwBuf = '';
  } else if(e.key.length === 1){
    _hwBuf += e.key;
    clearTimeout(_hwTmr);
    // Hardware scanners finish in < 100ms; if gap > 120ms it's human typing
    _hwTmr = setTimeout(()=>{ _hwBuf=''; }, 120);
  }
});

/* ── Product match helper (used by all three pages) ── */
// Matches scanned code against: product code, hsn_code, name
function matchProduct(products, code){
  const c = (code||'').toLowerCase().trim();
  if(!c) return null;
  return products.find(p =>
    (p.code        || '').toLowerCase() === c ||
    (p.hsn_code    || '').toLowerCase() === c ||
    (p.name        || '').toLowerCase() === c
  ) || null;
}

/* ── Expose public API ── */
global.SBPScanner = { open, close, toggleTorch, matchProduct, setHardwareScanCallback };

})(window);
