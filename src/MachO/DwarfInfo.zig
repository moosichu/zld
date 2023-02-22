const DwarfInfo = @This();

const std = @import("std");
const assert = std.debug.assert;
const dwarf = std.dwarf;
const leb = std.leb;
const log = std.log.scoped(.macho);
const mem = std.mem;

const Allocator = mem.Allocator;
pub const AbbrevLookupTable = std.AutoHashMap(u64, struct { pos: usize, len: usize });
pub const SubprogramLookupByName = std.StringHashMap(struct { addr: u64, size: u64 });

debug_info: []const u8,
debug_abbrev: []const u8,
debug_str: []const u8,

pub fn getCompileUnitIterator(self: DwarfInfo) CompileUnitIterator {
    return .{ .ctx = self };
}

const CompileUnitIterator = struct {
    ctx: DwarfInfo,
    pos: usize = 0,

    pub fn next(self: *CompileUnitIterator) !?CompileUnit {
        if (self.pos >= self.ctx.debug_info.len) return null;

        var stream = std.io.fixedBufferStream(self.ctx.debug_info);
        var creader = std.io.countingReader(stream.reader());
        const reader = creader.reader();

        const cuh = try CompileUnit.Header.read(reader);
        const total_length = cuh.length + @as(u64, if (cuh.is_64bit) @sizeOf(u64) else @sizeOf(u32));

        const cu = CompileUnit{
            .cuh = cuh,
            .debug_info_off = creader.bytes_read,
        };

        self.pos += total_length;

        return cu;
    }
};

pub fn genSubprogramLookupByName(
    self: DwarfInfo,
    compile_unit: CompileUnit,
    abbrev_lookup: AbbrevLookupTable,
    lookup: *SubprogramLookupByName,
) !void {
    var abbrev_it = compile_unit.getAbbrevEntryIterator(self);
    while (try abbrev_it.next(abbrev_lookup)) |entry| switch (entry.tag) {
        dwarf.TAG.subprogram => {
            var attr_it = entry.getAttributeIterator(self, compile_unit.cuh);

            var name: ?[]const u8 = null;
            var low_pc: ?u64 = null;
            var high_pc: ?u64 = null;

            while (try attr_it.next()) |attr| switch (attr.name) {
                dwarf.AT.name => if (attr.getString(self, compile_unit.cuh)) |str| {
                    log.warn("subprogram: {s}", .{str});
                    name = str;
                },
                dwarf.AT.low_pc => {
                    if (attr.getAddr(self, compile_unit.cuh)) |addr| {
                        low_pc = addr;
                    }
                    if (try attr.getConstant(self)) |constant| {
                        low_pc = @intCast(u64, constant);
                    }
                },
                dwarf.AT.high_pc => {
                    if (attr.getAddr(self, compile_unit.cuh)) |addr| {
                        high_pc = addr;
                    }
                    if (try attr.getConstant(self)) |constant| {
                        high_pc = @intCast(u64, constant);
                    }
                },
                else => {},
            };

            if (name == null or low_pc == null or high_pc == null) continue;

            try lookup.putNoClobber(name.?, .{ .addr = low_pc.?, .size = high_pc.? });
        },
        else => {},
    };
}

pub fn genAbbrevLookupByKind(self: DwarfInfo, off: usize, lookup: *AbbrevLookupTable) !void {
    const data = self.debug_abbrev[off..];
    var stream = std.io.fixedBufferStream(data);
    var creader = std.io.countingReader(stream.reader());
    const reader = creader.reader();

    while (true) {
        const kind = try leb.readULEB128(u64, reader);

        if (kind == 0) break;

        const pos = creader.bytes_read;
        _ = try leb.readULEB128(u64, reader); // TAG
        _ = try reader.readByte(); // CHILDREN

        while (true) {
            const name = try leb.readULEB128(u64, reader);
            const form = try leb.readULEB128(u64, reader);

            if (name == 0 and form == 0) break;
        }

        try lookup.putNoClobber(kind, .{
            .pos = pos,
            .len = creader.bytes_read - pos - 2,
        });
    }
}

