/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Shop Images Upload Library v1.0
   ShopBill Pro is a product of TradeCrest Technologies Pvt. Ltd.

   Wraps Supabase Storage for shop gallery uploads.
   Folder structure: shop-gallery/{shop_id}/{timestamp}-{slug}.{ext}

   Public API:
     SBPImages.upload(shopId, file, opts) → { ok, url, path }
     SBPImages.delete(path)               → { ok }
     SBPImages.publicURL(path)            → string
     SBPImages.compress(file, maxBytes)   → File (client-side resize)

   Requires: window._sb (Supabase JS client).
══════════════════════════════════════════════════════════════════ */

(function (global) {
  'use strict';

  const BUCKET = 'shop-gallery';
  const MAX_BYTES = 3 * 1024 * 1024;          // 3 MB
  const MAX_DIMENSION = 1600;                  // 1600px max width/height
  const ALLOWED_TYPES = ['image/jpeg','image/jpg','image/png','image/webp','image/gif'];

  function _sb() {
    if (!global._sb) { console.warn('[SBPImages] _sb not initialized'); return null; }
    return global._sb;
  }

  function _slug(str) {
    return String(str || 'img')
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 40);
  }

  // ── Client-side compression to keep uploads under 3MB ─────────────
  // Resizes image to fit within MAX_DIMENSION and re-encodes as JPEG
  // at progressively lower quality until under maxBytes.
  async function compress(file, maxBytes) {
    maxBytes = maxBytes || MAX_BYTES;

    if (!file || !file.type.startsWith('image/')) {
      throw new Error('Not an image file');
    }

    // Small enough already — return as-is unless it's a GIF (preserve animation)
    if (file.size <= maxBytes && file.type === 'image/gif') {
      return file;
    }

    return new Promise((resolve, reject) => {
      const img = new Image();
      const url = URL.createObjectURL(file);

      img.onload = function () {
        URL.revokeObjectURL(url);

        // Calculate target dimensions
        let w = img.width;
        let h = img.height;
        if (w > MAX_DIMENSION || h > MAX_DIMENSION) {
          if (w > h) { h = Math.round(h * MAX_DIMENSION / w); w = MAX_DIMENSION; }
          else       { w = Math.round(w * MAX_DIMENSION / h); h = MAX_DIMENSION; }
        }

        const canvas = document.createElement('canvas');
        canvas.width = w; canvas.height = h;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(img, 0, 0, w, h);

        // Try progressively lower quality
        let quality = 0.85;
        function tryQuality() {
          canvas.toBlob(function (blob) {
            if (!blob) { reject(new Error('Compression failed')); return; }
            if (blob.size <= maxBytes || quality <= 0.4) {
              const ext = blob.type === 'image/jpeg' ? 'jpg' : 'webp';
              const newName = (file.name || 'image').replace(/\.[^.]+$/, '') + '.' + ext;
              resolve(new File([blob], newName, { type: blob.type, lastModified: Date.now() }));
            } else {
              quality -= 0.1;
              tryQuality();
            }
          }, 'image/jpeg', quality);
        }
        tryQuality();
      };

      img.onerror = function () {
        URL.revokeObjectURL(url);
        reject(new Error('Could not load image for compression'));
      };

      img.src = url;
    });
  }

  // ── Upload a file to shop-gallery/{shop_id}/{timestamp}-{slug}.{ext} ──
  async function upload(shopId, file, opts) {
    opts = opts || {};
    if (!shopId)             return { ok: false, error: 'no_shop_id' };
    if (!file)               return { ok: false, error: 'no_file' };
    if (!file.type.startsWith('image/')) {
      return { ok: false, error: 'not_an_image' };
    }
    if (ALLOWED_TYPES.indexOf(file.type) < 0) {
      return { ok: false, error: 'unsupported_format' };
    }

    const sb = _sb();
    if (!sb) return { ok: false, error: 'no_sb' };

    // Compress if needed (skips GIFs)
    let toUpload = file;
    try {
      if (file.size > MAX_BYTES || (file.type !== 'image/gif' && (opts.compress !== false))) {
        toUpload = await compress(file, MAX_BYTES);
      }
    } catch (e) {
      console.warn('[SBPImages] compression failed, uploading original:', e);
      if (file.size > MAX_BYTES) {
        return { ok: false, error: 'file_too_large_after_compression' };
      }
    }

    // Build object path: {shop_id}/{timestamp}-{slug}.{ext}
    const ts = Date.now();
    const ext = toUpload.name.split('.').pop().toLowerCase() || 'jpg';
    const base = _slug((toUpload.name || 'img').replace(/\.[^.]+$/, '')) || 'img';
    const objectPath = shopId + '/' + ts + '-' + base + '.' + ext;

    try {
      const { data, error } = await sb.storage
        .from(BUCKET)
        .upload(objectPath, toUpload, {
          cacheControl: '31536000',  // 1 year — images don't change
          upsert: false,
          contentType: toUpload.type
        });

      if (error) return { ok: false, error: error.message || String(error) };

      const url = publicURL(data.path);
      return {
        ok: true,
        path: data.path,
        url: url,
        size: toUpload.size,
        compressed_from: file.size !== toUpload.size ? file.size : null
      };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }

  // ── Delete an image by its storage path ──────────────────────────
  async function remove(path) {
    if (!path) return { ok: false, error: 'no_path' };
    const sb = _sb();
    if (!sb) return { ok: false, error: 'no_sb' };

    try {
      const { error } = await sb.storage.from(BUCKET).remove([path]);
      if (error) return { ok: false, error: error.message };
      return { ok: true };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }

  // ── Construct public URL for a storage path ──────────────────────
  function publicURL(path) {
    const sb = _sb();
    if (!sb || !path) return '';
    const { data } = sb.storage.from(BUCKET).getPublicUrl(path);
    return data.publicUrl;
  }

  // ── Extract storage path from a public URL (for delete from URL) ──
  function pathFromURL(url) {
    if (!url) return null;
    const marker = '/' + BUCKET + '/';
    const idx = url.indexOf(marker);
    if (idx < 0) return null;
    return url.substring(idx + marker.length);
  }

  // ── Public API ───────────────────────────────────────────────────
  global.SBPImages = {
    upload:      upload,
    delete:      remove,
    remove:      remove,
    publicURL:   publicURL,
    pathFromURL: pathFromURL,
    compress:    compress,
    MAX_BYTES:   MAX_BYTES,
    BUCKET:      BUCKET
  };

})(typeof window !== 'undefined' ? window : this);
