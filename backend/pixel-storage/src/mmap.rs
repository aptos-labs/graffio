use super::{utils::get_image, CreateCanvasIntent, PixelStorageTrait, WritePixelIntent};
use crate::{HardcodedColor, RgbColor};
use anyhow::{Context, Result};
use aptos_move_graphql_scalars::Address;
use memmap2::MmapMut;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs::{File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    str::FromStr,
    sync::Arc,
};
use tokio::sync::Mutex;
use tracing::{error, info};

// There could be an alternate implementation where instead of using the mmap, for
// every pixel we read the png, update the pixel, and write the png back to disk.
// This would be slower and result in more disk IO but use less storage and memory.

// Note: The POSIX standard states that when a process dies, no matter how (even if
// it receives SIGKILL) the kernel will eventually flush all the writes in the mmap
// to disk, as long as the mmap is created using MAP_SHARED (which it is, because we
// use `map_mut` when creating the mmap). So there should be no need to manually flush
// the mmap on shutdown.

// Note: Everything we do here is synchronous, so we could consider making the trait
// require non async functions. If that were the case, we could safely use std Mutex
// instead of tokio Mutex. Given the function is async, even if now it would be safe
// to use std Mutex because there are no awaits, it's possible in the future we'll add
// one and then hold the std Mutex across an await point, which is not safe. So just to
// be defensive we use tokio Mutex.

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct MmapPixelStorageConfig {
    pub storage_directory: PathBuf,
}

/// Handles creating, updating, and reading canvases.
#[derive(Debug)]
pub struct MmapPixelStorage {
    config: MmapPixelStorageConfig,
    mmaps: Arc<Mutex<HashMap<Address, MmapMut>>>,
    //     mmaps: Arc<HashMap<Address, Mutex<HashMap<Address, MmapMut>>>>,
}

