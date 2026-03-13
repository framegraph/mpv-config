--[[
    mpv360.lua - Interactive 360° Video Viewer for mpv

    This script enables interactive viewing of 360° videos in mpv media player.
    It supports multiple projection formats (equirectangular, dual fisheye,
    dual half-equirectangular, half-equirectangular, cylindrical, Equi-Angular Cubemap)
    with full camera control through mouse and keyboard inputs.

    Installation:
    1. Place the files in the mpv config directory:
       - Linux/macOS: ~/.config/mpv/
       - Windows: %APPDATA%/mpv/
    2. Configure keybindings in mpv360.conf (optional)

    Configuration:
    By default, the script doesn't bind any keys. Only script messages are bound.
    To enable keybindings, use default configuration or customize it.
    You can use input.conf to bind keys, look at commands table in script for
    available commands.
    Example:
    ```
    Ctrl+r script-binding mpv360/reset-view
    ```

    Usage:
    - Press configured toggle key to enable/disable 360° mode
    - Ctrl+Click to enable mouse look, ESC or Ctrl+Click to exit
    - Use configured keys for camera control and projection switching
    - For SBS output, select `Both` eye (Ctrl+E to switch eye).

    Author: Kacper Michajłow <kasper93@gmail.com>
    Version: 1.3
    License: MIT
--]]

local mp = require "mp"
local options = require "mp.options"

local config = {
    -- Initial camera orientation (in radians)
    yaw = 0.0,                          -- Horizontal rotation (-π to π]
    pitch = 0.0,                        -- Vertical rotation (-π/2 to π/2)
    roll = 0.0,                         -- Camera tilt (-π to π)
    fov = math.rad(120),                -- Field of view (0 to π)

    input_projection = 0,               -- 0=equirectangular, 1=dual_fisheye,
                                        -- 2=dual_hequirectangular, 3=hequirectangular
    eye = 0,                            -- 0=left, 1=right (for dual formats)
    fisheye_fov = math.rad(180),        -- fisheye fov (0 to 2π]
    sampling = 0,                       -- 0=linear, 1=mitchell, 2=lanczos

    shader_path = mp.command_native({"expand-path", "~~/shaders/mpv360.glsl"}),

    invert_mouse = false,               -- Invert mouse movement
    mouse_sensitivity = math.rad(0.2),  -- Mouse look sensitivity
    capture_cursor = true,              -- Capture cursor to avoid it reaching screen boundaries during mouse look
                                        -- Works only for Windows with mpv that uses LuaJIT

    invert_keyboard = false,            -- Invert keyboard controls
    step = math.rad(0.75),              -- Step for keyboard controls
    scroll_multiplier = 3,              -- Multiply step for FOV adjustments by mouse wheel
    fisheye_fov_step = math.rad(10),    -- Step for fisheye FOV adjustment

    enabled = false,                    -- Start with 360° mode enabled
    show_values = true,                 -- Show camera orientation on change
    vsync_mode = "display-resample"     -- Enable specified display-sync option during 360° mode (empty value to disable)
                                        -- to allow rendering camera movement at monitor refresh rate,
                                        -- instead of video frame rate (usually 24-30 fps)
}

local commands
local initial_pos
local mouse_look_active
local last_mouse_pos
local cursor_autohide
local osc_visibility
local keepaspect
local orig_input_delay, orig_input_rate, orig_video_sync
local ar_rate = mp.get_property_number("input-ar-rate") or 30
local movement_fn
local winapi_available = false
local renders, renders_prev, prev_s_time = 0, nil, 0
local dropped_1s, dropped_1s_prev, dropped_total = 0, nil, 0 -- пока подсчитываются только для управления клавиатурой

local projection_names = {
    [0] = "Equirectangular",
    [1] = "Dual Fisheye",
    [2] = "Dual Half-Equirectangular",
    [3] = "Half-Equirectangular",
    [4] = "Dual Equirectangular (Vert)",
    [5] = "Cylindrical",
    [6] = "Equi-Angular Cubemap",
    [7] = "Dual Equi-Angular Cubemap",
}

local eye_names = {
    [0] = "Left",
    [1] = "Right",
    [2] = "Both",
}

local sampling_names = {
    [0] = "Linear",
    [1] = "Mitchell",
    [2] = "Lanczos",
}

local is_dual_eye = function()
    return config.input_projection == 1 or
           config.input_projection == 2 or
           config.input_projection == 4 or
           config.input_projection == 7
end

local is_fisheye = function()
    return config.input_projection == 1
end

