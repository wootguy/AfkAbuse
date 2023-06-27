#include "main.h"
#include "meta_init.h"
#include "misc_utils.h"
#include "meta_utils.h"
#include "private_api.h"
#include <set>
#include <map>
#include "Scheduler.h"
#include <vector>
#include "StartSound.h"
#include "meta_helper.h"
#include "temp_ents.h"

// Description of plugin
plugin_info_t Plugin_info = {
	META_INTERFACE_VERSION,	// ifvers
	"AfkAbuse",	// name
	"1.0",	// version
	__DATE__,	// date
	"w00tguy",	// author
	"https://github.com/wootguy/",	// url
	"AFKABUSE",	// logtag, all caps please
	PT_ANYTIME,	// (when) loadable
	PT_ANYPAUSE,	// (when) unloadable
};

float TETHER_MIN_DIST = 128; // minumum distance before tether forces are applied
float TETHER_MAX_DIST = 1024; // max tether distance before snapping
int MAX_TETHERS = 64;
vector<int> g_player_afk(33);
vector<float> g_lastTetherAttempt(33); // last time a player attempted a grab (used to prevent messages showing on accident)
bool g_disabled = false;

string stretch_snd = "as_tether/stretch.wav";
string twang_snd = "as_tether/twang.wav";
string snap_snd = "as_tether/snap.wav";

class Tether {
public:
	EHandle h_src;
	EHandle h_dst;
	float lastPullForce;
	float lastTwang = 0;
	float lastPullNoise = 0;

	Tether() {}

	Tether(edict_t* src, edict_t* dst) {
		h_src = EHandle(src);
		h_dst = EHandle(dst);
	}

	bool isValid() {
		CBasePlayer* src = getSrc();
		CBasePlayer* dst = getDst();

		return src && src->IsConnected() && dst && dst->IsConnected() && src->entindex() != dst->entindex();
	}

	bool shouldBreak() {
		CBasePlayer* src = getSrc();
		CBasePlayer* dst = getDst();

		return !src->IsAlive() || !dst->IsAlive() || g_player_afk[dst->entindex()] == 0;
	}

	void twangSound() {
		CBasePlayer* src = getSrc();
		CBasePlayer* dst = getDst();

		lastTwang = gpGlobals->time;
		PlaySound(src->edict(), CHAN_WEAPON, twang_snd, 1.0f, 0.8f, 0, RANDOM_LONG(75, 85), 0, true, src->pev->origin);
		PlaySound(dst->edict(), CHAN_WEAPON, twang_snd, 1.0f, 0.8f, 0, RANDOM_LONG(75, 85), 0, true, dst->pev->origin);
	}
	

	void snap() {
		CBasePlayer* src = getSrc();
		CBasePlayer* dst = getDst();

		edict_t* world = INDEXENT(0);

		if (src != NULL) {
			PlaySound(src->edict(), CHAN_WEAPON, snap_snd, 1.0f, 0.8f, 0, RANDOM_LONG(95, 105), 0, true, src->pev->origin);
			TakeDamage(src->edict(), world, world, 20, DMG_CLUB | DMG_ALWAYSGIB);
			te_killbeam(src->edict());
		}
		if (dst != NULL) {
			PlaySound(dst->edict(), CHAN_WEAPON, snap_snd, 1.0f, 0.8f, 0, RANDOM_LONG(95, 105), 0, true, dst->pev->origin);
			TakeDamage(dst->edict(), world, world, 20, DMG_CLUB | DMG_ALWAYSGIB);
		}

		if (src != NULL && dst != NULL) {
			te_tracer(dst->pev->origin, src->pev->origin);
			te_tracer(src->pev->origin, dst->pev->origin);
		}
	}

	CBasePlayer* getSrc() {
		return (CBasePlayer*)h_src.GetEntity();
	}

	CBasePlayer* getDst() {
		return (CBasePlayer*)h_dst.GetEntity();
	}

	void deleteit() {
		h_src = EHandle();
		h_dst = EHandle();
	}

	bool isHooked(CBaseEntity* plr) {
		if (!isValid()) {
			return false;
		}

		return plr->entindex() == getSrc()->entindex() || plr->entindex() == getDst()->entindex();
	}
};

vector<Tether> g_tethers;

Tether* getTether(CBaseEntity* p1, CBaseEntity* p2) {
	for (int i = 0; i < g_tethers.size(); i++) {
		Tether* t = &g_tethers[i];

		if (t->isHooked(p1) && t->isHooked(p2)) {
			return t;
		}
	}

	return NULL;
}

set<string> g_disabled_maps = {
	"minigolf3"
};


