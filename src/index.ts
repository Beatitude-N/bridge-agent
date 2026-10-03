import fs from "fs";
import path from "path";
import { loadAgentConfig } from "./config";
import { TerminalManager } from "./terminal-manager";

// Auto-load local .env if present
const envCandidates = [
  path.resolve(process.cwd(), ".env"),
  path.resolve(__dirname, "..", ".env"),
];

function parseAndLoadEnv(filePath: string) {
  try {
    const content = fs.readFileSync(filePath, "utf-8");
    for (const rawLine of content.split("\n")) {
      const line = rawLine.trim();
      if (!line || line.startsWith("#")) continue;
      const eqIdx = line.indexOf("=");
      if (eqIdx === -1) continue;
      const key = line.slice(0, eqIdx).trim();
      let val = line.slice(eqIdx + 1).trim();
      if (
        (val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"))
      ) {
        val = val.slice(1, -1);
      }
      // Force MT5_DISPLAY / DISPLAY / BFX_ keys to take priority
      if (key === "MT5_DISPLAY" || key === "TARGET_DISPLAY" || key === "DISPLAY" || !process.env[key]) {
        process.env[key] = val;
      }
    }
  } catch {}
}

for (const envPath of envCandidates) {
  if (fs.existsSync(envPath)) {
    if (typeof (process as any).loadEnvFile === "function") {
      try {
        (process as any).loadEnvFile(envPath);
      } catch {}
    }
    parseAndLoadEnv(envPath);
    break;
  }
}

async function main() {
  const config = loadAgentConfig();
  const manager = new TerminalManager(config);

  const shutdown = async () => {
    console.log("\n[BridgeAgent] Received termination signal. Shutting down...");
    await manager.stop();
    process.exit(0);
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  await manager.start();
}

main().catch((err) => {
  console.error("[BridgeAgent] Fatal error in agent runner:", err);
  process.exit(1);
});
