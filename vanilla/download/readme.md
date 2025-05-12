# Fabric Server Mods

This setup installs a set of Fabric mods designed to enhance server performance and functionality. All mods (except optional ones) are server-side only — clients don't need to install anything to join.

## Categories

### Performance Mods

Boost server efficiency without impacting gameplay or compatibility:

* Clumps – Clumps XP orbs together to reduce lag
* Lithium – An optimization mod for Minecraft which improves server performance significantly
* Smooth Chunk Save – Enables lag-free continuous chunk saving, increasing server TPS
* Connectivity - Fix Login timeouts, Packet sizes errors, Payloads errors, ghostblocks and more.
* Krypton - Krypton is a Fabric mod that attempts to optimize the Minecraft networking stack. 
* ScalableLux - A Fabric mod based on Starlight that improves the performance of light updates in Minecraft.
* Let Me Despawn - Improves performance by tweaking mob despawn rules.
* Get It Together, Drops! - Adds tags and configuration options for defining how dropped items should combine.

### Utility Mods

Add backend tools or server-side features:

* Better Safe Bed – Fixes issue with being unable to sleep, even if safe
* DarkSleep – Changes sleep percantage to progress the night
* RightClickHarvest - Allows you to harvest crops by right clicking
* Essential Commands - Configurable, permissions-backed utility commands for Fabric servers
* Login Protection - Protects the player during login from any harm
* Chunky – Pre-generates chunks, quickly, efficiently, and safely
* FallingTree - Break down your trees by only cutting one piece of it
* Better Than Mending - A small quality of life tweak to the Mending enchantment

### Optional Mods

Nice-to-have, but not required for running or joining the server:

* JourneyMap – Real-time mapping in-game or your browser as you explore.
* Simple Voice Chat – A working voice chat in Minecraft!
* REI - Roughly Enough Items

## Configuration

Edit variables.json in the root directory to choose which mods to install:

```json
"MODS": {
  "PERFORMANCE_MODS": true,
  "UTILITY_MODS": true,
  "OPTIONAL_MODS": false
}
```
Change false to true to include optional mods.

### Note

A mod may have required dependencies to run, in this case these mods will be installed aswell.