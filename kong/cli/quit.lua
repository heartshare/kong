#!/usr/bin/env lua

local constants = require "kong.constants"
local cutils = require "kong.cli.utils"
local signal = require "kong.cli.utils.signal"
local args = require("lapp")(string.format([[
Graceful shutdown. Stop the Kong instance running in the configured 'nginx_working_dir' directory.

Usage: kong stop [options]

Options:
  -c,--config (default %s) path to configuration file
]], constants.CLI.GLOBAL_KONG_CONF))

-- Check if running, will exit if not
local running, err = signal.is_running(args.config)
if not running then
  cutils.logger:error_exit(err)
end

-- Send 'quit' signal (graceful shutdown)
if signal.send_signal(args.config, signal.QUIT) then
  cutils.logger:success("Stopped")
else
  cutils.logger:error_exit("Could not gracefully stop Kong")
end
