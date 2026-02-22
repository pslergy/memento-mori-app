/**
 * Adaptive friction: anti–mass-registration layer.
 * No device fingerprint, no MAC/IMEI, no "1 per IP", no mandatory email verification.
 * Soft IP limits + burst protection + email attempt limit + trust score + optional delay/PoW.
 */

const crypto = require('crypto');

const WINDOW_60M = 60 * 60 * 1000;
const WINDOW_24H = 24 * 60 * 60 * 1000;
const WINDOW_2M = 2 * 60 * 1000;
const MAX_PER_60M = 5;
const MAX_PER_24H = 15;
const BURST_COUNT = 3;
const BURST_COOLDOWN_MS = 20 * 60 * 1000;
const RATE_COOLDOWN_MS = 60 * 60 * 1000;
const MAX_EMAIL_ATTEMPTS_24H = 5;
const TRUST_START = 100;
const TRUST_DECREMENT = 10;
const TRUST_RECOVERY_PER_HOUR = 10;
const TRUST_FRICTION_THRESHOLD = 40;
const FRICTION_60_PCT = 0.6; // 60% of limit
const FRICTION_DELAY_MS = 30 * 1000;
const POW_LEADING_ZEROS = 4; // hex chars => SHA256 must start with '0000'

function getClientIp(req) {
  const forwarded = req.headers && req.headers['x-forwarded-for'];
  if (forwarded) {
    const first = typeof forwarded === 'string' ? forwarded.split(',')[0] : forwarded[0];
    return (first && first.trim()) || req.socket?.remoteAddress || req.ip || 'unknown';
  }
  return req.socket?.remoteAddress || req.ip || 'unknown';
}

// --- In-memory state (per process) ---
const ipRegs60 = new Map();   // ip -> number[] (timestamps of successful regs in last 60m)
const ipRegs24 = new Map();   // ip -> number[] (last 24h)
const ipBurst2m = new Map();  // ip -> number[] (attempt timestamps last 2m)
const ipCooldownUntil = new Map(); // ip -> number (timestamp)
const ipTrustScore = new Map();   // ip -> { score, lastUpdated }
const emailAttempts24 = new Map(); // email -> number[] (attempt timestamps last 24h)

function prune(arr, windowMs) {
  const cutoff = Date.now() - windowMs;
  return arr.filter((t) => t > cutoff);
}

function ensureTrustScore(ip) {
  const now = Date.now();
  let entry = ipTrustScore.get(ip);
  if (!entry) {
    entry = { score: TRUST_START, lastUpdated: now };
    ipTrustScore.set(ip, entry);
    return entry;
  }
  const hoursElapsed = (now - entry.lastUpdated) / (60 * 60 * 1000);
  if (hoursElapsed >= 1) {
    const recovery = Math.floor(hoursElapsed) * TRUST_RECOVERY_PER_HOUR;
    entry.score = Math.min(TRUST_START, entry.score + recovery);
    entry.lastUpdated = now;
  }
  return entry;
}

function verifyPow(email, nonce) {
  if (!email || nonce == null || nonce === '') return false;
  const hash = crypto.createHash('sha256').update(String(email) + String(nonce)).digest('hex');
  return hash.startsWith('0'.repeat(POW_LEADING_ZEROS));
}

function cleanupOldEntries() {
  const now = Date.now();
  const cutoff24 = now - WINDOW_24H;
  for (const [ip, arr] of ipRegs60.entries()) {
    const pruned = arr.filter((t) => t > now - WINDOW_60M);
    if (pruned.length === 0) ipRegs60.delete(ip);
    else ipRegs60.set(ip, pruned);
  }
  for (const [ip, arr] of ipRegs24.entries()) {
    const pruned = arr.filter((t) => t > cutoff24);
    if (pruned.length === 0) ipRegs24.delete(ip);
    else ipRegs24.set(ip, pruned);
  }
  for (const [ip, arr] of ipBurst2m.entries()) {
    const pruned = arr.filter((t) => t > now - WINDOW_2M);
    if (pruned.length === 0) ipBurst2m.delete(ip);
    else ipBurst2m.set(ip, pruned);
  }
  for (const [ip, until] of ipCooldownUntil.entries()) {
    if (until <= now) ipCooldownUntil.delete(ip);
  }
  for (const [email, arr] of emailAttempts24.entries()) {
    const pruned = arr.filter((t) => t > cutoff24);
    if (pruned.length === 0) emailAttempts24.delete(email);
    else emailAttempts24.set(email, pruned);
  }
}

setInterval(cleanupOldEntries, 10 * 60 * 1000);

/**
 * Call after successful register or legalize to record the event and update trust score.
 */
function recordSuccess(meta) {
  if (!meta || !meta.ip) return;
  const now = Date.now();
  const { ip, email } = meta;

  if (!ipRegs60.has(ip)) ipRegs60.set(ip, []);
  ipRegs60.get(ip).push(now);
  if (!ipRegs24.has(ip)) ipRegs24.set(ip, []);
  ipRegs24.get(ip).push(now);

  const entry = ensureTrustScore(ip);
  entry.score = Math.max(0, entry.score - TRUST_DECREMENT);
}

