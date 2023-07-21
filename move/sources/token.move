// Copyright (c) Daniel Porteous
// SPDX-License-Identifier: Apache-2.0

//! See the README for more information about how this module works.
//!
//! In this module we intentionally do not emit events. The only real reason to emit
//! events is for the sake of indexing, but we can just process the writesets for that.

// todo idk whether to use vector or smart vector

// note, the plan for now is to have the collection be unlimited and allow anyone to
// mint, with the idea being that canvases should have value themselves rather than
// value through scarcity. perhaps a phase 2 release could be limited? who knows.

// this module could really benefit from allowing arbitrary drop structs as arguments
// to entry functions, e.g. CanvasConfig, Coords, Color, etc.

module addr::canvas_token {
    use addr::canvas_collection::{get_collection, get_collection_name};
    use std::error;
    use std::option::Self;
    use std::signer;
    use std::string::String;
    use std::vector;
    //use std::timestamp::now_seconds;
    use aptos_std::object::{Self, Object};
    use aptos_std::string_utils::format2;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_token_objects::collection::Self;
    use aptos_token_objects::token::Self;
    use dport_std::simple_set::{Self, SimpleSet};

    /// `default_color` was not in the palette.
    const E_CREATION_INITIAL_COLOR_NOT_IN_PALETTE: u64 = 1;

    /// The caller tried to draw outside the bounds of the canvas.
    const E_COORDINATE_OUT_OF_BOUNDS: u64 = 2;

    /// The caller tried to call a function that requires super admin privileges
    /// but they're not the super admin (the owner) or there is no super admin
    /// at all (as per owner_is_super_admin).
    const E_CALLER_NOT_SUPER_ADMIN: u64 = 2;

    /// The caller tried to call a function that requires admin privileges
    /// but they're not an admin / there are no admins at all.
    const E_CALLER_NOT_ADMIN: u64 = 3;

    /// `per_member_amount_octa` was zero.
    const E_CREATION_PlER_MEMBER_AMOUNT_ZERO: u64 = 3;

    /// `check_in_frequency_secs` was out of the accepted range.
    const E_CREATION_CHECK_IN_FREQUENCY_OUT_OF_RANGE: u64 = 4;

    /// `claim_window_secs` was too small. If the tontine is being configured to stake funds to a delegation pool, the claim window needs to be large enough to allow for unlocking the funds.
    const E_CREATION_CLAIM_WINDOW_TOO_SMALL: u64 = 5;

    /// `fallback_policy` was invalid.
    const E_CREATION_INVALID_FALLBACK_POLICY: u64 = 6;

    /// There was no delegation pool at the specified address.
    const E_CREATION_NO_DELEGATION_POOL: u64 = 7;

    /// The required minimum was too small to allow for staking. If staking, each member must contribute at least 20 APT / <number of members>.
    const E_CREATION_MINIMUM_TOO_SMALL: u64 = 8;

    /// Tried to interact with an account with no TontineStore.
    const E_TONTINE_STORE_NOT_FOUND: u64 = 10;

    /// Tried to get a Tontine from a TontineStore but there was nothing found with the requested index.
    const E_TONTINE_NOT_FOUND: u64 = 11;

    /// Tried to perform an action but the given caller is not in the tontine.
    const E_CALLER_NOT_IN_TONTINE: u64 = 12;

    /// Tried to perform an action that relies on the member having contributed a certain amount that they haven't actually contributed.
    const E_INSUFFICIENT_CONTRIBUTION: u64 = 13;

    /// Tried to lock the tontine but the conditions aren't yet met.
    const E_LOCK_CONDITIONS_NOT_MET: u64 = 14;

    /// Tried to perform an action but the given tontine is locked.
    const E_TONTINE_LOCKED: u64 = 15;

    /// Tried to perform an action but the caller was not the creator.
    const E_CALLER_IS_NOT_CREATOR: u64 = 16;

    /// Tried to perform an action that the creator is not allowed to take.
    const E_CALLER_IS_CREATOR: u64 = 17;

