-- =====================================================================
-- E-COMMERCE DATABASE SCHEMA (PostgreSQL)
-- =====================================================================
-- Notes on additions beyond the original list (see chat explanation):
--   brands, product_categories (M2M), order_status_history,
--   shipment_items, coupon_usages, wishlist_items, generic
--   updated_at trigger, ENUM types for all status/type fields.
-- =====================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =====================================================================
-- ENUM TYPES
-- =====================================================================
CREATE TYPE address_type_enum        AS ENUM ('billing','shipping','both');
CREATE TYPE cart_status_enum         AS ENUM ('active','converted','abandoned');
CREATE TYPE order_status_enum        AS ENUM ('pending','confirmed','processing','shipped','delivered','cancelled','refunded');
CREATE TYPE payment_status_enum      AS ENUM ('pending','authorized','captured','failed','refunded','partially_refunded');
CREATE TYPE payment_method_enum      AS ENUM ('credit_card','debit_card','paypal','bank_transfer','cod','wallet');
CREATE TYPE shipment_status_enum     AS ENUM ('pending','packed','shipped','in_transit','delivered','failed','returned');
CREATE TYPE return_status_enum       AS ENUM ('requested','approved','rejected','received','refunded');
CREATE TYPE return_reason_enum       AS ENUM ('defective','wrong_item','not_as_described','no_longer_needed','other');
CREATE TYPE po_status_enum           AS ENUM ('draft','submitted','approved','partially_received','received','cancelled');
CREATE TYPE transfer_status_enum     AS ENUM ('pending','in_transit','completed','cancelled');
CREATE TYPE adjustment_reason_enum   AS ENUM ('recount','damage','theft','expiry','correction','other');
CREATE TYPE inventory_txn_type_enum  AS ENUM ('purchase','sale','return','adjustment','transfer_in','transfer_out','damage','reservation','release');
CREATE TYPE coupon_type_enum         AS ENUM ('percentage','fixed_amount','free_shipping');

-- =====================================================================
-- GENERIC updated_at TRIGGER FUNCTION
-- =====================================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =====================================================================
-- CATALOG: BRANDS / CATEGORIES / PRODUCTS / VARIANTS / IMAGES
-- =====================================================================

CREATE TABLE brands (
    brand_id     BIGSERIAL PRIMARY KEY,
    name         VARCHAR(150) NOT NULL,
    slug         VARCHAR(160) NOT NULL,
    logo_url     TEXT,
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_brands_name UNIQUE (name),
    CONSTRAINT uq_brands_slug UNIQUE (slug)
);
CREATE TRIGGER trg_brands_updated_at BEFORE UPDATE ON brands
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE categories (
    category_id          BIGSERIAL PRIMARY KEY,
    parent_category_id   BIGINT REFERENCES categories(category_id) ON DELETE SET NULL,
    name                 VARCHAR(150) NOT NULL,
    slug                 VARCHAR(160) NOT NULL,
    description          TEXT,
    is_active            BOOLEAN NOT NULL DEFAULT TRUE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_categories_slug UNIQUE (slug),
    CONSTRAINT chk_categories_no_self_parent CHECK (parent_category_id IS DISTINCT FROM category_id)
);
CREATE INDEX idx_categories_parent ON categories(parent_category_id);
CREATE TRIGGER trg_categories_updated_at BEFORE UPDATE ON categories
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE products (
    product_id     BIGSERIAL PRIMARY KEY,
    brand_id       BIGINT REFERENCES brands(brand_id) ON DELETE SET NULL,
    category_id    BIGINT REFERENCES categories(category_id) ON DELETE SET NULL,
    name           VARCHAR(255) NOT NULL,
    slug           VARCHAR(270) NOT NULL,
    description    TEXT,
    base_price     NUMERIC(12,2) NOT NULL,
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_products_slug UNIQUE (slug),
    CONSTRAINT chk_products_base_price_nonneg CHECK (base_price >= 0)
);
CREATE INDEX idx_products_category ON products(category_id);
CREATE INDEX idx_products_brand ON products(brand_id);
CREATE INDEX idx_products_active ON products(is_active) WHERE is_active = TRUE;
CREATE TRIGGER trg_products_updated_at BEFORE UPDATE ON products
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Optional secondary categorization (many-to-many), independent of the
-- product's primary category_id above.
CREATE TABLE product_categories (
    product_id   BIGINT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    category_id  BIGINT NOT NULL REFERENCES categories(category_id) ON DELETE CASCADE,
    PRIMARY KEY (product_id, category_id)
);
CREATE INDEX idx_product_categories_category ON product_categories(category_id);

