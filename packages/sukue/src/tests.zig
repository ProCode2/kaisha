const std = @import("std");
const testing = std.testing;
const clay = @import("clay");
const types = @import("types.zig");
const Color = types.Color;
const renderer = @import("renderer.zig");
const app_mod = @import("app.zig");

// --- Color conversion tests ---

test "Color toClay produces correct float values" {
    const c = Color{ .r = 255, .g = 128, .b = 0, .a = 200 };
    const cc = c.toClay();
    try testing.expectEqual(@as(f32, 255), cc[0]);
    try testing.expectEqual(@as(f32, 128), cc[1]);
    try testing.expectEqual(@as(f32, 0), cc[2]);
    try testing.expectEqual(@as(f32, 200), cc[3]);
}

test "Color toRaylib preserves values" {
    const c = Color{ .r = 10, .g = 20, .b = 30, .a = 40 };
    const rc = c.toRaylib();
    try testing.expectEqual(@as(u8, 10), rc.r);
    try testing.expectEqual(@as(u8, 20), rc.g);
    try testing.expectEqual(@as(u8, 30), rc.b);
    try testing.expectEqual(@as(u8, 40), rc.a);
}

test "Color fromRaylib roundtrips" {
    const original = Color{ .r = 42, .g = 99, .b = 200, .a = 150 };
    const roundtripped = Color.fromRaylib(original.toRaylib());
    try testing.expectEqual(original.r, roundtripped.r);
    try testing.expectEqual(original.g, roundtripped.g);
    try testing.expectEqual(original.b, roundtripped.b);
    try testing.expectEqual(original.a, roundtripped.a);
}

test "Color default alpha is 255" {
    const c = Color{ .r = 100, .g = 100, .b = 100 };
    try testing.expectEqual(@as(u8, 255), c.a);
    const cc = c.toClay();
    try testing.expectEqual(@as(f32, 255), cc[3]);
}

test "Color zero values" {
    const c = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const cc = c.toClay();
    try testing.expectEqual(@as(f32, 0), cc[0]);
    try testing.expectEqual(@as(f32, 0), cc[1]);
    try testing.expectEqual(@as(f32, 0), cc[2]);
    try testing.expectEqual(@as(f32, 0), cc[3]);
}

// --- Renderer helper tests ---

test "clayColorToRaylib converts correctly" {
    const clay_color: clay.Color = .{ 100, 200, 50, 255 };
    const rc = renderer.clayColorToRaylib(clay_color);
    try testing.expectEqual(@as(u8, 100), rc.r);
    try testing.expectEqual(@as(u8, 200), rc.g);
    try testing.expectEqual(@as(u8, 50), rc.b);
    try testing.expectEqual(@as(u8, 255), rc.a);
}

test "clayColorToRaylib clamps overflow" {
    const clay_color: clay.Color = .{ 300, -10, 255.9, 0 };
    const rc = renderer.clayColorToRaylib(clay_color);
    try testing.expectEqual(@as(u8, 255), rc.r);
    try testing.expectEqual(@as(u8, 0), rc.g);
    try testing.expectEqual(@as(u8, 255), rc.b);
    try testing.expectEqual(@as(u8, 0), rc.a);
}

test "maxCornerRadius finds largest" {
    const cr = clay.CornerRadius{ .top_left = 5, .top_right = 10, .bottom_left = 3, .bottom_right = 8 };
    try testing.expectEqual(@as(f32, 10), renderer.maxCornerRadius(cr));
}

test "maxCornerRadius all zeros" {
    const cr = clay.CornerRadius{};
    try testing.expectEqual(@as(f32, 0), renderer.maxCornerRadius(cr));
}

test "maxCornerRadius.all helper" {
    const cr = clay.CornerRadius.all(7);
    try testing.expectEqual(@as(f32, 7), renderer.maxCornerRadius(cr));
}

// --- Clay layout integration tests ---
// Clay uses global state, so we initialize once and reuse across tests.
// Each test calls setLayoutDimensions + beginLayout/endLayout to reset.

