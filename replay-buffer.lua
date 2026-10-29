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
]]
local CREATE_NO_WINDOW = 0x08000000
local STILL_ACTIVE = 259

local home = os.getenv("USERPROFILE"):gsub("\\", "/")
local own_ffmpeg = os.getenv("LOCALAPPDATA"):gsub("\\", "/") .. "/obs-disk-replay-buffer/ffmpeg.exe"
local FFMPEG_ZIP = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-lgpl.zip"

local buffer_min = 30
local clip_folder = ""
local pieces = {}           -- finished pieces {path, ended}
local current = nil         -- piece OBS is writing right now
local save_pending = false
local jobs = {}             -- running ffmpeg merges {proc, parts, files, target}
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

local function clean_up()
  local limit = os.time() - buffer_min * 60
  local rest = {}
  for _, p in ipairs(pieces) do
    if p.ended < limit then obs.os_unlink(p.path) else rest[#rest + 1] = p end
  end
  pieces = rest
end

local function size(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local n = f:seek("end")
  f:close()
  return n
end

local function check_jobs()
  local open = {}
  local code = ffi.new("uint32_t[1]")
  for _, j in ipairs(jobs) do
    ffi.C.GetExitCodeProcess(j.proc, code)
    if code[0] == STILL_ACTIVE then
      open[#open + 1] = j
    else
      ffi.C.CloseHandle(j.proc)
      -- ffmpeg skips an unreadable piece and still exits with 0; the size gives it away.
      local total = 0
      for _, f in ipairs(j.files) do total = total + size(f) end
      if code[0] == 0 and size(j.target) >= total * 0.99 then
        for _, f in ipairs(j.files) do obs.os_unlink(f) end
        obs.os_unlink(j.parts .. "/list.txt")
        obs.os_rmdir(j.parts)
        print("Saved: " .. j.target)
      else
        print("Merge incomplete (ffmpeg " .. code[0] .. "), pieces kept in " .. j.parts)
      end
    end
  end
  jobs = open
  if #jobs == 0 then obs.timer_remove(check_jobs) end
end

-- Joins the pieces losslessly (-c copy) into one file; if that fails, the parts folder stays.
local function merge(parts, files, target)
  local list = io.open(parts .. "/list.txt", "w")
  for _, f in ipairs(files) do list:write("file '" .. f .. "'\n") end
  list:close()
  local ffmpeg = ffmpeg_path()
  local proc = ffmpeg and run_hidden('"' .. ffmpeg .. '" -nostdin -v error -f concat -safe 0 -i "' .. parts ..
                                     '/list.txt" -c copy -n "' .. target .. '"')
  if not proc then
    print("ffmpeg not found, pieces kept in " .. parts)
    return
  end
  jobs[#jobs + 1] = { proc = proc, parts = parts, files = files, target = target }
  if #jobs == 1 then obs.timer_add(check_jobs, 1000) end
end

local function save()
  if #pieces == 0 then return end
  local name = "Replay " .. os.date("%Y-%m-%d %H-%M-%S")
  local target = clip_folder .. "/" .. name .. ".mp4"
  obs.os_mkdirs(clip_folder)
  if #pieces == 1 then
    obs.os_rename(pieces[1].path, target)
    print("Saved: " .. target)
  else
    -- Move them out of the buffer folder first so clean_up cannot delete them while ffmpeg reads.
    local parts = clip_folder .. "/" .. name .. " parts"
    obs.os_mkdirs(parts)
    local files = {}
    for _, p in ipairs(pieces) do
      files[#files + 1] = parts .. "/" .. p.path:match("[^/\\]+$")
      obs.os_rename(p.path, files[#files])
    end
    merge(parts, files, target)
  end
  pieces = {}
end

local function save_delayed()
  obs.timer_remove(save_delayed)
  save()
end

local function finish_piece()
  if current then pieces[#pieces + 1] = { path = current, ended = os.time() } end
  current = nil
end

local function file_changed(cd)
  finish_piece()
  current = obs.calldata_string(cd, "next_file")
  if save_pending then
    save_pending = false
    -- The muxer closes the old file shortly after the signal.
    obs.timer_add(save_delayed, 3000)
  else
    clean_up()
  end
end

local function connect_signal(connect)
  local out = obs.obs_frontend_get_recording_output()
  if not out then return end
  local sh = obs.obs_output_get_signal_handler(out)
  if connect then
    local st = obs.obs_output_get_settings(out)
    current = obs.obs_data_get_string(st, "path")
    obs.obs_data_release(st)
    obs.signal_handler_connect(sh, "file_changed", file_changed)
  else
    obs.signal_handler_disconnect(sh, "file_changed", file_changed)
  end
  obs.obs_output_release(out)
end

local function on_event(e)
  if e == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
    if not obs.obs_frontend_recording_active() then obs.obs_frontend_recording_start() end
  elseif e == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
    -- New buffer: whatever the last recording did not save is discarded.
    for _, p in ipairs(pieces) do obs.os_unlink(p.path) end
    pieces = {}
    connect_signal(true)
  elseif e == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
    connect_signal(false)
    finish_piece()
    clean_up()
  end
end

local function hotkey_pressed(pressed)
  if not pressed then return end
  if obs.obs_frontend_recording_active() then
    save_pending = true
    obs.obs_frontend_recording_split_file()
  else
    save()
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
  local buffer = home .. "/Videos/Replays/Buffer (auto-deleted)"
  obs.os_mkdirs(buffer)
  obs.config_set_string(cfg, "Output", "Mode", "Advanced")
  obs.config_set_string(cfg, "AdvOut", "RecType", "Standard")
  obs.config_set_string(cfg, "AdvOut", "RecFilePath", buffer)
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
         "After that, OBS is always recording. That recording is the buffer, so leave it on."
end

function script_properties()
  local p = obs.obs_properties_create()
  obs.obs_properties_add_int(p, "buffer_min", "Buffer (minutes)", 1, 600, 1)
  obs.obs_properties_add_path(p, "clip_folder", "Clip folder (same drive as the buffer)", obs.OBS_PATH_DIRECTORY, nil, nil)
  obs.obs_properties_add_button(p, "set_up", "Set up OBS", set_up)
  local done = obs.obs_properties_add_text(p, "setup_done", "✔ Done. Now close and restart OBS.\n" ..
    "OBS will then always be recording. That recording is the buffer, so leave it on. Alt+F10 saves a clip.", obs.OBS_TEXT_INFO)
  obs.obs_property_set_visible(done, false)
  return p
end

function script_defaults(settings)
  obs.obs_data_set_default_int(settings, "buffer_min", 30)
  obs.obs_data_set_default_string(settings, "clip_folder", home .. "/Videos/Replays")
end

function script_update(settings)
  buffer_min = obs.obs_data_get_int(settings, "buffer_min")
  clip_folder = obs.obs_data_get_string(settings, "clip_folder")
end

function script_load(settings)
  -- Pieces from the last OBS session, so the next recording start discards them.
  for ended, path in obs.obs_data_get_string(settings, "pieces"):gmatch("(%d+)|([^\n]+)") do
    pieces[#pieces + 1] = { path = path, ended = tonumber(ended) }
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
  if obs.obs_frontend_recording_active() then connect_signal(true) end
end

function script_save(settings)
  local lines = {}
  for _, p in ipairs(pieces) do lines[#lines + 1] = p.ended .. "|" .. p.path end
  if current then lines[#lines + 1] = os.time() .. "|" .. current end
  obs.obs_data_set_string(settings, "pieces", table.concat(lines, "\n"))
  local a = obs.obs_hotkey_save(hotkey_id)
  obs.obs_data_set_array(settings, "hotkey_save", a)
  obs.obs_data_array_release(a)
end
