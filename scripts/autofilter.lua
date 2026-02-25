-- Скрипт с различными вспомогательными функциями для автоматического выставления параметров плеера при нужных условиях
-- Рассчитан на использование только в составе сборки SearchDownload

o = {} -- Настройки
o.flash_timeline_on_pause = true -- отображение на короткое время шкалы времени uosc и названия видео при нажатии на паузу (при снятии с паузы показываться не будут)
o.autodeint = false -- авто-деинтерлейсинг с помощью скрипта (в версии mpv 0.38 появилась (и используется в сборке) опция автоматического деинтерлейсинга)
o.autodeblock = true -- авто-деблокинг для старых кодеков (MPEG-1, MPEG-2, Xvid, DivX), в которых он не входит в процесс декодирования, в отличие от современных
o.autoplay = true -- автоплей при открытии видео (иначе плеер не снимется с паузы при выборе другого видео, как во всех других плеерах)
o.reset_crop = true -- сброс фильтров обрезки и де-лого, если у соседних видео разное разрешение (то есть, уже не подходящие из-за других размеров видео)
o.auto_change_seekstyle = true -- отключение перемотки по ключевым кадрам только во время просмотра с внешней аудиодорожкой, при необходимости (работает при --hr-seek=default)
                               -- (необходимо из-за бага плеера: рассинхрон внешнего аудио при перемотке https://github.com/mpv-player/mpv/issues/1824)
o.fix_no_choosed_audio = true -- исправление неприятной особенности плеера: если в предыдущем видео была вручную выбрана аудиодорожка с номером, которого нет в текущем видео,
                              -- а для текущего видео нет запомненной дорожки, то не будет выбрана ни одна аудиодорожка
o.use_system_proxy = 2 -- проверять и использовать настройки системного прокси по возможности (плеер поддерживает только HTTP-прокси): 
                       -- 0 - откл,  1 - только при запуске плеера,  2 - динамически при каждом открытии http(s) ссылки
o.adaptive_hwdec_mode = true -- при активном аппаратном декодировании: при отсутствии видео-фильтров использовать менее требовательный к ресурсам режим HW+ (zero-copy),
                             -- а перед включением фильтров переключать его в режим HW-copy, необходимый для работы фильтров (шейдеры нормально работают и при HW+)
                             -- при отключении опции режим аппаратного декодирования всегда будет HW-copy как наиболее совместимый
o.hw_zerocopy = "auto-safe" -- используемый тип аппаратного декодирования в режиме HW+ (настраивается в mpv.conf)
o.hw_copyback = "auto-copy-safe" -- тип декодирования с копированием кадров в оперативую память (настраивается в mpv.conf)
o.reload_on_network_errors = true -- перезагружать видео при опознанных ошибках сети, когда это может помочь (например, при истечении прямой ссылки на видеопоток)
                                  -- также за авто-перезагрузку в сборке отвечает скрипт reload, его можно настроить в script-opts\reload.conf
o.load_youtube_preview = false -- загрузка превью (миниатюры) ютуб-ролика для показа в медиа-панели windows (SMTC), появляющейся при использовании мультимедийных клавиш
                               -- имеет смысл только на версии mpv 0.39+, поскольку добавили поддержку отображения в SMTC только в этой версии
o.console_info = true -- вывод информации об изменении параметров скриптом в консоль плеера
o.osd_info = true -- вывод информации о важных ошибках, выводящихся в консоль, на OSD (на экран плеера)




(require "mp.options").read_options(o)

local old_w = 0
local old_h = 0
local seekstyle = mp.get_property("hr-seek")
local vidpath = ""
local reload_attempt = 0
local vf_action_fn = nil
local hw_change_time = 0

function info(text)
    if o.console_info then mp.msg.info(text) end
end
function osd_msg(text, dur)
    if o.osd_info then mp.osd_message(text, dur) end
end

mp.register_event("file-loaded", function()
    reload_attempt = 0
    if o.autodeint then
        mp.unobserve_property(deint)
        mp.observe_property("video-frame-info/interlaced", "bool", deint)
    end
	
	if o.reset_crop then
        h = mp.get_property_number("video-params/h")
        w = mp.get_property_number("video-params/w")
        if w ~= old_w or h ~= old_h then remove_vf("crop="); remove_vf("delogo=") end
        old_w = w
        old_h = h
    end
	
	-- авто-деблокинг для старых кодеков: MPEG-4 part 2 - Xvid или DivX, MPEG-2 video - MPEG-2, MPEG-1 video - MPEG-1
	if o.autodeblock then
        local codec = mp.get_property("video-codec")
        if codec and (string.match(codec, "MPEG.4 part 2") or string.match(codec, "MPEG.2 video") or string.match(codec, "MPEG.1 video")) then
            -- все эти кодеки не поддерживают аппаратное ускорение в mpv - можем смело включать этот фильтр
            mp.commandv("vf", "pre", "deblock") -- деблок для правильной работы должен идти перед остальными фильтрами (обязательно до обрезки)
            info("Старый кодек - включён deblocking")
        end
    end
    
    if o.fix_no_choosed_audio and mp.get_property("aid") == "no" then
        local allcount = mp.get_property_native("track-list/count")
        for i = 0, allcount - 1 do
            if mp.get_property_native("track-list/" .. i .. "/type") == "audio" then
                mp.set_property("aid", "1")
                info("Исправление автовыбора пустой аудиодорожки")
                break
            end
        end
    end
	
	-- отключение деинтерлейсинга, когда он не нужен
	local deinterlace = mp.get_property_native("deinterlace")
	if o.autodeint and deinterlace == true then
		mp.set_property_native("deinterlace", "no")
	end
    
    if o.load_youtube_preview and vidpath:match("^https?://[^/]*youtu%.?be") then
        local url_params = vidpath:match("^https?://[^/]+/(.+)") or ""
        local youtube_id = vidpath:match("://youtu%.be/([%w%-_]+)") or url_params:match("[?&]v=([%w%-_]+)") or url_params:match("^v/([%w%-_]+)")
          or url_params:match("^embed/([%w%-_]+)") or url_params:match("^live/([%w%-_]+)") or url_params:match("^shorts/([%w%-_]+)")
        
        if youtube_id and #youtube_id == 11 then -- загружаем только, если уверены в допустимости ID ютуб ролика
            local preview_path = "https://i.ytimg.com/vi/" .. youtube_id .. "/mqdefault.jpg"
            mp.commandv("video-add", preview_path, "auto", "Preview", "", "yes")
        end
    end
end)

mp.register_event("start-file", function()
    vidpath = mp.get_property("path") or ""
    if o.autoplay then 
        mp.set_property_bool("pause", false)
    end
    
    if o.autodeblock then
        remove_vf("deblock")
    end
    if o.adaptive_hwdec_mode and mp.get_property("vf") == "" and mp.get_property("hwdec") == o.hw_copyback then
        mp.set_property("hwdec", o.hw_zerocopy)
        info("Используется аппаратное ускорение и нет активных видео-фильтров - включено HW+ декодирование")
    end
end)


function deint(name, value)
    if value then
		local deinterlace = mp.get_property_native("deinterlace")
		if deinterlace == false then
			mp.set_property_native("deinterlace", "yes")
			info("Чересстрочная развёртка - включён деинтерлейсинг")
		end
    end
end

function manualdeint()
	mp.unobserve_property(deint)
end

function remove_vf(name)
	local vf_list = mp.get_property("vf")
    for filter in vf_list:gmatch(name .. "[^,]*") do
        mp.commandv("vf", "remove", filter)
    end
end

function flashpause(name, value)
	if value == true then mp.command("script-message-to uosc flash-elements timeline,top_bar") end
end

function changeseekstyle(name, value)
    if value == true and mp.get_property("hr-seek") ~= "yes" then
        mp.set_property("hr-seek", "yes")
        info("Внешняя аудиодорожка - включена точная перемотка")
    elseif value == false and mp.get_property("hr-seek") ~= seekstyle then
        mp.set_property("hr-seek", seekstyle)
        info("Встроенная аудиодорожка - перемотка по ключевым кадрам")
    end
end

if o.flash_timeline_on_pause then mp.observe_property("pause", "bool", flashpause) end

if o.auto_change_seekstyle and seekstyle ~= "yes" and seekstyle ~= "always" then
    mp.observe_property("current-tracks/audio/external", "bool", changeseekstyle)
end

function toggle_fs(bottom_area)
    local wh = mp.get_property_number("osd-height")
    if not wh then return end
    if bottom_area == nil then bottom_area = 80 end
    local hidpi = mp.get_property("display-hidpi-scale")
	if hidpi == nil then hidpi = 1 end
    bottom_area = bottom_area * hidpi
    if mp.get_property_bool("fullscreen") or mp.get_property_bool("window-maximized") then bottom_area = bottom_area * 1.3 end
    if mp.get_property_native("mouse-pos")["y"] < wh - bottom_area then
        mp.command("cycle fullscreen")
    end
end

mp.enable_messages("warn") -- получаем и анализируем сообщения об ошибках, которые выводятся в консоль плеера
mp.register_event("log-message", function(tab)
    if o.reload_on_network_errors then
        -- эта ошибка возникает, например, когда истекла прямая ссылка на видеопоток, и необходимо повторное её получение с помощью yt-dlp
        if tab["prefix"] == "ffmpeg" and tab["text"]:find("HTTP error 403 Forbidden") and mp.get_property("time-pos") then
            osd_msg("Error 403 Forbidden, перезагрузка...")
            mp.command("script-message-to reload reload_resume")
        end
        -- файл распознан как видео или аудио, но не удалось его воспроизвести (например, из-за ошибки сети)
        if tab["prefix"] == "cplayer" and tab["text"]:find("No video or audio streams selected") then
            reload_attempt = reload_attempt + 1
            if reload_attempt <= 3 and vidpath:find("https?://") then -- делаем максимум 3 попытки перезагрузить онлайн-видео
                info("Перезагрузка неудачно загрузившегося онлайн-видео (попытка " .. reload_attempt .. " из 3)")
                local count = mp.get_property_number("playlist-count")
                if count > 0 then -- пытаемся сохранить плейлист с видео
                    for i = 0, count-1 do
                        if mp.get_property("playlist/" .. i .. "/filename") == vidpath then
                            mp.commandv("playlist-play-index", i)
                            return
                        end
                    end
                end
                mp.commandv("loadfile", vidpath)
            else
                reload_attempt = 0
                osd_msg("Не удалось загрузить видео\n" .. vidpath)
            end
        end
    end
    
    -- если видео-фильтр не удалось применить при активном HW+ декодировании, пробуем переключить его в copy-back режим и заново включить фильтры
    -- (на всякий случай - перед включением фильтров из сборки режим декодирования при необходимости меняется, и фильтры включаются без ошибок)
    if o.adaptive_hwdec_mode and tab["prefix"] == "vf" and tab["text"]:match("Disabling filter.+because it has failed") then
        local hw_current = mp.get_property("hwdec-current") or "no" -- определение активного HW+ из autocrop.lua (там тоже временно откл HW+ на время работы фильтра)
        if hw_current:find("%-copy") == nil and hw_current ~= "no" and hw_current ~= "crystalhd" and hw_current ~= "rkmpp" then
            info("Включено декодирование HW-copy на время использования видео-фильтров")
            mp.set_property("hwdec", o.hw_copyback)
            hw_change_time = os.clock() -- ждём, пока переключится режим декодирования (не больше 3 секунд), и только потом применяем фильтры
            vf_action_fn = function() -- вызовется при ближайшем playback-restart (окончании переключения режима декодирования)
                local filters = mp.get_property("vf")
                mp.set_property("vf", "")
                mp.set_property("vf", filters)
            end
        end
    end
    
    if tab["prefix"] == "ytdl_hook" and tab["text"]:find("^ERROR: ") then
        osd_msg("Ошибка при загрузке онлайн-видео:\n" .. tab["text"]:gsub("^ERROR: ", ""), 5)
    end
    if tab["prefix"] == "cplayer" and tab["text"]:find("Failed to recognize file format") and not vidpath:find("https?://") then
        osd_msg("Не удалось распознать формат файла\n" .. vidpath)
    end
    if tab["prefix"] == "lavf" and tab["text"]:find("...treating it as fatal error") then
        osd_msg("Фатальная ошибка при воспроизведении, подробности в консоли плеера")
    end
end)

if o.adaptive_hwdec_mode then
    mp.register_event("playback-restart", function()
        if vf_action_fn and (os.clock() - hw_change_time) < 3 and mp.get_property("hwdec") == o.hw_copyback then
            vf_action_fn()
        end
        vf_action_fn = nil
    end)
end

function change_vf(action, filter, osd)
    local command = string.format("%s vf %s '%s'", (osd and "" or "no-osd"), action, filter)
    local hw_current = mp.get_property("hwdec-current") or "no"
    if o.adaptive_hwdec_mode and action == "clr" and mp.get_property("hwdec") == o.hw_copyback then
        info("Используется аппаратное ускорение и нет активных видео-фильтров - включено HW+ декодирование")
        mp.set_property("vf", "")
        mp.set_property("hwdec", o.hw_zerocopy)
    elseif o.adaptive_hwdec_mode and hw_current:find("%-copy") == nil and hw_current ~= "no" and hw_current ~= "crystalhd" and hw_current ~= "rkmpp" then
        if action and action ~= "remove" and action ~= "clr" then
            info("Включено декодирование HW-copy на время использования видео-фильтров")
            mp.set_property("hwdec", o.hw_copyback)
            hw_change_time = os.clock()
            vf_action_fn = function() mp.command(command) end
        else
            mp.command(command)
        end
    else
        mp.command(command)
    end
end

function toggle_hwdec()
    local hwdec = mp.get_property("hwdec") or "no"
    if hwdec == "no" then
        if o.adaptive_hwdec_mode and mp.get_property("vf") == "" then
            mp.set_property("hwdec", o.hw_zerocopy)
        else
            mp.set_property("hwdec", o.hw_copyback)
        end

        local hw_current = mp.get_property("hwdec-current")
        if not hw_current then
            mp.osd_message("Аппаратное декодирование: вкл")
        elseif hw_current == "no" then
            mp.osd_message("Аппаратное декодирование: вкл (недоступно для текущего видео)")
        else
            mp.osd_message("Аппаратное декодирование: вкл (" .. hw_current .. ")")
        end
    else
        mp.set_property("hwdec", "no")
        mp.osd_message("Аппаратное декодирование: откл (SW)")
    end
end

function swap_subs()
    local primary = mp.get_property("sid")
    local secondary = mp.get_property("secondary-sid")
    if primary ~= secondary then
        mp.set_property("sid", "no") -- необходимо, иначе плеер может выдать ошибку, что субтитры с этим id уже выбраны
        mp.set_property("secondary-sid", primary)
        mp.set_property("sid", secondary)
    end
end

function get_system_proxy_info(param) -- получение системного прокси командой, запущенной плеером (без всплывающих окон)
    local res = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = {"reg", "query", [[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings]], "/v", param}
    })
    return res.stdout or ""
