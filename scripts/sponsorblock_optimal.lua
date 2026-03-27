-- sponsorblock_optimal.lua
--
-- This script skips sponsored segments of YouTube videos
-- using data from https://github.com/ajayyy/SponsorBlock

local opt = require 'mp.options'
local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'

local ON = false
local ranges = nil
local ranges_cache = {}
local youtube_id = nil
local user_agent = "mpv_sponsorblock_optimal/1.0"

local options = {
	server = "https://sponsor.ajay.app/api/skipSegments",

	-- Categories to skip automatically 
    -- Available: sponsor,selfpromo,interaction,intro,outro,preview,music_offtopic,filler,hook
	categories = 'sponsor',
    -- categories to skip manually via button or hotkey
    notice_categories = 'selfpromo,interaction,intro,outro,preview,music_offtopic',
    
    -- Skip each segment only once
    skip_once = true,

	-- Set this to "true" to use sha256HashPrefix instead of videoID
	hash = "true",
    
    -- Use the same proxy to fetch and submit segments as for the video itself
    pass_proxy = true,
    
    skip_key = "Enter", -- key for manual skip when available
    submit_key = "G", -- open submit new segment menu
    toggle_key = "", -- key to enable/disable script
    
    -- 32-character User ID used when submitting SponsorBlock segments
    -- leave empty to use and store a randomly generated one
    user_id = "",
    -- Time before the start of a newly created segment when entering preview mode
    preview_offset = 2,
    
    --- Skip notice appearance fine-tuning ---
    
    -- Button position for skip relative to the player window:
    -- positive values = from top/left edge, negative = from right/bottom
    skip_notice_pos_x = -20,
    skip_notice_pos_y = -110,

    -- Scaling factors for the button and the coordinates above in windowed and fullscreen modes
    scale = 1,
    scale_fullscreen = 1.3,

    persist_duration = 3.5, -- duration to show the button in seconds when entering a skippable segment
    osc_duration = 2, -- time before hiding the button when no mouse movement
    fade_in_duration = 0.15, -- duration of button show/hide animations
    fade_out_duration = 0.25,

    opacity_after_skip = 0.75, -- button opacity after an auto-skip occurred
    min_opacity = 0, -- button opacity after hidden
    
    -- By default SponsorBlock segments are additionally extracted only from chapters
    -- created on downloaded yt-dlp videos with the --sponsorblock-mark option
    -- You can also set custom patterns to extract segments from video chapters
    -- if SponsorBlock segments cannot be obtained directly for the current video
    custom_chapter_patterns = false,
    
    -- A |-separated list of Lua patterns that matches chapter titles for each SponsorBlock category
    -- The syntax is the same as in ytdl_hook's exclude option: 
    -- ^ matches the beginning of the title, $ matches its end,
    -- and you should use % before any of the characters ^$()%|,.[]*+-? to match that character
    -- To enforce case sensitivity in a specific pattern include at least one uppercase letter in it,
    -- otherwise chapter title comparison will be case-insensitive
    sponsor_patterns = "^ad$|^advertisement$|^pre%-?roll$|^реклама$",
    selfpromo_patterns = "",
    interaction_patterns = "",
    intro_patterns = "^OP$|^OP |^opening$|^intro$|опенинг|оупенинг|интро|заставка",
    outro_patterns = "^ED$|^ED |^ending$|^ending |^outro|credits$|^end$|эндинг|^титры",
    preview_patterns = "^next$|^preview$|^PV$|^recap$|^далее$|^далее ",
    music_offtopic_patterns = "",
    filler_patterns = "",
    hook_patterns = "",
}
opt.read_options(options, "sponsorblock_optimal")

local all_categories = {}
local skip_categories = {}
for cat in options.categories:gmatch("[^,;%s]+") do
    table.insert(all_categories, string.format('"%s"', cat))
    skip_categories[cat] = true
end
for cat in options.notice_categories:gmatch("[^,;%s]+") do
    if not skip_categories[cat] then
        table.insert(all_categories, string.format('"%s"', cat))
    end
end

local slang = mp.get_property("slang") or ""
local is_rus = slang:match("rus?,") or slang:match("rus?$")
local cat_data = {
    sponsor = {
        title = is_rus and "Спонсорская реклама" or "Sponsor",
        title2 = is_rus and "\\Nспонсорскую рекламу",
        color = "00D400"
 }, selfpromo = {
        title = is_rus and "Самореклама" or "Self-Promotion",
        title2 = is_rus and "саморекламу",
        color = "00FFFF"
 }, interaction = {
        title = is_rus and "Просьбы подписаться" or "Interaction",
        title2 = is_rus and "просьбы\\Nподписаться",
        color = "FF00CC"
 }, intro = {
        title = is_rus and "Заставка" or "Intro",
        title2 = is_rus and "заставку",
        color = "FFFF00"
 }, outro = {
        title = is_rus and "Концовка / титры" or "Outro",
        title2 = is_rus and "\\Nконцовку / титры",
        color = "FF6600"
 }, preview = {
        title = is_rus and "Краткое содержание" or "Preview/Recap",
        title2 = is_rus and "краткое\\Nсодержание",
        color = "FFAA33"
 }, music_offtopic = {
        title = is_rus and "Сегмент без музыки" or "Music Offtopic",
        title2 = is_rus and "сегмент\\Nбез музыки",
        color = "0099FF"
 }, filler = {
        title = is_rus and "Не относящееся к сути" or "Filler Tangent",
        title2 = is_rus and "\\Nне относящееся к сути",
        color = "FF0077"
 }, hook = {
        title = is_rus and "Завязка / приветствие" or "Hook/Greetings",
        title2 = is_rus and "\\Nзавязку / приветствие",
        color = "995639"
}}

