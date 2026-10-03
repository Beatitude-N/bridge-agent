import fs from "fs";
import path from "path";
import { spawn, ChildProcess } from "child_process";
import { AgentConfig } from "./config";
import { BridgeAgentAccountConfig } from "./types";

export interface SpawnedTerminal {
  accountId: string;
  accountNumber: string;
  instanceDir: string;
  pid: number | undefined;
  process: ChildProcess;
  startedAt: Date;
  status: "STARTING" | "RUNNING" | "STOPPED" | "ERROR";
}

/**
 * Helper to encode strings into UTF-16LE with Windows Byte Order Mark (0xFF 0xFE) and CRLF.
 * MT5 strictly requires BOM and CRLF for .chr, .tpl, and .set files.
 */
function toUtf16LeWithBom(str: string): Buffer {
  const crlfStr = str.replace(/\r?\n/g, "\r\n");
  const bom = Buffer.from([0xff, 0xfe]);
  const body = Buffer.from(crlfStr, "utf16le");
  return Buffer.concat([bom, body]);
}

/**
 * Builds UTF-16LE chart file with auto-attached BfxBridge EA.
 */
function buildDefaultChartBuffer(backendUrl: string, accountId: string, symbol: string = "XAUUSD"): Buffer {
  const chartContent =
`<chart>
id=134329884593686340
symbol=${symbol}
description=${symbol}
period_type=1
period_size=1
digits=2
tick_size=0.000000
scale_fix=0
scale=16
mode=1
fore=1
grid=0
volume=2
scroll=1
shift=1
ticker=1
ohlc=0
one_click=0
one_click_btn=1
bidline=1
askline=0
lastline=0
days=0
descriptions=0
tradelines=1
tradehistory=0
window_left=0
window_top=0
window_right=1920
window_bottom=1080
window_type=3
windows_total=1

<window>
height=100.000000
objects=0

<indicator>
name=Main
path=
apply=1
show_data=1
scale_inherit=0
scale_line=0
scale_line_percent=50
scale_line_value=0.000000
scale_fix_min=0
scale_fix_min_val=0.000000
scale_fix_max=0
scale_fix_max_val=0.000000
expertmode=0
fixed_height=-1
</indicator>

<expert>
name=BfxBridge
path=Experts\\BfxBridge.ex5
expertmode=5
<inputs>
=== BfxBridge Server Settings ====
InpServerUrl=${backendUrl}
InpAccountId=${accountId}
=== Order Execution Type Settings ====
InpExecMode=0
InpPendingExpiryMins=0
=== Execution & Polling Settings ====
InpMagicNumber=20260904
InpLongPolling=true
InpPollInterval=1
InpHeartbeatInterval=30
InpDeviation=20
</inputs>
</expert>
</window>
</chart>
`;

  return toUtf16LeWithBom(chartContent);
}

/**
 * Builds UTF-16LE BfxBridge.set preset file for MT5 [StartUp] ExpertParameters.
 */
function buildExpertParamsBuffer(backendUrl: string, accountId: string): Buffer {
  const content =
    `InpServerUrl=${backendUrl}\r\n` +
    `InpAccountId=${accountId}\r\n` +
    `InpExecMode=0\r\n` +
    `InpPendingExpiryMins=0\r\n` +
    `InpMagicNumber=20260904\r\n` +
    `InpLongPolling=true\r\n` +
    `InpPollInterval=1\r\n` +
    `InpHeartbeatInterval=30\r\n` +
    `InpDeviation=20\r\n`;

  return toUtf16LeWithBom(content);
}

function normalizeSymbolCase(raw: string): string {
  const s = raw.trim();
  if (!s) return "XAUUSD";
  const upper = s.toUpperCase();
  if (upper === "GOLD") return "GOLD";
  if (upper === "XAUUSD") return "XAUUSD"; // Natural Gold: preserve exactly as XAUUSD
  if (upper.endsWith(".PRO")) return upper.slice(0, -4) + ".pro";
  if (upper.endsWith(".RAW")) return upper.slice(0, -4) + ".raw";
  if (upper.endsWith("+")) return upper;
  if (upper.endsWith("M") && !upper.startsWith("M")) return upper.slice(0, -1) + "m";
  if (upper.endsWith("Z") && !upper.startsWith("Z")) return upper.slice(0, -1) + "z";
  if (upper.endsWith("C") && !upper.startsWith("C") && upper !== "USDC") return upper.slice(0, -1) + "c";
  return upper;
}

