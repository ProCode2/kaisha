pub const c = @cImport({
    @cInclude("raylib.h");
    @cInclude("raygui.h");
});

pub const md = @cImport({
    @cInclude("md4c.h");
});
