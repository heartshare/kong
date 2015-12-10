local BaseService = require "kong.cli.services.base_service"
local logger = require "kong.cli.utils.logger"
local IO = require "kong.tools.io"
local stringy = require "stringy"
local cjson = require "cjson"
local cluster_utils = require "kong.tools.cluster"
local dao = require "kong.tools.dao_loader"

local Serf = BaseService:extend()

local SERVICE_NAME = "serf"
local LOG_FILE = "/tmp/"..SERVICE_NAME..".log"
local START_TIMEOUT = 10
local EVENT_NAME = "kong"

function Serf:new(configuration_value)
  local nginx_working_dir = configuration_value.nginx_working_dir

  self._parsed_config = configuration_value
  self._script_path = nginx_working_dir
                        ..(stringy.endswith(nginx_working_dir, "/") and "" or "/")
                        .."serf_event.sh"
  self._dao_factory = dao.load(self._parsed_config)
  Serf.super.new(self, SERVICE_NAME, nginx_working_dir)
end

function Serf:prepare()
  local luajit_path = BaseService.find_cmd("luajit")
  
  local script = [[
#!/bin/sh
PAYLOAD=`cat` # Read from stdin

if [ "$SERF_EVENT" != "user" ]; then
  PAYLOAD="{\"type\":\"${SERF_EVENT}\",\"entity\": \"${PAYLOAD}\"}"
fi

echo $PAYLOAD > /tmp/payload

COMMAND='require("kong.tools.http_client").post("http://127.0.0.1:]]..self._parsed_config.admin_api_port..[[/cluster/events/", ]].."[['${PAYLOAD}']]"..[[, {["content-type"] = "application/json"})'

echo $COMMAND | ]]..luajit_path..[[
]]
  local _, err = IO.write_to_file(self._script_path, script)
  if err then
    return false, err
  end

  -- Adding executable permissions
  local res, code = IO.os_execute("chmod +x "..self._script_path)
  if code ~= 0 then
    return false, res
  end

  return true
end

function Serf:_autojoin(current_node_name)
  if self._parsed_config.cluster["auto-join"] then

    logger:info("Auto-joining cluster, please wait..")

    -- Delete current node just in case it was there
    local _, err = self._dao_factory.nodes:delete({
      name = current_node_name
    })
    if err then
      return false, tostring(err)
    end

    local nodes, err = self._dao_factory.nodes:find_all()
    if err then
      return false, tostring(err)
    else
      if #nodes == 0 then
        logger:warn("Cannot auto-join the cluster because no nodes were found")
      else

        -- Sort by newest to oldest
        table.sort(nodes, function(a, b)
          return a.created_at > b.created_at
        end)

        local joined
        for _, v in ipairs(nodes) do
          local _, err = self:invoke_signal("join", {v.address})
          if err then
            logger:warn("Cannot join "..v.address..". If the node does not exist anymore it will be automatically purged.")
          else
            logger:info("Successfully auto-joined "..v.address)
            joined = true
            break
          end
        end
        if not joined then
          --return false, "Could not join the existing cluster"
          logger:warn("Could not join the existing cluster")
        end
      end
    end
  end
  return true
end

function Serf:start()
  if self:is_running() then
    return nil, SERVICE_NAME.." is already running"
  end

  local cmd, err = Serf.super._get_cmd(self)
  if err then
    return nil, err
  end

  -- Prepare arguments
  local cmd_args = {}
  setmetatable(cmd_args, require "kong.tools.printable")
  for k, v in pairs(self._parsed_config.cluster) do
    if type(v) ~= "table" and (type(v) == "boolean" or stringy.strip(v) ~= "") then
      cmd_args["-"..k] = v
    end
  end
  cmd_args["-auto-join"] = nil
  cmd_args["-log-level"] = "err"
  cmd_args["-profile"] = "wan"
  local node_name = cluster_utils.get_node_name(self._parsed_config)
  cmd_args["-node"] = node_name
  cmd_args["-event-handler"] = "member-join,member-leave,member-failed,member-update,member-reap,user:"..EVENT_NAME.."="..self._script_path

  local str_cmd_args = tostring(cmd_args)
  local res, code = IO.os_execute("nohup "..cmd.." agent "..str_cmd_args.." > "..LOG_FILE.." 2>&1 & echo $! > "..self._pid_file_path)
  if code == 0 then

    -- Wait for process to start, with a timeout
    local start = os.time()
    while not (IO.file_exists(LOG_FILE) and string.match(IO.read_file(LOG_FILE), "running") or (os.time() > start + START_TIMEOUT)) do
      -- Wait
    end

    if self:is_running() then
      logger:info(string.format([[serf ..............%s]], str_cmd_args))

      -- Auto-Join nodes
      return self:_autojoin(node_name)
    else
      -- Get last error message
      local parts = stringy.split(IO.read_file(LOG_FILE), "\n")
      return nil, "Could not start serf: "..string.gsub(parts[#parts - 1], "==> ", "")
    end
  else
    return nil, res
  end
end

function Serf:invoke_signal(signal, args, no_rpc)
  if not self:is_running() then
    return nil, SERVICE_NAME.." is not running"
  end

  local cmd, err = Serf.super._get_cmd(self)
  if err then
    return nil, err
  end

  if not args then args = {} end
  setmetatable(args, require "kong.tools.printable")
  local res, code = IO.os_execute(cmd.." "..signal.." "..(no_rpc and "" or "-rpc-addr="..self._parsed_config.cluster["rpc-addr"]).." "..tostring(args), true)
  if code == 0 then
    return res
  else
    return false, res
  end
end

function Serf:event(t_payload)
  local args = {
    ["-coalesce"] = false,
    ["-rpc-addr"] = self._parsed_config.cluster["rpc-addr"]
  }
  setmetatable(args, require "kong.tools.printable")

  local encoded_payload = cjson.encode(t_payload)
  if string.len(encoded_payload) > 512 then
    -- Serf can't send a payload greater than 512 bytes
    return false, "Encoded payload is "..string.len(encoded_payload).." and it exceeds the limit of 512 bytes!"
  end 

  return self:invoke_signal("event "..tostring(args).." kong", {"'"..encoded_payload.."'"}, true)
end

function Serf:stop()
  logger:info("Leaving cluster..")
  local _, err = self:invoke_signal("leave")
  if err then
    return false, err
  else
    Serf.super.stop(self)
  end
end

return Serf