CREATE TABLE product_variants (
    variant_id     BIGSERIAL PRIMARY KEY,
    product_id     BIGINT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    sku            VARCHAR(64) NOT NULL,
    variant_name   VARCHAR(150),
    attributes     JSONB NOT NULL DEFAULT '{}',
    price          NUMERIC(12,2) NOT NULL,
    weight_kg      NUMERIC(8,3),
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_variants_sku UNIQUE (sku),
    CONSTRAINT chk_variants_price_nonneg CHECK (price >= 0)
);
CREATE INDEX idx_variants_product ON product_variants(product_id);
CREATE INDEX idx_variants_attributes ON product_variants USING GIN (attributes);
CREATE TRIGGER trg_variants_updated_at BEFORE UPDATE ON product_variants
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE product_images (
    image_id       BIGSERIAL PRIMARY KEY,
    product_id     BIGINT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    variant_id     BIGINT REFERENCES product_variants(variant_id) ON DELETE CASCADE,
    image_url      TEXT NOT NULL,
    alt_text       VARCHAR(255),
    display_order  INT NOT NULL DEFAULT 0,
    is_primary     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_images_product ON product_images(product_id);
CREATE INDEX idx_images_variant ON product_images(variant_id);
-- Only one primary image per product
CREATE UNIQUE INDEX uq_images_one_primary_per_product
    ON product_images(product_id) WHERE is_primary = TRUE;

-- =====================================================================
-- WAREHOUSES / INVENTORY
-- =====================================================================

CREATE TABLE warehouses (
    warehouse_id   BIGSERIAL PRIMARY KEY,
    name           VARCHAR(150) NOT NULL,
    code           VARCHAR(20) NOT NULL,
    address_line1  VARCHAR(255),
    city           VARCHAR(100),
    state          VARCHAR(100),
    postal_code    VARCHAR(20),
    country        VARCHAR(100),
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_warehouses_code UNIQUE (code)
);

CREATE TABLE inventory (
    inventory_id       BIGSERIAL PRIMARY KEY,
    variant_id         BIGINT NOT NULL REFERENCES product_variants(variant_id) ON DELETE CASCADE,
    warehouse_id       BIGINT NOT NULL REFERENCES warehouses(warehouse_id) ON DELETE CASCADE,
    quantity_on_hand   INT NOT NULL DEFAULT 0,
    quantity_reserved  INT NOT NULL DEFAULT 0,
    reorder_level      INT NOT NULL DEFAULT 0,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_inventory_variant_warehouse UNIQUE (variant_id, warehouse_id),
    CONSTRAINT chk_inventory_qty_nonneg CHECK (quantity_on_hand >= 0 AND quantity_reserved >= 0),
    CONSTRAINT chk_inventory_reserved_le_onhand CHECK (quantity_reserved <= quantity_on_hand)
);
CREATE INDEX idx_inventory_variant ON inventory(variant_id);
CREATE INDEX idx_inventory_warehouse ON inventory(warehouse_id);
CREATE TRIGGER trg_inventory_updated_at BEFORE UPDATE ON inventory
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Append-only ledger: source of truth for all stock movement. `inventory`
-- above is a derived/cached balance table that should be reconciled
-- against this ledger.
CREATE TABLE inventory_transactions (
    transaction_id   BIGSERIAL PRIMARY KEY,
    variant_id       BIGINT NOT NULL REFERENCES product_variants(variant_id) ON DELETE RESTRICT,
    warehouse_id     BIGINT NOT NULL REFERENCES warehouses(warehouse_id) ON DELETE RESTRICT,
    txn_type         inventory_txn_type_enum NOT NULL,
    quantity         INT NOT NULL,
    reference_table  VARCHAR(50),
    reference_id     BIGINT,
    notes            TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_inventory_txn_qty_nonzero CHECK (quantity <> 0)
);
CREATE INDEX idx_inv_txn_variant_warehouse ON inventory_transactions(variant_id, warehouse_id);
CREATE INDEX idx_inv_txn_reference ON inventory_transactions(reference_table, reference_id);
CREATE INDEX idx_inv_txn_created_at ON inventory_transactions(created_at);

-- =====================================================================
-- SUPPLIERS / PURCHASE ORDERS
-- =====================================================================

CREATE TABLE suppliers (
    supplier_id    BIGSERIAL PRIMARY KEY,
    name           VARCHAR(200) NOT NULL,
    contact_name   VARCHAR(150),
    email          CITEXT,
    phone          VARCHAR(30),
    address_line1  VARCHAR(255),
    city           VARCHAR(100),
    state          VARCHAR(100),
    postal_code    VARCHAR(20),
    country        VARCHAR(100),
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_suppliers_email ON suppliers(email) WHERE email IS NOT NULL;

CREATE TABLE purchase_orders (
    po_id          BIGSERIAL PRIMARY KEY,
    supplier_id    BIGINT NOT NULL REFERENCES suppliers(supplier_id) ON DELETE RESTRICT,
    warehouse_id   BIGINT NOT NULL REFERENCES warehouses(warehouse_id) ON DELETE RESTRICT,
    status         po_status_enum NOT NULL DEFAULT 'draft',
    order_date     DATE NOT NULL DEFAULT CURRENT_DATE,
    expected_date  DATE,
    total_amount   NUMERIC(14,2) NOT NULL DEFAULT 0,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_po_total_nonneg CHECK (total_amount >= 0)
);
CREATE INDEX idx_po_supplier ON purchase_orders(supplier_id);
CREATE INDEX idx_po_warehouse ON purchase_orders(warehouse_id);
CREATE INDEX idx_po_status ON purchase_orders(status);
CREATE TRIGGER trg_po_updated_at BEFORE UPDATE ON purchase_orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE purchase_order_items (
    po_item_id         BIGSERIAL PRIMARY KEY,
    po_id              BIGINT NOT NULL REFERENCES purchase_orders(po_id) ON DELETE CASCADE,
    variant_id         BIGINT NOT NULL REFERENCES product_variants(variant_id) ON DELETE RESTRICT,
    quantity_ordered   INT NOT NULL,
    quantity_received  INT NOT NULL DEFAULT 0,
    unit_cost          NUMERIC(12,2) NOT NULL,
    CONSTRAINT uq_po_items_po_variant UNIQUE (po_id, variant_id),
    CONSTRAINT chk_po_items_qty_ordered_pos CHECK (quantity_ordered > 0),
    CONSTRAINT chk_po_items_qty_received_nonneg CHECK (quantity_received >= 0),
    CONSTRAINT chk_po_items_received_le_ordered CHECK (quantity_received <= quantity_ordered),
    CONSTRAINT chk_po_items_unit_cost_nonneg CHECK (unit_cost >= 0)
);
CREATE INDEX idx_po_items_po ON purchase_order_items(po_id);
CREATE INDEX idx_po_items_variant ON purchase_order_items(variant_id);

-- =====================================================================
-- CUSTOMERS / ADDRESSES
-- =====================================================================

CREATE TABLE customers (
    customer_id     BIGSERIAL PRIMARY KEY,
    email           CITEXT NOT NULL,
    password_hash   TEXT NOT NULL,
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100) NOT NULL,
    phone           VARCHAR(30),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_customers_email UNIQUE (email)
);
CREATE TRIGGER trg_customers_updated_at BEFORE UPDATE ON customers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE addresses (
    address_id     BIGSERIAL PRIMARY KEY,
    customer_id    BIGINT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    address_type   address_type_enum NOT NULL DEFAULT 'both',
    full_name      VARCHAR(150) NOT NULL,
    phone          VARCHAR(30),
    line1          VARCHAR(255) NOT NULL,
    line2          VARCHAR(255),
    city           VARCHAR(100) NOT NULL,
    state          VARCHAR(100),
    postal_code    VARCHAR(20) NOT NULL,
    country        VARCHAR(100) NOT NULL,
    is_default     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_addresses_customer ON addresses(customer_id);
CREATE UNIQUE INDEX uq_addresses_one_default_per_customer
    ON addresses(customer_id) WHERE is_default = TRUE;
CREATE TRIGGER trg_addresses_updated_at BEFORE UPDATE ON addresses
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =====================================================================
-- CARTS
-- =====================================================================

CREATE TABLE carts (
    cart_id         BIGSERIAL PRIMARY KEY,
    customer_id     BIGINT REFERENCES customers(customer_id) ON DELETE CASCADE,
    session_token   VARCHAR(255),
    status          cart_status_enum NOT NULL DEFAULT 'active',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_carts_owner CHECK (customer_id IS NOT NULL OR session_token IS NOT NULL)
);
CREATE INDEX idx_carts_customer ON carts(customer_id);
CREATE UNIQUE INDEX uq_carts_session_token ON carts(session_token) WHERE session_token IS NOT NULL;
CREATE TRIGGER trg_carts_updated_at BEFORE UPDATE ON carts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE cart_items (
    cart_item_id   BIGSERIAL PRIMARY KEY,
    cart_id        BIGINT NOT NULL REFERENCES carts(cart_id) ON DELETE CASCADE,
    variant_id     BIGINT NOT NULL REFERENCES product_variants(variant_id) ON DELETE RESTRICT,
    quantity       INT NOT NULL,
    unit_price     NUMERIC(12,2) NOT NULL,
    added_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_cart_items_cart_variant UNIQUE (cart_id, variant_id),
    CONSTRAINT chk_cart_items_qty_pos CHECK (quantity > 0),
    CONSTRAINT chk_cart_items_price_nonneg CHECK (unit_price >= 0)
);
CREATE INDEX idx_cart_items_cart ON cart_items(cart_id);
CREATE INDEX idx_cart_items_variant ON cart_items(variant_id);

-- =====================================================================
-- COUPONS (declared before orders since orders references coupons)
-- =====================================================================

CREATE TABLE coupons (
    coupon_id                  BIGSERIAL PRIMARY KEY,
    code                       VARCHAR(50) NOT NULL,
    coupon_type                coupon_type_enum NOT NULL,
    value                      NUMERIC(12,2) NOT NULL,
    min_order_amount           NUMERIC(12,2) NOT NULL DEFAULT 0,
    max_discount_amount        NUMERIC(12,2),
    usage_limit                INT,
    usage_limit_per_customer   INT NOT NULL DEFAULT 1,
    starts_at                  TIMESTAMPTZ,
    expires_at                 TIMESTAMPTZ,
    is_active                  BOOLEAN NOT NULL DEFAULT TRUE,
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_coupons_code UNIQUE (code),
    CONSTRAINT chk_coupons_value_nonneg CHECK (value >= 0),
    CONSTRAINT chk_coupons_min_order_nonneg CHECK (min_order_amount >= 0),
    CONSTRAINT chk_coupons_dates CHECK (starts_at IS NULL OR expires_at IS NULL OR starts_at < expires_at),
    CONSTRAINT chk_coupons_percentage_range CHECK (coupon_type <> 'percentage' OR (value > 0 AND value <= 100))
);
CREATE INDEX idx_coupons_active ON coupons(is_active) WHERE is_active = TRUE;

-- =====================================================================
-- ORDERS
-- =====================================================================

CREATE TABLE orders (
    order_id             BIGSERIAL PRIMARY KEY,
    order_number         VARCHAR(30) NOT NULL,
    customer_id          BIGINT NOT NULL REFERENCES customers(customer_id) ON DELETE RESTRICT,
    billing_address_id   BIGINT NOT NULL REFERENCES addresses(address_id) ON DELETE RESTRICT,
    shipping_address_id  BIGINT NOT NULL REFERENCES addresses(address_id) ON DELETE RESTRICT,
    coupon_id            BIGINT REFERENCES coupons(coupon_id) ON DELETE SET NULL,
    status               order_status_enum NOT NULL DEFAULT 'pending',
    subtotal             NUMERIC(14,2) NOT NULL,
    discount_amount      NUMERIC(14,2) NOT NULL DEFAULT 0,
    tax_amount           NUMERIC(14,2) NOT NULL DEFAULT 0,
    shipping_amount      NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_amount         NUMERIC(14,2) NOT NULL,
    placed_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_orders_order_number UNIQUE (order_number),
    CONSTRAINT chk_orders_amounts_nonneg CHECK (
        subtotal >= 0 AND discount_amount >= 0 AND tax_amount >= 0
        AND shipping_amount >= 0 AND total_amount >= 0
    )
);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_orders_placed_at ON orders(placed_at);
CREATE INDEX idx_orders_coupon ON orders(coupon_id);
CREATE TRIGGER trg_orders_updated_at BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE order_items (
    order_item_id     BIGSERIAL PRIMARY KEY,
    order_id          BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    variant_id        BIGINT NOT NULL REFERENCES product_variants(variant_id) ON DELETE RESTRICT,
    warehouse_id      BIGINT REFERENCES warehouses(warehouse_id) ON DELETE SET NULL,
    quantity          INT NOT NULL,
    unit_price        NUMERIC(12,2) NOT NULL,
    discount_amount   NUMERIC(12,2) NOT NULL DEFAULT 0,
    line_total        NUMERIC(14,2) NOT NULL,
    CONSTRAINT chk_order_items_qty_pos CHECK (quantity > 0),
    CONSTRAINT chk_order_items_amounts_nonneg CHECK (
        unit_price >= 0 AND discount_amount >= 0 AND line_total >= 0
    )
);
CREATE INDEX idx_order_items_order ON order_items(order_id);
CREATE INDEX idx_order_items_variant ON order_items(variant_id);
CREATE INDEX idx_order_items_warehouse ON order_items(warehouse_id);

CREATE TABLE order_status_history (
    history_id   BIGSERIAL PRIMARY KEY,
    order_id     BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    status       order_status_enum NOT NULL,
    note         TEXT,
    changed_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_order_status_history_order ON order_status_history(order_id);

CREATE TABLE coupon_usages (
    usage_id           BIGSERIAL PRIMARY KEY,
    coupon_id          BIGINT NOT NULL REFERENCES coupons(coupon_id) ON DELETE CASCADE,
    customer_id        BIGINT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    order_id           BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    discount_applied   NUMERIC(12,2) NOT NULL,
    used_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_coupon_usages_coupon_order UNIQUE (coupon_id, order_id),
    CONSTRAINT chk_coupon_usages_discount_nonneg CHECK (discount_applied >= 0)
);
CREATE INDEX idx_coupon_usages_coupon ON coupon_usages(coupon_id);
CREATE INDEX idx_coupon_usages_customer ON coupon_usages(customer_id);

-- =====================================================================
-- PAYMENTS
-- =====================================================================

CREATE TABLE payments (
    payment_id              BIGSERIAL PRIMARY KEY,
    order_id                BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    payment_method          payment_method_enum NOT NULL,
    status                  payment_status_enum NOT NULL DEFAULT 'pending',
    amount                  NUMERIC(12,2) NOT NULL,
    transaction_reference   VARCHAR(255),
    paid_at                 TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_payments_amount_nonneg CHECK (amount >= 0)
);
CREATE INDEX idx_payments_order ON payments(order_id);
CREATE INDEX idx_payments_status ON payments(status);
CREATE UNIQUE INDEX uq_payments_txn_ref ON payments(transaction_reference) WHERE transaction_reference IS NOT NULL;
CREATE TRIGGER trg_payments_updated_at BEFORE UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =====================================================================
-- SHIPMENTS
-- =====================================================================

CREATE TABLE shipments (
    shipment_id       BIGSERIAL PRIMARY KEY,
    order_id          BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    warehouse_id      BIGINT NOT NULL REFERENCES warehouses(warehouse_id) ON DELETE RESTRICT,
    carrier           VARCHAR(100),
    tracking_number   VARCHAR(150),
    status            shipment_status_enum NOT NULL DEFAULT 'pending',
    shipped_at        TIMESTAMPTZ,
    delivered_at      TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_shipments_order ON shipments(order_id);
CREATE INDEX idx_shipments_warehouse ON shipments(warehouse_id);
CREATE INDEX idx_shipments_status ON shipments(status);
CREATE TRIGGER trg_shipments_updated_at BEFORE UPDATE ON shipments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Maps which order_items (and how much of each) went into a shipment,
-- enabling partial/split shipments.
CREATE TABLE shipment_items (
    shipment_item_id   BIGSERIAL PRIMARY KEY,
    shipment_id        BIGINT NOT NULL REFERENCES shipments(shipment_id) ON DELETE CASCADE,
    order_item_id      BIGINT NOT NULL REFERENCES order_items(order_item_id) ON DELETE RESTRICT,
    quantity           INT NOT NULL,
    CONSTRAINT chk_shipment_items_qty_pos CHECK (quantity > 0)
);
CREATE INDEX idx_shipment_items_shipment ON shipment_items(shipment_id);
CREATE INDEX idx_shipment_items_order_item ON shipment_items(order_item_id);

-- =====================================================================
-- RETURNS
-- =====================================================================

CREATE TABLE returns (
    return_id       BIGSERIAL PRIMARY KEY,
    order_id        BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id) ON DELETE RESTRICT,
    status          return_status_enum NOT NULL DEFAULT 'requested',
    reason          return_reason_enum NOT NULL,
    requested_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at     TIMESTAMPTZ,
    refund_amount   NUMERIC(12,2) NOT NULL DEFAULT 0,
    CONSTRAINT chk_returns_refund_nonneg CHECK (refund_amount >= 0)
);
CREATE INDEX idx_returns_order ON returns(order_id);
CREATE INDEX idx_returns_customer ON returns(customer_id);
CREATE INDEX idx_returns_status ON returns(status);

CREATE TABLE return_items (
    return_item_id   BIGSERIAL PRIMARY KEY,
    return_id        BIGINT NOT NULL REFERENCES returns(return_id) ON DELETE CASCADE,
    order_item_id    BIGINT NOT NULL REFERENCES order_items(order_item_id) ON DELETE RESTRICT,
    quantity         INT NOT NULL,
    condition        VARCHAR(50),
    restock          BOOLEAN NOT NULL DEFAULT FALSE,
    CONSTRAINT chk_return_items_qty_pos CHECK (quantity > 0)
);
CREATE INDEX idx_return_items_return ON return_items(return_id);
CREATE INDEX idx_return_items_order_item ON return_items(order_item_id);

-- =====================================================================
-- STOCK ADJUSTMENTS
-- =====================================================================

CREATE TABLE stock_adjustments (
    adjustment_id   BIGSERIAL PRIMARY KEY,
    warehouse_id    BIGINT NOT NULL REFERENCES warehouses(warehouse_id) ON DELETE RESTRICT,
    reason          adjustment_reason_enum NOT NULL,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_stock_adjustments_warehouse ON stock_adjustments(warehouse_id);

CREATE TABLE stock_adjustment_items (
    adjustment_item_id   BIGSERIAL PRIMARY KEY,
    adjustment_id        BIGINT NOT NULL REFERENCES stock_adjustments(adjustment_id) ON DELETE CASCADE,
    variant_id            BIGINT NOT NULL REFERENCES product_variants(variant_id) ON DELETE RESTRICT,
    quantity_delta        INT NOT NULL,
    CONSTRAINT chk_stock_adj_items_delta_nonzero CHECK (quantity_delta <> 0)
);
CREATE INDEX idx_stock_adj_items_adjustment ON stock_adjustment_items(adjustment_id);
CREATE INDEX idx_stock_adj_items_variant ON stock_adjustment_items(variant_id);

-- =====================================================================
-- DAMAGE REPORTS
-- =====================================================================

CREATE TABLE damage_reports (
    damage_report_id   BIGSERIAL PRIMARY KEY,
    warehouse_id       BIGINT NOT NULL REFERENCES warehouses(warehouse_id) ON DELETE RESTRICT,
    description         TEXT,
    reported_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_damage_reports_warehouse ON damage_reports(warehouse_id);

CREATE TABLE damage_report_items (
    damage_report_item_id   BIGSERIAL PRIMARY KEY,
    damage_report_id        BIGINT NOT NULL REFERENCES damage_reports(damage_report_id) ON DELETE CASCADE,
    variant_id               BIGINT NOT NULL REFERENCES product_variants(variant_id) ON DELETE RESTRICT,
    quantity                 INT NOT NULL,
    CONSTRAINT chk_damage_report_items_qty_pos CHECK (quantity > 0)
);
CREATE INDEX idx_damage_report_items_report ON damage_report_items(damage_report_id);
CREATE INDEX idx_damage_report_items_variant ON damage_report_items(variant_id);

-- =====================================================================
-- TRANSFERS (inter-warehouse)
-- =====================================================================

CREATE TABLE transfers (
    transfer_id              BIGSERIAL PRIMARY KEY,
    source_warehouse_id      BIGINT NOT NULL REFERENCES warehouses(warehouse_id) ON DELETE RESTRICT,
    destination_warehouse_id BIGINT NOT NULL REFERENCES warehouses(warehouse_id) ON DELETE RESTRICT,
    status                   transfer_status_enum NOT NULL DEFAULT 'pending',
    initiated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at             TIMESTAMPTZ,
    CONSTRAINT chk_transfers_diff_warehouses CHECK (source_warehouse_id <> destination_warehouse_id)
);
CREATE INDEX idx_transfers_source ON transfers(source_warehouse_id);
CREATE INDEX idx_transfers_destination ON transfers(destination_warehouse_id);
CREATE INDEX idx_transfers_status ON transfers(status);

CREATE TABLE transfer_items (
    transfer_item_id   BIGSERIAL PRIMARY KEY,
    transfer_id        BIGINT NOT NULL REFERENCES transfers(transfer_id) ON DELETE CASCADE,
    variant_id         BIGINT NOT NULL REFERENCES product_variants(variant_id) ON DELETE RESTRICT,
    quantity           INT NOT NULL,
    CONSTRAINT chk_transfer_items_qty_pos CHECK (quantity > 0)
);
CREATE INDEX idx_transfer_items_transfer ON transfer_items(transfer_id);
CREATE INDEX idx_transfer_items_variant ON transfer_items(variant_id);

-- =====================================================================
-- REVIEWS
-- =====================================================================

CREATE TABLE reviews (
    review_id       BIGSERIAL PRIMARY KEY,
    product_id      BIGINT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    order_item_id   BIGINT REFERENCES order_items(order_item_id) ON DELETE SET NULL,
    rating          SMALLINT NOT NULL,
    title           VARCHAR(200),
    body            TEXT,
    is_approved     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_reviews_rating_range CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT uq_reviews_product_customer_orderitem UNIQUE (product_id, customer_id, order_item_id)
);
CREATE INDEX idx_reviews_product ON reviews(product_id);
CREATE INDEX idx_reviews_customer ON reviews(customer_id);
CREATE INDEX idx_reviews_approved ON reviews(is_approved) WHERE is_approved = TRUE;
CREATE TRIGGER trg_reviews_updated_at BEFORE UPDATE ON reviews
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =====================================================================
-- WISHLISTS
-- =====================================================================

CREATE TABLE wishlists (
    wishlist_id   BIGSERIAL PRIMARY KEY,
    customer_id   BIGINT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    name          VARCHAR(100) NOT NULL DEFAULT 'My Wishlist',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_wishlists_customer_name UNIQUE (customer_id, name)
);
CREATE INDEX idx_wishlists_customer ON wishlists(customer_id);

CREATE TABLE wishlist_items (
    wishlist_item_id   BIGSERIAL PRIMARY KEY,
    wishlist_id        BIGINT NOT NULL REFERENCES wishlists(wishlist_id) ON DELETE CASCADE,
    variant_id         BIGINT NOT NULL REFERENCES product_variants(variant_id) ON DELETE CASCADE,
    added_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_wishlist_items_wishlist_variant UNIQUE (wishlist_id, variant_id)
);
CREATE INDEX idx_wishlist_items_wishlist ON wishlist_items(wishlist_id);
CREATE INDEX idx_wishlist_items_variant ON wishlist_items(variant_id);

COMMIT;
