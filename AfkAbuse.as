
void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

CCVar@ g_cooldown;

class PlayerState
{
	array<int> hook_targets;
}

array<PlayerState> g_states(33);

void PluginInit() {
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "github" );
	
	g_Hooks.RegisterHook( Hooks::Player::PlayerUse, @PlayerUse );
	g_Hooks.RegisterHook( Hooks::Player::PlayerPreThink, @PlayerPreThink );
	g_Hooks.RegisterHook( Hooks::Player::ClientSay, @ClientSay );
	g_Hooks.RegisterHook( Hooks::Player::PlayerTakeDamage, @PlayerTakeDamage );
	
	@g_cooldown = CCVar("cooldown", 0.6f, "Time before a swapped player can be swapped with again", ConCommandFlag::AdminOnly);
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

class Color
{ 
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
	NetworkMessageDest msgType=MSG_BROADCAST, edict_t@ dest=null)
{
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

HookReturnCode PlayerUse( CBasePlayer@ plr, uint& out uiFlags ) {	
	if (plr.m_afButtonLast & IN_RELOAD == 0) {
		return HOOK_CONTINUE;
	}
	
	Vector swapDir = getSwapDir(plr);
	CBaseEntity@ target = getBestTarget(plr, swapDir);
	
	if (target is null) {
		return HOOK_CONTINUE;
	}
	
	PlayerState@ state = g_states[plr.entindex()];
	
	for (uint i = 0; i < state.hook_targets.size(); i++) {
		if (state.hook_targets[i] == target.entindex()) {
			return HOOK_CONTINUE;
		}
	}
	
	state.hook_targets.insertLast(target.entindex());
	println("NEW HOOK");
	
	//uiFlags |= PlrHook_SkipUse;
	
	return HOOK_CONTINUE;
}

HookReturnCode PlayerPreThink(CBasePlayer@ plr, uint& out) {
	hook_logic(plr);

	return HOOK_CONTINUE;
}

HookReturnCode PlayerTakeDamage(DamageInfo@ info)
{
	CBasePlayer@ victim = cast<CBasePlayer@>(g_EntityFuncs.Instance(info.pVictim.pev));
	CBaseEntity@ attacker = @info.pAttacker;
	
	if (attacker !is null && attacker.IsPlayer()) {		
		g_EngineFuncs.MakeVectors(attacker.pev.v_angle);
		victim.pev.velocity = g_Engine.v_forward*10*info.flDamage;
	}
	
	return HOOK_CONTINUE;
}

void te_bubbles(Vector mins, Vector maxs, float height=256.0f, 
	string sprite="sprites/bubble.spr", uint8 count=64, float speed=16.0f,
	NetworkMessageDest msgType=MSG_BROADCAST, edict_t@ dest=null)
{
	NetworkMessage m(msgType, NetworkMessages::SVC_TEMPENTITY, dest);
	m.WriteByte(TE_BUBBLES);
	m.WriteCoord(mins.x);
	m.WriteCoord(mins.y);
	m.WriteCoord(mins.z);
	m.WriteCoord(maxs.x);
	m.WriteCoord(maxs.y);
	m.WriteCoord(maxs.z);
	m.WriteCoord(height);
	m.WriteShort(g_EngineFuncs.ModelIndex(sprite));
	m.WriteByte(count);
	m.WriteCoord(speed);
	m.End();
}

void music_notes(EHandle h_plr, bool flip) {
	CBaseEntity@ ent = h_plr;
	if (ent is null) {
		return;
	}
	
	g_EngineFuncs.MakeVectors(ent.pev.v_angle);
	Vector headPos = ent.pev.origin + ent.pev.view_ofs;
	Vector leftEar = headPos - g_Engine.v_right*6;
	Vector rightEar = headPos + g_Engine.v_right*6;
	
	
	//te_playersprites(plr, "sprites/bubble.spr", 1);
	//te_fizz(plr, "sprites/bubble.spr", 1);
	if (flip)
		te_bubbles(leftEar, leftEar, 256, "sprites/bubble.spr", 1, 16);
	else
		te_bubbles(rightEar, rightEar, 256, "sprites/bubble.spr", 1, 16);
	
	g_Scheduler.SetTimeout("music_notes", 0.05, h_plr, !flip);
}

void apply_vel(CBasePlayer@ target, Vector addVel, bool shouldDuck) {
	target.pev.velocity = target.pev.velocity + addVel;
	if (target.pev.velocity.z > 10 && target.pev.flags & FL_ONGROUND != 0) {
		target.pev.origin.z += 1;
	}	
	
	
	if (target.IsOnLadder()) {
		target.pev.button |= IN_JUMP;
		g_EngineFuncs.RunPlayerMove( target.edict(), target.pev.angles, 
			target.pev.velocity.x, target.pev.velocity.y, target.pev.velocity.z, 
			target.pev.button, target.pev.impulse, uint8( 1 ) );
		
		if (target.pev.velocity.z < 0) {
			target.pev.velocity.z += 200;
		}
		
		println("JUMP NIGGA");
	}
	if (shouldDuck) {
			
		//target.pev.flags |= FL_DUCKING;
		//target.pev.flDuckTime = 26;
		//target.pev.origin.z -= 18;
		//target.Duck();
		target.pev.button |= IN_DUCK;
		target.m_afButtonLast |= IN_DUCK;
		/*
		g_EngineFuncs.RunPlayerMove( target.edict(), target.pev.angles, 
				target.pev.velocity.x, target.pev.velocity.y, target.pev.velocity.z, 
				target.pev.button, target.pev.impulse, uint8( 1 ) );
				*/
			
		println("DUCK NIGGA " + target.pev.flDuckTime);
	}
}

void hook_logic(CBasePlayer@ plr) {
	PlayerState@ state = g_states[plr.entindex()];
		
	for (int k = 0; k < int(state.hook_targets.size()); k++) {
		CBasePlayer@ target = g_PlayerFuncs.FindPlayerByIndex(state.hook_targets[k]);
		
		if (target is null or !target.IsAlive()) {
			state.hook_targets.removeAt(k);
			k--;
			continue;
		}
		
		Vector delta = plr.pev.origin - target.pev.origin;
		float dist = delta.Length() - 64;
		
		if (dist < 0) {
			dist = 0;
		}
		
		Vector dir = delta.Normalize();
		
		te_beaments(plr, target, "sprites/laserbeam.spr", 0, 100, 1, 8, 0, Color(0, 255, 255, 128), 32);
		
		Vector addVel = dir * (dist*10.0f*g_Engine.frametime);
		bool shouldDuck = plr.pev.flags & FL_DUCKING != 0;
		apply_vel(target, addVel, shouldDuck);
		//apply_vel(plr, addVel*-0.1f);
		
		//println("PULL " + dist + " = " + addVel.ToString() + " " + g_Engine.frametime);
	}
}

bool doCommand(CBasePlayer@ plr, const CCommand@ args)
{	
	if ( args.ArgC() > 0 )
	{
		if ( args[0] == ".afkabuse" )
		{
			g_PlayerFuncs.SayText(plr, "WOWWWWOWOW\n");			
			return true;
		}
		if (args[0] == 'd') {
		
			CBaseEntity@ ent = null;
			do {
				@ent = g_EntityFuncs.FindEntityByClassname(ent, "info_target"); 
				if (ent !is null)
				{
					if (@ent.pev.aiment == @plr.edict() && string(ent.pev.model).Find("hat") != String::INVALID_INDEX) {
						break;
					}
				}
			} while (ent !is null);
		
			music_notes(EHandle(plr), false);
			
			return true;
		}
	}
	return false;
}

HookReturnCode ClientSay( SayParameters@ pParams )
{	
	CBasePlayer@ plr = pParams.GetPlayer();
	const CCommand@ args = pParams.GetArguments();
	
	if (doCommand(plr, args))
	{
		pParams.ShouldHide = true;
		return HOOK_HANDLED;
	}
	
	return HOOK_CONTINUE;
}

CClientCommand _antiblock("pickup", "Anti-rush status", @consoleCmd );

void consoleCmd( const CCommand@ args )
{
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	doCommand(plr, args);
}