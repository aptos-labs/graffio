use anyhow::{bail, Context as AnyhowContext, Result};
use aptos_move_graphql_scalars::Address;
use aptos_processor_framework::{
    indexer_protos::transaction::v1::{
        transaction::TxnData, transaction_payload::Payload, EntryFunctionId, MoveModuleId,
        MoveStructTag, Transaction,
    },
    txn_parsers::get_clean_entry_function_payload,
    ProcessingResult, ProcessorTrait,
};
use metadata_storage::{MetadataStorageTrait, UpdateAttributionIntent};
use move_types::Object;
use pixel_storage::{HardcodedColor, PixelStorageTrait, WritePixelIntent};
use serde::{Deserialize, Serialize};
use std::{str::FromStr, sync::Arc};
use tracing::info;

const CANVAS_TOKEN_MODULE_NAME: &str = "canvas_token";

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CanvasProcessorConfig {
    // TODO: This should be an Address instead
    pub canvas_contract_address: String,

    /// If set, disable metadata processing and only process pixel data.
    #[serde(default)]
    pub disable_metadata_processing: bool,

    /// If set, disable pixel processing and only process metadata.
    #[serde(default)]
    pub disable_pixel_processing: bool,
}

#[derive(Debug)]
pub struct CanvasProcessor {
    config: CanvasProcessorConfig,
    pixels_storage: Arc<dyn PixelStorageTrait>,
    metadata_storage: Arc<dyn MetadataStorageTrait>,
}

impl CanvasProcessor {
    pub fn new(
        config: CanvasProcessorConfig,
        pixels_storage: Arc<dyn PixelStorageTrait>,
        metadata_storage: Arc<dyn MetadataStorageTrait>,
    ) -> Result<Self> {
        if config.disable_metadata_processing && config.disable_pixel_processing {
            bail!("disable_metadata_processing and disable_pixel_processing are both set to true, this is invalid");
        }
        Ok(Self {
            config,
            pixels_storage,
            metadata_storage,
        })
    }

    pub fn get_canvas_struct_tag(&self) -> MoveStructTag {
        MoveStructTag {
            address: self.config.canvas_contract_address.clone(),
            module: CANVAS_TOKEN_MODULE_NAME.to_string(),
            name: "Canvas".to_string(),
            generic_type_params: vec![],
        }
    }
}

/// A processor that just prints the txn version.
#[async_trait::async_trait]
impl ProcessorTrait for CanvasProcessor {
    fn name(&self) -> &'static str {
        "CanvasProcessor"
    }

    async fn process_transactions(
        &self,
        transactions: Vec<Transaction>,
        start_version: u64,
        end_version: u64,
    ) -> Result<ProcessingResult> {
        let mut all_write_pixel_intents = Vec::new();
        let mut all_update_attribution_intents = Vec::new();
        for transaction in transactions {
            // Skip failed transactions.
            if let Some(info) = &transaction.info {
                if !info.success {
                    continue;
                }
            }

            // todo process canvas_token::create and create images for that
            // todo create a storage interface with like create that takes in a default color
            // a width and height, then methods for writing pixels to it, and also reading
            // the full thing. it should handle the read update write process inside it
            let (write_pixel_intents, update_attribution_intents) =
                self.process_draw(&transaction).context(format!(
                    "Failed at process_draw for txn version {}",
                    transaction.version
                ))?;
            all_write_pixel_intents.extend(write_pixel_intents);
            all_update_attribution_intents.extend(update_attribution_intents);
        }
        info!(
            start_version = start_version,
            end_version = end_version,
            processor_name = self.name(),
            num_pixels_to_write = all_write_pixel_intents.len()
        );

        if !self.config.disable_pixel_processing {
            // Write pixels.
            if !all_write_pixel_intents.is_empty() {
                info!(
                    "Writing {} pixels (from txns {} to {})",
                    all_write_pixel_intents.len(),
                    start_version,
                    end_version
                );
                self.pixels_storage
                    .write_pixels(all_write_pixel_intents)
                    .await
                    .context("Failed to write pixel in storage")?;
            }
        }

        Ok((start_version, end_version))
    }
}

impl CanvasProcessor {
    fn process_draw(
        &self,
        transaction: &Transaction,
    ) -> Result<(Vec<WritePixelIntent>, Vec<UpdateAttributionIntent>)> {
        let nothing = Ok((vec![], vec![]));

        // Skip this transaction if this wasn't a draw transaction.
        let draw_function_id = EntryFunctionId {
            module: Some(MoveModuleId {
                address: self.config.canvas_contract_address.clone(),
                name: CANVAS_TOKEN_MODULE_NAME.to_string(),
            }),
            name: "draw".to_string(),
        };
        if !entry_function_id_matches(transaction, &draw_function_id) {
            return nothing;
        }

        let txn_data = transaction.txn_data.as_ref().context("No txn_data")?;

        let user_transaction = match txn_data {
            TxnData::User(user_transaction) => user_transaction,
            _ => return nothing,
        };

        let request = user_transaction.request.as_ref().context("No request")?;
        let payload = request.payload.as_ref().unwrap();
        let entry_function_payload = match payload.payload.as_ref().context("No payload")? {
            Payload::EntryFunctionPayload(payload) => payload,
            _ => return nothing,
        };

        let clean_entry_function_payload =
            get_clean_entry_function_payload(entry_function_payload, 0);

        let first_arg = clean_entry_function_payload.arguments[0].clone();

        let obj: Object = serde_json::from_value(first_arg).context("Failed to parse as Object")?;
        let canvas_address = obj.inner;

        let sender =
            Address::from_str(&request.sender).context("Failed to parse sender address")?;

        let payload = match request.payload.as_ref().unwrap().payload.as_ref().unwrap() {
            Payload::EntryFunctionPayload(payload) => payload,
            _ => return nothing,
        };

        let xs: Vec<u16> = serde_json::from_str(&payload.arguments[1]).unwrap();
        let ys: Vec<u16> = serde_json::from_str(&payload.arguments[2]).unwrap();
        let colors_str: String = serde_json::from_str(&payload.arguments[3]).unwrap();
        let colors: Vec<u8> = hex::decode(&colors_str[2..]).unwrap();

        let mut write_pixel_intents = vec![];

        for i in 0..xs.len() {
            let x = xs[i];
            let y = ys[i];
            let color = colors[i];

            let index = (y as u32) * 1000 + (x as u32);

            write_pixel_intents.push(WritePixelIntent {
                canvas_address,
                user_address: sender,
                index,
                color: HardcodedColor::from(color),
            });
        }

        Ok((write_pixel_intents, vec![]))
    }
}

fn entry_function_id_matches(
    transaction: &Transaction,
    entry_function_id: &EntryFunctionId,
) -> bool {
    let txn_data = transaction
        .txn_data
        .as_ref()
        .context("No txn_data")
        .unwrap();
    let user_transaction = match txn_data {
        TxnData::User(user_transaction) => user_transaction,
        _ => return false,
    };
    let request = user_transaction
        .request
        .as_ref()
        .context("No request")
        .unwrap();
    let payload = request.payload.as_ref().unwrap();
    let entry_function_payload = match payload.payload.as_ref().context("No payload").unwrap() {
        Payload::EntryFunctionPayload(payload) => payload,
        _ => return false,
    };

    let function_id = entry_function_payload
        .function
        .as_ref()
        .context("No function")
        .unwrap();

    function_id == entry_function_id
}

// Functions we need:
// - Make it easier to pull out the entry function payload, one function.
// - Something like get_clean_* for each of the Change:: variants, like WriteTableData.
// - This entry_function_id_matches function above.