end

local sysproxy_set = false
local prev_proxy_ip = ""
function check_system_proxy()
    local path = mp.get_property("path") or ""
    if path:match("^https?://") or mp.get_property_bool("idle-active") then -- проверяем только при открытии http(s) ссылки и при запуске плеера
        local enabled = get_system_proxy_info("ProxyEnable"):match("REG_DWORD%s+0x(.)")
        local sys_proxy = nil
        if enabled == "1" then
            sys_proxy = get_system_proxy_info("ProxyServer"):match("REG_SZ%s+([^\r\n]+)")
        end
        if sys_proxy then
            local proxy_ip = sys_proxy:gsub("localhost", "127.0.0.1")
            proxy_ip = proxy_ip:match("http=(%d+%.%d+%.%d+%.%d+:%d+)") or proxy_ip:match("%d+%.%d+%.%d+%.%d+:%d+")
            if proxy_ip ~= prev_proxy_ip then sysproxy_set = false end -- системный прокси изменился
            if proxy_ip then
                if not sysproxy_set and (mp.get_property("http-proxy") or ""):gsub("http://", "") == prev_proxy_ip then -- устанавливаем только, если другой прокси не используется
                    info("Используется системный прокси: " .. proxy_ip)
                    mp.set_property("http-proxy", "http://" .. proxy_ip) -- устанавливаем прокси для загрузки видео из сети плеером mpv (yt-dlp использует системный прокси автоматически)
                    sysproxy_set = true
                end
            else
                mp.msg.warn('Не удаётся использовать системный прокси "' .. sys_proxy .. '", поскольку плеер поддерживает только HTTP-прокси')
            end
            prev_proxy_ip = proxy_ip
        elseif sysproxy_set then -- системный прокси не используется, но раньше был установлен
            info("Системный прокси больше не установлен")
            mp.set_property("http-proxy", "")
            sysproxy_set = false
            prev_proxy_ip = ""
        end
    end
end

if o.use_system_proxy >= 1 then
    check_system_proxy()
    if o.use_system_proxy >= 2 then
        mp.register_event("start-file", check_system_proxy)
    end
end

mp.register_script_message("manualdeint", manualdeint)
mp.register_script_message("safe-toggle-fullscreen", toggle_fs) -- отключение перехода в полноэкранный режим при двойных кликах в нижней части экрана с элементами управления плеером uosc
                                                                -- на вход число пикселей от низа окна плеера, при кликах в области которых не переходить в полноэкранный режим
mp.register_script_message("vf", change_vf) -- включение copy-back режима перед активацией видео-фильтра (если активно аппаратное декодирование)
mp.register_script_message("toggle-hwdec", toggle_hwdec) -- включение аппатартного декодирования в нужном режиме в зависимости от наличия фильтров
mp.register_script_message("swap-subtitles", swap_subs) -- поменять местами основные и вторые субтитры
