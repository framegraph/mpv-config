-- Ютуб-парсер для MPV плеера v0.4
-- скрипт из сборки https://github.com/framegraph/mpv-config
-- для работы также требует кастомный ytdl_hook.lua из сборки

local utils = require('mp.utils')
local options = require('mp.options')
local msg = require('mp.msg')

-- подробнее о настройках в script-opts/youtube-parser.conf
local opts = {
    extractor = "default", -- android_vr, ios, visionos, android_reel, ios_reel, android_vr_reel, visionos_reel, web
    parse_hls_manifests = "auto", -- no | auto | yes
    parse_web_player_async = false,
    target_resolution = 1440,
    skip_av1 = true,
    skip_vp9 = false,
    skip_hdr = false,
    skip_ai_upscale = false,
    skip_ai_dub = true,
    prefer_drc = false,
    sub_format = "vtt", -- vtt | srt | srv3 | ttml
    metadata_lang = "en",
    translation_lang = "",
    auto_subs_action = "deselect", -- skip | skip-translated | deselect | none
    premium_extractor = "",
    yt_kids_extractor = "ios_reel",
    dubbed_tracks_extractor = "",
    livestream_extractor = "",
    geoblock_proxy = "",
    curl_path = [[curl]],
    cache_path = [[~~/youtube_parser_cache.json]],
    osd_errors = false,
}
options.read_options(opts, "youtube-parser")


local initial_path, interrupt_data, fallback_running
local storyboard_fmts = {}
local cache = {
    visitor_data = "",
    timestamp = 0 -- время последней записи в файл
}

