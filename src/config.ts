import fs from "fs";
import path from "path";
import os from "os";

export interface AgentConfig {
  backendBaseUrl: string;
  bridgeAgentSecret: string;
  instancesDir: string;
  terminalExePath: string;
  isWine: boolean;
  wineBinPath?: string;
  winePrefix?: string;
  pollIntervalMs: number;
  display: string;
}

/**
 * Auto-detects local MT5 runtime environment (Windows vs Mac Wine).
 */
export function loadAgentConfig(): AgentConfig {
  const backendBaseUrl =
    process.env.BFX_BASE_URL ||
    process.env.BACKEND_URL ||
    "";
  const bridgeAgentSecret =
    process.env.BRIDGE_AGENT_SECRET ||
    process.env.SESSION_SECRET ||
    "bfxbridge-secure-bridge-agent-secret-key-salt";

  const instancesDir =
    process.env.MT5_INSTANCES_DIR ||
    path.join(process.cwd(), "bridge-agent", "instances");

  // Ensure instances directory exists
  if (!fs.existsSync(instancesDir)) {
    fs.mkdirSync(instancesDir, { recursive: true });
  }

  const isMac = process.platform === "darwin";
  const isLinux = process.platform === "linux";
  let isWine = false;
  let wineBinPath: string | undefined;
  let winePrefix: string | undefined;
  let terminalExePath = process.env.MT5_TERMINAL_PATH || "";

  if (isMac) {
    isWine = true;
    const defaultMacWine =
      "/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine";
    const defaultMacPrefix = path.join(
      os.homedir(),
      "Library",
      "Application Support",
      "net.metaquotes.wine.metatrader5"
    );
    const defaultMacTerminal = path.join(
      defaultMacPrefix,
      "drive_c",
      "Program Files",
      "MetaTrader 5",
      "terminal64.exe"
    );

    if (fs.existsSync(defaultMacWine)) {
      wineBinPath = defaultMacWine;
    } else {
      wineBinPath = "wine";
    }

    if (fs.existsSync(defaultMacPrefix)) {
      winePrefix = defaultMacPrefix;
    }

    if (!terminalExePath && fs.existsSync(defaultMacTerminal)) {
      terminalExePath = defaultMacTerminal;
    }
  } else if (isLinux || process.env.IS_WINE === "true") {
    isWine = true;
    wineBinPath = process.env.WINE_BIN_PATH || "wine";
    const defaultLinuxPrefix = path.join(os.homedir(), ".wine");
    winePrefix = process.env.WINEPREFIX || defaultLinuxPrefix;

    const defaultLinuxTerminal = path.join(
      winePrefix,
      "drive_c",
      "Program Files",
      "MetaTrader 5",
      "terminal64.exe"
    );

    if (!terminalExePath && fs.existsSync(defaultLinuxTerminal)) {
      terminalExePath = defaultLinuxTerminal;
    } else if (!terminalExePath) {
      terminalExePath = defaultLinuxTerminal;
    }
  } else {
    // Windows default
    if (!terminalExePath) {
      const defaultWinTerminal = "C:\\Program Files\\MetaTrader 5\\terminal64.exe";
      terminalExePath = defaultWinTerminal;
    }
  }

  const pollIntervalMs = process.env.POLL_INTERVAL_MS
    ? parseInt(process.env.POLL_INTERVAL_MS, 10)
    : 30000;

  // Compute target GUI display (Prioritizes visible desktop over headless :99)
  let display = process.env.MT5_DISPLAY || process.env.TARGET_DISPLAY || "";
  if (!display && process.env.DISPLAY && process.env.DISPLAY !== ":99") {
    display = process.env.DISPLAY;
  }
  if (!display && isLinux) {
    try {
      if (fs.existsSync("/tmp/.X11-unix")) {
        const files = fs.readdirSync("/tmp/.X11-unix");
        const xSockets = files
          .filter((f) => f.startsWith("X"))
          .map((f) => f.slice(1))
          .filter((num) => num !== "99"); // Exclude headless Xvfb (:99)
        if (xSockets.includes("1")) {
          display = ":1";
        } else if (xSockets.includes("0")) {
          display = ":0";
        } else if (xSockets.length > 0) {
          display = `:${xSockets[0]}`;
        }
      }
    } catch {}
  }
  if (!display) {
    display = isMac ? ":10.0" : ":1";
  }

  return {
    backendBaseUrl,
    bridgeAgentSecret,
    instancesDir,
    terminalExePath,
    isWine,
    wineBinPath,
    winePrefix,
    pollIntervalMs,
    display,
  };
}
