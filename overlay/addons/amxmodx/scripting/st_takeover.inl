// Bot takeover (port of the CS2 Takeover.cs): a dead human spectating an alive bot teammate presses E
// (or types !takeover) and continues as that bot: same spot, view, health, armor, weapons and ammo.
// The bot is removed silently (no kill feed, no stats). Round modes only.

new bool:g_takeover = true, bool:g_silent[33], bool:g_usePrev[33];

takeover_init()
{
	register_forward(FM_CmdStart, "fw_cmd_start");
	set_task(0.8, "takeover_hint", _, _, _, "b");
}

bool:takeover_allowed()
{
	if (!g_takeover || !g_roundLive || g_changing) return false;
	// Only where dead players stay dead, not Arms Race or Deathmatch.
	return !mode_is("ar") && !mode_is("dm");
}

spectated_bot(id)
{
	if (!is_user_connected(id) || is_user_alive(id) || is_user_bot(id)) return 0;
	new mode = pev(id, pev_iuser1);
	if (mode == 0 || mode == 3) return 0; // not spectating / free roam
	new bot = pev(id, pev_iuser2);
	if (bot < 1 || bot > MaxClients || !is_user_alive(bot) || !is_user_bot(bot)) return 0;
	return cs_get_user_team(bot) == cs_get_user_team(id) ? bot : 0;
}

public fw_cmd_start(id, uc, seed)
{
	if (is_user_alive(id) || is_user_bot(id)) { g_usePrev[id] = true; return FMRES_IGNORED; }
	new bool:use = bool:(get_uc(uc, UC_Buttons) & IN_USE);
	new bool:was = g_usePrev[id];
	g_usePrev[id] = use;
	if (use && !was && takeover_allowed()) try_takeover(id, true);
	return FMRES_IGNORED;
}

public takeover_hint()
{
	if (!takeover_allowed()) return;
	new name[32], bot;
	for (new id = 1; id <= MaxClients; id++)
		if ((bot = spectated_bot(id)))
		{
			get_user_name(bot, name, charsmax(name));
			client_print(id, print_center, "Press E to take over %s", name);
		}
}

takeover_fail(id, bool:quiet, const why[])
{
	if (!quiet) client_print_color(id, print_team_default, "^3[Takeover]^1 %s", why);
}

try_takeover(id, bool:quiet)
{
	if (!g_takeover) { takeover_fail(id, quiet, "Takeover is turned off."); return; }
	if (!takeover_allowed()) { takeover_fail(id, quiet, "Only in round modes, during a live round."); return; }
	if (is_user_alive(id)) { takeover_fail(id, quiet, "You are alive."); return; }
	new bot = spectated_bot(id);
	if (!bot) { takeover_fail(id, quiet, "Spectate an alive bot on your team first."); return; }
	do_takeover(id, bot);
}

do_takeover(id, bot)
{
	// Snapshot the bot before anything changes.
	new Float:o[3], Float:ang[3], Float:vel[3], Float:hp, CsArmorType:atype;
	pev(bot, pev_origin, o); pev(bot, pev_v_angle, ang); pev(bot, pev_velocity, vel); pev(bot, pev_health, hp);
	new armor = cs_get_user_armor(bot, atype);
	new bool:ducked = bool:(pev(bot, pev_flags) & FL_DUCKING);
	new bool:kit = bool:cs_get_user_defuse(bot), bool:c4 = bool:user_has_weapon(bot, CSW_C4);
	new bool:nvg = bool:cs_get_user_nvg(bot);
	new held = get_user_weapon(bot);
	new wpns[32], num, clip[32], bp[32], botName[32], name[32];
	get_user_weapons(bot, wpns, num);
	for (new i = 0; i < num; i++)
	{
		new a, b; get_user_ammo(bot, wpns[i], a, b);
		clip[i] = a; bp[i] = b;
	}
	get_user_name(bot, botName, charsmax(botName));
	get_user_name(id, name, charsmax(name));

	// Human first, so the team never has zero alive players (would end the round).
	rg_round_respawn(id);
	if (!is_user_alive(id)) return;

	// Remove the bot: strip first so nothing drops, then a silent suicide.
	new deaths = cs_get_user_deaths(bot);
	g_silent[bot] = true;
	if (c4) cs_set_user_plant(bot, 0, 0);
	rg_remove_all_items(bot);
	user_silentkill(bot, 1);
	cs_set_user_deaths(bot, deaths);
	set_pev(bot, pev_effects, pev(bot, pev_effects) | EF_NODRAW);
	g_silent[bot] = false;

	rg_remove_all_items(id);
	rg_give_item(id, "weapon_knife");
	new wname[32];
	for (new i = 0; i < num; i++)
	{
		if (wpns[i] == CSW_KNIFE || wpns[i] == CSW_C4) continue;
		get_weaponname(wpns[i], wname, charsmax(wname));
		new ent = rg_give_item(id, wname);
		if (ent > 0 && clip[i] >= 0) cs_set_weapon_ammo(ent, clip[i]);
		cs_set_user_bpammo(id, wpns[i], bp[i]);
	}
	if (c4) give_c4(id);
	if (kit) rg_give_defusekit(id);
	if (nvg) cs_set_user_nvg(id, 1);
	cs_set_user_armor(id, armor, atype);
	set_pev(id, pev_health, hp);

	if (ducked)
	{
		static const Float:dmin[3] = { -16.0, -16.0, -18.0 }, Float:dmax[3] = { 16.0, 16.0, 18.0 };
		set_pev(id, pev_flags, pev(id, pev_flags) | FL_DUCKING);
		set_pev(id, pev_bInDuck, 0);
		engfunc(EngFunc_SetSize, id, dmin, dmax);
	}
	engfunc(EngFunc_SetOrigin, id, o);
	set_pev(id, pev_velocity, vel);
	ang[2] = 0.0;
	set_pev(id, pev_angles, ang); set_pev(id, pev_v_angle, ang);
	set_pev(id, pev_fixangle, 1);
	if (held > 0) { get_weaponname(held, wname, charsmax(wname)); engclient_cmd(id, wname); }

	client_print_color(0, print_team_default, "^3[Takeover]^1 %s took over ^4%s", name, botName);
	server_print("[TAKEOVER] %s took over %s", name, botName);
}
