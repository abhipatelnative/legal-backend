import { Router } from "express";
import { createClient, type User } from "@supabase/supabase-js";
import { randomInt, randomUUID, createHash, timingSafeEqual } from "crypto";

import { SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL } from "./config/credentials";
import { sendEmailsToAddresses } from "./email-service";

const router = Router();

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const supabaseService = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

type AllowedMethod = "totp" | "email";
type ChallengeMethod = AllowedMethod;
type DecodedClaims = {
  aal?: string | null;
  session_id?: string | null;
};

type RequestContext = {
  accessToken: string;
  aal: string | null;
  sessionId: string | null;
  user: User;
};

type StatusPayload = {
  userId: string;
  currentAal: string | null;
  allowedMethods: AllowedMethod[];
  enrolledMethods: AllowedMethod[];
  availableChallengeMethods: ChallengeMethod[];
  isRequiredForUser: boolean;
  mfaRequired: boolean;
  mfaSetupRequired: boolean;
  hasRecoveryCodes: boolean;
  recoveryCodesGeneratedAt: string | null;
  primaryMethod: AllowedMethod | null;
  emailEnabled: boolean;
  totpEnabled: boolean;
  recoveryRequired: boolean;
  canManageTarget: boolean;
  mfaOptOut: boolean;
};

const DEFAULT_EMAIL_CHALLENGE_EXPIRY_MINUTES = 10;
const EMAIL_CHALLENGE_RESEND_SECONDS = 30;
const EMAIL_CHALLENGE_LOCK_MINUTES = 10;
const RECOVERY_CODE_COUNT = 8;
const HASH_NAMESPACE = "legalprime-2fa";

function normalizeAllowedMethods(value: unknown): AllowedMethod[] {
  if (!Array.isArray(value)) {
    return ["totp", "email"];
  }

  return Array.from(
    new Set(
      value
        .map((item) => String(item).toLowerCase())
        .filter((item): item is AllowedMethod => item === "totp" || item === "email")
    )
  );
}

function decodeClaims(accessToken: string): DecodedClaims {
  try {
    const [, payload] = accessToken.split(".");
    const decoded = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as DecodedClaims;
    return decoded;
  } catch {
    return {};
  }
}

function getBearerToken(authorizationHeader?: string): string | null {
  if (!authorizationHeader) {
    return null;
  }

  const [scheme, token] = authorizationHeader.split(" ");
  if (!scheme || scheme.toLowerCase() !== "bearer" || !token) {
    return null;
  }

  return token.trim();
}

function hashValue(...parts: string[]): string {
  const hash = createHash("sha256");
  hash.update(HASH_NAMESPACE);
  parts.forEach((part) => hash.update(`:${part}`));
  return hash.digest("hex");
}

function safeHashEquals(left: string, right: string): boolean {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);

  if (leftBuffer.length !== rightBuffer.length) {
    return false;
  }

  return timingSafeEqual(leftBuffer, rightBuffer);
}

function generateEmailCode(): string {
  return String(randomInt(0, 1_000_000)).padStart(6, "0");
}

function formatRecoveryCode(raw: string): string {
  const compact = raw.replace(/[^A-Z0-9]/gi, "").toUpperCase();
  return `${compact.slice(0, 4)}-${compact.slice(4, 8)}-${compact.slice(8, 12)}`;
}

function generateRecoveryCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let code = "";

  for (let index = 0; index < 12; index += 1) {
    code += alphabet[randomInt(0, alphabet.length)];
  }

  return formatRecoveryCode(code);
}

async function logSecurityEvent(
  action: string,
  userId: string | null,
  actorUserId: string | null,
  metadata: Record<string, unknown> = {}
): Promise<void> {
  const { error } = await supabaseService.from("security_audit_log").insert({
    action,
    user_id: userId,
    actor_user_id: actorUserId,
    metadata,
  });

  if (error) {
    console.error("[2FA] Failed to write security audit log:", error.message);
  }
}

async function getRequestContext(authorizationHeader?: string): Promise<RequestContext | null> {
  const accessToken = getBearerToken(authorizationHeader);
  if (!accessToken) {
    return null;
  }

  const { data, error } = await supabase.auth.getUser(accessToken);
  if (error || !data.user) {
    return null;
  }

  const claims = decodeClaims(accessToken);

  return {
    accessToken,
    aal: typeof claims.aal === "string" ? claims.aal : null,
    sessionId: typeof claims.session_id === "string" ? claims.session_id : null,
    user: data.user,
  };
}

