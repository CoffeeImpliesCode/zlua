const std = @import("std");

pub const Result = struct {
    module: *std.Build.Module,
    library: *std.Build.Step.Compile,
};

// The pinned SDK does not select its existing wasm C backend or declare its
// wasm Zig layouts. Keep native SDK builds untouched and supply only that gap.
pub fn create(b: *std.Build, comptime emscripten: type, dependency: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sysroot: []const u8) Result {
    const ffi_h = b.addConfigHeader(.{
        .style = .{ .cmake = dependency.path("include/ffi.h.in") },
        .include_path = "ffi.h",
    }, .{
        .FFI_EXEC_TRAMPOLINE_TABLE = false,
        .FFI_VERSION_NUMBER = "30800\n",
        .FFI_VERSION_STRING = "3.8.0",
        .HAVE_LONG_DOUBLE = "1",
        .TARGET = "WASM32",
        .VERSION = "3.8.0",
    });
    // Use the pinned template, including its FFI_HIDDEN macro definitions.
    // Host-only assembler, executable-mmap, and trampoline options stay unset.
    const config = b.addConfigHeader(.{
        .style = .{ .autoconf_undef = dependency.path("fficonfig.zig.h") },
        .include_path = "fficonfig.h",
    }, .{
        .AC_APPLE_UNIVERSAL_BUILD = null,
        .EH_FRAME_FLAGS = "a",
        .FFI_DEBUG = null,
        .FFI_EXEC_STATIC_TRAMP = null,
        .FFI_EXEC_TRAMPOLINE_TABLE = null,
        .FFI_MMAP_EXEC_EMUTRAMP_PAX = null,
        .FFI_MMAP_EXEC_WRIT = null,
        .FFI_NO_RAW_API = null,
        .FFI_NO_STRUCTS = null,
        .HAVE_ALLOCA_H = true,
        .HAVE_ARM64E_PTRAUTH = null,
        .HAVE_AS_CFI_PSEUDO_OP = null,
        .HAVE_AS_REGISTER_PSEUDO_OP = null,
        .HAVE_AS_S390_ZARCH = null,
        .HAVE_AS_SPARC_UA_PCREL = null,
        .HAVE_AS_X86_64_UNWIND_SECTION_TYPE = null,
        .HAVE_AS_X86_PCREL = null,
        .HAVE_DLFCN_H = true,
        .HAVE_HIDDEN_VISIBILITY_ATTRIBUTE = true,
        .HAVE_INTTYPES_H = true,
        .HAVE_LONG_DOUBLE = 1,
        .HAVE_LONG_DOUBLE_VARIANT = null,
        .HAVE_MEMCPY = true,
        .HAVE_MEMFD_CREATE = null,
        .HAVE_RO_EH_FRAME = null,
        .HAVE_STDINT_H = true,
        .HAVE_STDIO_H = true,
        .HAVE_STDLIB_H = true,
        .HAVE_STRINGS_H = true,
        .HAVE_STRING_H = true,
        .HAVE_SYS_MEMFD_H = null,
        .HAVE_SYS_STAT_H = true,
        .HAVE_SYS_TYPES_H = true,
        .HAVE_UNISTD_H = true,
        .LIBFFI_GNU_SYMBOL_VERSIONING = null,
        .LT_OBJDIR = null,
        .PACKAGE = "libffi",
        .PACKAGE_BUGREPORT = "http://codeberg.org/vezel/libffi/issues",
        .PACKAGE_NAME = "libffi",
        .PACKAGE_STRING = "libffi 3.8.0",
        .PACKAGE_TARNAME = "libffi",
        .PACKAGE_URL = "",
        .PACKAGE_VERSION = "3.8.0",
        .SIZEOF_DOUBLE = 8,
        .SIZEOF_LONG_DOUBLE = 16,
        .SIZEOF_SIZE_T = 4,
        .STDC_HEADERS = true,
        .SYMBOL_UNDERSCORE = null,
        .USING_PURIFY = null,
        .VERSION = "3.8.0",
        .WORDS_BIGENDIAN = null,
    });
    const c_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .single_threaded = true,
    });
    c_module.addConfigHeader(config);
    c_module.addConfigHeader(ffi_h);
    c_module.addIncludePath(dependency.path("include"));
    c_module.addIncludePath(dependency.path("src"));
    c_module.addIncludePath(dependency.path("src/wasm"));
    emscripten.addIncludes(b, c_module, sysroot);
    // Java raw APIs are obsolete and not part of this consumer's wasm surface.
    // Their upstream 32-bit implementation calls its own deprecated API.
    // Keep modern ffi_call, executable closures, and the ordinary raw API.
    c_module.addCSourceFiles(.{
        .root = dependency.path("src"),
        .files = &.{ "closures.c", "java_raw_api.c", "prep_cif.c", "raw_api.c", "tramp.c", "types.c", "wasm/ffi.c" },
        .flags = &.{ "-fexceptions", "-D__EMSCRIPTEN__=1", "-DNO_JAVA_RAW_API=1" },
    });
    const library = b.addLibrary(.{ .name = "ffi-wasm", .linkage = .static, .root_module = c_module });

    // Preserve all pinned binding implementations. Add only the missing target
    // selector and layouts in a generated cache copy, never the package cache.
    const source = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        dependency.path("lib/ffi.zig").getPath(b),
        b.allocator,
        .limited(1 << 24),
    ) catch @panic("zlua libffi: cannot read pinned bindings");
    const needle = "    .xtensa => @import(\"ffi/xtensa.zig\"),";
    if (std.mem.count(u8, source, needle) != 1)
        @panic("zlua libffi: pinned binding target selector changed");
    const patched = std.mem.replaceOwned(u8, b.allocator, source, needle, needle ++ "\n    .wasm32 => @import(\"ffi/wasm.zig\"),") catch @panic("OOM");
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(dependency.path("lib"), "", .{ .exclude_extensions = &.{"ffi.zig"} });
    const root = files.add("ffi.zig", patched);
    _ = files.add("ffi/wasm.zig",
        \\const abi = @import("../abi.zig");
        \\const defaults = @import("../default.zig");
        \\const ffi = @import("../ffi.zig");
        \\const function = @import("../function.zig");
        \\pub const have_long_double = true;
        \\pub const Abi = enum(i32) {
        \\    wasm32 = 1,
        \\    wasm32_emscripten = 2,
        \\    _,
        \\    pub const default = abi.default;
        \\};
        \\pub const Function = extern struct {
        \\    abi: Abi,
        \\    param_count: c_uint,
        \\    param_types: ?[*]*ffi.Type,
        \\    return_type: *ffi.Type,
        \\    bytes: c_uint,
        \\    flags: c_uint,
        \\    nfixedargs: c_uint,
        \\    pub const prepare = function.prepare;
        \\    pub const prepareVarArgs = function.prepareVarArgs;
        \\    pub const call = function.call;
        \\};
        \\pub const Closure = defaults.Closure(Function, 4);
        \\pub const RawClosure = defaults.RawClosure(Function, 4, false);
        \\comptime {
        \\    if (@sizeOf(Function) != 28 or @offsetOf(Function, "nfixedargs") != 24)
        \\        @compileError("wasm ffi_cif layout mismatch");
        \\    if (@sizeOf(Closure) != 16 or @offsetOf(Closure, "datum") != 12)
        \\        @compileError("wasm ffi_closure layout mismatch");
        \\}
        \\
    );
    return .{
        .module = b.createModule(.{ .root_source_file = root, .target = target, .optimize = optimize, .link_libc = true }),
        .library = library,
    };
}
