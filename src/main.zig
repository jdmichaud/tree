const std = @import("std");

const Counter = struct {
  dirs: usize,
  files: usize,
};

pub fn walk(allocator: std.mem.Allocator, output: Output, options: Options, directory: []const u8, prefix: []const u8, level: u16, counter: *Counter) !void {
  if (level == 0) return;

  var dir = std.fs.cwd().openDir(directory, .{ .iterate = true }) catch {
    try std.io.getStdErr().writer().print("cannot open directory \"{s}\"", .{ directory });
    return;
  };
  defer dir.close();

  var it = dir.iterate();
  var dirent_list = std.ArrayList(std.fs.Dir.Entry).init(allocator);
  defer {
    for (dirent_list.items) |entry| {
      allocator.free(entry.name);
    }
    dirent_list.deinit();
  }
  while (try it.next()) |entry| {
    if (entry.name[0] != '.') {
      const dest = try allocator.alloc(u8, entry.name.len);
      @memcpy(dest, entry.name);
      try dirent_list.append(.{ .name = dest, .kind = entry.kind });
    }
  }

  std.mem.sort(std.fs.Dir.Entry, dirent_list.items, {}, struct {
    fn f(_: void, a: std.fs.Dir.Entry, b: std.fs.Dir.Entry) bool {
      return std.mem.lessThan(u8, a.name, b.name);
    }
  }.f);

  for (dirent_list.items, 0..) |entry, i| {
    var header = "├── ";
    var postprefix: [*:0]const u8 = "│   ";
    if (i == dirent_list.items.len - 1) {
      header = "└── ";
      postprefix = "    ";
    }

    try output.writer.print("{s}{s}", .{ prefix, header });
    const font_definition = try getFont(entry.name, entry.kind, options.ls_colors);
    try setColor(font_definition, output);
    try output.writer.print("{s}\n", .{ entry.name });
    try setColor(FontDefinition { .font_color = std.io.tty.Color.reset, .font_weight = std.io.tty.Color.reset }, output);

    if (entry.kind == std.fs.File.Kind.directory) { 
      counter.dirs += 1; 
      const new_directory = try std.fs.path.join(allocator, &.{ directory, entry.name });
      defer allocator.free(new_directory);
      const new_prefix = try std.mem.concat(allocator, u8, &.{ prefix, std.mem.span(postprefix) });
      defer allocator.free(new_prefix);
      try walk(allocator, output, options, new_directory, new_prefix, level - 1, counter);
    } else {
      counter.files += 1;
    }
  }
}

const Options = struct {
  directory: []const u8,
  level: u16,
  ls_colors: std.StringHashMap(FontDefinition),
};

fn getFont(name: []const u8, kind: std.fs.File.Kind, ls_colors: std.StringHashMap(FontDefinition)) !FontDefinition {
  const default = FontDefinition { .font_color = std.io.tty.Color.reset, .font_weight = std.io.tty.Color.reset };
  if (kind == std.fs.File.Kind.directory) {
    return ls_colors.get("di") orelse default;
  } else if (name.len > 4) {
    // try std.io.getStdOut().writer().print(">{s}<", .{ name[name.len - 4..] });
    return ls_colors.get(name[name.len - 4..]) orelse default;
  }
  return default;
}

fn setColor(font_definition: FontDefinition, output: Output) !void {
  if (!output.file.isTty()) return;

  try output.config.setColor(output.writer, font_definition.font_weight);
  try output.config.setColor(output.writer, font_definition.font_color);
}

fn splitScalarArray(comptime T: type, allocator: std.mem.Allocator, buffer: []const T, delimiter: T) !std.ArrayList([]const T) {
  var iter = std.mem.splitScalar(T, buffer, delimiter);
  var splits = std.ArrayList([]const T).init(allocator);
  errdefer splits.deinit();
  while (iter.next()) |entry|
    try splits.append(entry);
  return splits;
}

const FontDefinition = struct {
  font_weight: std.io.tty.Color,
  font_color: std.io.tty.Color,
};

