-- Replay buffer on disk instead of RAM.
-- OBS records all the time and splits the recording into pieces. This script deletes pieces older than the
-- buffer and, on hotkey, joins everything since the last save into one clip.
obs = obslua
local ffi = require("ffi")

-- Start ffmpeg without a console window and without waiting: os.execute would flash a window and freeze OBS.
ffi.cdef [[
typedef struct {
  uint32_t cb; void *lpReserved; void *lpDesktop; void *lpTitle;
  uint32_t dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
  uint16_t wShowWindow, cbReserved2; void *lpReserved2; void *hStdInput, *hStdOutput, *hStdError;
} STARTUPINFOA;
typedef struct { void *hProcess, *hThread; uint32_t dwProcessId, dwThreadId; } PROCESS_INFORMATION;
int CreateProcessA(const char *app, char *cmd, void *pa, void *ta, int inherit, uint32_t flags,
                   void *env, const char *dir, STARTUPINFOA *si, PROCESS_INFORMATION *pi);
int GetExitCodeProcess(void *h, uint32_t *code);
int CloseHandle(void *h);
uint32_t SearchPathA(const char *path, const char *file, const char *ext, uint32_t len, char *buf, char **part);
uint32_t GetModuleFileNameA(void *module, char *buf, uint32_t len);
int SetFileAttributesA(const char *path, uint32_t attrs);
int MoveFileExA(const char *from, const char *to, uint32_t flags);
]]
local CREATE_NO_WINDOW = 0x08000000
local STILL_ACTIVE = 259
local FILE_ATTRIBUTE_HIDDEN = 0x2
local MOVEFILE_COPY_ALLOWED = 0x2
local SPLIT_MS = 5 * 60 * 1000

local home = os.getenv("USERPROFILE"):gsub("\\", "/")
local app_dir = os.getenv("LOCALAPPDATA"):gsub("\\", "/") .. "/obs-disk-replay-buffer"
local own_ffmpeg = app_dir .. "/ffmpeg.exe"
-- AppData is hidden in Explorer, so nobody stumbles over the pieces.
local BUFFER = app_dir .. "/buffer"
local FFMPEG_ZIP = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-lgpl.zip"

local buffer_min = 30
local clip_folder = ""
local per_monitor = false
-- A recording whose pieces become clips:
--   pieces   finished pieces {path, started, ended}; started is unknown for pieces from a reload
--   current  piece OBS is writing right now, started at current_started
--   pending  name of the clip waiting for the split
--   saving   name of the clip waiting for the muxer to close the old file
local main
local extras = {}           -- recordings of further monitors {track, out, source, view, venc, aenc}
local ending = {}           -- stopped extras waiting for their last piece
local jobs = {}             -- running ffmpeg merges {proc, name, parts, files, placeholder, cut, seconds}
local hotkey_id = obs.OBS_INVALID_HOTKEY_ID

