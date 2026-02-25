-- Runs write-watch-later-config periodically, remain only last playing file in mpv's watch-later-history when watching via playlist file

local options = require 'mp.options'
local o = { 
    save_interval = 180, -- also saves when switching between videos, this is only for not losing watch position in case of emergencies like player crashing
    min_duration_to_save = 60, -- min video duration in seconds, 0 to save position for all files
    save_only_videos = true, -- don't save position for audio-only files by this script
    save_only_playlists = false -- save only if watching via playlist file
 }
options.read_options(o)

local pl = ""
local prevpl = ""
local reason = ""
local prevpath = ""
local need_saving = true
local pl_len = -1
local pl_0_fname = ""

local function save()
    if not need_saving then return end
	if mp.get_property_bool("resume-playback") and (mp.get_property("time-remaining") and mp.get_property_number("time-remaining") > 5) then
		mp.command("write-watch-later-config")
	end
    if mp.get_property_bool("pause") then timer:kill() end
end

local function restart_timer(_, pause)
	if pause == false then 
        if not timer:is_enabled() then timer:resume() end
    end
end


-- This function runs on file-loaded, registers two callback functions, and 
-- then they run delete-watch-later-config when appropriate.
local function delete_watch_later(event)
	local path = mp.get_property("path")
    
    mp.add_timeout(0.2, function()
        if pl ~= "" and prevpl == pl and reason ~= "" then
            mp.msg.info(reason)
            mp.commandv("delete-watch-later-config", prevpath)
        end 
        prevpl = pl
    end)
    if mp.get_property("duration") and mp.get_property_number("duration") < o.min_duration_to_save and o.min_duration_to_save > 0
            or o.save_only_playlists and pl == ""
            or o.save_only_videos and (mp.get_property("lavfi-complex") == "" and mp.get_property("vid") == "no" or mp.get_property("current-tracks/video/albumart") == "yes")
    then
        need_saving = false
        return
    else
        need_saving = true
    end

	-- Temporarily disables save-position-on-quit while eof-reached is true, so 
	-- state isn't saved at EOF when keep-open=yes
	local function eof_reached(_, eof)
		if not can_delete then
            reason = ""
			return
		elseif eof then
            local p = path
            mp.add_timeout(0.5, function()
                mp.msg.info("Deleting state (eof-reached)")
                mp.commandv("delete-watch-later-config", p)
            end)
        end
	end

	local function end_file(event)
		mp.unregister_event(end_file)
		mp.unobserve_property(eof_reached)
		if not can_delete then
            reason = ""
			can_delete = true
		elseif event["reason"] == "eof" or event["reason"] == "stop" then
			reason = "Deleting state (end-file "..event["reason"]..")"
			prevpath = path
		end
	end

	mp.observe_property("eof-reached", "bool", eof_reached)
	mp.register_event("end-file", end_file)
end

mp.set_property("save-position-on-quit", "yes")

can_delete = true
mp.register_script_message("skip-delete-state", function() can_delete = false end)

timer = mp.add_periodic_timer(o.save_interval, save)

mp.observe_property("pause", "bool", restart_timer)
mp.register_event("file-loaded", delete_watch_later)

function ResetPL()
    local playlist_0_filename = mp.get_property("playlist/0/filename")
    local playlist_count = mp.get_property_number("playlist-count")
    
    if pl == playlist_0_filename or pl == (playlist_0_filename or ""):gsub("[/\\]", package.config:sub(1,1)) then return end
    
    if playlist_count and playlist_0_filename and pl_len < 0 then
        pl = playlist_count .. " + " .. playlist_0_filename
        pl_len = playlist_count
        pl_0_fname = playlist_0_filename
    end
    if pl_len == playlist_count and pl_0_fname == playlist_0_filename then return end

    pl = ""
    mp.msg.info("End watching from playlist")
    mp.commandv("script-message", "current-playlist", "")
    mp.unobserve_property(ResetPL)
end
function CheckPlaylist(path, filename)
    if string.find(path, "://") then return end
    local ext = string.match(path, "%.([^%.]+)$")
    if ext == "m3u" or ext == "m3u8" or ext == "pls" then
        pl_len = -1
        pl_0_fname = ""
        pl = path
        mp.msg.info("Start watching from playlist: " .. filename)
        mp.commandv("script-message", "current-playlist", path) -- для функционала сборки: сохранение плейлиста (и его состояния) скриптом SimpleHistory
        mp.observe_property("playlist/0/filename", "native", ResetPL)
        mp.observe_property("playlist-count", "native", ResetPL)
    end
end
function onStart()
    CheckPlaylist(mp.get_property("path"), mp.get_property("filename"))
end

mp.register_script_message("playlist-created", CheckPlaylist) -- для функционала сборки: сразу же наблюдаем плейлист, созданный playlistmanager

mp.register_event("start-file", onStart)
mp.add_hook("on_unload", 10, save)
