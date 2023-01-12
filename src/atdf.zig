const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Database = @import("Database.zig");
const EntityId = Database.EntityId;

const xml = @import("xml.zig");

const log = std.log.scoped(.atdf);

const InterruptGroupEntry = struct {
    name: []const u8,
    index: i32,
    description: ?[]const u8,
};

const Context = struct {
    db: *Database,
    interrupt_groups: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(InterruptGroupEntry)) = .{},

    fn deinit(ctx: *Context) void {
        {
            var it = ctx.interrupt_groups.iterator();
            while (it.next()) |entry|
                entry.value_ptr.deinit(ctx.db.gpa);
        }

        ctx.interrupt_groups.deinit(ctx.db.gpa);
    }
};

// TODO: scratchpad datastructure for temporary string based relationships,
// then stitch it all together in the end
pub fn loadIntoDb(db: *Database, doc: xml.Doc) !void {
    var ctx = Context{ .db = db };
    defer ctx.deinit();

    const root = try doc.getRootElement();
    var module_it = root.iterate(&.{"modules"}, "module");
    while (module_it.next()) |entry|
        try loadModuleType(&ctx, entry);

    var device_it = root.iterate(&.{"devices"}, "device");
    while (device_it.next()) |entry|
        try loadDevice(&ctx, entry);

    db.assertValid();
}

fn loadDevice(ctx: *Context, node: xml.Node) !void {
    validateAttrs(node, &.{
        "architecture",
        "name",
        "family",
        "series",
    });

    const name = node.getAttribute("name") orelse return error.NoDeviceName;
    const arch = node.getAttribute("architecture") orelse return error.NoDeviceArch;
    const family = node.getAttribute("family") orelse return error.NoDeviceFamily;

    const db = ctx.db;
    const id = try db.createDevice(.{
        .name = name,
        .arch = archFromStr(arch),
    });
    errdefer db.destroyEntity(id);

    try db.addDeviceProperty(id, "arch", arch);
    try db.addDeviceProperty(id, "family", family);
    if (node.getAttribute("series")) |series|
        try db.addDeviceProperty(id, "series", series);

    var module_it = node.iterate(&.{"peripherals"}, "module");
    while (module_it.next()) |module_node|
        loadModuleInstances(ctx, module_node, id) catch |err| {
            log.warn("failed to instantiate module: {}", .{err});
        };

    if (node.findChild("interrupts")) |interrupts_node|
        try loadInterrupts(ctx, interrupts_node, id);

    try inferPeripheralOffsets(ctx);
    try inferEnumSizes(ctx);

    // TODO:
    // address-space.memory-segment
    // events.generators.generator
    // events.users.user
    // interfaces.interface.parameters.param
    // parameters.param

    // property-groups.property-group.property
}

fn loadInterrupts(ctx: *Context, node: xml.Node, device_id: EntityId) !void {
    var interrupt_it = node.iterate(&.{}, "interrupt");
    while (interrupt_it.next()) |interrupt_node|
        try loadInterrupt(ctx, interrupt_node, device_id);

    var interrupt_group_it = node.iterate(&.{}, "interrupt-group");
    while (interrupt_group_it.next()) |interrupt_group_node|
        try loadInterruptGroup(ctx, interrupt_group_node, device_id);
}

fn loadInterruptGroup(ctx: *Context, node: xml.Node, device_id: EntityId) !void {
    const db = ctx.db;
    const module_instance = node.getAttribute("module-instance") orelse return error.MissingModuleInstance;
    const name_in_module = node.getAttribute("name-in-module") orelse return error.MissingNameInModule;
    const index_str = node.getAttribute("index") orelse return error.MissingInterruptGroupIndex;
    const index = try std.fmt.parseInt(i32, index_str, 0);

    if (ctx.interrupt_groups.get(name_in_module)) |group_list| {
        for (group_list.items) |entry| {
            const full_name = try std.mem.join(db.arena.allocator(), "_", &.{ module_instance, entry.name });
            _ = try db.createInterrupt(device_id, .{
                .name = full_name,
                .index = entry.index + index,
                .description = entry.description,
            });
        }
    }
}

fn archFromStr(str: []const u8) Database.Arch {
    return if (std.mem.eql(u8, "ARM926EJ-S", str))
        .arm926ej_s
    else if (std.mem.eql(u8, "AVR8", str))
        .avr8
    else if (std.mem.eql(u8, "AVR8L", str))
        .avr8l
    else if (std.mem.eql(u8, "AVR8X", str))
        .avr8x
    else if (std.mem.eql(u8, "AVR8_XMEGA", str))
        .avr8xmega
    else if (std.mem.eql(u8, "CORTEX-A5", str))
        .cortex_a5
    else if (std.mem.eql(u8, "CORTEX-A7", str))
        .cortex_a7
    else if (std.mem.eql(u8, "CORTEX-M0PLUS", str))
        .cortex_m0plus
    else if (std.mem.eql(u8, "CORTEX-M23", str))
        .cortex_m23
    else if (std.mem.eql(u8, "CORTEX-M4", str))
        .cortex_m4
    else if (std.mem.eql(u8, "CORTEX-M7", str))
        .cortex_m7
    else if (std.mem.eql(u8, "MIPS", str))
        .mips
    else
        .unknown;
}

// This function is intended to normalize the struct layout of some peripheral
// instances. Like in ATmega328P there will be register groups with offset of 0
// and then the registers themselves have their absolute offset. We'd like to
// make it easier to dedupe generated types, so this will move the offset of
// the register group to the beginning of its registers (and adjust registers
// accordingly). This should make it easier to determine what register groups
// might be of the same "type".
fn inferPeripheralOffsets(ctx: *Context) !void {
    const db = ctx.db;
    // only infer the peripheral offset if there is only one instance for a given type.
    var type_counts = std.AutoArrayHashMap(EntityId, struct { count: usize, instance_id: EntityId }).init(db.gpa);
    defer type_counts.deinit();

    var instance_it = db.instances.peripherals.iterator();
    while (instance_it.next()) |instance_entry| {
        const instance_id = instance_entry.key_ptr.*;
        const type_id = instance_entry.value_ptr.*;
        if (type_counts.getEntry(type_id)) |entry|
            entry.value_ptr.count += 1
        else
            try type_counts.put(type_id, .{
                .count = 1,
                .instance_id = instance_id,
            });
    }

    var type_it = type_counts.iterator();
    while (type_it.next()) |type_entry| if (type_entry.value_ptr.count == 1) {
        const type_id = type_entry.key_ptr.*;
        const instance_id = type_entry.value_ptr.instance_id;
        inferPeripheralOffset(ctx, type_id, instance_id) catch |err|
            log.warn("failed to infer peripheral instance offset: {}", .{err});
    };
}

