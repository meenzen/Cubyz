const std = @import("std");

const main = @import("root");
const JsonElement = @import("json.zig").JsonElement;
const Neighbors = @import("chunk.zig").Neighbors;
const graphics = @import("graphics.zig");
const Shader = graphics.Shader;
const SSBO = graphics.SSBO;
const Image = graphics.Image;
const Color = graphics.Color;
const TextureArray = graphics.TextureArray;
const items = @import("items.zig");
const models = @import("models.zig");
const rotation = @import("rotation.zig");
const RotationMode = rotation.RotationMode;

pub const BlockClass = enum(u8) {
	wood,
	stone,
	sand,
	unbreakable,
	leaf,
	fluid,
	air
};

var arena = main.utils.NeverFailingArenaAllocator.init(main.globalAllocator);
const allocator = arena.allocator();

pub const maxBlockCount: usize = 65536; // 16 bit limit

pub const BlockDrop = struct {
	item: items.Item,
	amount: f32,
};

/// Ores can be found underground in veins.
/// TODO: Add support for non-stone ores.
pub const Ore = struct {
	/// average size of a vein in blocks
	size: f32,
	/// average density of a vein
	density: f32,
	/// average veins per chunk
	veins: f32,
	/// maximum height this ore can be generated
	maxHeight: i32,

	blockType: u16,

	sources: []u16,

	pub fn canCreateVeinInBlock(self: Ore, blockType: u16) bool {
		for(self.sources) |source| {
			if(blockType == source) return true;
		}
		return false;
	}
};

var _transparent: [maxBlockCount]bool = undefined;
var _id: [maxBlockCount][]u8 = undefined;
/// Time in seconds to break this block by hand.
var _hardness: [maxBlockCount]f32 = undefined;
/// Minimum pickaxe/axe/shovel power required.
var _breakingPower: [maxBlockCount]f32 = undefined;
var _solid: [maxBlockCount]bool = undefined;
var _selectable: [maxBlockCount]bool = undefined;
var _blockDrops: [maxBlockCount][]BlockDrop = undefined;
/// Meaning undegradable parts of trees or other structures can grow through this block.
var _degradable: [maxBlockCount]bool = undefined;
var _viewThrough: [maxBlockCount]bool = undefined;
var _hasBackFace: [maxBlockCount]bool = undefined;
var _blockClass: [maxBlockCount]BlockClass = undefined;
var _light: [maxBlockCount]u32 = undefined;
/// How much light this block absorbs if it is transparent
var _absorption: [maxBlockCount]u32 = undefined;
/// GUI that is opened on click.
var _gui: [maxBlockCount][]u8 = undefined;
var _mode: [maxBlockCount]*RotationMode = undefined;

var reverseIndices = std.StringHashMap(u16).init(allocator.allocator);

var size: u32 = 0;

pub var ores: main.List(Ore) = main.List(Ore).init(allocator);

var unfinishedOreSourceBlockIds: main.List([][]const u8) = undefined;

pub fn init() void {
	unfinishedOreSourceBlockIds = main.List([][]const u8).init(main.globalAllocator);
}

pub fn deinit() void {
	unfinishedOreSourceBlockIds.deinit();
}

pub fn register(_: []const u8, id: []const u8, json: JsonElement) u16 {
	if(reverseIndices.contains(id)) {
		std.log.warn("Registered block with id {s} twice!", .{id});
	}
	_id[size] = allocator.dupe(u8, id);
	reverseIndices.put(_id[size], @intCast(size)) catch unreachable;

	_mode[size] = rotation.getByID(json.get([]const u8, "rotation", "no_rotation"));
	_breakingPower[size] = json.get(f32, "breakingPower", 0);
	_hardness[size] = json.get(f32, "hardness", 1);

	_blockClass[size] = std.meta.stringToEnum(BlockClass, json.get([]const u8, "class", "stone")) orelse .stone;
	_light[size] = json.get(u32, "emittedLight", 0);
	_absorption[size] = json.get(u32, "absorbedLight", 0xffffff);
	_degradable[size] = json.get(bool, "degradable", false);
	_selectable[size] = json.get(bool, "selectable", true);
	_solid[size] = json.get(bool, "solid", true);
	_gui[size] = allocator.dupe(u8, json.get([]const u8, "GUI", ""));
	_transparent[size] = json.get(bool, "transparent", false);
	_viewThrough[size] = json.get(bool, "viewThrough", false) or _transparent[size];
	const hasFog: bool = json.get(f32, "fogDensity", 0.0) != 0.0;
	_hasBackFace[size] = hasFog and _transparent[size];

	const oreProperties = json.getChild("ore");
	if (oreProperties != .JsonNull) {
		// Extract the ids:
		const sourceBlocks = oreProperties.getChild("sources").toSlice();
		const oreIds = main.globalAllocator.alloc([]const u8, sourceBlocks.len);
		for(sourceBlocks, oreIds) |source, *oreId| {
			oreId.* = main.globalAllocator.dupe(u8, source.as([]const u8, ""));
		}
		unfinishedOreSourceBlockIds.append(oreIds);
		ores.append(Ore {
			.veins = oreProperties.get(f32, "veins", 0),
			.size = oreProperties.get(f32, "size", 0),
			.maxHeight = oreProperties.get(i32, "height", 0),
			.density = oreProperties.get(f32, "density", 0.5),
			.blockType = @intCast(size),
			.sources = &.{},
		});
	}

	size += 1;
	return @intCast(size - 1);
}

