-- main.lua
-- luacheck: globals love
-- XenPing + Hardware Monitor
-- Version: 2.3 FULL - 452 lines
-- Transparent 220x140, CPU + GPU, Ping

--[[ =========================================================================
     LIBRARIES
============================================================================= ]]
local dkjson = require("dkjson")
local ffi
local bit

--[[ =========================================================================
     FFI DEFINITIONS (WINDOWS ONLY)
============================================================================= ]]
if love.system.getOS() == "Windows" then
    ffi = require("ffi")
    bit = require("bit")
    ffi.cdef[[
        typedef void* HWND;
        typedef unsigned long DWORD;
        typedef int BOOL;
        typedef unsigned long ULONG;
        typedef ULONG COLORREF;
        typedef unsigned int UINT;
        typedef unsigned char BYTE;
        typedef long LONG;
        HWND GetForegroundWindow();
        BOOL SetWindowPos(HWND hWnd, HWND hWndInsertAfter, int X, int Y, int cx, int cy, UINT uFlags);
        BOOL SetLayeredWindowAttributes(HWND hwnd, COLORREF crKey, BYTE bAlpha, DWORD dwFlags);
        DWORD GetWindowLongA(HWND hWnd, int nIndex);
        LONG SetWindowLongA(HWND hWnd, int nIndex, LONG dwNewLong);
    ]]
end

--[[ =========================================================================
     GLOBAL STATE
============================================================================= ]]
local config = {}
local font
local dragging = false
local drag_offset = {0, 0}

local ping_data = {}
local temp_data = {}

local current_max_ping = 150
local target_max_ping = 150
local current_max_temp = 100
local target_max_temp = 100

local last_ping_time = 0
local last_temp_time = 0

