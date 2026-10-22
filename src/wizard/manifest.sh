#!/bin/bash
# Wizard step manifest: one tab-separated record per question, printed by wizard_manifest.
#
# Fields: id, json_path, type, widget, default_spec, routes, validators, when, title, help
#   json_path    dot path in variables.json, or "-" for a step the config writer handles
#                specially (server_kind, memory, backups, optional_mods and the CurseForge
#                steps); the engine then keys the answer by the step id.
#   type         string | number | bool | list (bool answers are stored as true/false)
#   widget       input | password | yesno | menu:CHOICES | radiolist:CHOICES | checklist:CHOICES
#                where CHOICES is tag=label pairs joined by "|"
#   default_spec literal text, or detect:<function> (the function's output is used)
#   routes       comma list of default,guided
#   validators   comma list of name[:arg[:arg]]; each name is a function in validators.sh
#   when         empty, id=value to show the step only if that step was answered with value,
#                or id!=value to show it unless that step was answered with value
# Adding a setting means adding one record here (and a validator if none fits).

_wm() { # id json_path type widget default_spec routes validators when title help
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
}

wizard_manifest() {
  _wm instance_name INSTANCE_NAME string input server guided \
    validate_instance_name,validate_nonempty,validate_instance_unused "" \
    "Server name" \
    "Give this server a short name. It is used for its folder and its background service. Use only letters, numbers, hyphens and underscores."

  _wm server_kind - string \
    "radiolist:fabric=Fabric (recommended, supports performance mods)|vanilla=Vanilla (plain Minecraft, no mods)|modpack=CurseForge modpack" \
    fabric guided validate_one_of:fabric:vanilla:modpack "" \
    "Server type" \
    "Fabric is the best choice for most people: it runs Minecraft with performance mods. Vanilla is plain Minecraft with no mods. A modpack installs a ready-made pack from CurseForge."

  _wm curseforge_key - string password "" guided validate_nonempty server_kind=modpack \
    "CurseForge API key" \
    "Modpacks are downloaded through CurseForge, which needs a free API key. Create one at console.curseforge.com and paste it here (it stays hidden)."

  _wm curseforge_pack - number input "" guided validate_curseforge_pack_id server_kind=modpack \
    "CurseForge pack ID" \
    "The number shown as Project ID on the CurseForge page of the modpack."

  _wm minecraft_version JAVA.SERVER.VANILLA.VERSION string input latest guided validate_nonempty "server_kind!=modpack" \
    "Minecraft version" \
    "The Minecraft game version the server runs; players need the same one. Type latest to use the newest version that works with the default mods, or a version such as 1.21.4."

  _wm memory - string input 4G guided validate_memory_size "" \
    "Memory" \
    "How much of the computer's memory (RAM) the server may use, for example 4G. More helps with more players or mods. Setup lowers it if your machine has less to spare."

  _wm max_players JAVA.SERVER.MAX_PLAYERS number input 10 guided validate_int_range:1:1000 "" \
    "Player slots" \
    "The most players that can be online at the same time. Each extra player uses a bit more memory."

  _wm motd JAVA.SERVER.MOTD string input "A Minecraft Server" guided "" "" \
    "Server message" \
    "The line of text shown under the server name in the multiplayer list."

  _wm difficulty JAVA.SERVER.DIFFICULTY string \
    "radiolist:peaceful=Peaceful|easy=Easy|normal=Normal|hard=Hard" \
    normal guided validate_one_of:peaceful:easy:normal:hard "" \
    "Difficulty" \
    "How dangerous the world is. Normal is the standard Minecraft experience."

  _wm whitelist JAVA.SERVER.WHITELIST bool yesno false guided "" "" \
    "Whitelist" \
    "A whitelist is a list of approved players. If you choose yes, only players you add to it can join, which keeps the server private."

  _wm optional_mods - list \
    "checklist:optional=Extra quality-of-life mods" \
    "" guided "" "" \
    "Optional mods" \
    "Optional mods add small extras on top of the default mods. Select the box to install them, or leave it empty to keep the server lean."

  _wm backups - bool yesno true guided "" "" \
    "Automatic backups" \
    "Backups are regular copies of your world, so you can go back if something breaks or gets lost."

  _wm restart_schedule RESTART_SCHEDULE.ENABLED bool yesno false guided "" "" \
    "Scheduled restarts" \
    "Restart the server automatically every few hours to keep it running smoothly. It waits while players are online."

  _wm webhook NOTIFICATIONS.WEBHOOK_URL string input "" guided validate_webhook_url "" \
    "Notifications" \
    "A Discord webhook is an address that lets the server post messages about backups and updates into a Discord channel. It starts with https://. Leave it empty to skip."

  _wm api_wrapper API_SERVER.ENABLED bool yesno false guided "" "" \
    "Management API" \
    "The API wrapper is a small web service that lets other programs start, stop and manage the server. Most people do not need it, so it is off by default."
}
