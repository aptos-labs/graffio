mod mmap;
mod utils;

use anyhow::Result;
use aptos_move_graphql_scalars::Address;
pub use mmap::{MmapPixelStorage, MmapPixelStorageConfig};
use std::{collections::HashMap, fmt::Debug, ops::Add};

/// Handles creating, updating, and reading canvases.
#[async_trait::async_trait]
pub trait PixelStorageTrait: Debug + Send + Sync + 'static {
    async fn create_canvas(&self, intent: CreateCanvasIntent) -> Result<()>;
    async fn write_pixels(&self, intent: Vec<WritePixelIntent>) -> Result<()>;
    async fn get_canvas_as_png(&self, canvas_address: &Address) -> Result<Vec<u8>>;
    async fn get_canvases_as_pngs(&self) -> Result<HashMap<Address, Vec<u8>>>;
}

// In the contract we just use different int values to represent different colors,
// for the sake of optimization.
#[derive(Clone, Debug)]
pub enum HardcodedColor {
    Black = 0,
    White = 1,
    Blue = 2,
    Green = 3,
    Yellow = 4,
    Orange = 5,
    Red = 6,
    Violet = 7,
}

impl From<u8> for HardcodedColor {
    fn from(color: u8) -> Self {
        match color {
            0 => HardcodedColor::Black,
            1 => HardcodedColor::White,
            2 => HardcodedColor::Blue,
            3 => HardcodedColor::Green,
            4 => HardcodedColor::Yellow,
            5 => HardcodedColor::Orange,
            6 => HardcodedColor::Red,
            7 => HardcodedColor::Violet,
            _ => panic!("Invalid color: {}", color),
        }
    }
}

#[derive(Clone, Debug)]
pub struct RgbColor {
    r: u8,
    g: u8,
    b: u8,
}

impl From<&HardcodedColor> for RgbColor {
    fn from(color: &HardcodedColor) -> Self {
        match color {
            HardcodedColor::Black => RgbColor { r: 0, g: 0, b: 0 },
            HardcodedColor::White => RgbColor {
                r: 255,
                g: 255,
                b: 255,
            },
            HardcodedColor::Blue => RgbColor {
                r: 0,
                g: 158,
                b: 253,
            },
            HardcodedColor::Green => RgbColor { r: 0, g: 197, b: 3 },
            HardcodedColor::Yellow => RgbColor {
                r: 255,
                g: 198,
                b: 0,
            },
            HardcodedColor::Orange => RgbColor {
                r: 255,
                g: 125,
                b: 0,
            },
            HardcodedColor::Red => RgbColor {
                r: 250,
                g: 0,
                b: 106,
            },
            HardcodedColor::Violet => RgbColor {
                r: 196,
                g: 0,
                b: 199,
            },
        }
    }
}

/// All the information necessary to write a Pixel to storage.
#[derive(Clone, Debug)]
pub struct WritePixelIntent {
    /// The address of the object containing the canvas.
    pub canvas_address: Address,
    pub user_address: Address,
    pub index: u32,
    pub color: HardcodedColor,
}

/// All the information necessary to create a Canvas in storage.
#[derive(Clone, Debug)]
pub struct CreateCanvasIntent {
    /// The address of the object containing the canvas.
    pub user_address: Address,
    pub width: u16,
    pub height: u16,
    pub default_color: HardcodedColor,
}