fn inferPeripheralOffset(ctx: *Context, type_id: EntityId, instance_id: EntityId) !void {
    const db = ctx.db;
    // TODO: assert that there's only one instance using this type

    var min_offset: ?u64 = null;
    // first find the min offset of all the registers for this peripheral
    const register_set = db.children.registers.get(type_id) orelse return;
    var register_it = register_set.iterator();
    while (register_it.next()) |register_entry| {
        const register_id = register_entry.key_ptr.*;
        const offset = db.attrs.offset.get(register_id) orelse continue;

        if (min_offset == null)
            min_offset = offset
        else
            min_offset = std.math.min(min_offset.?, offset);
    }

    if (min_offset == null)
        return error.NoRegisters;

    const instance_offset: u64 = db.attrs.offset.get(instance_id) orelse 0;
    try db.attrs.offset.put(db.gpa, instance_id, instance_offset + min_offset.?);

    register_it = register_set.iterator();
    while (register_it.next()) |register_entry| {
        const register_id = register_entry.key_ptr.*;
        if (db.attrs.offset.getEntry(register_id)) |offset_entry|
            offset_entry.value_ptr.* -= min_offset.?;
    }
}

// for each enum in the database get its max value, each field that references
// it, and determine the size of the enum
fn inferEnumSizes(ctx: *Context) !void {
    const db = ctx.db;
    var enum_it = db.types.enums.iterator();
    while (enum_it.next()) |entry| {
        const enum_id = entry.key_ptr.*;
        inferEnumSize(db, enum_id) catch |err| {
            log.warn("failed to infer size of enum '{s}': {}", .{
                db.attrs.name.get(enum_id) orelse "<unknown>",
                err,
            });
        };
    }
}

fn inferEnumSize(db: *Database, enum_id: EntityId) !void {
    const max_value = blk: {
        const enum_fields = db.children.enum_fields.get(enum_id) orelse return error.MissingEnumFields;
        var ret: u32 = 0;
        var it = enum_fields.iterator();
        while (it.next()) |entry| {
            const enum_field_id = entry.key_ptr.*;
            const value = db.types.enum_fields.get(enum_field_id).?;
            ret = std.math.max(ret, value);
        }

        break :blk ret;
    };

    var field_sizes = std.ArrayList(u64).init(db.gpa);
    defer field_sizes.deinit();

    var it = db.attrs.@"enum".iterator();
    while (it.next()) |entry| {
        const field_id = entry.key_ptr.*;
        const other_enum_id = entry.value_ptr.*;
        assert(db.entityIs("type.field", field_id));
        if (other_enum_id != enum_id)
            continue;

        const field_size = db.attrs.size.get(field_id) orelse continue;
        try field_sizes.append(field_size);
    }

    // if all the field sizes are the same, and the max value can fit in there,
    // then set the size of the enum. If there are no usages of an enum, then
    // assign it the smallest value possible
    const size = if (field_sizes.items.len == 0)
        if (max_value == 0)
            1
        else
            std.math.log2_int(u64, max_value) + 1
    else blk: {
        var ret: ?u64 = null;
        for (field_sizes.items) |field_size| {
            if (ret == null)
                ret = field_size
            else if (ret.? != field_size)
                return error.InconsistentEnumSizes;
        }

        if (max_value > 0 and (std.math.log2_int(u64, max_value) + 1) > ret.?)
            return error.EnumMaxValueTooBig;

        break :blk ret.?;
    };

    try db.attrs.size.put(db.gpa, enum_id, size);
}

// TODO: instances use name in module
fn getInlinedRegisterGroup(parent_node: xml.Node, parent_name: []const u8) ?xml.Node {
    var register_group_it = parent_node.iterate(&.{}, "register-group");
    const rg_node = register_group_it.next() orelse return null;
    const rg_name = rg_node.getAttribute("name") orelse return null;
    log.debug("rg name is {s}, parent is {s}", .{ rg_name, parent_name });
    if (register_group_it.next() != null) {
        log.debug("register group not alone", .{});
        return null;
    }

    return if (std.mem.eql(u8, rg_name, parent_name))
        rg_node
    else
        null;
}

// module instances are listed under atdf-tools-device-file.modules.
fn loadModuleType(ctx: *Context, node: xml.Node) !void {
    validateAttrs(node, &.{
        "oldname",
        "name",
        "id",
        "version",
        "caption",
        "name2",
    });

    const db = ctx.db;
    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    log.debug("{}: creating peripheral type", .{id});
    try db.types.peripherals.put(db.gpa, id, {});
    const name = node.getAttribute("name") orelse return error.ModuleTypeMissingName;
    try db.addName(id, name);

    if (node.getAttribute("caption")) |caption|
        try db.addDescription(id, caption);

    var value_group_it = node.iterate(&.{}, "value-group");
    while (value_group_it.next()) |value_group_node|
        try loadEnum(ctx, value_group_node, id);

    var interrupt_group_it = node.iterate(&.{}, "interrupt-group");
    while (interrupt_group_it.next()) |interrupt_group_node|
        try loadModuleInterruptGroup(ctx, interrupt_group_node);

    // special case but the most common, if there is only one register
    // group and it's name matches the peripheral, then inline the
    // registers. This operation needs to be done in
    // `loadModuleInstance()` as well
    if (getInlinedRegisterGroup(node, name)) |register_group_node| {
        try loadRegisterGroupChildren(ctx, register_group_node, id);
    } else {
        var register_group_it = node.iterate(&.{}, "register-group");
        while (register_group_it.next()) |register_group_node|
            try loadRegisterGroup(ctx, register_group_node, id);
    }
}

fn loadModuleInterruptGroup(ctx: *Context, node: xml.Node) !void {
    const name = node.getAttribute("name") orelse return error.MissingInterruptGroupName;
    try ctx.interrupt_groups.put(ctx.db.gpa, name, .{});

    var interrupt_it = node.iterate(&.{}, "interrupt");
    while (interrupt_it.next()) |interrupt_node|
        try loadModuleInterruptGroupEntry(ctx, interrupt_node, name);
}

