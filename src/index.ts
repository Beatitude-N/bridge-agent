import fs from "fs";
import path from "path";
import { loadAgentConfig } from "./config";
import { TerminalManager } from "./terminal-manager";

// Auto-load local .env if present
const envCandidates = [
  path.resolve(process.cwd(), ".env"),
  path.resolve(__dirname, "..", ".env"),
];
for (const envPath of envCandidates) {
  if (fs.existsSync(envPath) && typeof (process as any).loadEnvFile === "function") {
    try {
      (process as any).loadEnvFile(envPath);
      break;
    } catch {
      // Ignore
    }
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
