-- В сборке уже всё настроено, ничего дополнительно устанавливать не надо
-- Иначе нужно будет скачать две open-source программы:
-- TorrServer https://github.com/YouROK/TorrServer/releases
-- TorrServer Launcher https://github.com/Noperkot/TSL/releases (не обязателен, только под Windows)
-- Лаунчер нужен, если хотите, чтобы сервер был постоянно запущен и готов к работе
-- Пути к программам для автозапуска сервера можно указать в настройках скрипта (по умолчанию: папка 'TorrServer' в директории с mpv.conf)
-- Также для работы скрипта должен быть доступен curl (предустановлен в Windows 10+)

local opts = {                              -- Настройки:
    server = "http://localhost:8090",       -- адрес, на котором хостится Торрсервер
    search_for_external_tracks = true,      -- поиск внешних субтитров и аудиодорожек в торрент-раздаче (их названия должны начинаться с названий соответствующих видеофайлов)
    response_timeout = 15,                  -- максимальное время ожидания ответа (плейлиста с видео, полученного из магнет-ссылки)
    autorun_torrserver = false,             -- автозапуск локального Торрсервера при открытии торрента, если он не был запущен или вылетел
    use_torrserver_launcher = false,        -- откл: использовать "портативный" кроссплатформенный режим запуска TorrServer
                                                -- (сервер будет автоматически закрываться вместе с плеером)
                                            -- вкл: запускать сервер с помощью TorrServer Launcher (только на Windows):
                                                -- сервер останется запущенным до перезапуска ПК, и его можно будет закрыть с помощью значка в трее
    print_server_logs = false,              -- выводить логи Торрсервера в консоль плеера (только при "портативном" режиме запуска)
    torrserver_dir = "~~/TorrServer",       -- путь к папке, в которой лежат файлы Торрсервера ('~~/' - папка с mpv.conf)
    ts_name = "TorrServer-windows-amd64.exe", -- название исполняемого файла TorrServer
    tsl_name = "tsl.exe",                   -- название исполняемого файла TorrServer Launcher
    auto_reload_failed_loading_subs = true, -- автоматическая перезагрузка неудачно загрузившихся внешних субтитров
                                               -- (такое случается нечасто и только на торрентах онлайн, может занять 5-30 сек)
    include_unknown = true,                 -- включать в плейлист торрента файлы, не опознанные как видео или аудио
    correct_server_links = false,           -- при открытии ссылок на Торрсервер всегда подключаться к указанному в настройках адресу, даже если в ссылке написан другой
    -- Настройки горячих клавиш (пустая строка для отключения)
    key_toggle_stats = "Ctrl+i",            -- открыть оверлей со статистикой воспроизводимого торрента
    key_toggle_in_browser = "Ctrl+t",       -- открыть веб-интерфейс TorrServer в браузере по умолчанию
    key_copy_magnet = "Ctrl+m",             -- копировать магнет-ссылку текущей раздачи (без включённых трекеров-анонсеров)
    -- Настройки отображения статистики торрента
    stats_font_size = 20,                   -- размер шрифта текста статистики
    stats_font_border = 1.2,                -- размер контуров вокруг текста
    scale_stats_by_window = "auto",         -- масштабировать текст вместе с окном плеера (no|yes|auto), auto - в соответствии с опцией mpv --osd-scale-by-window
    stats_buffer_size = 20,                 -- размер буферов скорости и кэша в секундах на экране статистики
    stats_autoshow = "no",                  -- автоматически открывать статистику на время первоначальной загрузки видео (no|yes|always)
                                                -- yes - только при открытии новой торрент-раздачи, always - также и при смене файлов внутри раздачи
    stats_show_titles = true,               -- показывать названия торрентов и текущих файлов на экране статистики
    stats_show_hash = true,                 -- показывать инфо-хэш текущей раздачи
    stats_show_latency = false,             -- показывать сетевую задержку до TorrServer (актуально только для удалённых серверов)
}

(require 'mp.options').read_options(opts, 'mpv-torrserver')


local char_to_hex = function(c)
  return string.format("%%%02X", string.byte(c))
end

local function urlencode(url)
  if url == nil then
    return
  end
  url = url:gsub("\n", "\r\n")
  url = url:gsub("([^%w ])", char_to_hex)
  url = url:gsub(" ", "+")
  return url
end

function file_exists(name)
	local f = io.open(name, "r")
	if f ~= nil then io.close(f) return true else return false end
end

local utils = require 'mp.utils'
local server_launched = false -- только при запуске сервера в "портативном" режиме
local first_echo_time = 0


function hook_subprocess(arguments)
    return mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        playback_only = true, -- при ручном закрытии файла немедленно прекращаем попытку открыть торрент
        args = arguments
    })
end

function launch_server()
    local folder_path = mp.command_native({"expand-path", opts.torrserver_dir})
    if opts.use_torrserver_launcher then
        local tsl_path = utils.join_path(folder_path, opts.tsl_name)
        if file_exists(tsl_path) then
            mp.osd_message("Запускается TorrServer...")
            mp.commandv("run", tsl_path, "--start") -- запуск процесса в не зависимом от плеера режиме
            return true
        else
            mp.osd_message('TorrServer Launcher не найден по пути "' .. tsl_path .. '", не удалось запустить сервер', 10)
        end
    else
        local ts_path = utils.join_path(folder_path, opts.ts_name)
        local server_port = opts.server:match("://[^/:]+:(%d+)") or "8090" -- запуск сервера на заданном в настройках порту
        if file_exists(ts_path) then
            mp.osd_message("Запускается TorrServer...")
            server_launched = true
            mp.command_native_async({ -- запуск как сопроцесс - при штатном(!) закрытии плеера сервер завершится автоматически
                name = "subprocess",
                capture_stdout = not opts.print_server_logs,
                capture_stderr = not opts.print_server_logs, -- по непонятным причинам сервер пишет большинство логов в stderr
                playback_only = false,
                args = { ts_path, "--path", folder_path, "--port", server_port }
            }, function(_, res)
                server_launched = false
                if not res.killed_by_us then
                    mp.osd_message("TorrServer аварийно завершил работу! Подробности в консоли плеера")
                    if not opts.print_server_logs then
                        mp.msg.error(res.stderr)
                    end
                    mp.msg.error("TorrServer has crashed!")
                end
            end)
            return true
        else
            mp.osd_message('TorrServer не найден по пути "' .. ts_path .. '", не удалось запустить сервер', 10)
        end
    end