fn registerBlockDrop(typ: u16, json: JsonElement) void {
	const drops = json.toSlice();

	var result = allocator.alloc(BlockDrop, drops.len);
	result.len = 0;

	for(drops) |blockDrop| {
		var string = blockDrop.as([]const u8, "auto");
		string = std.mem.trim(u8, string, " ");
		var iterator = std.mem.split(u8, string, " ");

		var name = iterator.next() orelse continue;
		var amount: f32 = 1;
		while(iterator.next()) |next| {
			if(next.len == 0) continue; // skip multiple spaces.
			amount = std.fmt.parseFloat(f32, name) catch 1;
			name = next;
			break;
		}

		if(std.mem.eql(u8, name, "auto")) {
			name = _id[typ];
		}

		const item = items.getByID(name) orelse continue;
		result.len += 1;
		result[result.len - 1] = BlockDrop{.item = items.Item{.baseItem = item}, .amount = amount};
	}
}

pub fn finishBlocks(jsonElements: std.StringHashMap(JsonElement)) void {
	var i: u16 = 0;
	while(i < size) : (i += 1) {
		registerBlockDrop(i, jsonElements.get(_id[i]) orelse continue);
	}
	for(ores.items, unfinishedOreSourceBlockIds.items) |*ore, oreIds| {
		ore.sources = allocator.alloc(u16, oreIds.len);
		for(ore.sources, oreIds) |*source, id| {
			source.* = getByID(id);
			main.globalAllocator.free(id);
		}
		main.globalAllocator.free(oreIds);
	}
	unfinishedOreSourceBlockIds.clearRetainingCapacity();
}

pub fn reset() void {
	size = 0;
	_ = arena.reset(.free_all);
	reverseIndices = std.StringHashMap(u16).init(arena.allocator().allocator);
	std.debug.assert(unfinishedOreSourceBlockIds.items.len == 0);
	ores.clearRetainingCapacity();
}

pub fn getByID(id: []const u8) u16 {
	if(reverseIndices.get(id)) |result| {
		return result;
	} else {
		std.log.warn("Couldn't find block {s}. Replacing it with air...", .{id});
		return 0;
	}
}

pub fn hasRegistered(id: []const u8) bool {
	return reverseIndices.contains(id);
}

pub const Block = packed struct {
	typ: u16,
	data: u16,
	pub fn toInt(self: Block) u32 {
		return @as(u32, self.typ) | @as(u32, self.data)<<16;
	}
	pub fn fromInt(self: u32) Block {
		return Block{.typ=@truncate(self), .data=@intCast(self>>16)};
	}

	pub inline fn transparent(self: Block) bool {
		return _transparent[self.typ];
	}

	pub inline fn id(self: Block) []u8 {
		return _id[self.typ];
	}

	/// Time in seconds to break this block by hand.
	pub inline fn hardness(self: Block) f32 {
		return _hardness[self.typ];
	}

	/// Minimum pickaxe/axe/shovel power required.
	pub inline fn breakingPower(self: Block) f32 {
		return _breakingPower[self.typ];
	}

	pub inline fn solid(self: Block) bool {
		return _solid[self.typ];
	}

	pub inline fn selectable(self: Block) bool {
		return _selectable[self.typ];
	}

	pub inline fn blockDrops(self: Block) []BlockDrop {
		return _blockDrops[self.typ];
	}

	/// Meaning undegradable parts of trees or other structures can grow through this block.
	pub inline fn degradable(self: Block) bool {
		return _degradable[self.typ];
	}

	pub inline fn viewThrough(self: Block) bool {
		return _viewThrough[self.typ];
	}

	pub inline fn hasBackFace(self: Block) bool {
		return _hasBackFace[self.typ];
	}

	pub inline fn blockClass(self: Block) BlockClass {
		return _blockClass[self.typ];
	}

	pub inline fn light(self: Block) u32 {
		return _light[self.typ];
	}

	/// How much light this block absorbs if it is transparent.
	pub inline fn absorption(self: Block) u32 {
		return _absorption[self.typ];
	}
	
	/// GUI that is opened on click.
	pub inline fn gui(self: Block) []u8 {
		return _gui[self.typ];
	}
	
	pub inline fn mode(self: Block) *RotationMode {
		return _mode[self.typ];
	}

//	TODO:
//	/**
//	 * Fires the blocks on click event(usually nothing or GUI opening).
//	 * @param world
//	 * @param pos
//	 * @return if the block did something on click.
//	 */
//	public static boolean onClick(int block, World world, Vector3i pos) {
//		if (gui[block & TYPE_MASK] != null) {
//			GameLauncher.logic.openGUI("cubyz:workbench", new Inventory(26)); // TODO: Care about the inventory.
//			return true;
//		}
//		return false;
//	}
};