fn loadModuleInterruptGroupEntry(
    ctx: *Context,
    node: xml.Node,
    group_name: []const u8,
) !void {
    assert(ctx.interrupt_groups.contains(group_name));
    const list = ctx.interrupt_groups.getEntry(group_name).?.value_ptr;

    try list.append(ctx.db.gpa, .{
        .name = node.getAttribute("name") orelse return error.MissingInterruptName,
        .index = if (node.getAttribute("index")) |index_str|
            try std.fmt.parseInt(i32, index_str, 0)
        else
            return error.MissingInterruptIndex,
        .description = node.getAttribute("caption"),
    });
}

fn loadRegisterGroupChildren(
    ctx: *Context,
    node: xml.Node,
    dest_id: EntityId,
) !void {
    const db = ctx.db;
    assert(db.entityIs("type.peripheral", dest_id) or
        db.entityIs("type.register_group", dest_id));

    var mode_it = node.iterate(&.{}, "mode");
    while (mode_it.next()) |mode_node|
        loadMode(ctx, mode_node, dest_id) catch |err| {
            log.err("{}: failed to load mode: {}", .{ dest_id, err });
        };

    var register_it = node.iterate(&.{}, "register");
    while (register_it.next()) |register_node|
        try loadRegister(ctx, register_node, dest_id);
}

// loads a register group which is under a peripheral or under another
// register-group
fn loadRegisterGroup(
    ctx: *Context,
    node: xml.Node,
    parent_id: EntityId,
) !void {
    const db = ctx.db;
    assert(db.entityIs("type.peripheral", parent_id) or
        db.entityIs("type.register_group", parent_id));

    if (db.entityIs("type.peripheral", parent_id)) {
        validateAttrs(node, &.{
            "name",
            "caption",
            "aligned",
            "section",
            "size",
        });
    } else if (db.entityIs("type.register_group", parent_id)) {
        validateAttrs(node, &.{
            "name",
            "modes",
            "size",
            "name-in-module",
            "caption",
            "count",
            "start-index",
            "offset",
        });
    }

    // TODO: if a register group has the same name as the module then the
    // registers should be flattened in the namespace
    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    log.debug("{}: creating register group", .{id});
    try db.types.register_groups.put(db.gpa, id, {});
    if (node.getAttribute("name")) |name|
        try db.addName(id, name);

    if (node.getAttribute("caption")) |caption|
        try db.addDescription(id, caption);

    if (node.getAttribute("size")) |size|
        try db.addSize(id, try std.fmt.parseInt(u64, size, 0));

    try loadRegisterGroupChildren(ctx, node, id);

    // TODO: register-group
    // connect with parent
    try db.addChild("type.register_group", parent_id, id);
}

fn loadMode(ctx: *Context, node: xml.Node, parent_id: EntityId) !void {
    const db = ctx.db;
    assert(db.entityIs("type.peripheral", parent_id) or
        db.entityIs("type.register_group", parent_id) or
        db.entityIs("type.register", parent_id));

    validateAttrs(node, &.{
        "value",
        "mask",
        "name",
        "qualifier",
        "caption",
    });

    const id = try db.createMode(parent_id, .{
        .name = node.getAttribute("name") orelse return error.MissingModeName,
        .description = node.getAttribute("caption"),
        .value = node.getAttribute("value") orelse return error.MissingModeValue,
        .qualifier = node.getAttribute("qualifier") orelse return error.MissingModeQualifier,
    });
    errdefer db.destroyEntity(id);

    // TODO: "mask": "optional",
}

// search for modes that the parent entity owns, and if the name matches,
// then we have our entry. If not found then the input is malformed.
// TODO: assert unique mode name
fn assignModesToEntity(
    ctx: *Context,
    id: EntityId,
    parent_id: EntityId,
    mode_names: []const u8,
) !void {
    const db = ctx.db;
    var modes = Database.Modes{};
    errdefer modes.deinit(db.gpa);

    const mode_set = if (db.children.modes.get(parent_id)) |mode_set|
        mode_set
    else {
        log.warn("{}: failed to find mode set", .{id});
        return;
    };

    var tok_it = std.mem.tokenize(u8, mode_names, " ");
    while (tok_it.next()) |mode_str| {
        var it = mode_set.iterator();
        while (it.next()) |mode_entry| {
            const mode_id = mode_entry.key_ptr.*;
            if (db.attrs.name.get(mode_id)) |name|
                if (std.mem.eql(u8, name, mode_str)) {
                    const result = try db.attrs.modes.getOrPut(db.gpa, id);
                    if (!result.found_existing)
                        result.value_ptr.* = .{};

                    try result.value_ptr.put(db.gpa, mode_id, {});
                    log.debug("{}: assigned mode '{s}'", .{ id, name });
                    return;
                };
        } else {
            if (db.attrs.name.get(id)) |name|
                log.warn("failed to find mode '{s}' for '{s}'", .{
                    mode_str,
                    name,
                })
            else
                log.warn("failed to find mode '{s}'", .{
                    mode_str,
                });

            return error.MissingMode;
        }
    }

    if (modes.count() > 0)
        try db.attrs.modes.put(db.gpa, id, modes);
}

