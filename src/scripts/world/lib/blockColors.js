"use strict";

/**
 * Map colours for terrain tiles: a block id to the RGB it is drawn with from above.
 * A curated table for the common blocks, rules for families (wood, stone, ore, dyed
 * blocks, stairs and slabs of something), and a neutral grey for what is neither,
 * which is what modded blocks get. Grass, foliage and water have fixed colours: no
 * biome tinting. This is orientation for a person choosing chunks, not a renderer.
 */

const DYES = {
  white: [233, 236, 236],
  orange: [240, 118, 19],
  magenta: [189, 68, 179],
  light_blue: [58, 175, 217],
  yellow: [248, 197, 39],
  lime: [112, 185, 25],
  pink: [237, 141, 172],
  gray: [62, 68, 71],
  light_gray: [142, 142, 134],
  cyan: [21, 137, 145],
  purple: [121, 42, 172],
  blue: [53, 57, 157],
  brown: [114, 71, 40],
  green: [84, 109, 27],
  red: [160, 39, 34],
  black: [20, 21, 25],
};

const WOOD = {
  oak: [162, 130, 78],
  spruce: [114, 84, 48],
  birch: [196, 179, 123],
  jungle: [160, 115, 80],
  acacia: [168, 90, 50],
  dark_oak: [66, 43, 20],
  mangrove: [117, 54, 48],
  cherry: [226, 178, 172],
  pale_oak: [225, 214, 208],
  bamboo: [193, 173, 80],
  crimson: [101, 48, 70],
  warped: [43, 105, 99],
};

const EXACT = {
  grass_block: [110, 170, 60],
  grass: [110, 170, 60],
  short_grass: [110, 170, 60],
  tall_grass: [110, 170, 60],
  fern: [96, 150, 56],
  large_fern: [96, 150, 56],
  podzol: [91, 63, 24],
  mycelium: [111, 99, 105],
  dirt: [134, 96, 67],
  coarse_dirt: [119, 85, 59],
  rooted_dirt: [144, 103, 76],
  dirt_path: [148, 122, 65],
  farmland: [110, 75, 45],
  mud: [60, 57, 60],
  clay: [160, 166, 179],
  moss_block: [89, 109, 45],
  moss_carpet: [89, 109, 45],
  stone: [125, 125, 125],
  cobblestone: [115, 115, 115],
  mossy_cobblestone: [105, 120, 100],
  granite: [149, 103, 85],
  diorite: [188, 188, 188],
  andesite: [136, 136, 136],
  tuff: [108, 109, 102],
  calcite: [223, 224, 220],
  dripstone_block: [134, 107, 92],
  deepslate: [80, 80, 83],
  cobbled_deepslate: [77, 77, 80],
  bedrock: [85, 85, 85],
  sand: [219, 207, 163],
  red_sand: [190, 102, 33],
  sandstone: [216, 203, 155],
  red_sandstone: [186, 99, 29],
  gravel: [131, 127, 126],
  snow: [249, 254, 254],
  snow_block: [249, 254, 254],
  powder_snow: [248, 253, 253],
  ice: [145, 183, 253],
  packed_ice: [141, 180, 250],
  blue_ice: [116, 167, 253],
  water: [52, 90, 200],
  bubble_column: [52, 90, 200],
  kelp: [52, 90, 150],
  kelp_plant: [52, 90, 150],
  seagrass: [52, 100, 160],
  tall_seagrass: [52, 100, 160],
  lava: [230, 100, 20],
  magma_block: [140, 60, 20],
  obsidian: [20, 18, 29],
  crying_obsidian: [32, 10, 60],
  netherrack: [111, 54, 53],
  nether_bricks: [44, 21, 26],
  soul_sand: [81, 62, 50],
  soul_soil: [75, 57, 46],
  basalt: [73, 72, 77],
  smooth_basalt: [72, 72, 78],
  blackstone: [42, 36, 41],
  glowstone: [171, 131, 84],
  shroomlight: [240, 146, 70],
  nether_wart_block: [114, 2, 2],
  warped_wart_block: [22, 119, 121],
  crimson_nylium: [130, 31, 31],
  warped_nylium: [43, 114, 101],
  end_stone: [219, 222, 158],
  purpur_block: [169, 125, 169],
  chorus_plant: [93, 57, 93],
  chorus_flower: [152, 118, 152],
  terracotta: [152, 94, 67],
  glass: [175, 213, 219],
  bricks: [150, 97, 83],
  stone_bricks: [122, 121, 122],
  crafting_table: [119, 73, 42],
  furnace: [110, 110, 110],
  chest: [162, 112, 36],
  bookshelf: [117, 89, 55],
  hay_block: [165, 139, 12],
  pumpkin: [198, 118, 24],
  melon: [141, 145, 36],
  cactus: [85, 127, 43],
  sugar_cane: [148, 192, 101],
  bamboo: [93, 144, 19],
  vine: [60, 120, 40],
  lily_pad: [32, 128, 48],
  sweet_berry_bush: [60, 100, 50],
  azalea: [101, 124, 47],
  flowering_azalea: [112, 121, 64],
  dead_bush: [107, 78, 40],
  torch: [220, 180, 90],
  rail: [125, 111, 88],
  iron_block: [220, 220, 220],
  gold_block: [249, 236, 79],
  diamond_block: [98, 237, 228],
  emerald_block: [42, 203, 87],
  lapis_block: [31, 67, 140],
  coal_block: [16, 16, 16],
  redstone_block: [175, 24, 5],
  copper_block: [192, 107, 79],
  amethyst_block: [133, 97, 191],
};

