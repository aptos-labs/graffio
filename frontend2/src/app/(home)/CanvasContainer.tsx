"use client";

import dynamic from "next/dynamic";
import { useEffect, useState } from "react";
import useMeasure from "react-use-measure";
import { css } from "styled-system/css";
import { flex } from "styled-system/patterns";

import { CanvasOverlay } from "@/components/CanvasOverlay";
import { Skeleton } from "@/components/Skeleton";
import { toast } from "@/components/Toast";
import { PIXELS_PER_SIDE } from "@/constants/canvas";
import { APP_CONFIG } from "@/constants/config";
import { useAptosNetworkState } from "@/contexts/wallet";
import { isServer } from "@/utils/isServer";
import { getPixelArrayFromImageElement } from "@/utils/tempCanvas";

export function CanvasContainer() {
  const [canvasContainer, containerBounds] = useMeasure();
  const network = useAptosNetworkState((s) => s.network);
  const { height, width } = containerBounds;
  const hasSize = Boolean(height && width);

  const [baseImage, setBaseImage] = useState<Uint8ClampedArray>();

  useEffect(() => {
    if (isServer()) return;

    // The image is now a static asset bundled with the site.
    const img = new Image();
    img.src = APP_CONFIG[network].canvasImageUrl;
    img.onload = () => {
      const [pixelArray, cleanUp] = getPixelArrayFromImageElement(img, PIXELS_PER_SIDE);
      if (pixelArray) setBaseImage(pixelArray);
      cleanUp();
    };
  }, [network]);

  const [isCursorInBounds, setIsCursorInBounds] = useState(false);

  useEffect(() => {
    // This will only be set if need to pause the event in case of an emergency
    if (process.env.NEXT_PUBLIC_PAUSE_EVENT) {
      toast({
        id: "drawing-disabled",
        variant: "warning",
        content: "Drawing is temporarily paused",
        duration: null,
      });

      window.setTimeout(() => {
        window.location.reload();
      }, 60_000);
    }
  }, []);

  return (
    <div
      ref={canvasContainer}
      onMouseEnter={() => {
        setIsCursorInBounds(true);
      }}
      onMouseLeave={() => {
        setIsCursorInBounds(false);
      }}
      className={flex({
        position: "relative",
        height: "100%",
        width: "100%",
        justify: "center",
        overflow: "hidden",
        rounded: "md",
      })}
    >
      {hasSize && baseImage ? (
        <Canvas
          height={height}
          width={width}
          baseImage={baseImage}
          isCursorInBounds={isCursorInBounds}
        />
      ) : (
        canvasSkeleton
      )}
      <CanvasOverlay />
    </div>
  );
}

const Canvas = dynamic(
  async () => {
    const { Canvas } = await import("@/components/Canvas");
    return { default: Canvas };
  },
  {
    loading: () => canvasSkeleton,
    ssr: false,
  },
);

const canvasSkeleton = (
  <Skeleton key="canvas-skeleton" className={css({ h: "100%", w: "100%", rounded: "md" })} />
);