pub const meshes = struct {
	const AnimationData = extern struct {
		frames: i32,
		time: i32,
	};

	const TextureData = extern struct {
		textureIndices: [6]u32,
		absorption: u32,
		reflectivity: f32,
		fogDensity: f32,
		fogColor: u32,
	};
	var size: u32 = 0;
	var _modelIndex: [maxBlockCount]u16 = undefined;
	var textureData: [maxBlockCount]TextureData = undefined;
	/// Stores the number of textures after each block was added. Used to clean additional textures when the world is switched.
	var maxTextureCount: [maxBlockCount]u32 = undefined;
	/// Number of loaded meshes. Used to determine if an update is needed.
	var loadedMeshes: u32 = 0;

	var textureIDs: main.List([]const u8) = undefined;
	var animation: main.List(AnimationData) = undefined;
	var blockTextures: main.List(Image) = undefined;
	var emissionTextures: main.List(Image) = undefined;

	var arenaForWorld: main.utils.NeverFailingArenaAllocator = undefined;

	const sideNames = blk: {
		var names: [6][]const u8 = undefined;
		names[Neighbors.dirDown] = "texture_bottom";
		names[Neighbors.dirUp] = "texture_top";
		names[Neighbors.dirPosX] = "texture_right";
		names[Neighbors.dirNegX] = "texture_left";
		names[Neighbors.dirPosZ] = "texture_front";
		names[Neighbors.dirNegZ] = "texture_back";
		break :blk names;
	};

	var animationSSBO: ?SSBO = null;
	var textureDataSSBO: ?SSBO = null;
	var animatedTextureDataSSBO: ?SSBO = null;

	var animationShader: Shader = undefined;
	var animationUniforms: struct {
		time: c_int,
		size: c_int,
	} = undefined;

	pub var blockTextureArray: TextureArray = undefined;
	pub var emissionTextureArray: TextureArray = undefined;

	const black: Color = Color{.r=0, .g=0, .b=0, .a=255};
	const magenta: Color = Color{.r=255, .g=0, .b=255, .a=255};
	var undefinedTexture = [_]Color {magenta, black, black, magenta};
	const undefinedImage = Image{.width = 2, .height = 2, .imageData = undefinedTexture[0..]};
	var emptyTexture = [_]Color {black};
	const emptyImage = Image{.width = 1, .height = 1, .imageData = emptyTexture[0..]};

	pub fn init() void {
		animationShader = Shader.initComputeAndGetUniforms("assets/cubyz/shaders/animation_pre_processing.glsl", &animationUniforms);
		blockTextureArray = TextureArray.init();
		emissionTextureArray = TextureArray.init();
		textureIDs = main.List([]const u8).init(main.globalAllocator);
		animation = main.List(AnimationData).init(main.globalAllocator);
		blockTextures = main.List(Image).init(main.globalAllocator);
		emissionTextures = main.List(Image).init(main.globalAllocator);
		arenaForWorld = main.utils.NeverFailingArenaAllocator.init(main.globalAllocator);
	}

	pub fn deinit() void {
		if(animationSSBO) |ssbo| {
			ssbo.deinit();
		}
		if(textureDataSSBO) |ssbo| {
			ssbo.deinit();
		}
		if(animatedTextureDataSSBO) |ssbo| {
			ssbo.deinit();
		}
		animationShader.deinit();
		blockTextureArray.deinit();
		emissionTextureArray.deinit();
		textureIDs.deinit();
		animation.deinit();
		blockTextures.deinit();
		emissionTextures.deinit();
		arenaForWorld.deinit();
	}

	pub fn reset() void {
		meshes.size = 0;
		loadedMeshes = 0;
		textureIDs.clearRetainingCapacity();
		animation.clearRetainingCapacity();
		blockTextures.clearRetainingCapacity();
		emissionTextures.clearRetainingCapacity();
		_ = arenaForWorld.reset(.free_all);
	}

	pub inline fn model(block: Block) rotation.RotatedModel {
		return block.mode().model(block);
	}

	pub inline fn modelIndexStart(block: Block) u16 {
		return _modelIndex[block.typ];
	}

	pub inline fn fogDensity(block: Block) f32 {
		return textureData[block.typ].fogDensity;
	}

	pub inline fn fogColor(block: Block) u32 {
		return textureData[block.typ].fogColor;
	}

	pub fn readTexture(textureInfo: JsonElement, assetFolder: []const u8) !u31 {
		var result: u31 = undefined;
		if(textureInfo == .JsonString or textureInfo == .JsonStringOwned) {
			const resource = textureInfo.as([]const u8, "");
			var splitter = std.mem.split(u8, resource, ":");
			const mod = splitter.first();
			const id = splitter.rest();
			var buffer: [1024]u8 = undefined;
			var path = try std.fmt.bufPrint(&buffer, "{s}/{s}/blocks/textures/{s}.png", .{assetFolder, mod, id});
			// Test if it's already in the list:
			for(textureIDs.items, 0..) |other, j| {
				if(std.mem.eql(u8, other, path)) {
					result = @intCast(j);
					return result;
				}
			}
			const file = std.fs.cwd().openFile(path, .{}) catch |err| blk: {
				if(err != error.FileNotFound) {
					std.log.err("Could not open file {s}: {s}", .{path, @errorName(err)});
				}
				path = try std.fmt.bufPrint(&buffer, "assets/{s}/blocks/textures/{s}.png", .{mod, id}); // Default to global assets.
				break :blk std.fs.cwd().openFile(path, .{}) catch |err2| {
					std.log.err("File not found. Searched in \"{s}\" and also in the assetFolder \"{s}\"", .{path, assetFolder});
					return err2;
				};
			};
			file.close(); // It was only openend to check if it exists.
			// Otherwise read it into the list:
			result = @intCast(blockTextures.items.len);

			blockTextures.append(try Image.readFromFile(arenaForWorld.allocator(), path));
			@memcpy(buffer[path.len..][0.."_emission.png".len], "_emission.png");
			path.len += "_emission.png".len;
			const emissionTexture = Image.readFromFile(arenaForWorld.allocator(), path) catch Image.emptyImage;
			emissionTextures.append(emissionTexture);
			textureIDs.append(arenaForWorld.allocator().dupe(u8, path));
			animation.append(.{.frames = 1, .time = 1});
		} else if(textureInfo == .JsonObject) {
			const animationTime = textureInfo.get(i32, "time", 500);
			const textures = textureInfo.getChild("textures").toSlice();
			// Add the new textures into the list. Since this is an animation all textures that weren't found need to be replaced with undefined.
			result = @intCast(blockTextures.items.len);
			for(textures, 0..) |item, i| {
				if(i == 0) {
					animation.append(.{.frames = @intCast(textures.len), .time = animationTime});
				} else {
					animation.append(.{.frames = 1, .time = 1});
				}
				var splitter = std.mem.split(u8, item.as([]const u8, "cubyz:undefined"), ":");
				const mod = splitter.first();
				const id = splitter.rest();
				var buffer: [1024]u8 = undefined;
				var path = try std.fmt.bufPrint(&buffer, "{s}/{s}/blocks/textures/{s}.png", .{assetFolder, mod, id});
				const file = std.fs.cwd().openFile(path, .{}) catch |err| blk: {
					if(err != error.FileNotFound) {
						std.log.err("Could not open file {s}: {s}", .{path, @errorName(err)});
					}
					path = try std.fmt.bufPrint(&buffer, "assets/{s}/blocks/textures/{s}.png", .{mod, id}); // Default to global assets.
					break :blk std.fs.cwd().openFile(path, .{}) catch |err2| {
						std.log.err("File not found. Searched in \"{s}\" and also in the assetFolder \"{s}\"", .{path, assetFolder});
						return err2;
					};
				};
				file.close(); // It was only openend to check if it exists.

				blockTextures.append(try Image.readFromFile(arenaForWorld.allocator(), path));
				@memcpy(buffer[path.len..][0.."_emission.png".len], "_emission.png");
				path.len += "_emission.png".len;
				const emissionTexture = Image.readFromFile(arenaForWorld.allocator(), path) catch Image.emptyImage;
				emissionTextures.append(emissionTexture);
				textureIDs.append(arenaForWorld.allocator().dupe(u8, path));
			}
		} else {
			return error.NotSpecified;
		}
		return result;
	}

	pub fn getTextureIndices(json: JsonElement, assetFolder: []const u8, textureIndicesRef: []u32) void {
		const defaultIndex = readTexture(json.getChild("texture"), assetFolder) catch 0;
		for(textureIndicesRef, sideNames) |*ref, name| {
			const textureInfo = json.getChild(name);
			ref.* = readTexture(textureInfo, assetFolder) catch defaultIndex;
		}
	}

	pub fn register(assetFolder: []const u8, _: []const u8, json: JsonElement) void {
		_modelIndex[meshes.size] = models.getModelIndex(json.get([]const u8, "model", "cube"));

		// The actual model is loaded later, in the rendering thread.
		// But textures can be loaded here:

		getTextureIndices(json, assetFolder, &textureData[meshes.size].textureIndices);
		textureData[meshes.size].reflectivity = json.get(f32, "reflectivity", 0);
		textureData[meshes.size].absorption = json.get(u32, "absorption", 0xffffff);
		textureData[meshes.size].fogDensity = json.get(f32, "fogDensity", 0.0);
		textureData[meshes.size].fogColor = json.get(u32, "fogColor", 0xffffff);

		maxTextureCount[meshes.size] = @intCast(textureIDs.items.len);

		meshes.size += 1;
	}

// TODO: (this one requires thinking about the allocated memory!)
//	public static void reloadTextures() {
//		for(int i = 0; i < blockTextures.size(); i++) {
//			try {
//				blockTextures.set(i, ImageIO.read(new File(textureIDs.get(i).replace(":animation", ""))));
//			} catch(IOException e) {
//				Logger.warning("Could not read image from path "+textureIDs.get(i));
//				Logger.warning(e);
//				blockTextures.set(i, blockTextures.get(0));
//			}
//		}
//		generateTextureArray();
//	}


// TODO:
//	public static void loadMeshes() {
//		// Goes through all meshes that were newly added:
//		for(; loadedMeshes < size; loadedMeshes++) {
//			if (meshes[loadedMeshes] == null) {
//				meshes[loadedMeshes] = Meshes.cachedDefaultModels.get(models[loadedMeshes]);
//				if (meshes[loadedMeshes] == null) {
//					if(models[loadedMeshes].isEmpty())
//						continue;
//					Resource rs = new Resource(models[loadedMeshes]);
//					meshes[loadedMeshes] = new Mesh(ModelLoader.loadModel(rs, "assets/" + rs.getMod() + "/models/3d/" + rs.getID()));
//					Meshes.cachedDefaultModels.put(models[loadedMeshes], meshes[loadedMeshes]);
//				}
//			}
//		}
//	}

	pub fn preProcessAnimationData(time: u32) void {
		animationShader.bind();
		graphics.c.glUniform1ui(animationUniforms.time, time);
		graphics.c.glUniform1ui(animationUniforms.size, @intCast(meshes.size));
		graphics.c.glDispatchCompute(@divFloor(meshes.size + 63, 64), 1, 1); // TODO: Replace with @divCeil once available
		graphics.c.glMemoryBarrier(graphics.c.GL_SHADER_STORAGE_BARRIER_BIT);
	}

	pub fn generateTextureArray() void {
		const c = graphics.c;
		blockTextureArray.generate(blockTextures.items, true);
		if(main.settings.anisotropicFiltering) {
			c.glTexParameterf(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_MAX_ANISOTROPY, 16);
		}
		emissionTextureArray.generate(emissionTextures.items, true);
		if(main.settings.anisotropicFiltering) {
			c.glTexParameterf(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_MAX_ANISOTROPY, 16);
		}

		// Also generate additional buffers:
		if(animationSSBO) |ssbo| {
			ssbo.deinit();
		}
		if(textureDataSSBO) |ssbo| {
			ssbo.deinit();
		}
		if(animatedTextureDataSSBO) |ssbo| {
			ssbo.deinit();
		}
		animationSSBO = SSBO.initStatic(AnimationData, animation.items);
		animationSSBO.?.bind(0);
		textureDataSSBO = SSBO.initStatic(TextureData, textureData[0..meshes.size]);
		textureDataSSBO.?.bind(6);
		animatedTextureDataSSBO = SSBO.initStatic(TextureData, textureData[0..meshes.size]);
		animatedTextureDataSSBO.?.bind(1);
	}
};
