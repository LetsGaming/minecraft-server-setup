# Fabric Server Mods

This setup installs a set of Fabric mods designed to enhance server performance and functionality. All mods (except optional ones) are server-side only — clients don't need to install anything to join.

## Categories

### Performance Mods

Boost server efficiency without impacting gameplay or compatibility:

* Lithium – An optimization mod for Minecraft which improves server performance significantly
* Clumps – Clumps XP orbs together to reduce lag
* C2ME – A Fabric mod designed to improve the chunk performance of Minecraft.
* Krypton – Krypton is a Fabric mod that attempts to optimize the Minecraft networking stack. 
* Let Me Despawn – Improves performance by tweaking mob despawn rules.
* Get It Together, Drops! – Adds tags and configuration options for defining how dropped items should combine.

### Utility Mods

Add backend tools or server-side features:

* Better Safe Bed – Fixes issue with being unable to sleep, even if safe
* RightClickHarvest – Allows you to harvest crops by right clicking
* Essential Commands – Configurable, permissions-backed utility commands for Fabric servers
* Chunky – Pre-generates chunks, quickly, efficiently, and safely
* FallingTree – Break down your trees by only cutting one piece of it
* Better Than Mending – A small quality of life tweak to the Mending enchantment

### Optional Mods

Nice-to-have, but not required for running or joining the server:

* Xaeros World Map / Xaeros Minimap – Real-time mapping in-game or your browser as you explore. 
  Note: To make Xaeros Mods not be required on client you need to set 'register*_status_effects = false'
* Simple Voice Chat – A working voice chat in Minecraft!
* Enhanced Groups – Adds more features to the groups of Simple Voice Chat
* JEI – Just Enough Items
* Too Cheap! – Removes the level cap in the Anvil GUI
* AntiXray – A lightweight mod that allows server owners to combat xrayers.
* Sit! – Allows player to sit on various blocks.
* AppleSkin – Food/hunger-related HUD improvements

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