end

function server_echo(after_launch) -- проверка, запущен ли сервер (если да, то обычно занимает 50-100 мс, иначе до 2.5 секунд)
    if not after_launch then
        first_echo_time = os.clock()
    end
    local curl_cmd = {
        "curl",
        "-L",
        "--silent",
        "--max-time", "5",
        opts.server .. "/echo"
    }
    local res, err = hook_subprocess(curl_cmd)
    if not err and res.stdout and res.stdout ~= "" then
        return true
    elseif res.killed_by_us then
        return
    else
        if opts.autorun_torrserver then
            if not after_launch and not (not opts.use_torrserver_launcher and server_launched) then
                local success = launch_server()
                if success then
                    return server_echo(true) -- ждём; как только сервер будет готов к работе сразу пробуем воспроизвести торрент
                end -- не удалось запустить сервер, вся информация уже выведена
            else
                if (os.clock() - first_echo_time) < opts.response_timeout then
                    return server_echo(true)
                else
                    mp.osd_message("Нет связи с TorrServer после его запуска, проверьте правильность адреса сервера в настройках mpv-torrserver.lua", 10)
                end
            end
        else
            mp.osd_message("Нет связи с TorrServer (возможно, он не запущен)")
        end
    end
end

function get_magnet_info(url) -- вызывается только после проверки связи с сервером
    local info_url = opts.server .. "/stream?stat&link=" .. urlencode(url)
    local curl_cmd = {
        "curl",
        "-L",
        "--silent",
        "--max-time", tostring(opts.response_timeout),
        info_url
    }
    local cmd = hook_subprocess(curl_cmd)
    
    if cmd.stdout and cmd.stdout ~= "" then
        return utils.parse_json(cmd.stdout)
    elseif cmd.killed_by_us then
        return
    else
        return nil, "no info response (timeout?)"
    end
end

function post_torrent(url)
    local curl_cmd = {
        "curl",
        "-X",
        "POST",
        opts.server .. "/torrent/upload",
        "-H",
        "accept: application/json",
        "-H",
        "Content-Type: multipart/form-data",
        "-F",
        "file=@\""..url.."\""
    }
    local res, err = hook_subprocess(curl_cmd)

    if res.killed_by_us then
        return
    elseif err then
        return nil, err
    end

    return utils.parse_json(res.stdout)
end

local function edlencode(url)
    return "%" .. string.len(url) .. "%" .. url
end
local function edlencodevid(url)
    return "%" .. string.len(url) .. "%" .. url .. ",-0.01,-0.01,title=Chapter 1"
end

local function guess_type_by_extension(ext)
    if ext == "mkv" or ext == "mp4" or ext == "avi" or ext == "wmv" or ext == "vob" or ext == "m2ts" or ext == "ogm" or ext == "mpg"
			or ext == "mpeg" or ext == "mov" or ext == "ts" or ext == "webm" or ext == "m4v" then
        return "video"
    end
    if ext == "mka" or ext == "mp3" or ext == "aac" or ext == "flac" or ext == "ogg" or ext == "wma" or ext == "m4a" or ext == "dts"
            or ext == "wav" or ext == "wv" or ext == "opus" or ext == "ac3" or ext == "ape" then
        return "audio"
    end
    if ext == "ass" or ext == "srt" or ext == "vtt" or ext == "ssa" or ext == "mks" then
        return "sub"
    end
    return "other";
end

local function string_replace(str, match, replace)
    local s, e = string.find(str, match, 1, true)
    if s == nil or e == nil then
        return str
    end
    return string.sub(str, 1, s - 1) .. replace .. string.sub(str, e + 1)
end