pub const CompileUnit = struct {
    cuh: Header,
    debug_info_off: usize,

    pub const Header = struct {
        is_64bit: bool,
        length: u64,
        version: u16,
        debug_abbrev_offset: u64,
        address_size: u8,

        fn read(reader: anytype) !Header {
            var length: u64 = try reader.readIntLittle(u32);

            const is_64bit = length == 0xffffffff;
            if (is_64bit) {
                length = try reader.readIntLittle(u64);
            }

            const version = try reader.readIntLittle(u16);
            const debug_abbrev_offset = if (is_64bit)
                try reader.readIntLittle(u64)
            else
                try reader.readIntLittle(u32);
            const address_size = try reader.readIntLittle(u8);

            return Header{
                .is_64bit = is_64bit,
                .length = length,
                .version = version,
                .debug_abbrev_offset = debug_abbrev_offset,
                .address_size = address_size,
            };
        }
    };

    inline fn getDebugInfo(self: CompileUnit, ctx: DwarfInfo) []const u8 {
        return ctx.debug_info[self.debug_info_off..][0..self.cuh.length];
    }

    pub fn getAbbrevEntryIterator(self: CompileUnit, ctx: DwarfInfo) AbbrevEntryIterator {
        return .{ .cu = self, .ctx = ctx };
    }
};

const AbbrevEntryIterator = struct {
    cu: CompileUnit,
    ctx: DwarfInfo,
    pos: usize = 0,

    pub fn next(self: *AbbrevEntryIterator, lookup: AbbrevLookupTable) !?AbbrevEntry {
        if (self.pos + self.cu.debug_info_off >= self.ctx.debug_info.len) return null;

        const debug_info = self.ctx.debug_info[self.pos + self.cu.debug_info_off ..];
        var stream = std.io.fixedBufferStream(debug_info);
        var creader = std.io.countingReader(stream.reader());
        const reader = creader.reader();

        const kind = try leb.readULEB128(u64, reader);
        self.pos += creader.bytes_read;

        if (kind == 0) {
            return AbbrevEntry.null();
        }

        const abbrev_pos = lookup.get(kind) orelse return error.MalformedDwarf;
        const len = try findAbbrevEntrySize(
            self.ctx,
            abbrev_pos.pos,
            abbrev_pos.len,
            self.pos + self.cu.debug_info_off,
            self.cu.cuh,
        );
        const entry = try getAbbrevEntry(
            self.ctx,
            abbrev_pos.pos,
            abbrev_pos.len,
            self.pos + self.cu.debug_info_off,
            len,
        );

        self.pos += len;

        return entry;
    }
};

pub const AbbrevEntry = struct {
    tag: u64,
    children: u8,
    debug_abbrev_off: usize,
    debug_abbrev_len: usize,
    debug_info_off: usize,
    debug_info_len: usize,

    fn @"null"() AbbrevEntry {
        return .{
            .tag = 0,
            .children = dwarf.CHILDREN.no,
            .debug_abbrev_off = 0,
            .debug_abbrev_len = 0,
            .debug_info_off = 0,
            .debug_info_len = 0,
        };
    }

    pub fn hasChildren(self: AbbrevEntry) bool {
        return self.children == dwarf.CHILDREN.yes;
    }

    inline fn getDebugInfo(self: AbbrevEntry, ctx: DwarfInfo) []const u8 {
        return ctx.debug_info[self.debug_info_off..][0..self.debug_info_len];
    }

    inline fn getDebugAbbrev(self: AbbrevEntry, ctx: DwarfInfo) []const u8 {
        return ctx.debug_abbrev[self.debug_abbrev_off..][0..self.debug_abbrev_len];
    }

    pub fn getAttributeIterator(self: AbbrevEntry, ctx: DwarfInfo, cuh: CompileUnit.Header) AttributeIterator {
        return .{ .entry = self, .ctx = ctx, .cuh = cuh };
    }
};

