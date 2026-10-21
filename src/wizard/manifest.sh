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
#   when         empty, or id=value to show the step only if that step was answered with value
# Adding a setting means adding one record here (and a validator if none fits).

_wm() { # id json_path type widget default_spec routes validators when title help
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
}

wizard_manifest() {
  _wm instance_name INSTANCE_NAME string input server guided \
    validate_instance_name,validate_nonempty "" \
    "Server name" \
    "Pick a short name for this server. Use only letters, numbers, hyphens and underscores."

  _wm server_kind - string \
    "radiolist:fabric=Fabric (recommended, supports performance mods)|vanilla=Vanilla (plain Minecraft, no mods)|modpack=CurseForge modpack" \
    fabric guided validate_one_of:fabric:vanilla:modpack "" \
    "Server type" \
    "Fabric is the best choice for most people. Vanilla is plain Minecraft. A modpack installs a ready-made pack from CurseForge."

  _wm curseforge_key - string password "" guided validate_nonempty server_kind=modpack \
    "CurseForge API key" \
    "Modpacks are downloaded through CurseForge, which needs a free API key from console.curseforge.com."

  _wm curseforge_pack - number input "" guided validate_curseforge_pack_id server_kind=modpack \
    "CurseForge pack ID" \
    "The number shown as Project ID on the CurseForge page of the modpack."

  _wm minecraft_version JAVA.SERVER.VANILLA.VERSION string input latest guided validate_nonempty "" \
    "Minecraft version" \
    "Type latest for the newest release, or a version such as 1.21.4."

  _wm memory - string input 4G guided validate_memory_size "" \
    "Memory" \
    "How much memory the server may use, for example 4G. Setup lowers this if your machine has less to spare."

  _wm max_players JAVA.SERVER.MAX_PLAYERS number input 10 guided validate_int_range:1:1000 "" \
    "Player slots" \
    "The most players that can be online at the same time."

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
    "Only players you add to a list may join. Choose yes if the server should be private."

  _wm optional_mods - list \
    "checklist:optional=Extra quality-of-life mods" \
    "" guided "" "" \
    "Optional mods" \
    "Select the box to also install the optional mod group. Leave it empty to keep the server lean."

  _wm backups - bool yesno true guided "" "" \
    "Automatic backups" \
    "Regular copies of your world, so you can go back if something breaks."

  _wm restart_schedule RESTART_SCHEDULE.ENABLED bool yesno false guided "" "" \
    "Scheduled restarts" \
    "Restart the server every few hours to keep it fast. It waits while players are online."

  _wm webhook NOTIFICATIONS.WEBHOOK_URL string input "" guided validate_webhook_url "" \
    "Notifications" \
    "A Discord webhook address (starts with https://) to get messages about backups and updates. Leave empty to skip."

  _wm api_wrapper API_SERVER.ENABLED bool yesno false guided "" "" \
    "Management API" \
    "Turns on a small web service that lets other tools control the server. Most people do not need it."
}
