export type Mt5ConnectionStatus = "CONNECTED" | "DISCONNECTED" | "ERROR" | "CONNECTING";

export interface BridgeAgentAccountConfig {
  id: string;
  userId: string;
  accountName: string;
  accountNumber: string;
  broker: string;
  server: string;
  password?: string | null;
  status: "ACTIVE" | "INACTIVE";
  connectionStatus: Mt5ConnectionStatus;
  terminalStatus: "ONLINE" | "OFFLINE";
  eaStatus: "ONLINE" | "OFFLINE";
  algoTradingEnabled: boolean;
}