var clay_initialized = false;
var clay_buffer: ?[]u8 = null;

fn ensureClayInit() void {
    if (clay_initialized) return;
    const size = clay.minMemorySize();
    // Use page allocator since this lives for the entire test process
    clay_buffer = std.heap.page_allocator.alloc(u8, size) catch @panic("OOM");
    const arena = clay.createArenaWithCapacityAndMemory(clay_buffer.?);
    _ = clay.initialize(arena, .{ .w = 800, .h = 600 }, .{});
    clay.setMeasureTextFunction(void, {}, dummyMeasureText);
    clay_initialized = true;
}

test "Clay initialize and basic layout" {
    ensureClayInit();

    clay.setLayoutDimensions(.{ .w = 800, .h = 600 });
    clay.beginLayout();
    clay.UI()(.{
        .id = clay.ElementId.ID("basic_root"),
        .layout = .{ .sizing = .{ .w = .grow, .h = .grow } },
    })({});
    const commands = clay.endLayout();
    _ = commands; // no crash = success
}

test "Clay layout computes element positions" {
    ensureClayInit();

    clay.setLayoutDimensions(.{ .w = 800, .h = 600 });
    clay.beginLayout();

    clay.UI()(.{
        .id = clay.ElementId.ID("pos_root"),
        .layout = .{ .sizing = .{ .w = .grow, .h = .grow } },
        .background_color = .{ 30, 30, 40, 255 },
    })({
        clay.UI()(.{
            .id = clay.ElementId.ID("pos_sidebar"),
            .layout = .{ .sizing = .{ .w = .fixed(200), .h = .grow } },
            .background_color = .{ 50, 50, 60, 255 },
        })({});

        clay.UI()(.{
            .id = clay.ElementId.ID("pos_content"),
            .layout = .{ .sizing = .{ .w = .grow, .h = .grow } },
            .background_color = .{ 40, 40, 50, 255 },
        })({});
    });

    _ = clay.endLayout();

    const root = clay.getElementData(clay.ElementId.ID("pos_root"));
    try testing.expect(root.found);
    try testing.expectEqual(@as(f32, 800), root.bounding_box.width);
    try testing.expectEqual(@as(f32, 600), root.bounding_box.height);

    const sidebar = clay.getElementData(clay.ElementId.ID("pos_sidebar"));
    try testing.expect(sidebar.found);
    try testing.expectEqual(@as(f32, 200), sidebar.bounding_box.width);
    try testing.expectEqual(@as(f32, 600), sidebar.bounding_box.height);
    try testing.expectEqual(@as(f32, 0), sidebar.bounding_box.x);

    const content = clay.getElementData(clay.ElementId.ID("pos_content"));
    try testing.expect(content.found);
    try testing.expectEqual(@as(f32, 600), content.bounding_box.width);
    try testing.expectEqual(@as(f32, 200), content.bounding_box.x);
}

test "Clay layout with padding and gap" {
    ensureClayInit();

    clay.setLayoutDimensions(.{ .w = 400, .h = 300 });
    clay.beginLayout();
    clay.UI()(.{
        .id = clay.ElementId.ID("pad_root"),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .grow },
            .padding = .all(20),
            .child_gap = 10,
            .direction = .top_to_bottom,
        },
        .background_color = .{ 30, 30, 40, 255 },
    })({
        clay.UI()(.{
            .id = clay.ElementId.ID("pad_child1"),
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(50) } },
            .background_color = .{ 50, 50, 60, 255 },
        })({});

        clay.UI()(.{
            .id = clay.ElementId.ID("pad_child2"),
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(50) } },
            .background_color = .{ 50, 50, 60, 255 },
        })({});
    });
    _ = clay.endLayout();

    const child1 = clay.getElementData(clay.ElementId.ID("pad_child1"));
    try testing.expect(child1.found);
    try testing.expectEqual(@as(f32, 20), child1.bounding_box.x);
    try testing.expectEqual(@as(f32, 20), child1.bounding_box.y);
    try testing.expectEqual(@as(f32, 360), child1.bounding_box.width);

    const child2 = clay.getElementData(clay.ElementId.ID("pad_child2"));
    try testing.expect(child2.found);
    try testing.expectEqual(@as(f32, 80), child2.bounding_box.y);
}

