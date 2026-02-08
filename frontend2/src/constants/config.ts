import { NetworkName } from "@aptos-labs/wallet-adapter-react";

import { SupportedNetworkName } from "@/contexts/wallet";

interface AppConfig {
  canvasAddr: `0x${string}`;
  canvasTokenAddr: `0x${string}`;
  canvasImageUrl: string;
  rpcUrl: string;
}

export const APP_CONFIG: Record<SupportedNetworkName, AppConfig> = {
  [NetworkName.Mainnet]: {
    canvasAddr: "0x915efe6647e0440f927d46e39bcb5eb040a7e567e1756e002073bc6e26f2cd23",
    canvasTokenAddr: "0x5d45bb2a6f391440ba10444c7734559bd5ef9053930e3ef53d05be332518522b",
    canvasImageUrl: "/images/mainnet-canvas.png",
    rpcUrl: "https://fullnode.mainnet.aptoslabs.com/",
  },
  [NetworkName.Testnet]: {
    canvasAddr: "0x6b8169be66d9579ba9ad1192708edcf52de713d3513a431df6cb045f425d3d91",
    canvasTokenAddr: "0x8c654f4be9cefc3a7d0dfa0bda4ee19f75c926763e00f6534f3ab8b5c2ebcdea",
    canvasImageUrl: "/images/testnet-canvas.png",
    rpcUrl: "https://fullnode.testnet.aptoslabs.com/",
  },
};
