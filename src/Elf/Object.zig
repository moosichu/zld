const Object = @This();

const std = @import("std");
const assert = std.debug.assert;
const elf = std.elf;
const fs = std.fs;
const log = std.log.scoped(.elf);
const math = std.math;
const mem = std.mem;

const Allocator = mem.Allocator;
const Atom = @import("Atom.zig");
const Elf = @import("../Elf.zig");

const dis_x86_64 = @import("dis_x86_64");
const Disassembler = dis_x86_64.Disassembler;
const Instruction = dis_x86_64.Instruction;
const RegisterOrMemory = dis_x86_64.RegisterOrMemory;

name: []const u8,
data: []align(@alignOf(u64)) const u8,
header: elf.Elf64_Ehdr = undefined,
symtab_index: ?u16 = null,

symtab: std.ArrayListUnmanaged(elf.Elf64_Sym) = .{},

managed_atoms: std.ArrayListUnmanaged(*Atom) = .{},
atom_table: std.AutoHashMapUnmanaged(u32, *Atom) = .{},

pub fn deinit(self: *Object, allocator: Allocator) void {
    self.symtab.deinit(allocator);
    for (self.managed_atoms.items) |atom| {
        atom.deinit(allocator);
        allocator.destroy(atom);
    }
    self.managed_atoms.deinit(allocator);
    self.atom_table.deinit(allocator);

    // ZAR MODIFICATION:
    // We manage memory of file ourselves in zar - so
    // freeing this here for that does not make much sense.
    // allocator.free(self.name);
    // allocator.free(self.data);
}

pub fn parse(self: *Object, allocator: Allocator, cpu_arch: std.Target.Cpu.Arch) !void {
    var stream = std.io.fixedBufferStream(self.data);
    const reader = stream.reader();

    self.header = try reader.readStruct(elf.Elf64_Ehdr);

    if (!mem.eql(u8, self.header.e_ident[0..4], "\x7fELF")) {
        log.debug("Invalid ELF magic {s}, expected \x7fELF", .{self.header.e_ident[0..4]});
        return error.NotObject;
    }
    if (self.header.e_ident[elf.EI_VERSION] != 1) {
        log.debug("Unknown ELF version {d}, expected 1", .{self.header.e_ident[elf.EI_VERSION]});
        return error.NotObject;
    }
    if (self.header.e_ident[elf.EI_DATA] != elf.ELFDATA2LSB) {
        log.err("TODO big endian support", .{});
        return error.TODOBigEndianSupport;
    }
    if (self.header.e_ident[elf.EI_CLASS] != elf.ELFCLASS64) {
        log.err("TODO 32bit support", .{});
        return error.TODOElf32bitSupport;
    }
    if (self.header.e_type != elf.ET.REL) {
        log.debug("Invalid file type {any}, expected ET.REL", .{self.header.e_type});
        return error.NotObject;
    }
    // ZAR MODIFICATION: This check doesn't serve any purpose for the needs of
    // zar.
    _ = cpu_arch;
    // if (self.header.e_machine != cpu_arch.toElfMachine()) {
    //     log.debug("Invalid architecture {any}, expected {any}", .{
    //         self.header.e_machine,
    //         cpu_arch.toElfMachine(),
    //     });
    //     return error.InvalidCpuArch;
    // }
    if (self.header.e_version != 1) {
        log.debug("Invalid ELF version {d}, expected 1", .{self.header.e_version});
        return error.NotObject;
    }

    assert(self.header.e_entry == 0);
    assert(self.header.e_phoff == 0);
    assert(self.header.e_phnum == 0);

    if (self.header.e_shnum == 0) return;

    for (self.getShdrs(), 0..) |shdr, i| switch (shdr.sh_type) {
        elf.SHT_SYMTAB => {
            self.symtab_index = @intCast(i);
            const nsyms = @divExact(shdr.sh_size, @sizeOf(elf.Elf64_Sym));
            try self.symtab.appendSlice(allocator, @as(
                [*]const elf.Elf64_Sym,
                @ptrCast(@alignCast(&self.data[shdr.sh_offset])),
            )[0..nsyms]);
        },
        else => {},
    };
}

