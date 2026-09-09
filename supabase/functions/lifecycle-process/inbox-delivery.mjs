// Validate a receipt from the delivery-only, shared-quota transaction. This
// validator cannot approve, send, repair a receipt, or fall back to direct writes.
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const timestamp = value => typeof value === 'string' && Number.isFinite(Date.parse(value));

export async function validateInboxDeliveryReceipt(value, row, recipient) {
  if (!value || typeof value !== 'object' || !['sent','already_sent'].includes(value.kind) ||
      value.id !== row.id || value.provider_id !== row.provider_id ||
      typeof row.approved_by !== 'string' || !row.approved_by || value.approved_by !== row.approved_by ||
      !timestamp(row.approved_at) || !timestamp(value.approved_at) ||
      Date.parse(value.approved_at) !== Date.parse(row.approved_at) ||
      !timestamp(value.sent_at) || Date.parse(value.sent_at) < Date.parse(value.approved_at) ||
      value.status !== 'sent' || !uuid(value.receipt_id) || !uuid(value.notification_id) ||
      typeof recipient !== 'string' || !recipient || value.recipient_id !== recipient ||
      typeof row.content?.body !== 'string' || !row.content.body.trim() ||
      typeof value.body_sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(value.body_sha256) ||
      (value.kind === 'sent' && (typeof value.title !== 'string' || !value.title.trim() ||
        typeof value.preview !== 'string' || !value.preview.trim()))) return null;
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(row.content.body));
  const expected = Array.from(new Uint8Array(bytes), byte => byte.toString(16).padStart(2,'0')).join('');
  if (value.body_sha256 !== expected) return null;
  return {
    kind:value.kind, receiptId:value.receipt_id, notificationId:value.notification_id,
    recipientId:value.recipient_id, sentAt:value.sent_at,
    title:value.kind === 'sent' ? value.title : null,
    preview:value.kind === 'sent' ? value.preview : null,
  };
}