async function getActiveRoleIds(userId: string): Promise<string[]> {
  const { data, error } = await supabaseService
    .from("user_roles")
    .select("role_id")
    .eq("user_id", userId)
    .eq("is_active", true)
    .eq("is_deleted", false);

  if (error) {
    console.error("[2FA] Failed to load user roles:", error.message);
    return [];
  }

  return (data || [])
    .map((row) => row.role_id)
    .filter((roleId): roleId is string => typeof roleId === "string");
}

async function canManageOtherUsers(userId: string): Promise<boolean> {
  const { data, error } = await supabaseService
    .from("user_roles")
    .select("roles(name)")
    .eq("user_id", userId)
    .eq("is_active", true)
    .eq("is_deleted", false);

  if (error) {
    console.error("[2FA] Failed to load role names:", error.message);
    return false;
  }

  const roleNames = (data || [])
    .map((entry) => {
      const relation = entry.roles as { name?: string } | { name?: string }[] | null;
      if (Array.isArray(relation)) {
        return relation[0]?.name;
      }
      return relation?.name;
    })
    .filter((name): name is string => typeof name === "string");

  return roleNames.some((name) => name === "Admin" || name === "HR Manager");
}

async function getCompanyPolicy(userId: string): Promise<{
  allowedMethods: AllowedMethod[];
  enforceAll: boolean;
  enforceRoleIds: string[];
  isRequiredForUser: boolean;
  mfaOptOut: boolean;
}> {
  const [settingsResult, optOutResult] = await Promise.all([
    supabaseService
      .from("company_settings")
      .select("enforce_2fa_all, enforce_2fa_role_ids, allowed_2fa_methods")
      .eq("is_deleted", false)
      .maybeSingle(),
    supabaseService
      .from("user_two_factor_preferences")
      .select("mfa_opt_out")
      .eq("user_id", userId)
      .maybeSingle(),
  ]);

  if (settingsResult.error) {
    console.error("[2FA] Failed to load company policy:", settingsResult.error.message);
  }
  if (optOutResult.error) {
    console.error("[2FA] Failed to load user opt-out flag:", optOutResult.error.message);
  }

  const data = settingsResult.data;
  const allowedMethods = normalizeAllowedMethods(data?.allowed_2fa_methods);
  const enforceAll = Boolean(data?.enforce_2fa_all);
  const enforceRoleIds = Array.isArray(data?.enforce_2fa_role_ids)
    ? data!.enforce_2fa_role_ids.filter((roleId): roleId is string => typeof roleId === "string")
    : [];

  const mfaOptOut = Boolean(optOutResult.data?.mfa_opt_out);
  const activeRoleIds = await getActiveRoleIds(userId);
  const policyRequires = enforceAll || activeRoleIds.some((roleId) => enforceRoleIds.includes(roleId));
  const isRequiredForUser = policyRequires && !mfaOptOut;

  return {
    allowedMethods,
    enforceAll,
    enforceRoleIds,
    isRequiredForUser,
    mfaOptOut,
  };
}

async function getEmailOtpExpiryMinutes(): Promise<number> {
  const { data, error } = await supabaseService
    .from("company_settings")
    .select("email_otp_expiry_minutes")
    .eq("is_deleted", false)
    .maybeSingle();

  if (error) {
    console.error("[2FA] Failed to load email OTP expiry setting:", error.message);
  }

  const value = Number(data?.email_otp_expiry_minutes);
  return value > 0 ? value : DEFAULT_EMAIL_CHALLENGE_EXPIRY_MINUTES;
}

async function syncTotpPreference(userId: string, totpEnabled: boolean): Promise<void> {
  const row: Record<string, unknown> = {
    user_id: userId,
    totp_enabled: totpEnabled,
    updated_at: new Date().toISOString(),
  };
  if (totpEnabled) {
    row.mfa_opt_out = false;
  }
  const { error } = await supabaseService
    .from("user_two_factor_preferences")
    .upsert(row, { onConflict: "user_id" });

  if (error) {
    console.error("[2FA] Failed to sync TOTP preference:", error.message);
  }
}

