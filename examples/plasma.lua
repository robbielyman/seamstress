#!/opt/homebrew/bin/lua -i

seamstress = require 'seamstress'

-- plasma.lua
-- based on a script of the same name written for monome norns
-- by @tehn---thanks, Brian, for the gift of inspiration

local floor = math.floor
local abs = math.abs
local sin = math.sin
local cos = math.cos

t = 0
a = 3.0
b = 5.0
c = 1.0
d = 1.1
time_scale = 0.1

f = function(x, y)
  return abs(floor(16 * (sin(x / a + t * c) + cos(y / b + t * d)))) % 16
end

seamstress.event.addSubscriber({ 'monome', 'grid', 'add' }, function(_, grid)
  grid:connect()
  timer = seamstress.Timer(function(_, dt)
    t = t + (dt * time_scale)
    for x = 1, 16 do
      for y = 1, 16 do
        grid:led(x, y, f(x, y))
      end
    end
    grid:refresh()
  end, 1 / 60)
end)

function start(port_num)
  m = require 'seamstress.monome'(port_num)
end