fn loadRegister(
    ctx: *Context,
    node: xml.Node,
    parent_id: EntityId,
) !void {
    const db = ctx.db;
    assert(db.entityIs("type.register_group", parent_id) or
        db.entityIs("type.peripheral", parent_id));

    validateAttrs(node, &.{
        "rw",
        "name",
        "access-size",
        "modes",
        "initval",
        "size",
        "access",
        "mask",
        "bit-addressable",
        "atomic-op",
        "ocd-rw",
        "caption",
        "count",
        "offset",
    });

    const name = node.getAttribute("name") orelse return error.MissingRegisterName;

    const id = try db.createRegister(parent_id, .{
        .name = name,
        .description = node.getAttribute("caption"),
        //  size is in bytes, convert to bits
        .size = if (node.getAttribute("size")) |size_str|
            @as(u64, 8) * try std.fmt.parseInt(u64, size_str, 0)
        else
            return error.MissingRegisterSize,
        .offset = if (node.getAttribute("offset")) |offset_str|
            try std.fmt.parseInt(u64, offset_str, 0)
        else
            return error.MissingRegisterOffset,
    });
    errdefer db.destroyEntity(id);

    if (node.getAttribute("modes")) |modes|
        assignModesToEntity(ctx, id, parent_id, modes) catch {
            log.warn("failed to find mode '{s}' for register '{s}'", .{
                modes,
                name,
            });
        };

    if (node.getAttribute("initval")) |initval_str| {
        const initval = try std.fmt.parseInt(u64, initval_str, 0);
        try db.addResetValue(id, initval);
    }

    if (node.getAttribute("rw")) |access_str| blk: {
        const access = accessFromString(access_str) catch break :blk;
        switch (access) {
            .read_only, .write_only => try db.attrs.access.put(
                db.gpa,
                id,
                access,
            ),
            else => {},
        }
    }

    // assumes that modes are parsed before registers in the register group
    var mode_it = node.iterate(&.{}, "mode");
    while (mode_it.next()) |mode_node|
        loadMode(ctx, mode_node, id) catch |err| {
            log.err("{}: failed to load mode: {}", .{ id, err });
        };

    var field_it = node.iterate(&.{}, "bitfield");
    while (field_it.next()) |field_node|
        loadField(ctx, field_node, id) catch {};
}

fn loadField(ctx: *Context, node: xml.Node, register_id: EntityId) !void {
    const db = ctx.db;
    assert(db.entityIs("type.register", register_id));
    validateAttrs(node, &.{
        "caption",
        "lsb",
        "mask",
        "modes",
        "name",
        "rw",
        "value",
        "values",
    });

    const name = node.getAttribute("name") orelse return error.MissingFieldName;
    const mask_str = node.getAttribute("mask") orelse return error.MissingFieldMask;
    const mask = std.fmt.parseInt(u64, mask_str, 0) catch |err| {
        log.warn("failed to parse mask '{s}' of bitfield '{s}'", .{
            mask_str,
            name,
        });

        return err;
    };

    const offset = @ctz(mask);
    const leading_zeroes = @clz(mask);

    // if the bitfield is discontiguous then we'll break it up into single bit
    // fields. This assumes that the order of the bitfields is in order
    if (@popCount(mask) != @as(u64, 64) - leading_zeroes - offset) {
        var bit_count: u32 = 0;
        var i = offset;
        while (i < 32) : (i += 1) {
            if (0 != (@as(u64, 1) << @intCast(u5, i)) & mask) {
                const field_name = try std.fmt.allocPrint(db.arena.allocator(), "{s}_bit{}", .{
                    name,
                    bit_count,
                });
                bit_count += 1;

                const id = try db.createField(register_id, .{
                    .name = field_name,
                    .description = node.getAttribute("caption"),
                    .size = 1,
                    .offset = i,
                });
                errdefer db.destroyEntity(id);

                if (node.getAttribute("modes")) |modes|
                    assignModesToEntity(ctx, id, register_id, modes) catch {
                        log.warn("failed to find mode '{s}' for field '{s}'", .{
                            modes,
                            name,
                        });
                    };

                if (node.getAttribute("rw")) |access_str| blk: {
                    const access = accessFromString(access_str) catch break :blk;
                    switch (access) {
                        .read_only, .write_only => try db.attrs.access.put(
                            db.gpa,
                            id,
                            access,
                        ),
                        else => {},
                    }
                }

                // discontiguous fields like this don't get to have enums
            }
        }
    } else {
        const width = @popCount(mask);

        const id = try db.createField(register_id, .{
            .name = name,
            .description = node.getAttribute("caption"),
            .size = width,
            .offset = offset,
        });
        errdefer db.destroyEntity(id);

        // TODO: modes are space delimited, and multiple can apply to a single bitfield or register
        if (node.getAttribute("modes")) |modes|
            assignModesToEntity(ctx, id, register_id, modes) catch {
                log.warn("failed to find mode '{s}' for field '{s}'", .{
                    modes,
                    name,
                });
            };

        if (node.getAttribute("rw")) |access_str| blk: {
            const access = accessFromString(access_str) catch break :blk;
            switch (access) {
                .read_only, .write_only => try db.attrs.access.put(
                    db.gpa,
                    id,
                    access,
                ),
                else => {},
            }
        }

        // values _should_ match to a known enum
        // TODO: namespace the enum to the appropriate register, register_group, or peripheral
        if (node.getAttribute("values")) |values| {
            var it = db.types.enums.iterator();
            while (it.next()) |entry| {
                const enum_id = entry.key_ptr.*;
                const enum_name = db.attrs.name.get(enum_id) orelse continue;
                if (std.mem.eql(u8, enum_name, values)) {
                    log.debug("{}: assigned enum '{s}'", .{ id, enum_name });
                    try db.attrs.@"enum".put(db.gpa, id, enum_id);
                    break;
                }
            } else log.debug("{}: failed to find corresponding enum", .{id});
        }
    }
}

fn accessFromString(str: []const u8) !Database.Access {
    return if (std.mem.eql(u8, "RW", str))
        .read_write
    else if (std.mem.eql(u8, "R", str))
        .read_only
    else if (std.mem.eql(u8, "W", str))
        .write_only
    else
        error.InvalidAccessStr;
}

fn loadEnum(
    ctx: *Context,
    node: xml.Node,
    peripheral_id: EntityId,
) !void {
    const db = ctx.db;
    assert(db.entityIs("type.peripheral", peripheral_id));

    validateAttrs(node, &.{
        "name",
        "caption",
    });

    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    log.debug("{}: creating enum", .{id});
    const name = node.getAttribute("name") orelse return error.MissingEnumName;
    try db.types.enums.put(db.gpa, id, {});
    try db.addName(id, name);
    if (node.getAttribute("caption")) |caption|
        try db.addDescription(id, caption);

    var value_it = node.iterate(&.{}, "value");
    while (value_it.next()) |value_node|
        loadEnumField(ctx, value_node, id) catch {};

    try db.addChild("type.enum", peripheral_id, id);
}