async function getTwoFactorStatus(
  requester: RequestContext,
  targetUserId?: string
): Promise<StatusPayload | null> {
  const effectiveUserId = targetUserId || requester.user.id;
  const isSelf = effectiveUserId === requester.user.id;
  const canManageTarget = isSelf || (await canManageOtherUsers(requester.user.id));

  if (!canManageTarget) {
    return null;
  }

  const policy = await getCompanyPolicy(effectiveUserId);

  const { data: preferences, error: preferencesError } = await supabaseService
    .from("user_two_factor_preferences")
    .select("primary_method, totp_enabled, email_enabled, recovery_codes_generated_at")
    .eq("user_id", effectiveUserId)
    .maybeSingle();

  if (preferencesError) {
    console.error("[2FA] Failed to load 2FA preferences:", preferencesError.message);
  }

  const { data: factorData, error: factorsError } = await supabaseService.auth.admin.mfa.listFactors({
    userId: effectiveUserId,
  });

  if (factorsError) {
    console.error("[2FA] Failed to list TOTP factors:", factorsError.message);
  }

  const verifiedTotpFactors = (factorData?.factors || []).filter(
    (factor) => factor.factor_type === "totp" && factor.status === "verified"
  );
  const totpEnabled = verifiedTotpFactors.length > 0;
  await syncTotpPreference(effectiveUserId, totpEnabled);

  const emailEnabled = Boolean(preferences?.email_enabled);
  const emailAvailableForChallenge = policy.allowedMethods.includes("email") && (isSelf ? Boolean(requester.user.email) : emailEnabled);
  const enrolledMethods: AllowedMethod[] = [];

  if (totpEnabled) {
    enrolledMethods.push("totp");
  }
  if (emailEnabled) {
    enrolledMethods.push("email");
  }

  const availableChallengeMethods: ChallengeMethod[] = [];

  if (policy.allowedMethods.includes("totp") && enrolledMethods.includes("totp")) {
    availableChallengeMethods.push("totp");
  }

  if (emailAvailableForChallenge) {
    availableChallengeMethods.push("email");
  }

  const hasAllowedEnrolledMethod = policy.allowedMethods.some((method) => enrolledMethods.includes(method));
  const mfaRequired = policy.isRequiredForUser;
  const mfaSetupRequired = policy.isRequiredForUser && !hasAllowedEnrolledMethod;

  return {
    userId: effectiveUserId,
    currentAal: isSelf ? requester.aal : null,
    allowedMethods: policy.allowedMethods,
    enrolledMethods,
    availableChallengeMethods,
    isRequiredForUser: policy.isRequiredForUser,
    mfaRequired,
    mfaSetupRequired,
    hasRecoveryCodes: false,
    recoveryCodesGeneratedAt: null,
    primaryMethod:
      preferences?.primary_method === "totp" || preferences?.primary_method === "email"
        ? preferences.primary_method
        : null,
    emailEnabled,
    totpEnabled,
    recoveryRequired: false,
    canManageTarget,
    mfaOptOut: policy.mfaOptOut,
  };
}

router.get("/api/auth/2fa/status", async (req, res) => {
  const requester = await getRequestContext(req.headers.authorization);
  if (!requester) {
    return res.status(401).json({ success: false, message: "Unauthorized" });
  }

  const targetUserId = typeof req.query.userId === "string" ? req.query.userId : undefined;
  const status = await getTwoFactorStatus(requester, targetUserId);

  if (!status) {
    return res.status(403).json({ success: false, message: "You cannot manage this user's MFA status." });
  }

  return res.status(200).json({ success: true, status });
});

router.post("/api/auth/reauth/password", async (req, res) => {
  const requester = await getRequestContext(req.headers.authorization);
  if (!requester) {
    return res.status(401).json({ success: false, message: "Unauthorized" });
  }

  const password = typeof req.body?.password === "string" ? req.body.password : "";
  if (!password) {
    return res.status(400).json({ success: false, message: "Password is required." });
  }

  if (!requester.user.email) {
    return res.status(400).json({ success: false, message: "No email is available for this account." });
  }

  const ephemeralClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });

  const { error } = await ephemeralClient.auth.signInWithPassword({
    email: requester.user.email,
    password,
  });

  if (error) {
    return res.status(400).json({ success: false, message: "Incorrect password. Please try again." });
  }

  await logSecurityEvent("password_reauth_verified", requester.user.id, requester.user.id);

  return res.status(200).json({ success: true });
});