pub fn scanInputSections(self: *Object, elf_file: *Elf) !void {
    for (self.getShdrs()) |shdr| switch (shdr.sh_type) {
        elf.SHT_PROGBITS, elf.SHT_NOBITS => {
            const shdr_name = self.getShString(shdr.sh_name);
            if (shdr.sh_flags & elf.SHF_GROUP != 0) {
                log.err("section '{s}' is part of a section group", .{shdr_name});
                return error.HandleSectionGroups;
            }

            const tshdr_ndx = (try elf_file.getOutputSection(shdr, shdr_name)) orelse {
                log.debug("unhandled section", .{});
                continue;
            };
            const out_shdr = elf_file.sections.items(.shdr)[tshdr_ndx];
            log.debug("mapping '{s}' into output sect({d}, '{s}')", .{
                shdr_name,
                tshdr_ndx,
                elf_file.shstrtab.getAssumeExists(out_shdr.sh_name),
            });
        },
        else => {},
    };
}

pub fn splitIntoAtoms(self: *Object, allocator: Allocator, object_id: u16, elf_file: *Elf) !void {
    log.debug("parsing '{s}' into atoms", .{self.name});

    var symbols_by_shndx = std.AutoHashMap(u16, std.ArrayList(u32)).init(allocator);
    defer {
        var it = symbols_by_shndx.valueIterator();
        while (it.next()) |value| {
            value.deinit();
        }
        symbols_by_shndx.deinit();
    }

    const shdrs = self.getShdrs();

    var rel_shdrs = std.AutoHashMap(u16, u16).init(allocator);
    defer rel_shdrs.deinit();

    for (shdrs, 0..) |shdr, i| switch (shdr.sh_type) {
        elf.SHT_REL, elf.SHT_RELA => {
            try rel_shdrs.putNoClobber(@as(u16, @intCast(shdr.sh_info)), @as(u16, @intCast(i)));
        },
        else => {},
    };

    for (shdrs, 0..) |shdr, i| switch (shdr.sh_type) {
        elf.SHT_PROGBITS, elf.SHT_NOBITS => {
            try symbols_by_shndx.putNoClobber(@as(u16, @intCast(i)), std.ArrayList(u32).init(allocator));
        },
        else => {},
    };

    for (self.getSourceSymtab(), 0..) |sym, sym_id| {
        if (sym.st_shndx == elf.SHN_UNDEF) continue;
        if (elf.SHN_LORESERVE <= sym.st_shndx and sym.st_shndx < elf.SHN_HIRESERVE) continue;
        const map = symbols_by_shndx.getPtr(sym.st_shndx) orelse continue;
        try map.append(@as(u32, @intCast(sym_id)));
    }

    for (shdrs, 0..) |shdr, i| switch (shdr.sh_type) {
        elf.SHT_PROGBITS, elf.SHT_NOBITS => {
            const ndx = @as(u16, @intCast(i));
            const shdr_name = self.getShString(shdr.sh_name);

            log.debug("  parsing section '{s}'", .{shdr_name});

            const tshdr_ndx = (try elf_file.getOutputSection(shdr, shdr_name)) orelse {
                log.debug("unhandled section", .{});
                continue;
            };

            const syms = symbols_by_shndx.get(ndx).?;

            const atom = try Atom.createEmpty(allocator);
            errdefer {
                atom.deinit(allocator);
                allocator.destroy(atom);
            }
            try self.managed_atoms.append(allocator, atom);

            atom.file = object_id;
            atom.size = @as(u32, @intCast(shdr.sh_size));
            atom.alignment = @as(u32, @intCast(shdr.sh_addralign));

            // TODO if --gc-sections and there is exactly one contained symbol,
            // we can prune the main one. For example, in this situation we
            // get something like this:
            //
            // .text.__udivti3
            //    => __udivti3
            //
            // which can be pruned to:
            //
            // __udivti3
            var sym_index: ?u32 = null;

            for (syms.items) |sym_id| {
                const sym = self.getSourceSymbol(sym_id).?;
                const is_sect_sym = sym.st_info & 0xf == elf.STT_SECTION;
                if (is_sect_sym) {
                    const osym = self.getSymbolPtr(sym_id);
                    osym.* = .{
                        .st_name = 0,
                        .st_info = (elf.STB_LOCAL << 4) | elf.STT_OBJECT,
                        .st_other = 0,
                        .st_shndx = 0,
                        .st_value = 0,
                        .st_size = sym.st_size,
                    };
                    sym_index = sym_id;
                    continue;
                }
                try atom.contained.append(allocator, .{
                    .sym_index = sym_id,
                    .offset = sym.st_value,
                });
                try self.atom_table.putNoClobber(allocator, sym_id, atom);
            }

            atom.sym_index = sym_index orelse blk: {
                const index = @as(u32, @intCast(self.symtab.items.len));
                try self.symtab.append(allocator, .{
                    .st_name = 0,
                    .st_info = (elf.STB_LOCAL << 4) | elf.STT_OBJECT,
                    .st_other = 0,
                    .st_shndx = 0,
                    .st_value = 0,
                    .st_size = atom.size,
                });
                break :blk index;
            };
            try self.atom_table.putNoClobber(allocator, atom.sym_index, atom);

            var code = if (shdr.sh_type == elf.SHT_NOBITS) blk: {
                var code = try allocator.alloc(u8, atom.size);
                mem.set(u8, code, 0);
                break :blk code;
            } else try allocator.dupe(u8, self.getShdrContents(ndx));
            defer allocator.free(code);

            if (rel_shdrs.get(ndx)) |rel_ndx| {
                const rel_shdr = shdrs[rel_ndx];
                const raw_relocs = self.getShdrContents(rel_ndx);

                const nrelocs = @divExact(rel_shdr.sh_size, rel_shdr.sh_entsize);
                try atom.relocs.ensureTotalCapacityPrecise(allocator, nrelocs);

                var count: usize = 0;
                while (count < nrelocs) : (count += 1) {
                    const bytes = raw_relocs[count * rel_shdr.sh_entsize ..][0..rel_shdr.sh_entsize];
                    var rel = blk: {
                        if (rel_shdr.sh_type == elf.SHT_REL) {
                            const rel = @as(*const elf.Elf64_Rel, @ptrCast(@alignCast(bytes))).*;
                            // TODO parse addend from the placeholder
                            // const addend = mem.readIntLittle(i32, code[rel.r_offset..][0..4]);
                            // break :blk .{
                            //     .r_offset = rel.r_offset,
                            //     .r_info = rel.r_info,
                            //     .r_addend = addend,
                            // };
                            log.err("TODO need to parse addend embedded in the relocation placeholder for SHT_REL", .{});
                            log.err("  for relocation {}", .{rel});
                            return error.TODOParseAddendFromPlaceholder;
                        }

                        break :blk @as(*const elf.Elf64_Rela, @ptrCast(@alignCast(bytes))).*;
                    };

                    // While traversing relocations, synthesize any missing atom.
                    // TODO synthesize PLT atoms, GOT atoms, etc.
                    const tsym_name = self.getSourceSymbolName(rel.r_sym());
                    switch (rel.r_type()) {
                        elf.R_X86_64_REX_GOTPCRELX => blk: {
                            const global = elf_file.globals.get(tsym_name).?;
                            if (isDefinitionAvailable(elf_file, global)) opt: {
                                // Link-time constant, try to optimize it away.
                                var disassembler = Disassembler.init(code[rel.r_offset - 3 ..]);
                                const maybe_inst = disassembler.next() catch break :opt;
                                const inst = maybe_inst orelse break :opt;

                                // TODO can we optimise anything that isn't an RM encoding?
                                if (inst.enc != .rm) break :opt;
                                const rm = inst.data.rm;
                                if (rm.reg_or_mem != .mem) break :opt;
                                if (rm.reg_or_mem.mem.base != .rip) break :opt;
                                const dst = rm.reg;
                                const src = rm.reg_or_mem;

                                var stream = std.io.fixedBufferStream(code[rel.r_offset - 3 ..][0..7]);
                                const writer = stream.writer();

                                switch (inst.tag) {
                                    .mov => {
                                        // rewrite to LEA
                                        const new_inst = Instruction{
                                            .tag = .lea,
                                            .enc = .rm,
                                            .data = Instruction.Data.rm(dst, src),
                                        };
                                        try new_inst.encode(writer);

                                        const r_sym = rel.r_sym();
                                        rel.r_info = (@as(u64, @intCast(r_sym)) << 32) | elf.R_X86_64_PC32;
                                        log.debug("rewriting R_X86_64_REX_GOTPCRELX -> R_X86_64_PC32: MOV -> LEA", .{});
                                        break :blk;
                                    },
                                    .cmp => {
                                        // rewrite to CMP MI encoding
                                        const new_inst = Instruction{
                                            .tag = .cmp,
                                            .enc = .mi,
                                            .data = Instruction.Data.mi(RegisterOrMemory.reg(dst), 0x0),
                                        };
                                        try new_inst.encode(writer);

                                        const r_sym = rel.r_sym();
                                        rel.r_info = (@as(u64, @intCast(r_sym)) << 32) | elf.R_X86_64_32;
                                        rel.r_addend = 0;
                                        log.debug("rewriting R_X86_64_REX_GOTPCRELX -> R_X86_64_32: CMP r64, r/m64 -> CMP r/m64, imm32", .{});

                                        break :blk;
                                    },
                                    else => {},
                                }
                            }

                            if (elf_file.got_entries_map.contains(global)) break :blk;
                            log.debug("R_X86_64_REX_GOTPCRELX: creating GOT atom: [() -> {s}]", .{
                                tsym_name,
                            });
                            const got_atom = try elf_file.createGotAtom(global);
                            try elf_file.got_entries_map.putNoClobber(allocator, global, got_atom);
                        },
                        elf.R_X86_64_GOTPCREL => blk: {
                            const global = elf_file.globals.get(tsym_name).?;
                            if (elf_file.got_entries_map.contains(global)) break :blk;
                            log.debug("R_X86_64_GOTPCREL: creating GOT atom: [() -> {s}]", .{
                                tsym_name,
                            });
                            const got_atom = try elf_file.createGotAtom(global);
                            try elf_file.got_entries_map.putNoClobber(allocator, global, got_atom);
                        },
                        elf.R_X86_64_GOTTPOFF => blk: {
                            const global = elf_file.globals.get(tsym_name).?;
                            if (isDefinitionAvailable(elf_file, global)) {
                                // Link-time constant, try to optimize it away.
                                var disassembler = Disassembler.init(code[rel.r_offset - 3 ..]);
                                const maybe_inst = disassembler.next() catch break :blk;
                                const inst = maybe_inst orelse break :blk;

                                if (inst.enc != .rm) break :blk;
                                const rm = inst.data.rm;
                                if (rm.reg_or_mem != .mem) break :blk;
                                if (rm.reg_or_mem.mem.base != .rip) break :blk;
                                const dst = rm.reg;

                                var stream = std.io.fixedBufferStream(code[rel.r_offset - 3 ..][0..7]);
                                const writer = stream.writer();

                                switch (inst.tag) {
                                    .mov => {
                                        // rewrite to MOV MI encoding
                                        const new_inst = Instruction{
                                            .tag = .mov,
                                            .enc = .mi,
                                            .data = Instruction.Data.mi(RegisterOrMemory.reg(dst), 0x0),
                                        };
                                        try new_inst.encode(writer);

                                        const r_sym = rel.r_sym();
                                        rel.r_info = (@as(u64, @intCast(r_sym)) << 32) | elf.R_X86_64_TPOFF32;
                                        rel.r_addend = 0;
                                        log.debug("rewriting R_X86_64_GOTTPOFF -> R_X86_64_TPOFF32: MOV r64, r/m64 -> MOV r/m64, imm32", .{});
                                    },
                                    else => {},
                                }
                            }
                        },
                        elf.R_X86_64_DTPOFF64 => {
                            const global = elf_file.globals.get(tsym_name).?;
                            if (isDefinitionAvailable(elf_file, global)) {
                                // rewrite into TPOFF32
                                const r_sym = rel.r_sym();
                                rel.r_info = (@as(u64, @intCast(r_sym)) << 32) | elf.R_X86_64_TPOFF32;
                                rel.r_addend = 0;
                                log.debug("rewriting R_X86_64_DTPOFF64 -> R_X86_64_TPOFF32", .{});
                            }
                        },
                        else => {},
                    }

                    atom.relocs.appendAssumeCapacity(rel);
                }
            }

            try atom.code.appendSlice(allocator, code);
            try elf_file.addAtomToSection(atom, tshdr_ndx);
        },
        else => {},
    };
}

