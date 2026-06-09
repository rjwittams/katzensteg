local state = {
  elapsed = 0.0,
  frame = 0,
  mouse_x = 0,
  mouse_y = 0,
  wheel_x = 0,
  wheel_y = 0,
  last_key = "none",
  last_text = "",
  last_mouse = "none",
}

local auto_quit_after = tonumber(os.getenv("KATZENSTEG_LOVE_PROBE_SECONDS") or "")

local function mouse_buttons()
  local down = {}
  if love.mouse.isDown(1) then down[#down + 1] = "L" end
  if love.mouse.isDown(2) then down[#down + 1] = "R" end
  if love.mouse.isDown(3) then down[#down + 1] = "M" end
  if #down == 0 then return "none" end
  return table.concat(down, "+")
end

function love.load()
  love.window.setTitle("katzensteg-love-sdl3-probe")
  love.window.setMode(960, 540, {
    resizable = true,
    minwidth = 640,
    minheight = 360,
  })
  love.keyboard.setKeyRepeat(true)
end

function love.update(dt)
  state.elapsed = state.elapsed + dt
  state.frame = state.frame + 1
  state.mouse_x, state.mouse_y = love.mouse.getPosition()
  if auto_quit_after and auto_quit_after > 0 and state.elapsed >= auto_quit_after then
    love.event.quit()
  end
end

function love.keypressed(key)
  state.last_key = key
  if key == "escape" then
    love.event.quit()
  end
end

function love.textinput(text)
  state.last_text = text
end

function love.mousepressed(_, _, button)
  state.last_mouse = "down:" .. tostring(button)
end

function love.mousereleased(_, _, button)
  state.last_mouse = "up:" .. tostring(button)
end

function love.wheelmoved(dx, dy)
  state.wheel_x = state.wheel_x + dx
  state.wheel_y = state.wheel_y + dy
end

function love.draw()
  local w, h = love.graphics.getDimensions()
  local t = state.elapsed

  local bg_r = 0.12 + 0.08 * math.sin(t * 0.7)
  local bg_g = 0.10 + 0.10 * math.sin(t * 0.9 + 1.1)
  local bg_b = 0.14 + 0.08 * math.sin(t * 1.2 + 2.2)
  love.graphics.clear(bg_r, bg_g, bg_b, 1.0)

  local cx = w * 0.5 + math.cos(t * 1.4) * w * 0.18
  local cy = h * 0.5 + math.sin(t * 1.1) * h * 0.22
  local radius = 70 + 20 * math.sin(t * 2.1)
  love.graphics.setColor(0.96, 0.28, 0.22, 0.92)
  love.graphics.circle("fill", cx, cy, radius)

  local mx, my = state.mouse_x, state.mouse_y
  love.graphics.setColor(0.22, 0.92, 0.96, 1.0)
  love.graphics.line(mx - 20, my, mx + 20, my)
  love.graphics.line(mx, my - 20, mx, my + 20)

  love.graphics.setColor(1.0, 1.0, 1.0, 1.0)
  love.graphics.print("katzensteg LÖVE SDL3 smoke probe", 18, 16)
  love.graphics.print(string.format("window=%dx%d mouse=%d,%d buttons=%s", w, h, mx, my, mouse_buttons()), 18, 42)
  love.graphics.print(string.format("frame=%d time=%.2fs wheel=%d,%d", state.frame, state.elapsed, state.wheel_x, state.wheel_y), 18, 64)
  love.graphics.print(string.format("last_key=%s last_text=%s last_mouse=%s", state.last_key, state.last_text, state.last_mouse), 18, 86)
  love.graphics.print("controls: ESC quits, type/click/scroll to update state", 18, 108)
end
