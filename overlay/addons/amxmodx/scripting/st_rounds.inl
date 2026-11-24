// Site round modes (port of the CS2 Rounds.cs), built on configs/sites/<map>.ini (tools/sites.py):
//   retakes: bomb already planted on a random site; Ts hold it, CTs retake from the entrances.
//   rush:    Ts start at the entrances of a random site and rush it (other site disabled); CTs hold.
// Everyone gets a free rifle loadout + utility each round. Bots fill teams as usual.

#define MAX_SPOTS 16
enum { SPOT_PLANT, SPOT_SITE, SPOT_ENTRANCE };

new Float:g_spot[2][3][MAX_SPOTS][4], g_spotCount[2][3]; // [site][kind][n] = x y z yaw
new g_spotNode[2][MAX_SPOTS]; // YaPB node of each plant spot
new bool:g_spotsLoaded, g_site, g_planter, bool:g_bombDown;
new const SITE_NAME[][] = { "A", "B" };

bool:mode_is(const key[]) return bool:equal(g_modeKey[g_mode], key);
bool:site_mode() return mode_is("retakes") || mode_is("rush");

rounds_init()
{
	RegisterHookChain(RG_CSGameRules_RestartRound, "hc_restart_round", 1);
	RegisterHookChain(RG_CSGameRules_OnRoundFreezeEnd, "hc_freeze_end", 1);
	set_task(0.5, "bot_rush_plant", _, _, _, "b");
	load_spots();
}

load_spots()
{
	new path[160], map[32];
	get_mapname(map, charsmax(map));
	get_configsdir(path, charsmax(path));
	format(path, charsmax(path), "%s/sites/%s.ini", path, map);
	new f = fopen(path, "rt");
	if (!f) return;
	new line[96], s[4], k[4], x[12], y[12], z[12], a[12], nd[8];
	while (fgets(f, line, charsmax(line)))
	{
		trim(line);
		if (!line[0] || line[0] == ';') continue;
		if (parse(line, s, 3, k, 3, x, 11, y, 11, z, 11, a, 11, nd, 7) < 7) continue;
		new site = s[0] == 'B' ? 1 : 0;
		new kind = k[0] == 'P' ? SPOT_PLANT : (k[0] == 'S' ? SPOT_SITE : SPOT_ENTRANCE);
		new n = g_spotCount[site][kind];
		if (n >= MAX_SPOTS) continue;
		g_spot[site][kind][n][0] = str_to_float(x);
		g_spot[site][kind][n][1] = str_to_float(y);
		g_spot[site][kind][n][2] = str_to_float(z);
		g_spot[site][kind][n][3] = str_to_float(a);
		if (kind == SPOT_PLANT) g_spotNode[site][n] = str_to_num(nd);
		g_spotCount[site][kind]++;
	}
	fclose(f);
	g_spotsLoaded = true;
	for (new i = 0; i < 2; i++) for (new j = 0; j < 3; j++) if (!g_spotCount[i][j]) g_spotsLoaded = false;
}

public hc_restart_round()
{
	g_roundLive = true;
	g_bombDown = false;
	g_planter = 0;
	server_cmd("yb_debug_goal -1");
	if (!site_mode()) return;
	set_task(0.1, "setup_site_round");
}

public setup_site_round()
{
	if (!site_mode()) return;
	new modeName[16]; copy(modeName, charsmax(modeName), mode_is("retakes") ? "Retakes" : "Rush");
	if (!g_spotsLoaded)
	{
		client_print_color(0, print_team_default, "^3[%s]^1 No site spawns for this map, playing normally.", modeName);
		return;
	}
	g_site = random(2);
	new ts[32], cts[32], nt, nct;
	for (new id = 1; id <= MaxClients; id++)
	{
		if (!is_user_alive(id) || is_user_hltv(id)) continue;
		switch (cs_get_user_team(id))
		{
			case CS_TEAM_T: ts[nt++] = id;
			case CS_TEAM_CT: cts[nct++] = id;
		}
	}
	shuffle(ts, nt); shuffle(cts, nct);
	new lead = 0; // human T first: more fun to plant/defend your own bomb
	for (new i = 0; i < nt && !lead; i++) if (!is_user_bot(ts[i])) lead = ts[i];
	if (!lead && nt) lead = ts[0];

	if (mode_is("retakes"))
	{
		g_planter = lead;
		place_team(ts, nt, SPOT_SITE, lead);
		place_team(cts, nct, SPOT_ENTRANCE, 0);
	}
	else
	{
		place_team(ts, nt, SPOT_ENTRANCE, 0);
		place_team(cts, nct, SPOT_SITE, 0);
	}
	set_bomb_targets(mode_is("rush") ? g_site : -1);

	for (new i = 0; i < nt; i++) site_loadout(ts[i], true);
	for (new i = 0; i < nct; i++) site_loadout(cts[i], false);
	if (mode_is("rush") && lead) give_c4(lead);

	new bool:retakes = mode_is("retakes");
	for (new id = 1; id <= MaxClients; id++)
	{
		if (!is_user_alive(id) || is_user_bot(id)) continue;
		new bool:t = cs_get_user_team(id) == CS_TEAM_T;
		if (t) set_hudmessage(242, 177, 52, -1.0, 0.3, 0, 0.0, 4.0, 0.1, 0.4, 4);
		else set_hudmessage(77, 163, 255, -1.0, 0.3, 0, 0.0, 4.0, 0.1, 0.4, 4);
		show_hudmessage(id, "%s bombsite %s!", t ? (retakes ? "Hold" : "Rush") : (retakes ? "Retake" : "Defend"), SITE_NAME[g_site]);
	}
	client_print_color(0, print_team_default, "^3[%s]^1 Bombsite ^4%s^1: Ts %s, CTs %s.", modeName, SITE_NAME[g_site],
		retakes ? "hold" : "rush", retakes ? "retake" : "defend");
	server_print("[SITE] %s bombsite %s (%d T, %d CT)", modeName, SITE_NAME[g_site], nt, nct);
}

