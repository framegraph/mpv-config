-- Оверлей с отображением описания и прочих метаданных, предоставляемых парсером онлайн-видео

o = {} -- Настройки
o.fetch_youtube_dislikes = false    -- Включить получение примерного числа дизлайков на Ютуб-роликах,
                                    -- предоставляемого сервисом ReturnYoutubeDislike
o.ryd_api = "https://returnyoutubedislikeapi.com" -- API для получения данных о дизлайках - например:
                                    -- https://returnyoutubedislikeapi.com - официальный API RYD
                                    -- https://ryd-proxy.kavin.rocks - зеркало с отсутствием логов запросов
                                    -- от создателей сервиса Piped - альтернативного фронтенда Ютуба, уважащего приватность
o.prefetch_dislikes = false         -- Запрашивать данные о дизлайках автоматически при открытии видео, иначе - лишь после открытия оверлея
o.pass_proxy = true                 -- Использовать тот же прокси для получения дизлайков, что и для самого видео
o.sticky_header = true              -- Закрепить панель с общей информацией о видео при прокрутке описания
o.font_size = 60                    -- Размер шрифта в % относительно шрифта OSD (экранных надписей)
o.background_opacity = 0.35         -- Степень затемнения видео при открытии оверлея




(require "mp.options").read_options(o)

local utils = require('mp.utils')

local vid_info = {}
local desc = ""
local cap = ""
local ytdl_json_ready = false
local alt_desc_active = false
local ryd_cache = {}

-- список и алгоритм отображения региональных ограничений взяты из Invidious - другого альтернативного фронтенда Ютуба, уважащего приватность, работающего по сей день
-- https://github.com/iv-org/invidious/blob/6dec63a3e57c3f14ef6c615a96350d49a61a3d77/src/invidious/videos/regions.cr
REGIONS = {
    "AD", "AE", "AF", "AG", "AI", "AL", "AM", "AO", "AQ", "AR", "AS", "AT",
    "AU", "AW", "AX", "AZ", "BA", "BB", "BD", "BE", "BF", "BG", "BH", "BI",
    "BJ", "BL", "BM", "BN", "BO", "BQ", "BR", "BS", "BT", "BV", "BW", "BY",
    "BZ", "CA", "CC", "CD", "CF", "CG", "CH", "CI", "CK", "CL", "CM", "CN",
    "CO", "CR", "CU", "CV", "CW", "CX", "CY", "CZ", "DE", "DJ", "DK", "DM",
    "DO", "DZ", "EC", "EE", "EG", "EH", "ER", "ES", "ET", "FI", "FJ", "FK",
    "FM", "FO", "FR", "GA", "GB", "GD", "GE", "GF", "GG", "GH", "GI", "GL",
    "GM", "GN", "GP", "GQ", "GR", "GS", "GT", "GU", "GW", "GY", "HK", "HM",
    "HN", "HR", "HT", "HU", "ID", "IE", "IL", "IM", "IN", "IO", "IQ", "IR",
    "IS", "IT", "JE", "JM", "JO", "JP", "KE", "KG", "KH", "KI", "KM", "KN",
    "KP", "KR", "KW", "KY", "KZ", "LA", "LB", "LC", "LI", "LK", "LR", "LS",
    "LT", "LU", "LV", "LY", "MA", "MC", "MD", "ME", "MF", "MG", "MH", "MK",
    "ML", "MM", "MN", "MO", "MP", "MQ", "MR", "MS", "MT", "MU", "MV", "MW",
    "MX", "MY", "MZ", "NA", "NC", "NE", "NF", "NG", "NI", "NL", "NO", "NP",
    "NR", "NU", "NZ", "OM", "PA", "PE", "PF", "PG", "PH", "PK", "PL", "PM",
    "PN", "PR", "PS", "PT", "PW", "PY", "QA", "RE", "RO", "RS", "RU", "RW",
    "SA", "SB", "SC", "SD", "SE", "SG", "SH", "SI", "SJ", "SK", "SL", "SM",
    "SN", "SO", "SR", "SS", "ST", "SV", "SX", "SY", "SZ", "TC", "TD", "TF",
    "TG", "TH", "TJ", "TK", "TL", "TM", "TN", "TO", "TR", "TT", "TV", "TW",
    "TZ", "UA", "UG", "UM", "US", "UY", "UZ", "VA", "VC", "VE", "VG", "VI",
    "VN", "VU", "WF", "WS", "YE", "YT", "ZA", "ZM", "ZW",
}

