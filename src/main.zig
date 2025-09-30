const std = @import("std");
const zig_playground = @import("zig_playground");

const OrgNode = struct {
    name: []u8,
    title: []u8,
    join_date: []u8,
    reports_to: ?[]u8,
    reports: std.ArrayList(*OrgNode),

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        title: []const u8,
        join_date: []const u8,
        reports_to: ?[]const u8,
    ) !OrgNode {
        return OrgNode{
            .name = try allocator.dupe(u8, name),
            .title = try allocator.dupe(u8, title),
            .join_date = try allocator.dupe(u8, join_date),
            .reports_to = if (reports_to) |manager| try allocator.dupe(u8, manager) else null,
            .reports = .{},
        };
    }

    pub fn deinit(self: *OrgNode, allocator: std.mem.Allocator) void {
        self.reports.deinit(allocator);
        if (self.reports_to) |manager| allocator.free(manager);
        allocator.free(self.join_date);
        allocator.free(self.title);
        allocator.free(self.name);
    }
};

pub fn createNode(
    allocator: std.mem.Allocator,
    name: []const u8,
    title: []const u8,
    join_date: []const u8,
    reports_to: ?[]const u8,
) !OrgNode {
    return OrgNode.init(allocator, name, title, join_date, reports_to);
}

const OrgChartRecord = struct {
    name: []const u8,
    title: []const u8,
    join_date: []const u8,
    reports_to: ?[]const u8 = null,
};

pub fn loadOrgChartFromJson(
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.ArrayList(OrgNode) {
    const cwd = std.fs.cwd();
    const file = try cwd.openFile(path, .{});
    defer file.close();

    const max_bytes: usize = 16 * 1024;
    const contents = try file.readToEndAlloc(allocator, max_bytes);
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice([]OrgChartRecord, allocator, contents, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const records = parsed.value;

    var nodes = std.ArrayList(OrgNode){};
    errdefer {
        for (nodes.items) |*node| {
            node.deinit(allocator);
        }
        nodes.deinit(allocator);
    }

    for (records) |record| {
        var node = try createNode(allocator, record.name, record.title, record.join_date, record.reports_to);
        nodes.append(allocator, node) catch |append_err| {
            node.deinit(allocator);
            return append_err;
        };
    }

    return nodes;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) std.log.warn("general purpose allocator leaked", .{});
    }
    const allocator = gpa.allocator();

    var nodes = try loadOrgChartFromJson(allocator, "data/org_chart.json");
    defer {
        for (nodes.items) |*node| {
            node.deinit(allocator);
        }
        nodes.deinit(allocator);
    }

    var name_index = std.StringHashMap(*OrgNode).init(allocator);
    defer name_index.deinit();

    for (nodes.items) |*node| {
        try name_index.put(node.name, node);
    }

    for (nodes.items) |*node| {
        if (node.reports_to) |manager_name| {
            if (name_index.get(manager_name)) |manager| {
                manager.reports.append(allocator, node) catch |append_err| {
                    return append_err;
                };
            } else {
                std.log.warn("Manager {s} referenced by {s} not found in org chart", .{ manager_name, node.name });
            }
        }
    }

    std.debug.print("Loaded {d} people from JSON.\n", .{nodes.items.len});

    var all_reports = std.ArrayList(*OrgNode){};
    defer all_reports.deinit(allocator);

    for (nodes.items) |*node| {
        if (node.reports_to == null) {
            var recursion_depth: usize = 0;
            std.debug.print("Org root: {s} ({s}) joined {s}\n", .{ node.name, node.title, node.join_date });
            try getAllReports(node, &all_reports, allocator, &recursion_depth);
        }
    }

    std.debug.print("Tracked {d} subordinate links.\n", .{all_reports.items.len});
    try zig_playground.bufferedPrint();
}

pub fn getDirectReports(node: *OrgNode) []*OrgNode {
    return node.reports.items;
}

pub fn getAllReports(node: *OrgNode, reports_list: *std.ArrayList(*OrgNode), allocator: std.mem.Allocator, recursion_depth: *usize) !void {
    const hyphen_slice = try allocator.alloc(u8, recursion_depth.* + 1);
    defer allocator.free(hyphen_slice);
    for (hyphen_slice) |*c| {
        c.* = '-';
    }

    for (node.reports.items) |report| {
        std.debug.print("{s} {s} | {s}\n", .{ hyphen_slice, report.title, report.name });
        try reports_list.append(allocator, report);
        recursion_depth.* += 1;
        try getAllReports(report, reports_list, allocator, recursion_depth);
        recursion_depth.* -= 1;
    }
}

test "create node copies input" {
    const allocator = std.testing.allocator;
    var node = try createNode(allocator, "Ada", "VP Engineering", "2021-05-05", null);
    defer node.deinit(allocator);

    try std.testing.expectEqualStrings("Ada", node.name);
    try std.testing.expectEqualStrings("VP Engineering", node.title);
    try std.testing.expectEqualStrings("2021-05-05", node.join_date);
    try std.testing.expect(node.reports_to == null);
}

test "load org chart from json" {
    const allocator = std.testing.allocator;
    var nodes = try loadOrgChartFromJson(allocator, "data/org_chart.json");
    defer {
        for (nodes.items) |*node| {
            node.deinit(allocator);
        }
        nodes.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 12), nodes.items.len);

    const root = nodes.items[0];
    try std.testing.expectEqualStrings("Alice Smith", root.name);
    try std.testing.expect(root.reports_to == null);

    var found_grace = false;
    for (nodes.items) |node| {
        if (std.mem.eql(u8, node.name, "Grace Hopper")) {
            try std.testing.expect(node.reports_to != null);
            try std.testing.expectEqualStrings("Charlie Brown", node.reports_to.?);
            found_grace = true;
        }
    }

    try std.testing.expect(found_grace);
}