impl MmapPixelStorage {
    pub fn new(config: MmapPixelStorageConfig) -> Self {
        Self {
            config,
            mmaps: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn get_filename(&self, user_address: &Address) -> PathBuf {
        Path::new(&self.config.storage_directory)
            .join(format!("0x{}.canvas", user_address.to_canonical_string()))
    }
}

#[async_trait::async_trait]
impl PixelStorageTrait for MmapPixelStorage {
    /// Create a canvas as a file on disk. We use a custom format where each pixel is
    /// stored as 3 bytes (r, g, b) and the width and height are stored at the end of
    /// the file as 8 bytes each.
    async fn create_canvas(&self, intent: CreateCanvasIntent) -> Result<()> {
        let filename = self.get_filename(&intent.user_address);
        info!("Creating canvas file: {:?}", filename.display());
        let mut file = File::create(&filename)?;

        let width = intent.width as u64;
        let height = intent.height as u64;

        // Calculate the total number of pixels
        let num_pixels = width * height;

        // Build all the data into a single vector.
        let mut data = Vec::with_capacity(num_pixels as usize * 3);
        for _ in 0..num_pixels {
            // We don't use the hardcoded colors at our level, we convert
            // them into proper rgb colors.
            let color = RgbColor::from(&intent.default_color);
            data.push(color.r);
            data.push(color.g);
            data.push(color.b);
        }

        // Put the width and height at the end of the file.
        data.extend(width.to_le_bytes());
        data.extend(height.to_le_bytes());

        // Write the data to the file.
        file.write_all(&data)?;

        info!("Created canvas file: {:?}", filename.display());

        Ok(())
    }

    async fn write_pixels(&self, intents: Vec<WritePixelIntent>) -> Result<()> {
        let canvas_address_filter =
            Address::from_str("0x5d45bb2a6f391440ba10444c7734559bd5ef9053930e3ef53d05be332518522b")
                .unwrap();
        // Create a map of canvas address to intents.
        let mut user_address_to_intents = HashMap::new();
        for intent in intents.into_iter() {
            if intent.canvas_address != canvas_address_filter {
                continue;
            }
            user_address_to_intents
                .entry(intent.user_address)
                .or_insert_with(Vec::new)
                .push(intent);
        }

        for (user_address, intents) in user_address_to_intents.into_iter() {
            let intents_len = intents.len();
            info!(
                "Will write {} pixels to canvas {}",
                intents_len, user_address,
            );

            // Get an existing mmap for the canvas file or initialize a new one.
            let mut mmaps = self.mmaps.lock().await;

            if !mmaps.contains_key(&user_address) {
                match self
                    .create_canvas(CreateCanvasIntent {
                        user_address,
                        width: 1000,
                        height: 1000,
                        default_color: HardcodedColor::White,
                    })
                    .await
                {
                    Ok(_) => {},
                    Err(e) => {
                        error!("Failed to create canvas {}: {}", user_address, e);
                        panic!("Failed to create canvas {}: {}", user_address, e);
                    },
                }
            }

            let mmap = mmaps.entry(user_address).or_insert_with(|| {
                let filename = self.get_filename(&user_address);
                let file = match OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create(false)
                    .open(&filename)
                {
                    Ok(file) => file,
                    Err(e) => {
                        error!("Failed to open file {}: {}", filename.display(), e);
                        panic!("Failed to open file {}: {}", filename.display(), e);
                    },
                };
                unsafe { MmapMut::map_mut(&file).expect("Failed to mmap file") }
            });

            info!(
                "Got mmap, will write {} pixels to canvas {}",
                intents_len, user_address,
            );

            // Write the pixels to the file through the mmap.
            for intent in intents {
                // We don't use the hardcoded colors at our level, we convert
                // them into proper rgb colors.
                let index = intent.index as usize;
                let color = RgbColor::from(&intent.color);
                mmap[index * 3] = color.r;
                mmap[index * 3 + 1] = color.g;
                mmap[index * 3 + 2] = color.b;
            }

            info!(
                "Wrote {} pixels to user canvas {}",
                intents_len, user_address
            );
        }

        Ok(())
    }

    async fn get_canvas_as_png(&self, user_address: &Address) -> Result<Vec<u8>> {
        let (data, width, height) = {
            let mmaps = self.mmaps.lock().await;
            let mmap = mmaps.get(user_address).context("Failed to find canvas")?;

            // Get the width and height from the end of the file.
            let (width, height) =
                read_width_and_height(mmap).context("Failed to read width and height")?;

            // Read the data from the file as a vector of RgbColors.
            let mut data = Vec::with_capacity((width * height) as usize);
            for i in 0..width * height {
                let index = i as usize;
                data.push(RgbColor {
                    r: mmap[index * 3],
                    g: mmap[index * 3 + 1],
                    b: mmap[index * 3 + 2],
                });
            }
            (data, width, height)
        };

        // Convert the data to a png.
        let png = get_image(data, width as u32, height as u32)
            .context("Failed to convert data to a png")?;

        Ok(png)
    }

    /// This function returns all the canvases in the mmap as pngs. We use this for the
    /// flusher, which takes the local mmap data and writes it to an external location
    /// as PNGs. One thing worth noting is `mmaps` doesn't contain every file on disk,
    /// only those written to at least once since startup. This is actually fine for
    /// use in the flusher, since if nothing has been written since startup, there is
    /// also nothing to flush.
    async fn get_canvases_as_pngs(&self) -> Result<HashMap<Address, Vec<u8>>> {
        let mut pngs = HashMap::new();
        let addresses = {
            let mmaps = self.mmaps.lock().await;
            mmaps.iter().map(|mmap| *mmap.0).collect::<Vec<_>>()
        };
        for address in addresses {
            let png = self
                .get_canvas_as_png(&address)
                .await
                .context(format!("Failed to get canvas {} as a png", address))?;
            pngs.insert(address, png);
        }
        Ok(pngs)
    }
}

/// Read the width and height from the end of the file.
fn read_width_and_height(mmap: &MmapMut) -> Result<(u64, u64)> {
    let len = mmap.len();
    if len < 16 {
        anyhow::bail!("File is too short to contain width and height");
    }

    let width_bytes: [u8; 8] = mmap[len - 16..len - 8]
        .try_into()
        .context("Failed to read width")?;
    let height_bytes: [u8; 8] = mmap[len - 8..len]
        .try_into()
        .context("Failed to read height")?;

    let width = u64::from_le_bytes(width_bytes);
    let height = u64::from_le_bytes(height_bytes);

    Ok((width, height))
}
