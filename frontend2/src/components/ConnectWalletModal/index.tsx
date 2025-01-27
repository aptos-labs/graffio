"use client";

import { useWallet } from "@aptos-labs/wallet-adapter-react";
import { useEffect } from "react";
import { css } from "styled-system/css";

import { useCanvasState } from "@/contexts/canvas";
import { truncateAddress } from "@/utils/wallet";

import { removeToast, toast } from "../Toast";
import { openConnectWalletModal } from "./ConnectWalletModal";
import { openDisconnectWalletModal } from "./DisconnectWalletModal";
import { useCanDrawUnlimited } from "./useCanDrawUnlimited";

const CONNECT_TOAST_ID = "connect-wallet";

export function ConnectWalletButton() {
  const isCanvasInitialized = useCanvasState((s) => s.isInitialized);
  const isEventComplete = useCanvasState((s) => s.isEventComplete);
  const { disconnect, account, connected } = useWallet();

  useCanDrawUnlimited(account?.address);

  useEffect(
    function manageConnectWalletToast() {
      if (!isCanvasInitialized || isEventComplete || connected) return;

      toast({
        id: CONNECT_TOAST_ID,
        variant: "info",
        content: (
          <span>
            <button
              onClick={openConnectWalletModal}
              className={css({ color: "interactive.primary", cursor: "pointer" })}
            >
              Connect a Wallet
            </button>{" "}
            to draw on the canvas!
          </span>
        ),
        duration: null,
      });

      return () => {
        removeToast(CONNECT_TOAST_ID);
      };
    },
    [connected, isCanvasInitialized, isEventComplete],
  );

  return connected ? (
    <button
      className={buttonStyles}
      onClick={() => {
        openDisconnectWalletModal({ disconnect });
      }}
    >
      {account?.ansName || truncateAddress(account?.address) || "Unknown"}
    </button>
  ) : (
    <button className={buttonStyles} onClick={openConnectWalletModal}>
      Connect a Wallet
    </button>
  );
}

const buttonStyles = css({
  cursor: "pointer",
  textStyle: "body.md.regular",
  color: "interactive.primary",
  _hover: { color: "interactive.primary.hovered" },
  _active: { color: "interactive.primary.pressed" },
});
