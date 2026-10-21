//! The design tokens.
//!
//! Eatery has a brand, and a brand that only exists in the app's own
//! stylesheet is a brand that dies with the stylesheet. The Native SDK
//! lets the app own its whole design system - colours, type scale,
//! spacing, radii - so the palette lives in one file that a designer
//! can read and a developer can diff.
//!
//! The palette below is v2's own: the cyan-and-teal of Eatery v1,
//! re-expressed on the SDK's semantic token names. Colours are sRGB
//! bytes; the runtime handles the rest.

const std = @import("std");
const native_sdk = @import("native_sdk");

const core = @import("model.zig");

const canvas = native_sdk.canvas;
const Model = core.Model;

/// Eatery's brand palette.
const brand = struct {
    // The light semantic fills are the darkest step of the v1 hues that
    // clears WCAG AA with white text, and as text on the light
    // background and surface. The test in tests.zig is the guard.
    const primary = rgb(0x17, 0x6B, 0x84); // v1 cyan blue, one step down
    const primary_dark = rgb(0x12, 0x56, 0x6A);
    const secondary = rgb(0x4A, 0xC3, 0xA1); // v1 secondary - the teal green
    const accent = rgb(0x70, 0x5E, 0xE0); // v1 accent - the purple
    const success = rgb(0x1B, 0x6E, 0x47);
    const warning = rgb(0x87, 0x52, 0x0C);
    const danger = rgb(0xB3, 0x2D, 0x22);
    const info = rgb(0x2F, 0x5E, 0xC2);
};

fn rgb(r: u8, g: u8, b: u8) canvas.Color {
    return canvas.Color.rgb8(r, g, b);
}

/// The light palette.
pub fn light() canvas.DesignTokens {
    return .{
        .colors = .{
            .background = rgb(0xF7, 0xF8, 0xFA),
            .surface = rgb(0xFF, 0xFF, 0xFF),
            .surface_subtle = rgb(0xF1, 0xF3, 0xF6),
            .surface_pressed = rgb(0xE6, 0xEA, 0xEF),
            .text = rgb(0x15, 0x1A, 0x21),
            .text_muted = rgb(0x64, 0x6E, 0x7A),
            .border = rgb(0xE1, 0xE5, 0xEA),
            .accent = brand.primary,
            .accent_text = rgb(0xFF, 0xFF, 0xFF),
            .destructive = brand.danger,
            .destructive_text = rgb(0xFF, 0xFF, 0xFF),
            .success = brand.success,
            .success_text = rgb(0xFF, 0xFF, 0xFF),
            .warning = brand.warning,
            .warning_text = rgb(0xFF, 0xFF, 0xFF),
            .info = brand.info,
            .info_text = rgb(0xFF, 0xFF, 0xFF),
            .focus_ring = brand.primary,
        },
        .typography = .{
            .body_size = 14,
            .label_size = 13,
            .title_size = 20,
            .heading_size = 28,
            .display_size = 48,
            .button_size = 14,
        },
        .spacing = .{
            .xs = 4,
            .sm = 8,
            .md = 12,
            .lg = 16,
            .xl = 24,
        },
        .radius = .{
            .sm = 4,
            .md = 8,
            .lg = 12,
            .xl = 16,
            .none = 0,
        },
    };
}

/// The dark palette. The same brand, one step down in luminance.
pub fn dark() canvas.DesignTokens {
    return .{
        .colors = .{
            .background = rgb(0x0F, 0x13, 0x18),
            .surface = rgb(0x17, 0x1C, 0x23),
            .surface_subtle = rgb(0x1F, 0x26, 0x2E),
            .surface_pressed = rgb(0x27, 0x2F, 0x38),
            .text = rgb(0xEC, 0xEF, 0xF3),
            .text_muted = rgb(0x9A, 0xA5, 0xB1),
            .border = rgb(0x2A, 0x33, 0x3D),
            .accent = rgb(0x4C, 0xC2, 0xEA),
            .accent_text = rgb(0x08, 0x10, 0x14),
            .destructive = rgb(0xE8, 0x5D, 0x51),
            .destructive_text = rgb(0x12, 0x08, 0x08),
            .success = rgb(0x45, 0xB8, 0x86),
            .success_text = rgb(0x06, 0x14, 0x0E),
            .warning = rgb(0xE0, 0x9A, 0x3C),
            .warning_text = rgb(0x14, 0x0E, 0x04),
            .info = rgb(0x5B, 0x8C, 0xE0),
            .info_text = rgb(0x06, 0x0E, 0x18),
            .focus_ring = rgb(0x4C, 0xC2, 0xEA),
        },
        .typography = .{
            .body_size = 14,
            .label_size = 13,
            .title_size = 20,
            .heading_size = 28,
            .display_size = 48,
            .button_size = 14,
        },
        .spacing = .{
            .xs = 4,
            .sm = 8,
            .md = 12,
            .lg = 16,
            .xl = 24,
        },
        .radius = .{
            .sm = 4,
            .md = 8,
            .lg = 12,
            .xl = 16,
            .none = 0,
        },
    };
}

/// The tokens for the current model state. The runtime asks for these
/// on every rebuild, so flipping the theme is a model change and
/// nothing else.
pub fn tokens(model: *const Model) canvas.DesignTokens {
    return if (model.theme_dark) dark() else light();
}