    /// Tried to add a member to the tontine but they were already in it.
    const E_MEMBER_ALREADY_IN_TONTINE: u64 = 18;

    /// Tried to remove a member from the tontine but they're not in it.
    const E_MEMBER_NOT_IN_TONTINE: u64 = 19;

    /// The creator tried to remove themselves from the tontine.
    const E_CREATOR_CANNOT_REMOVE_SELF: u64 = 20;

    /// The creator tried to contribute / withdraw zero OCTA.
    const E_AMOUNT_ZERO: u64 = 21;

    /// Someone tried to unlock funds but funds were never staked.
    const E_FUNDS_WERE_NOT_STAKED: u64 = 22;

    /// Tried to unlock staked funds but there was nothing to unlock.
    const E_NO_FUNDS_TO_UNLOCK: u64 = 23;

    /// Tried to withdraw staked funds but there was nothing withdrawable.
    const E_NO_FUNDS_TO_WITHDRAW: u64 = 24;

    /// todo
    const STATUS_ALLOWED: u8 = 1;

    const STATUS_IN_BLOCKLIST: u8 = 2;

    const STATUS_NOT_IN_ALLOWLIST: u8 = 3;

    /// The caller is not allowe to contribute to the canvas.
    const E_CALLER_IN_BLOCKLIST: u64 = 30;

    /// The caller is not in the allowlist for contributing to the canvas.
    const E_CALLER_NOT_IN_ALLOWLIST: u64 = 31;

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Canvas has key {
        /// The parameters used to configure default creation of the canvas.
        config: CanvasConfig,

        /// The pixels of the canvas.
        pixels: vector<Color>,

        /// When each artist last contributed. Only tracked if
        /// per_account_timeout_s is non-zero.
        last_contributions_s: SmartTable<address, u64>,

        /// Accounts that are allowed to contribute. If empty, anyone can contribute.
        /// One notable application of this list is the owner of the canvas, if
        /// owner_is_super_admin is true, can set just their own address here to
        /// effectively lock the canvas.
        allowlisted_artists: SimpleSet<address>,

        /// Accounts that are not allowed to contribute.
        blocklisted_artists: SimpleSet<address>,

        /// Accounts that have admin privileges. It is only possible to have admins if
        /// there is a super admin.
        admins: SimpleSet<address>,
    }

    struct CanvasConfig has store, drop {
        /// The width of the canvas.
        width: u32,

        /// The width of the canvas.
        height: u32,

        /// How long artists have to wait between contributions. If zero, when
        /// artists contribute is not tracked.
        per_account_timeout_s: u64,

        // todo, for this ^ perhaps instead of the canvas maintaining a table of when
        // people last contributed, we put a simplemap on the artist's account?
        // or perhaps we have a table and just allow the creator of the canvas to call
        // some function to prune it as appropriate, giving them a tasty gas refund.
        // for this to work the caller would have to determine which keys to wipe from
        // the outside, since you can't iterate through a table from in Move. this is
        // probably only possible with writeset analysis in a processor. alternatively
        // we could just let the owner wipe the table at will.
        // also, for everything where we care about creator, use owner instead.

        /// Allowed colors. If empty, all colors are allowed.
        palette: vector<Color>,

        /// How much it costs in OCTA to contribute.
        cost: u64,

        /// The default color of the pixels. If a paletter is set, this color must be a
        /// part of the palette.
        default_color: Color,

        /// Whether the owner of the canvas has super admin privileges. Super admin
        /// powers are the same as normal admin powers but in addition you have the
        /// ability to add / remove additional admins. Set at creation time and can
        /// never be changed.
        owner_is_super_admin: bool,
    }

    struct Color has copy, drop, store {
        r: u8,
        g: u8,
        b: u8,
    }

