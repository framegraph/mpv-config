-- Режим "Картинка в картинке"
-- Настройки
pref_width = 480 -- размеры уменьшенного окна плеера
pref_heigh = 270  -- если соотношение сторон будет не совпадать, размер автоматически подберётся так, чтобы площадь окна плеера была такой же, как при заданных размерах
wheel_rewind = false -- в режиме "Картинка в картинке" включить перемотку видео колёсиком мыши на всей области окна
                     -- рекомендую также для удобства включить прокручивание неактивных окон в настройках windows
                     -- на win10: "Настройки > Устройства > Мышь и сенсорная панель" > тумблер "Прокручивать неактивные окна при наведении на них"
rew_secs = 5 -- интервал перемотки (отрицательные значения инвертируют направление перемотки)
wheel_resize = true -- вместо перемотки, масштабировать окно плеера колёсиком мыши (можно включить максимум одну из этих двух опций)
scale_factor = 1.07 -- множитель изменения масштаба окна плеера
hide_minitimeline = true -- отключение минимизированной шкалы времени uosc на время использования режима
auto_exit_if_fullscreen = true  -- выходить из режима "Картинка в картинке" при попытке перейти в полноэкранный режим
window_pos = "-10-10"  -- угол экрана, в который будет смещён плеер (только на mpv версии 0.38 и выше!)
                       -- "+0-0" - левый-нижний "-0-0" - правый-нижний, вместо нулей - расстояние в пикселях от краёв экрана по горизонтали и вертикали
use_hidpi_pixels = true -- применять коэффициент системного масштабирования к размерам, заданным выше




local is_pip_mode = false
local prev_border = mp.get_property_bool("border")
local orig_w = 1280 -- используются только на старой версии mpv
local orig_h = 800
local new_version = false
local fs_height = 0

--проверка версии плеера: на старых версиях geometry сам по себе не изменяет размер плеера, а 2 изменения размера окна одновременно будут конфликтовать друг с другом
if mp.get_property("input-commands") ~= nil then
    new_version = true
end

local hidpi = mp.get_property_number("display-hidpi-scale") or 1
if use_hidpi_pixels then
    pref_width = math.floor(pref_width * hidpi + 0.5)
    pref_heigh = math.floor(pref_heigh * hidpi + 0.5)
    local wpos_x, wpos_y = window_pos:match("(%d+).(%d+)")
    if wpos_x and wpos_y then
        window_pos = window_pos:gsub("%d+", math.floor(wpos_x * hidpi + 0.5), 1):gsub("%d+$", math.floor(wpos_y * hidpi + 0.5), 1)
    end
end

function set_pip_mode()
    if mp.get_property_bool("fullscreen") then
        local function on_resize(_, osd_h)
            if osd_h ~= fs_height and not mp.get_property_bool("fullscreen") then
                set_pip_mode()
                mp.unobserve_property(on_resize)
            end
        end
        
        fs_height = mp.get_property_number("osd-height")
        mp.observe_property("osd-height", "number", on_resize) -- ждём, пока плеер выйдет из полноэкранного режима
        mp.set_property_bool("fullscreen", false)
        mp.add_timeout(0.3, function() mp.unobserve_property(on_resize) end) -- отводим на это максимум 0.3с, чтобы не могло быть внезапного перехода спустя много времени
        return
    end
    
    test_w, test_h = mp.get_osd_size()
    if test_w > pref_width*1.5 and test_h > pref_heigh*1.5 then orig_w = test_w; orig_h = test_h end
    local w, h = get_video_size()
    if w == nil then -- на версии mpv 0.38+ этого не случится - там разрешение доступно даже, когда видео не загружено, что позволит рассчитать размеры окна плеера
        mp.osd_message("Видео не загружено - нельзя автоматически изменить размер окна")
        return
    else
        local ww = pref_width
        local wh = pref_heigh
        local diff = (w/h) / (ww/wh)
        if diff > 1 then
            diff = 1 / diff
            ww = ww / diff
        else
            wh = wh / diff
        end
        ww = math.floor(ww * math.sqrt(diff) + 0.5)
        wh = math.floor(wh * math.sqrt(diff) + 0.5)
        mp.set_property("geometry", string.format("%dx%d%s", ww, wh, window_pos))
        
        if not new_version then mp.set_property('window-scale', wh / h) end
    end
    mp.register_event("video-reconfig", savesize)
	
    prev_border = mp.get_property_bool("border")
    mp.set_property_bool("border", false)
    mp.set_property_bool("ontop", true)
	
	if wheel_rewind or wheel_resize then
		mp.add_forced_key_binding("WHEEL_UP",   "wu", function() if mp.get_property_native("mouse-pos")["hover"] then if wheel_rewind then mp.commandv("seek",  rew_secs) else resize_window(scale_factor) end end end)
		mp.add_forced_key_binding("WHEEL_DOWN", "wd", function() if mp.get_property_native("mouse-pos")["hover"] then if wheel_rewind then mp.commandv("seek", -rew_secs) else resize_window(1/scale_factor) end end end)
	end
    
    mp.observe_property("fullscreen", "bool", fs_changed)
    if hide_minitimeline and not mp.get_property("time-pos") then -- особенность поведения минимизированной шкалы времени uosc
        local function hide_after_loading()
            if is_pip_mode then
                mp.add_timeout(0.1, function()
                    mp.command("script-binding uosc/toggle-progress")
                end)
            end
            mp.unregister_event(hide_after_loading)
        end
        mp.register_event("file-loaded", hide_after_loading)
    end
    
    mp.unregister_script_message("toggle-pip-mode")
    mp.add_timeout(0.2, function() -- таймаут, чтобы успели обновиться данные об окне (запрещаем менять положение окна плеера слишком часто во избежание проблем)
        mp.register_script_message("toggle-pip-mode", toggle_pip_mode)
    end)
  
    is_pip_mode = true