pub const Attribute = struct {
    name: u64,
    form: u64,
    debug_info_off: usize,
    debug_info_len: usize,

    inline fn getDebugInfo(self: Attribute, ctx: DwarfInfo) []const u8 {
        return ctx.debug_info[self.debug_info_off..][0..self.debug_info_len];
    }

    pub fn getString(self: Attribute, ctx: DwarfInfo, cuh: CompileUnit.Header) ?[]const u8 {
        if (self.form != dwarf.FORM.strp) return null;
        const debug_info = self.getDebugInfo(ctx);
        const off = if (cuh.is_64bit)
            mem.readIntLittle(u64, debug_info[0..8])
        else
            mem.readIntLittle(u32, debug_info[0..4]);
        return ctx.getString(off);
    }

    pub fn getConstant(self: Attribute, ctx: DwarfInfo) !?i128 {
        const debug_info = self.getDebugInfo(ctx);
        var stream = std.io.fixedBufferStream(debug_info);
        const reader = stream.reader();

        return switch (self.form) {
            dwarf.FORM.data1 => debug_info[0],
            dwarf.FORM.data2 => mem.readIntLittle(u16, debug_info[0..2]),
            dwarf.FORM.data4 => mem.readIntLittle(u32, debug_info[0..4]),
            dwarf.FORM.data8 => mem.readIntLittle(u64, debug_info[0..8]),
            dwarf.FORM.udata => try leb.readULEB128(u64, reader),
            dwarf.FORM.sdata => try leb.readILEB128(i64, reader),
            else => null,
        };
    }

    pub fn getReference(self: Attribute, ctx: DwarfInfo) !?u64 {
        const debug_info = self.getDebugInfo(ctx);
        var stream = std.io.fixedBufferStream(debug_info);
        const reader = stream.reader();

        return switch (self.form) {
            dwarf.FORM.ref1 => debug_info[0],
            dwarf.FORM.ref2 => mem.readIntLittle(u16, debug_info[0..2]),
            dwarf.FORM.ref4 => mem.readIntLittle(u32, debug_info[0..4]),
            dwarf.FORM.ref8 => mem.readIntLittle(u64, debug_info[0..8]),
            dwarf.FORM.ref_udata => try leb.readULEB128(u64, reader),
            else => null,
        };
    }

    pub fn getAddr(self: Attribute, ctx: DwarfInfo, cuh: CompileUnit.Header) ?u64 {
        if (self.form != dwarf.FORM.addr) return null;
        const debug_info = self.getDebugInfo(ctx);
        return switch (cuh.address_size) {
            1 => debug_info[0],
            2 => mem.readIntLittle(u16, debug_info[0..2]),
            4 => mem.readIntLittle(u32, debug_info[0..4]),
            8 => mem.readIntLittle(u64, debug_info[0..8]),
            else => unreachable,
        };
    }
};

const AttributeIterator = struct {
    entry: AbbrevEntry,
    ctx: DwarfInfo,
    cuh: CompileUnit.Header,
    debug_abbrev_pos: usize = 0,
    debug_info_pos: usize = 0,

    pub fn next(self: *AttributeIterator) !?Attribute {
        const debug_abbrev = self.entry.getDebugAbbrev(self.ctx);
        if (self.debug_abbrev_pos >= debug_abbrev.len) return null;

        var stream = std.io.fixedBufferStream(debug_abbrev[self.debug_abbrev_pos..]);
        var creader = std.io.countingReader(stream.reader());
        const reader = creader.reader();

        const name = try leb.readULEB128(u64, reader);
        const form = try leb.readULEB128(u64, reader);

        self.debug_abbrev_pos += creader.bytes_read;

        const len = try findFormSize(
            self.ctx,
            form,
            self.debug_info_pos + self.entry.debug_info_off,
            self.cuh,
        );
        const attr = Attribute{
            .name = name,
            .form = form,
            .debug_info_off = self.debug_info_pos + self.entry.debug_info_off,
            .debug_info_len = len,
        };

        self.debug_info_pos += len;

        return attr;
    }
};

