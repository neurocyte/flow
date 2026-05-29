const vaxis = @import("vaxis");
pub const uucode = vaxis.uucode;

pub fn isWideCandidate(cp: u21) bool {
    // PUA ranges
    if ((cp >= 0xE000 and cp <= 0xF8FF) or
        (cp >= 0xF0000 and cp <= 0xFFFFD) or
        (cp >= 0x100000 and cp <= 0x10FFFD)) return true;

    // Non-emoji dingbats (U+2700–U+27BF) and enclosed alphanumeric supplement (U+1F100–U+1F1FF)
    if ((cp >= 0x2700 and cp <= 0x27BF) or (cp >= 0x1F100 and cp <= 0x1F1FF)) {
        return !uucode.get(.is_emoji_presentation, @intCast(cp));
    }

    // Symbols from general categories So, Sm, Sk, Sc
    const gc = uucode.get(.general_category, @intCast(cp));
    return switch (gc) {
        .symbol_math, .symbol_currency, .symbol_modifier, .symbol_other => true,
        else => false,
    };
}