fn loadEnumField(
    ctx: *Context,
    node: xml.Node,
    enum_id: EntityId,
) !void {
    const db = ctx.db;
    assert(db.entityIs("type.enum", enum_id));

    validateAttrs(node, &.{
        "name",
        "caption",
        "value",
    });

    const name = node.getAttribute("name") orelse return error.MissingEnumFieldName;
    const value_str = node.getAttribute("value") orelse {
        log.warn("enum missing value: {s}", .{name});
        return error.MissingEnumFieldValue;
    };

    const value = std.fmt.parseInt(u32, value_str, 0) catch |err| {
        log.warn("failed to parse enum value '{s}' of enum field '{s}'", .{
            value_str,
            name,
        });
        return err;
    };

    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    log.debug("{}: creating enum field with value: {}", .{ id, value });
    try db.addName(id, name);
    try db.types.enum_fields.put(db.gpa, id, value);
    if (node.getAttribute("caption")) |caption|
        try db.addDescription(id, caption);

    try db.addChild("type.enum_field", enum_id, id);
}

// module instances are listed under atdf-tools-device-file.devices.device.peripherals
fn loadModuleInstances(
    ctx: *Context,
    node: xml.Node,
    device_id: EntityId,
) !void {
    const db = ctx.db;
    const module_name = node.getAttribute("name") orelse return error.MissingModuleName;
    const type_id = blk: {
        var periph_it = db.types.peripherals.iterator();
        while (periph_it.next()) |entry| {
            if (db.attrs.name.get(entry.key_ptr.*)) |entry_name|
                if (std.mem.eql(u8, entry_name, module_name))
                    break :blk entry.key_ptr.*;
        } else {
            log.warn("failed to find the '{s}' peripheral type", .{
                module_name,
            });
            return error.MissingPeripheralType;
        }
    };

    var instance_it = node.iterate(&.{}, "instance");
    while (instance_it.next()) |instance_node|
        try loadModuleInstance(ctx, instance_node, device_id, type_id);
}

fn peripheralIsInlined(db: Database, id: EntityId) bool {
    assert(db.entityIs("type.peripheral", id));
    return db.children.register_groups.get(id) == null;
}

fn loadModuleInstance(
    ctx: *Context,
    node: xml.Node,
    device_id: EntityId,
    peripheral_type_id: EntityId,
) !void {
    const db = ctx.db;
    assert(db.entityIs("type.peripheral", peripheral_type_id));

    validateAttrs(node, &.{
        "oldname",
        "name",
        "caption",
    });

    // register-group never has an offset in a module, so we can safely assume
    // that they're used as variants of a peripheral, and never used like
    // clusters in SVD.
    return if (peripheralIsInlined(db.*, peripheral_type_id))
        loadModuleInstanceFromPeripheral(ctx, node, device_id, peripheral_type_id)
    else
        loadModuleInstanceFromRegisterGroup(ctx, node, device_id, peripheral_type_id);
}

fn loadModuleInstanceFromPeripheral(
    ctx: *Context,
    node: xml.Node,
    device_id: EntityId,
    peripheral_type_id: EntityId,
) !void {
    const db = ctx.db;
    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    log.debug("{}: creating module instance", .{id});
    const name = node.getAttribute("name") orelse return error.MissingInstanceName;
    try db.instances.peripherals.put(db.gpa, id, peripheral_type_id);
    try db.addName(id, name);
    if (node.getAttribute("caption")) |description|
        try db.addDescription(id, description);

    if (getInlinedRegisterGroup(node, name)) |register_group_node| {
        log.debug("{}: inlining", .{id});
        const offset_str = register_group_node.getAttribute("offset") orelse return error.MissingPeripheralOffset;
        const offset = try std.fmt.parseInt(u64, offset_str, 0);
        try db.addOffset(id, offset);
    } else {
        return error.Todo;
        //unreachable;
        //var register_group_it = node.iterate(&.{}, "register-group");
        //while (register_group_it.next()) |register_group_node|
        //    loadRegisterGroupInstance(db, register_group_node, id, peripheral_type_id) catch {
        //        log.warn("skipping register group instance in {s}", .{name});
        //    };
    }

    var signal_it = node.iterate(&.{"signals"}, "signal");
    while (signal_it.next()) |signal_node|
        try loadSignal(ctx, signal_node, id);

    try db.addChild("instance.peripheral", device_id, id);
}

fn loadModuleInstanceFromRegisterGroup(
    ctx: *Context,
    node: xml.Node,
    device_id: EntityId,
    peripheral_type_id: EntityId,
) !void {
    const db = ctx.db;
    const register_group_node = blk: {
        var it = node.iterate(&.{}, "register-group");
        const ret = it.next() orelse return error.MissingInstanceRegisterGroup;
        if (it.next() != null) {
            return error.TodoInstanceWithMultipleRegisterGroups;
        }

        break :blk ret;
    };

    const name = node.getAttribute("name") orelse return error.MissingInstanceName;
    const name_in_module = register_group_node.getAttribute("name-in-module") orelse return error.MissingNameInModule;
    const register_group_id = blk: {
        const register_group_set = db.children.register_groups.get(peripheral_type_id) orelse return error.MissingRegisterGroup;
        var it = register_group_set.iterator();
        break :blk while (it.next()) |entry| {
            const register_group_id = entry.key_ptr.*;
            const register_group_name = db.attrs.name.get(register_group_id) orelse continue;
            if (std.mem.eql(u8, name_in_module, register_group_name))
                break register_group_id;
        } else return error.MissingRegisterGroup;
    };

    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    const offset_str = register_group_node.getAttribute("offset") orelse return error.MissingOffset;
    const offset = try std.fmt.parseInt(u64, offset_str, 0);

    try db.instances.peripherals.put(db.gpa, id, register_group_id);
    try db.addName(id, name);
    try db.addOffset(id, offset);

    if (node.getAttribute("caption")) |description|
        try db.addDescription(id, description);

    try db.addChild("instance.peripheral", device_id, id);
}