function get_yt_dislikes()
    if not o.fetch_youtube_dislikes then return end
    local path = mp.get_property("path") or ""
    local url_params = path:match("https?://[^/]+/(.+)") or ""
    local video_id = path:match("://youtu%.be/([%w%-_]+)") or url_params:match("[?&]v=([%w%-_]+)") or url_params:match("^v/([%w%-_]+)")
      or url_params:match("^embed/([%w%-_]+)") or url_params:match("^live/([%w%-_]+)") or url_params:match("^shorts/([%w%-_]+)")
        
    if video_id and #video_id == 11 then
        vid_info["RYD_requested"] = true
        if ryd_cache[video_id] then
            if ryd_cache[video_id] >= 0 then
                vid_info["dislikes"] = ryd_cache[video_id]
                vid_info["RYD"] = true
            end
            return
        end
        
        local curl_cmd = {
            "curl", "--silent", "--show-error", "--max-time", "10",
            o.ryd_api.."/votes?videoId="..video_id
        }
        local ytdl_opts = mp.get_property_native("ytdl-raw-options") or {}
        local http_proxy = mp.get_property("http-proxy")
        local proxy = ytdl_opts.proxy or http_proxy
        if o.pass_proxy and proxy and proxy ~= "" then
            table.insert(curl_cmd, "--proxy")
            table.insert(curl_cmd, proxy)
        end
        mp.command_native_async({name="subprocess", args=curl_cmd, capture_stdout=true}, function(success, res)
            local ryd_data = utils.parse_json(res.stdout)
            if success and ryd_data and ryd_data.likes and ryd_data.likes > 0 and ryd_data.dislikes then
                vid_info["dislikes"] = ryd_data.dislikes
                vid_info["RYD"] = true
                ryd_cache[video_id] = ryd_data.dislikes
                if desc and desc ~= "" then
                    render_desc()
                end
            elseif ryd_data then
                mp.msg.info("Dislike count unknown")
                ryd_cache[video_id] = -1
            elseif not res.killed_by_us then
                mp.msg.warn("Fetching dislikes failed, curl status: " .. tostring(res.status))
                vid_info["RYD_requested"] = nil -- пробуем повторно получить дизлайки при следующем открытии оверлея
            end
        end)
    end
end

function prepare_regions(allowed_regions)
    if #allowed_regions == #REGIONS then -- ролик без региональных ограничений
        return "disallowed_regions", {}
    elseif #allowed_regions < (#REGIONS / 2) then -- видео недоступно в большинстве стран
        return "allowed_regions", allowed_regions
    else -- ролик недоступен лишь в части стран, которые и интересно выявить (как это делает и отображает Invidious)
        local disallowed_list = {}
        local allowed_set = {}
        for _, reg in ipairs(allowed_regions) do
            allowed_set[reg] = true
        end
        for _, reg in ipairs(REGIONS) do
            if not allowed_set[reg] then
                table.insert(disallowed_list, reg)
            end
        end
        return "disallowed_regions", disallowed_list
    end
end