router.post("/api/auth/2fa/email/challenge", async (req, res) => {
  const requester = await getRequestContext(req.headers.authorization);
  if (!requester) {
    return res.status(401).json({ success: false, message: "Unauthorized" });
  }

  const purpose = typeof req.body?.purpose === "string" ? req.body.purpose.trim() : "login";
  const sessionKey = typeof req.body?.sessionKey === "string" ? req.body.sessionKey.trim() : requester.sessionId;
  const email = requester.user.email;

  if (!email) {
    return res.status(400).json({ success: false, message: "No email address is available for this account." });
  }

  const cooldownThreshold = new Date(Date.now() - EMAIL_CHALLENGE_RESEND_SECONDS * 1000).toISOString();
  const { data: recentChallenge, error: recentChallengeError } = await supabaseService
    .from("user_two_factor_email_challenges")
    .select("id, created_at, expires_at")
    .eq("user_id", requester.user.id)
    .eq("purpose", purpose)
    .is("consumed_at", null)
    .gte("created_at", cooldownThreshold)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (recentChallengeError) {
    console.error("[2FA] Failed to check recent email challenge:", recentChallengeError.message);
  }

  if (recentChallenge) {
    const retryAfterSeconds = Math.max(
      1,
      EMAIL_CHALLENGE_RESEND_SECONDS -
        Math.floor((Date.now() - new Date(recentChallenge.created_at).getTime()) / 1000)
    );

    return res.status(429).json({
      success: false,
      message: `Please wait ${retryAfterSeconds} seconds before requesting another code.`,
      retryAfterSeconds,
      challengeId: recentChallenge.id,
      expiresAt: recentChallenge.expires_at,
    });
  }

  const code = generateEmailCode();
  const expiryMinutes = await getEmailOtpExpiryMinutes();
  const expiresAt = new Date(Date.now() + expiryMinutes * 60 * 1000).toISOString();

  const { data: challenge, error: challengeError } = await supabaseService
    .from("user_two_factor_email_challenges")
    .insert({
      user_id: requester.user.id,
      email,
      purpose,
      code_hash: hashValue(requester.user.id, purpose, code),
      expires_at: expiresAt,
      session_key: sessionKey || null,
      created_by: requester.user.id,
      updated_by: requester.user.id,
    })
    .select("id")
    .single();

  if (challengeError || !challenge) {
    console.error("[2FA] Failed to create email challenge:", challengeError?.message);
    return res.status(500).json({ success: false, message: "Unable to create the email verification code." });
  }

  const outcome = await sendEmailsToAddresses(
    [email],
    "Your LegalPrime verification code",
    `Your LegalPrime verification code is ${code}. It expires in ${expiryMinutes} minutes.`,
    undefined,
    {
      htmlBody: `<p>Your LegalPrime verification code is <strong>${code}</strong>.</p><p>This code expires in ${expiryMinutes} minutes.</p>`,
      textBody: `Your LegalPrime verification code is ${code}. It expires in ${expiryMinutes} minutes.`,
    }
  );

  if (outcome.sent === 0) {
    await supabaseService
      .from("user_two_factor_email_challenges")
      .delete()
      .eq("id", challenge.id);

    return res.status(500).json({
      success: false,
      message: outcome.errors[0] || "Unable to send the verification email.",
    });
  }

  await logSecurityEvent("2fa_email_challenge_sent", requester.user.id, requester.user.id, { purpose });

  return res.status(200).json({
    success: true,
    challengeId: challenge.id,
    expiresAt,
    retryAfterSeconds: EMAIL_CHALLENGE_RESEND_SECONDS,
  });
});

router.post("/api/auth/2fa/email/verify", async (req, res) => {
  const requester = await getRequestContext(req.headers.authorization);
  if (!requester) {
    return res.status(401).json({ success: false, message: "Unauthorized" });
  }

  const challengeId = typeof req.body?.challengeId === "string" ? req.body.challengeId.trim() : "";
  const code = typeof req.body?.code === "string" ? req.body.code.trim() : "";

  if (!challengeId || !code) {
    return res.status(400).json({ success: false, message: "challengeId and code are required." });
  }

  const { data: challenge, error: challengeError } = await supabaseService
    .from("user_two_factor_email_challenges")
    .select("*")
    .eq("id", challengeId)
    .eq("user_id", requester.user.id)
    .maybeSingle();

  if (challengeError || !challenge) {
    return res.status(404).json({ success: false, message: "Verification challenge not found." });
  }

  if (challenge.consumed_at) {
    return res.status(400).json({ success: false, message: "This verification code has already been used." });
  }

  if (new Date(challenge.expires_at).getTime() < Date.now()) {
    return res.status(400).json({ success: false, message: "This verification code has expired." });
  }

  if (challenge.blocked_until && new Date(challenge.blocked_until).getTime() > Date.now()) {
    return res.status(429).json({
      success: false,
      message: "Too many incorrect attempts. Please request a new code later.",
      blockedUntil: challenge.blocked_until,
    });
  }

  const expectedHash = hashValue(requester.user.id, challenge.purpose, code);
  if (!safeHashEquals(challenge.code_hash, expectedHash)) {
    const nextAttempts = Number(challenge.attempt_count || 0) + 1;
    const isLocked = nextAttempts >= Number(challenge.max_attempts || 5);
    const blockedUntil = isLocked
      ? new Date(Date.now() + EMAIL_CHALLENGE_LOCK_MINUTES * 60 * 1000).toISOString()
      : null;

    await supabaseService
      .from("user_two_factor_email_challenges")
      .update({
        attempt_count: nextAttempts,
        blocked_until: blockedUntil,
        updated_at: new Date().toISOString(),
        updated_by: requester.user.id,
      })
      .eq("id", challengeId);

    return res.status(isLocked ? 429 : 400).json({
      success: false,
      message: isLocked
        ? "Too many incorrect attempts. Please request a new code later."
        : "The verification code is incorrect.",
      remainingAttempts: isLocked ? 0 : Math.max(0, Number(challenge.max_attempts || 5) - nextAttempts),
      blockedUntil,
    });
  }

  await supabaseService
    .from("user_two_factor_email_challenges")
    .update({
      consumed_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      updated_by: requester.user.id,
    })
    .eq("id", challengeId);

  await supabaseService
    .from("user_two_factor_preferences")
    .upsert(
      {
        user_id: requester.user.id,
        email_enabled: true,
        primary_method: "email",
        last_verified_method: "email",
        mfa_opt_out: false,
        updated_at: new Date().toISOString(),
        updated_by: requester.user.id,
      },
      { onConflict: "user_id" }
    );

  await logSecurityEvent("2fa_email_verified", requester.user.id, requester.user.id, {
    purpose: challenge.purpose,
  });

  return res.status(200).json({ success: true });
});