void loadCrossPluginAfkState() {
	edict_t* afkEnt = g_engfuncs.pfnFindEntityByString(NULL, "targetname", "PlayerStatusPlugin");

	if (!afkEnt) {
		return;
	}

	static int afkIdx = 1;

	g_player_afk[afkIdx] = readCustomKeyvalueInteger(afkEnt, "$i_afk" + to_string(afkIdx));

	afkIdx++;
	if (afkIdx > 32) {
		afkIdx = 1;
	}
}

Vector getSwapDir(CBasePlayer* plr) {
	Vector angles = plr->pev->v_angle;

	// snap to 90 degree angles
	angles.y = (int((angles.y + 180 + 45) / 90) * 90) - 180;
	angles.x = (int((angles.x + 180 + 45) / 90) * 90) - 180;

	// vertical unblocking has priority
	if (angles.x != 0) {
		angles.y = 0;
	}
	else {
		angles.x = 0;
	}
	MAKE_VECTORS(angles);

	return gpGlobals->v_forward;
}

CBaseEntity* TraceLook(CBasePlayer* plr, Vector swapDir, float dist = 1) {
	Vector vecSrc = plr->pev->origin;

	plr->pev->solid = SOLID_NOT;

	TraceResult tr;
	Vector dir = swapDir * dist;
	int hullType = (plr->pev->flags & FL_DUCKING) != 0 ? head_hull : human_hull;
	TRACE_HULL(vecSrc, vecSrc + dir, dont_ignore_monsters, hullType, NULL, &tr);

	// try again in case the blocker is on a slope or stair
	if (swapDir.z == 0 && tr.pHit && ((CBaseEntity*)tr.pHit->pvPrivateData)->IsBSPModel()) {
		Vector verticalDir = Vector(0, 0, 36);
		if ((plr->pev->flags & FL_ONGROUND) == 0) {
			// probably on the ceiling, so try starting the trace lower instead (e.g. negative gravity or ladder)
			verticalDir.z = -36;
		}

		TRACE_HULL(vecSrc, vecSrc + verticalDir, dont_ignore_monsters, hullType, NULL, &tr);
		if (!tr.pHit || ((CBaseEntity*)tr.pHit->pvPrivateData)->IsBSPModel()) {
			TRACE_HULL(tr.vecEndPos, tr.vecEndPos + dir, dont_ignore_monsters, hullType, NULL, &tr);
		}
	}

	plr->pev->solid = SOLID_SLIDEBOX;

	return tr.pHit ? (CBaseEntity*)tr.pHit->pvPrivateData : NULL;
}

string format_float(float f) {
	uint32_t decimal = uint32_t(((f - int(f)) * 10)) % 10;
	return "" + to_string(int(f)) + "." + to_string(decimal);
}

CBaseEntity* getBestTarget(CBasePlayer* plr, Vector swapDir) {
	vector<CBaseEntity*> targets;

	float bestDist = 9e99;
	int bestIdx = -1;

	for (int i = 0; i < 4; i++) {
		CBaseEntity* target = TraceLook(plr, swapDir);

		if (!target || !target->IsPlayer()) {
			break;
		}

		targets.push_back(target);
		target->pev->solid = SOLID_NOT;

		float dist = (target->pev->origin - plr->pev->origin).Length();

		if (dist < bestDist) {
			bestDist = dist;
			bestIdx = i;
		}
	}

	for (int i = 0; i < targets.size(); i++) {
		targets[i]->pev->solid = SOLID_SLIDEBOX;
	}

	return bestIdx != -1 ? targets[bestIdx] : NULL;
}