local function run_hidden(cmd)
  local si = ffi.new("STARTUPINFOA")
  si.cb = ffi.sizeof(si)
  local pi = ffi.new("PROCESS_INFORMATION")
  if ffi.C.CreateProcessA(nil, ffi.new("char[?]", #cmd + 1, cmd), nil, nil, 0, CREATE_NO_WINDOW, nil, nil, si, pi) == 0 then
    return nil
  end
  ffi.C.CloseHandle(pi.hThread)
  return pi.hProcess
end

local function ffmpeg_path()
  if obs.os_file_exists(own_ffmpeg) then return own_ffmpeg end
  if ffi.C.SearchPathA(nil, "ffmpeg.exe", nil, 0, nil, nil) > 0 then return "ffmpeg.exe" end
  return nil
end

local function clean_up(t)
  local limit = os.time() - buffer_min * 60
  local rest = {}
  for _, p in ipairs(t.pieces) do
    if p.ended < limit then obs.os_unlink(p.path) else rest[#rest + 1] = p end
  end
  t.pieces = rest
end

local function size(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local n = f:seek("end")
  f:close()
  return n
end

-- Moves the pieces into the clip folder so nothing is lost; that may be another drive, hence the copy.
local function give_up(j, why)
  local visible = clip_folder .. "/" .. j.name .. " parts"
  obs.os_unlink(j.placeholder)
  obs.os_mkdirs(visible)
  for _, f in ipairs(j.files) do ffi.C.MoveFileExA(f, visible .. "/" .. f:match("[^/]+$"), MOVEFILE_COPY_ALLOWED) end
  -- The ffmpeg log stays with the pieces, so the cause can be looked up later.
  ffi.C.MoveFileExA(j.parts .. "/ffmpeg.log", visible .. "/ffmpeg.log", MOVEFILE_COPY_ALLOWED)
  obs.os_unlink(j.parts .. "/list.txt")
  obs.os_rmdir(j.parts)
  print(why .. ", pieces kept in " .. visible)
end

local function read_log(j)
  local f = io.open(j.parts .. "/ffmpeg.log", "r")
  if not f then return "" end
  local text = f:read(2000) or ""
  f:close()
  return text
end

local function check_jobs()
  local open = {}
  local code = ffi.new("uint32_t[1]")
  for _, j in ipairs(jobs) do
    if not j.code then
      ffi.C.GetExitCodeProcess(j.proc, code)
      if code[0] ~= STILL_ACTIVE then
        ffi.C.CloseHandle(j.proc)
        j.code, j.checks = code[0], 0
      end
    end
    if not j.code then
      open[#open + 1] = j
    else
      -- ffmpeg skips an unreadable piece and still exits with 0; the size gives it away.
      -- A cut first piece shrinks by an unknown share, so it is left out of the check.
      local total = 0
      for i, f in ipairs(j.files) do
        if not (i == 1 and j.cut) then total = total + size(f) end
      end
      local got = size(j.placeholder)
      -- Joining drops the fragment headers of the pieces, about 0.4 KB per second at 10 fps. On a quiet monitor
      -- that exceeds 1 % of the size (measured 15.11.2026), so the allowance also grows with the clip length.
      if j.code == 0 and got >= total * 0.99 - 2048 * j.seconds then
        local clip = clip_folder .. "/" .. j.name .. ".mp4"
        obs.os_rename(j.placeholder, clip)
        for _, f in ipairs(j.files) do obs.os_unlink(f) end
        obs.os_unlink(j.parts .. "/list.txt")
        obs.os_unlink(j.parts .. "/ffmpeg.log")
        obs.os_rmdir(j.parts)
        print("Saved: " .. clip)
      elseif j.code == 0 and j.checks < 5 then
        -- A virus scanner or indexer may hold the fresh clip for a moment, so the size reads too small; look again.
        j.checks = j.checks + 1
        open[#open + 1] = j
      else
        give_up(j, ("Merge incomplete (ffmpeg %d, clip %d of %d bytes) %s"):format(j.code, got, total, read_log(j)))
      end
    end
  end
  jobs = open
  if #jobs == 0 then obs.timer_remove(check_jobs) end
end

-- Joins the pieces losslessly (-c copy) into the placeholder; if that fails, the pieces go to the clip folder.
local function merge(j)
  local list = io.open(j.parts .. "/list.txt", "w")
  for i, f in ipairs(j.files) do
    list:write("file '" .. f .. "'\n")
    -- Starts at the keyframe before the cut, so the clip is at most a few seconds longer than the buffer.
    if i == 1 and j.cut then list:write("inpoint " .. j.cut .. "\n") end
  end
  list:close()
  local ffmpeg = ffmpeg_path()
  -- cmd only routes ffmpeg's errors into a log; /s strips the outer quotes and its exit code is ffmpeg's.
  j.proc = ffmpeg and run_hidden('cmd /s /c ""' .. ffmpeg .. '" -nostdin -v error -f concat -safe 0 -i "' .. j.parts ..
                                 '/list.txt" -c copy -f mp4 -y "' .. j.placeholder .. '" 2>"' .. j.parts ..
                                 '/ffmpeg.log""')
  if not j.proc then return give_up(j, "ffmpeg not found") end
  jobs[#jobs + 1] = j
  if #jobs == 1 then obs.timer_add(check_jobs, 1000) end
end

-- The placeholder appears right on the hotkey, so the user sees that the clip is on its way. ffmpeg writes straight
-- into it; it gets its extension once the clip is complete.
local function announce_clip(name)
  obs.os_mkdirs(clip_folder)
  io.open(clip_folder .. "/" .. name .. " - processing", "w"):close()
  return name
end

local function save(t, name)
  local pieces = t.pieces
  local placeholder = clip_folder .. "/" .. name .. " - processing"
  if #pieces == 0 then return obs.os_unlink(placeholder) end
  -- clean_up runs only at splits and keeps a piece as long as it ended within the buffer, so the pieces may reach
  -- further back than the clip length.
  local from = pieces[#pieces].ended - buffer_min * 60
  while pieces[1].ended <= from do
    obs.os_unlink(pieces[1].path)
    table.remove(pieces, 1)
  end
  local first = pieces[1]
  local cut = first.started and from - first.started
  if not cut or cut <= 0 then cut = nil end
  -- Moving the pieces aside keeps clean_up from deleting them while ffmpeg reads. Hidden for setups whose buffer
  -- still lies in Videos.
  local parts = first.path:match("^(.*)[/\\]") .. "/" .. name .. " parts"
  obs.os_mkdirs(parts)
  ffi.C.SetFileAttributesA(parts, FILE_ATTRIBUTE_HIDDEN)
  local files = {}
  for _, p in ipairs(pieces) do
    files[#files + 1] = parts .. "/" .. p.path:match("[^/\\]+$")
    obs.os_rename(p.path, files[#files])
  end
  -- Writing in the clip folder also works when it is on another drive than the buffer.
  local seconds = pieces[#pieces].ended - math.max(from, first.started or from)
  merge({ name = name, parts = parts, files = files, placeholder = placeholder, cut = cut, seconds = seconds })
  t.pieces = {}
end

local function finish_piece(t)
  if t.current then t.pieces[#t.pieces + 1] = { path = t.current, started = t.current_started, ended = os.time() } end
  t.current = nil
end

-- suffix tells the clips of several recordings apart, e.g. " Monitor 2".
local function new_track(suffix)
  local t = { suffix = suffix, pieces = {}, pending = false }
  t.save_delayed = function()
    obs.timer_remove(t.save_delayed)
    local name = t.saving
    t.saving = nil
    save(t, name)
  end
  t.file_changed = function(cd)
    finish_piece(t)
    t.current = obs.calldata_string(cd, "next_file")
    t.current_started = os.time()
    if t.pending then
      t.saving = t.pending
      t.pending = false
      -- The muxer closes the old file shortly after the signal.
      obs.timer_add(t.save_delayed, 3000)
    else
      clean_up(t)
    end
  end
  return t
end
main = new_track("")

-- The OBS recording plus, with "One clip per monitor", one recording for each further monitor.
local function tracks()
  local all = { main }
  for _, e in ipairs(extras) do all[#all + 1] = e.track end
  return all
end

local function busy()
  for _, t in ipairs(tracks()) do
    if t.pending or t.saving then return true end
  end
  return false
end

local function split_output(out)
  local cd = obs.calldata_create()
  obs.proc_handler_call(obs.obs_output_get_proc_handler(out), "split_file", cd)
  obs.calldata_destroy(cd)
end

local function split_all()
  obs.obs_frontend_recording_split_file()
  for _, e in ipairs(extras) do split_output(e.out) end
end

-- A 300 MB piece lasts 27 min of a calm scene; short pieces keep the buffer folder close to the buffer length.
-- The size split stays for busy scenes.
local function split_regularly()
  if not busy() then split_all() end
end

local function connect_signal(connect)
  local out = obs.obs_frontend_get_recording_output()
  if not out then return end
  local sh = obs.obs_output_get_signal_handler(out)
  if connect then
    local st = obs.obs_output_get_settings(out)
    main.current = obs.obs_data_get_string(st, "path")
    main.current_started = os.time()
    obs.obs_data_release(st)
    obs.signal_handler_connect(sh, "file_changed", main.file_changed)
    obs.timer_add(split_regularly, SPLIT_MS)
  else
    obs.signal_handler_disconnect(sh, "file_changed", main.file_changed)
    obs.timer_remove(split_regularly)
  end
  obs.obs_output_release(out)
end

local function discard_pieces(t)
  for _, p in ipairs(t.pieces) do obs.os_unlink(p.path) end
  t.pieces = {}
end

-- Stopping ends the buffer; unsaved pieces would only take up space.
local function end_track(t)
  finish_piece(t)
  -- A clip still waiting for its split gets everything up to the stop instead of a placeholder that never resolves.
  local name = t.pending or t.saving
  t.pending, t.saving = false, nil
  obs.timer_remove(t.save_delayed)
  if name then save(t, name) end
  discard_pieces(t)
end

-- Monitors as Display Capture lists them ("BenQ GL2450: 1920x1080 @ 1920,0"), numbered from left to right.
local function list_monitors()
  local props = obs.obs_get_source_properties("monitor_capture")
  local list = obs.obs_properties_get(props, "monitor_id")
  local mons = {}
  for i = 0, obs.obs_property_list_item_count(list) - 1 do
    local w, h, x, y = obs.obs_property_list_item_name(list, i):match("(%d+)x(%d+) @ (%-?%d+),(%-?%d+)")
    if w then
      mons[#mons + 1] = { id = obs.obs_property_list_item_string(list, i), w = tonumber(w), h = tonumber(h),
                          x = tonumber(x), y = tonumber(y) }
    end
  end
  obs.obs_properties_destroy(props)
  table.sort(mons, function(a, b) return a.x < b.x or (a.x == b.x and a.y < b.y) end)
  return mons
end

-- Monitors the current scene already shows through a visible Display Capture.
local function monitors_in_scene()
  local ids = {}
  local scene_source = obs.obs_frontend_get_current_scene()
  local items = obs.obs_scene_enum_items(obs.obs_scene_from_source(scene_source)) or {}
  for _, item in ipairs(items) do
    local s = obs.obs_sceneitem_get_source(item)
    if obs.obs_sceneitem_visible(item) and obs.obs_source_get_unversioned_id(s) == "monitor_capture" then
      local st = obs.obs_source_get_settings(s)
      ids[obs.obs_data_get_string(st, "monitor_id")] = true
      obs.obs_data_release(st)
    end
  end
  obs.sceneitem_list_release(items)
  obs.obs_source_release(scene_source)
  return ids
end

-- Same encoder and settings as the OBS recording, so all clips look alike.
local function copy_encoder(enc, name, mixer)
  local st = obs.obs_encoder_get_settings(enc)
  local id = obs.obs_encoder_get_id(enc)
  local copy = mixer and obs.obs_audio_encoder_create(id, name, st, mixer, nil) or
               obs.obs_video_encoder_create(id, name, st, nil)
  obs.obs_data_release(st)
  return copy
end

local function release_extra(e)
  obs.signal_handler_disconnect(obs.obs_output_get_signal_handler(e.out), "file_changed", e.track.file_changed)
  obs.obs_output_release(e.out)
  obs.obs_encoder_release(e.venc)
  obs.obs_encoder_release(e.aenc)
  obs.obs_view_remove(e.view)
  obs.obs_view_set_source(e.view, 0, nil)
  obs.obs_view_destroy(e.view)
  obs.obs_source_release(e.source)
end

-- Records one monitor at its own resolution with the audio of the OBS recording, in pieces like the OBS recording.
local function start_extra(mon, n, rec)
  local name = "Disk replay Monitor " .. n
  local st = obs.obs_data_create()
  obs.obs_data_set_string(st, "monitor_id", mon.id)
  local e = { source = obs.obs_source_create_private("monitor_capture", name, st), view = obs.obs_view_create() }
  obs.obs_data_release(st)
  local ovi = obs.obs_video_info()
  obs.obs_get_video_info(ovi)
  ovi.base_width, ovi.base_height, ovi.output_width, ovi.output_height = mon.w, mon.h, mon.w, mon.h
  obs.obs_view_set_source(e.view, 0, e.source)
  e.venc = copy_encoder(obs.obs_output_get_video_encoder(rec), name, nil)
  obs.obs_encoder_set_video(e.venc, obs.obs_view_add2(e.view, ovi))
  e.aenc = copy_encoder(obs.obs_output_get_audio_encoder(rec, 0), name, 0)
  obs.obs_encoder_set_audio(e.aenc, obs.obs_get_audio())
  -- The prefix keeps the pieces apart from the OBS recording's, which splits in the same second.
  local prefix = "Monitor " .. n .. " "
  e.track = new_track(" Monitor " .. n)
  e.track.current = BUFFER .. "/" .. prefix .. os.date("%Y-%m-%d %H-%M-%S") .. ".mp4"
  e.track.current_started = os.time()
  st = obs.obs_data_create()
  obs.obs_data_set_string(st, "path", e.track.current)
  obs.obs_data_set_string(st, "directory", BUFFER)
  obs.obs_data_set_string(st, "format", prefix .. "%CCYY-%MM-%DD %hh-%mm-%ss")
  obs.obs_data_set_string(st, "extension", "mp4")
  obs.obs_data_set_bool(st, "allow_spaces", true)
  obs.obs_data_set_bool(st, "split_file", true)
  obs.obs_data_set_int(st, "max_size_mb",
                       obs.config_get_int(obs.obs_frontend_get_profile_config(), "AdvOut", "RecSplitFileSize"))
  e.out = obs.obs_output_create("mp4_output", name, st, nil)
  obs.obs_data_release(st)
  obs.obs_output_set_video_encoder(e.out, e.venc)
  obs.obs_output_set_audio_encoder(e.out, e.aenc, 0)
  obs.signal_handler_connect(obs.obs_output_get_signal_handler(e.out), "file_changed", e.track.file_changed)
  obs.os_mkdirs(BUFFER)
  if not obs.obs_output_start(e.out) then
    print("Monitor " .. n .. " could not be recorded: " .. (obs.obs_output_get_last_error(e.out) or "unknown error"))
    return release_extra(e)
  end
  extras[#extras + 1] = e
  print(("Recording Monitor %d (%dx%d at %d,%d) separately."):format(n, mon.w, mon.h, mon.x, mon.y))
end

-- The OBS recording keeps recording the scene. Each monitor the scene does not show gets its own recording; if the
-- scene shows exactly one monitor, its clips carry that monitor's number.
local function start_extras()
  if not per_monitor or #extras > 0 or not obs.obs_frontend_recording_active() then return end
  local rec = obs.obs_frontend_get_recording_output()
  local shown = monitors_in_scene()
  local in_scene = {}
  for n, mon in ipairs(list_monitors()) do
    if shown[mon.id] then in_scene[#in_scene + 1] = n else start_extra(mon, n, rec) end
  end
  obs.obs_output_release(rec)
  main.suffix = #in_scene == 1 and " Monitor " .. in_scene[1] or ""
end

-- The output stops only at the next keyframe and closes its last piece after that, so a fixed wait missed it.
local function finish_ending()
  local open = {}
  for _, e in ipairs(ending) do
    if obs.obs_output_active(e.out) then
      open[#open + 1] = e
    else
      end_track(e.track)
      release_extra(e)
    end
  end
  ending = open
  if #ending == 0 then obs.timer_remove(finish_ending) end
end

local function end_extras()
  main.suffix = ""
  if #extras == 0 then return end
  for _, e in ipairs(extras) do
    obs.obs_output_stop(e.out)
    ending[#ending + 1] = e
  end
  extras = {}
  obs.timer_remove(finish_ending)
  obs.timer_add(finish_ending, 500)
end

-- Only our own folder gets emptied, never a recording folder from a setup that predates it.
local function buffer_is_ours()
  local path = obs.config_get_string(obs.obs_frontend_get_profile_config(), "AdvOut", "RecFilePath") or ""
  return path:gsub("\\", "/"):lower() == BUFFER:lower()
end

-- Deletes what an earlier session left in the buffer, e.g. after a crash.
local function sweep_buffer()
  local current = main.current
  if not current or not buffer_is_ours() then return end
  local dir = obs.os_opendir(BUFFER)
  if not dir then return end
  local e = obs.os_readdir(dir)
  while e do
    local path = BUFFER .. "/" .. e.d_name
    if not e.directory and path:lower() ~= current:gsub("\\", "/"):lower() then obs.os_unlink(path) end
    e = obs.os_readdir(dir)
  end
  obs.os_closedir(dir)
end

-- OBS may still be writing the last piece while scripts shut down, so a hidden cmd keeps trying for a minute.
local function empty_buffer_after_exit()
  if not buffer_is_ours() then return end
  local pattern = '"' .. BUFFER:gsub("/", "\\") .. '\\*.mp4"'
  local proc = run_hidden("cmd /c for /l %i in (1,1,30) do @(del /q " .. pattern .. " 2>nul & if not exist " ..
                          pattern .. " (exit) else ping -n 3 127.0.0.1 >nul)")
  if proc then ffi.C.CloseHandle(proc) end
end

local function on_event(e)
  if e == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
    if not obs.obs_frontend_recording_active() then obs.obs_frontend_recording_start() end
  elseif e == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
    discard_pieces(main)
    connect_signal(true)
    sweep_buffer()
    start_extras()
  elseif e == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
    connect_signal(false)
    end_track(main)
    end_extras()
  elseif e == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN then
    empty_buffer_after_exit()
  end
end

local function hotkey_pressed(pressed)
  if not pressed then return end
  -- The split waits for the next keyframe (up to 2 s). A second press in that time used to replace the waiting clip's
  -- name, so its placeholder stayed at "processing" forever.
  if busy() then
    print("A clip is already being saved, hotkey ignored.")
    return
  end
  local name = "Replay " .. os.date("%Y-%m-%d %H-%M-%S")
  if obs.obs_frontend_recording_active() then
    for _, t in ipairs(tracks()) do t.pending = announce_clip(name .. t.suffix) end
    split_all()
  else
    save(main, announce_clip(name .. main.suffix))
  end
end

-- Starts OBS at Windows login. OBS looks for its files relative to the working
-- directory, so the shortcut has to set it.
local function add_autostart()
  local buf = ffi.new("char[260]")
  local exe = ffi.string(buf, ffi.C.GetModuleFileNameA(nil, buf, 260))
  local f = io.open(os.getenv("APPDATA") .. "\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\OBS Replay Buffer.vbs", "w")
  f:write('Set sh = CreateObject("WScript.Shell")\n',
          'sh.CurrentDirectory = "', exe:match("^(.*)\\"), '"\n',
          'sh.Run """', exe, '"" --startrecording", 1, False\n')
  f:close()
end

-- One-time setup of the active profile: record to the buffer folder in 300 MB pieces.
-- Splitting by time would split only once with Hybrid MP4 (OBS 33, obs-studio#14051).
local function set_up(props)
  local cfg = obs.obs_frontend_get_profile_config()
  obs.os_mkdirs(BUFFER)
  obs.config_set_string(cfg, "Output", "Mode", "Advanced")
  obs.config_set_string(cfg, "AdvOut", "RecType", "Standard")
  obs.config_set_string(cfg, "AdvOut", "RecFilePath", BUFFER)
  obs.config_set_string(cfg, "AdvOut", "RecFormat2", "hybrid_mp4")
  obs.config_set_bool(cfg, "AdvOut", "RecSplitFile", true)
  obs.config_set_string(cfg, "AdvOut", "RecSplitFileType", "Size")
  obs.config_set_int(cfg, "AdvOut", "RecSplitFileSize", 300)
  -- NVIDIA: HEVC at constant quality 24 looks like the source and needs about 2.5 GB per 30 min.
  if obs.obs_get_encoder_codec("obs_nvenc_hevc_tex") then
    obs.config_set_string(cfg, "AdvOut", "RecEncoder", "obs_nvenc_hevc_tex")
    local enc = obs.obs_data_create_from_json('{"rate_control":"CQP","cqp":24,"preset":"p5","keyint_sec":2}')
    obs.obs_data_save_json_safe(enc, os.getenv("APPDATA") .. "/obs-studio/basic/profiles/" ..
                                obs.obs_frontend_get_current_profile() .. "/recordEncoder.json", ".tmp", ".bak")
    obs.obs_data_release(enc)
  end
  obs.config_save_safe(cfg, "tmp", nil)
  if not ffmpeg_path() then
    local dir = own_ffmpeg:match("^(.*)/"):gsub("/", "\\")
    obs.os_mkdirs(dir)
    -- curl and tar (bsdtar, reads zip) ship with Windows 10 1803 and later.
    local sys = "%SystemRoot%\\System32\\"
    local proc = run_hidden('cmd /c ' .. sys .. 'curl.exe -sSfL -o "' .. dir .. '\\ffmpeg.zip" ' .. FFMPEG_ZIP .. ' && ' .. sys .. 'tar.exe -xf "' ..
                            dir .. '\\ffmpeg.zip" -C "' .. dir .. '" --strip-components 2 */bin/ffmpeg.exe && del "' ..
                            dir .. '\\ffmpeg.zip"')
    if proc then ffi.C.CloseHandle(proc) end
    print("Downloading ffmpeg in the background (about 180 MB).")
  end
  add_autostart()
  print("Setup done. Restart OBS; from then on it buffers whenever OBS runs. OBS now starts with Windows.")
  obs.obs_property_set_visible(obs.obs_properties_get(props, "setup_done"), true)
  return true
end

function script_description()
  return "Replay buffer on disk: keeps the last minutes of the recording and saves everything since the last save " ..
         "as one clip (hotkey „Save replay to disk“, default Alt+F10).\n" ..
         "Click „Set up OBS“ once, then restart OBS.\n" ..
         "After that, OBS is always recording. That recording is the buffer, so leave it on.\n" ..
         "„One clip per monitor“ also records every monitor the scene does not show and saves one clip each."
end

function script_properties()
  local p = obs.obs_properties_create()
  obs.obs_properties_add_float(p, "buffer_min", "Max clip length (minutes)", 0.5, 600, 0.5)
  obs.obs_properties_add_path(p, "clip_folder", "Clip folder", obs.OBS_PATH_DIRECTORY, nil, nil)
  obs.obs_properties_add_button(p, "set_up", "Set up OBS", set_up)
  local done = obs.obs_properties_add_text(p, "setup_done", "✔ Done. Now close and restart OBS.\n" ..
    "OBS will then always be recording. That recording is the buffer, so leave it on. Alt+F10 saves a clip.", obs.OBS_TEXT_INFO)
  obs.obs_property_set_visible(done, false)
  local pm = obs.obs_properties_add_bool(p, "per_monitor", "One clip per monitor")
  obs.obs_property_set_long_description(pm, "Records each monitor the scene does not show separately with the same " ..
    "encoder. The hotkey then saves one clip per monitor (… Monitor 1, … Monitor 2), numbered from left to right. " ..
    "Takes effect right away while recording.")
  return p
end

function script_defaults(settings)
  obs.obs_data_set_default_double(settings, "buffer_min", 30)
  obs.obs_data_set_default_string(settings, "clip_folder", home .. "/Videos/Replays")
  obs.obs_data_set_default_bool(settings, "per_monitor", false)
end

function script_update(settings)
  buffer_min = obs.obs_data_get_double(settings, "buffer_min")
  clip_folder = obs.obs_data_get_string(settings, "clip_folder")
  per_monitor = obs.obs_data_get_bool(settings, "per_monitor")
  if per_monitor then start_extras() else end_extras() end
end

function script_load(settings)
  -- Pieces from the last OBS session, so the next recording start discards them.
  for ended, path in obs.obs_data_get_string(settings, "pieces"):gmatch("(%d+)|([^\n]+)") do
    main.pieces[#main.pieces + 1] = { path = path, ended = tonumber(ended) }
  end
  hotkey_id = obs.obs_hotkey_register_frontend("disk_replay_save", "Save replay to disk", hotkey_pressed)
  local a = obs.obs_data_get_array(settings, "hotkey_save")
  if obs.obs_data_array_count(a) == 0 then
    obs.obs_data_array_release(a)
    a = obs.obs_data_array_create()
    local key = obs.obs_data_create_from_json('{"alt":true,"key":"OBS_KEY_F10"}')
    obs.obs_data_array_push_back(a, key)
    obs.obs_data_release(key)
  end
  obs.obs_hotkey_load(hotkey_id, a)
  obs.obs_data_array_release(a)
  obs.obs_frontend_add_event_callback(on_event)
  -- OBS refuses to record into a missing folder, e.g. after a cleanup tool removed it. Scripts load before the
  -- recording starts.
  if buffer_is_ours() then obs.os_mkdirs(BUFFER) end
  if obs.obs_frontend_recording_active() then
    connect_signal(true)
    start_extras()
  end
end

-- Reloading the script must not leave its recordings running without anyone to save them.
function script_unload()
  for _, e in ipairs(extras) do
    obs.obs_output_stop(e.out)
    release_extra(e)
  end
  for _, e in ipairs(ending) do release_extra(e) end
  extras, ending = {}, {}
end

function script_save(settings)
  local lines = {}
  for _, p in ipairs(main.pieces) do lines[#lines + 1] = p.ended .. "|" .. p.path end
  if main.current then lines[#lines + 1] = os.time() .. "|" .. main.current end
  obs.obs_data_set_string(settings, "pieces", table.concat(lines, "\n"))
  local a = obs.obs_hotkey_save(hotkey_id)
  obs.obs_data_set_array(settings, "hotkey_save", a)
  obs.obs_data_array_release(a)
end
