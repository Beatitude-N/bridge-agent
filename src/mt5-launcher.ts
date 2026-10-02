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
 * Builds UTF-16LE chart file with auto-attached BfxBridge EA.
 */
function buildDefaultChartBuffer(backendUrl: string, accountId: string): Buffer {
  const chartContent =
    `<chart>
id=134329884593686340
symbol=XAUUSD
description=Gold vs US Dollar
period_type=0
period_size=1
digits=3
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
window_right=1200
window_bottom=800
window_type=1
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
name=BFX\\BfxBridge
flags=339
window_num=0
<inputs>
InpServerUrl=${backendUrl}
InpAccountId=${accountId}
InpMagicNumber=20260904
InpPollInterval=5
InpHeartbeatInterval=60
InpDeviation=20
</inputs>
</expert>
</window>
</chart>
`;

  return Buffer.from(chartContent, "utf16le");
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
  const configDir = path.join(instanceDir, "config");

  fs.mkdirSync(chartsDir, { recursive: true });
  fs.mkdirSync(expertsDir, { recursive: true });
  fs.mkdirSync(configDir, { recursive: true });

  // Copy compiled EA to instance experts directory
  try {
    const localMql5Dir = path.join(__dirname, "..", "mql5", "BfxBridge.ex5");
    const cwdMql5Dir = path.join(process.cwd(), "mql5", "BfxBridge.ex5");
    const baseTerminalDir = path.dirname(config.terminalExePath);
    const baseBfxEx5 = path.join(baseTerminalDir, "MQL5", "Experts", "BFX", "BfxBridge.ex5");

    if (fs.existsSync(localMql5Dir)) {
      fs.copyFileSync(localMql5Dir, path.join(expertsDir, "BfxBridge.ex5"));
    } else if (fs.existsSync(cwdMql5Dir)) {
      fs.copyFileSync(cwdMql5Dir, path.join(expertsDir, "BfxBridge.ex5"));
    } else if (fs.existsSync(baseBfxEx5)) {
      fs.copyFileSync(baseBfxEx5, path.join(expertsDir, "BfxBridge.ex5"));
    }
  } catch {
    // Best-effort copy
  }

  // 1. Write UTF-16LE common.ini with WebRequest enabled
  const commonIniPath = path.join(configDir, "common.ini");
  const commonIniContent = `[Common]\r\nLogin=0\r\n\r\n[Experts]\r\nAllowDllImport=1\r\nEnabled=1\r\nAccount=0\r\nProfile=0\r\nChart=0\r\nWebRequest=1\r\nWebRequestUrl=${config.backendBaseUrl},http://localhost:3000,http://127.0.0.1:3000\r\n`;
  fs.writeFileSync(commonIniPath, Buffer.from(commonIniContent, "utf16le"));

  // 2. Write UTF-16LE chart file with auto-loaded EA
  const chartPath = path.join(chartsDir, "chart01.chr");
  fs.writeFileSync(chartPath, buildDefaultChartBuffer(config.backendBaseUrl, account.id));

  // 3. Write transient account.ini with strict 0600 file permissions
  const accountIniPath = path.join(instanceDir, "account.ini");
  const safePassword = decryptedPassword || "";

  const initialIniContent = `[Common]
Login=${account.accountNumber}
Password=${safePassword}
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

  fs.writeFileSync(accountIniPath, initialIniContent, { mode: 0o600 });

  // 3. Prepare spawn arguments
  let child: ChildProcess;

  if (config.isWine) {
    const wineBin = config.wineBinPath || "wine";
    const terminalExe = config.terminalExePath;

    const spawnEnv = {
      ...process.env,
      DISPLAY: process.env.DISPLAY || ":99",
      WINEPREFIX: config.winePrefix || "",
      WINEDEBUG: "-all", // Suppress noisy Wine debug logs
    };

    // On Apple Silicon (arm64), Wine is an x86_64 binary. Calling spawn directly from an arm64
    // Node.js process causes macOS posix_spawnp to throw EBADARCH (errno -86: 'Bad CPU type in executable').
    // Prepending '/usr/bin/arch -x86_64' routes execution directly through Rosetta 2.
    const isMacArm64 = process.platform === "darwin" && process.arch === "arm64";
    const spawnBin = isMacArm64 ? "/usr/bin/arch" : wineBin;
    const spawnArgs = isMacArm64
      ? ["-x86_64", wineBin, terminalExe, "/portable", `/config:${accountIniPath}`]
      : [terminalExe, "/portable", `/config:${accountIniPath}`];

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
      config.terminalExePath,
      ["/portable", `/config:${accountIniPath}`],
      {
        cwd: instanceDir,
        stdio: "ignore",
        detached: false,
      }
    );
  }

  // 4. RULE: Ephemeral Password Wipe
  // Overwrite the password field in account.ini after MT5 has ingested it (after 5 seconds)
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
  }, 5000);

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
