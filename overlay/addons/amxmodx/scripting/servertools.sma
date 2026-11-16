/*
 * ServerTools for CS 1.6: port of the CS2 ServerTools plugin.
 *  - Mode + map chat vote near the end of each match (type the number), switches 5s after the end
 *  - Modes: ar (GunGame), dm (ReGameDLL deathmatch), casual, comp. Config: configs/servertools.ini
 *  - Bots (YaPB) fill to N players, difficulty 0-3
 *  - Fun toggles: low gravity, headshot only, speed, adaptive bots, kill announcer, player colors
 *  - Stats in SQLite (data/sqlite3/servertools.sq3) for the web panel; st_state prints JSON for it
 * State that must survive map changes (mode, bots, toggles) lives in localinfo.
 */
#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <fun>
#include <fakemeta>
#include <hamsandwich>
#include <sqlx>
#include <json>

#pragma dynamic 32768

#define MAX_MODES 6
#define MAX_MAPS 32
#define TASK_VOTE 7100
#define TASK_SWITCH 7200
#define TASK_NEAREND 7300

enum { PH_IDLE, PH_MODEVOTE, PH_MAPVOTE, PH_DECIDED };
new const PHASE_NAMES[][] = { "Idle", "ModeVote", "MapVote", "Decided" };

new g_modeKey[MAX_MODES][12], g_modeName[MAX_MODES][32];
new g_maps[MAX_MODES][MAX_MAPS][32], g_mapCount[MAX_MODES], g_modeCount;
new g_mode; // current mode index

new g_phase = PH_IDLE, g_opts[8][40], g_optCount, g_optIdx[8], g_votes[33];
new g_nextMode = -1, g_nextMap[32], g_changing, g_switchMode = -1, g_switchMap[32];

new g_bots = 6, g_diff = 2;
new bool:g_lowgrav, bool:g_hs, bool:g_speed, bool:g_adaptive, bool:g_announcer, bool:g_colors;

new g_kills[33], g_deaths[33], g_streak[33], g_multi[33], Float:g_multiLast[33], bool:g_firstBlood;
new g_lastKiller, g_rounds, g_matchRecorded, g_ggWinner[32];

new Handle:g_db;
new pVoteSecs, pChoices, pEndScreen;

new const DIFF_NAMES[][] = { "easy", "normal", "hard", "expert" };
new const COLORS[6][3] = { {255,40,40}, {40,140,255}, {40,255,80}, {255,220,0}, {255,0,255}, {0,255,255} };

public plugin_init()
{
	register_plugin("ServerTools", "1.0.0", "local");

	pVoteSecs = register_cvar("st_vote_seconds", "20");
	pChoices = register_cvar("st_map_choices", "5");
	pEndScreen = register_cvar("st_endscreen_seconds", "5");

	register_clcmd("say", "cmd_say");
	register_clcmd("say_team", "cmd_say");

	register_srvcmd("st_state", "srv_state");
	register_srvcmd("st_vote", "srv_vote");
	register_srvcmd("st_autovote", "srv_autovote");
	register_srvcmd("st_matchend", "srv_matchend");
	register_srvcmd("st_bots", "srv_bots");
	register_srvcmd("st_diff", "srv_diff");
	register_srvcmd("st_map", "srv_map");
	register_srvcmd("st_mode", "srv_mode");
	register_srvcmd("st_restart", "srv_restart");
	register_srvcmd("st_toggle", "srv_toggle");

	register_event("DeathMsg", "ev_death", "a");
	register_message(SVC_INTERMISSION, "msg_intermission");
	register_message(SVC_FINALE, "msg_finale");
	register_logevent("ev_round_end", 2, "1=Round_End");
	register_logevent("ev_round_start", 2, "1=Round_Start");
	register_logevent("ev_restart", 2, "1&Restart_Round_");
	register_logevent("ev_gg_won", 3, "2=Won_GunGame");

	RegisterHam(Ham_TraceAttack, "player", "fw_trace_attack");
	RegisterHam(Ham_CS_Player_ResetMaxSpeed, "player", "fw_maxspeed", 1);
	RegisterHam(Ham_Spawn, "player", "fw_spawn", 1);

	load_config();
	load_state();

	// GunGame reads gg_enabled ~1s after map start; set it now (this plugin loads before gungame.amxx).
	set_cvar_num("gg_enabled", equal(g_modeKey[g_mode], "ar") ? 1 : 0);

	set_task(2.0, "check_near_end", TASK_NEAREND, _, _, "b");
}

public plugin_cfg()
{
	SQL_SetAffinity("sqlite");
	g_db = SQL_MakeDbTuple("", "", "", "servertools");
	db_exec("CREATE TABLE IF NOT EXISTS st_players (id TEXT PRIMARY KEY, name TEXT NOT NULL, is_bot INTEGER NOT NULL DEFAULT 0, last_seen TEXT NOT NULL, best_streak INTEGER NOT NULL DEFAULT 0)");
	db_exec("CREATE TABLE IF NOT EXISTS st_kills (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, map TEXT, mode TEXT, killer_id TEXT, victim_id TEXT NOT NULL, weapon TEXT, headshot INTEGER NOT NULL DEFAULT 0)");
	db_exec("CREATE INDEX IF NOT EXISTS st_kills_k ON st_kills(killer_id)");
	db_exec("CREATE INDEX IF NOT EXISTS st_kills_v ON st_kills(victim_id)");
	db_exec("CREATE TABLE IF NOT EXISTS st_matches (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, map TEXT, mode TEXT, winner_id TEXT, winner_name TEXT, winner_bot INTEGER NOT NULL DEFAULT 0)");

	apply_mode_cfg();
	set_task(1.5, "apply_mode_cfg");  // again after server.cfg / gungame.cfg have run
	set_task(3.0, "apply_bots");
}

