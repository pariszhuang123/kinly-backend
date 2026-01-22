-- Extend allowed channels for share_events to support onboarding dismissals
ALTER TABLE public.share_events
  DROP CONSTRAINT IF EXISTS share_channel_valid;

ALTER TABLE public.share_events
  ADD CONSTRAINT share_channel_valid CHECK (
    channel IN (
      'system_share',
      'qr_code',
      'copy_link',
      'other',
      'onboarding_dismiss'
    )
  );
