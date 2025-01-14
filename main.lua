-- main.lua

-- Load dkjson for JSON parsing
local dkjson = require("dkjson")

-- Load FFI for transparency (Windows only)
local ffi = nil
if love.system.getOS() == "Windows" then
    ffi = require("ffi")
    ffi.cdef[[
        typedef void* HWND;
        typedef unsigned long DWORD;
        typedef int BOOL;
        typedef unsigned long ULONG;
        typedef ULONG COLORREF;
        typedef unsigned int UINT;
        typedef unsigned char BYTE;
        typedef long LONG;
        typedef struct {
            DWORD cbSize;
            DWORD dwFlags;
            HWND hwndInsertAfter;
            int x;
            int y;
            int cx;
            int cy;
            DWORD dwExStyle;
        } WINDOWPOS;
        HWND GetForegroundWindow();
        BOOL SetWindowPos(HWND hWnd, HWND hWndInsertAfter, int X, int Y, int cx, int cy, UINT uFlags);
        BOOL SetLayeredWindowAttributes(HWND hwnd, COLORREF crKey, BYTE bAlpha, DWORD dwFlags);
        DWORD GetWindowLongA(HWND hWnd, int nIndex);
        LONG SetWindowLongA(HWND hWnd, int nIndex, LONG dwNewLong);
    ]]
    -- Load user32.dll for window-related functions
    local user32 = ffi.load("user32")
end

-- Configuration
local config = {
    window = {
        width = 200,
        height = 100,
        transparent = true,
        borderless = true,
        always_on_top = true,
        background_color = {0, 0, 0, 0},  -- Transparent background
        padding_left = 10,
        padding_right = 40,
        position = "top-right",  -- Options: "top-left", "top-right", "bottom-left", "bottom-right"
        offset_x = 100,  -- Offset from the left or right edge
        offset_y = 100   -- Offset from the top or bottom edge
    },
    visual = {
        max_points = 60,
        fps = 60,
        font_size = 14,
        ping_text_offset = {0, 0},
        scale_decay_rate = 0.95,
        text_color = {255, 255, 255},
        ping_interval = 1,
        show_guides = true,
        guide_lines_color = {128, 128, 128},
        guide_lines_thickness = 1,
        guide_lines_length = 10,
        guide_levels = {50, 100, 150}
    },
    servers = {
        {address = "1.1.1.1", color = {255, 255, 0, 50}, line_thickness = 2, enabled = true},  -- Yellow
        {address = "8.8.4.4", color = {0, 255, 255, 50}, line_thickness = 2, enabled = true}   -- Cyan
    }
}

-- Load or create config file
local function load_config()
    local config_file = "config.json"
    local file = io.open(config_file, "r")
    if file then
        local data = file:read("*a")
        file:close()
        config = dkjson.decode(data)
    else
        -- Create default config file
        file = io.open(config_file, "w")
        file:write(dkjson.encode(config, {indent = true}))
        file:close()
    end
end

-- Initialize Love2D
function love.load()
    load_config()

    -- Window setup
    love.window.setMode(config.window.width, config.window.height, {
        borderless = config.window.borderless,
        resizable = false,
        highdpi = true
    })
    love.window.setTitle("XenPing")

    -- Enable transparency (Windows only)
    if ffi then
        local hwnd = ffi.C.GetForegroundWindow()
        if config.window.transparent then
            ffi.C.SetWindowLongA(hwnd, -20, bit.bor(ffi.C.GetWindowLongA(hwnd, -20), 0x80000))  -- WS_EX_LAYERED
            ffi.C.SetLayeredWindowAttributes(hwnd, 0x000000, 0, 0x00000001)  -- LWA_COLORKEY
        end
        if config.window.always_on_top then
            ffi.C.SetWindowPos(hwnd, ffi.cast("HWND", -1), 0, 0, 0, 0, bit.bor(0x0002, 0x0001))  -- HWND_TOPMOST
        end

        -- Position the window based on the configuration
        local screen_width, screen_height = love.window.getDesktopDimensions()
        local x, y = 0, 0

        if config.window.position == "top-left" then
            x = config.window.offset_x
            y = config.window.offset_y
        elseif config.window.position == "top-right" then
            x = screen_width - config.window.width - config.window.offset_x
            y = config.window.offset_y
        elseif config.window.position == "bottom-left" then
            x = config.window.offset_x
            y = screen_height - config.window.height - config.window.offset_y
        elseif config.window.position == "bottom-right" then
            x = screen_width - config.window.width - config.window.offset_x
            y = screen_height - config.window.height - config.window.offset_y
        end

        ffi.C.SetWindowPos(hwnd, nil, x, y, 0, 0, bit.bor(0x0001))  -- SWP_NOSIZE | SWP_NOZORDER
    end

    -- Font setup
    font = love.graphics.newFont(config.visual.font_size)

    -- Initialize ping data
    ping_data = {}
    current_max_ping = math.max(unpack(config.visual.guide_levels)) * 1.5
    target_max_ping = current_max_ping
    last_ping_time = 0

    for _, server in ipairs(config.servers) do
        ping_data[server.address] = {
            values = {},
            last_value = 0
        }
        for i = 1, config.visual.max_points do
            table.insert(ping_data[server.address].values, 0)
        end
    end

    dragging = false
    drag_offset = {0, 0}