fn loadRegisterGroupInstance(
    ctx: *Context,
    node: xml.Node,
    peripheral_id: EntityId,
    peripheral_type_id: EntityId,
) !void {
    const db = ctx.db;
    assert(db.entityIs("instance.peripheral", peripheral_id));
    assert(db.entityIs("type.peripheral", peripheral_type_id));
    validateAttrs(node, &.{
        "name",
        "address-space",
        "version",
        "size",
        "name-in-module",
        "caption",
        "id",
        "offset",
    });

    const id = db.createEntity();
    errdefer db.destroyEntity(id);

    log.debug("{}: creating register group instance", .{id});
    const name = node.getAttribute("name") orelse return error.MissingInstanceName;
    // TODO: this isn't always a set value, not sure what to do if it's left out
    const name_in_module = node.getAttribute("name-in-module") orelse {
        log.warn("no 'name-in-module' for register group '{s}'", .{
            name,
        });

        return error.MissingNameInModule;
    };

    const type_id = blk: {
        var type_it = (db.children.register_groups.get(peripheral_type_id) orelse
            return error.MissingRegisterGroupType).iterator();

        while (type_it.next()) |entry| {
            if (db.attrs.name.get(entry.key_ptr.*)) |entry_name|
                if (std.mem.eql(u8, entry_name, name_in_module))
                    break :blk entry.key_ptr.*;
        } else return error.MissingRegisterGroupType;
    };

    try db.instances.register_groups.put(db.gpa, id, type_id);
    try db.addName(id, name);
    if (node.getAttribute("caption")) |caption|
        try db.addDescription(id, caption);

    // size is in bytes
    if (node.getAttribute("size")) |size_str| {
        const size = try std.fmt.parseInt(u64, size_str, 0);
        try db.addSize(id, size);
    }

    if (node.getAttribute("offset")) |offset_str| {
        const offset = try std.fmt.parseInt(u64, offset_str, 0);
        try db.addOffset(id, offset);
    }

    try db.addChild("instance.register_group", peripheral_id, id);

    // TODO:
    // "address-space": "optional",
    // "version": "optional",
    // "id": "optional",
}

fn loadSignal(ctx: *Context, node: xml.Node, peripheral_id: EntityId) !void {
    const db = ctx.db;
    assert(db.entityIs("instance.peripheral", peripheral_id));
    validateAttrs(node, &.{
        "group",
        "index",
        "pad",
        "function",
        "field",
        "ioset",
    });

    // TODO: pads
}

// TODO: there are fields like irq-index
fn loadInterrupt(ctx: *Context, node: xml.Node, device_id: EntityId) !void {
    const db = ctx.db;
    assert(db.entityIs("instance.device", device_id));
    validateAttrs(node, &.{
        "index",
        "name",
        "irq-caption",
        "alternate-name",
        "irq-index",
        "caption",
        // TODO: probably connects module instance to interrupt
        "module-instance",
        "irq-name",
        "alternate-caption",
    });

    const name = node.getAttribute("name") orelse return error.MissingInterruptName;
    const index_str = node.getAttribute("index") orelse return error.MissingInterruptIndex;
    const index = std.fmt.parseInt(i32, index_str, 0) catch |err| {
        log.warn("failed to parse value '{s}' of interrupt '{s}'", .{
            index_str,
            name,
        });
        return err;
    };

    const full_name = if (node.getAttribute("module-instance")) |module_instance|
        try std.mem.join(db.arena.allocator(), "_", &.{ module_instance, name })
    else
        name;

    _ = try db.createInterrupt(device_id, .{
        .name = full_name,
        .index = index,
        .description = node.getAttribute("caption"),
    });
}

