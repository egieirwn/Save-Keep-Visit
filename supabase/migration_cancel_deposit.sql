-- Apply after migration_penitipan_barang.sql.
-- Adds an auditable cancellation flow for active deposit transactions.

ALTER TABLE public.deposit_transactions
  ADD COLUMN IF NOT EXISTS cancellation_reason TEXT NOT NULL DEFAULT '';

ALTER TABLE public.deposit_transactions
  ADD COLUMN IF NOT EXISTS cancelled_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.deposit_transactions
  ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.rpc_cancel_deposit(
  p_transaction_id UUID,
  p_cancellation_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_transaction public.deposit_transactions%ROWTYPE;
  v_reason TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_staff() THEN
    RAISE EXCEPTION 'Akses ditolak: hanya petugas yang berwenang dapat membatalkan penitipan.';
  END IF;

  v_reason := NULLIF(BTRIM(p_cancellation_reason), '');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'Alasan pembatalan wajib diisi.';
  END IF;
  IF CHAR_LENGTH(v_reason) > 500 THEN
    RAISE EXCEPTION 'Alasan pembatalan maksimal 500 karakter.';
  END IF;

  SELECT *
  INTO v_transaction
  FROM public.deposit_transactions
  WHERE id = p_transaction_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaksi penitipan tidak ditemukan.';
  END IF;
  IF v_transaction.status <> 'stored' THEN
    RAISE EXCEPTION 'Hanya penitipan yang masih aktif yang dapat dibatalkan.';
  END IF;

  UPDATE public.deposit_transactions
  SET status = 'cancelled',
      cancellation_reason = v_reason,
      cancelled_by = auth.uid(),
      cancelled_at = NOW()
  WHERE id = p_transaction_id;

  WITH location_usage AS (
    SELECT storage_location_id, COUNT(*)::INTEGER AS released_count
    FROM public.deposit_items
    WHERE transaction_id = p_transaction_id
      AND storage_location_id IS NOT NULL
    GROUP BY storage_location_id
  )
  UPDATE public.storage_locations AS location
  SET active_count = GREATEST(0, location.active_count - location_usage.released_count),
      status = CASE
        WHEN NOT location.is_active THEN 'inactive'
        WHEN GREATEST(0, location.active_count - location_usage.released_count) < location.capacity THEN 'available'
        ELSE 'full'
      END,
      updated_at = NOW()
  FROM location_usage
  WHERE location.id = location_usage.storage_location_id;

  INSERT INTO public.transaction_logs (
    transaction_id, action, old_status, new_status, notes, performed_by
  ) VALUES (
    p_transaction_id,
    'deposit_cancelled',
    v_transaction.status,
    'cancelled',
    v_reason,
    auth.uid()
  );

  RETURN jsonb_build_object(
    'success', TRUE,
    'transaction_id', p_transaction_id,
    'status', 'cancelled'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_cancel_deposit(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_deposit(UUID, TEXT) TO authenticated;