function parse_desc(json)
    vid_info["title"] = json.alt_title or json.title -- обычное название и так отображается в заголовке - стремимся показать альтернативное
    vid_info["url"] = json.webpage_url or json.original_url
    vid_info["channel"] = json.uploader or json.channel
    vid_info["subscribers"] = json.channel_follower_count
    vid_info["verified"] = json.channel_is_verified
    vid_info["description"] = json.description
    vid_info["date"] = json.upload_date_text or json.upload_date
    vid_info["views"] = json.view_count
    vid_info["likes"] = json.like_count or vid_info["likes"]
    vid_info["dislikes"] = json.dislike_count or vid_info["dislikes"]
    vid_info["comment_count"] = json.comment_count
    vid_info["categories"] = json.categories
    vid_info["tags"] = json.tags
    vid_info["availability"] = json.availability
    -- поля ниже предоставляются только Ютуб-парсером из сборки
    vid_info["alt_description"] = json.alt_description
    vid_info["ai_content_warning"] = json.ai_content_warning
    if json.allowed_regions then
        local key, regions = prepare_regions(json.allowed_regions)
        vid_info[key] = regions
    end
    render_desc()
end

function parse_ytdl_json(json_str)
    local data, err = utils.parse_json(json_str or "")
    if data then
        ytdl_json_ready = false
        parse_desc(data)
    elseif json_str then
        mp.msg.warn("Unable to parse ytdl JSON: " .. (err or "unknown error"))
    end
end

function has_metadata()
    for key in pairs(vid_info) do
        if key ~= "title" and key ~= "url" then 
            return true 
        end
    end
    return false
end

