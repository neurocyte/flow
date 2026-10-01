//! Hand-written CoreFoundation / CoreText / CoreGraphics declarations
//!
//! `@cImport` cannot be used due to macOS SDK nullability attributes
//! `@translate-c rejects
//!
//! checked against the 15.5 SDK headers
//!
const std = @import("std");

/// An opaque CoreFoundation-derived object
pub const Ref = ?*anyopaque;

pub const CGFloat = f64;
pub const CFIndex = isize;
pub const CGGlyph = u16;
pub const UniChar = u16;
pub const Boolean = u8;
pub const CFStringEncoding = u32;
pub const CTFontSymbolicTraits = u32;
pub const CGBitmapInfo = u32;

pub const CGPoint = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
pub const CGSize = extern struct { width: CGFloat = 0, height: CGFloat = 0 };
pub const CGRect = extern struct { origin: CGPoint = .{}, size: CGSize = .{} };
pub const CFRange = extern struct { location: CFIndex = 0, length: CFIndex = 0 };
pub const CGAffineTransform = extern struct {
    a: CGFloat = 1,
    b: CGFloat = 0,
    c: CGFloat = 0,
    d: CGFloat = 1,
    tx: CGFloat = 0,
    ty: CGFloat = 0,
};

pub const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;

pub const kCTFontTraitItalic: CTFontSymbolicTraits = 1 << 0;
pub const kCTFontTraitBold: CTFontSymbolicTraits = 1 << 1;
pub const kCTFontTraitMonoSpace: CTFontSymbolicTraits = 1 << 10;
pub const kCTFontTraitColorGlyphs: CTFontSymbolicTraits = 1 << 13;

pub const kCGImageAlphaNone: CGBitmapInfo = 0;
pub const kCGImageAlphaPremultipliedLast: CGBitmapInfo = 1;
pub const kCGImageAlphaPremultipliedFirst: CGBitmapInfo = 2;
pub const kCGImageAlphaOnly: CGBitmapInfo = 7;
pub const kCGBitmapByteOrder32Little: CGBitmapInfo = 2 << 12;

pub const kCFNumberSInt32Type: i32 = 3;

/// kCFNumberCGFloatType; CGFloat is double, so the double code applies.
pub const kCFNumberDoubleType: i32 = 13;

pub const kCGTextFill: u32 = 0;
pub const kCGTextFillStroke: u32 = 2;

