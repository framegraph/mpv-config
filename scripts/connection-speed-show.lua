-- Показ информации о скорости подключения к видео-серверу при проигрывании видео по сети (скрывается синхронно с интерфейсом uosc)
-- Отображение в полупрозрачном курсиве - значит кэш заполнен и наполняется на скорости потока видео
-- Настройки
local enabled = true -- включено ли отображение по умолчанию (для видео по сети)
local prec = 2 -- точность отображения в числе знаков после запятой (точки)
local showk = false -- показывать ли соотношение скорости к битрейту
local showzero = false -- показывать ли нулевую скорость (в случае, когда кэш должен заполняться)
local duration = 2.0 -- длительность отображения в секундах (желательно, чтобы значение совпадало со временем до скрытия интерфейса)
local scale_factor = 1.0 -- множитель масштаба надписей (желательно, чтобы был такой же, как в uosc)
local fs_scale_factor = 1.3 -- масштаб надписей в полноэкранном режиме





local osd_timer = nil
local timer_update = mp.add_periodic_timer(1, function() updateNetworkSpeed() end)
local timer_clear = mp.add_timeout(duration, function() timer_update:kill(); ass_osd() end)
timer_update:kill()
timer_clear:kill()
local prevspeed = 0
local repcount = 0
local initial = false
local hidpi = 1
local prev1 = ""
local prev2 = ""

function updateNetworkSpeed()
	if enabled then
		cachespeed = mp.get_property_number("cache-speed")
		bitrate = mp.get_property_number("video-bitrate")
        abitrate = mp.get_property_number("audio-bitrate")
        if abitrate then
            if bitrate then bitrate = bitrate + abitrate
            elseif mp.get_property("vid") == "no" then bitrate = abitrate end
        end
        if cachespeed == prevspeed then
            repcount = repcount + 1
        else
            repcount = 0
        end
        prevspeed = cachespeed
        if repcount > 3 then cachespeed = 0 end -- если скорость долго не обновляется, значит потеряна связь с сервером (то есть скорость 0)
		if (cachespeed ~= nil) and (cachespeed > 0 or (showzero and not mp.get_property_bool("demuxer-cache-idle"))) then
			csfloat = cachespeed / 1000000.0 * 8 -- байт/с -> Мбит/с
			if bitrate ~= nil and showk then 
				k = csfloat / (bitrate / 1000000.0)
				PrintASS(string.format("%." .. prec .. "f Мбит/с", csfloat), string.format("k = %." .. prec .. "f", k))
			else
				PrintASS(string.format("%." .. prec .. "f Мбит/с", csfloat), "")
			end
		else
            prev1 = ""
            prev2 = ""
        end
	end
end

function Toggle()
	enabled = not enabled
	if enabled then
		if showk then
			mp.osd_message("Включено отображение скорости соединения для видео по сети\nk - соотношение скорости к битрейту")
		else
			mp.osd_message("Включено отображение скорости соединения для видео по сети\nПоказ соотношения скорости к битрейту можно включить в настройках connection-speed-show.lua")
		end
	else
		mp.osd_message("Отображение скорости соединения выключено", 2)
		ass_osd()
	end	
end

mp.register_event("file-loaded",  function()
    mp.unobserve_property(onMouseMove)
    mp.unobserve_property(onResize)
	hidpi = mp.get_property_number("display-hidpi-scale") or 1
	local path = mp.get_property_native('path') or ""
    if string.find(path, '://') then
        prev1 = ""
        prev2 = ""
        mp.observe_property("mouse-pos", "native", onMouseMove)
        mp.observe_property("osd-dimensions", "native", onResize)
        initial = true
	end
end)

local prev_x = -1
local prev_y = -1
function onMouseMove(_, v)
    if initial then
        initial = false
        return
    end
    if not enabled or (v["x"] == prev_x and v["y"] == prev_y and v["hover"]) then return end
    
    prev_x = v["x"]
    prev_y = v["y"]
    timer_clear:kill()
    local w, h = mp.get_osd_size()
    if v["hover"] == false then -- курсор убран за пределы окна - скрываем надписи
        timer_update:kill()
        ass_osd()
        return
	elseif not (v and v["x"] < w*0.12 and v["y"] > h*0.86) then -- при наведении в облась надписей отображаем скорость постоянно
        timer_clear:resume() -- в противном случае скрываем спустя установленный таймаут
    end
    if not timer_update:is_enabled() then -- если надписи не отображались - показываем их немедленно, иначе - по уже установленному таймеру
        updateNetworkSpeed()
        timer_update:resume()
    end
end

function onResize(_, v) -- если размер интерфейса изменился - необходимо обновить место расположения надписей
    if v and timer_update:is_enabled() then
		PrintASS(prev1, prev2)
    end
end

function PrintASS(text1, text2)
    prev1 = text1
    prev2 = text2
	local scale = hidpi * scale_factor
    if mp.get_property_bool("fullscreen") or mp.get_property_bool("window-maximized") then -- масштабирование аналогично uosc
        scale = hidpi * fs_scale_factor
    end
    local w, h = mp.get_osd_size()
    local style = "{\\fs" .. 17*scale .. "\\bord" .. 1.1*scale .. "\\1c&Heeeeee}"
	local cachefilled = ""
	if mp.get_property_bool("demuxer-cache-idle") then cachefilled = "\\i1\\alpha&H33" end
    local msg = "{\\pos(" .. 16*scale .. "," .. h - 110*scale .. ")"..cachefilled.."}"..style..text2 .. "\n" .. "{\\pos(" .. 16*scale .. "," .. h - 90*scale .. ")"..cachefilled.."}" .. style .. text1
    ass_osd(msg, 1.05, w, h)
end

function ass_osd(msg, duration, osd_x, osd_y)  -- empty or missing msg -> just clears the OSD
  if not msg or msg == '' then
    msg = '{}'  -- the API ignores empty string, but '{}' works to clean it up
    duration = 0
  end
  mp.set_osd_ass(osd_x or 0, osd_y or 0, msg)
  if osd_timer then
    osd_timer:kill()
    osd_timer = nil
  end
  if duration > 0 then
    osd_timer = mp.add_timeout(duration, ass_osd)  -- ass_osd() clears without a timer
  end
end

mp.register_script_message("toggle-connection-speed", Toggle)