fn parse_ls_colors(allocator: std.mem.Allocator) !std.StringHashMap(FontDefinition) {
  var map = std.StringHashMap(FontDefinition).init(allocator);
  errdefer map.deinit();
  const ls_colors = try std.process.getEnvVarOwned(allocator, "LS_COLORS");
  defer allocator.free(ls_colors);
  var it = std.mem.splitScalar(u8, ls_colors, ':');
  while (it.next()) |entry| {
    // Split to get all the *.ext:colors
    const key_value = try splitScalarArray(u8, allocator, entry, '=');
    defer key_value.deinit();
    if (key_value.items.len != 2) continue;
    // Then split the colors so that the first item is bold/regular and second the color.
    const values = try splitScalarArray(u8, allocator, key_value.items[1], ';');
    defer values.deinit();  
    if (values.items.len < 2) continue;
    const font_weight = if (std.mem.eql(u8, values.items[0], "0")) std.io.tty.Color.bold else std.io.tty.Color.reset;
    const font_color = switch (try std.fmt.parseInt(u8, values.items[1], 10)) {
      31 => std.io.tty.Color.red,
      32 => std.io.tty.Color.green,
      33 => std.io.tty.Color.red,
      34 => std.io.tty.Color.blue,
      35 => std.io.tty.Color.magenta,
      36 => std.io.tty.Color.cyan,
      37 => std.io.tty.Color.white,
      38 => std.io.tty.Color.cyan,
      96 => std.io.tty.Color.blue,
      else => std.io.tty.Color.white,
    };
    // We do use globbing, so we will ignore the * for now
    const start_index: u8 = if (key_value.items[0][0] == '*') 1 else 0;
    // A little gymnastic here allocate the key only if it does not exist yet
    const getEntry = try map.getOrPut(key_value.items[0][start_index..]);
    if (!getEntry.found_existing) {
      getEntry.key_ptr.* = try allocator.dupe(u8, key_value.items[0][start_index..]);
    }
    getEntry.value_ptr.* = FontDefinition {
      .font_weight = font_weight,
      .font_color = font_color,
    };
  }
  return map;
}

const Output = struct {
  file: std.fs.File,
  writer: std.fs.File.Writer,
  config: std.io.tty.Config,
};

pub fn main() !u8 {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  defer std.debug.assert(gpa.deinit() == .ok);
  const allocator = gpa.allocator();

  const args = try std.process.argsAlloc(allocator);
  defer std.process.argsFree(allocator, args);

  const stdout = std.io.getStdOut();
  const output = Output {
    .file = stdout, 
    .writer = stdout.writer(),
    .config = std.io.tty.detectConfig(stdout),
  };
  
  var ls_colors = if (stdout.isTty())
    parse_ls_colors(allocator) catch std.StringHashMap(FontDefinition).init(allocator)
  else
    std.StringHashMap(FontDefinition).init(allocator);
  defer {
    var it = ls_colors.iterator();
    while (it.next()) |entry| {
      allocator.free(entry.key_ptr.*);
    }
    ls_colors.deinit();
  }
  // try output.writer.print("{}", .{ ls_colors });

  var options = Options {
    .directory = ".",
    .level = std.math.maxInt(u16),
    .ls_colors = ls_colors,
  };  
  options.directory = 
    if (args.len > 1) dir: {
      if (std.mem.eql(u8, args[1], "-L") and args.len > 2) {
        options.level = try std.fmt.parseInt(u8, args[2], 10);
        break :dir if (args.len > 3) args[3] else ".";
      } else break :dir ".";
    } else ".";
  try output.writer.print("{s}\n", .{ options.directory }); 

  var counter = Counter { .dirs = 0, .files = 0 };
  try walk(allocator, output, options, options.directory, "", options.level, &counter);

  try std.io.getStdOut().writer().print("\n{} directories, {} files\n", .{ counter.dirs, counter.files });
  return 0;
}

