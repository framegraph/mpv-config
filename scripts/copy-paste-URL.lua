local subprocess = {
   name = "subprocess",
   args = { 'powershell', '-NoProfile', '-Command', [[& {
         Trap {
             Write-Error -ErrorRecord $_
             Exit 1
         }

         $clip = ""
         if (Get-Command "Get-Clipboard" -errorAction SilentlyContinue) {
             $clip = Get-Clipboard -Raw -Format Text -TextFormatType UnicodeText
         } else {
             Add-Type -AssemblyName PresentationCore
             $clip = [Windows.Clipboard]::GetText()
         }

         $clip = $clip -Replace "`r",""
         $u8clip = [System.Text.Encoding]::UTF8.GetBytes($clip)
         [Console]::OpenStandardOutput().Write($u8clip, 0, $u8clip.Length)
      }]] }, -- from console.lua
   playback_only = false,
   capture_stdout = true,
   capture_stderr = true
}

function trim(s)
   return (s:gsub("^%s*", ""):gsub("%s*$", ""))
end

function openURL(append)
    local command = "replace"
    local prefix = "Try Opening"
    if append then
        command = "append-play"
        prefix = "Appending"
    end
   
   if mp.get_property("clipboard") then -- mpv v0.40+ позволяет получить данные буфера обмена через специальное свойство без задержки (мгновенно)
      url = mp.get_property("clipboard/text") or ""
   else
      mp.osd_message("Getting URL from clipboard...")
      r = mp.command_native(subprocess)
      
      --failed getting clipboard data for some reason
      if r.status < 0 then
         mp.osd_message("Failed getting clipboard data!")
         print("Error(string): "..r.error_string)
         print("Error(stderr): "..r.stderr)
      end
      
      url = r.stdout
   end
   
   if not url then
      return
   end
   
   --trim whitespace from string
   url=trim(url)

   if url == "" then
      mp.osd_message("Clipboard empty")
      return
   end
   
   --immediately resume playback after loading URL
   -- if mp.get_property_bool("core-idle") then
      -- if not mp.get_property_bool("idle-active") then
         -- mp.command("keypress space")
      -- end
   -- end

   --try opening url
   --will fail if url is not valid
   mp.osd_message(prefix .. " URL:\n"..url)
   mp.command("script-message-to SimpleHistory list-close")
   if command == "replace" and url:match("youtube%.com") and url:match("watch%?v=([%w_-]+)") and url:match("list=([%w_-]+)") then
      local list = url:match("list=([%w_-]+)")
      yt_id = url:match("watch%?v=([%w_-]+)")
      mp.osd_message(prefix .. " Youtube playlist:\n" .. url)
      mp.commandv("loadfile", "https://www.youtube.com/playlist?list=" .. list, "replace")
	  mp.add_timeout(0.5, function() mp.observe_property("playlist-count", "number", change_pl_pos) end)
   else
      mp.commandv("loadfile", url, command)
   end
end

function change_pl_pos(_, plc)
	if plc == nil or plc <= 1 then return end
    local pos = mp.get_property_number("playlist-pos")
    for i = 0, plc-1 do
        local link = mp.get_property("playlist/" .. i .. "/filename")
        if yt_id and link:find("v=" .. yt_id) and pos ~= i then
            mp.commandv("playlist-play-index", i)
            break
        end
    end
	mp.unobserve_property(change_pl_pos)
end

mp.add_key_binding("ctrl+v", "open-clipboard", openURL)
mp.add_key_binding("ctrl+shift+v", "append-clipboard", function() openURL(true) end)