shuffle(a[], n)
{
	for (new i = n - 1; i > 0; i--) { new j = random(i + 1), t = a[i]; a[i] = a[j]; a[j] = t; }
}

place_team(const team[], n, kind, planter)
{
	new order[MAX_SPOTS], cnt = g_spotCount[g_site][kind], used = 0;
	for (new i = 0; i < cnt; i++) order[i] = i;
	shuffle(order, cnt);
	for (new i = 0; i < n; i++)
	{
		if (team[i] == planter) { teleport(planter, g_spot[g_site][SPOT_PLANT][random(g_spotCount[g_site][SPOT_PLANT])]); continue; }
		// more players than spots: keep them where they spawned instead of stacking them
		if (used < cnt) teleport(team[i], g_spot[g_site][kind][order[used++]]);
	}
}

teleport(id, const Float:spot[4])
{
	new Float:o[3], Float:a[3], Float:zero[3];
	o[0] = spot[0]; o[1] = spot[1]; o[2] = spot[2] + 4.0;
	a[1] = spot[3];
	set_pev(id, pev_velocity, zero);
	engfunc(EngFunc_SetOrigin, id, o);
	set_pev(id, pev_angles, a);
	set_pev(id, pev_v_angle, a);
	set_pev(id, pev_fixangle, 1);
}

// Rush: only the chosen site accepts the bomb. site -1 = both.
set_bomb_targets(site)
{
	new ent = -1, Float:mn[3], Float:mx[3], Float:c[3];
	for (new k = 0; k < 2; k++)
	{
		ent = -1;
		while ((ent = engfunc(EngFunc_FindEntityByString, ent, "classname", k ? "info_bomb_target" : "func_bomb_target")) > 0)
		{
			pev(ent, pev_absmin, mn); pev(ent, pev_absmax, mx);
			for (new i = 0; i < 3; i++) c[i] = (mn[i] + mx[i]) / 2.0;
			new mine = site_dist(0, c) <= site_dist(1, c) ? 0 : 1;
			set_pev(ent, pev_solid, (site == -1 || site == mine) ? SOLID_TRIGGER : SOLID_NOT);
			new Float:o[3]; pev(ent, pev_origin, o);
			engfunc(EngFunc_SetOrigin, ent, o); // relink
		}
	}
}

Float:site_dist(site, const Float:c[3])
{
	new Float:best = 999999.0;
	for (new i = 0; i < g_spotCount[site][SPOT_PLANT]; i++)
	{
		new Float:d = spot_dist(g_spot[site][SPOT_PLANT][i], c);
		if (d < best) best = d;
	}
	return best;
}

Float:spot_dist(const Float:s[4], const Float:o[3])
	return floatsqroot((s[0] - o[0]) * (s[0] - o[0]) + (s[1] - o[1]) * (s[1] - o[1]) + (s[2] - o[2]) * (s[2] - o[2]));

give_c4(id)
{
	rg_give_item(id, "weapon_c4");
	cs_set_user_plant(id, 1, 1);
}