local function show_values()
    if not config.show_values then
        return
    end
    local eye = is_dual_eye() and " | Eye: " .. eye_names[config.eye] or ""
    local fisheye_fov = is_fisheye()
                        and string.format(" | Fisheye FOV: %.0f°", math.deg(config.fisheye_fov))
                        or ""
    local info = string.format(
        "Proj: %s" ..  fisheye_fov .. eye .. " | Sampling: %s\n" ..
        "Yaw: %.1f° | Pitch: %.1f° | Roll: %.1f° | FOV: %.1f°\n" ..
        "Renders/s: %s / %d | Dropped/s (all): %s (%d)", -- значения за прошедшую секунду
        projection_names[config.input_projection] or "N/A",
        sampling_names[config.sampling] or "N/A",
        math.deg(config.yaw), math.deg(config.pitch), math.deg(config.roll),
        math.deg(config.fov),
        renders_prev or "-", ar_rate, dropped_1s_prev or "-", dropped_total
    )
    mp.osd_message(info)
end

local function update_params()
    local function clamp(value, min, max)
        return math.min(math.max(value, min), max)
    end

    local function normalize(angle)
        while angle > math.pi do
            angle = angle - 2 * math.pi
        end
        while angle < -math.pi do
            angle = angle + 2 * math.pi
        end
        return angle
    end

    local eps = 1e-6
    config.roll = clamp(normalize(config.roll), -math.pi + eps, math.pi - eps)
    config.pitch = clamp(config.pitch, -math.pi / 2, math.pi / 2)
    config.yaw = clamp(normalize(config.yaw), -math.pi, math.pi)
    config.fov = clamp(config.fov, eps, math.pi - eps)

    config.input_projection = clamp(config.input_projection, 0, #projection_names)
    config.eye = clamp(config.eye, 0, #eye_names)
    config.fisheye_fov = clamp(config.fisheye_fov, eps, 2 * math.pi)
    config.sampling = clamp(config.sampling, 0, #sampling_names)

    if not config.enabled then
        return
    end

    local params = string.format(
        "mpv360/fov=%f,mpv360/yaw=%f,mpv360/pitch=%f,mpv360/roll=%f," ..
        "mpv360/input_projection=%d,mpv360/fisheye_fov=%f,mpv360/eye=%d,mpv360/sampling=%d",
        config.fov, config.yaw, config.pitch, config.roll,
        config.input_projection, config.fisheye_fov, config.eye, config.sampling
    )
    mp.commandv("no-osd", "change-list", "glsl-shader-opts", "add", params)
    local curr_time = os.clock()
    if curr_time - 1 > prev_s_time then
        renders_prev = renders
        renders = 0
        dropped_total = dropped_total + dropped_1s
        dropped_1s_prev = dropped_1s
        dropped_1s = 0
        if curr_time - 2 > prev_s_time then -- значит за прошлую секунду рендеров не было
            renders_prev, dropped_1s_prev = nil, nil
        end
        prev_s_time = curr_time
    else
        renders = renders + 1
    end
    show_values()
end

local function add_key_bindings()
    for cmd, func in pairs(commands) do
        for binding in config[cmd]:gmatch("[^%s]+") do
            if cmd ~= "toggle" then
                if cmd == "toggle-values" or cmd == "toggle-mouse-look" or cmd == "reset-view" or cmd == "cycle-projection" 
                        or cmd == "switch-eye" or cmd == "cycle-sampling" or cmd == "show-help"
                then
                    mp.add_forced_key_binding(binding ~= "" and binding, cmd.."-"..binding,
                    function ()
                        func()
                        if cmd ~= "show-help" then
                            update_params()
                        end
                    end, {repeatable = true})
                else
                    -- клавиши регулировки позиции и угла обзора делаем с мгновенным повторением после зажатия с частотой обновления монитора
                    mp.add_forced_key_binding(binding ~= "" and binding, cmd.."-"..binding,
                    function (tab)
                        if tab.event == "down" then
                            dropped_1s = dropped_1s + 1 -- должно обратно уменьшиться перед вызовом movement_fn()
                            mp.set_property_native("input-ar-delay", 0)
                            movement_fn = function()
                                func()
                                update_params()
                            end
                        elseif tab.event == "up" then
                            mp.set_property_native("input-ar-delay", orig_input_delay or 200)
                            movement_fn = nil
                        elseif tab.event == "repeat" then
                            dropped_1s = dropped_1s + 1
                            -- если сделать здесь обработку смещения, то в случае, если ПК не справляется с рендером нужное число раз в секунду
                            -- (или если плеер не даёт рендерить чаще), все эти события будут откладываться и воспроизводиться даже после отпускания клавиши
                            -- поэтому обрабатываем смещение после каждого event loop, пока зажата клавиша
                            -- а эта функция просто генератор событий с нужной частотой (всё равно плеер пока не может регистрировать зажатие одновременно нескольких хоткеев)
                        end
                    end, {complex = true})
                end
            end
        end
    end
end

local function remove_key_bindings()
    for cmd in pairs(commands) do
        for binding in config[cmd]:gmatch("[^%s]+") do
            if cmd ~= "toggle" then
                mp.remove_key_binding(cmd.."-"..binding)
            end
        end
    end
end

local function get_mouse_pos()
    if winapi_available then
        local pos = get_absolute_cursor_pos()
        if pos then
            return pos
        else
            mp.msg.error("WinAPI integration error: GetCursorPos failed")
            winapi_available = false
        end
    end
    return mp.get_property_native("mouse-pos")
end

local function on_mouse_move()
    local mouse_pos = get_mouse_pos()
    local dx = mouse_pos.x - last_mouse_pos.x
    local dy = mouse_pos.y - last_mouse_pos.y
    last_mouse_pos = mouse_pos

    if dx == 0 and dy == 0 then return end

    if config.invert_mouse then
        dx = dx * -1
        dy = dy * -1
    end

    config.yaw = config.yaw + dx * config.mouse_sensitivity
    config.pitch = config.pitch - dy * config.mouse_sensitivity

    update_params()
    
    if winapi_available then
        local result, err = center_cursor_on_primary_monitor()
        if result then
            last_mouse_pos = result
        else
            mp.msg.error("WinAPI integration error:", err)
            winapi_available = false
        end
    end
end

local function stop_mouse_look()
    mouse_look_active = false
    mp.remove_key_binding("_mpv360_mouse_move")

    if cursor_autohide ~= nil then
        mp.set_property_native("cursor-autohide", cursor_autohide)
        cursor_autohide = nil
    end

    if osc_visibility ~= nil then
        mp.command(string.format("script-message osc-visibility %s no-osd", osc_visibility))
        osc_visibility = nil
    end

    mp.remove_key_binding("_mpv360_esc")
    mp.remove_key_binding("_mpv360_wheel_up")
    mp.remove_key_binding("_mpv360_wheel_down")
    
    mp.unobserve_property(on_lost_focus)
    mp.unobserve_property(on_opening_uosc_menu)
    mp.remove_key_binding("mouse-enter")
    
    mp.osd_message("")
    mp.commandv("keypress", "MOUSE_ENTER")
end

local function start_mouse_look()
    if not config.enabled or mouse_look_active then
        return
    end

    mouse_look_active = true
    last_mouse_pos = get_mouse_pos()
    cursor_autohide = mp.get_property_native("cursor-autohide")
    mp.set_property_native("cursor-autohide", "always")
    osc_visibility = mp.get_property_native("user-data/osc/visibility")
    mp.command("script-message osc-visibility never no-osd")
    mp.osd_message("Mouse look enabled. Press ESC to exit", 1.5)
    mp.add_forced_key_binding("MOUSE_MOVE", "_mpv360_mouse_move", on_mouse_move)
    mp.add_forced_key_binding("WHEEL_UP", "_mpv360_wheel_up", function ()
        commands["fov-decrease"](true)
        update_params()
    end)
    mp.add_forced_key_binding("WHEEL_DOWN", "_mpv360_wheel_down", function ()
        commands["fov-increase"](true)
        update_params()
    end)
    mp.add_forced_key_binding("ESC", "_mpv360_esc", stop_mouse_look)
    
    mp.commandv("keypress", "MOUSE_LEAVE") -- для быстрого скрытия интерфейса uosc
    
    mp.observe_property("focused", "bool", on_lost_focus)
    mp.observe_property("user-data/uosc/menu/type", "native", on_opening_uosc_menu) -- отключение захвата курсора при открытии меню uosc
    mp.add_forced_key_binding("MOUSE_ENTER", "mouse-enter", stop_mouse_look) -- отключение при выходе курсора за пределы окна плеера (и повторном заходе)
end

function on_lost_focus(_, focused)
    if focused == false then stop_mouse_look() end
end
function on_opening_uosc_menu(_, menu_type)
    if menu_type then stop_mouse_look() end
end

function set_mpv360_shader(_, shaders)
    if not shaders then shaders = {} end
    for _, shader in ipairs(shaders) do
        if shader == config.shader_path then
            return
        end
    end
    table.insert(shaders, 1, config.shader_path) -- добавляем шейдер строго перед остальными, для корректной работы
    mp.set_property_native("glsl-shaders", shaders)
end

function on_rate_change(_, rate)
    if rate then
        ar_rate = math.floor(rate + 0.5)
        mp.set_property_number("input-ar-rate", ar_rate)
    end
end
function on_pause_change(_, core_idle)
    if core_idle then
        on_rate_change(_, mp.get_property("display-fps"))
    else
        on_rate_change(_, mp.get_property("estimated-vf-fps"))
    end
end

local function enable()
    stop_mouse_look()

    config.enabled = true
    update_params()
    mp.observe_property("glsl-shaders", "native", set_mpv360_shader) -- первоначальная установка шейдера + его сохранение при стороннем изменении списка

    add_key_bindings()

    keepaspect = mp.get_property_native("keepaspect")
    mp.set_property_bool("keepaspect", false)
    
    orig_input_delay = mp.get_property_number("input-ar-delay")
    orig_input_rate = mp.get_property_number("input-ar-rate")
    if (mp.get_property("video-sync") or ""):match("^display%-") then
        mp.observe_property("display-fps", "number", on_rate_change)
    elseif config.vsync_mode and config.vsync_mode:match("^display%-") then
        orig_video_sync = mp.get_property("video-sync")
        mp.set_property("video-sync", config.vsync_mode)
        mp.observe_property("display-fps", "number", on_rate_change)
    else
        mp.observe_property("estimated-vf-fps", "number", on_rate_change)
        mp.observe_property("core-idle", "bool", on_pause_change)
    end

    local msg = "360° mode enabled - " .. projection_names[config.input_projection]
    if config["show-help"] then
        msg = msg .. " - Press " .. config["show-help"]:match("[^%s]+") .. " for help"
    end
    mp.osd_message(msg)
end

local function disable()
    stop_mouse_look()
    remove_key_bindings()

    if keepaspect ~= nil then
        mp.set_property_native("keepaspect", keepaspect)
        keepaspect = nil
    end
    if orig_video_sync ~= nil then
        mp.set_property("video-sync", orig_video_sync)
        orig_video_sync = nil
    end
    
    mp.unobserve_property(on_rate_change)
    mp.unobserve_property(on_pause_change)
    mp.set_property_number("input-ar-delay", orig_input_delay)
    mp.set_property_number("input-ar-rate", orig_input_rate)

    mp.unobserve_property(set_mpv360_shader)
    local shaders = mp.get_property_native("glsl-shaders") or {}
    for i, shader in ipairs(shaders) do
        if shader == config.shader_path then
            table.remove(shaders, i)
        end
    end
    mp.set_property_native("glsl-shaders", shaders)

    config.enabled = false
    mp.osd_message("360° mode disabled")
end

local function show_help()
    local function get_key(cmd)
        return config[cmd] and config[cmd] ~= "" and config[cmd]:match("[^%s]+") or "not set"
    end

    local help = {
        "360° Video Controls",
        "",
        "• Enable mouse look: " .. get_key("toggle-mouse-look"),
        "• Exit mouse look: ESC or " .. get_key("toggle-mouse-look"),
        "• Adjust FOV (in mouse look): Scroll wheel",
        "",
        "• Toggle 360° mode: " .. get_key("toggle"),
        "• Toggle stats: " .. get_key("toggle-values"),
        "• Reset view: " .. get_key("reset-view"),
        "• Look up: " .. get_key("look-up"),
        "• Look down: " .. get_key("look-down"),
        "• Look left: " .. get_key("look-left"),
        "• Look right: " .. get_key("look-right"),
        "• Roll left: " .. get_key("roll-left"),
        "• Roll right: " .. get_key("roll-right"),
        "• Increase FOV: " .. get_key("fov-increase"),
        "• Decrease FOV: " .. get_key("fov-decrease"),
        "",
        "• Cycle projection: " .. get_key("cycle-projection"),
        "• Increase Fisheye FOV: " .. get_key("fisheye-fov-increase"),
        "• Decrease Fisheye FOV: " .. get_key("fisheye-fov-decrease"),
        "• Switch eye: " .. get_key("switch-eye"),
        "• Cycle sampling: " .. get_key("cycle-sampling"),
        "",
        "• Show this help: " .. get_key("show-help"),
    }
    mp.osd_message(table.concat(help, "\n"), 10)
end

commands = {
    ["toggle"] = function () if config.enabled then disable() else enable() end end,
    ["toggle-values"] = function () config.show_values = not config.show_values if not config.show_values then mp.osd_message("") end end,
    ["look-up"] = function () config.pitch = config.pitch + config.step * 60/ar_rate end, -- одинаковое смещение в секунду при разных частотах рендера
    ["look-down"] = function () config.pitch = config.pitch - config.step * 60/ar_rate end,
    ["look-left"] = function () config.yaw = config.yaw - config.step * 60/ar_rate end,
    ["look-right"] = function () config.yaw = config.yaw + config.step * 60/ar_rate end,
    ["roll-left"] = function () config.roll = config.roll - config.step * 60/ar_rate end,
    ["roll-right"] = function () config.roll = config.roll + config.step * 60/ar_rate end,
    ["fov-increase"] = function (is_wheel) config.fov = config.fov + config.step * (is_wheel and config.scroll_multiplier or 60/ar_rate) end,
    ["fov-decrease"] = function (is_wheel) config.fov = config.fov - config.step * (is_wheel and config.scroll_multiplier or 60/ar_rate) end,
    ["toggle-mouse-look"] = function ()
        if mouse_look_active then
            stop_mouse_look()
        else
            start_mouse_look()
        end
    end,
    ["reset-view"] = function ()
        config.yaw = initial_pos.yaw
        config.pitch = initial_pos.pitch
        config.roll = initial_pos.roll
        config.fov = initial_pos.fov
    end,
    ["cycle-projection"] = function ()
        config.input_projection = (config.input_projection + 1) % (#projection_names + 1)
        mp.osd_message(projection_names[config.input_projection] .. " Projection")
    end,
    ["fisheye-fov-increase"] = function ()
        config.fisheye_fov = config.fisheye_fov + config.fisheye_fov_step
    end,
    ["fisheye-fov-decrease"] = function ()
        config.fisheye_fov = config.fisheye_fov - config.fisheye_fov_step
    end,
    ["switch-eye"] = function ()
        if is_dual_eye() then
            config.eye = (config.eye + 1) % (#eye_names + 1)
        else
            mp.msg.warn("Eye selection only available for dual eye formats.")
        end
    end,
    ["cycle-sampling"] = function ()
        config.sampling = (config.sampling + 1) % (#sampling_names + 1)
        mp.osd_message("Sampling: " .. sampling_names[config.sampling])
    end,
    ["show-help"] = show_help,
}

for cmd in pairs(commands) do
    config[cmd] = ""
end

options.read_options(config, "mpv360", update_params)

initial_pos = {
    yaw = config.yaw,
    pitch = config.pitch,
    roll = config.roll,
    fov = config.fov,
}

for binding in config["toggle"]:gmatch("[^%s]+") do
    mp.add_key_binding(binding, "toggle-"..binding, commands["toggle"])
end

if config.enabled then
    enable()
end

mp.register_idle(function()
    if movement_fn then
        dropped_1s = dropped_1s - 1
        movement_fn()
    end
end)


-- перемещение курсора в центр экрана обращением к WinAPI с помощью LuaJIT, 
-- чтобы он не упирался в границы экрана и не переставал позволять регистрировать перемещения мыши
if config.capture_cursor then
    local ffi_loaded, ffi = pcall(require, "ffi")
    if ffi_loaded and jit and jit.os == "Windows" then
        winapi_available = true
        
        ffi.cdef[[
            typedef int BOOL;
            typedef long LONG;
            typedef unsigned int UINT;
            typedef unsigned long DWORD;

            BOOL SetCursorPos(int X, int Y);
            int GetSystemMetrics(int nIndex);

            typedef struct { LONG x; LONG y; } POINT;
            BOOL GetCursorPos(POINT *lpPoint);
        ]]

        local SM_CXSCREEN = 0
        local SM_CYSCREEN = 1

        function center_cursor_on_primary_monitor()
            local screen_w = ffi.C.GetSystemMetrics(SM_CXSCREEN)
            local screen_h = ffi.C.GetSystemMetrics(SM_CYSCREEN)
            if screen_w == 0 or screen_h == 0 then
                return nil, "failed to get screen metrics"
            end
            local result = {}
            result.x = math.floor(screen_w / 2)
            result.y = math.floor(screen_h / 2)
            local res = ffi.C.SetCursorPos(result.x, result.y)
            if res == 0 then
                return nil, "SetCursorPos failed"
            end
            return result
        end

        function get_absolute_cursor_pos()
            local pt = ffi.new("POINT[1]")
            if ffi.C.GetCursorPos(pt) ~= 0 then
                return { x = tonumber(pt[0].x), y = tonumber(pt[0].y) }
            end
        end
        
    elseif not ffi_loaded then
        mp.msg.warn("LuaJIT unavailable, cursor capturing won't work")
    else
        mp.msg.info("Cursor capturing is not implemented on", jit.os)
    end
end