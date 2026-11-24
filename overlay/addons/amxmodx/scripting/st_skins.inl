// Weapon finishes (the CS 1.6 stand-in for the CS2 armory): recolored view models made by tools/skins.py
// into models/st/<finish>/v_<weapon>.mdl. Only the owner sees them. Missing models = feature off.
// Also gives humans player models the bots never wear (HumanTint).

#define MAX_FINISH 6
#define SKIN_WEAPONS 12
new const SKIN_WPN[SKIN_WEAPONS][] = { "knife", "ak47", "m4a1", "awp", "scout", "famas", "galil", "deagle", "usp", "glock18", "mp5navy", "m3" };
new const SKIN_MDL[SKIN_WEAPONS][] = { "knife", "ak47", "m4a1", "awp", "scout", "famas", "galil", "deagle", "usp", "glock18", "mp5", "m3" };
new const SKIN_LABEL[SKIN_WEAPONS][] = { "Knife", "AK-47", "M4A1", "AWP", "Scout", "FAMAS", "Galil", "Desert Eagle", "USP", "Glock-18", "MP5", "M3" };
new const FINISH_KEY[MAX_FINISH][] = { "royalty", "gold", "neon", "ocean", "toxic", "crimson" };
new const FINISH_NAME[MAX_FINISH][] = { "Royalty", "Fire & Gold", "Neon", "Ocean", "Toxic", "Crimson" };

new g_skin[33][SKIN_WEAPONS];                 // 0 = stock, else finish + 1
new bool:g_skinsOn, bool:g_mdlOk[MAX_FINISH][SKIN_WEAPONS], g_menuWpn[33];
new g_agent[33];

skins_precache()
{
	new path[64];
	for (new f = 0; f < MAX_FINISH; f++)
		for (new w = 0; w < SKIN_WEAPONS; w++)
		{
			formatex(path, charsmax(path), "models/st/%s/v_%s.mdl", FINISH_KEY[f], SKIN_MDL[w]);
			if (!file_exists(path)) continue;
			precache_model(path);
			g_mdlOk[f][w] = true;
			g_skinsOn = true;
		}
}

skins_init()
{
	new ent[32];
	for (new w = 0; w < SKIN_WEAPONS; w++)
	{
		formatex(ent, charsmax(ent), "weapon_%s", SKIN_WPN[w]);
		RegisterHam(Ham_Item_Deploy, ent, "ham_deploy", 1);
	}
	register_srvcmd("st_skin", "srv_skin");
}

public ham_deploy(ent)
{
	if (!g_skinsOn || pev_valid(ent) != 2) return;
	new id = get_member(ent, m_pPlayer);
	if (is_user_alive(id) && !is_user_bot(id)) apply_skin(id, cs_get_weapon_id(ent));
}

skin_index(csw)
{
	new name[32]; get_weaponname(csw, name, charsmax(name));
	for (new w = 0; w < SKIN_WEAPONS; w++) if (equal(name[7], SKIN_WPN[w])) return w;
	return -1;
}

apply_skin(id, csw)
{
	new w = skin_index(csw);
	if (w < 0 || cs_get_user_shield(id)) return;
	new f = g_skin[id][w] - 1, path[64];
	if (f >= 0 && g_mdlOk[f][w]) formatex(path, charsmax(path), "models/st/%s/v_%s.mdl", FINISH_KEY[f], SKIN_MDL[w]);
	else formatex(path, charsmax(path), "models/v_%s.mdl", SKIN_MDL[w]);
	set_pev(id, pev_viewmodel2, path);
}

finish_by_key(const key[])
{
	for (new f = 0; f < MAX_FINISH; f++) if (equali(key, FINISH_KEY[f])) return f + 1;
	return equali(key, "stock") ? 0 : -1;
}

weapon_by_key(const key[])
{
	for (new w = 0; w < SKIN_WEAPONS; w++) if (equali(key, SKIN_WPN[w])) return w;
	return -1;
}

// weapon -1 = all. Saves and applies to the player if online.
set_skin(const pid[], weapon, finish)
{
	new epid[150], q[256];
	sql_escape(pid, epid, charsmax(epid));
	for (new w = 0; w < SKIN_WEAPONS; w++)
	{
		if (weapon != -1 && weapon != w) continue;
		formatex(q, charsmax(q), "INSERT OR REPLACE INTO st_skins (player_id, weapon, finish) VALUES ('%s', '%s', '%s')",
			epid, SKIN_WPN[w], finish ? FINISH_KEY[finish - 1] : "stock");
		db_exec(q);
	}
	new other[72];
	for (new id = 1; id <= MaxClients; id++)
	{
		if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id)) continue;
		player_id(id, other, charsmax(other));
		if (!equal(other, pid)) continue;
		for (new w = 0; w < SKIN_WEAPONS; w++) if (weapon == -1 || weapon == w) g_skin[id][w] = finish;
		if (is_user_alive(id)) apply_skin(id, get_user_weapon(id));
	}
}

public srv_skin()
{
	new pid[72], w[16], f[16];
	read_argv(1, pid, charsmax(pid)); read_argv(2, w, charsmax(w)); read_argv(3, f, charsmax(f));
	new wi = equal(w, "all") ? -1 : weapon_by_key(w), fi = finish_by_key(f);
	if (!pid[0] || fi < 0 || (wi < 0 && !equal(w, "all"))) { server_print("Usage: st_skin <authid> <weapon|all> <finish|stock>"); return PLUGIN_HANDLED; }
	set_skin(pid, wi, fi);
	server_print("SKIN OK");
	return PLUGIN_HANDLED;
}

