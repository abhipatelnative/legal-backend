import { createCipheriv, createDecipheriv, createHash, randomBytes } from "crypto";

import { SUPABASE_SERVICE_ROLE_KEY } from "../config/credentials";

const ALGORITHM = "aes-256-gcm";
const SECRET = process.env.AI_CONFIG_SECRET || `legalprime-ai:${SUPABASE_SERVICE_ROLE_KEY}`;

function getKey(): Buffer {
  return createHash("sha256").update(SECRET).digest();
}

export function encryptSecret(value: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv(ALGORITHM, getKey(), iv);
  const encrypted = Buffer.concat([cipher.update(value, "utf8"), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return `${iv.toString("base64")}.${authTag.toString("base64")}.${encrypted.toString("base64")}`;
}

export function decryptSecret(value?: string | null): string | null {
  if (!value) {
    return null;
  }

  const [ivBase64, authTagBase64, payloadBase64] = value.split(".");
  if (!ivBase64 || !authTagBase64 || !payloadBase64) {
    return null;
  }

  try {
    const decipher = createDecipheriv(ALGORITHM, getKey(), Buffer.from(ivBase64, "base64"));
    decipher.setAuthTag(Buffer.from(authTagBase64, "base64"));
    const decrypted = Buffer.concat([
      decipher.update(Buffer.from(payloadBase64, "base64")),
      decipher.final(),
    ]);
    return decrypted.toString("utf8");
  } catch {
    return null;
  }
}