test "Clay layout percent sizing" {
    ensureClayInit();

    clay.setLayoutDimensions(.{ .w = 1000, .h = 500 });
    clay.beginLayout();
    clay.UI()(.{
        .id = clay.ElementId.ID("pct_root"),
        .layout = .{ .sizing = .{ .w = .grow, .h = .grow } },
        .background_color = .{ 30, 30, 40, 255 },
    })({
        clay.UI()(.{
            .id = clay.ElementId.ID("pct_half"),
            .layout = .{ .sizing = .{ .w = .percent(0.5), .h = .grow } },
            .background_color = .{ 50, 50, 60, 255 },
        })({});
    });
    _ = clay.endLayout();

    const half = clay.getElementData(clay.ElementId.ID("pct_half"));
    try testing.expect(half.found);
    try testing.expectEqual(@as(f32, 500), half.bounding_box.width);
}

test "Clay getElementData returns not found for missing ID" {
    ensureClayInit();

    clay.setLayoutDimensions(.{ .w = 100, .h = 100 });
    clay.beginLayout();
    clay.UI()(.{
        .id = clay.ElementId.ID("exists_test"),
        .layout = .{ .sizing = .{ .w = .grow, .h = .grow } },
        .background_color = .{ 30, 30, 40, 255 },
    })({});
    _ = clay.endLayout();

    const missing = clay.getElementData(clay.ElementId.ID("does_not_exist"));
    try testing.expect(!missing.found);
}

test "Clay scroll container data" {
    ensureClayInit();

    clay.setLayoutDimensions(.{ .w = 400, .h = 300 });
    clay.beginLayout();
    clay.UI()(.{
        .id = clay.ElementId.ID("scroll_test"),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(100) },
            .direction = .top_to_bottom,
        },
        .clip = .{ .vertical = true },
    })({
        clay.UI()(.{
            .id = clay.ElementId.ID("scroll_tall"),
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(500) } },
            .background_color = .{ 50, 50, 60, 255 },
        })({});
    });
    _ = clay.endLayout();

    const scroll_data = clay.getScrollContainerData(clay.ElementId.ID("scroll_test"));
    try testing.expect(scroll_data.found);
    try testing.expectEqual(@as(f32, 100), scroll_data.scroll_container_dimensions.h);
    try testing.expect(scroll_data.content_dimensions.h > scroll_data.scroll_container_dimensions.h);
}

// --- AppConfig tests ---

test "AppConfig defaults" {
    const config = app_mod.AppConfig{};
    try testing.expectEqual(@as(i32, 800), config.width);
    try testing.expectEqual(@as(i32, 600), config.height);
    try testing.expectEqual(@as(i32, 60), config.target_fps);
    try testing.expect(config.resizable);
}

// --- Types tests ---

test "Vec2 and Rect structs" {
    const v = types.Vec2{ .x = 1.5, .y = 2.5 };
    try testing.expectEqual(@as(f32, 1.5), v.x);

    const r = types.Rect{ .x = 10, .y = 20, .width = 100, .height = 50 };
    try testing.expectEqual(@as(f32, 100), r.width);
}

// --- Dummy text measurement for Clay tests ---

fn dummyMeasureText(
    text: []const u8,
    config: *clay.TextElementConfig,
    _: void,
) clay.Dimensions {
    // Simple approximation: 8px per char width, font_size height
    const char_width: f32 = 8;
    const len: f32 = @floatFromInt(text.len);
    const height: f32 = @floatFromInt(config.font_size);
    return .{
        .w = len * char_width,
        .h = height,
    };
}