site_loadout(id, bool:t)
{
	rg_remove_all_items(id);
	rg_give_item(id, "weapon_knife");
	rg_give_item(id, t ? "weapon_glock18" : "weapon_usp");
	rg_set_user_bpammo(id, t ? WEAPON_GLOCK18 : WEAPON_USP, t ? 120 : 100);
	new nade = random(3);
	if (nade == 0) rg_give_item(id, "weapon_smokegrenade");
	else if (nade == 1) rg_give_item(id, "weapon_hegrenade");
	if (nade == 2 || random(2)) rg_give_item(id, "weapon_flashbang");
	// One in six gets an AWP, the rest rifles.
	if (random(6) == 0) { rg_give_item(id, "weapon_awp"); rg_set_user_bpammo(id, WEAPON_AWP, 30); }
	else if (t) { rg_give_item(id, "weapon_ak47"); rg_set_user_bpammo(id, WEAPON_AK47, 90); }
	else { rg_give_item(id, "weapon_m4a1"); rg_set_user_bpammo(id, WEAPON_M4A1, 90); }
	rg_set_user_armor(id, 100, ARMOR_VESTHELM);
	if (!t) rg_give_defusekit(id);
}

public hc_freeze_end()
{
	if (!site_mode() || !g_spotsLoaded) return;
	if (mode_is("retakes")) { auto_plant(g_planter); return; }
	// Rush: send every bot to the chosen site until the bomb is down.
	server_cmd("yb_debug_goal %d", g_spotNode[g_site][random(g_spotCount[g_site][SPOT_PLANT])]);
}

// Bots do not know which site was picked, so a bot carrying the bomb plants as soon as it
// reaches that site's plant spots (humans plant normally).
public bot_rush_plant()
{
	if (!mode_is("rush") || !g_spotsLoaded || g_bombDown || !g_roundLive || get_member_game(m_bFreezePeriod)) return;
	new Float:o[3];
	for (new id = 1; id <= MaxClients; id++)
	{
		if (!is_user_alive(id) || !is_user_bot(id) || cs_get_user_team(id) != CS_TEAM_T || !user_has_weapon(id, CSW_C4)) continue;
		pev(id, pev_origin, o);
		for (new i = 0; i < g_spotCount[g_site][SPOT_PLANT]; i++)
		{
			if (spot_dist(g_spot[g_site][SPOT_PLANT][i], o) > 220.0) continue;
			rg_remove_item(id, "weapon_c4");
			cs_set_user_plant(id, 0, 0);
			auto_plant(id);
			return;
		}
	}
}

auto_plant(id)
{
	if (g_bombDown) return;
	if (!is_user_alive(id) || cs_get_user_team(id) != CS_TEAM_T)
	{
		id = 0;
		for (new i = 1; i <= MaxClients && !id; i++) if (is_user_alive(i) && cs_get_user_team(i) == CS_TEAM_T) id = i;
		if (!id) return;
	}
	new Float:o[3], Float:ang[3], Float:end[3];
	if (mode_is("retakes"))
	{
		// On a plant spot, also when the planter already walked off during the freeze time.
		new Float:best = 999999.0, n = 0, Float:p[3];
		pev(id, pev_origin, p);
		for (new i = 0; i < g_spotCount[g_site][SPOT_PLANT]; i++)
		{
			new Float:d = spot_dist(g_spot[g_site][SPOT_PLANT][i], p);
			if (d < best) { best = d; n = i; }
		}
		for (new i = 0; i < 3; i++) o[i] = g_spot[g_site][SPOT_PLANT][n][i];
	}
	else pev(id, pev_origin, o);

	// drop it on the floor
	end = o; end[2] -= 128.0;
	new tr = create_tr2();
	engfunc(EngFunc_TraceLine, o, end, IGNORE_MONSTERS, id, tr);
	get_tr2(tr, TR_vecEndPos, end);
	free_tr2(tr);

	new bomb = rg_plant_bomb(id, end, ang);
	if (bomb <= 0) { server_print("[SITE] plant failed"); return; }
	g_bombDown = true;
	server_cmd("yb_debug_goal -1");
	// Same announcements a normal plant makes: HUD/radar, radio voice, and YaPB (which hooks the text message).
	emessage_begin(MSG_BROADCAST, get_user_msgid("BombDrop"));
	ewrite_coord(floatround(end[0])); ewrite_coord(floatround(end[1])); ewrite_coord(floatround(end[2]));
	ewrite_byte(1);
	emessage_end();
	emessage_begin(MSG_BROADCAST, get_user_msgid("TextMsg"));
	ewrite_byte(print_center); ewrite_string("#Bomb_Planted");
	emessage_end();
	emessage_begin(MSG_BROADCAST, get_user_msgid("SendAudio"));
	ewrite_byte(0); ewrite_string("%!MRAD_BOMBPL"); ewrite_short(100);
	emessage_end();
	new name[32]; get_user_name(id, name, charsmax(name));
	server_print("[SITE] %s auto-planted on %s", name, SITE_NAME[g_site]);
}
