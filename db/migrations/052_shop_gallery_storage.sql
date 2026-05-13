-- ════════════════════════════════════════════════════════════════════
-- 052_shop_gallery_storage.sql
--
-- Creates a public Supabase Storage bucket for shop gallery images,
-- with RLS policies that allow:
--   • Anyone (anon) to read images   — public website needs this
--   • Shop owners to upload to {shop_id}/ folder under their shop
--   • Shop owners to delete their own images
--
-- File constraints:
--   • Max 3MB per image (client-side compression recommended)
--   • Allowed formats: JPEG, PNG, WebP, GIF
--   • Folder structure: shop-gallery/{shop_id}/{timestamp}-{filename}
--
-- IDEMPOTENT — safe to re-run. Uses INSERT … ON CONFLICT DO UPDATE.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Create/update bucket ─────────────────────────────────────────
INSERT INTO storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
VALUES (
  'shop-gallery',
  'shop-gallery',
  true,
  3145728,  -- 3 MB
  ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/gif']
)
ON CONFLICT (id) DO UPDATE SET
  public             = EXCLUDED.public,
  file_size_limit    = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ── 2. RLS policies on storage.objects ──────────────────────────────

-- 2a. Public SELECT — anyone can view images (needed for /s/{slug} page)
DROP POLICY IF EXISTS "shop_gallery_public_read" ON storage.objects;
CREATE POLICY "shop_gallery_public_read"
ON storage.objects
FOR SELECT
USING (bucket_id = 'shop-gallery');

-- 2b. Authenticated INSERT — only shop owners can upload to their folder
-- Folder pattern: shops/{shop_id}/{filename} — first path segment is shop_id
DROP POLICY IF EXISTS "shop_gallery_owner_upload" ON storage.objects;
CREATE POLICY "shop_gallery_owner_upload"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'shop-gallery'
  AND EXISTS (
    SELECT 1
    FROM shops
    WHERE shops.id::text = split_part(name, '/', 1)
      AND shops.owner_id = auth.uid()
  )
);

-- 2c. Authenticated DELETE — only shop owners can delete their own images
DROP POLICY IF EXISTS "shop_gallery_owner_delete" ON storage.objects;
CREATE POLICY "shop_gallery_owner_delete"
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'shop-gallery'
  AND EXISTS (
    SELECT 1
    FROM shops
    WHERE shops.id::text = split_part(name, '/', 1)
      AND shops.owner_id = auth.uid()
  )
);

-- 2d. Authenticated UPDATE — only shop owners can update their image metadata
DROP POLICY IF EXISTS "shop_gallery_owner_update" ON storage.objects;
CREATE POLICY "shop_gallery_owner_update"
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'shop-gallery'
  AND EXISTS (
    SELECT 1
    FROM shops
    WHERE shops.id::text = split_part(name, '/', 1)
      AND shops.owner_id = auth.uid()
  )
);

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- Verify after deploy:
--
--   -- Check bucket exists
--   SELECT id, public, file_size_limit, allowed_mime_types
--   FROM storage.buckets WHERE id = 'shop-gallery';
--
--   -- Check policies are in place
--   SELECT polname, polcmd
--   FROM pg_policy
--   WHERE polrelid = 'storage.objects'::regclass
--     AND polname LIKE 'shop_gallery%';
--
-- Should return 4 policies: public_read, owner_upload, owner_delete, owner_update.
-- ════════════════════════════════════════════════════════════════════