router.post("/api/auth/2fa/recovery/regenerate", async (req, res) => {
  const requester = await getRequestContext(req.headers.authorization);
  if (!requester) {
    return res.status(401).json({ success: false, message: "Unauthorized" });
  }

  const [preferencesResult, policyResult] = await Promise.all([
    supabaseService
      .from("user_two_factor_preferences")
      .select("email_enabled")
      .eq("user_id", requester.user.id)
      .maybeSingle(),
    getCompanyPolicy(requester.user.id),
  ]);

  if (preferencesResult.error) {
    console.error("[2FA] Failed to load preferences before regenerating recovery codes:", preferencesResult.error.message);
  }

  const hasVerifiedSecondFactor = requester.aal === "aal2" || Boolean(preferencesResult.data?.email_enabled);
  if (!hasVerifiedSecondFactor && !policyResult.isRequiredForUser) {
    return res.status(400).json({
      success: false,
      message: "Enable a second factor before generating recovery codes.",
    });
  }

  const batchId = randomUUID();
  const codes = Array.from({ length: RECOVERY_CODE_COUNT }, () => generateRecoveryCode());
  const nowIso = new Date().toISOString();

  await supabaseService
    .from("user_two_factor_recovery_codes")
    .update({
      expires_at: nowIso,
      updated_at: nowIso,
      updated_by: requester.user.id,
    })
    .eq("user_id", requester.user.id)
    .is("used_at", null);

  const inserts = codes.map((code) => ({
    user_id: requester.user.id,
    code_hash: hashValue(requester.user.id, code),
    batch_id: batchId,
    created_by: requester.user.id,
    updated_by: requester.user.id,
  }));

  const { error: insertError } = await supabaseService.from("user_two_factor_recovery_codes").insert(inserts);
  if (insertError) {
    console.error("[2FA] Failed to store recovery codes:", insertError.message);
    return res.status(500).json({ success: false, message: "Unable to generate recovery codes." });
  }

  await supabaseService
    .from("user_two_factor_preferences")
    .upsert(
      {
        user_id: requester.user.id,
        recovery_codes_generated_at: nowIso,
        updated_at: nowIso,
        updated_by: requester.user.id,
      },
      { onConflict: "user_id" }
    );

  await logSecurityEvent("2fa_recovery_codes_regenerated", requester.user.id, requester.user.id, {
    batchId,
  });

  return res.status(200).json({
    success: true,
    batchId,
    codes,
  });
});

router.post("/api/auth/2fa/recovery/verify", async (req, res) => {
  const requester = await getRequestContext(req.headers.authorization);
  if (!requester) {
    return res.status(401).json({ success: false, message: "Unauthorized" });
  }

  const code = typeof req.body?.code === "string" ? formatRecoveryCode(req.body.code) : "";
  if (!code) {
    return res.status(400).json({ success: false, message: "Recovery code is required." });
  }

  const hashedCode = hashValue(requester.user.id, code);
  const nowIso = new Date().toISOString();

  const { data: recoveryCodes, error: recoveryCodesError } = await supabaseService
    .from("user_two_factor_recovery_codes")
    .select("id, code_hash, used_at, expires_at")
    .eq("user_id", requester.user.id)
    .is("used_at", null);

  if (recoveryCodesError) {
    console.error("[2FA] Failed to load recovery codes:", recoveryCodesError.message);
    return res.status(500).json({ success: false, message: "Unable to verify the recovery code right now." });
  }

  const match = (recoveryCodes || []).find(
    (entry) =>
      (!entry.expires_at || new Date(entry.expires_at).getTime() > Date.now()) &&
      safeHashEquals(entry.code_hash, hashedCode) &&
      Boolean(entry.id)
  );

  if (!match) {
    return res.status(400).json({ success: false, message: "That recovery code is invalid or already used." });
  }

  await supabaseService
    .from("user_two_factor_recovery_codes")
    .update({
      used_at: nowIso,
      updated_at: nowIso,
      updated_by: requester.user.id,
    })
    .eq("id", match.id);

  await supabaseService
    .from("user_two_factor_preferences")
    .upsert(
      {
        user_id: requester.user.id,
        last_verified_method: "recovery",
        updated_at: nowIso,
        updated_by: requester.user.id,
      },
      { onConflict: "user_id" }
    );

  const { data: remainingRecoveryRows } = await supabaseService
    .from("user_two_factor_recovery_codes")
    .select("id, expires_at")
    .eq("user_id", requester.user.id)
    .is("used_at", null);

  await logSecurityEvent("2fa_recovery_code_used", requester.user.id, requester.user.id);

  return res.status(200).json({
    success: true,
    remainingRecoveryCodes: (remainingRecoveryRows || []).filter(
      (row) => !row.expires_at || new Date(row.expires_at).getTime() > Date.now()
    ).length,
  });
});