function alphanumsort(a, b)
    local function padnum(d)
        local dec, n = string.match(d, "(%.?)0*(.+)")
        return #dec > 0 and ("%.12f"):format(d) or ("%s%03d%s"):format(dec, #n, n)
    end
    return tostring(a):lower():gsub("%.?%d+",padnum)..("%3d"):format(#b)
        < tostring(b):lower():gsub("%.?%d+",padnum)..("%3d"):format(#a)
end

-- https://github.com/mpv-player/mpv/blob/master/DOCS/edl-mpv.rst
local function generate_m3u(magnet_uri, files, hash)
    for i, fileinfo in ipairs(files) do
        -- strip top directory
        if fileinfo.path:find("/", 1, true) then
            fileinfo.fullpath = string.sub(fileinfo.path, fileinfo.path:find("/", 1, true) + 1)
        else
            fileinfo.fullpath = fileinfo.path
        end
        fileinfo.path = {}
        for w in fileinfo.fullpath:gmatch("([^/]+)") do table.insert(fileinfo.path, w) end
        local ext = string.match(fileinfo.path[#fileinfo.path], "%.(%w+)$")
        fileinfo.type = guess_type_by_extension(ext)
    end
    table.sort(files, function(a, b)
        -- make top-level files appear first in the playlist
        if (#a.path == 1 or #b.path == 1) and #a.path ~= #b.path then
            return #a.path < #b.path
        end
        -- make videos first
        if (a.type == "video" or b.type == "video") and a.type ~= b.type then
            return a.type == "video"
        end
        -- otherwise sort by path
        return alphanumsort(a.fullpath, b.fullpath)
    end)

    local infohash = hash or magnet_uri:match("^magnet:%?xt=urn:bt[im]h:(%w+)") or urlencode(magnet_uri)

    local playlist = { '#EXTM3U' }

    for _, fileinfo in ipairs(files) do
        if fileinfo.processed ~= true and (fileinfo.type ~= "other" or opts.include_unknown) then
            table.insert(playlist, '#EXTINF:0,' .. fileinfo.fullpath)
            local basename = string.match(fileinfo.path[#fileinfo.path], '^(.+)%.%w+$')

            local url = opts.server .. "/stream/" .. urlencode(fileinfo.fullpath) .."?play&index=" .. fileinfo.id .. "&link=" .. infohash
            local hdr = { "!new_stream", "!no_clip",
                          --"!track_meta,title=" .. edlencode(basename),
                          edlencodevid(url)
            }
            local edl = "edl://" .. table.concat(hdr, ";") .. ";"
            local external_tracks = 0

            fileinfo.processed = true
            if opts.search_for_external_tracks and basename ~= nil and fileinfo.type == "video" then
                mp.msg.info("!" .. basename)

                for _, fileinfo2 in ipairs(files) do
                    if #fileinfo2.path > 0 and
                            fileinfo2.type ~= "other" and
                            fileinfo2.processed ~= true and
                            string.find(fileinfo2.path[#fileinfo2.path], basename, 1, true) ~= nil
                    then
                        mp.msg.info("->" .. fileinfo2.fullpath)
                        local title = string_replace(fileinfo2.fullpath, basename, "%")
                        local url = opts.server .. "/stream/" .. urlencode(fileinfo2.fullpath).."?play&index=" .. fileinfo2.id .. "&link=" .. infohash
                        local hdr = { "!new_stream", "!no_clip", "!no_chapters",
                                      "!delay_open,media_type=" .. fileinfo2.type,
                                      "!track_meta,title=" .. edlencode(title),
                                      edlencode(url)
                        }
                        edl = edl .. table.concat(hdr, ";") .. ";"
                        fileinfo2.processed = true
                        external_tracks = external_tracks + 1
                    end
                end
            end
            if external_tracks == 0 then -- dont use edl
                table.insert(playlist, url)
            else
                table.insert(playlist, edl)
            end
        end
    end
    if #playlist == 1 then
        mp.msg.warn("Got empty playlist from torrent")
        return
    end
    return table.concat(playlist, '\n')
end

function from_server(url, strict) -- проигрывается ли ссылка с Torrserver
    if not url then
        url = mp.get_property("stream-open-filename") or ""
    end
    local hash = url:match("[?&]link=(%w+)") -- на случай, если адрес сервера сменился
    return (string.find(url, opts.server, 1, true) ~= nil)
            or (not strict and url:match("https?://[^/]+/stream/") and url:match("[?&]play") and url:match("[?&]index=") and hash and #hash == 40)
end

mp.add_hook("on_load", 5, function()
	local url = mp.get_property("stream-open-filename") or ""
    if opts.correct_server_links and from_server(url) and not from_server(url, true) and url:match("https?://[^/]+") then
        local host = url:match("https?://[^/]+")
        local stream_url = url:gsub(host:gsub("([%p])", "%%%1"), opts.server) -- экранирование адреса для строгой замены
        if url ~= stream_url then
            mp.msg.info("TorrServer hostname has corrected from " .. host .. " to " .. opts.server)
            mp.set_property("stream-open-filename", stream_url) -- подключение по новому адресу без изменения ссылки в плейлисте
            url = stream_url
        end
    end
    
    if #url == 40 and url:lower():match("^[%dabcdef]+$") then
		mp.osd_message("Инфо-хэш " .. url .. " конвертируется в магнет-ссылку...")
		url = "magnet:?xt=urn:btih:" .. url	
	end
    
    if url:match("^magnet:") or url:match("%.torrent$") or (opts.autorun_torrserver and from_server(url, true) and not server_launched) then
        local success = server_echo() -- проверка связи и запуск сервера при необходимости
        if not success then
            mp.set_property("stream-open-filename", opts.server .. "/stream?m3u&link=" .. urlencode(url))
            return
        end
    end
	
    if url:match("^magnet:") or url:match("%.torrent$") then
        local torrent_info, err
        if url:match("%.torrent$") and not url:match("://") then
            torrent_info, err = post_torrent(url)
        else
            torrent_info, err = get_magnet_info(url)
        end
    
        if type(torrent_info) == "table" and torrent_info.file_stats then
            -- торрент может содержать множество файлов - открываем как плейлист
            local m3u = generate_m3u(url, torrent_info.file_stats, torrent_info.hash)
            if m3u then
                mp.set_property("stream-open-filename", "memory://" .. m3u)
                mp.osd_message("Торрент воспроизводится...\n"
                        .. opts.key_toggle_stats .. " – показать статистику торрента\n"
                        .. opts.key_toggle_in_browser .. " – открыть веб-интерфейс сервера")
            else
                mp.osd_message("Торрент не содержит воспроизводимых файлов")
                mp.commandv("playlist-remove", "current")
            end
        else
            if err then
                mp.msg.warn("error: " .. err)
                mp.osd_message("Нет ответа от TorrServer (возможно, на раздаче нет сидов)\n"
                        .. "Попробуйте зайти в веб-интерфейс сервера за информацией, нажав " .. opts.key_toggle_in_browser .. "\n"
                        .. "Если открывали торрент по магнет-ссылке, попробуйте скачать .torrent файл и перетащить его в окно плеера", 15)
            end
            mp.set_property("stream-open-filename", opts.server .. "/stream?m3u&link=" .. urlencode(url))
        end
    end
    
    if from_server(url) and url:match("^https?://") and mp.get_property_bool("ytdl") then
        mp.set_property_bool("file-local-options/ytdl", false) -- отключение парсинга ссылки на сервер с помощью yt-dlp
    end
    if (url:match("https?://localhost[/:]") or url:match("https?://127%.0%.0%.1[/:]")) and (mp.get_property("http-proxy") or "") ~= "" then
        -- отключение проксирования соединений до локального Torrserver
        -- судя по всему, сам Torrserver не позволяет указать прокси для торрент-трафика, поэтому перенаправить его на сервер не получится
        mp.set_property("file-local-options/http-proxy", "")
    end
end)


local pause_state = nil
local checking = false
local timer = mp.add_timeout(1, function() timer_fn() end)
timer:kill()
function subs_repair()
	if checking == false then
		pause_state = mp.get_property_bool("pause")
	end
    checking = true
    mp.set_property_bool("pause", true)
    mp.osd_message("Перезагрузка субтитров...", 10)
	if mp.get_property("current-tracks/sub/codec") ~= "null" or mp.get_property("sid") == "no" then restore() mp.osd_message("") return end
    reload_subs()
    timer:kill()
    timer:resume()
end
function timer_fn()
    if (mp.get_property_number('demuxer-cache-duration') or 0) < 1 then
        if checking then
            timer:kill()
            timer:resume()
        end
    else
        if checking then mp.osd_message("Субтитры успешно загружены") end
        restore()
    end
end
function restore()
	if pause_state ~= nil then mp.set_property_bool("pause", pause_state) end
    checking = false
end
function reload_subs()
    local t = mp.get_property("sid")
	mp.set_property("sid", "no")
	mp.set_property("sid", t)
end

function check_message(tab)
    if tab["prefix"] == "timeline" and string.find(tab["text"], "failed to load segment") and from_server() then
        subs_repair()
    end
end
if opts.auto_reload_failed_loading_subs then
    mp.enable_messages("error")
    mp.register_event("log-message", check_message)
end


local stats_overlay = mp.create_osd_overlay("ass-events")
local stats_updater = mp.add_periodic_timer(1, function() update_stats() end)
stats_updater:kill()
local style = string.format("{\\rDefault\\fs%d\\bord%f\\1a&H11&}", opts.stats_font_size, opts.stats_font_border)
local buffers = {  -- буферы с предыдущими значениями величин для построения графиков
    dl = {},
    ul = {},
    cache = {},
    poll = {}
}
local info_hash = ""
local stats_visible = false
local stats_query = nil
local start_time = 0
local guessed_files = {}
local autohide = false

local scale_stats = false
if opts.scale_stats_by_window == "auto" then
    scale_stats = mp.get_property_bool("osd-scale-by-window")
elseif opts.scale_stats_by_window == "yes" or opts.scale_stats_by_window == "true" then
    scale_stats = true
end
if not scale_stats then -- иначе mpv самостоятельно отмасштабирует надписи
    mp.observe_property("osd-height", "number", function(_, h)
        stats_overlay.res_y = h or 0
        if stats_visible then
            stats_overlay:update()
        end
    end)
end


function toggle_torrent_stats()
    stats_visible = not stats_visible
    if stats_visible then
        if from_server(link) and #info_hash == 40 then
            if not autohide then
                mp.osd_message("")
                stats_overlay.data = style .. "Получение данных..."
                stats_overlay:update()
            end
            for _, buf in pairs(buffers) do -- данные в буферах стали неактуальны - очищаем их
                for i = 1, opts.stats_buffer_size do buf[i] = 0 end
            end
            mp.add_forced_key_binding("ESC", "close-stats", toggle_torrent_stats)
            update_stats()
            stats_updater:resume()
        else
            local osd_msg = "Торрент не открыт - статистика недоступна"
            if from_server(link) then
                osd_msg = "Не удаётся извлечь инфо-хэш торрента из ссылки TorrServer"
            end
            -- сервер, запущенный в портативном режиме в одном окне плеера, вполне может использоваться и другими окнами - полезно знать, где он открыт
            if server_launched then
                osd_msg = osd_msg .. "\n* Сервер запущен в этом окне mpv"
            end
            mp.osd_message(osd_msg)
            stats_visible = false
        end
    else
        stats_updater:kill()
        stats_overlay:remove()
        if stats_query then
            mp.abort_async_command(stats_query)
            stats_query = nil
        end
        mp.remove_key_binding("close-stats")
        autohide = false
    end
end

function update_stats()
    -- получение внутренней информации о состоянии торрента на сервере, подробнее: http://localhost:8090/swagger/index.html#/API/post_cache
    if stats_query then
        -- запрос не успел обработаться за секунду (возможно Торрсервер завис, в среднем он обрабатывается ~50 мс), пробуем отправить новый
        mp.abort_async_command(stats_query)
        if not autohide then
            stats_overlay.data = stats_overlay.data:gsub("\\N{\\1c&H[^\n\\]+$", "") .. "\\N{\\1c&H66CCFF&}TorrServer не отвечает"
            stats_overlay:update()
        end
    else
        start_time = os.clock()
    end
    local host = string.match(mp.get_property("stream-open-filename") or "", "https?://[^/]+")
    stats_query = mp.command_native_async({ -- stats_query содержит лишь данные для отмены асинхронного запроса
        name = "subprocess",
        capture_stdout = true,
        playback_only = false, -- чтобы не было прерываний при переключении между файлами торрента
        args = {
            'curl', '--silent', '-X', 'POST', (host or opts.server)..'/cache',
            '-H', 'accept: application/json', '-H', 'Content-Type: application/json', 
            '-d', string.format('{"action": "get", "hash": "%s"}', info_hash),
            '-w', '\n%{http_code} %{time_total}'
        }
    }, function(success, res)
        if not res.killed_by_us then
            stats_query = nil
        end
        if not stats_visible then return end
        
        local json_str, status_code, latency = res.stdout:match("^(.*)\n(%d+) ([%d%.]+)$")
        if success and res.status == 0 and json_str and json_str ~= "" then
            local polling_time = tonumber(latency) and (math.floor(os.clock() - start_time) * 1000 + math.floor(tonumber(latency) * 1000 + 0.5)) or -1
            local json = utils.parse_json(json_str)
            if json and json.Torrent then
                local function safe(val)
                    if val then return tostring(val)
                           else return "{\\i1}?{\\i0}" end
                end
                local function format_bytes_humanized(val)
                    local d = {"байт", "КБ", "МБ", "ГБ", "ТБ", "ПБ"}
                    local b = tonumber(val)
                    if not b or b < 1000 then return tostring(val).." "..d[1] end
                    
                    local i = 1
                    while b >= 1000 do
                        b = b / 1024
                        i = i + 1
                    end
                    return string.format("%0.2f %s", b, d[i] and d[i] or "*1024^" .. (i-1))
                end
                local function append(txt)
                    stats_overlay.data = stats_overlay.data .. txt .. "\\N"
                end
                local function iappend(txt) -- добавление с отступом в начале
                    stats_overlay.data = stats_overlay.data .. "\\h\\h\\h\\h\\h" .. txt .. "\\N" 
                end
                local function bold(txt)
                    return "{\\b1}" .. txt .. "{\\b0}"
                end
                -- адаптировано из stats.lua
                -- Generate a graph from the given values.
                -- Returns an ASS formatted vector drawing as string.
                --
                -- values: Array/table of numbers representing the data. Used like a ring buffer
                --         it will get iterated backwards `opts.stats_buffer_size` times starting at position `i`.
                -- v_max : The maximum number in `values`. It is used to scale all data
                --         values to a range of 0 to `v_max`.
                -- v_avg : The average number in `values`. It is used to try and center graphs
                --         if possible. May be left as nil
                local function generate_graph(values, v_max, v_avg, pieces_count, ratio)
                    local x_tics = 8 * opts.stats_font_size / opts.stats_buffer_size
                    local x_max = (opts.stats_buffer_size - 1) * x_tics
                    local y_max = opts.stats_font_size * 0.66
                    local x = 0
                    local scale = 1
                    local s = {}

                    if not pieces_count then
                        if v_max > 0 then
                            -- try and center the graph if possible, but avoid going above `scale`
                            if v_avg and v_avg > 0 then
                                scale = math.min(scale, v_max / (2 * v_avg))
                            end
                            scale = scale * y_max / v_max
                        end  -- else if v_max==0 then all values are 0 and scale doesn't matter

                        s[1] = string.format("m 0 0 n %f %f l ", x, y_max - scale * math.min(values[opts.stats_buffer_size], v_max))
                        local i = ((opts.stats_buffer_size - 2) % opts.stats_buffer_size) + 1

                        for _ = 1, opts.stats_buffer_size - 1 do
                            if values[i] then
                                x = x - x_tics
                                s[#s+1] = string.format("%f %f ", x, y_max - scale * math.min(values[i], v_max))
                            end
                            i = ((i - 2) % opts.stats_buffer_size) + 1
                        end

                        s[#s+1] = string.format("%f %f %f %f", x, y_max, 0, y_max)
                    else
                        x_max = x_max * 2
                        x_tics = x_max / pieces_count
                        s[1] = string.format("m 0 0 -%f %f ", x_max, y_max)
                        local curr_tic = 0
                        local function calc(cnt) return -x_max + curr_tic + x_tics * cnt end
                        for _, v in ipairs(values) do
                            if v.prio == 0 then
                                s[#s+1] = string.format("m %f %f ", calc(v.count), y_max)
                            else
                                local height = 1 -- блок уже в кэше
                                if v.prio > 0 and v.prio < 3 then
                                    height = 0.2
                                elseif v.prio >= 3 and v.prio < 5 then
                                    height = 0.4
                                elseif v.prio >= 5 then
                                    height = 0.7
                                end
                                s[#s+1] = string.format("l %f %f %f %f %f %f ",
                                        calc(0), (1-height)*y_max, calc(v.count), (1-height)*y_max, calc(v.count), y_max, calc(0), y_max, calc(v.count), y_max)
                            end
                            curr_tic = curr_tic + x_tics * v.count
                        end
                        if ratio and ratio < 1 then -- выделение текущего примерного местоположения на шкале кэша
                            local marker_x = -x_max*2 + x_max * ratio
                            s[#s+1] = string.format("{\\p0\\1c&H0000FF&\\p1}m %f %f l %f %f %f %f",
                                    marker_x, -y_max*0.2, marker_x - opts.stats_font_size*0.15, -y_max*0.7, marker_x + opts.stats_font_size*0.15, -y_max*0.7)
                        end
                    end

                    local bg_box = string.format("{\\bord%s\\3c&HCCCC22&\\1c&H262626&}m 0 %f l %f %f %f 0 0 0",
                                    opts.stats_font_border, y_max, x_max, y_max, x_max)
                    return string.format("  {\\rDefault\\pbo%s\\shad0\\alpha&H00}{\\p1}%s{\\p0}{\\bord0\\1c&HFFFFFF}{\\p1}%s{\\p0}%s",
                                    opts.stats_font_border, bg_box, table.concat(s), style)
                end
                local function calc_buf(buf, min_target) -- min_target не позволяет значениям на уровне погрешности заполнять график
                    local sum = 0
                    local maxv = 0
                    for i = 1, #buf do
                        sum = sum + buf[i]
                        if buf[i] > maxv then maxv = buf[i] end
                    end
                    return math.max(maxv, min_target), sum / #buf
                end
                local function progress_bar(p_start, p_end, s_id, ratio) -- подготовка данных об участке кэша (соответствующему одному файлу) для прогресс-бара
                    local v_cache = {}
                    -- -1 : блок скачан и в кэше TorrServer
                    --  0 : нет данных или явно не скачан и приоритет 0
                    -- 1+ : блок не скачан, но в очереди на скачивание с указанным приоритетом
                    local prev_type = -2
                    local is_high_priority = false
                    local have_downloaded = false
                    for i = p_start, p_end do
                        local piece = json.Pieces[tostring(i)]
                        local curr_type = 0
                        if piece then
                            if piece.Completed then
                                curr_type = -1
                                have_downloaded = true
                            else
                                curr_type = math.max(piece.Priority, 0)
                            end
                            -- судя по наблюдением, Torrserver выставляет приоритет 4-5 на блоки, которые сейчас пытается скачать плеер
                            if piece.Priority > 3 then
                                is_high_priority = true
                            end
                        end
                        if curr_type ~= prev_type then
                            v_cache[#v_cache+1] = {prio = curr_type, count = 1}
                        else
                            v_cache[#v_cache].count = v_cache[#v_cache].count + 1
                        end
                        prev_type = curr_type
                    end
                    if is_high_priority and s_id and not guessed_files[s_id] then
                        guessed_files[s_id] = {start_offset = p_start, end_offset = p_end}
                    end
                    
                    -- касаемо графика заполнения кэша:
                    -- TorrServer не предоставляет исходный порядок размещения файлов в раздаче, а лишь только отсортированный по алфавиту
                    -- эти порядки совпадают далеко не всегда, поэтому на торрентах с несколькими файлами кэш может быть смещён или вообще не виден 
                    -- чтобы это хоть как-то исправить и сделать видимой хотя бы динамику заполнения кэша при буферизации, добавлена корректировка области кэша:
                    
                    -- если не нашли ни одного запрашиваемого плеером блока в участке кэша, но они есть в другом месте, пробуем скорректировать участок
                    -- однако для торрентов с внешними дорожками плеер может одновременно пытаться скачать до 3 потоков (видео, внешние аудио и субтитры)
                    -- в этом случае есть вероятность перепутать участки кэша местами, поэтому корректируем только, если расчётный участок совсем неверный
                    if s_id and ratio and ratio < 1 and not guessed_files[s_id] and not is_high_priority 
                            and not (string.match(mp.get_property("stream-open-filename") or "", "^edl://") and have_downloaded)
                    then
                        local found, byte_offset
                        local ext_subs = mp.get_property("current-tracks/sub") and string.match(mp.get_property("stream-open-filename") or "", "^edl://")
                        for k, v in pairs(json.Pieces) do
                            if v.Priority and v.Priority > 3 and tonumber(k) then
                                byte_offset = tonumber(k) * json.PiecesLength
                                local taken = false
                                for _, entry in pairs(guessed_files) do -- проверяем, что сегмент уже не занят другой дорожкой
                                    if tonumber(k) >= entry.start_offset and tonumber(k) <= entry.end_offset then
                                        taken = true
                                    end
                                end
                                -- если выбраны субтитры (для которых не строится график), есть шанс посчитать их скачивание за неверный расчётный участок
                                -- даже, когда он правильный - поэтому требуем наличие активности в соседнем блоке (субтитры зачастую умещаются в 1 блок)
                                if not taken and (not ext_subs or json.Pieces[tostring(tonumber(k) - 1)] or json.Pieces[tostring(tonumber(k) + 1)]) then
                                    found = true
                                    break
                                end
                            end
                        end
                        if found and byte_offset and json.Torrent.file_stats[tonumber(s_id)] then
                            local file_len = json.Torrent.file_stats[tonumber(s_id)].length
                            local start_seg = math.floor((byte_offset - file_len * ratio) / json.PiecesLength + 0.5)
                            local end_seg = start_seg + (p_end - p_start) -- длина в сегментах должна остаться такой же, как и на входе
                            if start_seg >= 0 and end_seg <= json.PiecesCount then
                                guessed_files[s_id] = {start_offset = start_seg, end_offset = end_seg, approx = true}
                                return progress_bar(start_seg, end_seg) -- пересчёт с новым диапазоном
                            end
                        end
                        -- если хоть одно условие не выполнено, возвращаем кэш расчётного участка (пробуем скорректировать при более благоприятных условиях)
                    end
                    
                    return v_cache
                end
                local function stream_info(s_id, ext_path) -- вывод информации о текущем видео, а также о выбранной внешней аудиодорожке
                    local byte_pos = 0
                    local s_path = nil
                    local s_size = nil
                    for _, elem in ipairs(json.Torrent.file_stats) do
                        if elem.id == tonumber(s_id) then
                            s_path = elem.path
                            s_size = elem.length
                            break
                        end
                        byte_pos = byte_pos + elem.length
                    end
                    
                    if s_path and s_size then
                        local piece_start = math.floor(byte_pos / json.PiecesLength)
                        local piece_end = math.floor(piece_start + s_size / json.PiecesLength)
                        if guessed_files[s_id] then
                            piece_start = guessed_files[s_id].start_offset
                            piece_end = guessed_files[s_id].end_offset
                        end
                        local approx = (guessed_files[s_id] and guessed_files[s_id].approx)
                        local bitrate_str = ""
                        local duration = mp.get_property_number("duration") -- продолжительность медиа неизвестна до его открытия плеером
                        if duration and duration > 0 then
                            if not ext_path then
                                bitrate_str = bold("Средний битрейт:  ") .. string.format("%.2f Мбит/с", (s_size / duration) / 1000000 * 8)
                            else
                                bitrate_str = bold("Средний битрейт:  ") .. string.format("%d кбит/с", (s_size / duration) / 1000 * 8)
                            end
                        end
                        
                        local ratio = nil -- отношение текущей позиции плеера на медиа-потоке к размеру потока в байтах
                        local dl_ratio = nil -- то же, но для позиции, которую сейчас скачивает плеер (находится после конца внутреннего кэша плеера)
                        if not ext_path then
                            local curr_byte_pos = mp.get_property_number("stream-pos") -- известна даже в EDL как позиция в байтах на видеопотоке
                            local demuxer_stats = mp.get_property_native("demuxer-cache-state") or {}
                            if curr_byte_pos then
                                ratio = curr_byte_pos / s_size
                                dl_ratio = (curr_byte_pos + (demuxer_stats["fw-bytes"] or 0)) / s_size
                            end
                        else
                            -- в аудио битрейт колеблется не так сильно, поэтому можно взять соотношение к продолжительности дорожки
                            local time_pos = mp.get_property_number("time-pos")
                            local duration = mp.get_property_number("duration")
                            if time_pos and duration then
                                ratio = time_pos / duration
                                dl_ratio = (time_pos + (mp.get_property_number("demuxer-cache-duration") or 0)) / duration 
                            end
                        end
                        
                        append("")
                        if not ext_path then
                            append(bold("Видео:  ") .. (opts.stats_show_titles and s_path:gsub("[^/]*/", "", 1) or ""))
                        else
                            append(bold("Внешнее аудио:  ") .. (opts.stats_show_titles and ext_path or ""))
                        end
                        iappend(bold("Размер файла:  ") .. format_bytes_humanized(s_size) .. "      " .. bitrate_str)
                        iappend((approx and "{\\i1}" or "") .. bold("Заполнение кэша:")
                                .. generate_graph(progress_bar(piece_start, piece_end, s_id, dl_ratio), 0, 0, piece_end-piece_start+1, ratio))
                    end
                end
                
                
                if not json.Torrent.download_speed then json.Torrent.download_speed = 0 end
                if not json.Torrent.upload_speed then json.Torrent.upload_speed = 0 end
                if not json.Torrent.Filled then json.Torrent.Filled = 0 end
                for _, buf in pairs(buffers) do
                    if #buf >= opts.stats_buffer_size then table.remove(buf, 1) end
                end
                table.insert(buffers.dl, json.Torrent.download_speed)
                table.insert(buffers.ul, json.Torrent.upload_speed)
                table.insert(buffers.cache, json.Filled)
                table.insert(buffers.poll, polling_time)
                
                stats_overlay.data = style
                append(bold("Торрент:  ") .. (opts.stats_show_titles and safe(json.Torrent.title) or ""))
                if opts.stats_show_hash then
                    iappend(bold("Инфо-хэш:  ") .. safe(json.Hash))
                end
                -- от размера блока в торренте зависит скорость перемотки (чем меньше, тем быстрее) - иногда полезно знать
                iappend(bold("Размер торрента:  ") .. format_bytes_humanized(safe(json.Torrent.torrent_size))
                        .. "      " .. bold("Размер блока:  ") .. format_bytes_humanized(safe(json.PiecesLength)):gsub("%.00 ", " "))
                iappend(bold("Сиды:  ") .. safe(json.Torrent.connected_seeders) 
                        .. "      " .. bold("Пиры:  ") .. safe(json.Torrent.active_peers).." / "..safe(json.Torrent.total_peers))
                -- для торрента онлайн скорость меньше 0.1 Мбит/с - погрешность около 0, так что можно всегда писать в Мбит/с
                iappend(bold("Скорость загрузки:  ") .. string.format("%.2f Мбит/с", json.Torrent.download_speed / 1000000 * 8) 
                        .. generate_graph(buffers.dl, calc_buf(buffers.dl, 125000)))
                iappend(bold("Скорость отдачи:  ") .. string.format("%.2f Мбит/с", json.Torrent.upload_speed / 1000000 * 8)
                        .. generate_graph(buffers.ul, calc_buf(buffers.ul, 125000)))
                iappend(bold("Кэш TorrServer:  ") .. format_bytes_humanized(json.Filled) .. generate_graph(buffers.cache, json.Capacity or 100 * 2^20))
                iappend(bold("Всего загружено:  ") .. format_bytes_humanized(safe(json.Torrent.bytes_read))
                        .. "      " .. bold("Всего отдано:  ") .. format_bytes_humanized(safe(json.Torrent.bytes_written)))
                -- число повреждённых блоков (с несовпавшей контрольной суммой), которые серверу пришлось перекачать перед отправкой в плеер
                iappend(bold("Потеряно блоков:  ") .. (json.Torrent.pieces_dirtied_bad or 0) .. " из " .. (json.Torrent.pieces_dirtied_good or 0))
                if opts.stats_show_latency and polling_time >= 0 then
                    iappend(bold("Задержка сервера:  ") .. string.format("%d мс", polling_time) .. generate_graph(buffers.poll, calc_buf(buffers.poll, 100)))
                end
                if server_launched then
                    iappend("Сервер запущен в этом окне mpv")
                end
                
                if json.Pieces and json.PiecesCount and json.Torrent.torrent_size and json.PiecesLength and json.Torrent.file_stats then
                    local link = mp.get_property("stream-open-filename") or ""
                    local v_id = link:match("[?&]index=(%d+)") -- id видеофайла (в edl он также идёт первой ссылкой)
                    local audio_title = mp.get_property("current-tracks/audio/title")
                    if v_id then
                        stream_info(v_id)
                    end
                    if link:find("^edl://") and audio_title then
                        -- заменяем начала полей внешних аудиодорожек на непечатный символ, чтобы можно было пройтись по ним с помощью gmatch
                        link = link:gsub("!new_stream;!no_clip;!no_chapters;!delay_open,media_type=audio;!track_meta,title=", "\001")
                        for track in link:gmatch("\001[^\001]+") do
                            local title_len = track:match("^\001%%(%d+)")
                            if title_len and tonumber(title_len) == #audio_title and audio_title == track:gsub("^\001%%%d+%%", ""):sub(1, #audio_title) then
                                local a_id = track:gsub("^\001%%%d+%%", ""):sub(#audio_title+1):match("[?&]index=(%d+)")
                                if a_id then
                                    stream_info(a_id, audio_title)
                                end
                            end
                        end
                    end
                    -- внешние субтитры обычно занимают лишь 1 блок торрента, загружаются в плеер атомарно (не по частям, а сразу целиком),
                    -- поэтому выводить информацию о них нет особого смысла
                end
                
                stats_overlay:update()
            end
        elseif not res.killed_by_us and not autohide then
            local err = ""
            if status_code == "000" then
                err = "Нет связи с сервером"
            elseif status_code == "404" then
                err = "Торрент не найден на сервере"
            else
                err = "Неизвестная ошибка" .. (status_code and (" с кодом " .. status_code) or "")
            end
            stats_overlay.data = stats_overlay.data:gsub("\\N{\\1c&H[^\n\\]+$", "") .. "\\N{\\1c&H6666FF&}" .. err
            stats_overlay:update()
        end
    end)
end

mp.observe_property("stream-open-filename", "string", function(_, link)
    if link then -- сбрасывается в nil при переключениях между файлами на короткое время
        local hash = link:match("[?&]link=(%w+)") or ""
        
        if opts.stats_autoshow ~= "no" and #hash == 40 and from_server(link) and not stats_visible and (hash ~= info_hash or opts.stats_autoshow == "always") then
            local function on_playback_starts()
                if autohide and stats_visible then
                    toggle_torrent_stats()
                end
                mp.unregister_event(on_playback_starts)
            end
            
            autohide = true
            info_hash = hash
            toggle_torrent_stats()
            mp.register_event("playback-restart", on_playback_starts) -- окончание загрузки и первичной буферизации
        end
        
        if #hash == 40 and from_server(link) then
            info_hash = hash -- не закрываем статистику при переключении между разными торрентами, а лишь обновляем инфо-хэш
        else
            if stats_visible then
                toggle_torrent_stats()
            end
            info_hash = ""
        end
        guessed_files = {}
    end
end)
mp.observe_property("idle-active", "bool", function(_, idle)
    if idle and stats_visible then
        toggle_torrent_stats()
    end
end)

mp.register_event("file-loaded", function()
    local link = mp.get_property("stream-open-filename") or ""
    if link:match("^edl://") and from_server(link) then
        -- при добавлении нового сегмента в виртуальную шкалу времени EDL плеер автоматически добавляет туда чаптер
        -- чтобы при этом сохранить встроенные в видеофайл эпизоды приходится не отключать это поведение
        -- убираем этот искусственный чаптер при загрузке видео
        local chapters = mp.get_property_native("chapter-list") or {}
        for i, v in ipairs(chapters) do
            if v.title == "Chapter 1" and v.time and v.time <= 0 then
                table.remove(chapters, i)
                mp.set_property_native("chapter-list", chapters)
                break
            end
        end
    end
end)

local plat = "windows"
if not (package.config:sub(1,1) ~= '/') then
    plat = "linux"
end
if mp.get_property("platform") == "darwin" then -- свойство доступно начиная с mpv v0.36+
    plat = "darwin"
end

function open_in_browser()
    mp.osd_message("Открывается веб-интерфейс TorrServer в браузере...")
    local param = "" -- команды взяты из MPV_lazy/scripts/input_plus.lua (проверялось только на windows)
	if plat == "windows" then
		param = 'no-osd run cmd /c start "" "' .. opts.server .. '"'
	elseif plat == "darwin" then
		param = "no-osd run /bin/sh -c \"open '" .. opts.server .. "' &\""
	elseif plat == "linux" then
		param = "no-osd run /bin/sh -c \"xdg-open '" .. opts.server .. "' &\""
	end
    mp.command(param)
end

function copy_magnet()
    if info_hash ~= "" then
        local magnet = "magnet:?xt=urn:btih:" .. info_hash
        local wait = "Магнет-ссылка копируется..."
        local succ = "Скопирована ссылка: " .. magnet
        if mp.get_property("clipboard") ~= nil then -- новая версия mpv (0.40+) с нативной поддержкой копирования в буфер обмена
            mp.set_property("clipboard/text", magnet)
            mp.osd_message(succ)
        elseif plat == "windows" then -- копирование с помощью powershell (может занять время)
            mp.osd_message(wait)
            mp.command_native_async({
                name = "subprocess",
                capture_stdout = true,
                playback_only = false,
                args = { "powershell", "set-clipboard", string.format('"%s"', magnet) }
            }, function(success, res)
                if success and res.status == 0 then
                    mp.osd_message(succ)
                end
            end)
        else
            mp.osd_message("Копирование на " .. plat .. " доступно только с помощью встроенной функции mpv v0.40+")
        end
    else
        mp.osd_message("Недоступен инфо-хэш торрента, необходимый для формирования ссылки")
    end
end

function bind_key(key, name, fn)
    mp.add_forced_key_binding(key ~= "" and key or nil, name, fn)
end
bind_key(opts.key_toggle_stats, "torrent-stats", toggle_torrent_stats)
bind_key(opts.key_toggle_in_browser, "open-torrserver-web", open_in_browser)
bind_key(opts.key_copy_magnet, "copy-magnet", copy_magnet)

-- скрипт доработан SearchDownload
