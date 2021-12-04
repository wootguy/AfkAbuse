
void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

class Tether {
	EHandle h_src;
	EHandle h_dst;
	float lastPullForce;
	float lastTwang = 0;
	float lastPullNoise = 0;
	
	Tether() {}
	
	Tether(CBaseEntity@ src, CBaseEntity@ dst) {
		h_src = EHandle(src);
		h_dst = EHandle(dst);
	}

	bool isValid() {
		CBasePlayer@ src = getSrc();
		CBasePlayer@ dst = getDst();
		
		return src !is null && src.IsConnected() and dst !is null && dst.IsConnected() and src.entindex() != dst.entindex();
	}
	
	bool shouldBreak() {
		CBasePlayer@ src = getSrc();
		CBasePlayer@ dst = getDst();
		
		return !src.IsAlive() or !dst.IsAlive() or g_player_afk[dst.entindex()] == 0;
	}
	
	void twangSound() {
		CBasePlayer@ src = getSrc();
		CBasePlayer@ dst = getDst();
		
		lastTwang = g_Engine.time;
		g_SoundSystem.PlaySound(src.edict(), CHAN_WEAPON, twang_snd, 1.0f, 0.8f, 0, Math.RandomLong(75, 85), 0, true, src.pev.origin);
		g_SoundSystem.PlaySound(dst.edict(), CHAN_WEAPON, twang_snd, 1.0f, 0.8f, 0, Math.RandomLong(75, 85), 0, true, dst.pev.origin);
	}
	
	void snap() {
		CBasePlayer@ src = getSrc();
		CBasePlayer@ dst = getDst();
		
		CBaseEntity@ world = g_EntityFuncs.Instance(0);
		
		if (src !is null) {
			g_SoundSystem.PlaySound(src.edict(), CHAN_WEAPON, snap_snd, 1.0f, 0.8f, 0, Math.RandomLong(95, 105), 0, true, src.pev.origin);
			src.TakeDamage(world.pev, world.pev, 20, DMG_CLUB | DMG_ALWAYSGIB);
			te_killbeam(src);
		}
		if (dst !is null) {
			g_SoundSystem.PlaySound(dst.edict(), CHAN_WEAPON, snap_snd, 1.0f, 0.8f, 0, Math.RandomLong(95, 105), 0, true, dst.pev.origin);
			dst.TakeDamage(world.pev, world.pev, 20, DMG_CLUB | DMG_ALWAYSGIB);
		}
		
		if (src !is null and dst !is null) {
			te_tracer(dst.pev.origin, src.pev.origin);
			te_tracer(src.pev.origin, dst.pev.origin);
		}
	}
	
	CBasePlayer@ getSrc() {
		return cast<CBasePlayer@>(h_src.GetEntity());
	}
	
	CBasePlayer@ getDst() {
		return cast<CBasePlayer@>(h_dst.GetEntity());
	}
	
	void delete() {
		h_src = null;
		h_dst = null;
	}
	
	bool isHooked(CBaseEntity@ plr) {
		if (!isValid()) {
			return false;
		}
		
		return plr.entindex() == getSrc().entindex() || plr.entindex() == getDst().entindex();
	}
}

Tether@ getTether(CBaseEntity@ p1, CBaseEntity@ p2) {
	for (uint i = 0; i < g_tethers.size(); i++) {
		Tether@ t = g_tethers[i];
		
		if (t.isHooked(p1) && t.isHooked(p2)) {
			return t;
		}
	}
	
	return null;
}

float TETHER_MIN_DIST = 128; // minumum distance before tether forces are applied
float TETHER_MAX_DIST = 1024; // max tether distance before snapping
int MAX_TETHERS = 64;
array<Tether> g_tethers;
array<int> g_player_afk(33);

string stretch_snd = "as_tether/stretch.wav";
string twang_snd = "as_tether/twang.wav";
string snap_snd = "as_tether/snap.wav";

void PluginInit() {
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "github" );
	
	g_Hooks.RegisterHook( Hooks::Player::PlayerUse, @PlayerUse );
	g_Hooks.RegisterHook( Hooks::Player::PlayerTakeDamage, @PlayerTakeDamage );
	
	g_Scheduler.SetInterval("tether_logic", 0.02f, -1);
	g_Scheduler.SetInterval("loadCrossPluginAfkState", 1.0f, -1);
}

