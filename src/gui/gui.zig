const std = @import("std");
const Allocator = std.mem.Allocator;

const main = @import("root");
const graphics = main.graphics;
const draw = graphics.draw;
const settings = main.settings;
const vec = main.vec;
const Vec2f = vec.Vec2f;

const Button = @import("components/Button.zig");
pub const GuiComponent = @import("GuiComponent.zig");
pub const GuiWindow = @import("GuiWindow.zig");

const windowlist = @import("windows/_windowlist.zig");

var windowList: std.ArrayList(*GuiWindow) = undefined;
var hudWindows: std.ArrayList(*GuiWindow) = undefined;
pub var openWindows: std.ArrayList(*GuiWindow) = undefined;
pub var selectedWindow: ?*GuiWindow = null; // TODO: Make private.

pub fn init() !void {
	windowList = std.ArrayList(*GuiWindow).init(main.globalAllocator);
	hudWindows = std.ArrayList(*GuiWindow).init(main.globalAllocator);
	openWindows = std.ArrayList(*GuiWindow).init(main.globalAllocator);
	inline for(@typeInfo(windowlist).Struct.decls) |decl| {
		try @field(windowlist, decl.name).init();
	}
	try GuiWindow.__init();
	try Button.__init();
}

pub fn deinit() void {
	windowList.deinit();
	hudWindows.deinit();
	for(openWindows.items) |window| {
		window.onCloseFn();
	}
	openWindows.deinit();
	GuiWindow.__deinit();
	Button.__deinit();
}

pub fn addWindow(window: *GuiWindow, isHudWindow: bool) !void {
	for(windowList.items) |other| {
		if(std.mem.eql(u8, window.id, other.id)) {
			std.log.err("Duplicate window id: {s}", .{window.id});
			return;
		}
	}
	if(isHudWindow) {
		try hudWindows.append(window);
		window.showTitleBar = false;
	}
	try windowList.append(window);
}

pub fn openWindow(id: []const u8) Allocator.Error!void {
	defer updateWindowPositions();
	var wasFound: bool = false;
	for(windowList.items) |window| {
		if(std.mem.eql(u8, window.id, id)) {
			wasFound = true;
			for(openWindows.items, 0..) |_openWindow, i| {
				if(_openWindow == window) {
					_ = openWindows.swapRemove(i);
					openWindows.appendAssumeCapacity(window);
					selectedWindow = null;
					return;
				}
			}
			window.showTitleBar = true;
			try openWindows.append(window);
			window.pos = .{0, 0};
			window.size = window.contentSize;
			try window.onOpenFn();
			selectedWindow = null;
			return;
		}
	}
	std.log.warn("Could not find window with id {s}.", .{id});
}

pub fn openWindowFunction(comptime id: []const u8) *const fn() void {
	const function = struct {
		fn function() void {
			@call(.never_inline, openWindow, .{id}) catch {
				std.log.err("Couldn't open window due to out of memory error.", .{});
			};
		}
	}.function;
	return &function;
}

pub fn closeWindow(window: *GuiWindow) void {
	defer updateWindowPositions();
	if(selectedWindow == window) {
		selectedWindow = null;
	}
	for(openWindows.items, 0..) |_openWindow, i| {
		if(_openWindow == window) {
			openWindows.swapRemove(i);
		}
	}
	window.onCloseFn();
}

pub fn mainButtonPressed() void {
	selectedWindow = null;
	var selectedI: usize = 0;
	for(openWindows.items, 0..) |window, i| {
		var mousePosition = main.Window.getMousePosition();
		mousePosition -= window.pos;
		mousePosition /= @splat(2, window.scale*settings.guiScale);
		if(@reduce(.And, mousePosition >= Vec2f{0, 0}) and @reduce(.And, mousePosition < window.size)) {
			selectedWindow = window;
			selectedI = i;
		}
	}
	if(selectedWindow) |_selectedWindow| {
		_selectedWindow.mainButtonPressed();
		_ = openWindows.orderedRemove(selectedI);
		openWindows.appendAssumeCapacity(_selectedWindow);
	}
}

pub fn mainButtonReleased() void {
	var oldWindow = selectedWindow;
	selectedWindow = null;
	for(openWindows.items) |window| {
		var mousePosition = main.Window.getMousePosition();
		mousePosition -= window.pos;
		mousePosition /= @splat(2, window.scale*settings.guiScale);
		if(@reduce(.And, mousePosition >= Vec2f{0, 0}) and @reduce(.And, mousePosition < window.size)) {
			selectedWindow = window;
		}
	}
	if(selectedWindow != oldWindow) { // Unselect the window if the mouse left it.
		selectedWindow = null;
	}
	if(oldWindow) |_oldWindow| {
		_oldWindow.mainButtonReleased();
	}
}

pub fn updateWindowPositions() void {
	var wasChanged: bool = false;
	for(openWindows.items) |window| {
		const oldPos = window.pos;
		window.updateWindowPosition();
		const newPos = window.pos;
		if(vec.lengthSquare(oldPos - newPos) >= 1e-3) {
			wasChanged = true;
		}
	}
	if(wasChanged) @call(.always_tail, updateWindowPositions, .{}); // Very efficient O(n²) algorithm :P
}

pub fn updateAndRenderGui() !void {
	if(selectedWindow) |selected| {
		try selected.update();
	}
	for(openWindows.items) |window| {
		try window.render();
	}
}