local sha256
--[[
minified code below is a combination of:
-sha256 implementation from
http://lua-users.org/wiki/SecureHashAlgorithm
-lua implementation of bit32 (used as fallback on lua5.1) from
https://www.snpedia.com/extensions/Scribunto/engines/LuaCommon/lualib/bit32.lua
both are licensed under the MIT
--]]
do local b,c,d,e,f;if bit32 then b,c,d,e,f=bit32.band,bit32.rrotate,bit32.bxor,bit32.rshift,bit32.bnot else f=function(g)g=math.floor(tonumber(g))%0x100000000;return(-g-1)%0x100000000 end;local h={[0]={[0]=0,0,0,0},[1]={[0]=0,1,0,1},[2]={[0]=0,0,2,2},[3]={[0]=0,1,2,3}}local i={[0]={[0]=0,1,2,3},[1]={[0]=1,0,3,2},[2]={[0]=2,3,0,1},[3]={[0]=3,2,1,0}}local function j(k,l,m,n,o)for p=1,m do l[p]=math.floor(tonumber(l[p]))%0x100000000 end;local q=1;local r=0;for s=0,31,2 do local t=n;for p=1,m do t=o[t][l[p]%4]l[p]=math.floor(l[p]/4)end;r=r+t*q;q=q*4 end;return r end;b=function(...)return j('band',{...},select('#',...),3,h)end;d=function(...)return j('bxor',{...},select('#',...),0,i)end;e=function(g,u)g=math.floor(tonumber(g))%0x100000000;u=math.floor(tonumber(u))u=math.min(math.max(-32,u),32)return math.floor(g/2^u)%0x100000000 end;c=function(g,u)g=math.floor(tonumber(g))%0x100000000;u=-math.floor(tonumber(u))%32;local g=g*2^u;return g%0x100000000+math.floor(g/0x100000000)end end;local v={0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2}local function w(n)return string.gsub(n,".",function(t)return string.format("%02x",string.byte(t))end)end;local function x(y,z)local n=""for p=1,z do local A=y%256;n=string.char(A)..n;y=(y-A)/256 end;return n end;local function B(n,p)local z=0;for p=p,p+3 do z=z*256+string.byte(n,p)end;return z end;local function C(D,E)local F=-(E+1+8)%64;E=x(8*E,8)D=D.."\128"..string.rep("\0",F)..E;return D end;local function G(H)H[1]=0x6a09e667;H[2]=0xbb67ae85;H[3]=0x3c6ef372;H[4]=0xa54ff53a;H[5]=0x510e527f;H[6]=0x9b05688c;H[7]=0x1f83d9ab;H[8]=0x5be0cd19;return H end;local function I(D,p,H)local J={}for K=1,16 do J[K]=B(D,p+(K-1)*4)end;for K=17,64 do local L=J[K-15]local M=d(c(L,7),c(L,18),e(L,3))L=J[K-2]local N=d(c(L,17),c(L,19),e(L,10))J[K]=J[K-16]+M+J[K-7]+N end;local O,s,t,P,Q,R,S,T=H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8]for p=1,64 do local M=d(c(O,2),c(O,13),c(O,22))local U=d(b(O,s),b(O,t),b(s,t))local V=M+U;local N=d(c(Q,6),c(Q,11),c(Q,25))local W=d(b(Q,R),b(f(Q),S))local X=T+N+W+v[p]+J[p]T=S;S=R;R=Q;Q=P+X;P=t;t=s;s=O;O=X+V end;H[1]=b(H[1]+O)H[2]=b(H[2]+s)H[3]=b(H[3]+t)H[4]=b(H[4]+P)H[5]=b(H[5]+Q)H[6]=b(H[6]+R)H[7]=b(H[7]+S)H[8]=b(H[8]+T)end;local function Y(H)return w(x(H[1],4)..x(H[2],4)..x(H[3],4)..x(H[4],4)..x(H[5],4)..x(H[6],4)..x(H[7],4)..x(H[8],4))end;local Z={}sha256=function(D)D=C(D,#D)local H=G(Z)for p=1,#D,64 do I(D,p,H)end;return Y(H)end end
-- end of sha code

local notice_active = false
local notice_data = {}
local notice_focused = false
local notice_opacity = 1
local notice_last_render_time = 0
local transition_active, notice_target_opacity
local button_left, button_top, button_w, button_h
local scale = options.scale
local prev_time_left = -1

local skip_notice = mp.create_osd_overlay("ass-events")
skip_notice.z = 10000
function on_resize(_, dimensions, initial)
    if dimensions and dimensions.w and dimensions.h then
        skip_notice.res_x = dimensions.w
        skip_notice.res_y = dimensions.h
        local display_scale = mp.get_property_number("display-hidpi-scale") or 1
        if mp.get_property_bool("fullscreen") or mp.get_property_bool("window-maximized") then
            scale = options.scale_fullscreen * display_scale
        else
            scale = options.scale * display_scale
        end
        if not initial then
            if notice_active then
                render(mp.get_property_number("time-pos"))
            end
            on_mouse_move(_, mp.get_property_native("mouse-pos")) -- на случай, если координаты курсора обновятся раньше, чем размеры окна
        end
    end
end

local bounds_cache = {} -- кэш предыдущих рассчитанных размеров элементов кнопки (их не должно быть слишком много разных)
local probe_overlay = mp.create_osd_overlay("ass-events")
probe_overlay.compute_bounds = true
probe_overlay.hidden = true
function get_bounds(text)
    text = text:gsub("\\%d[ca]&H%w+&", "")
    if bounds_cache[text] then
        return bounds_cache[text][1], bounds_cache[text][2]
    else
        probe_overlay.res_x = skip_notice.res_x
        probe_overlay.res_y = skip_notice.res_y
        probe_overlay.data = text
        local res = probe_overlay:update()
        if res and res.x0 and res.x1 and res.y0 and res.y1 then -- работает как минимум с mpv v0.33+
            bounds_cache[text] = {math.abs(res.x1 - res.x0), math.abs(res.y1 - res.y0)}
            return math.abs(res.x1 - res.x0), math.abs(res.y1 - res.y0)
        end
    end
end

local fade_out_timer = mp.add_timeout(options.persist_duration, function()
    if notice_active and not transition_active and not notice_focused and notice_opacity == 1 then
        start_transition(0)
    end
end)
function reset_fade_out_timer(new_timeout)
    fade_out_timer.timeout = new_timeout
    fade_out_timer:kill()
    fade_out_timer:resume()
end
fade_out_timer:kill()

local render_generator = mp.add_periodic_timer(1 / (mp.get_property_number("display-fps") or 60), function()
    if notice_active and transition_active and mp.get_property_bool("core-idle") then
        -- во время воспроизведения плеер рендерит интерфейс лишь с частотой, равной fps видео (по умолчанию, если не включён --video-sync=display-*)
        -- поэтому неплохим решением будет во время воспроизведения рендерить переход каждый кадр видео, а на паузе - примерно на частоте обновления монитора
        render(mp.get_property_number("time-pos"))
    end
end)
render_generator:kill()

function calc_alpha(opaque_alpha)
    local normalized_opacity = notice_opacity + options.min_opacity * (1 - notice_opacity)
    local skipped_mag = (notice_data.skipped and not notice_focused) and options.opacity_after_skip or 1
    return 255 - (255 - opaque_alpha) * normalized_opacity * skipped_mag
end
function ease_out_sine(curr_opacity, dx) -- функция плавности с постепенным замедлением под конец перехода
    local x = math.asin(curr_opacity) * 2 / math.pi
    x = x + dx
    return x >= 1 and 1 or math.sin(x * math.pi/2)
end

function render(curr_time_pos)
    if not curr_time_pos or not notice_data.segment then return end
    
    local time_str
    if not notice_data.skipped then
        prev_time_left = math.floor(notice_data.segment[2] - curr_time_pos + 0.5)
        time_str = ("%d:%02d"):format(prev_time_left / 60, prev_time_left % 60)
    else
        prev_time_left = -1
        time_str = ("%d %s"):format(notice_data.skipped_secs, is_rus and "с" or "s")
    end
    local text = cat_data[notice_data.category] and 
            ((is_rus and not notice_data.skipped) and cat_data[notice_data.category].title2 or cat_data[notice_data.category].title) 
            or notice_data.category
    local color = cat_data[notice_data.category] and cat_data[notice_data.category].color or ""
    
    if not notice_data.skipped then
        text = (is_rus and "Пропустить " or "Skip ") .. text
    else
        local delim = text:find(" ") and "\\N" or " "
        text = (is_rus and "Пропущено:" or "Skipped:") .. delim .. text
    end
    
    if transition_active then
        if notice_target_opacity == 1 then
            notice_opacity = ease_out_sine(notice_opacity, (os.clock() - notice_last_render_time) / options.fade_in_duration)
        else
            notice_opacity = 1 - ease_out_sine(1 - notice_opacity, (os.clock() - notice_last_render_time) / options.fade_out_duration)
        end
        if notice_opacity == notice_target_opacity then
            transition_active = false
            render_generator:kill()
            if notice_data.skipped and notice_opacity == 0 then
                notice_data = {}
            end
        end
    end
    notice_last_render_time = os.clock()
    
    -- если хотите изменить внешний вид под себя, рекомендую включить "горячую перезагрузку" в конце скрипта, чтобы видеть изменения налету
    local text_ass = ("{\\an5\\fs%f\\bord0\\1c&H%s&\\1a&H%X&}%s"):format(18*scale, "EEEEEE", calc_alpha(0), text)
    local time_left_ass = ("{\\fs%f\\bord0\\1c&H%s&\\1a&H%X&}%s"):format(16*scale, "EEEEEE", calc_alpha(0), time_str)
    local text_w, text_h = get_bounds(text_ass)
    local time_w, time_h = get_bounds(time_left_ass:gsub(time_str, time_str:gsub("%d", "0"))) -- все цифры имеют примерно одинаковую ширину
    if notice_focused then
        if not notice_data.skipped then
            time_left_ass = time_left_ass:gsub(time_str, options.skip_key)
        else
            time_left_ass = time_left_ass:gsub(time_str, is_rus and "Назад" or "Unskip")
        end
        local w2, h2 = get_bounds(time_left_ass)
        time_w = math.max(time_w, w2) -- кнопка при наведении не должна быть меньше, чем до, чтобы не допустить мерцания
        time_h = math.max(time_h, h2)
    end
    
    local padding = 8 * scale
    local time_pad = 1 * scale
    local w_gap = 9 * scale
    local border_size = 1 * scale
    local accent_h = 2 * scale
    
    if text_w and text_h and time_w and time_h and curr_time_pos then
        local ass = assdraw.ass_new()
        button_w = math.floor(text_w + padding*2 + time_w + time_pad*2 + border_size*2 + w_gap + 0.5)
        button_h = math.floor(math.max(text_h, 18*scale * (text:find("\\N") and 2 or 1) + time_pad*2 + border_size*2 + accent_h) + padding*2 + 0.5)
        button_left = math.floor((options.skip_notice_pos_x >= 0 and button_w or skip_notice.res_x) + options.skip_notice_pos_x*scale - button_w + 0.5)
        button_top = math.floor((options.skip_notice_pos_y >= 0 and button_h or skip_notice.res_y) + options.skip_notice_pos_y*scale - button_h + 0.5)
        
        ass:new_event() -- задний фон
        ass:pos(button_left, button_top)
        ass:append(("{\\bord0\\1c&H%s&&\\1a&H%X&}"):format(notice_focused and "000000" or "202020", calc_alpha(32)))
        ass:draw_start()
        ass:round_rect_cw(0, 0, button_w, button_h, 8 * scale)
        ass:draw_stop()
        
        ass:new_event() -- цветовое выделение сверху в зависимости от категории
        ass:pos(button_left, button_top)
        ass:append(("{\\bord0\\1c&H%s&\\1a&H%X&\\clip(%f,%f,%f,%f)}"):format(color, calc_alpha(0), button_left, button_top, button_left + button_w, button_top + accent_h))
        ass:draw_start()
        ass:round_rect_cw(0, 0, button_w, button_h, 8 * scale)
        ass:draw_stop()
        
        ass:new_event() -- текст с категорией
        ass:pos(button_left + padding-border_size + text_w/2, button_top + button_h/2)
        ass:an(5)
        ass:append(text_ass)
        
        ass:new_event() -- линия-разделитель
        ass:pos(math.floor(button_left + text_w + padding-border_size + w_gap/2), math.ceil(button_top + button_h/2 - (button_h-padding*2)*0.45))
        ass:append(("{\\bord0\\1c&H%s&\\1a&H%X&}"):format("AAAAAA", calc_alpha(16))) 
        ass:draw_start()
        ass:rect_cw(0, 0, math.max(math.floor(border_size), 1), math.floor((button_h-padding*2)*0.9))
        ass:draw_stop()
        
        ass:new_event() -- текст со временем
        ass:pos(button_left + button_w - padding-border_size - time_w/2, button_top + button_h/2)
        ass:an(5)
        ass:append(time_left_ass)
        
        ass:new_event() -- рамка вокруг времени  (должна иметь дробные координаты, чтобы не было искажений)
        ass:pos(math.floor(button_left + button_w - padding-border_size - time_w - time_pad - 3 * (time_pad - time_pad/scale) + 0.5) - 0.1,
                math.floor(button_top + button_h/2 - time_h/2 - time_pad + 0.5) - 0.1)
        ass:append(("{\\bord%f\\3c&H%s&\\1a&HFF&\\3a&H%X&}"):format(border_size > 1 and math.floor(border_size) or border_size, "EEEEEE", calc_alpha(16)))
        ass:draw_start()
        ass:round_rect_cw(0, 0, math.floor(time_w + (time_pad + 3 * (time_pad - time_pad/scale)) * 2 + 0.5), math.floor(time_h + time_pad * 2 + 0.5), 4 * scale)
        ass:draw_stop()
        
        skip_notice.data = ass.text
        skip_notice:update()
    else
        button_left, button_top, button_w, button_h = nil, nil, nil, nil
    end
    notice_active = true
end

function clear()
    button_left, button_top, button_w, button_h = nil, nil, nil, nil
    skip_notice:remove()
    notice_active = false
    notice_focused = false
    mp.remove_key_binding("skip-segment")
    mp.remove_key_binding("skip-click")
    render_generator:kill()
    notice_opacity = 1
end

function start_transition(target_opacity)
    transition_active = true
    notice_last_render_time = os.clock() - 0.001
    notice_target_opacity = target_opacity
    if not render_generator:is_enabled() then
        render_generator:kill()
        render_generator:resume()
    end
end

function skip()
    if notice_active and notice_data then
        mp.commandv("revert-seek", "mark")
        mp.set_property("time-pos", notice_data.segment[notice_data.skipped and 1 or 2]+0.01)
    end
end

function on_mouse_move(_, mouse_pos)
    local focused = false
    if notice_active and mouse_pos and mouse_pos.hover and button_left 
            and mouse_pos.x >= button_left and mouse_pos.x < button_left + button_w
            and mouse_pos.y >= button_top and mouse_pos.y < button_top + button_h
    then
        focused = true
    end
    if mouse_pos and mouse_pos.hover and (not notice_data.skipped or focused) then
        reset_fade_out_timer(options.osc_duration)
        if notice_active and (not transition_active or notice_target_opacity < 1) and not (notice_opacity == 1 and not transition_active) then
            start_transition(1)
        end
    end
    if notice_active then
        if notice_focused ~= focused then
            notice_focused = focused
            render(mp.get_property_number("time-pos"))
            if focused then
                mp.add_forced_key_binding("MBTN_LEFT", "skip-click", skip)
            else
                mp.remove_key_binding("skip-click")
            end
        end
        if not mouse_pos.hover and not notice_focused and (not transition_active or notice_target_opacity > 0) then
            start_transition(0)
        end
    end
end

function skip_ads(name,pos)
	if pos then
        local skip_suggested = false
		for _, i in pairs(ranges) do
			v = i.segment[2]
			if i.segment[1] <= pos and v > pos and (mp.get_property_number("time-remaining") or 1) > 0.2 then
                if skip_categories[i.category] and not i.already_skipped then -- автопропуск сегмента (должен вызываться лишь единожды)
                    mp.commandv("revert-seek", "mark")
                    if options.skip_once then
                        i.already_skipped = true
                    end
                    notice_data = {}
                    notice_data.category = i.category
                    notice_data.segment = i.segment
                    notice_data.skipped = true
                    notice_data.skipped_secs = math.floor(v - pos + 0.5)
                    
                    reset_fade_out_timer(options.persist_duration)
                    render(pos)
                    
                    --need to do the +0.01 otherwise mpv will start spamming skip sometimes
                    --example: https://www.youtube.com/watch?v=4ypMJzeNooo
                    mp.set_property("time-pos",v+0.01)
                    mp.msg.info(string.format("%s auto-skipped (from %g to %g)", i.category, pos, v))
                    return
                elseif not skip_suggested then -- уведомление о ручном пропуске (вызывается каждый кадр видео)
                    skip_suggested = true
                    if not notice_active or notice_data ~= i then
                        if not fade_out_timer:is_enabled() then
                            notice_opacity = 0
                            start_transition(1)
                        end
                        reset_fade_out_timer(options.persist_duration)
                    end
                    
                    if not notice_active or not notice_data.category or notice_data.skipped then
                        mp.add_forced_key_binding(options.skip_key, "skip-segment", skip)
                    end
                    if not notice_active or notice_data ~= i or transition_active or prev_time_left ~= math.floor(v - pos + 0.5) then
                        notice_data = i
                        render(pos) -- рендерим кнопку только, если с момента прошлого рендера произошли изменения
                    end
                end
			end
		end
        if not skip_suggested and notice_data.skipped and transition_active then
            render(pos)
        elseif not skip_suggested and notice_active and not notice_data.skipped then
            clear()
        end
	end
end

function enable()
    ON = true
    for _, segment in ipairs(ranges) do
        segment.already_skipped = nil
    end
    on_resize(_, mp.get_property_native("osd-dimensions"), true)
    mp.observe_property("time-pos", "native", skip_ads)
    mp.observe_property("mouse-pos", "native", on_mouse_move)
    mp.observe_property("osd-dimensions", "native", on_resize)
end

function disable()
    if notice_active then
        clear()
    end
    mp.unobserve_property(skip_ads)
    mp.unobserve_property(on_resize)
    mp.unobserve_property(on_mouse_move)
	ON = false
end

function tolower(str) -- функция для приведения регистра букв к нижнему с поддержкой кириллицы
    str = str:gsub("[\208][\129\144-\175]", function(chr)
        local second_byte = chr:byte(2)
        if second_byte == 129 then
            return "ё"
        elseif (second_byte + 32 > 191) then
            return string.char(209, second_byte - 32)
        else
            return string.char(208, second_byte + 32)
        end
    end)
    return string.lower(str)
end

local ytdlp_category_names = {
	-- ["Chapter"] = "chapter",
	["Endcards/Credits"] = "outro",
	["Filler Tangent"] = "filler",
	-- ["Highlight"] = "poi_highlight",
	["Interaction Reminder"] = "interaction",
	["Intermission/Intro Animation"] = "intro",
	["Non-Music Section"] = "music_offtopic",
	["Preview/Recap"] = "preview",
	["Sponsor"] = "sponsor",
	["Unpaid/Self Promotion"] = "selfpromo",
    ["Hook/Greetings"] = "hook"
}
function ranges_from_chapters()
	local chapter_ranges = {}

	local chapters = mp.get_property_native("chapter-list")
	local duration = mp.get_property_native("duration")

	for i, chapter in ipairs(chapters) do
		local categories_string = string.match(chapter.title, "%[SponsorBlock%]:%s(.+)")
		if categories_string then
			for category_name in string.gmatch(categories_string, "([^,]+),?%s?") do
				local category = ytdlp_category_names[category_name]
				if category then
					local to = duration
					if i < #chapters then
						to = chapters[i+1].time
					end
					table.insert(chapter_ranges, {["segment"] = {chapter.time, to}, ["category"] = category})
				end
			end
		end
        
        if options.custom_chapter_patterns then
            for cat in pairs(cat_data) do
                local lower_title = tolower(chapter.title)
                for match in (options[cat.."_patterns"] or ""):gmatch('%|?([^|]+)') do
                    local case_sensitive = tolower(match) ~= match
                    if string.match(case_sensitive and chapter.title or lower_title, match) then
                        local to = duration
                        if i < #chapters then
                            to = chapters[i+1].time
                        end
                        table.insert(chapter_ranges, {["segment"] = {chapter.time, to}, ["category"] = cat})
                        break
                    end
                end
            end
        end
	end

    if #chapter_ranges > 0 then
        ranges = chapter_ranges
        mp.msg.info("Received", #ranges, "segments from chapters")
        enable()
    end
end

function pass_current_proxy(args)
    if options.pass_proxy then
        local ytdl_opts = mp.get_property_native("ytdl-raw-options") or {}
        local http_proxy = mp.get_property("http-proxy")
        local proxy = ytdl_opts["proxy"] or http_proxy
        if proxy and proxy ~= "" then
            mp.msg.debug("Using proxy:", proxy)
            table.insert(args, "--proxy")
            table.insert(args, proxy)
        end
    end
end

function file_loaded()
	local video_path = mp.get_property("path", "")
	local video_referer = string.match(mp.get_property("http-header-fields", ""), "Referer:([^,]+)") or ""
    local purl = mp.get_property("metadata/by-key/PURL", "")

	local urls = {
		"ytdl://youtu%.be/([%w-_]+).*",
		"ytdl://w?w?w?%.?youtube%.com/v/([%w-_]+).*",
		"https?://youtu%.be/([%w-_]+).*",
		"https?://w?w?w?%.?youtube%.com/v/([%w-_]+).*",
		"://.*/watch.*[?&]v=([%w-_]+).*",
		"://.*/embed/([%w-_]+).*",
		"^ytdl://([%w-_]+)$",
		"https?://[^/]*youtu%.?be[^/]*/[^/]*/([%w-_]+)"
	}
	for i,url in ipairs(urls) do
		youtube_id = youtube_id or string.match(video_path, url) or string.match(video_referer, url) or string.match(purl, url)
		if youtube_id then break end
	end
	if not youtube_id or string.len(youtube_id) ~= 11 then 
        youtube_id = nil
        ranges_from_chapters()
        return 
    end
	
    if ranges_cache[youtube_id] then
        mp.msg.debug("Reusing cached", #ranges_cache[youtube_id], "segments")
        if #ranges_cache[youtube_id] > 0 then
            ranges = ranges_cache[youtube_id]
            enable()
        else
            ranges_from_chapters()
        end
        return
    end

    -- иногда сервер sponsorblock возвращает http-ошибки 500 / 503, которые могут пройти при повторном обращении
    -- однако при переподключении удачный результат дописывается к выводу в stdout от предыдущей попытки, что ломает парсинг json
    -- поэтому пишем во временный файл, который перезаписывается после каждой новой попытки
    local out_path = utils.join_path((package.config:sub(1,1) ~= '/') and os.getenv("TEMP") or "/tmp/", "sponsorblock_out" .. utils.getpid())
	local args = {"curl", "-L", "-s", "-G", "--max-time", "10", "--retry", "3", "--retry-delay", "0", "-o", out_path, "-w", "%{http_code}",
            "--data-urlencode", ("categories=[%s]"):format(table.concat(all_categories, ","))}
	local url = options.server
	if options.hash == "true" or options.hash == "yes" then
		url = ("%s/%s"):format(url, string.sub(sha256(youtube_id), 0, 4))
	else
		table.insert(args, "--data-urlencode")
		table.insert(args, "videoID=" .. youtube_id)
	end
    pass_current_proxy(args)
	table.insert(args, url)

	local sponsors = mp.command_native{
		name = "subprocess",
		capture_stdout = true,
		args = args
	}
    local response = "(missing output file)"
    local file = io.open(out_path)
    if file then
        response = file:read("*a")
        file:close()
        os.remove(out_path)
    end
    mp.msg.debug(string.format("curl status: %d, received data: %s", sponsors.status or -1, response))
    
    local json = utils.parse_json(response)
    if type(json) == "table" then
        if options.hash == "true" or options.hash == "yes" then
            for _, i in pairs(json) do
                if i.videoID == youtube_id then
                    ranges = i.segments
                    break
                end
            end
        else
            ranges = json
        end

        if ranges then
            mp.msg.info("Received", #ranges, "sponsored segments")
            ranges_cache[youtube_id] = ranges
            enable()
            return
        end
    end
        
    if response:lower():match("^not found") or type(json) == "table" then
        -- не ошибка - сегментов просто нет в базе для текущего видео
        mp.msg.info("Sponsored segments not found")
        ranges_cache[youtube_id] = {}
    elseif not sponsors.killed_by_us then
        local err = "Unable to fetch SponsorBlock segments" .. (sponsors.status == 28 and " (network timeout)" or "")
        mp.msg.error(err .. ((sponsors.stdout ~= "" and sponsors.stdout ~= "000") and (", status code: " .. sponsors.stdout) or ""))
        mp.osd_message(is_rus and "Не удалось получить сегменты SponsorBlock" .. (sponsors.status == 28 and " (таймаут сети)" or "") or err)
        youtube_id = ""
    end
    
    ranges_from_chapters() -- если не получено не одного сегмента из базы
end

local submit_overlay = mp.create_osd_overlay("ass-events")
local start_pos, end_pos, preview_active, orig_time_pos, orig_pause_state
local selected_cat = 0
function submit_menu(action)
    local function format_button(btn)
        return string.format("{\\1c&H90FF90&}[%s]{\\1c}", btn)
    end
    local function format_time(s)
        if s >= 3600 then
            return string.format("{\\1c&FFFF90&}%02d:%02d:%02d{\\fscx70\\fscy70}.%03d{\\1c\\fscx100\\fscy100}", s / 3600, s / 60 % 60, s % 60, (s - math.floor(s)) * 1000)
        else
            return string.format("{\\1c&FFFF90&}%02d:%02d{\\fscx70\\fscy70}.%03d{\\1c\\fscx100\\fscy100}", s / 60, s % 60, (s - math.floor(s)) * 1000)
        end
    end
    
    local tpos = mp.get_property_number("time-pos")
    if not youtube_id or not tpos then
        mp.osd_message(is_rus and "Отправить сегмент SponsorBlock можно только для YouTube роликов" or "Sending a SponsorBlock segment is only available for YouTube videos")
        return
    elseif youtube_id == "" then
        mp.osd_message(is_rus and "Не удалось связаться с сервером SponsorBlock, попробуйте перезагрузить видео" or "Failed to connect to SponsorBlock, try reloading the video")
        return
    end
    
    if not submit_overlay.data or submit_overlay.data == "" then
        mp.add_forced_key_binding("p", "enter-preview-mode", function() 
            if not start_pos or not end_pos or start_pos >= end_pos then return end
            
            if not preview_active then
                orig_time_pos = mp.get_property_number("time-pos")
                orig_pause_state = mp.get_property_bool("pause")
                mp.observe_property("time-pos", "native", simulate_skip) -- skip_ads() может быть неактивна, если для текущего ролика не найдено ни одного сегмента
            end
            mp.set_property_number("time-pos", start_pos - options.preview_offset)
            mp.set_property_bool("pause", false)
            preview_active = true
            submit_overlay.data = "{\\fscx70\\fscy70}" .. string.format(
                    is_rus and "Через %g сек произойдёт пропуск нового сегмента - постарайтесь, чтобы он получился бесшовным\\NДля выхода из предпросмотра нажмите %s"
                    or "A new segment will be skipped in %g seconds - try to make it seamless\\NPress %s to exit preview",
                    options.preview_offset, format_button("Esc")) .. "{\\fscx90\\fscy90}\\h" -- дополнительный межстрочный интервал
            submit_overlay:update()
        end)
        
        mp.add_forced_key_binding("1", "change-start-pos", function()
            submit_menu(1)
        end)
        mp.add_forced_key_binding("2", "change-end-pos", function()
            submit_menu(2)
        end)
        
        mp.add_forced_key_binding("!", "jump-to-start-pos", function()
            if start_pos and not preview_active then
                mp.set_property_number("time-pos", start_pos)
            end
        end)
        mp.add_forced_key_binding("@", "jump-to-end-pos", function()
            if end_pos and not preview_active then
                mp.set_property_number("time-pos", end_pos)
            end
        end)
        
        mp.add_forced_key_binding("UP", "selected-up", function()
            selected_cat = selected_cat - 1
            if selected_cat < 0 then selected_cat = #all_categories - 1 end
            submit_menu(-1)
        end, "repeatable")
        mp.add_forced_key_binding("DOWN", "selected-down", function()
            selected_cat = (selected_cat + 1) % #all_categories
            submit_menu(-1)
        end, "repeatable")
        
        mp.add_forced_key_binding("Ctrl+Enter", "submit-segment", function()
            if not start_pos or not end_pos or start_pos >= end_pos or preview_active then return end
            if #options.user_id < 32 then
                options.user_id = get_user_id()
            end
            submit_segment()
        end)
        
        mp.add_forced_key_binding("Esc", "handle-submit-esc", function() 
            if preview_active then
                preview_active = false
                mp.unobserve_property(simulate_skip)
                submit_menu(-1)
                if orig_time_pos then mp.set_property_number("time-pos", orig_time_pos) end
                if orig_pause_state == true then mp.set_property_bool("pause", orig_pause_state) end
                orig_time_pos, orig_pause_state = nil, nil
            else
                exit_submit_menu()
            end
        end)
    end
    
    if not preview_active then
        if action ~= -1 then
            if action == 1 or not start_pos then
                start_pos = tpos
            elseif action == 2 or not end_pos or start_pos >= end_pos then
                end_pos = tpos
            end
        end
        
        local start_time_txt = is_rus and "Начальное время: " or "Start time: "
        local end_time_txt = is_rus and "Конечное время: " or "End time: "
        local set_curr_txt = is_rus and " - установить" or " - set current"
        local change_txt = is_rus and " - изменить, " or " - change, "
        local jump_to_txt = is_rus and " - перейти сюда" or " - jump to"
        submit_overlay.data = start_time_txt .. format_time(start_pos) .. "  " .. format_button("1") .. change_txt .. format_button("!") .. jump_to_txt
                .. "\\N" .. end_time_txt .. (end_pos and 
                    (format_time(end_pos) .. "  ")
                    or ("...  " .. format_button(options.submit_key) .. (is_rus and " или " or " or "))
                ) .. format_button("2") .. (not end_pos and set_curr_txt or (change_txt .. format_button("@") .. jump_to_txt))
        
        if start_pos and end_pos then
            if start_pos >= end_pos then
                submit_overlay.data = submit_overlay.data .. "\\N{\\1c&H7070FF&}"
                        .. (is_rus and "Конечное время должно быть больше начального!" or "End time must be greater than start time!")
            else
                submit_overlay.data = submit_overlay.data .. "\\N" .. format_button("p") .. " - " .. (is_rus and "режим предпросмотра" or "preview mode")
                        .. string.format("\\N%s:  {\\fscx70\\fscy70}({\\1c&H90FF90&}[{\\fnsans-serif}↑↓{\\fnDefault}]{\\1c} %s)",
                            is_rus and "Категория" or "Category", is_rus and "для изменения" or "for switching")
                        .. "{\\fscx130\\fscy130}\\h{\\fscx100\\fscy100}\\N"
                for i, category in ipairs(all_categories) do -- предлагаем на выбор только те категории, для которых загружены сегменты
                    local name = category:sub(2, #category-1)
                    submit_overlay.data = submit_overlay.data .. (cat_data[name] and ("{\\1c&H" .. cat_data[name].color .. "&}") or "") .. "{\\fscx80}➤{\\fscx100} "
                            .. (i-1 == selected_cat and "{\\1c&Hffbf7f&}" or "{\\1c}")
                            .. (cat_data[name] and cat_data[name].title or category) .. "{\\1c}\\N"
                end
                submit_overlay.data = submit_overlay.data .. "{\\fscx100\\fscy100}" .. format_button("Ctrl+Enter") .. " - " 
                        .. (is_rus and "отправить сегмент" or "submit segment") .. "{\\fscx150\\fscy150}\\h"
            end
        end
        submit_overlay:update()
        mp.osd_message("")
    end
end

function exit_submit_menu()
    submit_overlay.data = ""
    submit_overlay:remove()
    mp.remove_key_binding("enter-preview-mode")
    mp.remove_key_binding("change-start-pos")
    mp.remove_key_binding("change-end-pos")
    mp.remove_key_binding("jump-to-start-pos")
    mp.remove_key_binding("jump-to-end-pos")
    mp.remove_key_binding("selected-up")
    mp.remove_key_binding("selected-down")
    mp.remove_key_binding("submit-segment")
    mp.remove_key_binding("handle-submit-esc")
end

function simulate_skip(_, pos)
    if pos and start_pos <= pos and end_pos > pos then
        mp.set_property("time-pos", end_pos+0.01)
        submit_overlay.data = submit_overlay.data:gsub(".*\\N", string.format("{\\fscx70\\fscy70}%s {\\1c&H90FF90&}[p]{\\1c}\\N",
                is_rus and "Для повторения пропуска нажмите" or "To repeat the skip, press"))
        submit_overlay:update()
    end
end

function get_user_id()
    local id_file_path = mp.command_native({"expand-path", "~~/sponsorblock_user_id.txt"})
    local f = io.open(id_file_path, "r")
    if f then
        local id = f:read("*l")
        f:close()
        if id and #id >= 32 then
            return id
        end
    end
        
    math.randomseed(os.time() * math.floor(os.clock() * 1000))
    local id = ""
    for i = 1, 32 do 
        id = id .. string.char(string.byte('a') + math.random(0, 25))
    end
    mp.msg.debug("New user ID generated: " .. id)
    local new_f = io.open(id_file_path, "w")
    if new_f then
        new_f:write(id)
        new_f:close()
    else
        mp.msg.warn("Unable to save user ID to file '" .. id_file_path .. "', new ID will be generated the next time")
    end
    return id
end

function submit_segment()
    local category_name = all_categories[selected_cat+1]:sub(2, #all_categories[selected_cat+1]-1)
    local json_body = utils.format_json({
        videoID = youtube_id,
        userID = options.user_id,
        userAgent = user_agent,
        videoDuration = mp.get_property_number("duration"),
        segments = {{ -- массив сегментов из одного элемента
            segment = {start_pos, end_pos},
            category = category_name
        }}
    })
    local args = {"curl", "-L", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-A", user_agent, "-d", json_body, "-w", "\n%{http_code}"}
    pass_current_proxy(args)
    table.insert(args, options.server) -- уже включает в себя нужный API endpoint
    
    ranges_cache[youtube_id] = nil -- позволяем загрузить сегменты для видео заново, чтобы убедиться, что новый успешно добавился
    exit_submit_menu()
    mp.osd_message(is_rus and "Сегмент отправляется..." or "Submitting segment...", 10)
    
    local res = mp.command_native{
		name = "subprocess",
		capture_stdout = true,
		args = args
	}
    mp.msg.debug("Response:", res.stdout)
    
    local status_code = res.stdout:match("\n(%d+)") or ""
    if tonumber(status_code) and tonumber(status_code) >= 200 and tonumber(status_code) < 300 then
        mp.osd_message(is_rus and "Сегмент успешно отправлен" or "Segment submitted successfully")
        if not ranges then -- для видео не было ни одного сегмента, из-за чего отслеживание свойств для пропуска не включено
            ranges = {}
            enable()
        end
        table.insert(ranges, {category = category_name, segment = {start_pos, end_pos}})
        start_pos, end_pos = nil, nil
    elseif status_code == "400" then
        mp.osd_message(is_rus and "Не удалось отправить сегмент из-за недопустимого ввода" or "Failed to submit segment due to impossible inputs", 5)
    elseif status_code == "403" then
        mp.osd_message(is_rus and "Сегмент был отвергнут авто-модератором" or "Segment was rejected by auto moderator", 5)
    elseif status_code == "409" then
        mp.osd_message(is_rus and "Этот сегмент уже был отправлен" or "Segment already submitted")
    elseif status_code == "429" then
        mp.osd_message(is_rus and "Слишком много запросов, попробуйте повторить отправку позже" or "Too many requests, try submitting again later", 5)
    elseif tonumber(status_code) and tonumber(status_code) >= 500 and tonumber(status_code) < 600 then
        mp.osd_message(is_rus and "Сервер SponsorBlock упал, попробуйте ещё раз" or "SponsorBlock server is down, please try again", 5)
    elseif res.killed_by_us then
        mp.osd_message(is_rus and "Отправка сегмента прервана" or "Segment submission aborted")
    else
        local err_code = (status_code ~= "" and status_code ~= "000") and status_code or "nil (unknown)"
        mp.osd_message(string.format(is_rus and "Не удалось отправить сегмент, ошибка с кодом %s" or "Failed to submit segment, error code %s", err_code), 5)
    end
end


function end_file()
    if submit_overlay.data and submit_overlay.data ~= "" then
        if preview_active then
            preview_active = false
            mp.unobserve_property(simulate_skip)
            orig_time_pos, orig_pause_state = nil, nil
        end
        exit_submit_menu()
    end
    start_pos, end_pos = nil, nil
    ranges = nil
    youtube_id = nil

	if ON then 
        disable()
    end
end

function toggle()
    if not ranges then
        mp.osd_message("[sponsorblock] " .. (is_rus and "откл (сегменты недоступны)" or "off (segments unavailable)"))
	elseif ON then
		disable()
		mp.osd_message("[sponsorblock] " .. (is_rus and "откл" or "off"))
	else
		enable()
		mp.osd_message("[sponsorblock] " .. (is_rus and "вкл" or "on"))
	end
end


if #all_categories > 0 then
    mp.register_event("file-loaded", file_loaded)
    mp.register_event("end-file", end_file)
    mp.add_forced_key_binding(options.submit_key, "submit-segment-menu", submit_menu)
    mp.add_forced_key_binding(options.toggle_key, "sponsorblock-toggle", toggle)
else
    mp.keep_running = false -- завершение работы скрипта
end


-- горячая перезагрузка при изменении кода скрипта
--[[ чтобы включить, удалите эту строку и перезапустите плеер
local script_path = debug.getinfo(1).source:match('@?(.*)')
function get_script_mtime()
    local finfo = utils.file_info(script_path)
    if finfo and finfo.mtime then
        return finfo.mtime
    end
end
local initial_time = get_script_mtime()
mp.add_periodic_timer(0.3, function()
    if get_script_mtime() ~= initial_time then
        mp.msg.info("Live-reloading...")
        if ranges then
            mp.set_property_native("user-data/live-reload-transfer", ranges)
        end
        mp.set_property_native("user-data/live-reload-transfer2", youtube_id)
        mp.commandv("load-script", script_path)
        clear()
        mp.keep_running = false
    end
end)

local saved_ranges = mp.get_property_native("user-data/live-reload-transfer")
if saved_ranges then
    ranges = saved_ranges
    mp.set_property_native("user-data/live-reload-transfer", nil)
    enable()
end
youtube_id = mp.get_property_native("user-data/live-reload-transfer2")
mp.set_property_native("user-data/live-reload-transfer2", nil)
--]]