void MapInit() {
	g_SoundSystem.PrecacheSound(stretch_snd);
	g_Game.PrecacheGeneric("sound/" + stretch_snd);
	
	g_SoundSystem.PrecacheSound(twang_snd);
	g_Game.PrecacheGeneric("sound/" + twang_snd);
	
	g_SoundSystem.PrecacheSound(snap_snd);
	g_Game.PrecacheGeneric("sound/" + snap_snd);
	
	g_Game.PrecacheModel("sprites/rope.spr");
	g_tethers.resize(0);
	g_player_afk.resize(0);
	g_player_afk.resize(33);
}

void loadCrossPluginAfkState() {
	CBaseEntity@ afkEnt = g_EntityFuncs.FindEntityByTargetname(null, "PlayerStatusPlugin");
	
	if (afkEnt is null) {
		return;
	}
	
	CustomKeyvalues@ customKeys = afkEnt.GetCustomKeyvalues();
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CustomKeyvalue key = customKeys.GetKeyvalue("$i_afk" + i);
		if (key.Exists()) {
			g_player_afk[i] = key.GetInteger();
		} 
	}
}

Vector getSwapDir(CBasePlayer@ plr) {
	Vector angles = plr.pev.v_angle;
	
	// snap to 90 degree angles
	angles.y = (int((angles.y + 180 + 45) / 90) * 90) - 180;
	angles.x = (int((angles.x + 180 + 45) / 90) * 90) - 180;
	
	// vertical unblocking has priority
	if (angles.x != 0) {
		angles.y = 0; 
	} else {
		angles.x = 0;
	}
	
	Math.MakeVectors( angles );
	
	return g_Engine.v_forward;
}

CBaseEntity@ TraceLook(CBasePlayer@ plr, Vector swapDir, float dist=1) {
	Vector vecSrc = plr.pev.origin;	
	
	plr.pev.solid = SOLID_NOT;
	
	TraceResult tr;
	Vector dir = swapDir * dist;
	HULL_NUMBER hullType = plr.pev.flags & FL_DUCKING != 0 ? head_hull : human_hull;
	g_Utility.TraceHull( vecSrc, vecSrc + dir, dont_ignore_monsters, hullType, null, tr );
	
	// try again in case the blocker is on a slope or stair
	if (swapDir.z == 0 and g_EntityFuncs.Instance( tr.pHit ) !is null and g_EntityFuncs.Instance( tr.pHit ).IsBSPModel()) {
		Vector verticalDir = Vector(0,0,36);
		if (plr.pev.flags & FL_ONGROUND == 0) {
			// probably on the ceiling, so try starting the trace lower instead (e.g. negative gravity or ladder)
			verticalDir.z = -36; 
		}
		
		g_Utility.TraceHull( vecSrc, vecSrc + verticalDir, dont_ignore_monsters, hullType, null, tr );
		if (g_EntityFuncs.Instance( tr.pHit ) is null or g_EntityFuncs.Instance( tr.pHit ).IsBSPModel()) {
			g_Utility.TraceHull( tr.vecEndPos, tr.vecEndPos + dir, dont_ignore_monsters, hullType, null, tr );
		}
	}
	
	plr.pev.solid = SOLID_SLIDEBOX;

	return g_EntityFuncs.Instance( tr.pHit );
}

string format_float(float f) {
	uint decimal = uint(((f - int(f)) * 10)) % 10;
	return "" + int(f) + "." + decimal;
}

CBaseEntity@ getBestTarget(CBasePlayer@ plr, Vector swapDir) {
	array<CBaseEntity@> targets;

	float bestDist = 9e99;
	int bestIdx = -1;

	for (int i = 0; i < 4; i++) {
		CBaseEntity@ target = TraceLook(plr, swapDir);
		
		if (target is null or !target.IsPlayer()) {
			break;
		}
		
		targets.insertLast(target);
		target.pev.solid = SOLID_NOT;
		
		float dist = (target.pev.origin - plr.pev.origin).Length();
		
		if (dist < bestDist) {
			bestDist = dist;
			bestIdx = i;
		}
	}
	
	for (uint i = 0; i < targets.length(); i++) {
		targets[i].pev.solid = SOLID_SLIDEBOX;
	}
	
	return bestIdx != -1 ? targets[bestIdx] : null;
}

class Color { 
	uint8 r, g, b, a;
	
	Color() { r = g = b = a = 0; }
	Color(uint8 _r, uint8 _g, uint8 _b, uint8 _a = 255 ) { r = _r; g = _g; b = _b; a = _a; }
	Color (Vector v) { r = int(v.x); g = int(v.y); b = int(v.z); a = 255; }
	string ToString() { return "" + r + " " + g + " " + b + " " + a; }
}