router.post("/api/auth/2fa/disable", async (req, res) => {
  const requester = await getRequestContext(req.headers.authorization);
  if (!requester) {
    return res.status(401).json({ success: false, message: "Unauthorized" });
  }

  const status = await getTwoFactorStatus(requester);
  if (!status) {
    return res.status(403).json({ success: false, message: "Unable to load your MFA status." });
  }

  const method = req.body?.method === "email" ? "email" : req.body?.method === "all" ? "all" : "totp";

  const nowIso = new Date().toISOString();

  if (method === "totp" || method === "all") {
    const { data: factors, error: factorsError } = await supabaseService.auth.admin.mfa.listFactors({
      userId: requester.user.id,
    });

    if (factorsError) {
      return res.status(500).json({ success: false, message: "Unable to load your authenticator factors." });
    }

    const totpFactors = (factors?.factors || []).filter((factor) => factor.factor_type === "totp");
    for (const factor of totpFactors) {
      const { error } = await supabaseService.auth.admin.mfa.deleteFactor({
        id: factor.id,
        userId: requester.user.id,
      });
      if (error) {
        console.error("[2FA] Failed to delete TOTP factor:", error.message);
        return res.status(500).json({ success: false, message: "Unable to disable your authenticator right now." });
      }
    }
  }

  const nextEmailEnabled = method === "email" || method === "all" ? false : status.emailEnabled;
  const nextTotpEnabled = method === "totp" || method === "all" ? false : status.totpEnabled;
  const nextPrimaryMethod = nextTotpEnabled ? "totp" : nextEmailEnabled ? "email" : null;
  const nextOptOut = !nextEmailEnabled && !nextTotpEnabled;

  const { error: upsertError } = await supabaseService
    .from("user_two_factor_preferences")
    .upsert(
      {
        user_id: requester.user.id,
        email_enabled: nextEmailEnabled,
        totp_enabled: nextTotpEnabled,
        primary_method: nextPrimaryMethod,
        mfa_opt_out: nextOptOut,
        updated_at: nowIso,
        updated_by: requester.user.id,
      },
      { onConflict: "user_id" }
    );

  if (upsertError) {
    console.error("[2FA] Failed to persist disable state:", upsertError.message);
    return res.status(500).json({
      success: false,
      message: `Unable to save your 2FA state: ${upsertError.message}`,
    });
  }

  if (!nextTotpEnabled && !nextEmailEnabled) {
    await supabaseService
      .from("user_two_factor_recovery_codes")
      .update({
        expires_at: nowIso,
        updated_at: nowIso,
        updated_by: requester.user.id,
      })
      .eq("user_id", requester.user.id)
      .is("used_at", null);
  }

  await logSecurityEvent("2fa_disabled", requester.user.id, requester.user.id, { method });

  return res.status(200).json({ success: true });
});