/// sfnt table tag as CTFontCopyTable takes it: a four-character code packed
/// big-endian into a u32.
pub fn tag(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

// CoreFoundation

pub extern "c" fn CFRelease(cf: Ref) void;
pub extern "c" fn CFRetain(cf: Ref) Ref;

pub extern "c" fn CFStringCreateWithBytes(
    alloc: Ref,
    bytes: [*]const u8,
    num_bytes: CFIndex,
    encoding: CFStringEncoding,
    is_external_representation: Boolean,
) Ref;
pub extern "c" fn CFStringGetLength(str: Ref) CFIndex;
pub extern "c" fn CFStringGetCString(
    str: Ref,
    buffer: [*]u8,
    buffer_size: CFIndex,
    encoding: CFStringEncoding,
) Boolean;

pub extern "c" fn CFArrayGetCount(array: Ref) CFIndex;
pub extern "c" fn CFArrayGetValueAtIndex(array: Ref, idx: CFIndex) Ref;

pub extern "c" fn CFDataCreate(alloc: Ref, bytes: [*]const u8, length: CFIndex) Ref;
pub extern "c" fn CFDataGetLength(data: Ref) CFIndex;

pub extern "c" fn CFDictionaryCreate(
    alloc: Ref,
    keys: [*]const Ref,
    values: [*]const Ref,
    num_values: CFIndex,
    key_callbacks: ?*const anyopaque,
    value_callbacks: ?*const anyopaque,
) Ref;

pub extern "c" fn CFNumberCreate(alloc: Ref, the_type: i32, value_ptr: *const anyopaque) Ref;
pub extern "c" fn CFNumberGetValue(number: Ref, the_type: i32, value_ptr: *anyopaque) Boolean;
pub extern "c" fn CFDictionaryGetValue(dict: Ref, key: Ref) Ref;

pub extern const kCFTypeDictionaryKeyCallBacks: anyopaque;
pub extern const kCFTypeDictionaryValueCallBacks: anyopaque;

// CoreText

pub extern "c" fn CTFontCreateWithFontDescriptor(
    descriptor: Ref,
    size: CGFloat,
    matrix: ?*const CGAffineTransform,
) Ref;
pub extern "c" fn CTFontCreateCopyWithAttributes(
    font: Ref,
    size: CGFloat,
    matrix: ?*const CGAffineTransform,
    attributes: Ref,
) Ref;
pub extern "c" fn CTFontCreateForString(current: Ref, string: Ref, range: CFRange) Ref;

pub extern "c" fn CTFontDescriptorCreateWithAttributes(attributes: Ref) Ref;
pub extern "c" fn CTFontDescriptorCopyAttribute(descriptor: Ref, attribute: Ref) Ref;

pub extern "c" fn CTFontCopyFamilyName(font: Ref) Ref;
pub extern "c" fn CTFontGetSymbolicTraits(font: Ref) CTFontSymbolicTraits;

pub extern "c" fn CTFontGetSize(font: Ref) CGFloat;
pub extern "c" fn CTFontGetAscent(font: Ref) CGFloat;
pub extern "c" fn CTFontGetDescent(font: Ref) CGFloat;
pub extern "c" fn CTFontGetLeading(font: Ref) CGFloat;
pub extern "c" fn CTFontGetCapHeight(font: Ref) CGFloat;
pub extern "c" fn CTFontGetXHeight(font: Ref) CGFloat;
pub extern "c" fn CTFontGetUnderlinePosition(font: Ref) CGFloat;
pub extern "c" fn CTFontGetUnderlineThickness(font: Ref) CGFloat;

pub extern "c" fn CTFontGetGlyphsForCharacters(
    font: Ref,
    characters: [*]const UniChar,
    glyphs: [*]CGGlyph,
    count: CFIndex,
) Boolean;
pub extern "c" fn CTFontGetAdvancesForGlyphs(
    font: Ref,
    orientation: u32,
    glyphs: [*]const CGGlyph,
    advances: ?[*]CGSize,
    count: CFIndex,
) f64;
pub extern "c" fn CTFontGetBoundingRectsForGlyphs(
    font: Ref,
    orientation: u32,
    glyphs: [*]const CGGlyph,
    bounding_rects: ?[*]CGRect,
    count: CFIndex,
) CGRect;
pub extern "c" fn CTFontDrawGlyphs(
    font: Ref,
    glyphs: [*]const CGGlyph,
    positions: [*]const CGPoint,
    count: usize,
    context: Ref,
) void;
pub extern "c" fn CTFontCopyTable(font: Ref, table: u32, options: u32) Ref;

pub extern "c" fn CTFontManagerCreateFontDescriptorFromData(data: Ref) Ref;

pub extern "c" fn CTFontCollectionCreateFromAvailableFonts(options: Ref) Ref;
pub extern "c" fn CTFontCollectionCreateMatchingFontDescriptors(collection: Ref) Ref;

pub extern const kCTFontFamilyNameAttribute: Ref;
pub extern const kCTFontTraitsAttribute: Ref;
pub extern const kCTFontWeightTrait: Ref;
pub extern const kCTFontSlantTrait: Ref;
pub extern const kCTFontSymbolicTrait: Ref;

// CoreGraphics

pub extern "c" fn CGColorSpaceCreateDeviceGray() Ref;
pub extern "c" fn CGColorSpaceCreateDeviceRGB() Ref;
pub extern "c" fn CGColorSpaceRelease(space: Ref) void;

pub extern "c" fn CGBitmapContextCreate(
    data: ?*anyopaque,
    width: usize,
    height: usize,
    bits_per_component: usize,
    bytes_per_row: usize,
    space: Ref,
    bitmap_info: CGBitmapInfo,
) Ref;
pub extern "c" fn CGContextRelease(context: Ref) void;
pub extern "c" fn CGContextSetShouldAntialias(context: Ref, should: Boolean) void;
pub extern "c" fn CGContextSetShouldSmoothFonts(context: Ref, should: Boolean) void;
pub extern "c" fn CGContextSetGrayFillColor(context: Ref, gray: CGFloat, alpha: CGFloat) void;
pub extern "c" fn CGContextSetGrayStrokeColor(context: Ref, gray: CGFloat, alpha: CGFloat) void;
pub extern "c" fn CGContextSetTextMatrix(context: Ref, t: CGAffineTransform) void;
pub extern "c" fn CGContextSetTextDrawingMode(context: Ref, mode: u32) void;
pub extern "c" fn CGContextSetLineWidth(context: Ref, width: CGFloat) void;
pub extern "c" fn CGContextSetRGBFillColor(context: Ref, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
pub extern "c" fn CGContextSaveGState(context: Ref) void;
pub extern "c" fn CGContextRestoreGState(context: Ref) void;
pub extern "c" fn CGContextConcatCTM(context: Ref, transform: CGAffineTransform) void;
pub extern "c" fn CGContextSetAllowsFontSubpixelPositioning(context: Ref, allows: Boolean) void;
pub extern "c" fn CGContextSetShouldSubpixelPositionFonts(context: Ref, should: Boolean) void;
pub extern "c" fn CGContextSetAllowsFontSubpixelQuantization(context: Ref, allows: Boolean) void;
pub extern "c" fn CGContextSetShouldSubpixelQuantizeFonts(context: Ref, should: Boolean) void;
pub extern "c" fn CGContextSetAllowsAntialiasing(context: Ref, allows: Boolean) void;
pub extern "c" fn CGContextFillRect(context: Ref, rect: CGRect) void;