end

function restore_original_mode(uosc)
	if mp.get_property_bool("fullscreen") then
        mp.set_property_bool("fullscreen", false)
        return
    end
    mp.unregister_event(savesize)
    
    mp.set_property("geometry", "50%:50%")
    if not new_version then
        local w, h = get_video_size()
        if w == nil then
            mp.osd_message("Видео не загружено - нельзя автоматически изменить размер окна")
        else
            widthscale = orig_w / w
            heightscale = orig_h / h
            local scale = (widthscale < heightscale and widthscale or heightscale)
            mp.set_property('window-scale', scale)
        end
    end
	
    mp.set_property_bool("border", prev_border)
    mp.set_property_bool("ontop", false) -- для правильного определения текущего режима окна плеер должен быть поверх остальных окон только в режиме PiP
	
    if wheel_rewind or wheel_resize then
		mp.remove_key_binding("wu")
		mp.remove_key_binding("wd")
	end
    
    mp.unobserve_property(fs_changed)
    
    mp.unregister_script_message("toggle-pip-mode")
    mp.add_timeout(0.2, function()
        if hide_minitimeline and mp.get_property_bool("fullscreen") == false and uosc then mp.command("script-binding uosc/toggle-progress") end
        mp.register_script_message("toggle-pip-mode", toggle_pip_mode)
    end)
    
    is_pip_mode = false
end

mp.register_event("file-loaded", function()
	if is_pip_mode == false and (mp.get_property_bool("ontop") and not mp.get_property_bool("border")) then
		restore_original_mode()
	end
end)

function savesize()
    local ww, wh = mp.get_osd_size()
    local w, h = get_video_size()
    if not w or not h or not ww or ww <= 0 or not wh or wh <= 0 or not is_pip_mode then return end
    
    local diff = (w/h)/(ww/wh)
    if math.abs(diff - 1) < 0.01 and mp.get_property("geometry") ~= "" then return end
    if diff > 1 then -- постоянная площадь окна плеера при переключениях видео
        diff = 1 / diff
        ww = ww / diff
    else
        wh = wh / diff
    end
    ww = math.floor(ww * math.sqrt(diff) + 0.5)
    wh = math.floor(wh * math.sqrt(diff) + 0.5)
    mp.set_property("geometry", string.format("%dx%d%s", ww, wh, window_pos))
end

function get_video_size() -- фактически отображаемый в плеере размер видео с учётом анаморфа и обрезки
    local w = mp.get_property_number("video-out-params/dw")
    local h = mp.get_property_number("video-out-params/dh")
    return w, h
end

function fs_changed(_, fullscreen)
    if fullscreen and auto_exit_if_fullscreen then
        mp.unobserve_property(fs_changed)
        mp.set_property_bool("fullscreen", false)
        mp.add_timeout(0.1, restore_original_mode)
    elseif fullscreen == false and hide_minitimeline then
        mp.add_timeout(0.2, function() mp.command("script-binding uosc/toggle-progress") end)
    end
end

function toggle_pip_mode()
    if is_pip_mode or (mp.get_property_bool("ontop") and not mp.get_property_bool("border")) then
        restore_original_mode(true)
    else
        set_pip_mode()
    end
end

function resize_window(value) -- уменьшение / увеличечение размеров окна плеера на заданный множитель
    value = tonumber(value) or 1
    if value < 0 then value = -1 / value end -- поскольку 1.5 даёт изменение в полтора раза, в то время как 0.5 - в два, допускаем запись -1.5 (что даст 0.67)
    local ww, wh = mp.get_osd_size()
    if value and ww and not mp.get_property_bool("fullscreen") and (ww * value) > 100 and (wh * value) > 100 then
        if is_pip_mode and new_version then
            local w, h = get_video_size()
            if w and h then
                local ratio = w / h -- не накапливаем ошибку округления
                mp.set_property("geometry", string.format("%dx%d%s", wh*ratio*value, wh*value, window_pos))
            end
        else
            local window_scale = mp.get_property_number("current-window-scale")
            if window_scale then
                mp.set_property_number("current-window-scale", window_scale * value)
            end
        end
    end
end

mp.register_script_message("toggle-pip-mode", toggle_pip_mode)
mp.register_script_message("resize-window", resize_window)
