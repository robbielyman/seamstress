--- osc
-- @module osc

--[[
  based on norns' osc.lua
  norns osc.lua first committed by @artfwo April 17, 2018
  rewritten for seamstress by @ryleelyman April 30, 2023
]]

local osc = {
  methods = {},
}

--- callback executed when seamstress receives OSC
-- overwrite in user scripts
-- @tparam string path an osc path `/like/this`
-- @tparam table args arguments from the OSC message
-- @tparam {host,port} from table containing sender information
-- @function osc.event
function osc.event(path, args, from) end

--- send OSC message
-- @tparam[opt] {host,port} to address (both strings)
-- @tparam string path an osc path `/like/this`
-- @tparam[opt] table args an array of arguments to the OSC message
function osc.send(to, path, args)
  if path == nil and args == nil then
    _seamstress.osc_send({ "127.0.0.1", _seamstress.remote_port }, to, {})
  elseif args == nil and type(to) == "string" then
    _seamstress.osc_send({ "127.0.0.1", _seamstress.remote_port }, to, path)
  elseif args == nil then
    _seamstress.osc_send(to, path, {})
  else
    _seamstress.osc_send(to, path, args)
  end
end

--- registers OSC handler
-- an alternative to complex `osc.event` functions;
-- register a lua function that will respond to only the given path
-- (and, optionally, args matching the typespec)
-- @tparam string path an osc path `/like/this`
-- @tparam function fn a lua function that handles messages matching the path
-- @tparam[opt] string typespec a list of characters specifying the types expected by fn
-- eg. `"iifs"` for two integers, a floating point number and a string
function osc.register(path, fn, typespec)
  local idx
  if typespec then
    idx = _seamstress.osc_register(path, typespec)
  else
    idx = _seamstress.osc_register(path)
  end
  osc.methods[idx] = fn
end

--- unregisters OSC handler
-- unregisters ALL functions that match the given path (or typespec); use responsibly :)
-- @tparam string path an osc path `/like/this`
-- @tparam[opt] string typespec a list of characters specifying the types expected by the function.
function osc.delete(path, typespec)
  if typespec then
    _seamstress.osc_delete(path, typespec)
  else
    _seamstress.osc_delete(path)
  end
end

_seamstress.osc = {}

local function param_handler(path, args)
  local address_parts = {}
  local osc_pset_id = ""
  local osc_param_id
  local osc_param_value

  for part in path:gmatch("[^/]+") do
    table.insert(address_parts, part)
  end

  if 1 < #address_parts and #address_parts < 4 then
    if #address_parts == 3 then
      osc_pset_id = address_parts[2]
      osc_param_id = address_parts[3]
    else
      osc_param_id = address_parts[2]
    end

    osc_param_value = args[1]
    if osc_param_value == nil then
      error("osc parameter value is not set")
    end

    for pset_id, pset in pairs(paramset.sets) do
      if pset_id == osc_pset_id then
        local param = pset:lookup_param(osc_param_id)

        if param.id == osc_param_id then
          param:set(osc_param_value)
        end
      end
    end
  end
end

function _seamstress.osc.event(path, args, from)
  if osc.event ~= nil then
    osc.event(path, args, from)
  end
  if util.string_starts(path, "/param") then
    param_handler(path, args)
  end
end

function _seamstress.osc.method(index, ...)
  if osc.methods[index] ~= nil then
    osc.methods[index](...)
  end
end

return osc