    /// Create a new canvas.
    public entry fun create(
        caller: &signer,
        // Arguments for the token + object.
        description: String,
        name: String,
        // Arguments for the canvas.
        width: u32,
        height: u32,
        per_account_timeout_s: u64,
        // Note, for now we don't allow setting palette because it's a pain
        cost: u64,
        default_color_r: u8,
        default_color_g: u8,
        default_color_b: u8,
        owner_is_super_admin: bool,
    ) {
        let config = CanvasConfig {
            width,
            height,
            per_account_timeout_s,
            palette: vector::empty(),
            cost,
            default_color: Color {
                r: default_color_r,
                g: default_color_g,
                b: default_color_b,
            },
            owner_is_super_admin,
        };
        create_(caller, description, name, config);
    }

    /// This function is separate from the top level create function so we can use it
    /// in tests. This is necessary because entry functions (correctly) cannot return
    /// anything but we need it to return the object with the canvas in it. They also
    /// cannot take in struct arguments, which again is convenient for testing.
    public fun create_(
        caller: &signer,
        description: String,
        name: String,
        config: CanvasConfig,
    ): Object<Canvas> {
        // If a palette is given, assert it contains the default color.
        if (!vector::is_empty(&config.palette)) {
            assert!(
                vector::contains(&config.palette, &config.default_color),
                error::invalid_argument(E_CREATION_INITIAL_COLOR_NOT_IN_PALETTE),
            );
        };

        // Get the collection, which we need to build the URI.
        let collection = get_collection();

        // Build the URI, for example: https://canvas.dport.me/view/0x123
        let uri = format2(
            &b"{}/view/{}",
            collection::uri(collection),
            object::object_address(&collection),
        );

        // Create the token. This creates an ObjectCore and Token.
        // TODO: Use token::create when AUIDs are enabled.
        let constructor_ref = token::create_from_account(
            caller,
            get_collection_name(),
            description,
            name,
            option::none(),
            uri,
        );

        // Create the pixels.
        // TODO: There has to be a faster way than this.
        let pixels = vector::empty();
        let i = 0;
        while (i < config.width * config.height) {
            vector::push_back(&mut pixels, config.default_color);
            i = i + 1;
        };

        // Create the canvas.
        let canvas = Canvas {
            config,
            pixels,
            last_contributions_s: smart_table::new(),
            allowlisted_artists: simple_set::create(),
            blocklisted_artists: simple_set::create(),
            admins: simple_set::create(),
        };

        let object_signer = object::generate_signer(&constructor_ref);

        // Move the canvas resource into the object.
        move_to(&object_signer, canvas);

        object::object_from_constructor_ref(&constructor_ref)
    }

    /// Draw a pixel to the canvas. We consider the top left corner 0,0.
    public fun draw(
        caller: &signer,
        canvas: Object<Canvas>,
        x: u32,
        y: u32,
        r: u8,
        g: u8,
        b: u8,
    ) acquires Canvas {
        let caller_addr = signer::address_of(caller);

        // Make sure the caller is allowed to draw.
        assert_allowlisted_to_draw(canvas, caller_addr);

        let canvas_ = borrow_global_mut<Canvas>(object::object_address(&canvas));

        // Confirm the coordinates are not out of bounds.
        assert!(x < canvas_.config.width, error::invalid_argument(E_COORDINATE_OUT_OF_BOUNDS));
        assert!(y < canvas_.config.height, error::invalid_argument(E_COORDINATE_OUT_OF_BOUNDS));

        // Write the pixel.
        let color = Color { r, g, b };
        let index = ((y * canvas_.config.width + x) as u64);
        *vector::borrow_mut(&mut canvas_.pixels, index) = color;
    }

    fun assert_allowlisted_to_draw(canvas: Object<Canvas>, caller_addr: address) acquires Canvas {
        let status = allowlisted_to_draw(canvas, caller_addr);

        if (status == STATUS_IN_BLOCKLIST) {
            assert!(false, error::invalid_state(E_CALLER_IN_BLOCKLIST));
        };

        if (status == STATUS_NOT_IN_ALLOWLIST) {
            assert!(false, error::invalid_state(E_CALLER_NOT_IN_ALLOWLIST));
        };
    }