fn getAbbrevEntry(self: DwarfInfo, da_off: usize, da_len: usize, di_off: usize, di_len: usize) !AbbrevEntry {
    const debug_abbrev = self.debug_abbrev[da_off..][0..da_len];
    var stream = std.io.fixedBufferStream(debug_abbrev);
    var creader = std.io.countingReader(stream.reader());
    const reader = creader.reader();

    const tag = try leb.readULEB128(u64, reader);
    const children = switch (tag) {
        std.dwarf.TAG.const_type,
        std.dwarf.TAG.packed_type,
        std.dwarf.TAG.pointer_type,
        std.dwarf.TAG.reference_type,
        std.dwarf.TAG.restrict_type,
        std.dwarf.TAG.rvalue_reference_type,
        std.dwarf.TAG.shared_type,
        std.dwarf.TAG.volatile_type,
        => if (creader.bytes_read == da_len) std.dwarf.CHILDREN.no else try reader.readByte(),
        else => try reader.readByte(),
    };

    return AbbrevEntry{
        .tag = tag,
        .children = children,
        .debug_abbrev_off = creader.bytes_read + da_off,
        .debug_abbrev_len = da_len - creader.bytes_read,
        .debug_info_off = di_off,
        .debug_info_len = di_len,
    };
}

fn findFormSize(self: DwarfInfo, form: u64, di_off: usize, cuh: CompileUnit.Header) !usize {
    const debug_info = self.debug_info[di_off..];
    var stream = std.io.fixedBufferStream(debug_info);
    var creader = std.io.countingReader(stream.reader());
    const reader = creader.reader();

    return switch (form) {
        dwarf.FORM.strp => if (cuh.is_64bit) @sizeOf(u64) else @sizeOf(u32),
        dwarf.FORM.sec_offset => if (cuh.is_64bit) @sizeOf(u64) else @sizeOf(u32),
        dwarf.FORM.addr => cuh.address_size,
        dwarf.FORM.exprloc => blk: {
            const expr_len = try leb.readULEB128(u64, reader);
            var i: u64 = 0;
            while (i < expr_len) : (i += 1) {
                _ = try reader.readByte();
            }
            break :blk creader.bytes_read;
        },
        dwarf.FORM.flag_present => 0,

        dwarf.FORM.data1 => @sizeOf(u8),
        dwarf.FORM.data2 => @sizeOf(u16),
        dwarf.FORM.data4 => @sizeOf(u32),
        dwarf.FORM.data8 => @sizeOf(u64),
        dwarf.FORM.udata => blk: {
            _ = try leb.readULEB128(u64, reader);
            break :blk creader.bytes_read;
        },
        dwarf.FORM.sdata => blk: {
            _ = try leb.readILEB128(i64, reader);
            break :blk creader.bytes_read;
        },

        dwarf.FORM.ref1 => @sizeOf(u8),
        dwarf.FORM.ref2 => @sizeOf(u16),
        dwarf.FORM.ref4 => @sizeOf(u32),
        dwarf.FORM.ref8 => @sizeOf(u64),
        dwarf.FORM.ref_udata => blk: {
            _ = try leb.readULEB128(u64, reader);
            break :blk creader.bytes_read;
        },

        else => return error.ToDo,
    };
}

fn findAbbrevEntrySize(self: DwarfInfo, da_off: usize, da_len: usize, di_off: usize, cuh: CompileUnit.Header) !usize {
    const debug_abbrev = self.debug_abbrev[da_off..][0..da_len];
    var stream = std.io.fixedBufferStream(debug_abbrev);
    var creader = std.io.countingReader(stream.reader());
    const reader = creader.reader();

    const tag = try leb.readULEB128(u64, reader);
    _ = switch (tag) {
        std.dwarf.TAG.const_type,
        std.dwarf.TAG.packed_type,
        std.dwarf.TAG.pointer_type,
        std.dwarf.TAG.reference_type,
        std.dwarf.TAG.restrict_type,
        std.dwarf.TAG.rvalue_reference_type,
        std.dwarf.TAG.shared_type,
        std.dwarf.TAG.volatile_type,
        => if (creader.bytes_read != da_len) try reader.readByte(),
        else => try reader.readByte(),
    };

    var len: usize = 0;
    while (creader.bytes_read < debug_abbrev.len) {
        _ = try leb.readULEB128(u64, reader);
        const form = try leb.readULEB128(u64, reader);
        const form_len = try self.findFormSize(form, di_off + len, cuh);
        len += form_len;
    }

    return len;
}

fn getString(self: DwarfInfo, off: u64) []const u8 {
    assert(off < self.debug_str.len);
    return mem.sliceTo(@ptrCast([*:0]const u8, self.debug_str.ptr + off), 0);
}
