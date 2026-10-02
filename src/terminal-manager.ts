import { execSync } from "child_process";
import { AgentConfig } from "./config";
import { launchMt5Terminal, SpawnedTerminal } from "./mt5-launcher";
import { decryptPasswordInMemory } from "./crypto";
import { BridgeAgentAccountConfig } from "./types";

function isSystemTerminalRunning(): boolean {
  try {
    if (process.platform === "win32") {
      const out = execSync("tasklist /FI \"IMAGENAME eq terminal64.exe\"", { encoding: "utf8" });
      return out.includes("terminal64.exe");
    } else {
      const out = execSync("ps aux | grep -iE 'terminal64\\.exe|MetaTrader 5' | grep -v grep", { encoding: "utf8" });
      return out.trim().length > 0;
    }
  } catch {
    return false;
  }
}

export class TerminalManager {
  private config: AgentConfig;
  private instances: Map<string, SpawnedTerminal> = new Map();
  private isRunning: boolean = false;
  private pollTimer: ReturnType<typeof setInterval> | null = null;

  constructor(config: AgentConfig) {
    this.config = config;
  }

  /**
   * Starts the autonomous Terminal Manager daemon loop.
   */
  public async start(): Promise<void> {
    if (this.isRunning) return;
    this.isRunning = true;

    console.log("==================================================");
    console.log("[BridgeAgent] MT5 Terminal Manager Daemon Starting");
    console.log(`[BridgeAgent] Target Server: ${this.config.backendBaseUrl}`);
    console.log(`[BridgeAgent] Runtime: ${this.config.isWine ? "Wine (macOS)" : "Native Windows"}`);
    console.log(`[BridgeAgent] Terminal Binary: ${this.config.terminalExePath}`);
    console.log(`[BridgeAgent] Instances Dir: ${this.config.instancesDir}`);
    console.log("==================================================");

    // Initial sync
    await this.syncAccounts();

    // Periodic sync loop
    this.pollTimer = setInterval(async () => {
      if (this.isRunning) {
        await this.syncAccounts();
      }
    }, this.config.pollIntervalMs);
  }

  /**
   * Stops the daemon and gracefully terminates all spawned terminal instances.
   */
  public async stop(): Promise<void> {
    this.isRunning = false;
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }

    console.log("[BridgeAgent] Stopping all active MT5 terminal instances...");
    for (const [accountId, instance] of this.instances.entries()) {
      try {
        if (instance.process && !instance.process.killed) {
          instance.process.kill("SIGTERM");
        }
      } catch {
        // Best effort
      }
      this.instances.delete(accountId);
    }
    console.log("[BridgeAgent] All terminal instances stopped.");
  }

  /**
   * Synchronizes active accounts from BfxBridge backend.
   */
  private async syncAccounts(): Promise<void> {
    try {
      const res = await fetch(`${this.config.backendBaseUrl}/api/mt5/bridge-agent/accounts`, {
        headers: {
          "x-bridge-agent-secret": this.config.bridgeAgentSecret,
        },
      });

      if (!res.ok) {
        console.error(`[BridgeAgent] Failed to fetch accounts: HTTP ${res.status}`);
        return;
      }

      const data = await res.json();
      if (!data.success || !Array.isArray(data.accounts)) return;

      const activeAccounts: BridgeAgentAccountConfig[] = data.accounts;
      const activeAccountIds = new Set(activeAccounts.map((a) => a.id));

      // 1. Launch terminals for active accounts that are not yet running
      for (const account of activeAccounts) {
        if (!this.instances.has(account.id)) {
          await this.startInstance(account);
        }
      }

      // 2. Terminate instances for accounts that were deactivated or deleted
      for (const [accountId, instance] of this.instances.entries()) {
        if (!activeAccountIds.has(accountId)) {
          console.log(`[BridgeAgent] Account ${instance.accountNumber} (${accountId}) deactivated. Stopping terminal.`);
          try {
            if (instance.process && !instance.process.killed) {
              instance.process.kill("SIGTERM");
            }
          } catch {
            // Ignore
          }
          this.instances.delete(accountId);
        }
      }
    } catch (err) {
      console.error("[BridgeAgent] Error syncing accounts with BfxBridge:", err);
    }
  }

  /**
   * Starts a dedicated, isolated MT5 terminal instance for an account.
   */
  private async startInstance(account: BridgeAgentAccountConfig): Promise<void> {
    console.log(`[BridgeAgent] Starting MT5 instance for Account ${account.accountNumber} (${account.id}) on ${account.server}...`);

    // Retrieve plain trading password
    const decryptedPassword = account.password || null;

    try {
      // Notify backend: STARTING
      await this.reportStatus(account.id, {
        connectionStatus: "STARTING",
        terminalStatus: "ONLINE",
        eaStatus: "OFFLINE",
      });

      const spawned = await launchMt5Terminal(this.config, account, decryptedPassword);
      this.instances.set(account.id, spawned);

      // Handle process exit / crash
      spawned.process.on("exit", (code, signal) => {
        console.log(`[BridgeAgent] Terminal process for account ${spawned.accountNumber} exited with code: ${code}`);

        this.instances.delete(account.id);
        this.reportStatus(account.id, {
          connectionStatus: "DISCONNECTED",
          terminalStatus: "OFFLINE",
          eaStatus: "OFFLINE",
          terminalPid: null,
          errorMessage: `Terminal exited with code ${code}`,
        }).catch(() => {});
      });

      // Notify backend: CONNECTING with PID
      await this.reportStatus(account.id, {
        connectionStatus: "CONNECTING",
        terminalStatus: "ONLINE",
        terminalPid: spawned.pid,
      });

      console.log(`[BridgeAgent] Terminal instance launched for ${account.accountNumber}. PID: ${spawned.pid}`);
    } catch (err: any) {
      console.error(`[BridgeAgent] Failed to start terminal for ${account.accountNumber}:`, err);
      await this.reportStatus(account.id, {
        connectionStatus: "TERMINAL_ERROR",
        terminalStatus: "OFFLINE",
        eaStatus: "OFFLINE",
        errorMessage: err?.message || "Failed to launch MT5 process.",
      });
    }
  }

  /**
   * Transmits terminal lifecycle status to BfxBridge backend.
   */
  private async reportStatus(
    accountId: string,
    payload: {
      connectionStatus: string;
      terminalStatus?: "ONLINE" | "OFFLINE";
      eaStatus?: "ONLINE" | "OFFLINE";
      terminalPid?: number | null;
      errorMessage?: string;
    }
  ): Promise<void> {
    try {
      await fetch(`${this.config.backendBaseUrl}/api/mt5/bridge-agent/status`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-bridge-agent-secret": this.config.bridgeAgentSecret,
        },
        body: JSON.stringify({
          accountId,
          ...payload,
        }),
      });
    } catch {
      // Best effort reporting
    }
  }
}