end

-- Get ping value
local function get_ping(server)
    local start_time = love.timer.getTime()
    local socket = require("socket")
    local tcp = socket.tcp()
    tcp:settimeout(0.5)  -- 500ms timeout

    local success, err = tcp:connect(server, 443)  -- Try HTTPS port first
    if not success then
        tcp:close()
        tcp = socket.tcp()
        tcp:settimeout(0.5)
        success, err = tcp:connect(server, 80)  -- Fallback to HTTP port
    end

    tcp:close()

    if success then
        return (love.timer.getTime() - start_time) * 1000
    end
    return 0
end

-- Update scale
local function update_scale()
    local highest_ping = 0
    for _, server_data in pairs(ping_data) do
        highest_ping = math.max(highest_ping, math.max(unpack(server_data.values)))
    end

    target_max_ping = math.max(highest_ping * 1.2, math.max(unpack(config.visual.guide_levels)) * 1.2)

    if current_max_ping < target_max_ping then
        current_max_ping = target_max_ping
    else
        current_max_ping = math.max(target_max_ping, current_max_ping * config.visual.scale_decay_rate)
    end
end

-- Update ping values
local function update_values()
    local current_time = love.timer.getTime()
    if current_time - last_ping_time >= config.visual.ping_interval then
        for _, server in ipairs(config.servers) do
            if server.enabled then
                local ping_value = get_ping(server.address)
                print("Ping value for " .. server.address .. ": " .. ping_value)  -- Debugging statement
                table.remove(ping_data[server.address].values, 1)
                table.insert(ping_data[server.address].values, ping_value)
                ping_data[server.address].last_value = ping_value
                print("Updated values for " .. server.address .. ": " .. table.concat(ping_data[server.address].values, ", "))  -- Debugging statement
            end
        end
        last_ping_time = current_time
    end
end

-- Draw guide lines
local function draw_guide_lines()
    if not config.visual.show_guides then return end

    for _, level in ipairs(config.visual.guide_levels) do
        local y = config.window.height - (level / current_max_ping) * (config.window.height - 20)

        local x_positions = {
            config.window.padding_left,
            config.window.width / 2,
            config.window.width - config.window.padding_right
        }

        for _, x in ipairs(x_positions) do
            love.graphics.setColor(config.visual.guide_lines_color)
            love.graphics.line(
                x - config.visual.guide_lines_length / 2, y,
                x + config.visual.guide_lines_length / 2, y
            )
        end
    end
end

-- Draw ping graph
local function draw()
    love.graphics.setBackgroundColor(config.window.background_color)

    update_scale()
    draw_guide_lines()

    for _, server in ipairs(config.servers) do
        if not server.enabled then goto continue end

        local server_data = ping_data[server.address]
        local points = {}

        for i, value in ipairs(server_data.values) do
            local x = config.window.width - config.window.padding_right -
                      (#server_data.values - i) *
                      ((config.window.width - config.window.padding_left - config.window.padding_right) /
                       (config.visual.max_points - 1))
            local y = config.window.height - (value / current_max_ping) * (config.window.height - 20)
            table.insert(points, x)
            table.insert(points, y)
        end

        if #points >= 4 then
            love.graphics.setColor(server.color)
            love.graphics.setLineWidth(server.line_thickness)
            love.graphics.line(points)
        end

        if #points > 0 then
            local text = string.format("%dms", server_data.last_value)
            love.graphics.setFont(font)  -- Set the font before rendering text
            love.graphics.setColor(server.color)
            local text_width = font:getWidth(text)
            local text_x = points[#points - 1] + config.visual.ping_text_offset[1]
            local text_y = points[#points] + config.visual.ping_text_offset[2]

            -- Ensure text is within window bounds
            if text_x + text_width > config.window.width then
                text_x = points[#points - 1] - text_width - 5
            end

            love.graphics.print(text, text_x, text_y)
        end

        ::continue::
    end
end

-- Handle events
function love.update(dt)
    update_values()
end

function love.draw()
    draw()
end

function love.mousepressed(x, y, button)
    if button == 1 then
        dragging = true
        drag_offset = {love.window.getPosition()}
        drag_offset[1] = drag_offset[1] - x
        drag_offset[2] = drag_offset[2] - y
    end
end

function love.mousereleased(x, y, button)
    if button == 1 then
        dragging = false
    end
end

function love.mousemoved(x, y, dx, dy)
    if dragging then
        love.window.setPosition(x + drag_offset[1], y + drag_offset[2])
    end
end