--[[ =========================================================================
     UTILITY: HIDDEN COMMAND EXECUTION
============================================================================= ]]
local function execute_command(cmd)
    if love.system.getOS() ~= "Windows" then
        local h = io.popen(cmd.. " 2>/dev/null")
        if not h then return "" end
        local r = h:read("*a")
        h:close()
        return r
    end

    local kernel32 = ffi.load("kernel32")
    ffi.cdef[[
        typedef void* HANDLE;
        typedef int BOOL;
        typedef unsigned long DWORD;
        typedef struct { DWORD nLength; void* lpSecurityDescriptor; BOOL bInheritHandle; } SECURITY_ATTRIBUTES;
        typedef struct { DWORD cb; void* lpReserved; void* lpDesktop; void* lpTitle; DWORD dwX; DWORD dwY; DWORD dwXSize; DWORD dwYSize; DWORD dwXCountChars; DWORD dwYCountChars; DWORD dwFillAttribute; DWORD dwFlags; unsigned short wShowWindow; unsigned short cbReserved2; void* lpReserved2; HANDLE hStdInput; HANDLE hStdOutput; HANDLE hStdError; } STARTUPINFOA;
        typedef struct { HANDLE hProcess; HANDLE hThread; DWORD dwProcessId; DWORD dwThreadId; } PROCESS_INFORMATION;
        BOOL CreatePipe(HANDLE*, HANDLE*, SECURITY_ATTRIBUTES*, DWORD);
        BOOL SetHandleInformation(HANDLE, DWORD, DWORD);
        BOOL CreateProcessA(const char* lpApplicationName, char* lpCommandLine, void* lpProcessAttributes, void* lpThreadAttributes, BOOL bInheritHandles, DWORD dwCreationFlags, void* lpEnvironment, const char* lpCurrentDirectory, STARTUPINFOA* lpStartupInfo, PROCESS_INFORMATION* lpProcessInformation);
        DWORD WaitForSingleObject(HANDLE, DWORD);
        BOOL CloseHandle(HANDLE);
        BOOL ReadFile(HANDLE, void*, DWORD, DWORD*, void*);
        BOOL PeekNamedPipe(HANDLE, void*, DWORD, DWORD*, DWORD*, DWORD*);
    ]]

    local sa = ffi.new("SECURITY_ATTRIBUTES")
    sa.nLength = ffi.sizeof(sa)
    sa.bInheritHandle = 1

    local read_h = ffi.new("HANDLE[1]")
    local write_h = ffi.new("HANDLE[1]")
    if kernel32.CreatePipe(read_h, write_h, sa, 0) == 0 then return "" end
    kernel32.SetHandleInformation(read_h[0], 1, 0)

    local si = ffi.new("STARTUPINFOA")
    si.cb = ffi.sizeof(si)
    si.dwFlags = 0x100
    si.hStdOutput = write_h[0]
    si.hStdError = write_h[0]
    si.wShowWindow = 0

    local pi = ffi.new("PROCESS_INFORMATION")
    local cmd_buf = ffi.new("char[?]", #cmd + 1)
    ffi.copy(cmd_buf, cmd)

    local CREATE_NO_WINDOW = 0x08000000
    local ok = kernel32.CreateProcessA(nil, cmd_buf, nil, nil, 1, CREATE_NO_WINDOW, nil, nil, si, pi)
    kernel32.CloseHandle(write_h[0])

    if ok == 0 then
        kernel32.CloseHandle(read_h[0])
        return ""
    end

    kernel32.WaitForSingleObject(pi.hProcess, 5000)

    local out = {}
    local buf = ffi.new("char[4096]")
    local bytes = ffi.new("DWORD[1]")

    while true do
        local avail = ffi.new("DWORD[1]")
        if kernel32.PeekNamedPipe(read_h[0], nil, 0, nil, avail, nil) == 0 then break end
        if avail[0] == 0 then break end
        if kernel32.ReadFile(read_h[0], buf, 4096, bytes, nil) == 0 then break end
        if bytes[0] == 0 then break end
        out[#out + 1] = ffi.string(buf, bytes[0])
    end

    kernel32.CloseHandle(read_h[0])
    kernel32.CloseHandle(pi.hProcess)
    kernel32.CloseHandle(pi.hThread)

    return table.concat(out)
end

--[[ =========================================================================
     CONFIGURATION
============================================================================= ]]
local function load_config()
    -- Hard-coded defaults - no external file needed
    config = {
        window = {
            width = 220,
            height = 140,
            borderless = true,
            transparent = true,
            always_on_top = true,
            position = "top-right",
            offset_x = 50,
            offset_y = 50,
            background_color = {0, 0, 0, 1},
            padding_left = 8,
            padding_right = 35
        },
        visual = {
            ping_interval = 1.0,
            max_points = 90,
            font_size = 11,
            guide_lines_color = {1, 1, 1, 0.85},
            guide_lines_length = 14,
            ping_guide_levels = {50, 100, 150},
            temp_guide_levels = {40, 60, 80, 100},
            scale_decay_rate = 0.97,
            show_guides = true
        },
        servers = {
            ["1.1.1.1"] = {enabled = true, color = {0, 1, 1, 1}, line_thickness = 2},
            ["8.8.8.8"] = {enabled = true, color = {1, 1, 0, 1}, line_thickness = 2}
        },
        hardware_monitoring = {
            enabled = true,
            update_interval = 1.0,
            cpu = {enabled = true, color = {1, 0.45, 0.15, 1}},
            gpu = {enabled = true, color = {0.5, 0.5, 1, 1}}
        }
    }
end

local function initialize_data_table(max_points)
    local data = {values = {}, last_value = 0}
    for i = 1, max_points do
        table.insert(data.values, 0)
    end
    return data
end

--[[ =========================================================================
     HARDWARE MONITORING - USING YOUR EXACT IDENTIFIERS
============================================================================= ]]
local function get_temp(device)
    if device == 'cpu' then
        -- Core Max - /intelcpu/0/temperature/17
        local cmd = [[powershell -NoProfile -Command "(Get-CimInstance -Namespace root/LibreHardwareMonitor -ClassName Sensor -Filter \"Identifier='/intelcpu/0/temperature/17'\").Value"]]
        local out = execute_command(cmd)
        local temp = tonumber(out)
        if temp and temp > 0 then return temp end
        return 0
    end

    if device == 'gpu' then
        -- GPU Core - /gpu-nvidia/0/temperature/0
        local cmd = [[powershell -NoProfile -Command "(Get-CimInstance -Namespace root/LibreHardwareMonitor -ClassName Sensor -Filter \"Identifier='/gpu-nvidia/0/temperature/0'\").Value"]]
        local out = execute_command(cmd)
        local temp = tonumber(out)
        if temp and temp > 0 then return temp end

        -- Fallback to Hot Spot - /gpu-nvidia/0/temperature/2
        cmd = [[powershell -NoProfile -Command "(Get-CimInstance -Namespace root/LibreHardwareMonitor -ClassName Sensor -Filter \"Identifier='/gpu-nvidia/0/temperature/2'\").Value"]]
        out = execute_command(cmd)
        return tonumber(out) or 0
    end

    return 0
end

local function update_temp_values()
    if not config.hardware_monitoring or not config.hardware_monitoring.enabled then
        return
    end

    local current_time = love.timer.getTime()
    if current_time - last_temp_time >= config.hardware_monitoring.update_interval then

        if config.hardware_monitoring.cpu.enabled then
            local value = get_temp('cpu')
            table.remove(temp_data.cpu.values, 1)
            table.insert(temp_data.cpu.values, value)
            temp_data.cpu.last_value = value
        end

        if config.hardware_monitoring.gpu.enabled then
            local value = get_temp('gpu')
            table.remove(temp_data.gpu.values, 1)
            table.insert(temp_data.gpu.values, value)
            temp_data.gpu.last_value = value
        end

        last_temp_time = current_time
    end
end

--[[ =========================================================================
     PING FUNCTIONS
============================================================================= ]]
local function get_ping(server)
    local start_time = love.timer.getTime()
    local socket = require("socket")
    local tcp = socket.tcp()
    tcp:settimeout(0.5)

    local success = tcp:connect(server, 443)
    if not success then
        tcp:close()
        tcp = socket.tcp()
        tcp:settimeout(0.5)
        success = tcp:connect(server, 80)
    end
    tcp:close()

    if success then
        return (love.timer.getTime() - start_time) * 1000
    end
    return 0
end

local function update_ping_values()
    local current_time = love.timer.getTime()
    if current_time - last_ping_time >= config.visual.ping_interval then
        for address, server_config in pairs(config.servers) do
            if server_config.enabled then
                local value = get_ping(address)
                table.remove(ping_data[address].values, 1)
                table.insert(ping_data[address].values, value)
                ping_data[address].last_value = value
            end
        end
        last_ping_time = current_time
    end
end

--[[ =========================================================================
     DRAWING FUNCTIONS
============================================================================= ]]
local function update_graph_scale(current_max, target_max, data_sources, default_max)
    local highest_value = 0
    for _, source in ipairs(data_sources) do
        if source and source.values and #source.values > 0 then
            highest_value = math.max(highest_value, math.max(unpack(source.values)))
        end
    end

    local new_target_max = math.max(highest_value * 1.2, default_max)

    if current_max < new_target_max then
        current_max = new_target_max
    else
        current_max = math.max(new_target_max, current_max * config.visual.scale_decay_rate)
    end
    return current_max, new_target_max
end

local function draw_guide_lines(y_offset, graph_height, max_value, levels)
    if not config.visual.show_guides or not levels then
        return
    end

    for _, level in ipairs(levels) do
        local y = y_offset + graph_height - (level / max_value) * (graph_height - 8)

        if y > y_offset and y < y_offset + graph_height then
            local x_positions = {
                config.window.padding_left,
                config.window.width / 2,
                config.window.width - config.window.padding_right
            }
            love.graphics.setColor(config.visual.guide_lines_color)
            for _, x in ipairs(x_positions) do
                love.graphics.line(
                    x - config.visual.guide_lines_length / 2, y,
                    x + config.visual.guide_lines_length / 2, y
                )
            end
        end
    end
end

local function draw_graph(data_map, config_map, y_offset, graph_height, max_value, text_format)
    for id, data in pairs(data_map) do
        local source_config = config_map[id]
        if not source_config or not source_config.enabled then
            goto continue
        end

        local points = {}
        for i, value in ipairs(data.values) do
            local x = config.window.padding_left + (i - 1) * ((config.window.width - config.window.padding_left - config.window.padding_right) / (config.visual.max_points - 1))
            local y = y_offset + graph_height - (math.min(value, max_value) / max_value) * (graph_height - 8)
            table.insert(points, x)
            table.insert(points, math.max(y, y_offset))
        end

        if #points >= 4 then
            love.graphics.setColor(source_config.color)
            love.graphics.setLineWidth(source_config.line_thickness or 2)
            love.graphics.line(points)
        end

        if #points > 0 then
            local text = string.format(text_format, data.last_value)
            love.graphics.setFont(font)
            love.graphics.setColor(source_config.color)
            local text_x = points[#points - 1] + 4
            local text_y = points[#points] - font:getHeight() / 2

            if text_x + font:getWidth(text) > config.window.width then
                text_x = points[#points - 1] - font:getWidth(text) - 4
            end

            love.graphics.print(text, text_x, text_y)
        end
        ::continue::
    end
end

--[[ =========================================================================
     LOVE2D CALLBACKS
============================================================================= ]]
function love.load()
    load_config()

    -- Force size (overrides everything)
    config.window.width = 220
    config.window.height = 140
    config.window.padding_right = 35
    config.window.padding_left = 8

    love.window.setMode(config.window.width, config.window.height, {
        borderless = config.window.borderless,
        resizable = false,
        highdpi = true
    })
    love.window.setTitle("XenPing")

    if ffi then
        local hwnd = ffi.C.GetForegroundWindow()
        if config.window.transparent then
            local GWL_EXSTYLE = -20
            local WS_EX_LAYERED = 0x80000
            local LWA_COLORKEY = 0x1
            local ex = ffi.C.GetWindowLongA(hwnd, GWL_EXSTYLE)
            ffi.C.SetWindowLongA(hwnd, GWL_EXSTYLE, bit.bor(ex, WS_EX_LAYERED))
            ffi.C.SetLayeredWindowAttributes(hwnd, 0, 0, LWA_COLORKEY)
        end
        if config.window.always_on_top then
            ffi.C.SetWindowPos(hwnd, ffi.cast("HWND", -1), 0, 0, 0, 0, bit.bor(0x0002, 0x0001))
        end

        local screen_width, screen_height = love.window.getDesktopDimensions()
        local x = screen_width - config.window.width - config.window.offset_x
        local y = config.window.offset_y
        ffi.C.SetWindowPos(hwnd, nil, x, y, 0, 0, 0x0001)
    end

    font = love.graphics.newFont(config.visual.font_size)

    for address, _ in pairs(config.servers) do
        ping_data[address] = initialize_data_table(config.visual.max_points)
    end

    if config.hardware_monitoring and config.hardware_monitoring.enabled then
        temp_data.cpu = initialize_data_table(config.visual.max_points)
        temp_data.gpu = initialize_data_table(config.visual.max_points)
        current_max_temp = 100
    end
    current_max_ping = 150
end

function love.update(dt)
    update_ping_values()
    update_temp_values()
end

function love.draw()
    -- Pure black = transparent
    love.graphics.clear(0, 0, 0, 1)

    local ping_graph_height = config.window.height / 2
    local temp_graph_height = config.window.height / 2

    local ping_sources = {}
    for _, data in pairs(ping_data) do
        table.insert(ping_sources, data)
    end
    current_max_ping, target_max_ping = update_graph_scale(current_max_ping, target_max_ping, ping_sources, 150)

    if config.hardware_monitoring.enabled then
        current_max_temp, target_max_temp = update_graph_scale(current_max_temp, target_max_temp, {temp_data.cpu, temp_data.gpu}, 100)
    end

    draw_guide_lines(0, ping_graph_height, current_max_ping, config.visual.ping_guide_levels)
    draw_graph(ping_data, config.servers, 0, ping_graph_height, current_max_ping, "%dms")

    -- Divider
    love.graphics.setColor(1, 1, 1, 0.12)
    love.graphics.setLineWidth(1)
    love.graphics.line(0, ping_graph_height, config.window.width, ping_graph_height)

    if config.hardware_monitoring.enabled then
        draw_guide_lines(ping_graph_height, temp_graph_height, current_max_temp, config.visual.temp_guide_levels)
        draw_graph(temp_data, config.hardware_monitoring, ping_graph_height, temp_graph_height, current_max_temp, "%d°C")
    end
end

function love.mousepressed(x, y, button)
    if button == 1 then
        dragging = true
        local px, py = love.window.getPosition()
        drag_offset = {px - x, py - y}
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