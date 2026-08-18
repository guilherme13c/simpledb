const std = @import("std");

pub const page_size = 8192;
pub const content_length = page_size - @sizeOf(PageHeader);

pub const PageHeader = packed struct(u128) {
    lsn: u32,
    checksum: u32,
    lower: u13,
    upper: u13,
    special: u38,
};

pub const Page = extern struct {
    header: PageHeader align(4096),
    content: [content_length]u8,
};
