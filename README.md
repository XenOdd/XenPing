
---

# **XenPing**

A lightweight, real-time ping monitoring tool built with Love2D. Visualize ping latency to multiple servers in a customizable, transparent window.

---

## **Features**
- Real-time ping monitoring.
- Customizable servers and visuals.
- Transparent, borderless, and always-on-top window.
- Drag-and-drop window movement.

---

## **Usage**
1. **Run the Tool**:
   - Install [Love2D](https://love2d.org/).
   - Drag the `XenPing.love` file onto the `love.exe` executable, or run:
     ```bash
     love XenPing.love
     ```

2. **Customize**:
   - Edit `config.json` to add/remove servers, adjust colors, and modify settings.

---

## **Configuration**
Edit `config.json` to customize the tool. Here’s an example configuration:

```json
{
  "servers": [
    {
      "address": "1.1.1.1",
      "enabled": true,
      "color": [255, 255, 0, 50],
      "line_thickness": 2
    },
    {
      "address": "8.8.4.4",
      "enabled": true,
      "color": [0, 255, 255, 50],
      "line_thickness": 2
    }
  ],
  "visual": {
    "text_color": [255, 255, 255],
    "ping_interval": 1,
    "show_guides": true,
    "guide_lines_color": [128, 128, 128],
    "guide_lines_thickness": 1,
    "guide_lines_length": 10,
    "guide_levels": [50, 100, 150],
    "max_points": 60,
    "fps": 60,
    "font_size": 14,
    "ping_text_offset": [0, 0],
    "scale_decay_rate": 0.95
  },
  "window": {
    "borderless": true,
    "transparent": true,
    "always_on_top": true,
    "background_color": [0, 0, 0, 0],
    "width": 200,
    "height": 100,
    "position": "top-right",
    "offset_x": 100,
    "offset_y": 100,
    "padding_left": 10,
    "padding_right": 40
  }
}
```



---

Enjoy monitoring your ping! 🚀

---