const Color RED(255,0,0);
const Color GREEN(0,255,0);
const Color BLUE(0,0,255);

void te_beaments(CBaseEntity@ start, CBaseEntity@ end, 
	string sprite="sprites/laserbeam.spr", int frameStart=0, 
	int frameRate=100, int life=10, int width=32, int noise=1, 
	Color c=PURPLE, int scroll=32,
	NetworkMessageDest msgType=MSG_BROADCAST, edict_t@ dest=null) {
	NetworkMessage m(msgType, NetworkMessages::SVC_TEMPENTITY, dest);
	m.WriteByte(TE_BEAMENTS);
	m.WriteShort(start.entindex());
	m.WriteShort(end.entindex());
	m.WriteShort(g_EngineFuncs.ModelIndex(sprite));
	m.WriteByte(frameStart);
	m.WriteByte(frameRate);
	m.WriteByte(life);
	m.WriteByte(width);
	m.WriteByte(noise);
	m.WriteByte(c.r);
	m.WriteByte(c.g);
	m.WriteByte(c.b);
	m.WriteByte(c.a); // actually brightness
	m.WriteByte(scroll);
	m.End();
}

void te_tracer(Vector start, Vector end, 
	NetworkMessageDest msgType=MSG_BROADCAST, edict_t@ dest=null)
{
	NetworkMessage m(msgType, NetworkMessages::SVC_TEMPENTITY, dest);
	m.WriteByte(TE_TRACER);
	m.WriteCoord(start.x);
	m.WriteCoord(start.y);
	m.WriteCoord(start.z);
	m.WriteCoord(end.x);
	m.WriteCoord(end.y);
	m.WriteCoord(end.z);
	m.End();
}

HookReturnCode PlayerUse( CBasePlayer@ plr, uint& out uiFlags ) {	
	if (plr.m_afButtonPressed & IN_RELOAD == 0) {
		return HOOK_CONTINUE;
	}
	
	Vector swapDir = getSwapDir(plr);
	CBaseEntity@ target = getBestTarget(plr, swapDir);
	
	if (target is null) {
		return HOOK_CONTINUE;
	}
	
	Tether@ existingTether = getTether(plr, target);
	
	if (existingTether !is null) {
		existingTether.delete();
		g_SoundSystem.PlaySound(plr.edict(), CHAN_ITEM, "weapons/bgrapple_release.wav", 1.0f, 0.8f, 0, 150, 0, true, plr.pev.origin);
	} else {
		if (int(g_tethers.size()) >= MAX_TETHERS) {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Too many tethers are active!\n");
			return HOOK_CONTINUE;
		}
		if (g_player_afk[target.entindex()] == 0) {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Only AFK players can be abused.\n");
			return HOOK_CONTINUE;
		}
		g_tethers.insertLast(Tether(plr, target));
		g_SoundSystem.PlaySound(plr.edict(), CHAN_ITEM, "weapons/bgrapple_fire.wav", 1.0f, 0.8f, 0, 150, 0, true, plr.pev.origin);
	}
	
	return HOOK_CONTINUE;
}

HookReturnCode PlayerTakeDamage(DamageInfo@ info) {
	CBasePlayer@ victim = cast<CBasePlayer@>(g_EntityFuncs.Instance(info.pVictim.pev));
	CBaseEntity@ attacker = @info.pAttacker;
	
	if (g_player_afk[victim.entindex()] > 0 and attacker !is null && attacker.IsPlayer()) {		
		g_EngineFuncs.MakeVectors(attacker.pev.v_angle);
		victim.pev.velocity = victim.pev.velocity + g_Engine.v_forward*20*Math.max(20, info.flDamage);
		unstick_from_ground(victim);
	}
	
	return HOOK_CONTINUE;
}

void unstick_from_ground(CBasePlayer@ plr) {
	if (plr.pev.velocity.z > 10 && plr.pev.flags & FL_ONGROUND != 0) {
		// check if moving up would get player stuck in something
		TraceResult tr;
		HULL_NUMBER hullType = plr.pev.flags & FL_DUCKING != 0 ? head_hull : human_hull;
		Vector pos = plr.pev.origin;
		g_Utility.TraceHull( pos, pos + Vector(0,0,2), dont_ignore_monsters, hullType, null, tr );
		
		if (tr.flFraction >= 1.0f) {
			plr.pev.origin.z += 2;
		}
	}
}