function getDisplayEnv(): string {
  if (process.env.DISPLAY) return process.env.DISPLAY;
  if (process.platform === "linux") {
    try {
      if (fs.existsSync("/tmp/.X11-unix")) {
        const files = fs.readdirSync("/tmp/.X11-unix");
        const xSockets = files.filter((f) => f.startsWith("X")).map((f) => f.slice(1));
        if (xSockets.includes("1")) return ":1";
        if (xSockets.includes("0")) return ":0";
        if (xSockets.length > 0) return `:${xSockets[0]}`;
      }
    } catch {}
    return ":1";
  }
  return ":10.0";
}

/**
 * Provisions an isolated working directory and launches a dedicated MT5 terminal instance.
 */
export async function launchMt5Terminal(
  config: AgentConfig,
  account: BridgeAgentAccountConfig,
  decryptedPassword?: string | null
): Promise<SpawnedTerminal> {
  const instanceDir = path.join(config.instancesDir, account.id);
  const chartsDir = path.join(instanceDir, "MQL5", "Profiles", "Charts", "Default");
  const expertsDir = path.join(instanceDir, "MQL5", "Experts", "BFX");
  const presetsDir = path.join(instanceDir, "MQL5", "Presets");
  const configDir = path.join(instanceDir, "config");
  const baseTerminalDir = path.dirname(config.terminalExePath);
  const basePresetsDir = path.join(baseTerminalDir, "MQL5", "Presets");

  fs.mkdirSync(chartsDir, { recursive: true });
  fs.mkdirSync(expertsDir, { recursive: true });
  fs.mkdirSync(presetsDir, { recursive: true });
  fs.mkdirSync(basePresetsDir, { recursive: true });
  fs.mkdirSync(configDir, { recursive: true });

  // Resolve target symbol:
  // If the user specified a tradingSymbol, respect their choice completely (no forced suffixes!)
  let targetSymbol = (account.tradingSymbol || "").trim();
  if (targetSymbol) {
    targetSymbol = normalizeSymbolCase(targetSymbol);
  } else {
    // Only if tradingSymbol was completely empty/omitted, infer sensible default:
    const accHint = `${account.accountName || ""} ${account.server || ""} ${account.broker || ""}`.toLowerCase();
    if (accHint.includes("zero") || accHint.includes(" 0")) {
      targetSymbol = "XAUUSDz";
    } else if (accHint.includes("cent") || accHint.includes("micro")) {
      targetSymbol = "XAUUSDm";
    } else {
      targetSymbol = "XAUUSD";
    }
  }

  console.log(`[Launcher] Account ${account.accountNumber} resolved target symbol: '${targetSymbol}'`);

  // Deep clean any old charts across all profile directories so MT5 opens strictly ONE clean chart from [StartUp]
  const profilesDir = path.join(instanceDir, "MQL5", "Profiles", "Charts");
  try {
    if (fs.existsSync(profilesDir)) {
      const subdirs = fs.readdirSync(profilesDir);
      for (const subdir of subdirs) {
        const fullSubdir = path.join(profilesDir, subdir);
        if (fs.statSync(fullSubdir).isDirectory()) {
          const files = fs.readdirSync(fullSubdir);
          for (const file of files) {
            if (file.toLowerCase().endsWith(".chr") || file.toLowerCase().endsWith(".wnd")) {
              fs.unlinkSync(path.join(fullSubdir, file));
            }
          }
        }
      }
    }
  } catch {}

  // Copy compiled EA to instance experts directories (both MQL5/Experts and MQL5/Experts/BFX)
  const rootExpertsDir = path.join(instanceDir, "MQL5", "Experts");
  const baseRootExperts = path.join(baseTerminalDir, "MQL5", "Experts");
  const baseBfxDir = path.join(baseRootExperts, "BFX");
  fs.mkdirSync(rootExpertsDir, { recursive: true });
  fs.mkdirSync(baseRootExperts, { recursive: true });
  fs.mkdirSync(baseBfxDir, { recursive: true });

  try {
    const localMql5Dir = path.join(__dirname, "..", "mql5", "BfxBridge.ex5");
    const cwdMql5Dir = path.join(process.cwd(), "mql5", "BfxBridge.ex5");
    const baseBfxEx5 = path.join(baseBfxDir, "BfxBridge.ex5");
    const baseRootEx5 = path.join(baseRootExperts, "BfxBridge.ex5");

    let sourceEx5: string | null = null;
    if (fs.existsSync(localMql5Dir)) sourceEx5 = localMql5Dir;
    else if (fs.existsSync(cwdMql5Dir)) sourceEx5 = cwdMql5Dir;
    else if (fs.existsSync(baseBfxEx5)) sourceEx5 = baseBfxEx5;
    else if (fs.existsSync(baseRootEx5)) sourceEx5 = baseRootEx5;

    if (sourceEx5) {
      fs.copyFileSync(sourceEx5, path.join(expertsDir, "BfxBridge.ex5"));
      fs.copyFileSync(sourceEx5, path.join(rootExpertsDir, "BfxBridge.ex5"));
      fs.copyFileSync(sourceEx5, path.join(baseBfxDir, "BfxBridge.ex5"));
      fs.copyFileSync(sourceEx5, path.join(baseRootExperts, "BfxBridge.ex5"));
    }
  } catch {
    // Best-effort copy
  }

  // 1. Copy common.ini from mt5_cache or base so encrypted WebRequestUrl and Expert settings are preserved
  const commonIniPath = path.join(configDir, "common.ini");
  const baseConfigDir = path.join(baseTerminalDir, "config");
  const cacheCommonIni = path.join(__dirname, "..", "mt5_cache", "config", "common.ini");
  const baseCommonIni = path.join(baseConfigDir, "common.ini");

  if (fs.existsSync(cacheCommonIni)) {
    fs.copyFileSync(cacheCommonIni, commonIniPath);
  } else if (fs.existsSync(baseCommonIni)) {
    fs.copyFileSync(baseCommonIni, commonIniPath);
  }

  // 2. Write BfxBridge.set preset file for MT5 [StartUp] ExpertParameters
  const setBuffer = buildExpertParamsBuffer(config.backendBaseUrl, account.id);
  fs.writeFileSync(path.join(presetsDir, "BfxBridge.set"), setBuffer);
  fs.writeFileSync(path.join(instanceDir, "BfxBridge.set"), setBuffer);
  fs.writeFileSync(path.join(basePresetsDir, "BfxBridge.set"), setBuffer);

  // 3. Write single UTF-16LE chart file with auto-loaded EA for the target Gold symbol
  const chartBuffer = buildDefaultChartBuffer(config.backendBaseUrl, account.id, targetSymbol);
  const chartPath = path.join(chartsDir, "chart01.chr");
  fs.writeFileSync(chartPath, chartBuffer);

  // Also write chart file to base MT5 profile
  try {
    const baseChartsDir = path.join(baseTerminalDir, "MQL5", "Profiles", "Charts", "Default");
    fs.mkdirSync(baseChartsDir, { recursive: true });
    const baseFiles = fs.readdirSync(baseChartsDir);
    for (const file of baseFiles) {
      if (file.toLowerCase().endsWith(".chr") && file !== "chart01.chr") {
        fs.unlinkSync(path.join(baseChartsDir, file));
      }
    }
    fs.writeFileSync(path.join(baseChartsDir, "chart01.chr"), chartBuffer);
  } catch {
    // Best-effort copy to base
  }

  // Copy network cache (servers.dat, dnsperf.dat) into instance config so broker discovery is instant
  if (fs.existsSync(baseConfigDir)) {
    for (const f of ["servers.dat", "dnsperf.dat"]) {
      const src = path.join(baseConfigDir, f);
      const dst = path.join(configDir, f);
      if (fs.existsSync(src) && !fs.existsSync(dst)) {
        try { fs.copyFileSync(src, dst); } catch {}
      }
    }
  }

  // Copy bases directory into instance dir
  const baseBasesDir = path.join(baseTerminalDir, "bases");
  const instanceBasesDir = path.join(instanceDir, "bases");
  if (fs.existsSync(baseBasesDir) && !fs.existsSync(instanceBasesDir)) {
    try {
      fs.cpSync(baseBasesDir, instanceBasesDir, { recursive: true });
    } catch {}
  }

  // Copy Templates directory into instance MQL5, and ensure default.tpl has BfxBridge auto-attached
  const baseTemplatesDir = path.join(baseTerminalDir, "MQL5", "Profiles", "Templates");
  const instanceTemplatesDir = path.join(instanceDir, "MQL5", "Profiles", "Templates");
  fs.mkdirSync(instanceTemplatesDir, { recursive: true });
  fs.mkdirSync(baseTemplatesDir, { recursive: true });
  if (fs.existsSync(baseTemplatesDir)) {
    try {
      fs.cpSync(baseTemplatesDir, instanceTemplatesDir, { recursive: true });
    } catch {}
  }

  // Write default.tpl with BfxBridge so ANY opened chart auto-attaches BfxBridge
  const tplBuffer = buildDefaultChartBuffer(config.backendBaseUrl, account.id, targetSymbol);
  try {
    fs.writeFileSync(path.join(instanceTemplatesDir, "default.tpl"), tplBuffer);
    fs.writeFileSync(path.join(baseTemplatesDir, "default.tpl"), tplBuffer);
  } catch {}

  // RULE: MT5 forbids multiple instances running out of the same directory in portable mode.
  // We hardlink/copy terminal64.exe directly into instanceDir so each account has its own isolated executable root.
  const instanceExePath = path.join(instanceDir, "terminal64.exe");
  if (!fs.existsSync(instanceExePath) && fs.existsSync(config.terminalExePath)) {
    try {
      fs.linkSync(config.terminalExePath, instanceExePath);
    } catch {
      try {
        fs.copyFileSync(config.terminalExePath, instanceExePath);
      } catch (err) {
        console.warn("[Launcher] Could not link/copy terminal64.exe to instance dir:", err);
      }
    }
  }

  const targetExe = fs.existsSync(instanceExePath) ? instanceExePath : config.terminalExePath;
  const winTargetExe = config.isWine
    ? `Z:${targetExe.replace(/\//g, "\\")}`
    : targetExe;

  // 4. Write transient account.ini with strict 0600 file permissions and persistent profile loading
  const accountIniPath = path.join(instanceDir, "account.ini");
  const safePassword = decryptedPassword || "";

  const initialIniContent = `[Common]
Login=${account.accountNumber}
Password=${safePassword}
Server=${account.server}
EnableNews=0

[Charts]
ProfileLast=Default

[StartUp]
ShutdownTerminal=0

[Experts]
AllowDll=1
Enabled=1
Account=0
Profile=0
`;

  fs.writeFileSync(accountIniPath, initialIniContent, { mode: 0o600 });

  // Convert account.ini path to Windows drive format (Z:\path\to\account.ini) for Wine
  const winAccountIniPath = config.isWine
    ? `Z:${accountIniPath.replace(/\//g, "\\")}`
    : accountIniPath;

  // 3. Prepare spawn arguments
  let child: ChildProcess;

  if (config.isWine) {
    const wineBin = config.wineBinPath || "wine";
    const activeDisplay = getDisplayEnv();

    const spawnEnv = {
      ...process.env,
      DISPLAY: activeDisplay,
      WINEPREFIX: config.winePrefix || "",
      WINEDEBUG: "-all", // Suppress noisy Wine debug logs
    };

    // On Apple Silicon (arm64), Wine is an x86_64 binary. Calling spawn directly from an arm64
    // Node.js process causes macOS posix_spawnp to throw EBADARCH (errno -86: 'Bad CPU type in executable').
    // Prepending '/usr/bin/arch -x86_64' routes execution directly through Rosetta 2.
    const isMacArm64 = process.platform === "darwin" && process.arch === "arm64";
    const spawnBin = isMacArm64 ? "/usr/bin/arch" : wineBin;
    const spawnArgs = isMacArm64
      ? ["-x86_64", wineBin, winTargetExe, "/portable", `/config:${winAccountIniPath}`]
      : [winTargetExe, "/portable", `/config:${winAccountIniPath}`];

    child = spawn(
      spawnBin,
      spawnArgs,
      {
        cwd: instanceDir,
        env: spawnEnv,
        stdio: "ignore", // Prevent terminal output from leaking passwords into logs
        detached: false,
      }
    );
  } else {
    // Windows Native
    child = spawn(
      targetExe,
      ["/portable", `/config:${accountIniPath}`],
      {
        cwd: instanceDir,
        stdio: "ignore",
        detached: false,
      }
    );
  }

  // 4. RULE: Ephemeral Password Wipe
  // Overwrite the password field in account.ini after MT5 has finished handshaking (after 60 seconds)
  setTimeout(() => {
    try {
      if (fs.existsSync(accountIniPath)) {
        const sanitizedIni = `[Common]
Login=${account.accountNumber}
Password=
Server=${account.server}
EnableNews=0

[Charts]
ProfileLast=Default

[Experts]
AllowDll=1
Enabled=1
Account=0
Profile=0
WebRequest=1
WebRequestUrl=${config.backendBaseUrl},http://localhost:3000,http://127.0.0.1:3000
`;
        fs.writeFileSync(accountIniPath, sanitizedIni, { mode: 0o600 });
      }
    } catch {
      // Best-effort overwrite
    }
  }, 60000);

  return {
    accountId: account.id,
    accountNumber: account.accountNumber,
    instanceDir,
    pid: child.pid,
    process: child,
    startedAt: new Date(),
    status: "STARTING",
  };
}