// for now just emit warning logs when the input has attributes that it shouldn't have
// TODO: better output
fn validateAttrs(node: xml.Node, attrs: []const []const u8) void {
    var it = node.iterateAttrs();
    while (it.next()) |attr| {
        for (attrs) |expected_attr| {
            if (std.mem.eql(u8, attr.key, expected_attr))
                break;
        } else log.warn("line {}: the '{s}' isn't usually found in the '{s}' element, this could mean unhandled ATDF behaviour or your input is malformed", .{
            node.impl.line,
            attr.key,
            std.mem.span(node.impl.name),
        });
    }
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const testing = @import("testing.zig");
const expectAttr = testing.expectAttr;

test "atdf.register with bitfields and enum" {
    const text =
        \\<avr-tools-device-file>
        \\  <modules>
        \\    <module caption="Real-Time Counter" id="I2116" name="RTC">
        \\      <register-group caption="Real-Time Counter" name="RTC" size="0x20">
        \\        <register caption="Control A"
        \\                  initval="0x00"
        \\                  name="CTRLA"
        \\                  offset="0x00"
        \\                  rw="RW"
        \\                  size="1">
        \\          <bitfield caption="Enable"
        \\                    mask="0x01"
        \\                    name="RTCEN"
        \\                    rw="RW"/>
        \\          <bitfield caption="Correction enable"
        \\                    mask="0x04"
        \\                    name="CORREN"
        \\                    rw="RW"/>
        \\          <bitfield caption="Prescaling Factor"
        \\                    mask="0x78"
        \\                    name="PRESCALER"
        \\                    rw="RW"
        \\                    values="RTC_PRESCALER"/>
        \\          <bitfield caption="Run In Standby"
        \\                    mask="0x80"
        \\                    name="RUNSTDBY"
        \\                    rw="RW"/>
        \\        </register>
        \\      </register-group>
        \\      <value-group caption="Prescaling Factor select" name="RTC_PRESCALER">
        \\         <value caption="RTC Clock / 1" name="DIV1" value="0x00"/>
        \\         <value caption="RTC Clock / 2" name="DIV2" value="0x01"/>
        \\      </value-group>
        \\    </module>
        \\  </modules>
        \\</avr-tools-device-file>
    ;
    var doc = try xml.Doc.fromMemory(text);
    var db = try Database.initFromAtdf(std.testing.allocator, doc);
    defer db.deinit();

    // RTC_PRESCALER enum checks
    // =========================
    const enum_id = try db.getEntityIdByName("type.enum", "RTC_PRESCALER");

    try expectAttr(db, "description", "Prescaling Factor select", enum_id);
    try expect(db.children.enum_fields.contains(enum_id));

    // DIV1 enum field checks
    // ======================
    const div1_id = try db.getEntityIdByName("type.enum_field", "DIV1");

    try expectAttr(db, "description", "RTC Clock / 1", div1_id);
    try expectEqual(@as(u32, 0), db.types.enum_fields.get(div1_id).?);

    // DIV2 enum field checks
    // ======================
    const div2_id = try db.getEntityIdByName("type.enum_field", "DIV2");

    try expectAttr(db, "description", "RTC Clock / 2", div2_id);
    try expectEqual(@as(u32, 1), db.types.enum_fields.get(div2_id).?);

    // CTRLA register checks
    // ===============
    const register_id = try db.getEntityIdByName("type.register", "CTRLA");

    // access is read-write, so its entry is omitted (we assume read-write by default)
    try expect(!db.attrs.access.contains(register_id));

    // check name and description
    try expectAttr(db, "name", "CTRLA", register_id);
    try expectAttr(db, "description", "Control A", register_id);

    // reset value of the register is 0 (initval attribute)
    try expectAttr(db, "reset_value", 0, register_id);

    // byte offset is 0
    try expectAttr(db, "offset", 0, register_id);

    // size of register is 8 bits, note that ATDF measures in bytes
    try expectAttr(db, "size", 8, register_id);

    // there will 4 registers total, they will all be children of the one register
    try expectEqual(@as(usize, 4), db.types.fields.count());
    try expectEqual(@as(usize, 4), db.children.fields.get(register_id).?.count());

    // RTCEN field checks
    // ============
    const rtcen_id = try db.getEntityIdByName("type.field", "RTCEN");

    // attributes RTCEN should/shouldn't have
    try expect(!db.attrs.access.contains(rtcen_id));

    try expectAttr(db, "description", "Enable", rtcen_id);
    try expectAttr(db, "offset", 0, rtcen_id);
    try expectAttr(db, "size", 1, rtcen_id);

    // CORREN field checks
    // ============
    const corren_id = try db.getEntityIdByName("type.field", "CORREN");

    // attributes CORREN should/shouldn't have
    try expect(!db.attrs.access.contains(corren_id));

    try expectAttr(db, "description", "Correction enable", corren_id);
    try expectAttr(db, "offset", 2, corren_id);
    try expectAttr(db, "size", 1, corren_id);

    // PRESCALER field checks
    // ============
    const prescaler_id = try db.getEntityIdByName("type.field", "PRESCALER");

    // attributes PRESCALER should/shouldn't have
    try expect(db.attrs.@"enum".contains(prescaler_id));
    try expect(!db.attrs.access.contains(prescaler_id));

    try expectAttr(db, "description", "Prescaling Factor", prescaler_id);
    try expectAttr(db, "offset", 3, prescaler_id);
    try expectAttr(db, "size", 4, prescaler_id);

    // this field has an enum value
    try expectEqual(enum_id, db.attrs.@"enum".get(prescaler_id).?);

    // RUNSTDBY field checks
    // ============
    const runstdby_id = try db.getEntityIdByName("type.field", "RUNSTDBY");

    // attributes RUNSTDBY should/shouldn't have
    try expect(!db.attrs.access.contains(runstdby_id));

    try expectAttr(db, "description", "Run In Standby", runstdby_id);
    try expectAttr(db, "offset", 7, runstdby_id);
    try expectAttr(db, "size", 1, runstdby_id);
}

test "atdf.register with mode" {
    const text =
        \\<avr-tools-device-file>
        \\  <modules>
        \\    <module caption="16-bit Timer/Counter Type A" id="I2117" name="TCA">
        \\      <register-group caption="16-bit Timer/Counter Type A" name="TCA" size="0x40">
        \\        <mode caption="Single Mode"
        \\              name="SINGLE"
        \\              qualifier="TCA.SINGLE.CTRLD.SPLITM"
        \\              value="0"/>
        \\        <mode caption="Split Mode"
        \\              name="SPLIT"
        \\              qualifier="TCA.SPLIT.CTRLD.SPLITM"
        \\              value="1"/>
        \\        <register caption="Control A"
        \\                  initval="0x00"
        \\                  modes="SINGLE"
        \\                  name="CTRLA"
        \\                  offset="0x00"
        \\                  rw="RW"
        \\                  size="1"/>
        \\      </register-group>
        \\    </module>
        \\  </modules>
        \\</avr-tools-device-file>
        \\
    ;

    var doc = try xml.Doc.fromMemory(text);
    var db = try Database.initFromAtdf(std.testing.allocator, doc);
    defer db.deinit();

    // there will only be one register
    try expectEqual(@as(usize, 1), db.types.registers.count());
    const register_id = blk: {
        var it = db.types.registers.iterator();
        break :blk it.next().?.key_ptr.*;
    };

    // the register will have one associated mode
    try expect(db.attrs.modes.contains(register_id));
    const mode_set = db.attrs.modes.get(register_id).?;
    try expectEqual(@as(usize, 1), mode_set.count());
    const mode_id = blk: {
        var it = mode_set.iterator();
        break :blk it.next().?.key_ptr.*;
    };

    // the name of the mode is 'SINGLE'
    try expectAttr(db, "name", "SINGLE", mode_id);

    // the register group should be flattened, so the mode should be a child of
    // the peripheral
    try expectEqual(@as(usize, 1), db.types.peripherals.count());
    const peripheral_id = blk: {
        var it = db.types.peripherals.iterator();
        break :blk it.next().?.key_ptr.*;
    };

    try expect(db.children.modes.contains(peripheral_id));
    const peripheral_modes = db.children.modes.get(peripheral_id).?;
    try expect(peripheral_modes.contains(mode_id));
}

test "atdf.instance of register group" {
    const text =
        \\<avr-tools-device-file>
        \\  <devices>
        \\    <device name="ATmega328P" architecture="AVR8" family="megaAVR">
        \\      <peripherals>
        \\        <module name="PORT">
        \\          <instance name="PORTB" caption="I/O Port">
        \\            <register-group name="PORTB"
        \\                            name-in-module="PORTB"
        \\                            offset="0x00"
        \\                            address-space="data"
        \\                            caption="I/O Port"/>
        \\          </instance>
        \\          <instance name="PORTC" caption="I/O Port">
        \\            <register-group name="PORTC"
        \\                            name-in-module="PORTC"
        \\                            offset="0x00"
        \\                            address-space="data"
        \\                            caption="I/O Port"/>
        \\          </instance>
        \\        </module>
        \\      </peripherals>
        \\    </device>
        \\  </devices>
        \\  <modules>
        \\    <module caption="I/O Port" name="PORT">
        \\      <register-group caption="I/O Port" name="PORTB">
        \\        <register caption="Port B Data Register"
        \\                  name="PORTB"
        \\                  offset="0x25"
        \\                  size="1"
        \\                  mask="0xFF"/>
        \\        <register caption="Port B Data Direction Register"
        \\                  name="DDRB"
        \\                  offset="0x24"
        \\                  size="1"
        \\                  mask="0xFF"/>
        \\        <register caption="Port B Input Pins"
        \\                  name="PINB"
        \\                  offset="0x23"
        \\                  size="1"
        \\                  mask="0xFF"
        \\                  ocd-rw="R"/>
        \\      </register-group>
        \\      <register-group caption="I/O Port" name="PORTC">
        \\        <register caption="Port C Data Register"
        \\                  name="PORTC"
        \\                  offset="0x28"
        \\                  size="1"
        \\                  mask="0x7F"/>
        \\        <register caption="Port C Data Direction Register"
        \\                  name="DDRC"
        \\                  offset="0x27"
        \\                  size="1"
        \\                  mask="0x7F"/>
        \\        <register caption="Port C Input Pins"
        \\                  name="PINC"
        \\                  offset="0x26"
        \\                  size="1"
        \\                  mask="0x7F"
        \\                  ocd-rw="R"/>
        \\      </register-group>
        \\      <register-group caption="I/O Port" name="PORTD">
        \\        <register caption="Port D Data Register"
        \\                  name="PORTD"
        \\                  offset="0x2B"
        \\                  size="1"
        \\                  mask="0xFF"/>
        \\        <register caption="Port D Data Direction Register"
        \\                  name="DDRD"
        \\                  offset="0x2A"
        \\                  size="1"
        \\                  mask="0xFF"/>
        \\        <register caption="Port D Input Pins"
        \\                  name="PIND"
        \\                  offset="0x29"
        \\                  size="1"
        \\                  mask="0xFF"
        \\                  ocd-rw="R"/>
        \\      </register-group>
        \\    </module>
        \\  </modules>
        \\</avr-tools-device-file>
        \\
    ;

    var doc = try xml.Doc.fromMemory(text);
    var db = try Database.initFromAtdf(std.testing.allocator, doc);
    defer db.deinit();

    try expectEqual(@as(usize, 9), db.types.registers.count());
    try expectEqual(@as(usize, 1), db.types.peripherals.count());
    try expectEqual(@as(usize, 3), db.types.register_groups.count());
    try expectEqual(@as(usize, 2), db.instances.peripherals.count());
    try expectEqual(@as(usize, 1), db.instances.devices.count());

    const portb_instance_id = try db.getEntityIdByName("instance.peripheral", "PORTB");
    try expectAttr(db, "offset", 0x23, portb_instance_id);

    // Register assertions
    const portb_id = try db.getEntityIdByName("type.register", "PORTB");
    try expectAttr(db, "offset", 0x2, portb_id);

    const ddrb_id = try db.getEntityIdByName("type.register", "DDRB");
    try expectAttr(db, "offset", 0x1, ddrb_id);

    const pinb_id = try db.getEntityIdByName("type.register", "PINB");
    try expectAttr(db, "offset", 0x0, pinb_id);
}

test "atdf.interrupts" {
    const text =
        \\<avr-tools-device-file>
        \\  <devices>
        \\    <device name="ATmega328P" architecture="AVR8" family="megaAVR">
        \\      <interrupts>
        \\        <interrupt name="TEST_VECTOR1" index="1"/>
        \\        <interrupt name="TEST_VECTOR2" index="5"/>
        \\      </interrupts>
        \\    </device>
        \\  </devices>
        \\</avr-tools-device-file>
        \\
    ;

    var doc = try xml.Doc.fromMemory(text);
    var db = try Database.initFromAtdf(std.testing.allocator, doc);
    defer db.deinit();

    const vector1_id = try db.getEntityIdByName("instance.interrupt", "TEST_VECTOR1");
    try expectEqual(@as(i32, 1), db.instances.interrupts.get(vector1_id).?);

    const vector2_id = try db.getEntityIdByName("instance.interrupt", "TEST_VECTOR2");
    try expectEqual(@as(i32, 5), db.instances.interrupts.get(vector2_id).?);
}

test "atdf.interrupts with module-instance" {
    const text =
        \\<avr-tools-device-file>
        \\  <devices>
        \\    <device name="ATmega328P" architecture="AVR8" family="megaAVR">
        \\      <interrupts>
        \\        <interrupt index="1" module-instance="CRCSCAN" name="NMI"/>
        \\        <interrupt index="2" module-instance="BOD" name="VLM"/>
        \\      </interrupts>
        \\    </device>
        \\  </devices>
        \\</avr-tools-device-file>
        \\
    ;

    var doc = try xml.Doc.fromMemory(text);
    var db = try Database.initFromAtdf(std.testing.allocator, doc);
    defer db.deinit();

    const crcscan_nmi_id = try db.getEntityIdByName("instance.interrupt", "CRCSCAN_NMI");
    try expectEqual(@as(i32, 1), db.instances.interrupts.get(crcscan_nmi_id).?);

    const bod_vlm_id = try db.getEntityIdByName("instance.interrupt", "BOD_VLM");
    try expectEqual(@as(i32, 2), db.instances.interrupts.get(bod_vlm_id).?);
}

test "atdf.interrupts with interrupt-groups" {
    const text =
        \\<avr-tools-device-file>
        \\  <devices>
        \\    <device name="ATmega328P" architecture="AVR8" family="megaAVR">
        \\      <interrupts>
        \\        <interrupt-group index="1" module-instance="PORTB" name-in-module="PORT"/>
        \\      </interrupts>
        \\    </device>
        \\  </devices>
        \\  <modules>
        \\    <module name="PORT">
        \\      <interrupt-group name="PORT">
        \\        <interrupt index="0" name="INT0"/>
        \\        <interrupt index="1" name="INT1"/>
        \\      </interrupt-group>
        \\    </module>
        \\  </modules>
        \\</avr-tools-device-file>
        \\
    ;

    var doc = try xml.Doc.fromMemory(text);
    var db = try Database.initFromAtdf(std.testing.allocator, doc);
    defer db.deinit();

    const portb_int0_id = try db.getEntityIdByName("instance.interrupt", "PORTB_INT0");
    try expectEqual(@as(i32, 1), db.instances.interrupts.get(portb_int0_id).?);

    const portb_int1_id = try db.getEntityIdByName("instance.interrupt", "PORTB_INT1");
    try expectEqual(@as(i32, 2), db.instances.interrupts.get(portb_int1_id).?);
}