void PlayerPostThink(edict_t* ed_plr) {
	CBasePlayer* plr = (CBasePlayer*)ed_plr->pvPrivateData;

	if ((plr->m_afButtonPressed & IN_RELOAD) == 0) {
		RETURN_META(MRES_IGNORED);
	}

	Vector swapDir = getSwapDir(plr);
	CBaseEntity* target = getBestTarget(plr, swapDir);

	if (!target) {
		RETURN_META(MRES_IGNORED);
	}

	Tether* existingTether = getTether(plr, target);

	if (existingTether) {
		existingTether->deleteit();
		PlaySound(plr->edict(), CHAN_ITEM, "weapons/bgrapple_release.wav", 1.0f, 0.8f, 0, 150, 0, true, plr->pev->origin);
	}
	else {
		bool shouldShowMessage = (gpGlobals->time - g_lastTetherAttempt[plr->entindex()]) < 1.0f;
		g_lastTetherAttempt[plr->entindex()] = gpGlobals->time;

		if (int(g_tethers.size()) >= MAX_TETHERS) {
			if (shouldShowMessage)
				ClientPrint(ed_plr, HUD_PRINTCENTER, "Too many tethers are active!\n");
			RETURN_META(MRES_IGNORED);
		}
		if (g_player_afk[target->entindex()] == 0) {
			if (shouldShowMessage)
				ClientPrint(ed_plr, HUD_PRINTCENTER, "Only AFK players can be abused.\n");
			RETURN_META(MRES_IGNORED);
		}
		if (g_disabled) {
			if (shouldShowMessage)
				ClientPrint(ed_plr, HUD_PRINTCENTER, "AFK abuse disabled on this map.\n");
			RETURN_META(MRES_IGNORED);
		}
		g_tethers.push_back(Tether(ed_plr, target->edict()));
		PlaySound(ed_plr, CHAN_ITEM, "weapons/bgrapple_fire.wav", 1.0f, 0.8f, 0, 150, 0, true, plr->pev->origin);
	}

	RETURN_META(MRES_IGNORED);
}

void unstick_from_ground(CBasePlayer* plr) {
	if (plr->pev->velocity.z > 10 && plr->pev->flags & FL_ONGROUND != 0) {
		// check if moving up would get player stuck in something
		TraceResult tr;
		int hullType = (plr->pev->flags & FL_DUCKING) != 0 ? head_hull : human_hull;
		Vector pos = plr->pev->origin;
		TRACE_HULL(pos, pos + Vector(0, 0, 2), dont_ignore_monsters, hullType, NULL, &tr);

		if (tr.flFraction >= 1.0f) {
			plr->pev->origin.z += 2;
		}
	}
}

void PlayerTakeDamage() {
	CommandArgs args = CommandArgs();
	args.loadArgs();
	//println(args.getFullCommand());

	int i_victim = atoi(args.ArgV(1).c_str());
	int i_inflictor = atoi(args.ArgV(2).c_str());
	int attacker = atoi(args.ArgV(3).c_str());
	float damage = atof(args.ArgV(4).c_str());
	int damageType = atoi(args.ArgV(5).c_str());

	CBasePlayer* victim = (CBasePlayer*)(INDEXENT(i_victim)->pvPrivateData);
	CBaseEntity* inflictor = (CBaseEntity*)(INDEXENT(i_inflictor)->pvPrivateData);

	if (g_disabled || !victim || !inflictor) {
		return;
	}

	if (!inflictor->IsPlayer()) {
		edict_t* owner = inflictor->pev->owner;
		if (!isValidPlayer(owner)) {
			return; // don't get pushed by monster projectiles
		}
	}

	if (g_player_afk[i_victim] > 0) {
		Vector pushDir;

		if (inflictor->IsPlayer()) {
			MAKE_VECTORS(inflictor->pev->v_angle);
			pushDir = gpGlobals->v_forward;
		}
		else {
			pushDir = (victim->pev->origin - inflictor->pev->origin).Normalize();
		}

		victim->pev->velocity = victim->pev->velocity + pushDir * 20 * Max(20, damage);
		unstick_from_ground(victim);
	}
}

void apply_vel(CBasePlayer* target, Vector addVel, bool shouldLadderBoost) {
	target->pev->velocity = target->pev->velocity + addVel;

	unstick_from_ground(target);

	if (target->IsOnLadder()) {
		int oldPressed = target->m_afButtonPressed;

		// run movement code so player jumps off ladder, otherwise player gets stuck.
		g_engfuncs.pfnRunPlayerMove(target->edict(), target->pev->angles,
			target->pev->velocity.x, target->pev->velocity.y, target->pev->velocity.z,
			target->pev->button | IN_JUMP, target->pev->impulse, 10);

		// prevent afk checking plugin detecting this as coming back from AFK
		target->m_afButtonPressed = oldPressed;

		if (shouldLadderBoost)
			target->pev->velocity.z = 250;
	}
}

int thinkCount = 0;

