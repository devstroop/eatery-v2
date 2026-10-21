//! The starter menu.
//!
//! A fresh installation has no menu, no tables and no staff. An empty
//! POS is a POS the operator cannot evaluate, so the setup writes a
//! small, real starter menu: four categories, a dozen dishes, and six
//! tables. Every row is editable afterwards, and every row is a real
//! row - not a placeholder that pretends to be data.
//!
//! The prices are in minor units, like every other price in the app.

const std = @import("std");
const domain = @import("../domain/models.zig");

/// One dish of the starter menu.
pub const Dish = struct {
    category: []const u8,
    name: []const u8,
    price_minor: i64,
    product_type: domain.ProductType,
    food_type: domain.FoodType,
};

/// The starter menu, in the order it is written.
pub const dishes = [_]Dish{
    .{ .category = "Starters", .name = "Paneer Tikka", .price_minor = 24500, .product_type = .dish, .food_type = .veg },
    .{ .category = "Starters", .name = "Chicken Samosa", .price_minor = 12000, .product_type = .dish, .food_type = .non_veg },
    .{ .category = "Starters", .name = "Papadum", .price_minor = 4000, .product_type = .dish, .food_type = .veg },

    .{ .category = "Mains", .name = "Butter Chicken", .price_minor = 32000, .product_type = .dish, .food_type = .non_veg },
    .{ .category = "Mains", .name = "Paneer Butter Masala", .price_minor = 28000, .product_type = .dish, .food_type = .veg },
    .{ .category = "Mains", .name = "Dal Tadka", .price_minor = 18000, .product_type = .dish, .food_type = .veg },
    .{ .category = "Mains", .name = "Jeera Rice", .price_minor = 16000, .product_type = .dish, .food_type = .veg },
    .{ .category = "Mains", .name = "Garlic Naan", .price_minor = 6000, .product_type = .dish, .food_type = .veg },

    .{ .category = "Breads", .name = "Tandoori Roti", .price_minor = 5000, .product_type = .dish, .food_type = .veg },
    .{ .category = "Breads", .name = "Laccha Paratha", .price_minor = 9000, .product_type = .dish, .food_type = .veg },

    .{ .category = "Drinks", .name = "Masala Chai", .price_minor = 4000, .product_type = .beverage, .food_type = .veg },
    .{ .category = "Drinks", .name = "Fresh Lime Soda", .price_minor = 8000, .product_type = .beverage, .food_type = .veg },
    .{ .category = "Drinks", .name = "Masala Lemonade", .price_minor = 9000, .product_type = .beverage, .food_type = .veg },
};

/// The categories the starter menu uses, in menu order.
pub const categories = [_][]const u8{ "Starters", "Mains", "Breads", "Drinks" };

/// The table category the starter floor uses.
pub const table_category = "Main room";

/// The starter floor.
pub const tables = [_]struct { name: []const u8, seats: i64 }{
    .{ .name = "T1", .seats = 2 },
    .{ .name = "T2", .seats = 2 },
    .{ .name = "T3", .seats = 4 },
    .{ .name = "T4", .seats = 4 },
    .{ .name = "T5", .seats = 6 },
    .{ .name = "T6", .seats = 6 },
};