function format_num(number)
    local formatted = ""
    local num_str = tostring(number)
    for i = 1, #num_str do
        formatted = formatted .. num_str:sub(i, i)
        if (#num_str - i) % 3 == 0 and i ~= #num_str then
            formatted = formatted .. " "
        end
    end
    return formatted
end

local darkening_overlay = string.format("{\\pos(0,0)\\alpha&H%x&\\c&H00\\p1} m 0 0 l 0 1000 1000 1000 1000 0 \n", 255 - 255*o.background_opacity)
local default_style = string.format("{\\fscx%d\\fscy%d\\bord%f}", o.font_size, o.font_size, 0.67 * o.font_size/100)
local small_font = string.format("{\\fscx%d\\fscy%d\\bord%f}", o.font_size*0.8, o.font_size*0.8, 0.54 * o.font_size/100)
local is_showing = false
local offset = 0
function render_desc()
    local function aif(key, str1, str2, fmt_num) -- "append if available", с опциональным форматированием чисел
        if vid_info[key] == true then
            desc = desc .. str1
        elseif type(vid_info[key]) == "table" then
            if #vid_info[key] > 0 then
                desc = desc .. str1 .. table.concat(vid_info[key], ", ") .. str2
            end
        elseif vid_info[key] and vid_info[key] ~= "" then
            if fmt_num and tonumber(vid_info[key]) then
                desc = desc .. str1 .. format_num(vid_info[key]) .. str2
            else
                desc = desc .. str1 .. vid_info[key] .. str2
            end
        end
    end
    if not vid_info then desc = "" return end
    if vid_info["date"] and tonumber(vid_info["date"]) then
        vid_info["date"] = string.format("%s-%s-%s", vid_info["date"]:sub(1, 4), vid_info["date"]:sub(5, 6), vid_info["date"]:sub(7))
    end
    
    desc = string.format(default_style.."{\\b1}%s{\\b0}"..small_font.."  (%s){\\i1}%s{\\i0}\n",
            vid_info["title"] or mp.get_property("media-title") or "", (vid_info["url"] or mp.get_property("path") or ""):gsub("^https?://", ""),
            vid_info["availability"] == "unlisted" and " (Видео с доступом по ссылке)" or (vid_info["availability"] == "private" and " (Видео с ограниченным доступом)" or ""))
            
    aif("ai_content_warning", "{\\u1\\1c&H66DDFF&}Происхождение ролика{\\u0}: ", "{\\1c}\n")
    aif("channel", "{\\u1}Канал{\\u0}: ", "")
    aif("verified", "✔")
    aif("subscribers", " (", " подписчиков)", true)

    aif("date", "\n 📅 ", "")
    aif("views", " | 👁‍ ", "", true)
    aif("likes", " | 👍 ", "", true)
    if vid_info["likes"] and vid_info["dislikes"] then
        local ratio = tonumber(vid_info["likes"]) / (tonumber(vid_info["likes"]) + tonumber(vid_info["dislikes"]))
        local l = math.floor(ratio * 75 + 0.5)
        local dl = math.floor((1 - ratio) * 75 + 0.5)
        desc = desc .. " {\\fnsans-serif\\bord".. 1.1 * o.font_size/100 .."\\1c&H2020E8&}" 
                .. string.rep("▏", l) .. "{\\1c&HA0A0A0&}" .. string.rep("▏", dl) .. "{\\r}" .. default_style
        aif("RYD", "{\\alpha&H33&}")
        aif("dislikes", " 👎 ", "", true)
        aif("RYD", "{\\alpha&H00&}")
    end
    aif("comment_count", " | 🗨 ", "", true)
    
    if o.sticky_header then
        cap = desc
        desc = " "
    else
        desc = "\n" .. desc
    end
    
    local desc_info = string.format("\n{\\u1}%s{\\u0}:  {\\i1\\fnsans-serif}"..small_font.."(↑↓ для прокрутки%s)\n",
            alt_desc_active and "Оригинальное описание" or "Описание",
            vid_info.alt_description and ", [Tab] - показать "..(alt_desc_active and "исходное" or "оригинал") or "")
    aif(alt_desc_active and "alt_description" or "description", desc_info, "\n")
    aif("categories", "\n{\\u1}Категория{\\u0}: ", "")
    aif("tags", "\n{\\u1}Теги{\\u0}: ", "")
    aif("allowed_regions", "\n{\\u1}Доступно в регионах{\\u0}: ", "")
    aif("disallowed_regions", "\n{\\u1}Недоступно в регионах{\\u0}: ", "")
    
    desc = desc:gsub("\r\n?", "\n"):gsub("\n\n", "\n\\h\n") -- рендер ASS пропускает (не выводит) пустые строки
    desc = desc:gsub("\n", "\n" .. default_style) -- рендер ASS сбрасывает оформление при начале новой строки
    cap = cap:gsub("\n", "\n" .. default_style)
    
    if is_showing then
        is_showing = false
        show_desc(true)
    end
end

function show_desc(save_offset)
    if ytdl_json_ready then
        parse_ytdl_json(mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result/stdout"))
    end
    if desc == "" or not has_metadata() then
        if (mp.get_property("path") or ""):find("^https?://") and not mp.get_property("time-pos") then
            mp.osd_message("Загрузка описания...", 30)
            is_showing = true
            offset = 0
        else
            mp.osd_message("Описание видео недоступно")
        end
        return
    end
    
    if is_showing == false then
        if not vid_info["RYD_requested"] then
            get_yt_dislikes()
        end
        if not save_offset then
            offset = 0
        end
        mp.add_forced_key_binding("UP", "scroll-up", scroll_up, {repeatable=true})
        mp.add_forced_key_binding("DOWN", "scroll-down", scroll_down, {repeatable=true})
        mp.add_forced_key_binding("WHEEL_UP", "wheel-up", function() scroll_up(3) end)
        mp.add_forced_key_binding("WHEEL_DOWN", "wheel-down", function() scroll_down(3) end)
        mp.add_forced_key_binding("Tab", "switch-desc", switch_desc)
        mp.add_forced_key_binding("Esc", "close-desc", show_desc)
        mp.add_forced_key_binding("MBTN_RIGHT", "close-desc2", show_desc)

        mp.osd_message("")
        ass_osd(string.gsub(desc, "[^\n]*\n", "", offset))
    else
        mp.set_osd_ass(0, 0, "{}")
        mp.remove_key_binding("scroll-up")
        mp.remove_key_binding("scroll-down")
        mp.remove_key_binding("wheel-up")
        mp.remove_key_binding("wheel-down")
        mp.remove_key_binding("switch-desc")
        mp.remove_key_binding("close-desc")
        mp.remove_key_binding("close-desc2")
    end
    is_showing = not is_showing
end

function switch_desc()
    if vid_info.alt_description then
        alt_desc_active = not alt_desc_active
        render_desc()
    end
end

function scroll_up(val)
    if not val then val = 1 end
    if val > offset then val = offset end
    offset = offset - val
    if offset < 3 then offset = 0 end
    ass_osd(string.gsub(desc, "[^\n]*\n", "", offset))
end
function scroll_down(val)
    if not val then val = 1 end
    if offset < 2 then offset = 2 end
    local new_msg = string.gsub(desc, "[^\n]*\n", "", offset + val)
    if not string.find(new_msg, "\n") then return end
    offset = offset + val 
    ass_osd(new_msg)
end
function ass_osd(msg)
    local cut = ""
    if offset > 0 then
        cut = "\n{\\i1}"..small_font.."...\n"
    end
    mp.set_osd_ass(0, 0, darkening_overlay .. cap .. cut .. msg)
end

function set_uosc_button(enable)
    local btn_json = utils.format_json({
        icon = enable and "info_outline" or "",
        active = false,
        tooltip = "Описание видео",
        command = "script-message show-description",
        hide = not enable
    })
    mp.commandv("script-message-to", "uosc", "set-button", "description-overlay", btn_json)
end

mp.observe_property("metadata", "native", function(_, meta)
    if meta and (meta.ytdl_description or meta.description or meta.DESCRIPTION) then
        -- для отображения описания из метаданных, встроенных в видеофайл, скачанный yt-dlp с опцией --embed-metadata,
        -- а также на случай старой версии mpv без экспорта ytdl/json-subprocess-result
        if not vid_info["description"] then
            local function add_meta(info_key, meta_key, ytdl_tag)
                if not meta_key then meta_key = info_key end
                if not vid_info[info_key] then
                    vid_info[info_key] = meta[meta_key] or meta[meta_key:upper()] or (ytdl_tag and meta[ytdl_tag])
                end
            end
        
            add_meta("channel", "artist", "uploader")
            add_meta("description", "description", "ytdl_description")
            add_meta("title")
            add_meta("url", "purl")
            add_meta("date")
            add_meta("categories", "genre")
            render_desc()
        end
        if o.prefetch_dislikes and not vid_info["RYD_requested"] then
            get_yt_dislikes()
        end
        set_uosc_button(true)
    end
end)

mp.observe_property("user-data/mpv/ytdl/json-subprocess-result", "native", function(_, res)
    if res and res.status == 0 then
        ytdl_json_ready = true -- info json может быть очень большим, поэтому парсим его только при открытии меню
        if is_showing then
            parse_ytdl_json(res.stdout)
        end
        if o.prefetch_dislikes and not vid_info["RYD_requested"] then
            get_yt_dislikes()
        end
    end
end)

function reset_state()
    if is_showing and desc ~= "" and has_metadata() then
        show_desc() -- закрытие описания
    elseif is_showing then
        mp.osd_message("")
    end
    vid_info = {}
    desc = ""
    is_showing = false
    ytdl_json_ready = false
    alt_desc_active = false
    set_uosc_button(false)
end

mp.register_event("start-file", reset_state)

mp.observe_property("idle-active", "bool", function(_, idle)
    if idle then
        reset_state()
    end
end)

mp.register_event("file-loaded", function() -- к этому моменту описание, если оно есть, всегда доступно
    if is_showing and desc == "" and not has_metadata() and not mp.get_property("metadata/ytdl_description") then
        mp.osd_message("Описание видео недоступно")
        is_showing = false
    end
end)

mp.register_script_message("show-description", show_desc)