load_skins(id)
{
	if (is_user_bot(id) || g_db == Empty_Handle) return;
	new pid[72], epid[150], q[256], data[1];
	player_id(id, pid, charsmax(pid));
	sql_escape(pid, epid, charsmax(epid));
	data[0] = get_user_userid(id);
	// second column: how many players have a loadout already, so each new one gets the next preset
	formatex(q, charsmax(q), "SELECT weapon, finish, 0 FROM st_skins WHERE player_id='%s' UNION ALL SELECT '', '', COUNT(DISTINCT player_id) FROM st_skins", epid);
	SQL_ThreadQuery(g_db, "skins_loaded", q, data, 1);
}

public skins_loaded(failstate, Handle:query, error[], errnum, data[], size, Float:queuetime)
{
	if (failstate != TQUERY_SUCCESS) { log_amx("[ServerTools] skins: %s", error); return; }
	new id = find_player("k", data[0]);
	if (!id) return;
	new w[16], f[16], rows, count;
	while (SQL_MoreResults(query))
	{
		SQL_ReadResult(query, 0, w, charsmax(w)); SQL_ReadResult(query, 1, f, charsmax(f));
		if (w[0])
		{
			new wi = weapon_by_key(w), fi = finish_by_key(f);
			if (wi >= 0 && fi >= 0) g_skin[id][wi] = fi;
			rows++;
		}
		else count = SQL_ReadResult(query, 2);
		SQL_NextRow(query);
	}
	if (!rows && g_skinsOn)
	{
		new pid[72]; player_id(id, pid, charsmax(pid));
		set_skin(pid, -1, 1 + count % MAX_FINISH);
		client_print_color(id, print_team_default, "^4Welcome!^1 You got the ^3%s^1 weapon finish. Change it with ^4!skins^1 or ^4!knife", FINISH_NAME[count % MAX_FINISH]);
	}
	else if (is_user_alive(id)) apply_skin(id, get_user_weapon(id));
}

// ---------- !skins / !knife ----------

skins_menu(id)
{
	if (!g_skinsOn) { client_print(id, print_chat, "Weapon finishes are not installed on this server."); return; }
	new menu = menu_create("Weapon finishes", "skins_menu_h");
	menu_additem(menu, "All weapons", "-1");
	new info[4];
	for (new w = 0; w < SKIN_WEAPONS; w++) { num_to_str(w, info, charsmax(info)); menu_additem(menu, SKIN_LABEL[w], info); }
	menu_display(id, menu);
}

public skins_menu_h(id, menu, item)
{
	new info[4], a, b;
	if (item >= 0) menu_item_getinfo(menu, item, a, info, charsmax(info), _, _, b);
	menu_destroy(menu);
	if (item >= 0) finish_menu(id, str_to_num(info));
	return PLUGIN_HANDLED;
}

finish_menu(id, weapon)
{
	if (!g_skinsOn) { client_print(id, print_chat, "Weapon finishes are not installed on this server."); return; }
	g_menuWpn[id] = weapon;
	new title[48]; formatex(title, charsmax(title), "Finish: %s", weapon < 0 ? "All weapons" : SKIN_LABEL[weapon]);
	new menu = menu_create(title, "finish_menu_h");
	menu_additem(menu, "Stock");
	for (new f = 0; f < MAX_FINISH; f++) menu_additem(menu, FINISH_NAME[f]);
	menu_setprop(menu, MPROP_PERPAGE, 0);
	menu_display(id, menu);
}

public finish_menu_h(id, menu, item)
{
	menu_destroy(menu);
	if (item < 0 || item > MAX_FINISH) return PLUGIN_HANDLED;
	new pid[72]; player_id(id, pid, charsmax(pid));
	set_skin(pid, g_menuWpn[id], item);
	client_print_color(id, print_team_default, "^4[Skins]^1 Equipped ^3%s", item ? FINISH_NAME[item - 1] : "Stock");
	return PLUGIN_HANDLED;
}

// ---------- human agents ----------

new const T_HUMAN[][] = { "leet", "arctic", "guerilla" };
new const CT_HUMAN[][] = { "gign", "gsg9", "sas" };

public apply_agent(id)
{
	if (!is_user_alive(id)) return;
	new CsTeams:team = cs_get_user_team(id);
	if (team != CS_TEAM_T && team != CS_TEAM_CT) return;
	new bool:t = team == CS_TEAM_T;
	if (is_user_bot(id)) { cs_set_user_model(id, t ? "terror" : "urban"); return; }
	if (!g_agent[id])
	{
		// lowest free slot, so friends look different from each other
		for (new s = 1; s <= MaxClients && !g_agent[id]; s++)
		{
			new bool:used = false;
			for (new i = 1; i <= MaxClients; i++) if (g_agent[i] == s) used = true;
			if (!used) g_agent[id] = s;
		}
	}
	cs_set_user_model(id, t ? T_HUMAN[(g_agent[id] - 1) % sizeof T_HUMAN] : CT_HUMAN[(g_agent[id] - 1) % sizeof CT_HUMAN]);
}
