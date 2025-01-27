//! `SeaORM` Entity. Generated by sea-orm-codegen 0.12.2

use sea_orm::entity::prelude::*;

#[derive(Clone, Debug, PartialEq, DeriveEntityModel, Eq)]
#[sea_orm(table_name = "pixel_attribution")]
pub struct Model {
    #[sea_orm(primary_key, auto_increment = false)]
    pub index: i64,
    #[sea_orm(primary_key, auto_increment = false)]
    pub canvas_address: String,
    pub artist_address: String,
    pub drawn_at_secs: i64,
}

#[derive(Copy, Clone, Debug, EnumIter, DeriveRelation)]
pub enum Relation {}

impl ActiveModelBehavior for ActiveModel {}

#[derive(Copy, Clone, Debug, EnumIter, DeriveRelatedEntity)]
pub enum RelatedEntity {}