public plugin_end()
{
	if (g_db != Empty_Handle) SQL_FreeHandle(g_db);
}

// ---------- config / persisted state ----------

load_config()
{
	new path[128];
	get_configsdir(path, charsmax(path));
	add(path, charsmax(path), "/servertools.ini");
	new f = fopen(path, "rt");
	if (!f) { log_amx("Missing %s", path); return; }

	new line[1024], key[12], name[32], maps[960], m[32];
	while (!feof(f) && g_modeCount < MAX_MODES)
	{
		fgets(f, line, charsmax(line));
		trim(line);
		if (!line[0] || line[0] == ';' || line[0] == '/' || line[0] == '#') continue;
		strtok(line, key, charsmax(key), maps, charsmax(maps), '|');
		strtok(maps, name, charsmax(name), maps, charsmax(maps), '|');
		trim(key); trim(name); trim(maps);
		new i = g_modeCount;
		copy(g_modeKey[i], 11, key);
		copy(g_modeName[i], 31, name);
		g_mapCount[i] = 0;
		while (maps[0] && g_mapCount[i] < MAX_MAPS)
		{
			strtok(maps, m, charsmax(m), maps, charsmax(maps), ' ');
			trim(m); trim(maps);
			if (m[0] && is_map_valid(m)) copy(g_maps[i][g_mapCount[i]++], 31, m);
			else if (m[0]) log_amx("Map %s not installed, skipped", m);
		}
		if (g_mapCount[i] > 0) g_modeCount++;
	}
	fclose(f);
}

load_state()
{
	new v[32];
	g_mode = 0;
	get_localinfo("st_mode", v, charsmax(v));
	new idx = mode_by_key(v);
	if (idx >= 0) g_mode = idx;

	get_localinfo("st_bots", v, charsmax(v));
	if (v[0]) g_bots = str_to_num(v);
	get_localinfo("st_diff", v, charsmax(v));
	if (v[0]) g_diff = str_to_num(v);
	get_localinfo("st_mods", v, charsmax(v));
	new b = str_to_num(v);
	g_lowgrav = bool:(b & 1); g_hs = bool:(b & 2); g_speed = bool:(b & 4);
	g_adaptive = bool:(b & 8); g_announcer = bool:(b & 16); g_colors = bool:(b & 32);
}

save_state()
{
	new v[16];
	set_localinfo("st_mode", g_modeKey[g_mode]);
	num_to_str(g_bots, v, charsmax(v)); set_localinfo("st_bots", v);
	num_to_str(g_diff, v, charsmax(v)); set_localinfo("st_diff", v);
	new b = (g_lowgrav ? 1 : 0) | (g_hs ? 2 : 0) | (g_speed ? 4 : 0) | (g_adaptive ? 8 : 0) | (g_announcer ? 16 : 0) | (g_colors ? 32 : 0);
	num_to_str(b, v, charsmax(v)); set_localinfo("st_mods", v);
}

mode_by_key(const key[])
{
	if (!key[0]) return -1;
	for (new i = 0; i < g_modeCount; i++) if (equali(g_modeKey[i], key)) return i;
	return -1;
}

public apply_mode_cfg()
{
	server_cmd("exec st/common.cfg");
	server_cmd("exec st/%s.cfg", g_modeKey[g_mode]);
	server_exec();
	apply_modifiers();
}

public apply_bots()
{
	// YaPB difficulty is 0-4; map easy/normal/hard/expert to 1-4.
	server_cmd("yb_quota_mode fill; yb_quota %d; yb_difficulty %d", g_bots, g_diff + 1);
}

apply_modifiers()
{
	set_cvar_num("sv_gravity", g_lowgrav ? 300 : 800);
	set_cvar_num("sv_maxspeed", g_speed ? 450 : 320);
	for (new id = 1; id <= 32; id++)
	{
		if (!is_user_alive(id)) continue;
		ExecuteHamB(Ham_CS_Player_ResetMaxSpeed, id);
		paint(id);
	}
}

// ---------- helpers ----------

chat(const fmt[], any:...)
{
	new msg[190];
	vformat(msg, charsmax(msg), fmt, 2);
	client_print_color(0, print_team_default, "^4[Vote]^1 %s", msg);
}

humans_count()
{
	new n = 0;
	for (new id = 1; id <= 32; id++) if (is_user_connected(id) && !is_user_bot(id) && !is_user_hltv(id)) n++;
	return n;
}

current_map(name[], len) { get_mapname(name, len); }

bool:same_map(const m[])
{
	new cur[32]; current_map(cur, charsmax(cur));
	return bool:equali(cur, m);
}