pub inline fn getShdrs(self: Object) []const elf.Elf64_Shdr {
    return @as(
        [*]const elf.Elf64_Shdr,
        @ptrCast(@alignCast(&self.data[self.header.e_shoff])),
    )[0..self.header.e_shnum];
}

inline fn getShdrContents(self: Object, index: u16) []const u8 {
    const shdr = self.getShdrs()[index];
    return self.data[shdr.sh_offset..][0..shdr.sh_size];
}

pub fn getSourceSymtab(self: Object) []const elf.Elf64_Sym {
    const index = self.symtab_index orelse return &[0]elf.Elf64_Sym{};
    const shdr = self.getShdrs()[index];
    const nsyms = @divExact(shdr.sh_size, @sizeOf(elf.Elf64_Sym));
    return @as(
        [*]const elf.Elf64_Sym,
        @ptrCast(@alignCast(&self.data[shdr.sh_offset])),
    )[0..nsyms];
}

pub fn getSourceStrtab(self: Object) []const u8 {
    const index = self.symtab_index orelse return &[0]u8{};
    const shdr = self.getShdrs()[index];
    return self.getShdrContents(@as(u16, @intCast(shdr.sh_link)));
}

pub fn getSourceShstrtab(self: Object) []const u8 {
    return self.getShdrContents(self.header.e_shstrndx);
}

