function love.conf(t)
	t.identity                = "cornellbox-gi"
	t.version                 = "11.5"
	t.console                 = false

	t.window.title            = "Cornell Box - SSAO / SSGI / SSR in LOVE2D"
	t.window.width            = 1280
	t.window.height           = 720
	t.window.resizable        = true
	t.window.minwidth         = 640
	t.window.minheight        = 360
	t.window.vsync            = 0
	t.window.msaa             = 0
	t.window.depth            = 0
	t.window.stencil          = false
	t.window.highdpi          = false

	t.modules.joystick        = false
	t.modules.physics         = false
	t.modules.audio           = false
	t.modules.sound           = false
	t.modules.video           = false
	t.modules.touch           = false
end