player_id(id, out[], len)
{
	new name[32]; get_user_name(id, name, charsmax(name));
	if (is_user_bot(id)) { formatex(out, len, "BOT:%s", name); return; }
	get_user_authid(id, out, len);
	if (!out[0] || containi(out, "LAN") != -1 || containi(out, "PENDING") != -1 || containi(out, "UNKNOWN") != -1)
		formatex(out, len, "NAME:%s", name);
}

sql_escape(const src[], dst[], len)
{
	new j = 0;
	for (new i = 0; src[i] && j < len - 2; i++)
	{
		if (src[i] == ''') dst[j++] = ''';
		dst[j++] = src[i];
	}
	dst[j] = 0;
}

db_exec(const query[])
{
	if (g_db == Empty_Handle) return;
	SQL_ThreadQuery(g_db, "db_done", query);
}

public db_done(failstate, Handle:query, error[], errnum, data[], size, Float:queuetime)
{
	if (failstate != TQUERY_SUCCESS) log_amx("[ServerTools] DB error %d: %s", errnum, error);
}

// ---------- stats ----------

upsert_player(id)
{
	new pid[72], name[32], ename[72], epid[150], q[400];
	player_id(id, pid, charsmax(pid));
	get_user_name(id, name, charsmax(name));
	sql_escape(name, ename, charsmax(ename));
	sql_escape(pid, epid, charsmax(epid));
	formatex(q, charsmax(q), "INSERT OR IGNORE INTO st_players (id, name, is_bot, last_seen) VALUES ('%s', '%s', %d, datetime('now'))", epid, ename, is_user_bot(id) ? 1 : 0);
	db_exec(q);
	formatex(q, charsmax(q), "UPDATE st_players SET name='%s', last_seen=datetime('now') WHERE id='%s'", ename, epid);
	db_exec(q);
}

record_match(winner)
{
	if (g_matchRecorded) return;
	g_matchRecorded = 1;
	new map[32], q[512], wid[72], wname[32], ewid[150], ewname[72];
	current_map(map, charsmax(map));
	if (winner && is_user_connected(winner))
	{
		player_id(winner, wid, charsmax(wid));
		get_user_name(winner, wname, charsmax(wname));
		sql_escape(wid, ewid, charsmax(ewid));
		sql_escape(wname, ewname, charsmax(ewname));
		formatex(q, charsmax(q), "INSERT INTO st_matches (ts, map, mode, winner_id, winner_name, winner_bot) VALUES (datetime('now'), '%s', '%s', '%s', '%s', %d)",
			map, g_modeKey[g_mode], ewid, ewname, is_user_bot(winner) ? 1 : 0);
	}
	else
		formatex(q, charsmax(q), "INSERT INTO st_matches (ts, map, mode, winner_bot) VALUES (datetime('now'), '%s', '%s', 0)", map, g_modeKey[g_mode]);
	db_exec(q);
	adapt_difficulty(winner);
}

top_player()
{
	new best = 0, bestScore = -9999;
	for (new id = 1; id <= 32; id++)
	{
		if (!is_user_connected(id) || is_user_hltv(id)) continue;
		new CsTeams:t = cs_get_user_team(id);
		if (t != CS_TEAM_T && t != CS_TEAM_CT) continue;
		new s = get_user_frags(id);
		if (s > bestScore) { bestScore = s; best = id; }
	}
	return best;
}

// ---------- events ----------

public client_putinserver(id)
{
	g_kills[id] = 0; g_deaths[id] = 0; g_streak[id] = 0; g_multi[id] = 0;
	if (!is_user_hltv(id)) set_task(1.0, "delayed_upsert", id);
}

public delayed_upsert(id) { if (is_user_connected(id)) upsert_player(id); }

public client_disconnected(id)
{
	g_votes[id] = 0;
	g_kills[id] = 0; g_deaths[id] = 0; g_streak[id] = 0; g_multi[id] = 0;
}

public ev_death()
{
	new killer = read_data(1), victim = read_data(2), hs = read_data(3);
	new wpn[24]; read_data(4, wpn, charsmax(wpn));
	if (!is_user_connected(victim)) return;

	g_deaths[victim]++;
	new vstreak = g_streak[victim];
	g_streak[victim] = 0;
	g_multi[victim] = 0;

	new kid[72], vid[72], ekid[150], evid[150], map[32], q[512];
	player_id(victim, vid, charsmax(vid));
	sql_escape(vid, evid, charsmax(evid));
	current_map(map, charsmax(map));
	upsert_player(victim);

	new bool:real = killer >= 1 && killer <= 32 && killer != victim && is_user_connected(killer);
	if (real)
	{
		g_kills[killer]++;
		g_lastKiller = killer;
		upsert_player(killer);
		player_id(killer, kid, charsmax(kid));
		sql_escape(kid, ekid, charsmax(ekid));
		g_streak[killer]++;
		formatex(q, charsmax(q), "INSERT INTO st_kills (ts, map, mode, killer_id, victim_id, weapon, headshot) VALUES (datetime('now'), '%s', '%s', '%s', '%s', '%s', %d)",
			map, g_modeKey[g_mode], ekid, evid, wpn, hs);
		db_exec(q);
		formatex(q, charsmax(q), "UPDATE st_players SET best_streak = MAX(best_streak, %d) WHERE id='%s'", g_streak[killer], ekid);
		db_exec(q);
		announce(killer, victim, hs, wpn, vstreak);
	}
	else
	{
		formatex(q, charsmax(q), "INSERT INTO st_kills (ts, map, mode, killer_id, victim_id, weapon, headshot) VALUES (datetime('now'), '%s', '%s', NULL, '%s', '%s', 0)",
			map, g_modeKey[g_mode], evid, wpn);
		db_exec(q);
	}
}

public msg_intermission()
{
	// Time/round limit reached (GunGame handles its own end when active).
	if (equal(g_modeKey[g_mode], "ar") && get_cvar_num("gg_enabled")) return PLUGIN_CONTINUE;
	record_match(top_player());
	match_end(float(get_pcvar_num(pEndScreen)));
	return PLUGIN_CONTINUE;
}

public msg_finale()
{
	// GunGame sends SVC_FINALE when someone wins; the last killer is the winner.
	if (!equal(g_modeKey[g_mode], "ar")) return PLUGIN_CONTINUE;
	set_task(0.5, "record_gg_win");
	return PLUGIN_CONTINUE;
}

public ev_gg_won()
{
	new arg[96];
	read_logargv(0, arg, charsmax(arg));
	new name[32];
	parse_loguser(arg, name, charsmax(name));
	copy(g_ggWinner, charsmax(g_ggWinner), name);
}

public record_gg_win()
{
	new winner = 0;
	if (g_ggWinner[0]) winner = get_user_index(g_ggWinner);
	if (!winner) winner = g_lastKiller;
	record_match(winner);
	// Make sure a decision exists; GunGame calls st_matchend after its win screen.
	finish_running_vote();
	if (g_phase != PH_DECIDED) pick_random_next();
}

public ev_round_end() { g_rounds++; }
public ev_restart() { g_rounds = 0; }
public ev_round_start()
{
	if (!equal(g_modeKey[g_mode], "comp")) return;
	new max = get_cvar_num("mp_maxrounds");
	if (max > 0 && g_rounds >= max - 1) auto_vote();
}

public check_near_end()
{
	if (g_phase != PH_IDLE || g_changing) return;
	if (equal(g_modeKey[g_mode], "dm") || equal(g_modeKey[g_mode], "casual"))
	{
		if (get_cvar_float("mp_timelimit") <= 0.0) return;
		new left = get_timeleft();
		if (left > 0 && left <= 75) auto_vote();
	}
}

// ---------- voting ----------

auto_vote()
{
	if (g_phase != PH_IDLE || g_changing || humans_count() == 0) return;
	start_mode_vote();
}

reset_vote()
{
	remove_task(TASK_VOTE);
	g_phase = PH_IDLE;
	g_optCount = 0;
	arrayset(g_votes, 0, sizeof g_votes);
	g_nextMode = -1;
	g_nextMap[0] = 0;
}

announce_options(const title[])
{
	chat("^3%s^1 - type the number in chat (press Y):", title);
	for (new i = 0; i < g_optCount; i++)
		client_print_color(0, print_team_default, "   ^4%d^1. %s", i + 1, g_opts[i]);
}

start_mode_vote()
{
	g_phase = PH_MODEVOTE;
	g_optCount = 0;
	arrayset(g_votes, 0, sizeof g_votes);
	g_optIdx[g_optCount] = g_mode;
	formatex(g_opts[g_optCount++], 39, "%s (keep)", g_modeName[g_mode]);
	for (new i = 0; i < g_modeCount && g_optCount < 8; i++)
	{
		if (i == g_mode) continue;
		g_optIdx[g_optCount] = i;
		copy(g_opts[g_optCount++], 39, g_modeName[i]);
	}
	announce_options("Vote for the NEXT GAME MODE");
	set_task(float(get_pcvar_num(pVoteSecs)), "finish_phase", TASK_VOTE);
}

start_map_vote()
{
	new mode = g_nextMode;
	new pool[MAX_MAPS], n = 0;
	for (new i = 0; i < g_mapCount[mode]; i++) if (!same_map(g_maps[mode][i])) pool[n++] = i;
	if (n == 0) for (new i = 0; i < g_mapCount[mode]; i++) pool[n++] = i;
	// shuffle
	for (new i = n - 1; i > 0; i--) { new j = random(i + 1), t = pool[i]; pool[i] = pool[j]; pool[j] = t; }
	new choices = min(get_pcvar_num(pChoices), min(n, 8));
	if (choices <= 1)
	{
		copy(g_nextMap, charsmax(g_nextMap), g_maps[mode][pool[0]]);
		decide();
		return;
	}
	g_phase = PH_MAPVOTE;
	g_optCount = 0;
	arrayset(g_votes, 0, sizeof g_votes);
	for (new i = 0; i < choices; i++)
	{
		g_optIdx[g_optCount] = pool[i];
		copy(g_opts[g_optCount++], 39, g_maps[mode][pool[i]]);
	}
	new title[64]; formatex(title, charsmax(title), "Vote for the NEXT MAP (%s)", g_modeName[mode]);
	announce_options(title);
	set_task(float(get_pcvar_num(pVoteSecs)), "finish_phase", TASK_VOTE);
}

winner_option()
{
	new tally[8], any_votes = 0;
	for (new id = 1; id <= 32; id++) if (g_votes[id] > 0) { tally[g_votes[id] - 1]++; any_votes = 1; }
	if (!any_votes) return 0; // nobody voted: keep mode / first map
	new max = 0;
	for (new i = 0; i < g_optCount; i++) if (tally[i] > max) max = tally[i];
	new top[8], n = 0;
	for (new i = 0; i < g_optCount; i++) if (tally[i] == max) top[n++] = i;
	return top[random(n)];
}

public finish_phase()
{
	remove_task(TASK_VOTE);
	if (g_phase == PH_MODEVOTE)
	{
		g_nextMode = g_optIdx[winner_option()];
		chat("Next mode: ^4%s", g_modeName[g_nextMode]);
		start_map_vote();
	}
	else if (g_phase == PH_MAPVOTE)
	{
		copy(g_nextMap, charsmax(g_nextMap), g_maps[g_nextMode][g_optIdx[winner_option()]]);
		decide();
	}
}

finish_running_vote()
{
	while (g_phase == PH_MODEVOTE || g_phase == PH_MAPVOTE) finish_phase();
}

decide()
{
	remove_task(TASK_VOTE);
	g_phase = PH_DECIDED;
	set_cvar_string("amx_nextmap", g_nextMap);
	chat("Next up: ^4%s^1 on ^4%s^1 (after this match)", g_modeName[g_nextMode], g_nextMap);
}

pick_random_next()
{
	g_nextMode = g_mode;
	new pool[MAX_MAPS], n = 0;
	for (new i = 0; i < g_mapCount[g_mode]; i++) if (!same_map(g_maps[g_mode][i])) pool[n++] = i;
	if (n == 0) for (new i = 0; i < g_mapCount[g_mode]; i++) pool[n++] = i;
	copy(g_nextMap, charsmax(g_nextMap), g_maps[g_mode][pool[random(n)]]);
	g_phase = PH_DECIDED;
	set_cvar_string("amx_nextmap", g_nextMap);
	chat("Next up: ^4%s^1 on ^4%s", g_modeName[g_nextMode], g_nextMap);
}

match_end(Float:delay)
{
	if (g_changing) return;
	g_changing = 1;
	finish_running_vote();
	if (g_phase != PH_DECIDED) pick_random_next();
	switch_to(g_nextMode, g_nextMap, delay);
}

switch_to(mode, const map[], Float:delay)
{
	g_changing = 1;
	g_switchMode = mode;
	copy(g_switchMap, charsmax(g_switchMap), map);
	remove_task(TASK_SWITCH);
	set_task(delay, "do_switch", TASK_SWITCH);
}

public do_switch()
{
	g_mode = g_switchMode;
	save_state();
	set_cvar_num("gg_enabled", equal(g_modeKey[g_mode], "ar") ? 1 : 0);
	set_cvar_string("amx_nextmap", g_switchMap);
	server_cmd("changelevel %s", g_switchMap);
}

// ---------- chat ----------

public cmd_say(id)
{
	if (!is_user_connected(id) || is_user_bot(id)) return PLUGIN_CONTINUE;
	new text[96];
	read_args(text, charsmax(text));
	remove_quotes(text);
	trim(text);
	new p = 0;
	if (text[0] == '!' || text[0] == '/') p = 1;

	// numeric vote
	if ((g_phase == PH_MODEVOTE || g_phase == PH_MAPVOTE) && isdigit(text[p]))
	{
		new n = str_to_num(text[p]);
		if (n >= 1 && n <= g_optCount)
		{
			g_votes[id] = n;
			new count = 0;
			for (new i = 1; i <= 32; i++) if (g_votes[i] == n) count++;
			new name[32]; get_user_name(id, name, charsmax(name));
			chat("%s voted ^4%s^1 (%d)", name, g_opts[n - 1], count);
			new all = 1;
			for (new i = 1; i <= 32; i++)
				if (is_user_connected(i) && !is_user_bot(i) && !is_user_hltv(i) && !g_votes[i]) { all = 0; break; }
			if (all) set_task(0.1, "finish_phase");
			return PLUGIN_HANDLED;
		}
	}
	if (!p) return PLUGIN_CONTINUE;

	new cmd[24], arg1[32], arg2[32];
	parse(text[p], cmd, charsmax(cmd), arg1, charsmax(arg1), arg2, charsmax(arg2));
	new bool:admin = bool:(get_user_flags(id) & ADMIN_RCON);
	new name[32]; get_user_name(id, name, charsmax(name));

	if (equali(cmd, "vote") || equali(cmd, "rtv")) { cmd_vote(id); }
	else if (equali(cmd, "nextmap"))
	{
		if (g_phase == PH_DECIDED) client_print_color(id, print_team_default, "^4Next:^1 %s on %s", g_modeName[g_nextMode], g_nextMap);
		else client_print_color(id, print_team_default, "Next map not decided yet (vote starts near the end, or type ^4!vote^1).");
	}
	else if (equali(cmd, "maps"))
	{
		for (new m = 0; m < g_modeCount; m++)
		{
			new list[190], len = formatex(list, charsmax(list), "[%s] ", g_modeKey[m]);
			for (new i = 0; i < g_mapCount[m]; i++) len += formatex(list[len], charsmax(list) - len, "%s%s", i ? ", " : "", g_maps[m][i]);
			client_print(id, print_chat, "%s", list);
		}
	}
	else if (equali(cmd, "fun"))
	{
		client_print(id, print_chat, "Low grav %s | HS only %s | Speed %s | Adaptive %s | Announcer %s | Colors %s | Bots %s",
			g_lowgrav ? "ON" : "off", g_hs ? "ON" : "off", g_speed ? "ON" : "off", g_adaptive ? "ON" : "off",
			g_announcer ? "ON" : "off", g_colors ? "ON" : "off", DIFF_NAMES[g_diff]);
	}
	else if (equali(cmd, "host") || equali(cmd, "help"))
	{
		client_print(id, print_chat, "Everyone: !vote !nextmap !maps !fun !lowgrav !headshot !speed !adaptive !announcer !colors");
		client_print(id, print_chat, "Host: !bots <n> !diff <0-3> !map <name> !mode <ar|dm|casual|comp> [map] !restart");
	}
	else if (equali(cmd, "lowgrav")) toggle(name, "lowgrav");
	else if (equali(cmd, "headshot") || equali(cmd, "hs")) toggle(name, "headshot");
	else if (equali(cmd, "speed")) toggle(name, "speed");
	else if (equali(cmd, "adaptive")) toggle(name, "adaptive");
	else if (equali(cmd, "announcer")) toggle(name, "announcer");
	else if (equali(cmd, "colors")) toggle(name, "colors");
	else if (equali(cmd, "bots") || equali(cmd, "diff") || equali(cmd, "map") || equali(cmd, "mode") || equali(cmd, "restart"))
	{
		if (!admin) { client_print(id, print_chat, "Host only."); return PLUGIN_HANDLED; }
		if (equali(cmd, "bots")) set_bots(str_to_num(arg1));
		else if (equali(cmd, "diff")) set_diff(str_to_num(arg1));
		else if (equali(cmd, "map")) change_map(arg1);
		else if (equali(cmd, "mode")) change_mode(arg1, arg2);
		else do_restart();
	}
	else return PLUGIN_CONTINUE;
	return PLUGIN_CONTINUE;
}

cmd_vote(id)
{
	if (g_phase == PH_MODEVOTE || g_phase == PH_MAPVOTE)
	{
		if (id) client_print(id, print_chat, "A vote is already running.");
		return;
	}
	if (g_changing) return;
	reset_vote();
	start_mode_vote();
}

// ---------- host actions ----------

set_bots(n)
{
	if (n < 0 || n > 20) return;
	g_bots = n;
	save_state();
	apply_bots();
	client_print_color(0, print_team_default, "Bots fill to ^4%d^1 players (%dv%d)", n, n / 2, n - n / 2);
}

set_diff(n)
{
	if (n < 0 || n > 3) return;
	g_diff = n;
	save_state();
	server_cmd("yb_difficulty %d; yb kickall", n + 1);
	set_task(1.0, "apply_bots");
	client_print_color(0, print_team_default, "Bot difficulty: ^4%s", DIFF_NAMES[n]);
}

bool:find_map(const query[], &mode, map[], len)
{
	// exact match first (current mode preferred), then substring
	for (new pass = 0; pass < 2; pass++)
		for (new k = -1; k < g_modeCount; k++)
		{
			new m = k == -1 ? g_mode : k;
			if (k == g_mode) continue;
			for (new i = 0; i < g_mapCount[m]; i++)
				if ((pass == 0 && equali(g_maps[m][i], query)) || (pass == 1 && containi(g_maps[m][i], query) != -1))
				{
					mode = m; copy(map, len, g_maps[m][i]); return true;
				}
		}
	return false;
}

change_map(const q[])
{
	new mode, map[32];
	if (!find_map(q, mode, map, charsmax(map)))
	{
		if (is_map_valid(q)) { mode = g_mode; copy(map, charsmax(map), q); }
		else { server_print("Unknown map %s", q); return; }
	}
	client_print_color(0, print_team_default, "Changing to ^4%s^1 on ^4%s", g_modeName[mode], map);
	switch_to(mode, map, 2.0);
}

change_mode(const key[], const q[])
{
	new mode = mode_by_key(key);
	if (mode < 0) { server_print("Unknown mode %s", key); return; }
	new map[32];
	if (q[0])
	{
		for (new i = 0; i < g_mapCount[mode]; i++) if (equali(g_maps[mode][i], q)) { copy(map, charsmax(map), q); break; }
		if (!map[0]) for (new i = 0; i < g_mapCount[mode]; i++) if (containi(g_maps[mode][i], q) != -1) { copy(map, charsmax(map), g_maps[mode][i]); break; }
	}
	if (!map[0]) copy(map, charsmax(map), g_maps[mode][random(g_mapCount[mode])]);
	client_print_color(0, print_team_default, "Changing to ^4%s^1 on ^4%s", g_modeName[mode], map);
	switch_to(mode, map, 2.0);
}

do_restart()
{
	reset_vote();
	g_rounds = 0;
	if (equal(g_modeKey[g_mode], "ar") && get_cvar_num("gg_enabled")) server_cmd("amx_gungame_restart 1");
	else server_cmd("sv_restartround 1");
}

toggle(const who[], const what[])
{
	new bool:on, label[32];
	if (equal(what, "lowgrav")) { g_lowgrav = !g_lowgrav; on = g_lowgrav; copy(label, 31, "low gravity"); }
	else if (equal(what, "headshot")) { g_hs = !g_hs; on = g_hs; copy(label, 31, "headshot only"); }
	else if (equal(what, "speed")) { g_speed = !g_speed; on = g_speed; copy(label, 31, "speed boost"); }
	else if (equal(what, "adaptive")) { g_adaptive = !g_adaptive; on = g_adaptive; copy(label, 31, "adaptive bots"); }
	else if (equal(what, "announcer")) { g_announcer = !g_announcer; on = g_announcer; copy(label, 31, "kill announcer"); }
	else if (equal(what, "colors")) { g_colors = !g_colors; on = g_colors; copy(label, 31, "player colors"); }
	else return;
	save_state();
	apply_modifiers();
	client_print_color(0, print_team_default, "^3[Fun]^1 %s turned %s %s", who, label, on ? "^4ON^1" : "^3OFF^1");
	if (equal(what, "adaptive") && on)
		client_print_color(0, print_team_default, "^3[Fun]^1 Bots get harder when a human wins a match, easier when a bot wins.");
}

adapt_difficulty(top)
{
	if (!g_adaptive || !top || !is_user_connected(top)) return;
	new old = g_diff;
	g_diff = clamp(g_diff + (is_user_bot(top) ? -1 : 1), 0, 3);
	if (g_diff == old) return;
	save_state();
	if (is_user_bot(top))
		client_print_color(0, print_team_default, "^3[Fun]^1 A bot won. Bots get easier next match: ^4%s", DIFF_NAMES[g_diff]);
	else
	{
		new name[32]; get_user_name(top, name, charsmax(name));
		client_print_color(0, print_team_default, "^3[Fun]^1 %s won! Bots get harder next match: ^4%s", name, DIFF_NAMES[g_diff]);
	}
}

// ---------- fun hooks ----------

public fw_trace_attack(victim, attacker, Float:damage, Float:dir[3], tr, bits)
{
	if (!g_hs || attacker < 1 || attacker > 32 || attacker == victim) return HAM_IGNORED;
	if (get_tr2(tr, TR_iHitgroup) != HIT_HEAD) return HAM_SUPERCEDE;
	return HAM_IGNORED;
}

public fw_maxspeed(id)
{
	if (!g_speed || !is_user_alive(id)) return;
	new Float:m = get_user_maxspeed(id);
	if (m > 1.0) set_user_maxspeed(id, m * 1.4);
}

public fw_spawn(id)
{
	if (!is_user_alive(id)) return;
	paint(id);
	if (equal(g_modeKey[g_mode], "dm")) cs_set_user_money(id, 16000, 0);
}

paint(id)
{
	if (!g_colors || is_user_bot(id))
	{
		if (!is_user_bot(id)) set_user_rendering(id);
		return;
	}
	// each human gets a stable color by join order among humans
	new slot = 0;
	for (new i = 1; i < id; i++) if (is_user_connected(i) && !is_user_bot(i) && !is_user_hltv(i)) slot++;
	slot %= 6;
	set_user_rendering(id, kRenderFxGlowShell, COLORS[slot][0], COLORS[slot][1], COLORS[slot][2], kRenderNormal, 20);
}

// ---------- kill announcer (text only) ----------

announce(killer, victim, hs, const wpn[], vstreak)
{
	if (!g_announcer) return;
	new kname[32], vname[32];
	get_user_name(killer, kname, charsmax(kname));
	get_user_name(victim, vname, charsmax(vname));

	if (!g_firstBlood)
	{
		g_firstBlood = true;
		hud(255, 50, 50, "FIRST BLOOD^n%s", kname);
	}
	new Float:now = get_gametime();
	if (now - g_multiLast[killer] <= 4.0) g_multi[killer]++; else g_multi[killer] = 1;
	g_multiLast[killer] = now;

	static const MULTI[][] = { "", "", "DOUBLE KILL", "TRIPLE KILL", "MULTI KILL", "ULTRA KILL", "MONSTER KILL" };
	new mk = min(g_multi[killer], 6);
	if (mk >= 2) hud(255, 160, 0, "%s^n%s", MULTI[mk], kname);

	new s = g_streak[killer];
	if (s == 5) hud(255, 170, 0, "%s is on a KILLING SPREE", kname);
	else if (s == 10) hud(255, 100, 0, "%s is on a RAMPAGE", kname);
	else if (s == 15) hud(255, 50, 50, "%s is DOMINATING", kname);
	else if (s == 20) hud(255, 0, 255, "%s is UNSTOPPABLE", kname);
	else if (s == 25) hud(0, 255, 255, "%s is GODLIKE", kname);

	if (vstreak >= 5) client_print_color(0, print_team_default, "^4%s^1 ended ^3%s^1's %d kill streak", kname, vname, vstreak);
	if (equal(wpn, "knife")) client_print_color(0, print_team_default, "^4%s^1 humiliated ^3%s^1 with a knife", kname, vname);
	else if (hs && mk < 2 && s != 5) client_print(killer, print_center, "HEADSHOT");
}

hud(r, g, b, const fmt[], any:...)
{
	new msg[128];
	vformat(msg, charsmax(msg), fmt, 5);
	set_hudmessage(r, g, b, -1.0, 0.25, 0, 0.0, 2.5, 0.1, 0.3, 3);
	show_hudmessage(0, "%s", msg);
}

// ---------- server commands (RCON / panel) ----------

public srv_vote() { cmd_vote(0); return PLUGIN_HANDLED; }
public srv_autovote() { auto_vote(); return PLUGIN_HANDLED; }

public srv_matchend()
{
	// GunGame's changelevel hook (gg_changelevel_custom) after the win screen.
	g_changing = 0;
	record_match(g_lastKiller);
	match_end(0.1);
	return PLUGIN_HANDLED;
}

public srv_bots() { new a[8]; read_argv(1, a, charsmax(a)); set_bots(str_to_num(a)); return PLUGIN_HANDLED; }
public srv_diff() { new a[8]; read_argv(1, a, charsmax(a)); set_diff(str_to_num(a)); return PLUGIN_HANDLED; }
public srv_map() { new a[32]; read_argv(1, a, charsmax(a)); change_map(a); return PLUGIN_HANDLED; }
public srv_mode() { new a[16], b[32]; read_argv(1, a, charsmax(a)); read_argv(2, b, charsmax(b)); change_mode(a, b); return PLUGIN_HANDLED; }
public srv_restart() { do_restart(); return PLUGIN_HANDLED; }
public srv_toggle() { new a[16]; read_argv(1, a, charsmax(a)); toggle("Host", a); return PLUGIN_HANDLED; }

public srv_state()
{
	new JSON:root = json_init_object();
	new map[32]; current_map(map, charsmax(map));
	json_object_set_string(root, "map", map);
	json_object_set_string(root, "mode", g_modeKey[g_mode]);
	json_object_set_string(root, "modeName", g_modeName[g_mode]);
	json_object_set_number(root, "botQuota", g_bots);
	json_object_set_number(root, "difficulty", g_diff);
	json_object_set_number(root, "timeleft", get_timeleft());

	new JSON:mods = json_init_object();
	json_object_set_bool(mods, "lowgrav", g_lowgrav);
	json_object_set_bool(mods, "headshot", g_hs);
	json_object_set_bool(mods, "speed", g_speed);
	json_object_set_bool(mods, "adaptive", g_adaptive);
	json_object_set_bool(mods, "announcer", g_announcer);
	json_object_set_bool(mods, "colors", g_colors);
	json_object_set_value(root, "modifiers", mods);
	json_free(mods);

	json_object_set_string(root, "vote", PHASE_NAMES[g_phase]);
	if (g_phase == PH_DECIDED && g_nextMode >= 0)
	{
		new JSON:next = json_init_object();
		json_object_set_string(next, "mode", g_modeKey[g_nextMode]);
		json_object_set_string(next, "map", g_nextMap);
		json_object_set_value(root, "next", next);
		json_free(next);
	}
	else json_object_set_null(root, "next");

	new JSON:players = json_init_array();
	for (new id = 1; id <= 32; id++)
	{
		if (!is_user_connected(id) || is_user_hltv(id)) continue;
		new JSON:p = json_init_object(), name[32], ping, loss;
		get_user_name(id, name, charsmax(name));
		get_user_ping(id, ping, loss);
		json_object_set_string(p, "name", name);
		json_object_set_bool(p, "bot", bool:is_user_bot(id));
		// 1.6 teams: 1 = T, 2 = CT. The panel uses CS2 numbering (2 = T, 3 = CT).
		new t = _:cs_get_user_team(id);
		json_object_set_number(p, "team", (t == 1 || t == 2) ? t + 1 : t);
		json_object_set_number(p, "score", get_user_frags(id));
		json_object_set_number(p, "kills", g_kills[id]);
		json_object_set_number(p, "deaths", g_deaths[id]);
		json_object_set_bool(p, "alive", bool:is_user_alive(id));
		json_object_set_number(p, "ping", is_user_bot(id) ? 0 : ping);
		json_array_append_value(players, p);
		json_free(p);
	}
	json_object_set_value(root, "players", players);
	json_free(players);

	static buf[6144];
	json_serial_to_string(root, buf, charsmax(buf));
	json_free(root);

	// Console output is printed in short numbered chunks so RCON delivers it intact.
	new len = strlen(buf), size = 160, parts = (len + size - 1) / size, chunk[176];
	for (new i = 0; i < parts; i++)
	{
		copy(chunk, min(size, len - i * size), buf[i * size]);
		server_print("STATEPART %d %d %s", i, parts, chunk);
	}
	return PLUGIN_HANDLED;
}
