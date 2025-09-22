# Valkary Studio LayoutLib

Valkary Studio LayoutLib is an experimental reimplementation of the Android Studio
layoutlib renderer written in [Zig](https://ziglang.org/). The library focuses on
providing a clean, idiomatic Zig API for building lightweight view hierarchies and
running deterministic layout passes without depending on the Android runtime.

## Goals

* Offer a composable Zig data model that mirrors the core pieces of Google's
  Java layoutlib (layout nodes, layout params and rendering output).
* Provide a deterministic layout engine capable of computing frames for
  vertical and horizontal linear layouts, basic containers and text elements.
* Serve as a foundation for future work toward feature parity with the Android
  renderer while remaining simple enough to experiment with new ideas.

## Project structure

```
├── build.zig          # Zig build script that exposes the `layoutlib` library
├── src
│   ├── layout
│   │   ├── node.zig   # Layout tree representation
│   │   ├── renderer.zig # Rendering and layout engine
│   │   └── types.zig  # Shared enums, structs and helpers
│   └── lib.zig        # Public API surface and tests
└── README.md
```

## Getting started

> **Note:** Zig is not pre-installed in every environment. Install Zig 0.11+
> locally to build or run the examples.

Build and run the unit tests:

```sh
zig build test
```

## Usage example

```zig
const std = @import("std");
const layoutlib = @import("layoutlib");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var root = layoutlib.LayoutNode.linearLayout(layoutlib.LayoutParams{
        .width = .wrap_content,
        .height = .wrap_content,
        .padding = layoutlib.EdgeInsets.uniform(8),
    }, .vertical);
    defer root.deinit(allocator);

    try root.addChild(allocator, layoutlib.LayoutNode.text(.{}, "Title"));
    try root.addChild(allocator, layoutlib.LayoutNode.text(.{}, "Description"));

    var renderer = layoutlib.Renderer.init(allocator);
    var rendered = try renderer.render(&root, layoutlib.Constraint{ .width = 240, .height = null });
    defer rendered.deinit(allocator);

    for (rendered.children.items) |child| {
        std.debug.print("{s}: ({d:.2}, {d:.2}) -> {d:.2}x{d:.2}\n", .{
            child.text orelse "view",
            child.frame.x,
            child.frame.y,
            child.frame.width,
            child.frame.height,
        });
    }
}
```

The example builds a small vertical layout composed of two text nodes and prints
out the computed positions and dimensions for each child view.

## Roadmap

* Implement parsing of Android XML layout resources.
* Support more layout containers (FrameLayout, RelativeLayout, ConstraintLayout).
* Introduce a resource loading pipeline compatible with Android theme assets.
* Provide tooling integrations for design-time previews.

Contributions and feedback are welcome!