    #[view]
    /// Check whether the caller is allowed to draw to the canvas. Returns one of the
    /// STATUS_* constants.
    public fun allowlisted_to_draw(canvas: Object<Canvas>, caller_addr: address): u8 acquires Canvas {
        let canvas_ = borrow_global<Canvas>(object::object_address(&canvas));

        // Check the blocklist.
        if (simple_set::length(&canvas_.blocklisted_artists) > 0) {
            if (simple_set::contains(&canvas_.blocklisted_artists, &caller_addr)) {
                return STATUS_IN_BLOCKLIST
            };
        };

        // Check the allowlist.
        if (simple_set::length(&canvas_.allowlisted_artists) > 0) {
            if (!simple_set::contains(&canvas_.allowlisted_artists, &caller_addr)) {
                return STATUS_NOT_IN_ALLOWLIST
            };
        };

        STATUS_ALLOWED
    }

    ///////////////////////////////////////////////////////////////////////////////////
    //                                  Super admin                                  //
    ///////////////////////////////////////////////////////////////////////////////////

    public entry fun add_admin(
        caller: &signer,
        canvas: Object<Canvas>,
        addr: address,
    ) acquires Canvas {
        let caller_addr = signer::address_of(caller);
        assert_is_super_admin(canvas, caller_addr);
        let canvas_ = borrow_global_mut<Canvas>(object::object_address(&canvas));
        simple_set::insert(&mut canvas_.admins, addr);
    }

    public entry fun remove_admin(
        caller: &signer,
        canvas: Object<Canvas>,
        addr: address,
    ) acquires Canvas {
        let caller_addr = signer::address_of(caller);
        assert_is_super_admin(canvas, caller_addr);
        let canvas_ = borrow_global_mut<Canvas>(object::object_address(&canvas));
        simple_set::remove(&mut canvas_.admins, &addr);
    }

    fun assert_is_super_admin(canvas: Object<Canvas>, caller_addr: address) acquires Canvas {
        assert!(is_super_admin(canvas, caller_addr), error::invalid_state(E_CALLER_NOT_SUPER_ADMIN));
    }

    #[view]
    /// Check whether the caller is the super admin (if there is one at all).
    public fun is_super_admin(canvas: Object<Canvas>, caller_addr: address): bool acquires Canvas {
        let is_owner = object::is_owner(canvas, caller_addr);
        if (!is_owner) {
            return false
        };

        let canvas_ = borrow_global<Canvas>(object::object_address(&canvas));

        if (!canvas_.config.owner_is_super_admin) {
            return false
        };

        true
    }

    ///////////////////////////////////////////////////////////////////////////////////
    //                                     Admin                                     //
    ///////////////////////////////////////////////////////////////////////////////////

    public entry fun add_to_allowlist(
        caller: &signer,
        canvas: Object<Canvas>,
        addr: address,
    ) acquires Canvas {
        let caller_addr = signer::address_of(caller);
        assert_is_admin(canvas, caller_addr);
        let canvas_ = borrow_global_mut<Canvas>(object::object_address(&canvas));
        simple_set::insert(&mut canvas_.allowlisted_artists, addr);
    }

    public entry fun remove_from_allowlist(
        caller: &signer,
        canvas: Object<Canvas>,
        addr: address,
    ) acquires Canvas {
        let caller_addr = signer::address_of(caller);
        assert_is_admin(canvas, caller_addr);
        let canvas_ = borrow_global_mut<Canvas>(object::object_address(&canvas));
        simple_set::remove(&mut canvas_.allowlisted_artists, &addr);
    }

    public entry fun add_to_blocklist(
        caller: &signer,
        canvas: Object<Canvas>,
        addr: address,
    ) acquires Canvas {
        let caller_addr = signer::address_of(caller);
        assert_is_admin(canvas, caller_addr);
        let canvas_ = borrow_global_mut<Canvas>(object::object_address(&canvas));
        simple_set::insert(&mut canvas_.blocklisted_artists, addr);
    }

    public entry fun remove_from_blocklist(
        caller: &signer,
        canvas: Object<Canvas>,
        addr: address,
    ) acquires Canvas {
        let caller_addr = signer::address_of(caller);
        assert_is_admin(canvas, caller_addr);
        let canvas_ = borrow_global_mut<Canvas>(object::object_address(&canvas));
        simple_set::remove(&mut canvas_.blocklisted_artists, &addr);
    }