const AIR = new Set(["air", "cave_air", "void_air"]);

/** Plants and the like that a heightmap can end on but that hide what a person wants to see. */
const SEE_THROUGH = new Set(["light", "barrier", "structure_void", "moving_piston"]);

const STONE = EXACT.stone;
const NEUTRAL = [128, 128, 128];

function dyed(name) {
  for (const dye of Object.keys(DYES)) {
    if (name.startsWith(dye + "_")) return DYES[dye];
  }
  return null;
}

/**
 * The colour of a block id (with or without "minecraft:"), or null for air and anything
 * that should be looked through. Unknown blocks get a neutral grey and `known: false`.
 *
 * @returns {{rgb: number[], known: boolean} | null}
 */
function colorOf(id) {
  const name = id.includes(":") ? (id.startsWith("minecraft:") ? id.slice(10) : null) : id;
  if (name === null) return { rgb: NEUTRAL, known: false }; // another namespace: a modded block
  if (AIR.has(name) || SEE_THROUGH.has(name)) return null;
  const exact = EXACT[name];
  if (exact) return { rgb: exact, known: true };

  // Shapes of a material look like the material: oak_stairs is oak_planks.
  const shape = name.replace(/_(stairs|slab|wall|fence|fence_gate|button|pressure_plate|trapdoor|door|sign|wall_sign|hanging_sign|carpet|pane|bed|banner|wall_banner|head|skull)$/, "");
  if (shape !== name) {
    for (const candidate of [shape, `${shape}_planks`, `${shape}_block`]) {
      const base = colorOf(candidate);
      if (base?.known) return base;
    }
  }

  for (const [wood, rgb] of Object.entries(WOOD)) {
    if (name.startsWith(wood + "_") || name.startsWith("stripped_" + wood + "_")) {
      if (/_(leaves)$/.test(name)) return { rgb: [56, 120, 40], known: true };
      if (/_(log|wood|stem|hyphae)$/.test(name)) return { rgb: rgb.map((c) => Math.round(c * 0.75)), known: true };
      if (/_(planks)$/.test(name)) return { rgb, known: true };
      if (/_(sapling|propagule)$/.test(name)) return { rgb: [70, 130, 50], known: true };
      return { rgb, known: true };
    }
  }
  if (/_leaves$/.test(name)) return { rgb: [56, 120, 40], known: true };

  const dye = dyed(name);
  if (dye && /_(concrete|concrete_powder|wool|terracotta|glazed_terracotta|stained_glass|shulker_box|candle)$/.test(name)) {
    const shade = /terracotta/.test(name) ? 0.7 : 1;
    return { rgb: dye.map((c) => Math.round(c * shade)), known: true };
  }
  if (dye) return { rgb: dye, known: true };

  if (/_ore$/.test(name)) return { rgb: name.startsWith("deepslate_") ? EXACT.deepslate : STONE, known: true };
  if (/(^|_)(flower|tulip|orchid|allium|azure_bluet|cornflower|dandelion|poppy|rose|lilac|peony|sunflower|oxeye_daisy|lily_of_the_valley)($|_)/.test(name)) return { rgb: EXACT.grass_block, known: true };
  if (/deepslate/.test(name)) return { rgb: EXACT.deepslate, known: true };
  if (/(stone|brick|cobble|andesite|granite|diorite|tuff|basalt|blackstone)/.test(name)) return { rgb: STONE, known: true };
  if (/(sand)/.test(name)) return { rgb: EXACT.sand, known: true };
  if (/(nether|crimson|warped)/.test(name)) return { rgb: EXACT.netherrack, known: true };
  if (/(copper)/.test(name)) return { rgb: EXACT.copper_block, known: true };
  if (/(glass)/.test(name)) return { rgb: EXACT.glass, known: true };
  if (/(coral)/.test(name)) return { rgb: [217, 100, 120], known: true };
  return { rgb: NEUTRAL, known: false };
}

module.exports = { colorOf, AIR, DYES };