pub fn getSourceSymbol(self: Object, index: u32) ?elf.Elf64_Sym {
    const symtab = self.getSourceSymtab();
    if (index >= symtab.len) return null;
    return symtab[index];
}

pub fn getSourceSymbolName(self: Object, index: u32) []const u8 {
    const sym = self.getSourceSymtab()[index];
    if (sym.st_info & 0xf == elf.STT_SECTION) {
        const shdr = self.getShdrs()[sym.st_shndx];
        return self.getShString(shdr.sh_name);
    } else {
        return self.getString(sym.st_name);
    }
}

pub fn getSymbolPtr(self: *Object, index: u32) *elf.Elf64_Sym {
    return &self.symtab.items[index];
}

pub fn getSymbol(self: Object, index: u32) elf.Elf64_Sym {
    return self.symtab.items[index];
}

pub fn getSymbolName(self: Object, index: u32) []const u8 {
    const sym = self.getSymbol(index);
    return self.getString(sym.st_name);
}

pub fn getAtomForSymbol(self: Object, sym_index: u32) ?*Atom {
    return self.atom_table.get(sym_index);
}

pub fn getString(self: Object, off: u32) []const u8 {
    const strtab = self.getSourceStrtab();
    assert(off < strtab.len);
    return mem.sliceTo(@as([*:0]const u8, @ptrCast(strtab.ptr + off)), 0);
}

pub fn getShString(self: Object, off: u32) []const u8 {
    const shstrtab = self.getSourceShstrtab();
    assert(off < shstrtab.len);
    return mem.sliceTo(@as([*:0]const u8, @ptrCast(shstrtab.ptr + off)), 0);
}

fn isDefinitionAvailable(elf_file: *Elf, global: Elf.SymbolWithLoc) bool {
    const sym = if (global.file) |file| sym: {
        const object = elf_file.objects.items[file];
        break :sym object.symtab.items[global.sym_index];
    } else elf_file.locals.items[global.sym_index];
    return sym.st_info & 0xf != elf.STT_NOTYPE or sym.st_shndx != elf.SHN_UNDEF;
}