router.post("/api/auth/2fa/admin/reset-authenticator", async (req, res) => {
  const requester = await getRequestContext(req.headers.authorization);
  if (!requester) {
    return res.status(401).json({ success: false, message: "Unauthorized" });
  }

  const canManage = await canManageOtherUsers(requester.user.id);
  if (!canManage) {
    return res.status(403).json({ success: false, message: "Only admins can reset another user's authenticator." });
  }

  const targetUserId = typeof req.body?.targetUserId === "string" ? req.body.targetUserId.trim() : "";
  if (!targetUserId) {
    return res.status(400).json({ success: false, message: "targetUserId is required." });
  }

  const { data: factors, error: factorsError } = await supabaseService.auth.admin.mfa.listFactors({
    userId: targetUserId,
  });

  if (factorsError) {
    return res.status(500).json({ success: false, message: "Unable to load authenticator factors for this user." });
  }

  const totpFactors = (factors?.factors || []).filter((factor) => factor.factor_type === "totp");
  for (const factor of totpFactors) {
    const { error } = await supabaseService.auth.admin.mfa.deleteFactor({
      id: factor.id,
      userId: targetUserId,
    });
    if (error) {
      console.error("[2FA] Failed to admin-reset factor:", error.message);
      return res.status(500).json({ success: false, message: "Unable to reset the authenticator right now." });
    }
  }

  const nowIso = new Date().toISOString();
  const { data: existingPreferences } = await supabaseService
    .from("user_two_factor_preferences")
    .select("email_enabled")
    .eq("user_id", targetUserId)
    .maybeSingle();

  await supabaseService
    .from("user_two_factor_preferences")
    .upsert(
      {
        user_id: targetUserId,
        totp_enabled: false,
        primary_method: existingPreferences?.email_enabled ? "email" : null,
        recovery_codes_generated_at: null,
        updated_at: nowIso,
        updated_by: requester.user.id,
      },
      { onConflict: "user_id" }
    );

  await supabaseService
    .from("user_two_factor_recovery_codes")
    .update({
      expires_at: nowIso,
      updated_at: nowIso,
      updated_by: requester.user.id,
    })
    .eq("user_id", targetUserId)
    .is("used_at", null);

  await logSecurityEvent("2fa_admin_reset_authenticator", targetUserId, requester.user.id, {
    factorCount: totpFactors.length,
  });

  return res.status(200).json({ success: true });
});

router.post("/api/auth/2fa/self-reset-authenticator", async (req, res) => {
  const requester = await getRequestContext(req.headers.authorization);
  if (!requester) {
    return res.status(401).json({ success: false, message: "Unauthorized" });
  }

  const challengeId = typeof req.body?.challengeId === "string" ? req.body.challengeId.trim() : "";
  const code = typeof req.body?.code === "string" ? req.body.code.trim() : "";

  if (!challengeId || !code) {
    return res.status(400).json({ success: false, message: "challengeId and code are required." });
  }

  const { data: challenge, error: challengeError } = await supabaseService
    .from("user_two_factor_email_challenges")
    .select("*")
    .eq("id", challengeId)
    .eq("user_id", requester.user.id)
    .maybeSingle();

  if (challengeError || !challenge) {
    return res.status(404).json({ success: false, message: "Verification challenge not found." });
  }

  if (challenge.consumed_at) {
    return res.status(400).json({ success: false, message: "This verification code has already been used." });
  }

  if (new Date(challenge.expires_at).getTime() < Date.now()) {
    return res.status(400).json({ success: false, message: "This verification code has expired." });
  }

  if (challenge.blocked_until && new Date(challenge.blocked_until).getTime() > Date.now()) {
    return res.status(429).json({
      success: false,
      message: "Too many incorrect attempts. Please request a new code later.",
      blockedUntil: challenge.blocked_until,
    });
  }

  const expectedHash = hashValue(requester.user.id, challenge.purpose, code);
  if (!safeHashEquals(challenge.code_hash, expectedHash)) {
    const nextAttempts = Number(challenge.attempt_count || 0) + 1;
    const isLocked = nextAttempts >= Number(challenge.max_attempts || 5);
    const blockedUntil = isLocked
      ? new Date(Date.now() + EMAIL_CHALLENGE_LOCK_MINUTES * 60 * 1000).toISOString()
      : null;

    await supabaseService
      .from("user_two_factor_email_challenges")
      .update({
        attempt_count: nextAttempts,
        blocked_until: blockedUntil,
        updated_at: new Date().toISOString(),
        updated_by: requester.user.id,
      })
      .eq("id", challengeId);

    return res.status(isLocked ? 429 : 400).json({
      success: false,
      message: isLocked
        ? "Too many incorrect attempts. Please request a new code later."
        : "The verification code is incorrect.",
      remainingAttempts: isLocked ? 0 : Math.max(0, Number(challenge.max_attempts || 5) - nextAttempts),
      blockedUntil,
    });
  }

  await supabaseService
    .from("user_two_factor_email_challenges")
    .update({
      consumed_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      updated_by: requester.user.id,
    })
    .eq("id", challengeId);

  const { data: factors, error: factorsError } = await supabaseService.auth.admin.mfa.listFactors({
    userId: requester.user.id,
  });

  if (factorsError) {
    return res.status(500).json({ success: false, message: "Unable to load your authenticator factors." });
  }

  const totpFactors = (factors?.factors || []).filter((factor) => factor.factor_type === "totp");
  for (const factor of totpFactors) {
    const { error } = await supabaseService.auth.admin.mfa.deleteFactor({
      id: factor.id,
      userId: requester.user.id,
    });
    if (error) {
      console.error("[2FA] Failed to self-reset factor:", error.message);
      return res.status(500).json({ success: false, message: "Unable to reset your authenticator right now." });
    }
  }

  const nowIso = new Date().toISOString();
  const { data: existingPreferences } = await supabaseService
    .from("user_two_factor_preferences")
    .select("email_enabled")
    .eq("user_id", requester.user.id)
    .maybeSingle();

  await supabaseService
    .from("user_two_factor_preferences")
    .upsert(
      {
        user_id: requester.user.id,
        totp_enabled: false,
        primary_method: existingPreferences?.email_enabled ? "email" : null,
        recovery_codes_generated_at: null,
        updated_at: nowIso,
        updated_by: requester.user.id,
      },
      { onConflict: "user_id" }
    );

  await supabaseService
    .from("user_two_factor_recovery_codes")
    .update({
      expires_at: nowIso,
      updated_at: nowIso,
      updated_by: requester.user.id,
    })
    .eq("user_id", requester.user.id)
    .is("used_at", null);

  await logSecurityEvent("2fa_self_reset_authenticator", requester.user.id, requester.user.id, {
    factorCount: totpFactors.length,
  });

  return res.status(200).json({ success: true });
});