void tether_logic() {
	for (int k = 0; k < int(g_tethers.size()); k++) {
		Tether& tether = g_tethers[k];

		if (!tether.isValid()) {
			g_tethers.erase(g_tethers.begin() + k);
			k--;
			continue;
		}

		CBasePlayer* src = tether.getSrc();
		CBasePlayer* dst = tether.getDst();

		Vector delta = src->pev->origin - dst->pev->origin;
		float dist = delta.Length();
		float pullForce = dist - TETHER_MIN_DIST;

		if (pullForce < 0) {
			pullForce = 0;
		}

		if (dist > TETHER_MAX_DIST) {
			tether.snap();
			tether.deleteit();
			continue;
		}

		Vector dir = delta.Normalize();

		float strainMin = TETHER_MAX_DIST * 0.3f;
		float prc = Max(0.0f, Min(1.0f, (dist - strainMin) / (TETHER_MAX_DIST - strainMin)));
		int r = int(prc * 255);
		Color c = Color(255, 200 - int(prc * 150), 200 - int(prc * 150), 255);

		if (thinkCount % 16 == 0) {
			bool wiggle = gpGlobals->time - tether.lastTwang < 0.5f;
			te_beaments(src->edict(), dst->edict(), "sprites/rope.spr", 0, 0, 4, 12 - int(prc * 6), wiggle ? 16 : 0, c, 0);
		}

		if (tether.shouldBreak()) {
			if (dist > TETHER_MAX_DIST * 0.9f) {
				tether.snap();
			}
			else {
				tether.twangSound();
			}

			if (g_player_afk[dst->entindex()] == 0) {
				ClientPrint(src->edict(), HUD_PRINTCENTER, (string("") + STRING(dst->pev->netname) + " woke up!\n").c_str());
			}

			te_killbeam(src->edict());
			te_tracer(dst->pev->origin, src->pev->origin);
			te_tracer(src->pev->origin, dst->pev->origin);
			tether.deleteit();
		}

		bool pullNoise = dist > strainMin && pullForce > tether.lastPullForce;

		if (pullNoise && gpGlobals->time - tether.lastPullNoise > 0.05f && gpGlobals->time - tether.lastTwang > 0.5f) {
			int p = 30 + int(prc * 10);
			float vol = Min(1.0f, prc) * 0.8f;
			PlaySound(src->edict(), CHAN_ITEM, stretch_snd, vol, 0.8f, 0, p, 0, true, src->pev->origin);
			PlaySound(dst->edict(), CHAN_ITEM, stretch_snd, vol, 0.8f, 0, p, 0, true, dst->pev->origin);
			tether.lastPullNoise = gpGlobals->time;
		}

		if (pullForce > strainMin && (pullForce - tether.lastPullForce) < -16 && gpGlobals->time - tether.lastTwang > 0.5f) {
			tether.twangSound();
			te_killbeam(src->edict());
			te_beaments(src->edict(), dst->edict(), "sprites/rope.spr", 0, 0, 2, 12, 16, c, 0);
		}

		tether.lastPullForce = pullForce;

		Vector addVel = dir * (pullForce * 100.0f * gpGlobals->frametime);
		apply_vel(dst, addVel, dst->pev->origin.z < src->pev->origin.z);
		//apply_vel(src, addVel*-0.1f);

		//println("PULL " + dist + " = " + addVel.ToString() + " " + g_Engine.frametime);
	}

	thinkCount++;
}


void MapInit(edict_t* pEdictList, int edictCount, int maxClients) {
	PrecacheSound(stretch_snd);
	PrecacheSound(twang_snd);
	PrecacheSound(snap_snd);

	g_engfuncs.pfnPrecacheModel("sprites/rope.spr");
	g_tethers.resize(0);
	g_player_afk.resize(0);
	g_player_afk.resize(33);
	g_lastTetherAttempt.resize(0);
	g_lastTetherAttempt.resize(33);

	hook_angelscript("TakeDamage", "TakeDamage_AfkAbuse", PlayerTakeDamage);
	g_disabled = g_disabled_maps.count(string(STRING(gpGlobals->mapname))) != 0;

	RETURN_META(MRES_IGNORED);
}

void MapInit_post(edict_t* pEdictList, int edictCount, int maxClients) {
	loadSoundCacheFile();
}

void StartFrame() {
	g_Scheduler.Think();
	RETURN_META(MRES_IGNORED);
}

void PluginInit() {
	g_dll_hooks.pfnServerActivate = MapInit;
	g_dll_hooks_post.pfnServerActivate = MapInit_post;
	g_dll_hooks.pfnStartFrame = StartFrame;
	g_dll_hooks.pfnPlayerPostThink = PlayerPostThink;

	g_Scheduler.SetInterval(tether_logic, 0.02f, -1);
	g_Scheduler.SetInterval(loadCrossPluginAfkState, 0.03125f, -1);

	if (gpGlobals->time > 4) {
		hook_angelscript("TakeDamage", "TakeDamage_AfkAbuse", PlayerTakeDamage);
		g_disabled = g_disabled_maps.count(string(STRING(gpGlobals->mapname))) != 0;
		loadSoundCacheFile();
	}
}

void PluginExit() {}