/**
 * Middleware: run before register and legalize. Sets req.registrationGuardMeta = { ip, email } on pass.
 */
function registrationAbuseGuard(req, res, next) {
  const ip = getClientIp(req);
  const email = (req.body && req.body.email) ? String(req.body.email).toLowerCase().trim() : null;
  const now = Date.now();

  // --- Cooldown check ---
  const cooldownUntil = ipCooldownUntil.get(ip);
  if (cooldownUntil && cooldownUntil > now) {
    const retryAfter = Math.ceil((cooldownUntil - now) / 1000);
    res.setHeader('Retry-After', String(retryAfter));
    console.log('[REG] cooldown_triggered ip=' + ip + ' retryAfter=' + retryAfter);
    return res.status(429).json({ message: 'Too many attempts. Please try again later.', retryAfterSeconds: retryAfter });
  }

  // --- Burst: 3+ attempts (requests) in 2 min ---
  let burstArr = ipBurst2m.get(ip) || [];
  burstArr = prune(burstArr, WINDOW_2M);
  if (burstArr.length >= BURST_COUNT) {
    ipCooldownUntil.set(ip, now + BURST_COOLDOWN_MS);
    const retryAfter = Math.ceil(BURST_COOLDOWN_MS / 1000);
    res.setHeader('Retry-After', String(retryAfter));
    console.log('[REG] burst_detected ip=' + ip);
    return res.status(429).json({ message: 'Too many attempts from your network. Please try again later.', retryAfterSeconds: retryAfter });
  }
  burstArr.push(now);
  ipBurst2m.set(ip, burstArr);

  // --- IP rate: 5/60m, 15/24h ---
  let regs60 = ipRegs60.get(ip) || [];
  let regs24 = ipRegs24.get(ip) || [];
  regs60 = prune(regs60, WINDOW_60M);
  regs24 = prune(regs24, WINDOW_24H);
  ipRegs60.set(ip, regs60);
  ipRegs24.set(ip, regs24);
  if (regs60.length >= MAX_PER_60M || regs24.length >= MAX_PER_24H) {
    ipCooldownUntil.set(ip, now + RATE_COOLDOWN_MS);
    const retryAfter = Math.ceil(RATE_COOLDOWN_MS / 1000);
    res.setHeader('Retry-After', String(retryAfter));
    console.log('[REG] cooldown_triggered ip=' + ip + ' (rate limit)');
    return res.status(429).json({ message: 'Registration limit reached for your network. Try again later.', retryAfterSeconds: retryAfter });
  }

  // --- Email attempt limit: 5/24h ---
  if (email) {
    let attempts = emailAttempts24.get(email) || [];
    attempts = prune(attempts, WINDOW_24H);
    emailAttempts24.set(email, attempts);
    if (attempts.length >= MAX_EMAIL_ATTEMPTS_24H) {
      console.log('[REG] email_attempt_limit email=' + (email.substring(0, 6) + '...'));
      return res.status(429).json({ message: 'Too many attempts for this email. Try again tomorrow.' });
    }
  }

  // --- Trust score (recover over time) ---
  const trustEntry = ensureTrustScore(ip);
  const count60 = regs60.length;
  const count24 = regs24.length;
  const frictionByLimit = count60 >= Math.ceil(MAX_PER_60M * FRICTION_60_PCT) || count24 >= Math.ceil(MAX_PER_24H * FRICTION_60_PCT);
  const frictionByTrust = trustEntry.score < TRUST_FRICTION_THRESHOLD;
  const needFriction = frictionByLimit || frictionByTrust;

  console.log('[REG] IP trustScore ip=' + ip + ' score=' + trustEntry.score);

  function recordAttemptAndProceed() {
    if (email) {
      if (!emailAttempts24.has(email)) emailAttempts24.set(email, []);
      emailAttempts24.get(email).push(Date.now());
    }
    req.registrationGuardMeta = { ip, email };
    next();
  }

  if (needFriction) {
    console.log('[REG] adaptive_friction_enabled ip=' + ip);

    const nonce = req.body && req.body.registrationNonce;
    if (nonce != null && nonce !== '') {
      if (!verifyPow(email || '', nonce)) {
        return res.status(400).json({
          message: 'Proof-of-work invalid or missing. Retry with a valid nonce.',
          frictionRequired: true,
          powTarget: 'SHA256(email+nonce) must start with ' + POW_LEADING_ZEROS + ' zero hex chars',
        });
      }
      // PoW valid → proceed
      recordAttemptAndProceed();
    } else {
      // No nonce: apply 30s delay then proceed
      return setTimeout(recordAttemptAndProceed, FRICTION_DELAY_MS);
    }
  } else {
    recordAttemptAndProceed();
  }
}

module.exports = {
  registrationAbuseGuard,
  recordSuccess,
};
