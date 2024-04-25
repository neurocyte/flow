const nc = @import("notcurses");

pub const key = nc.key;
pub const modifier = nc.mod;
pub const event_type = nc.event_type;

pub const utils = struct {
    pub const isSuper = nc.isSuper;
    pub const isCtrl = nc.isCtrl;
    pub const isShift = nc.isShift;
    pub const isAlt = nc.isAlt;
    pub const key_id_string = nc.key_id_string;
    pub const key_string = nc.key_string;
};
