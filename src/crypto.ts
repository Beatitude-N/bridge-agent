import crypto from "crypto";

const ENCRYPTION_ALGORITHM = "aes-256-gcm";

/**
 * Derives a 32-byte secret key matching BfxBridge backend encryption.
 */
function getEncryptionKey(): Buffer {
  const secret =
    process.env.ENCRYPTION_KEY ||
    process.env.SESSION_SECRET ||
    process.env.MONGODB_URI ||
    "bfxbridge-mt5-password-encryption-secret-salt";
  return crypto.createHash("sha256").update(secret).digest();
}

/**
 * Decrypts an AES-256-GCM encrypted MT5 password in-memory.
 * Only called by the Terminal Manager when generating transient startup config.
 */
export function decryptPasswordInMemory(encryptedPayload: string): string | null {
  if (!encryptedPayload) return null;
  try {
    const parts = encryptedPayload.split(":");
    if (parts.length !== 3) return null;

    const [ivHex, authTagHex, encryptedText] = parts;
    const key = getEncryptionKey();
    const iv = Buffer.from(ivHex, "hex");
    const authTag = Buffer.from(authTagHex, "hex");

    const decipher = crypto.createDecipheriv(ENCRYPTION_ALGORITHM, key, iv);
    decipher.setAuthTag(authTag);

    let decrypted = decipher.update(encryptedText, "hex", "utf8");
    decrypted += decipher.final("utf8");
    return decrypted;
  } catch (err) {
    console.error("[BridgeAgent] Error decrypting account password in memory:", err);
    return null;
  }
}