void apply_vel(CBasePlayer@ target, Vector addVel, bool shouldLadderBoost) {
	target.pev.velocity = target.pev.velocity + addVel;
	
	unstick_from_ground(target);
	
	if (target.IsOnLadder()) {
		int oldPressed = target.m_afButtonPressed;
	
		// run movement code so player jumps off ladder, otherwise player gets stuck.
		g_EngineFuncs.RunPlayerMove( target.edict(), target.pev.angles, 
			target.pev.velocity.x, target.pev.velocity.y, target.pev.velocity.z, 
			target.pev.button | IN_JUMP, target.pev.impulse, uint8( 10 ) );
		
		// prevent afk checking plugin detecting this as coming back from AFK
		target.m_afButtonPressed = oldPressed;
		
		if (shouldLadderBoost)
			target.pev.velocity.z = 250;
	}
}

void te_killbeam(CBaseEntity@ target, 
	NetworkMessageDest msgType=MSG_BROADCAST, edict_t@ dest=null)
{
	NetworkMessage m(msgType, NetworkMessages::SVC_TEMPENTITY, dest);
	m.WriteByte(TE_KILLBEAM);
	m.WriteShort(target.entindex());
	m.End();
}

int thinkCount = 0;

void tether_logic() {		
	for (int k = 0; k < int(g_tethers.size()); k++) {
		Tether@ tether = g_tethers[k];
		
		if (!tether.isValid()) {		
			g_tethers.removeAt(k);
			k--;
			continue;
		}
	
		CBasePlayer@ src = tether.getSrc();
		CBasePlayer@ dst = tether.getDst();
		
		Vector delta = src.pev.origin - dst.pev.origin;
		float dist = delta.Length();
		float pullForce = dist - TETHER_MIN_DIST;
		
		if (pullForce < 0) {
			pullForce = 0;
		}
		
		if (dist > TETHER_MAX_DIST) {
			tether.snap();
			tether.delete();
			continue;
		}
		
		Vector dir = delta.Normalize();
		
		float strainMin = TETHER_MAX_DIST*0.3f;
		float prc = Math.max(0.0f, Math.min(1.0f, (dist-strainMin) / (TETHER_MAX_DIST-strainMin)));
		int r = int(prc*255);
		Color c = Color(255, 200 - int(prc*150), 200 - int(prc*150), 255);
		
		if (thinkCount % 16 == 0) {
			bool wiggle = g_Engine.time - tether.lastTwang < 0.5f;
			te_beaments(src, dst, "sprites/rope.spr", 0, 0, 4, 12-int(prc*6), wiggle ? 16 : 0, c, 0);
		}
		
		if (tether.shouldBreak()) {
			if (dist > TETHER_MAX_DIST*0.9f) {
				tether.snap();
			} else {
				tether.twangSound();
			}
			
			if (g_player_afk[dst.entindex()] == 0) {
				g_PlayerFuncs.ClientPrint(src, HUD_PRINTCENTER, "" + dst.pev.netname + " woke up!\n");
			}
			
			te_killbeam(src);
			te_tracer(dst.pev.origin, src.pev.origin);
			te_tracer(src.pev.origin, dst.pev.origin);
			tether.delete();
		}
		
		bool pullNoise = dist > strainMin and pullForce > tether.lastPullForce;
		
		if (pullNoise and g_Engine.time - tether.lastPullNoise > 0.05f and g_Engine.time - tether.lastTwang > 0.5f) {
			int p = 30 + int(prc*10);
			float vol = Math.min(1.0f, prc)*0.8f;
			g_SoundSystem.PlaySound(src.edict(), CHAN_ITEM, stretch_snd, vol, 0.8f, 0, p, 0, true, src.pev.origin);
			g_SoundSystem.PlaySound(dst.edict(), CHAN_ITEM, stretch_snd, vol, 0.8f, 0, p, 0, true, dst.pev.origin); 
			tether.lastPullNoise = g_Engine.time;
		}
		
		if (pullForce > strainMin and (pullForce - tether.lastPullForce) < -16 and g_Engine.time - tether.lastTwang > 0.5f) {
			tether.twangSound();
			te_killbeam(src);
			te_beaments(src, dst, "sprites/rope.spr", 0, 0, 2, 12, 16, c, 0);
		}
		
		tether.lastPullForce = pullForce;
		
		Vector addVel = dir * (pullForce*100.0f*g_Engine.frametime);
		apply_vel(dst, addVel, dst.pev.origin.z < src.pev.origin.z);
		//apply_vel(src, addVel*-0.1f);
		
		//println("PULL " + dist + " = " + addVel.ToString() + " " + g_Engine.frametime);
	}
	
	thinkCount++;
}
