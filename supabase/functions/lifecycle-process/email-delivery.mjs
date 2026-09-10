// Delivery-only validators: no approval, source mutation, or provider request.
// A ready receipt authorizes exactly its sealed bytes and one durable attempt.
const uuid = v => typeof v === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(v);
const providerId = v => typeof v === 'string' && /^[A-Za-z0-9_-]{1,200}$/.test(v);
const instant = v => {
  if (typeof v !== 'string') return null;
  const m = v.match(/^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$/);
  if (!m || !Number.isFinite(Date.parse(m[1] + m[3]))) return null;
  return Date.parse(m[1] + m[3]) + ':' + (m[2] ?? '').padEnd(6,'0');
};
const sameTime = (a,b) => instant(a) !== null && instant(a) === instant(b);
const same = (a,b) => {
  if (a === b) return true;
  if (!a || !b || typeof a !== 'object' || typeof b !== 'object') return false;
  if (Array.isArray(a) || Array.isArray(b)) return Array.isArray(a) && Array.isArray(b) &&
    a.length === b.length && a.every((v,i)=>same(v,b[i]));
  return Object.keys(a).length === Object.keys(b).length &&
    Object.keys(a).every(k=>Object.hasOwn(b,k) && same(a[k],b[k]));
};

export async function validateEmailDispatch(value,row,envelope) {
  if (!value || !['ready','held','deferred','already_accepted'].includes(value.kind) ||
    value.message_id !== row.id || value.provider_id !== row.provider_id ||
    !row.approved_by || value.actor_id !== row.approved_by ||
    !sameTime(value.approved_at,row.approved_at) || !same(value.approved_content,row.content) ||
    !uuid(value.dispatch_id) || !uuid(value.attempt_id) || !uuid(value.quota_claim_id) ||
    !Number.isSafeInteger(value.attempt_count) || value.attempt_count < 1 ||
    !instant(value.created_at) || Date.parse(value.created_at) < Date.parse(row.approved_at) ||
    typeof value.branding_footer !== 'boolean') return null;
  if (value.kind === 'already_accepted') {
    return value.state === 'accepted' && uuid(value.result_id) && providerId(value.provider_message_id) &&
      instant(value.accepted_at) && Date.parse(value.accepted_at) >= Date.parse(value.created_at) ? value : null;
  }
  if (value.kind === 'held') {
    return ['dispatching','ambiguous','rejected'].includes(value.state) ? value : null;
  }
  if (value.kind === 'deferred') {
    return value.state === 'retry_wait' && instant(value.retry_after) ? value : null;
  }
  if (value.state !== 'dispatching' || value.retry_after !== null || value.result_id !== null ||
    value.provider_message_id !== null || value.accepted_at !== null ||
    Date.now() - Date.parse(value.created_at) >= 23 * 60 * 60 * 1000 ||
    Date.parse(value.created_at) > Date.now() + 60_000 ||
    typeof value.idempotency_key !== 'string' || !value.idempotency_key.startsWith('sporv/email/') ||
    !uuid(value.idempotency_key.slice('sporv/email/'.length)) ||
    typeof value.wire_body !== 'string' || new TextEncoder().encode(value.wire_body).length > 100_000 ||
    typeof value.wire_sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(value.wire_sha256) ||
    typeof row.content?.body !== 'string' || !row.content.body.trim() || !envelope.unsubscribe) return null;
  const bytes = await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value.wire_body));
  const digest = Array.from(new Uint8Array(bytes),b=>b.toString(16).padStart(2,'0')).join('');
  if (digest !== value.wire_sha256) return null;
  let wire;
  try { wire = JSON.parse(value.wire_body); } catch { return null; }
  const expected = {
    from:envelope.from, reply_to:envelope.replyTo, to:[envelope.recipient], subject:envelope.subject,
    text:row.content.body + (value.branding_footer ? '\n\nSent via Sporv' : '') +
      '\n\nUnsubscribe from these messages: ' + envelope.unsubscribe,
    headers:{'X-Sporv-Message-Id':row.id,'List-Unsubscribe':'<' + envelope.unsubscribe + '>',
      'List-Unsubscribe-Post':'List-Unsubscribe=One-Click'},
  };
  return same(wire,expected) ? value : null;
}

export function validateEmailResult(value,dispatch,outcome,acceptedId) {
  return !!value && ['recorded','already_recorded'].includes(value.kind) &&
    uuid(value.result_id) && value.dispatch_id === dispatch.dispatch_id &&
    value.attempt_id === dispatch.attempt_id && value.outcome === outcome &&
    value.provider_message_id === acceptedId && instant(value.created_at) !== null &&
    Date.parse(value.created_at) >= Date.parse(dispatch.created_at);
}