local extractors = {
    android_vr = {
        client = {
            clientName = "ANDROID_VR",
            clientVersion = "1.63.57", -- начиная с версии 1.64.34 возможен (пока изредка) эксперимент с PO Token (ошибка 403 при открытии потока)
            userAgent = "com.google.android.apps.youtube.vr.oculus/1.63.57 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        },
        client_id = 28,
        yt_kids_available = false,
        premium_available = false, -- доступен ли поток "1080p Premium" (в HLS манифесте)
        -- начиная с clientVersion 1.73.24 доступны аудиодорожки с переводами, однако на ней уже выдаются только SABR медиа-потоки
        -- (кастомный стриминговый протокол Ютуба), не воспроизводимые в mpv и других десктопных плеерах
        dubbed_tracks_available = false,
        visitor_id_required = true,
        api_route = "player",
    },
    -- нестабилен, открываются только HLS потоки, причём не всегда:
    -- парсинг проходит успешно, но при попытке открыть полученный медиапоток возникает ошибка 403 Forbidden
    -- (эксперимент с обязательным требованием предоставить PO Token, которые парсер не поддерживает)
    -- также возможен эксперимент с отсутствием выдачи единственно воспроизводимого HLS манифеста
    ios = {
        client = {
            clientName = "IOS",
            clientVersion = "21.02.3",
            deviceMake = "Apple",  -- необходимо для получения 60 fps форматов
            deviceModel = "iPhone16,2",
            userAgent = "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
        },
        client_id = 5,
        yt_kids_available = true,
        premium_available = true,
        dubbed_tracks_available = true,
        visitor_id_required = false,
        adaptive_formats_unplayable = true, -- всегда требуют PO Token
        api_route = "player",
    },
    visionos = {
        client = { -- Ютуб клиент для visionOS https://apps.apple.com/us/app/youtube-for-visionos/id6745572359
            clientName = "VISIONOS",
            clientVersion = "1.01",
        },
        client_id = 101,
        yt_kids_available = false,
        premium_available = true,
        dubbed_tracks_available = true, -- включая дорожку "Постоянный уровень громкости"
        visitor_id_required = true,
        api_route = "player",
    },
    -- теперь стал всегда требовать PO Token (кроме качества 360p и HLS трансляций, которые воспроизводит стабильно)
    android_reel = { -- также поддерживает извлечение дополнительных метаданных (дата публикации, число лайков, комментариев...)
        client = {
            clientName = "ANDROID",
            clientVersion = "20.26.46",  -- на версии "21.02.35" (возможно и других 21.*) может быть SABR-эксперимент
            androidSdkVersion = 30,
            userAgent = "com.google.android.youtube/20.26.46 (Linux; U; Android 11) gzip"
        },
        client_id = 3,
        yt_kids_available = true,
        premium_available = false,
        dubbed_tracks_available = true, -- включая дорожку "Постоянный уровень громкости"
        visitor_id_required = false,
        adaptive_formats_unplayable = true,
        api_route = "reel",
    },
    -- в отличие от iOS даёт воспроизводимые DASH потоки и стабильно возвращает HLS, но они тоже открываются не всегда (возможен эксперимент с PO Token)
    ios_reel = {
        client = {
            clientName = "IOS",
            clientVersion = "21.02.3",
            deviceMake = "Apple",
            deviceModel = "iPhone16,2",
            osName = "iPhone",  -- необходимо для получения аудиодорожек в кодеке Opus
            osVersion = "18.3.2.22D82",
            -- прослеживается вариативность: если передавать iOS user agent, макс. качество будет 4K HDR
            -- а если не передавать, будет доступно 8K качество, но HDR потоки возвращаться не будут
            userAgent = "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
        },
        client_id = 5,
        yt_kids_available = true,
        premium_available = true,
        dubbed_tracks_available = true, -- включая дорожку "Постоянный уровень громкости"
        visitor_id_required = false,
        api_route = "reel",
    },
    android_vr_reel = { -- эквивалент android_vr, но с предоставлением доп. метаданных
        client = {
            clientName = "ANDROID_VR",
            clientVersion = "1.63.57",
            userAgent = "com.google.android.apps.youtube.vr.oculus/1.63.57 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        },
        client_id = 28,
        yt_kids_available = false,
        premium_available = false,
        dubbed_tracks_available = false,
        visitor_id_required = true,
        api_route = "reel",
    },
    visionos_reel = { -- эквивалент visionos, но с предоставлением доп. метаданных
        client = {
            clientName = "VISIONOS",
            clientVersion = "1.01",
        },
        client_id = 101,
        yt_kids_available = false,
        premium_available = true,
        dubbed_tracks_available = true,
        visitor_id_required = true,
        api_route = "reel",
    },
    -- только для извлечения метаданных, предоставляет только SABR потоки и формат 360p, требующий JavaScript расшифровки
    web = {
        client = {
            clientName = "WEB",
            clientVersion = "2.20260114.08.00",
        },
        client_id = 1,
        yt_kids_available = true,
        visitor_id_required = false,
        sabr_expected = true,
        api_route = "player",
    },
}
local default_extractor = "visionos_reel"

local innertube_api = "https://www.google.com/youtubei/v1"
function get_innertube_api_route(extractor, get_config)
    if get_config then
        return innertube_api .. "/config?prettyPrint=false"
    elseif extractor.api_route == "player" then
        return innertube_api .. "/player?prettyPrint=false"
    elseif extractor.api_route == "reel" then
        return innertube_api .. "/reel/reel_item_watch?fields=responseContext,playerResponse,overlay,engagementPanels&prettyPrint=false"
    end
end

function get_innertube_request(extractor, video_id)
    local req = {}
    req.context = {}
    req.context.client = extractor.client
    req.context.client.hl = opts.metadata_lang ~= "" and opts.metadata_lang or "en"
    req.context.client.timeZone = "UTC"
    req.context.client.utcOffsetMinutes = 0
    if extractor.api_route == "reel" then
        req.playerRequest = {}
        req.disablePlayerResponse = false
    end
    local tab = extractor.api_route == "reel" and req.playerRequest or req
    tab.contentCheckOk = true
    tab.racyCheckOk = true
    tab.videoId = video_id
    tab.playbackContext = { contentPlaybackContext = {html5Preference = "HTML5_PREF_WANTS", signatureTimestamp = 20648} }
    local req_str = utils.format_json(req)
    return req_str
end

function get_innertube_api_headers(extractor)
    local headers = {}
    local innertube_host = "www.youtube.com"
    if extractor.api_route == "reel" then
        innertube_host = "youtubei.googleapis.com"
    end
    table.insert(headers, "Host: "..innertube_host)
    table.insert(headers, "Origin: https://"..innertube_host)
    table.insert(headers, "Content-Type: application/json")
    if extractor.client.userAgent then
        table.insert(headers, "User-Agent: "..extractor.client.userAgent)
    else -- самая последняя версия chrome для windows 7
        table.insert(headers, "User-Agent: Mozilla/5.0 (Windows NT 6.1; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.5414.121 Safari/537.36")
    end
    if extractor.client_id then
        table.insert(headers, "X-Youtube-Client-Name: "..extractor.client_id)
        table.insert(headers, "X-Youtube-Client-Version: "..extractor.client.clientVersion)
    end
    if extractor.visitor_id_required and get_visitor_data() then
        msg.debug("Passing visitor data header according to extractor requirements")
        table.insert(headers, "X-Goog-Visitor-Id: " .. get_visitor_data())
    end
    return headers
end

function try_get(obj, path) -- попытка получения узла в таблице с json
    local node = obj or {}
    for elem in path:gmatch("[^%.]+") do
        local child, idx = elem:match("(.*)%[(%d+)%]$")
        if not child then
            child = elem
        end
        node = node[child]
        if idx and node then
            node = node[tonumber(idx)]
        end
        if not node then return nil end
    end
    return node
end

local NBSP = "\194\160" -- неразрывный пробел
local ZWSP = "\226\128\139" -- пробел нулевой ширины (Гитхабу не нравится, когда в коде невидимые символы записаны напрямую)
function parse_num(str)
    return str and tonumber((str:match("[%d%s"..NBSP.."%.,]+") or ""):gsub("[%s"..NBSP.."%.,]", ""), nil) or nil
end
function clean_str(str) -- удаление из строки невидимых спецсимволов (для сравнения локализованных метаданных с оригинальными)
    return str and str:gsub(ZWSP, ""):gsub("\226\128\170", ""):gsub("\226\128\172", ""):gsub("\226\129\160", "") or nil
end

function report_error(text, is_fatal)
    msg[is_fatal and "fatal" or "error"](text)
    if opts.osd_errors or is_fatal then
        mp.osd_message(text, is_fatal and 10 or 4)
    end
end

function vdata_is_stale(fraction)
    -- по моему опыту visitor data может быть действительна очень долго (у меня до сих пор действует полученная 3 месяца назад),
    -- но на всякий случай пусть будет считаться устаревшей полученная более 6 часов назад (срок действия прямой ссылки на поток)
    return cache.visitor_data == "" and true or (os.time() - cache.timestamp) > 6 * 3600 * (fraction or 1)
end

function update_visitor_data(new_data)
    cache.visitor_data = new_data
    if vdata_is_stale(0.5) and opts.cache_path ~= "" then
        local f = io.open(opts.cache_path, "w") -- путь по умоланию должен быть доступен даже на mpv-android
        if f then
            msg.debug("Updating disk cache")
            cache.timestamp = os.time()
            local cache_json = utils.format_json(cache)
            f:write(cache_json)
            f:close()
        else
            msg.warn("Unable to write to cache file: " .. opts.cache_path)
        end
    elseif opts.cache_path == "" then
        cache.timestamp = os.time()
    end
end

function get_visitor_data()
    if cache.visitor_data ~= "" then
        return cache.visitor_data
    elseif opts.cache_path ~= "" then
        local f = io.open(opts.cache_path, "r")
        if f then
            local cache_str = f:read("*a")
            f:close()
            local cache_json = utils.parse_json(cache_str)
            if cache_json and cache_json.visitor_data then 
                cache = cache_json
                return cache.visitor_data
            end
        end
    end
end

function clear_visitor_data()
    cache.visitor_data = ""
    if opts.cache_path ~= "" then
        os.remove(opts.cache_path)
    end
end

if opts.parse_hls_manifests == "true" then opts.parse_hls_manifests = "yes" end
if opts.parse_hls_manifests == "false" then opts.parse_hls_manifests = "no" end
if opts.skip_vp9 or opts.target_resolution < 1080 or opts.parse_hls_manifests == "no" then
    opts.premium_extractor = ""
end
opts.extractor = opts.extractor:lower()
opts.cache_path = mp.command_native({"expand-path", opts.cache_path})

function sanity_check_extractor(opt, check, msg)
    opts[opt] = opts[opt]:lower()
    if not extractors[opts[opt]] and (opts[opt] ~= "") then
        report_error(string.format("Unknown extractor '%s'!", opts[opt]))
        opts[opt] = ""
    elseif check and opts[opt] ~= "" and not extractors[opts[opt]][check] then
        report_error(string.format("'%s' %s, disabling", opts[opt], msg))
        opts[opt] = ""
    end
end
sanity_check_extractor("premium_extractor", "premium_available", "doesn't return premium format")
sanity_check_extractor("dubbed_tracks_extractor", "dubbed_tracks_available", "doesn't return dubbed tracks")
sanity_check_extractor("yt_kids_extractor", "yt_kids_available", "doesn't support YT Kids videos")


mp.add_hook("on_load", 9, function()
    if opts.extractor == "" or mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result/status") == 0 then return end
    
    local url = mp.get_property("path") or ""
    local url_params = url:match("^https?://[^/]*youtu%.?be[^/]*/(.+)") or ""
    local youtube_id = url:match("://youtu%.be/([%w%-_]+)") or url_params:match("[?&]v=([%w%-_]+)") or url_params:match("^v/([%w%-_]+)")
      or url_params:match("^embed/([%w%-_]+)") or url_params:match("^live/([%w%-_]+)") or url_params:match("^shorts/([%w%-_]+)")
    if youtube_id and #youtube_id == 11 then
        local start_time = mp.get_time()
        local ytdl = {}
        ytdl.formats = {}
        ytdl.subtitles = {}
        ytdl.requested_subtitles = {}
        ytdl.automatic_captions = {}
        ytdl.id = youtube_id
        ytdl.extractor = "youtube"
        if url_params:match("[?&]t=%d+") then
            ytdl.start_time = tonumber(url_params:match("[?&]t=(%d+)"))
        end
        local checked_extractors = {[""] = true} -- если доп. экстрактор (например, для премиум потока) не задан, он всегда будет считаться проверенным
        
        initial_path = url
        if opts.parse_web_player_async then
            storyboard_fmts = {}
            parse_yt(ytdl, youtube_id, "web", checked_extractors, false, populate_with_web_metadata)
        end
        
        local ok -- прошёл ли безошибочно хоть один парсинг
        for extr in opts.extractor:gmatch("[^,%s]+") do
            if not extractors[extr] and extr ~= "default" then
                msg.warn(string.format("Unknown extractor '%s'! Falling back to %s", extr, default_extractor))
            end
            if not extractors[extr] then
                extr = default_extractor
            end
            if not checked_extractors[extr] then
                local success = parse_yt(ytdl, youtube_id, extr, checked_extractors)
                if success == false then return -- nil - ошибка текущего парсинга, false - парсинг не может быть продолжен
                elseif success then ok = true end
            end
        end
        ytdl.requested_formats = ok and select_formats(ytdl.formats)
        if ok and ytdl.requested_formats and #ytdl.requested_formats > 0 then
            if opts.parse_web_player_async then -- временно убираем форматы раскадровки до получения форматов с веб-плеера в более высоком качестве,
                local i = 1                     -- чтобы не запустилась генерация эскизов в низком разрешении (при неудаче изначальные форматы вернутся)
                while ytdl.formats[i] do
                    if ytdl.formats[i].format_note == "storyboard" then
                        table.insert(storyboard_fmts, ytdl.formats[i])
                        table.remove(ytdl.formats, i)
                    else
                        i = i+1
                    end
                end
            end
            local res = {}
            res.status = 0
            res.stdout = utils.format_json(ytdl)
            res.stderr = ""
            mp.set_property_native("user-data/mpv/ytdl/json-subprocess-result", res)
        else
            if ok and ytdl.requested_formats then
                report_error("No playable formats available")
            end
            if opts.parse_web_player_async and interrupt_data then
                mp.abort_async_command(interrupt_data)
            end
        end
        msg.verbose(string.format("Script running time: %.3f seconds", mp.get_time()-start_time))
    end
end)

function parse_yt(ytdl, youtube_id, extractor_name, checks, get_config, async_cb) -- наполняет таблицу ytdl данными
    local start = mp.get_time()
    checks[extractor_name] = true
    
    local vdata_missing = false
    if not get_config and not async_cb and extractors[extractor_name].visitor_id_required and not get_visitor_data() then
        msg.debug("Visitor data is missing, trying to get it from client config")
        local status = parse_yt(ytdl, youtube_id, extractor_name, checks, true)
        if status == false then
            return false
        elseif not status then
            msg.warn("Failed to extract visitor data from client config, continuing without it")
            vdata_missing = true
        end
    end
    
    local args = { opts.curl_path, "--silent", "--show-error", "--request", "POST", "--connect-timeout", "10", "--max-time", "30" }
    local api_headers = get_innertube_api_headers(extractors[extractor_name])
    for _, h in ipairs(api_headers) do
        table.insert(args, "--header")
        table.insert(args, h)
    end
    table.insert(args, "--data")
    table.insert(args, get_innertube_request(extractors[extractor_name], get_config and nil or youtube_id))
    table.insert(args, "--compressed") -- если используемый curl не поддерживает сжатие, оно просто не будет запрашиваться
    
    local ytdl_opts = mp.get_property_native("ytdl-raw-options") or {}
    local http_proxy = mp.get_property("http-proxy")
    local proxy = ytdl.proxy or ytdl_opts.proxy or http_proxy
    if proxy and proxy ~= "" then
        msg.debug("Using proxy: "..proxy)
        table.insert(args, "--proxy")
        table.insert(args, proxy)
        ytdl.proxy = proxy -- ytdl_hook выставит этот прокси для скачивания медиапотоков плеером (хотя yt-dlp почему-то не возвращает это поле в своём json)
    end
    
    table.insert(args, get_innertube_api_route(extractors[extractor_name], get_config))
    
    msg.verbose(string.format("Downloading %s %s%s", extractor_name, get_config and "config" or "player response", async_cb and " (async)" or ""))
    if async_cb then
        interrupt_data = mp.command_native_async({name="subprocess", capture_stdout=true, args=args}, async_cb)
        return true
    end
    local res = mp.command_native({name="subprocess", capture_stdout=true, args=args})    --mp.set_property("clipboard/text", res.stdout)   
    if res.error_string == "init" then
        report_error("curl not found! You can specify its path in youtube-parser's options", true)
        return false
    elseif res.killed_by_us then -- видео закрыто вручную во время парсинга
        return false
    end
    local json = utils.parse_json(res.stdout)
    
    local extr_status = extract_visitor_data(json and (json.responseContext or try_get(json, "playerResponse.responseContext")) or nil)
    if get_config then
        return extr_status
    end
    
    if json and (json.streamingData or (json.playerResponse and json.playerResponse.streamingData)) then
        local response = json.playerResponse or json
        local manifest
        local prem_track, dubs
        local ai_qualities = {}
        local sabr_warned = false
        local streaming_fields = {}
        for key, val in pairs(response.streamingData) do
            if type(val) == "table" then
                table.insert(streaming_fields, string.format("%s(%d)", key, #val))
            else
                table.insert(streaming_fields, key)
            end
        end
        table.sort(streaming_fields)
        msg.debug("Received streaming data: " .. table.concat(streaming_fields, ", "))
        
        if not checks[opts.livestream_extractor] and response.videoDetails and response.videoDetails.isLive then
            ytdl.is_live = true
            msg.info("Trying to get " .. opts.livestream_extractor .. " livestream formats")
            local success = parse_yt(ytdl, youtube_id, opts.livestream_extractor, checks)
            if success ~= nil and not (success and not ytdl.hls_manifest and not ytdl.dash_manifest) then
                return success
            else
                msg.warn("Livestream extractor failed, using initial formats")
            end
        end
        
        if response.playabilityStatus and response.playabilityStatus.paygatedQualitiesMetadata then
            for _, quality in ipairs(response.playabilityStatus.paygatedQualitiesMetadata.qualityDetails or {}) do
                if quality.key then ai_qualities[quality.key] = true end
            end
        end
        if not response.streamingData.adaptiveFormats then response.streamingData.adaptiveFormats = {} end
        for _, form in ipairs(response.streamingData.formats or {}) do
            form.legacy = true
            table.insert(response.streamingData.adaptiveFormats, form) -- для удобства обработки все форматы объединяются в один список
        end
        
        local premium_possible = false -- есть все условия для наличия премиум потока в HLS манифесте
        local no_adaptive = true
        local fhd, vp9, qhd
        for _, form in ipairs(response.streamingData.adaptiveFormats) do
            if form.url and not form.url:find("source=yt_%a+_broadcast") and not extractors[extractor_name].adaptive_formats_unplayable then
                if not form.legacy then
                    no_adaptive = false
                end
                if form.qualityLabel == "1080p" then -- намеренно не включает в себя 60fps форматы: https://github.com/yt-dlp/yt-dlp/issues/16764#issuecomment-4497587022
                    fhd = true
                elseif form.qualityLabel == "1440p" then 
                    qhd = true 
                end
                if (form.height or 0) > 480 and string.match(form.mimeType or "", "vp0?9") then -- премиум поток только в кодеке VP9, значит и ролику нужно быть в нём доступным
                    vp9 = true
                end
            end
        end
        if fhd and vp9 and not qhd and not next(ai_qualities) then
            premium_possible = true
        end
        if response.streamingData.hlsManifestUrl and (opts.parse_hls_manifests == "yes" or no_adaptive or
                (premium_possible and extractors[extractor_name].premium_available)) and opts.parse_hls_manifests ~= "no"
        then
            msg.verbose(string.format("Downloading %s HLS manifest", extractor_name))
            local args = { opts.curl_path, "--silent", "--show-error", "--compressed", "--connect-timeout", "10", "--max-time", "30" }
            if proxy and proxy ~= "" then
                table.insert(args, "--proxy")
                table.insert(args, proxy)
            end
            table.insert(args, response.streamingData.hlsManifestUrl)
            local res = mp.command_native({name="subprocess", capture_stdout=true, args=args})
            if res.stdout:find("^#EXTM3U") then
                manifest = res.stdout
            elseif not res.killed_by_us then
                msg.warn("curl failed when parsing HLS manifest, status=" .. tostring(res.status))
            else
                return false
            end
        end
        
        if manifest then
            local function extract_filesize(url) -- в HLS метаданных содержится завышенный (пиковый?) битрейт, но настоящий можно вычислить из url параметров
                local clen, dur = url:lower():gsub("%%3d", "="):gsub("%%3b", ";"):match("/clen=(%d+);dur=([%d%.]+)")
                if tonumber(clen or "") and (tonumber(dur or "") or 0) > 0 then
                    local true_bitrate = math.floor(tonumber(clen) / tonumber(dur) * 8)
                    return clen, true_bitrate
                end
            end
            
            local next_is_url = false
            for line in manifest:gmatch("[^\r\n]+") do
                if next_is_url then
                    if not line:match("^https?://") then
                        msg.warn("Malformed HLS manifest entry (should be media playlist URL): " .. line)
                        table.remove(response.streamingData.adaptiveFormats, #response.streamingData.adaptiveFormats)
                    else
                        response.streamingData.adaptiveFormats[#response.streamingData.adaptiveFormats].url = line
                        response.streamingData.adaptiveFormats[#response.streamingData.adaptiveFormats].itag = line:match("/itag/(%d+)/")
                        local filesize_str, true_bitrate = extract_filesize(line)
                        if filesize_str and true_bitrate then
                            response.streamingData.adaptiveFormats[#response.streamingData.adaptiveFormats].contentLength = filesize_str
                            response.streamingData.adaptiveFormats[#response.streamingData.adaptiveFormats].averageBitrate = true_bitrate
                        end
                    end
                    next_is_url = false
                else
                    local url, itag, width, height, fps, mime, is_ext_audio, is_hdr_fmt, name, lang, bitrate
                    -- пропускаем субтитры по протоколу HLS - даже iOS предоставляет воспроизводимые субтитры по прямой ссылке
                    if line:match("^#EXT%-X%-MEDIA") and line:find("TYPE=AUDIO") then
                        url = line:match('URI="([^"]+)')
                        itag = line:match('/itag/(%d+)/')
                        name = line:match('NAME="([^"]+)')
                        is_ext_audio = line:match("TYPE=AUDIO")
                        lang = line:match('LANGUAGE="([^"]+)')
                    elseif line:match("#EXT%-X%-STREAM%-INF") then
                        next_is_url = true
                        local resolution = line:match("RESOLUTION=(%w+)")
                        if resolution then
                            width = resolution:match("(%d+)x")
                            height = resolution:match("x(%d+)")
                        end
                        fps = line:match("FRAME%-RATE=(%d+)")
                        bitrate = line:match("BANDWIDTH=(%d+)")
                        mime = line:match('CODECS="[^"]+"')
                        is_hdr_fmt = line:match('VIDEO%-RANGE=PQ')
                    end
                    if itag == "234" and not bitrate then -- эквивалент формата 140 в DASH, то есть AAC (mp4a) ~128 кбит/с
                        bitrate = "128000"
                        mime = 'codecs="mp4a"'
                    elseif itag == "233" and not bitrate then
                        bitrate = "48000"
                        mime = 'codecs="mp4a"'
                    end
                    local filesize_str, true_bitrate = extract_filesize(url or "")
                    if true_bitrate then
                        bitrate = true_bitrate
                    end
                    if url or next_is_url then
                        table.insert(response.streamingData.adaptiveFormats, {
                            hls = true,
                            isHdr = is_hdr_fmt ~= nil,
                            qualityLabel = name,
                            url = url,
                            itag = itag,
                            width = tonumber(width),
                            height = tonumber(height),
                            fps = tonumber(fps),
                            mimeType = mime and mime:lower() or nil,
                            averageBitrate = tonumber(bitrate),
                            contentLength = filesize_str,
                            audioQuality = is_ext_audio and (itag == "234" and "medium" or "low") or nil,
                            language = lang and (lang .. (name and name:find("-auto") and "-auto" or "")) or nil
                        })
                    end
                end
            end
        end
        local function is_premium(itag)
            if itag == "616" or itag == "235" then return true end
        end
        local function is_hdr(form)
            if try_get(form, "colorInfo.primaries") == "COLOR_PRIMARIES_BT2020" or form.isHdr or string.find(form.qualityLabel or "", "HDR") then return true end
        end
        local function calc_format_preference(form) -- быть может, есть способ надёжнее, но yt-dlp тоже использует подобную логику с source_preference
            if opts.skip_ai_upscale and form.qualityLabel and ai_qualities[form.qualityLabel] then return -1 end
            if opts.skip_ai_dub and (form.audioTrack and form.audioTrack.isAutoDubbed) or string.find(form.qualityLabel or "", "dubbed%-auto") then return -1 end
            if opts.skip_hdr and is_hdr(form) then return -1 end
            if is_premium(tostring(form.itag)) then return 10^6 end
            local q = 1
            local mime = form.mimeType and form.mimeType:lower() or ""
            local aquality = form.audioQuality and form.audioQuality:lower() or ""
            
            -- для видеопотоков (основная сортировка по разрешению и fps)
            if is_hdr(form) then
                q = q + 100
            end
            if mime:match("av0?1") and not opts.skip_av1 then
                q = q + 3
            elseif mime:match("vp0?9") and not opts.skip_vp9 then
                q = q + 2
            elseif mime:find("avc1") then
                q = q + 1
            end
            local vtrack_considered = q > 1
            
            -- для аудиопотоков
            if opts.translation_lang ~= "" and form.language and form.language:find("^"..opts.translation_lang) then -- название языка уже прошло обработку
                q = q + 1000
            end
            if not vtrack_considered then
                if aquality:find("high") then
                    q = q + 300
                elseif aquality:find("medium") then
                    q = q + 200
                elseif aquality:find("low") then
                    q = q + 100
                end
                if form.isDrc then
                    if opts.prefer_drc then q = q + 20 else q = q - 5 end
                end
                if (form.audioTrack and form.audioTrack.audioIsDefault) -- дорожка помечена Ютубом как выбранная по умоланию (оригинальная?)
                        or (form.qualityLabel and form.qualityLabel:lower():find("original")) 
                    then q = q + 10 end
                if mime:find("opus") then
                    q = q + 2
                elseif mime:find("mp4a") or mime:find("aac") then
                    q = q + 1
                end
            end
            
            if not form.hls then q = q + 0.1 end
            return q
        end
        
        for i, form in ipairs(response.streamingData.adaptiveFormats) do
            local itag = form.itag and tostring(form.itag) or "unknown-"..i
            form.language = form.language or (form.audioTrack and form.audioTrack.id and form.audioTrack.id:match("^[^%.]+"))
            itag = itag .. (form.language and ("-"..form.language) or "") .. (form.isDrc and "-drc" or "")
            
            local duplicate = false
            for _, existed in ipairs(ytdl.formats) do
                if existed.format_id == itag then duplicate = true end
            end
            if form.url and not form.url:find("source=yt_%a+_broadcast") and not duplicate 
                    and (not extractors[extractor_name].adaptive_formats_unplayable or form.hls or form.legacy) 
            then
                local mime = form.mimeType or ""
                local is_video = mime:match("^video") or form.fps or form.height -- может также содержать аудиодорожку
                local is_audio = (mime:match("^audio") or form.audioQuality) and not is_video
                local is_both = is_video and form.audioQuality
                local codec = mime:match('codecs="([^"]+)"')
                local vcodec, acodec = mime:match('codecs="([^",]+), *([^"]+)"')
                if is_premium(itag) then
                    form.qualityLabel = form.qualityLabel and (form.qualityLabel .. " Premium") or "Premium"
                end
                if form.audioTrack then
                    if form.language and (not form.language:find("^"..opts.translation_lang) or opts.translation_lang == "") then
                        dubs = true        -- если оригинал уже на желаемом языке, незачем получать дубляжи
                    end
                    if form.audioTrack.displayName then
                        form.qualityLabel = form.qualityLabel and (form.qualityLabel .. ", " .. form.audioTrack.displayName) or form.audioTrack.displayName
                    end
                    if form.audioTrack.isAutoDubbed then
                        form.language = form.language and (form.language .. "-auto") or "auto"
                        form.qualityLabel = form.qualityLabel and (form.qualityLabel .. " (AI-dub)") or "AI-dub"
                    end
                end
                if form.isDrc then
                    form.qualityLabel = form.qualityLabel and (form.qualityLabel .. " (Stable Volume)") or "Stable Volume"
                elseif not form.qualityLabel and is_audio then
                    form.qualityLabel = "Original"
                end
                table.insert(ytdl.formats, {
                    url = form.url,
                    manifest_url = form.hls and response.streamingData.hlsManifestUrl or nil,
                    width = form.width,
                    height = form.height,
                    fps = form.fps,
                    dynamic_range = is_hdr(form) and "HDR" or nil,
                    quality = calc_format_preference(form),
                    format_note = form.qualityLabel and (form.qualityLabel .. (ai_qualities[form.qualityLabel] and " (AI-upscale)" or "")) or nil,
                    resolution = (form.width and form.height) and form.width.."x"..form.height,
                    filesize = form.contentLength and tonumber(form.contentLength),
                    format_id = itag,
                    ext = mime:match("/(%w+)"),
                    video_ext = is_video and mime:match("/(%w+)") or nil,
                    audio_ext = is_audio and mime:match("/(%w+)") or nil,
                    vcodec = is_audio and "none" or vcodec or (is_video and codec or nil),
                    acodec = (not is_audio and not is_both and (acodec and nil or "none")) or acodec or (is_audio and codec or nil),
                    protocol = form.hls and "m3u8" or "https",
                    tbr = form.averageBitrate and form.averageBitrate / 1000 or nil, -- yt-dlp пишет битрейт в кбит/с
                    asr = form.audioSampleRate and tonumber(form.audioSampleRate),
                    audio_channels = form.audioChannels,
                    language = form.language,
                    downloader_options = (not form.legacy and not form.hls) and { http_chunk_size = 10 * 2^20 } or nil,
                    
                    projection_type = (is_video and form.projectionType and form.projectionType ~= "RECTANGULAR") and form.projectionType:lower() or nil,
                    byte_ranges = (form.initRange and form.indexRange) and {
                        init_start = tonumber(form.initRange["start"] or ""),
                        init_end = tonumber(form.initRange["end"] or ""),
                        index_start = tonumber(form.indexRange["start"] or ""),
                        index_end = tonumber(form.indexRange["end"] or ""),
                    } or nil
                })
            elseif not form.url and not extractors[extractor_name].sabr_expected and not sabr_warned then
                msg.warn("YouTube may have enabled the SABR-only streaming experiment for " .. extractor_name)
                sabr_warned = true
            end
        end
        
        local duration = response.videoDetails and response.videoDetails.lengthSeconds and tonumber(response.videoDetails.lengthSeconds)
        if duration and response.storyboards and response.storyboards.playerStoryboardSpecRenderer and response.storyboards.playerStoryboardSpecRenderer.spec then
            add_storyboard_formats(ytdl, response.storyboards.playerStoryboardSpecRenderer.spec, duration)
        end
        
        if response.captions and response.captions.playerCaptionsTracklistRenderer then
            -- в отличие от yt-dlp, который переводит лишь с автоматических субтитров, пробуем сначала вручную добавленные на языке оригинала,
            -- затем вручную добавленные английские, после любые другие ручные, и лишь, если таковых нет, берём за основу автоматические
            local src_lang, src_fmt, orig_lang
            local function poison_lang_code(code)
                if opts.auto_subs_action == "deselect" or opts.auto_subs_action:find("skip") then
                    code = code:gsub("%w", ZWSP.."%0") -- помещаем невидимый пробел между буквами языка субтитров, чтобы предотвратить их авто-выбор плеером
                end
                return code
            end
            local function add_autotranslated_subs(lang_code, lang_name)
                local auto_subs = {
                    url = src_fmt.url .. "&tlang=" .. lang_code,
                    ext = opts.sub_format,
                    name = string.format("%s (%s %s)", lang_name or lang_code:upper(),
                            opts.metadata_lang == "ru" and "автоперевод с" or "translated from", src_fmt.name or src_lang),
                    impersonate = true
                }
                ytdl.automatic_captions[lang_code] = { auto_subs }
                
                if lang_code == opts.translation_lang and not ytdl.requested_subtitles[opts.translation_lang] then
                    ytdl.requested_subtitles[poison_lang_code(lang_code) .. "-autotr"] = auto_subs
                end
            end
            
            for _, subs in ipairs(response.captions.playerCaptionsTracklistRenderer.captionTracks or {}) do
                if subs.baseUrl and subs.languageCode and opts.sub_format ~= "" then
                    local subs_url = subs.baseUrl:gsub("&fmt=%w+", "&fmt="..opts.sub_format):gsub("&xosf=1", "")
                    if not subs_url:find("fmt=") then
                        subs_url = subs_url .. "&fmt="..opts.sub_format
                    end
                    local subs_track = {
                        url = subs_url,
                        ext = opts.sub_format,
                        name = subs.name and subs.name.runs and subs.name.runs[1] and subs.name.runs[1].text,
                        translatable = subs.isTranslatable
                    }
                    if subs.kind ~= "asr" then
                        ytdl.subtitles[subs.languageCode] = { subs_track }
                        ytdl.requested_subtitles[subs.languageCode] = subs_track
                        if (subs.languageCode:match("^en") or not src_lang) and subs.isTranslatable then
                            src_lang = subs.languageCode
                            src_fmt = subs_track
                        end
                    else
                        ytdl.automatic_captions[subs.languageCode] = { subs_track }
                        if opts.auto_subs_action ~= "skip" then
                            ytdl.requested_subtitles[poison_lang_code(subs.languageCode) .. "-auto"] = subs_track
                        end
                        orig_lang = subs.languageCode -- полагая, что авто-субтитры всегда делаются с языка оригинала ролика
                    end
                end
            end
            if orig_lang and ytdl.subtitles[orig_lang] then
                src_lang = orig_lang
                src_fmt = ytdl.subtitles[orig_lang][1]
            elseif not src_lang and next(ytdl.automatic_captions) and next(ytdl.automatic_captions) ~= opts.translation_lang
                    and ytdl.automatic_captions[next(ytdl.automatic_captions)][1].translatable then
                src_lang = next(ytdl.automatic_captions)
                src_fmt = ytdl.automatic_captions[src_lang][1]
            end

            if not opts.auto_subs_action:find("skip") and src_lang and opts.translation_lang ~= "" then
                -- названия языков для перевода могут быть недоступны (например, если в языковой паре нет английского), поэтому полагаться на их наличие нельзя
                for _, tlang in ipairs(response.captions.playerCaptionsTracklistRenderer.translationLanguages or {}) do
                    if tlang.languageCode and src_lang ~= tlang.languageCode and not ytdl.subtitles[tlang.languageCode] then
                        add_autotranslated_subs(tlang.languageCode, try_get(tlang, "languageName.runs[1].text"))
                    end
                end
                if not ytdl.automatic_captions[opts.translation_lang] and not ytdl.requested_subtitles[opts.translation_lang] then
                    add_autotranslated_subs(opts.translation_lang)
                end
            end
        end
        
        local meta = response.videoDetails or {}
        ytdl.title = ytdl.title or meta.title or ("YT video " .. youtube_id)
        ytdl.description = ytdl.description or clean_str(meta.shortDescription)
        ytdl.tags = ytdl.tags or meta.keywords
        ytdl.duration = ytdl.duration or duration
        ytdl.uploader = ytdl.uploader or meta.author
        ytdl.view_count = ytdl.view_count or (meta.viewCount and tonumber(meta.viewCount))
        ytdl.channel_id = ytdl.channel_id or meta.channelId
        ytdl.channel_url = ytdl.channel_url or (meta.channelId and ("https://www.youtube.com/channel/" .. meta.channelId))
        if ytdl.description and not ytdl.chapters then
            ytdl.chapters = chapters_from_description(ytdl.description, ytdl.duration)
        end
        if meta.allowRatings == false then
            ytdl.like_count = 0
        end
        if meta.thumbnail and meta.thumbnail.thumbnails and not ytdl.thumbnail then
            table.sort(meta.thumbnail.thumbnails, function(a, b) -- по возрастанию, как у yt-dlp
                if a.height and b.height then
                    return a.height < b.height
                end
            end)
            local i = 1
            while meta.thumbnail.thumbnails[i] do
                meta.thumbnail.thumbnails[i].preference = i
                if meta.thumbnail.thumbnails[i].url then
                    if meta.thumbnail.thumbnails[i].url:find("/vi_webp/") then -- все превью также продублированы в jpeg
                        table.insert(meta.thumbnail.thumbnails, i+1, {
                            url = meta.thumbnail.thumbnails[i].url:gsub("_webp", ""):gsub("%.webp$", ".jpg"),
                            width = meta.thumbnail.thumbnails[i].width,
                            height = meta.thumbnail.thumbnails[i].height,
                            preference = i+1
                        })
                        i = i + 2
                    else
                        i = i + 1
                    end
                else
                    table.remove(meta.thumbnail.thumbnails, i)
                end
            end
            ytdl.thumbnails = meta.thumbnail.thumbnails
            ytdl.thumbnail = #ytdl.thumbnails > 0 and ytdl.thumbnails[#ytdl.thumbnails].url or nil
        end
        if not ytdl.thumbnail then
            ytdl.thumbnail = "https://i.ytimg.com/vi/" .. youtube_id .. "/hqdefault.jpg"
            ytdl.thumbnails = {url = ytdl.thumbnail}
        end
        ytdl.webpage_url = "https://www.youtube.com/watch?v=" .. youtube_id
        
        ytdl.hls_manifest = response.streamingData.hlsManifestUrl
        -- .mpd манифест прямой трансляции, который может быть воспроизведён (очень ненадёжно) лишь будучи открытым напрямую mpv с включённым libxml2
        ytdl.dash_manifest = response.streamingData.dashManifestUrl
        
        if meta.isLive then
            ytdl.is_live = true
        elseif meta.isLiveContent then
            ytdl.was_live = true
        end
        
        if meta.isPrivate then
            ytdl.availability = "private"
        elseif meta.isCrawlable == false then
            ytdl.availability = "unlisted"
        elseif meta.isCrawlable then
            ytdl.availability = "public"
        end
        
        if response.microformat and response.microformat.playerMicroformatRenderer then
            parse_microformat(ytdl, response.microformat.playerMicroformatRenderer)
        end
        
        if json.overlay then -- доп. метаданные доступны только для Reel экстракторов
            local overlay_data = json.overlay.reelPlayerOverlayRenderer or {}
            local likes_str = try_get(overlay_data, "doubleTapLikeButton.likeButtonRenderer.likeCountWithLikeText.accessibility.accessibilityData.label")
            if likes_str and not ytdl.like_count then -- содержит точное число лайков (с учётом лайка пользователя), в виде строки
                ytdl.like_count = parse_num(likes_str)
                if ytdl.like_count then
                    ytdl.like_count = math.max(ytdl.like_count - 1, 0) 
                end
            elseif try_get(overlay_data, "likeButton.likeButtonRenderer.likeCount") then
                ytdl.like_count = overlay_data.likeButton.likeButtonRenderer.likeCount
            end
            local viewmodel_path = "elementRenderer.newElement.type.componentType.model.youtubeModel.viewModel"
            local models = try_get(overlay_data, "buttonBar."..viewmodel_path..".reelActionBarViewModel.buttonViewModels")
                    or try_get(overlay_data, "playerOverlay."..viewmodel_path..".reelPlayerOverlayViewModel.actionBar.reelActionBarViewModel.buttonViewModels")
            for _, model in ipairs(models or {}) do
                if model.buttonViewModel and model.buttonViewModel.accessibilityText and not ytdl.comment_count then -- опять же, число точное
                    ytdl.comment_count = parse_num(model.buttonViewModel.accessibilityText)
                    if not ytdl.comment_count and model.buttonViewModel.title and model.buttonViewModel.title:match("^%d+$") then
                        ytdl.comment_count = tonumber(model.buttonViewModel.title)
                    end
                end
            end
            if not ytdl.comment_count and string.match(try_get(overlay_data, "viewCommentsButton.buttonRenderer.text.runs[1].text") or "", "^%d+$") then
                ytdl.comment_count = tonumber(overlay_data.viewCommentsButton.buttonRenderer.text.runs[1].text)
            elseif not ytdl.comment_count and try_get(overlay_data, "viewCommentsButton.buttonRenderer.accessibility.label") then
                ytdl.comment_count = parse_num(overlay_data.viewCommentsButton.buttonRenderer.accessibility.label)
            end
            local items = try_get(overlay_data, "metapanel."..viewmodel_path..".reelMetapanelViewModel.metadataItems")
                    or try_get(overlay_data, "playerOverlay."..viewmodel_path..".reelPlayerOverlayViewModel.metapanel.reelMetapanelViewModel.metadataItems")
            for _, item in ipairs(items or {}) do
                local localized_title = clean_str(try_get(item, "shortsVideoTitleViewModel.text.content")) or ""
                if localized_title ~= "" and ytdl.title ~= localized_title then
                    ytdl.alt_title = ytdl.title
                    ytdl.title = localized_title
                end
            end
        end
        
        local contents = try_get(json, "engagementPanels[1].engagementPanelSectionListRenderer.content.sectionListRenderer.contents")
        for _, content in ipairs(contents or {}) do
            local element = try_get(content, "itemSectionRenderer.contents[1].elementRenderer.newElement.type.componentType.model") or {}
            if element.videoDescriptionHeaderModel then
                local localized_title = clean_str(try_get(element.videoDescriptionHeaderModel, "videoDescriptionHeader.videoTitle.content")) or ""
                if localized_title ~= "" and ytdl.title ~= localized_title then
                    ytdl.alt_title = ytdl.title
                    ytdl.title = localized_title
                end
                local date_str = try_get(element.videoDescriptionHeaderModel, "videoDescriptionHeader.dateText")
                if date_str then -- yt-dlp возвращает дату лишь в формате YYYYMMDD, но для отображения в интерфейсе годится дата и в человекочитаемом формате
                    ytdl.upload_date_text = date_str:gsub("Published on ", ""):gsub("Дата публикации: ", "")
                end
            elseif element.descriptionBodyModel then
                local localized_description = clean_str(try_get(element.descriptionBodyModel, "renderer.descriptionBodyText.elementsAttributedString.content")) or ""
                if localized_description ~= "" and ytdl.description ~= localized_description then
                    ytdl.alt_description = ytdl.description -- у yt-dlp нет такого поля, но оригинальное описание тоже может быть полезно
                    ytdl.description = localized_description
                end
            elseif not ytdl.alt_description and try_get(content, "slimVideoMetadataSectionRenderer.contents[1].slimVideoDescriptionRenderer.description.runs") then
                local desc_frags = {}
                for _, frag in ipairs(content.slimVideoMetadataSectionRenderer.contents[1].slimVideoDescriptionRenderer.description.runs) do
                    if frag.text then table.insert(desc_frags, frag.text) end
                end
                local localized_description = clean_str(table.concat(desc_frags, ""))
                if localized_description ~= "" and ytdl.description ~= localized_description then
                    ytdl.alt_description = ytdl.description
                    ytdl.description = localized_description
                end
            elseif element.youtubeModel and not ytdl.ai_content_warning then
                local origin_info = try_get(element.youtubeModel, "viewModel.howThisWasMadeSectionViewModel")
                -- плашка от Ютуба о том, что видео сделано с помощью ИИ (или же о наличии ИИ-озвучек, которые скрипт, в отличие от Ютуба, по умолчанию не выбирает)
                -- в любом случае, очень полезная информация, если видео до этого не открывалось в браузере (увы, присутствует далеко не на всех подобных роликах)
                if origin_info then
                    local header = try_get(origin_info, "bodyHeader.content")
                    local text = try_get(origin_info, "bodyText.content")
                    local support_url = try_get(origin_info, "bodyText.commandRuns[1].onTap.innertubeCommand.urlEndpoint.url")
                    if header then
                        local str = header
                        if text then
                            text = text:gsub("%.?%s*Learn more$", ""):gsub("%.?%s*Подробнее$", "")
                            str = str .. " (" .. text .. ")"
                        end
                        if support_url and support_url:find("/answer/15447836") then -- сообщение именно о контенте, сгенерированном ИИ
                            ytdl.ai_content_warning = str -- yt-dlp не имеет ни одного близкого по смыслу поля, поэтому имеющиеся скрипты никак им не воспользуются
                            msg.warn(str) -- так что считаю нужным вывести об этом предупреждение
                            if opts.osd_errors then
                                mp.osd_message(str, 4)
                            end
                        end
                    end
                end
            end
        end
        
        msg.info(string.format("Parsing as %s succeeded (took %.3f s, response length: %d%s)", extractor_name,
                mp.get_time() - start, #res.stdout, manifest and (" + " .. #manifest) or ""))
        
        if not checks[opts.premium_extractor] and not manifest and not extractors[extractor_name].premium_available and premium_possible then
            msg.info("Trying to get " .. opts.premium_extractor .. " premium quality format")
            return parse_yt(ytdl, youtube_id, opts.premium_extractor, checks) ~= false
        elseif not checks[opts.dubbed_tracks_extractor] and not extractors[extractor_name].dubbed_tracks_available and dubs then
            msg.info("Trying to get " .. opts.dubbed_tracks_extractor .. " dubbed audio tracks")
            return parse_yt(ytdl, youtube_id, opts.dubbed_tracks_extractor, checks) ~= false
        end
        
        return true
    elseif json and (json.playabilityStatus or (json.playerResponse and json.playerResponse.playabilityStatus)) then
        local status = (json.playerResponse or json).playabilityStatus.status or "(unknown)"
        local reason = (json.playerResponse or json).playabilityStatus.reason
        local err = reason and string.format("Youtube said: %s (status: %s)", reason, status) or "unknown error received from Youtube"
        if reason and (reason:match("Оно содержит материалы партн") 
                or reason:match("This video contains content from")
                or reason:match("Владелец видео запретил .* в вашей стране")
                or reason:match("The uploader has not made .* in your country")
                or reason:match("контент[^,]*, на который заявил[^ ]* права")
                or reason:match("[ti][hn][es] claimed content [bf][yr]")
                or reason:match("заблокирован в.* вашей стран")
                or reason:match("not available on this country"))
        then
            if opts.geoblock_proxy ~= "" and proxy ~= opts.geoblock_proxy then
                msg.warn(string.format("Attempt failed after %.3f s, %s", mp.get_time() - start, err))
                msg.info("Retrying with geoblock proxy")
                ytdl.proxy = opts.geoblock_proxy
                if opts.parse_web_player_async and interrupt_data then -- в этом случае парсинг веб плеера также не удастся, поэтому также перезапускаем его с прокси
                    msg.verbose("Restarting async sub-parsing with proxy")
                    mp.abort_async_command(interrupt_data)
                    parse_yt(ytdl, youtube_id, "web", checks, false, populate_with_web_metadata)
                    fallback_running = true
                end
                return parse_yt(ytdl, youtube_id, extractor_name, checks)
            end
        elseif status == "UNPLAYABLE" and not extractors[extractor_name].yt_kids_available and not checks[opts.yt_kids_extractor] then
            -- могут быть ложные срабатывания, однако при открытии YT Kids видео VR клиентом возвращается лишь расплывчатое "Видео недоступно."
            msg.warn(string.format("Attempt failed after %.3f s, %s", mp.get_time() - start, err))
            msg.info("Trying " .. opts.yt_kids_extractor .. " extractor fallback")
            return parse_yt(ytdl, youtube_id, opts.yt_kids_extractor, checks)
        elseif status == "LOGIN_REQUIRED" and vdata_missing and not vdata_is_stale() then
            -- не получилось извлечь visitorData из конфига, получена ожидаемая ошибка, зато удалось извлечь прямо из текущего ответа,
            -- а значит можно попробовать повторить парсинг уже с требуемым заголовком
            msg.warn(string.format("Attempt failed after %.3f s, %s", mp.get_time() - start, err))
            msg.info("Trying again with received visitor data")
            return parse_yt(ytdl, youtube_id, extractor_name, checks)
        elseif status == "LOGIN_REQUIRED" then -- не исключено, что, ошибка из-за того, что visitorData больше недействительна
            clear_visitor_data()               -- на всякий случай, лучше сбросить её, чтобы получить новую при следующей попытке
        end
        
        if #ytdl.formats > 0 or ytdl.is_live then -- дополнительный парсинг (например, для получения премиум потока)
            msg.warn(string.format("Sub-parsing as %s failed after %.3f s, %s", extractor_name, mp.get_time() - start, err))
        else
            report_error("Parsing failed, " .. err)
        end
    elseif json then
        report_error("Youtube parsing failed, unable to recognize json, response length: " .. #res.stdout)
    elseif res.status == 0 and not json then
        report_error("Youtube parsing failed, json string unparsable, response length: " .. #res.stdout)
    else
        report_error("Youtube parsing failed, curl finished with error code " .. tostring(res.status))
    end
    
    msg.debug("Innertube response: " .. (#res.stdout > 0 and res.stdout or "(nil)")) -- выведется только при ошибке парсинга
end

function add_storyboard_formats(ytdl, sb_spec, duration)
    local function split(s, sep)
        local res = {}
        for token in s:gmatch("([^" .. (sep or "%s") .. "]+)") do
            table.insert(res, token)
        end
        return res
    end

    local spec = split(sb_spec, '|')
    for i = 1, math.floor(#spec / 2) do
        spec[i], spec[#spec - i + 1] = spec[#spec - i + 1], spec[i]
    end

    local base_url = spec[#spec]
    for i = 1, #spec - 1 do
        local args = split(spec[i], '#')
        local counts = {}
        for j = 1, math.min(5, #args) do
            counts[j] = tonumber(args[j])
        end
        
        -- в yt-dlp раскадровка с лучшим качеством всегда называется sb0, поэтому подход к дедупликации должен быть особенным:
        -- если у текущей раскадровки есть разрешение лучше, чем у имевшейся, придётся удалить все прошлые раскадровки для требуемой маркировки
        -- иначе же можно оставить всё как есть
        if i == 1 and counts[1] and counts[2] then
            for _, existed in ipairs(ytdl.formats) do
                if existed.format_id == "sb0" then
                    if (existed.width or 0) >= counts[1] and (existed.height or 0) >= counts[2] then
                        return
                    else
                        local n = 1
                        while ytdl.formats[n] do
                            if ytdl.formats[n].format_note == "storyboard" then
                                table.remove(ytdl.formats, n)
                            else n = n + 1 end
                        end
                    end
                    break
                end
            end
        end
        
        if #args ~= 8 or not (counts[1] and counts[2] and counts[3] and counts[4] and counts[5]) then
            msg.warn(string.format("Malformed storyboard %d: %s", i, table.concat(args, '#')))
        elseif not duplicate then
            local width, height, frame_count, cols, rows = counts[1], counts[2], counts[3], counts[4], counts[5]
            local N, sigh = args[7], args[8]
            
            local url = base_url:gsub("$L", tostring(#spec - 1 - i)):gsub("$N", N) .. "&sigh=" .. sigh
            local fragment_count = frame_count / (cols * rows)
            local fragment_duration = duration / fragment_count
            local fragments = {}
            for j = 0, math.ceil(fragment_count) - 1 do
                local remaining = duration - (j * fragment_duration)
                if remaining < fragment_duration then fragment_duration = remaining end
                table.insert(fragments, { url = url:gsub("$M", tostring(j)), duration = fragment_duration })
            end

            table.insert(ytdl.formats, 1, {
                format_id = "sb"..(i-1),
                format_note = "storyboard",
                ext = "mhtml",
                protocol = "mhtml",
                acodec = "none",
                vcodec = "none",
                url = url,
                width = width,
                height = height,
                fps = frame_count / duration,
                rows = rows,
                columns = cols,
                fragments = fragments,
            })
        end
    end
end

function parse_microformat(ytdl, microformat)
    if try_get(microformat, "thumbnail.thumbnails[1].url") then -- содержит превью в лучшем доступном разрешении
        if not ytdl.thumbnail or (ytdl.thumbnail.height or 0) < (microformat.thumbnail.thumbnails[1].height or 0) then
            table.insert(ytdl.thumbnails, microformat.thumbnail.thumbnails[1])
            ytdl.thumbnails[#ytdl.thumbnails].preference = #ytdl.thumbnails
            ytdl.thumbnail = microformat.thumbnail.thumbnails[1].url
        end
    end
    ytdl.uploader_url =  microformat.ownerProfileUrl or ytdl.uploader_url 
    if microformat.availableCountries and #microformat.availableCountries < 249 then -- если видео доступно в 249 странах, значит у него нет региональных ограничений
        ytdl.allowed_regions = microformat.availableCountries
    end
    if microformat.category then
        ytdl.categories = { microformat.category }
    end
    if microformat.publishDate then
        local yyyy, mm, dd = microformat.publishDate:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
        if yyyy then
            ytdl.upload_date = yyyy..mm..dd
        end
    end
    if microformat.liveBroadcastDetails and microformat.liveBroadcastDetails.startTimestamp then
        if microformat.liveBroadcastDetails.isLiveNow then
            ytdl.is_live = true
        else
            ytdl.was_live = true
        end
    end
    ytdl.like_count = tonumber(microformat.likeCount or "") or ytdl.like_count
    ytdl.webpage_url = microformat.canonicalUrl or ytdl.webpage_url
end

function chapters_from_description(text, video_dur)
    local function parse_time(timetext)
        if timetext and timetext:match("^%d+:%d%d:%d%d") then
            local h, m, s = timetext:match("^(%d+):(%d%d):(%d%d)")
            return h * 3600 + m * 60 + s
        elseif timetext and timetext:match("^%d+:%d%d") then
            local m, s = timetext:match("^(%d+):(%d%d)")
            return m * 60 + s
        end
    end

    local chaplist = {}
    local last_timestamp = -1 -- таймкоды должны идти строго по возрастанию
    local video_duration = video_dur or 10^9
    local lpunct = "%-=:;/|~%(%[{<" -- отсекаемые слева спецсимволы (должны занимать 1 байт, чтобы не было ложных срабатываний)
    local rpunct = "%-=:;/|~%)%]}>"
    for raw_line in text:gmatch("[^\r\n]+") do
        local line = raw_line:gsub("^%p*%d+[%.%)%]]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line:match("^[%s%p]*%d+:%d%d[%s%p]") or line:match("^[%s%p]*%d+:%d%d$") then
            local timestamp_str, rest = line:match("^[%s%p]*(%d+:%d%d:?%d?%d?)[%s"..rpunct.."]*(.*)") -- исключаем таймкод из названия чаптера
            local timestamp = parse_time(timestamp_str)
            if timestamp and timestamp > last_timestamp and timestamp <= video_duration then
                rest = rest:gsub("^%d+:%d%d:?%d?%d?[%s"..rpunct.."]*", ""):gsub("^—%s*", ""):gsub("^–%s*", "") -- иногда пишут не только время начала, но и время окончания эпизода
                table.insert(chaplist, { ["start_time"] = timestamp, ["title"] = (rest == "" and line or rest) })
                last_timestamp = timestamp
            end
        elseif line:match("[%s%p]%d+:%d%d[%s%p]") or line:match("[%s%p]%d+:%d%d$") then
            -- даже если таймкод не в начале строки, всё равно добавляем его, беря в название чаптера строку целиком
            local timestamp_str = line:match("[%s%p]+(%d+:%d%d:?%d?%d?)")
            local timestamp = parse_time(timestamp_str)
            if timestamp and timestamp > last_timestamp and timestamp <= video_duration then
                -- если таймкод в самом конце строки, его можно спокойно убрать
                line = line:gsub("[%s"..lpunct.."]*"..timestamp_str.."[%s%p]*%d+:%d%d:?%d?%d?[%s%p]*$", ""):gsub("[%s"..lpunct.."]*"..timestamp_str.."[%s%p]*$", "")
                table.insert(chaplist, { ["start_time"] = timestamp, ["title"] = line })
                last_timestamp = timestamp
            end
        end
    end
    if #chaplist >= 3 then
        for i, chap in ipairs(chaplist) do
            chap.end_time = chaplist[i+1] and chaplist[i+1].start_time or video_duration
        end
        return chaplist
    end
    return {}
end

function extract_visitor_data(context)
    if context and context.visitorData then
        msg.debug("Found visitor data in responseContext")
        update_visitor_data(context.visitorData)
        return true
    elseif context and try_get(context, "serviceTrackingParams[1].params") then
        for _, field in ipairs(context.serviceTrackingParams[1].params) do
            if field.key == "visitor_data" and field.value then
                msg.debug("Found visitor data in serviceTrackingParams")
                update_visitor_data(field.value)
                return true
            end
        end
    end
end


function select_formats(formats)
    table.sort(formats, function(a, b) -- сортировка от худшего к лучшему, как у yt-dlp
        if (a.height or 0) ~= (b.height or 0) then
            return (a.height or 0) < (b.height or 0)
        elseif (a.width or 0) ~= (b.width or 0) then
            return (a.width or 0) < (b.width or 0)
        elseif (a.fps and math.floor(a.fps+0.5) or 0) ~= (b.fps and math.floor(b.fps+0.5) or 0) then
            return (a.fps and math.floor(a.fps+0.5) or 0) < (b.fps and math.floor(b.fps+0.5) or 0)
        elseif (a.quality or -1) ~= (b.quality or -1) then
            return (a.quality or -1) < (b.quality or -1)
        elseif (a.tbr or 0) ~= (b.tbr or 0) then
            return (a.tbr or 0) < (b.tbr or 0)
        end
    end)
    
    local req_fmts = {}
    local forced_formats = mp.get_property("ytdl-format") or ""
    if forced_formats:match("^%d[%w%-%+]*$") or forced_formats:match("^unknown%-[%w%-%+]*$") then
        local vtrack, atrack = forced_formats:match("^([%w%-]+)%+([%w%-]+)")
        if not vtrack then
            vtrack = forced_formats:match("^[%w%-]+")
        end
        for _, form in ipairs(formats) do
            if form.format_id == vtrack or form.format_id == atrack then
                table.insert(req_fmts, form)
            end
        end
        if #req_fmts == 0 or (atrack and #req_fmts == 1) then
            report_error("Requested format " .. forced_formats .. " is not available!")
            return
        else
            msg.verbose("Selecting format " .. forced_formats)
        end
    else
        local vtrack, atrack
        for i = #formats, 1, -1 do -- *** подумать над более надёжным способом определения наличия видео- и аудиопотока в формате
            if not vtrack and formats[i].vcodec ~= "none" and (formats[i].quality or -1) >= 0
                    and math.min(formats[i].width or formats[i].height or 10^6, formats[i].height or 10^6) <= opts.target_resolution then
                vtrack = formats[i]
            elseif not atrack and (not formats[i].vcodec or formats[i].vcodec == "none") and (formats[i].quality or -1) >= 0
                    and ((formats[i].acodec and formats[i].acodec ~= "none") or formats[i].audio_ext) then
                atrack = formats[i]
            end
        end
        if vtrack then 
            table.insert(req_fmts, vtrack)
        end
        if not vtrack or not ((vtrack.acodec and vtrack.acodec ~= "none") or vtrack.audio_ext) then
            table.insert(req_fmts, atrack)
        end
    end
    return req_fmts
end


function populate_with_web_metadata(success, res)
    if fallback_running then fallback_running = nil return end
    if not (success and res and not res.killed_by_us and mp.get_property("path") == initial_path) then return end
    
    local ytdl_result = mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result") or {}
    local ytdl = utils.parse_json(ytdl_result.stdout or "")
    if ytdl_result.status ~= 0 or not ytdl then return end
    msg.debug("Async response received, response length: " .. #res.stdout)
    
    for _, sb_fmt in ipairs(storyboard_fmts) do -- возвращаем раскадровку обратно, при наличии форматов лучшего качества они перезапишут имеющиеся
        table.insert(ytdl.formats, 1, sb_fmt)
    end
    
    local response = utils.parse_json(res.stdout)
    if response and response.playabilityStatus then
        local duration = response.videoDetails and response.videoDetails.lengthSeconds and tonumber(response.videoDetails.lengthSeconds)
        if duration and response.storyboards and response.storyboards.playerStoryboardSpecRenderer and response.storyboards.playerStoryboardSpecRenderer.spec then
            add_storyboard_formats(ytdl, response.storyboards.playerStoryboardSpecRenderer.spec, duration)
        end
        if response.microformat and response.microformat.playerMicroformatRenderer then
            parse_microformat(ytdl, response.microformat.playerMicroformatRenderer)
        end
        if response.playabilityStatus.status ~= "OK" then -- при этом microformat всё равно может быть доступен
            msg.warn("Async sub-parsing failed, Youtube status: " .. response.playabilityStatus.status)
        end
    else
        msg.warn("Async sub-parsing failed, curl status=" .. tostring(res.status))
        msg.debug("Innertube response: " .. (#res.stdout > 0 and res.stdout or "(nil)"))
    end
    ytdl_result.stdout = utils.format_json(ytdl)
    mp.set_property_native("user-data/mpv/ytdl/json-subprocess-result", ytdl_result)
end