    public entry fun clear(
        caller: &signer,
        canvas: Object<Canvas>,
    ) acquires Canvas {
        let caller_addr = signer::address_of(caller);
        assert_is_admin(canvas, caller_addr);
        let canvas_ = borrow_global_mut<Canvas>(object::object_address(&canvas));
        let i = 0;
        while (i < canvas_.config.width * canvas_.config.height) {
            *vector::borrow_mut(&mut canvas_.pixels, (i as u64)) = canvas_.config.default_color;
            i = i + 1;
        };
    }

    fun assert_is_admin(canvas: Object<Canvas>, caller_addr: address) acquires Canvas {
        assert!(is_admin(canvas, caller_addr), error::invalid_state(E_CALLER_NOT_ADMIN));
    }

    #[view]
    /// Check whether the caller is an admin (if there are any at all). We also check
    /// if they're the super admin, since that's a higher privilege level.
    public fun is_admin(canvas: Object<Canvas>, caller_addr: address): bool acquires Canvas {
        if (is_super_admin(canvas, caller_addr)) {
            return true
        };

        let canvas_ = borrow_global<Canvas>(object::object_address(&canvas));
        simple_set::contains(&canvas_.admins, &caller_addr)
    }

    ///////////////////////////////////////////////////////////////////////////////////
    //                                     Tests                                     //
    ///////////////////////////////////////////////////////////////////////////////////

    #[test_only]
    use addr::canvas_collection::{create as create_canvas_collection};
    #[test_only]
    use std::string;
    #[test_only]
    use std::timestamp;
    #[test_only]
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    #[test_only]
    use aptos_framework::account::{Self};
    #[test_only]
    use aptos_framework::coin;

    #[test_only]
    const ONE_APT: u64 = 100000000;

    #[test_only]
    const STARTING_BALANCE: u64 = 50 * 100000000;

    #[test_only]
    /// Create a test account with some funds.
    fun create_test_account(
        aptos_framework: &signer,
        account: &signer,
    ) {
        if (!aptos_coin::has_mint_capability(aptos_framework)) {
            // If aptos_framework doesn't have the mint cap it means we need to do some
            // initialization. This function will initialize AptosCoin and store the
            // mint cap in aptos_framwork. These capabilities that are returned from the
            // function are just copies. We don't need them since we use aptos_coin::mint
            // to mint coins, which uses the mint cap from the MintCapStore on
            // aptos_framework. So we burn them.
            let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
            coin::destroy_burn_cap(burn_cap);
            coin::destroy_mint_cap(mint_cap);
        };
        account::create_account_for_test(signer::address_of(account));
        coin::register<AptosCoin>(account);
        aptos_coin::mint(aptos_framework, signer::address_of(account), STARTING_BALANCE);
    }

    #[test_only]
    public fun set_global_time(
        aptos_framework: &signer,
        timestamp: u64
    ) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test_secs(timestamp);
    }

    #[test_only]
    fun create_canvas(caller: &signer, friend1: &signer, friend2: &signer, aptos_framework: &signer): Object<Canvas> {
        set_global_time(aptos_framework, 100);

        create_test_account(aptos_framework, caller);
        create_test_account(aptos_framework, friend1);
        create_test_account(aptos_framework, friend2);

        let config = CanvasConfig {
            width: 50,
            height: 50,
            per_account_timeout_s: 0,
            palette: vector::empty(),
            cost: 0,
            default_color: Color {
                r: 0,
                g: 0,
                b: 0,
            },
            owner_is_super_admin: false,
        };

        create_(caller, string::utf8(b"description"), string::utf8(b"name"), config)
    }

    #[test(caller = @addr, friend1 = @0x456, friend2 = @0x789, aptos_framework = @aptos_framework)]
    fun test_create(caller: signer, friend1: signer, friend2: signer, aptos_framework: signer) {
        create_canvas_collection(&caller);
        create_canvas(&caller, &friend1, &friend2, &aptos_framework);
    }
}
