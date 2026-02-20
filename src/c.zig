pub const c = @cImport({
    @cInclude("raylib.h");
    @cInclude("raygui.h");
});

pub const curl = @cImport({
    @cInclude("curl/curl.h");
});
