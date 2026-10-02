# BfxBridge MT5 Bridge Agent / Terminal Manager

The **BfxBridge MT5 Bridge Agent** is an autonomous daemon responsible for supervising local MetaTrader 5 terminal instances. It eliminates manual terminal logins, manages isolated instances per account, auto-launches the `BfxBridge` Expert Advisor, and reports real-time telemetry back to BfxBridge.

---

## Architecture Flow

```
Customer enters credentials on BfxBridge
       ↓
Backend encrypts credentials (AES-256-GCM)
       ↓
Bridge Agent polls /api/mt5/bridge-agent/accounts
       ↓
Bridge Agent decrypts password in-memory
       ↓
Provisions isolated directory: /mt5-instances/<accountId>/
       ↓
Launches terminal64.exe /portable /config:account.ini
       ↓
MT5 automatically logs in & loads BfxBridge EA
       ↓
Transient account.ini password is wiped from disk
       ↓
EA sends verified heartbeat (login, server, algoTrading)
       ↓
Account transitions to READY_TO_TRADE
```

---

## Security Guarantees

1. **Zero Customer Manual Intervention**: Customers enter credentials once on the website. No manual terminal login or EA attachment is needed.
2. **Ephemeral Password Lifecycle**: The password is decrypted in-memory only when writing the transient `account.ini` with `0600` permissions. It is wiped and overwritten immediately after terminal startup.
3. **Strict Account Isolation**: Every MT5 account runs inside its own isolated working directory with dedicated chart profiles, logs, and processes.
4. **Outbound Only**: The agent initiates outbound HTTPS requests to BfxBridge. No incoming ports need to be opened on your VPS or router.

---

## Environment Variables

| Variable | Description | Default |
| :--- | :--- | :--- |
| `BFX_BASE_URL` | BfxBridge Next.js Backend URL | `http://localhost:3000` |
| `BRIDGE_AGENT_SECRET` | Shared secret with BfxBridge backend | `bfxbridge-secure-bridge-agent-secret-key-salt` |
| `ENCRYPTION_KEY` | Master credential encryption key | (Fallback salt) |
| `MT5_INSTANCES_DIR` | Directory where isolated instances are stored | `./bridge-agent/instances` |
| `MT5_TERMINAL_PATH` | Path to `terminal64.exe` | Auto-detected |
| `POLL_INTERVAL_MS` | Account synchronization interval (ms) | `3000` |

---

## Running on Mac (Wine Development)

1. Ensure MetaTrader 5 is installed in Wine or `/Applications/MetaTrader 5.app`.
2. Start the agent from the project root:
   ```bash
   npm run agent
   ```
3. The agent will automatically detect Wine and launch isolated terminal instances.

---

## Production Deployment (Windows VPS)

1. Clone or copy the repository onto your Windows VPS:
   ```powershell
   git clone https://github.com/Beatitude-N/bfx-trading-bridge.git
   cd bfx-trading-bridge
   npm install
   ```
2. Configure `.env.local` or environment variables:
   ```env
   BFX_BASE_URL=https://your-production-domain.com
   BRIDGE_AGENT_SECRET=your-secure-agent-secret
   ENCRYPTION_KEY=your-strong-encryption-key
   MT5_TERMINAL_PATH=C:\Program Files\MetaTrader 5\terminal64.exe
   ```
3. Start the daemon (or use PM2 / Windows Service):
   ```powershell
   npm run agent
   ```
