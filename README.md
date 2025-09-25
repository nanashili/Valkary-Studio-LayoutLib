# Valkary Studio LayoutLib

An experimental reimplementation of the Android Studio layoutlib renderer written in [Zig](https://ziglang.org/). This library provides a clean, idiomatic Zig API for building lightweight view hierarchies and running deterministic layout passes without depending on the Android runtime.

## Features

- **Composable data model** that mirrors core Android layoutlib components (layout nodes, layout params, and rendering output)
- **Deterministic layout engine** for vertical/horizontal linear layouts, basic containers, and text elements
- **Foundation for future development** toward feature parity with Android renderer while remaining simple and extensible
- **JSON-over-stdio daemon** for easy integration with other languages

## Project Structure

```
├── build.zig                 # Zig build script exposing the layoutlib library
├── src/
│   ├── layout/
│   │   ├── node.zig          # Layout tree representation
│   │   ├── renderer.zig      # Rendering and layout engine
│   │   └── types.zig         # Shared enums, structs and helpers
│   └── lib.zig               # Public API surface and tests
└── README.md
```

## Quick Start

### Prerequisites

Zig 0.15.1+ is required. [Install Zig](https://ziglang.org/download/) locally to build and run examples.

### Build and Test

```bash
# Run unit tests
zig build test

# Launch JSON-over-stdio daemon
zig build daemon
```

The daemon reads framed XML requests from stdin and writes JSONC responses to stdout. Each response includes a base64 preview image and structured layout tree for easy integration with Swift or other host languages.

## Usage Example

```zig
const std = @import("std");
const layoutlib = @import("layoutlib");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a vertical linear layout
    var root = layoutlib.LayoutNode.linearLayout(layoutlib.LayoutParams{
        .width = .wrap_content,
        .height = .wrap_content,
        .padding = layoutlib.EdgeInsets.uniform(8),
    }, .vertical);
    defer root.deinit(allocator);

    // Add child text nodes
    try root.addChild(allocator, layoutlib.LayoutNode.text(.{}, "Title"));
    try root.addChild(allocator, layoutlib.LayoutNode.text(.{}, "Description"));

    // Render the layout
    var renderer = layoutlib.Renderer.init(allocator);
    var rendered = try renderer.render(&root, layoutlib.Constraint{ 
        .width = 240, 
        .height = null 
    });
    defer rendered.deinit(allocator);

    // Print computed positions and dimensions
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

This example creates a vertical layout with two text nodes and prints their computed frames.

## Daemon Protocol

### Request Format

Requests begin with a `Content-Length` header followed by XML payload. The root element can be either a `<layout-request>` envelope or a layout element like `<LinearLayout>`.

**Example with envelope:**
```xml
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

### Response Format

The daemon returns a JSONC object with the computed layout tree:

```jsonc
{
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
          "text": "Hello",
          "children": []
        },
        {
          "type": "text",
          "frame": { "x": 8, "y": 24, "width": 60, "height": 16 },
          "text": "World",
          "children": []
        }
      ]
    }
  }
}
```

Errors return `"status": "error"` with a descriptive message. Send EOF (Ctrl+D) to terminate.

### Advanced Example with Resources

Launch the daemon with custom colors and fonts:

```bash
payload=$(cat <<'EOF'
<layout-request id="resource-demo" action="render">
  <constraint width="300" />
  <resources>
    <color name="brandPrimary" value="#0A84FF" />
    <color name="brandOnPrimary" value="#10131B" />
    <font name="headline" charWidth="8" lineHeight="24" />
  </resources>
  <LinearLayout
      android:layout_width="match_parent"
      android:layout_height="wrap_content"
      android:orientation="vertical"
      android:padding="16dp"
      android:background="@color/brandPrimary">
    <TextView
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:text="Headline"
        android:textColor="@color/brandOnPrimary"
        android:fontFamily="@font/headline" />
  </LinearLayout>
</layout-request>
EOF
)

content_length=$(printf %s "$payload" | wc -c | tr -d ' ')
{
  printf 'Content-Length: %s\n' "$content_length"
  printf '%s' "$payload"
} | zig build daemon
```

## Roadmap

- [ ] Parse Android XML layout resources
- [ ] Support additional layout containers (FrameLayout, RelativeLayout, ConstraintLayout)
- [ ] Implement resource loading pipeline compatible with Android theme assets
- [ ] Provide tooling integrations for design-time previews

## Contributing

Contributions and feedback are welcome! Please feel free to submit issues and pull requests.