router.post("/api/auth/reset-password", async (req, res) => {
  const requester = await getRequestContext(req.headers.authorization);
  if (!requester) {
    return res.status(401).json({ success: false, message: "Unauthorized" });
  }

  const password = typeof req.body?.password === "string" ? req.body.password : "";
  if (!password || password.length < 8) {
    return res.status(400).json({ success: false, message: "Password must be at least 8 characters." });
  }

  const { error } = await supabaseService.auth.admin.updateUserById(requester.user.id, { password });

  if (error) {
    console.error("[Auth] Failed to reset password via admin API:", error.message);
    return res.status(500).json({ success: false, message: "Unable to update your password right now." });
  }

  await logSecurityEvent("password_reset", requester.user.id, requester.user.id);

  return res.status(200).json({ success: true });
});

router.post("/api/auth/forgot-password", async (req, res) => {
  const email = typeof req.body?.email === "string" ? req.body.email.trim().toLowerCase() : "";
  if (!email) {
    return res.status(400).json({ success: false, message: "Email is required." });
  }

  const redirectTo = typeof req.body?.redirectTo === "string" ? req.body.redirectTo : "";

  try {
    const { data: linkData, error: linkError } = await supabaseService.auth.admin.generateLink({
      type: "recovery",
      email,
      options: { redirectTo },
    });

    if (linkError || !linkData?.properties?.action_link) {
      console.error("[Auth] Failed to generate recovery link:", linkError?.message);
      return res.status(200).json({ success: true });
    }

    const resetLink = linkData.properties.action_link;

    const outcome = await sendEmailsToAddresses(
      [email],
      "Reset your LegalPrime password",
      `You requested a password reset. Click the link below to set a new password:\n\n${resetLink}\n\nIf you did not request this, you can safely ignore this email.`,
      undefined,
      {
        htmlBody: `
          <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <div style="background-color: #4F46E5; color: white; padding: 20px; text-align: center; border-radius: 8px 8px 0 0;">
              <h1 style="margin: 0; font-size: 24px;">Reset Your Password</h1>
            </div>
            <div style="background-color: #f9fafb; padding: 30px; border-radius: 0 0 8px 8px;">
              <p style="color: #374151;">Hello,</p>
              <p style="color: #374151;">We received a request to reset the password for your LegalPrime account associated with <strong>${email}</strong>.</p>
              <p style="color: #374151;">Click the button below to set a new password:</p>
              <div style="text-align: center; margin: 30px 0;">
                <a href="${resetLink}" style="display: inline-block; background-color: #4F46E5; color: white; padding: 14px 36px; text-decoration: none; border-radius: 8px; font-weight: 600; font-size: 16px;">
                  Reset Password
                </a>
              </div>
             
            </div>
          </div>`,
        textBody: `You requested a password reset for your LegalPrime account (${email}).\n\nClick the link below to set a new password:\n${resetLink}\n\nIf you did not request this, you can safely ignore this email.`,
      }
    );

    if (outcome.sent === 0) {
      console.error("[Auth] Failed to send password reset email:", outcome.errors);
    }
  } catch (err) {
    console.error("[Auth] Unexpected error in forgot-password:", err);
  }

  return res.status(200).json({ success: true });
});

export { router as twoFactorRouter };