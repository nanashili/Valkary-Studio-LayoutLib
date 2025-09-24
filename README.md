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

The project also exposes a JSON-over-stdio daemon that can be launched with:

```sh
zig build daemon
```

The daemon reads framed XML requests from stdin and writes JSONC responses to
stdout. Each response carries the base64 preview image and structured layout
tree, making it straightforward to integrate with Swift or any other host
language that can manage a child process.

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

## Daemon protocol

Each request begins with a `Content-Length` header that specifies the number of
bytes that follow, immediately followed by a newline and the XML payload. The
root element can either be a `<layout-request>` envelope or a layout root
element such as `<LinearLayout>`. The optional envelope allows you to pass a
correlation ID and layout constraints alongside the Android XML layout:

```
Content-Length: 333
<layout-request id="example" action="render">
  <constraint width="240" />
  <LinearLayout
      android:layout_width="match_parent"
      android:layout_height="wrap_content"
      android:orientation="vertical"
      android:padding="8dp">
    <TextView
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:text="Hello" />
    <TextView
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:text="World" />
  </LinearLayout>
</layout-request>
```

The daemon replies with an JSONC object describing the computed layout tree. The
response echoes the request ID when present, includes a base64 encoded PNG
preview of the rendered hierarchy, and exposes the resolved frame, margin,
padding, text, and orientation metadata directly within the JSON payload:

```jsonc
{
  // Layout render payload encoded as JSON for Valkary Studio integration.
  "status": "ok",
  "result": {
    "image": "iVBORw0KGgoAAAANSUhEUgAAA...",
    "root": {
      "type": "linear_layout",
      "frame": { "x": 0, "y": 0, "width": 240, "height": 64 },
      "margin": { "left": 0, "top": 0, "right": 0, "bottom": 0 },
      "padding": { "left": 8, "top": 8, "right": 8, "bottom": 8 },
      "orientation": "vertical",
      "children": [
        {
          "type": "text",
          "frame": { "x": 8, "y": 8, "width": 60, "height": 16 },
          "margin": { "left": 0, "top": 0, "right": 0, "bottom": 0 },
          "padding": { "left": 0, "top": 0, "right": 0, "bottom": 0 },
          "text": "Hello",
          "children": []
        },
        {
          "type": "text",
          "frame": { "x": 8, "y": 24, "width": 60, "height": 16 },
          "margin": { "left": 0, "top": 0, "right": 0, "bottom": 0 },
          "padding": { "left": 0, "top": 0, "right": 0, "bottom": 0 },
          "text": "World",
          "children": []
        }
      ]
    }
  }
}
```

Errors use the same JSONC envelope with `status: "error"` and an `error`
object containing a descriptive `message`. Diagnostics are printed to stderr.
Send EOF (Ctrl+D) to terminate the process.

## Roadmap

* Implement parsing of Android XML layout resources.
* Support more layout containers (FrameLayout, RelativeLayout, ConstraintLayout).
* Introduce a resource loading pipeline compatible with Android theme assets.
* Provide tooling integrations for design-time previews.

Contributions and feedback are welcome!