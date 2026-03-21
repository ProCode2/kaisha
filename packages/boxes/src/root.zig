// boxes — execution environment abstraction for kaisha.
// Local is just another box.

pub const Box = @import("box.zig").Box;
pub const BoxConfig = @import("config.zig").BoxConfig;
pub const BoxType = @import("config.zig").BoxType;
pub const LocalBox = @import("local.zig").LocalBox;
pub const DockerBox = @import("docker.zig").DockerBox;

const manager_mod = @import("manager.zig");
pub const BoxManager = manager_mod.BoxManager;
pub const ActiveBox = manager_mod.ActiveBox;
pub const BoxInfo = manager_mod.BoxInfo;
