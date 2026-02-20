// This file exists because raygui is a "single-header" C library.
// It contains both declarations AND implementation in one .h file.
// Zig's @cImport can handle the declarations fine, but struggles
// with the implementation (internal cross-references break).
//
// So we compile the implementation as plain C here, and in Zig
// we only import the declarations (no RAYGUI_IMPLEMENTATION).
#define RAYGUI_IMPLEMENTATION
#include "raylib.h"
#include "raygui.h"
