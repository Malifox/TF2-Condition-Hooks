#pragma semicolon 1
#pragma newdecls required

#include <tf2_stocks>
#include <sdktools>
#include <dhooks>
#include <tf2condhooks>
#include <virtual_address>

public Plugin myinfo =
{
	name = "[TF2] Condition Manager",
	author = "Scag, Malifox", // Original by Scag, x64 compatibility rewrite by Malifox
	description = "Condition add and removal control for developers",
	version = "1.1.0",
	url = "https://github.com/Scags/"
};

GlobalForward g_gfAddCond;
GlobalForward g_gfRemoveCond;

Address g_iOffset_m_pOuter; 	//CTFPlayerShared::m_pOuter
Address g_iOffset_m_RefEHandle;	//CBaseEntity::m_RefEHandle
Address g_iOffset_m_ConditionData; //CTFPlayerShared::m_ConditionData.m_Memory, CUtlVector< condition_source_t > + 0

enum struct condition_source_t // Offsets within CTFPlayerShared::m_ConditionData.m_Memory
{
	Address m_flExpireTime;
	Address m_pProvider;
	int iSizeOf;

	void Init()
	{
		// vfptr = 0
		// this.m_nPreventedDamageFromCondition = PointerSize; // int

		if (PointerSize == view_as<Address>(8))
		{
			this.m_flExpireTime = view_as<Address>(12);		// float
			this.m_pProvider = view_as<Address>(16);		// CNetworkHandle( CBaseEntity, m_pProvider )
			// this.m_bPrevActive = view_as<Address>(20);	// bool
			this.iSizeOf = 24;
		}
		else
		{
			this.m_flExpireTime = view_as<Address>(8);
			this.m_pProvider = view_as<Address>(12);
			// this.m_bPrevActive = view_as<Address>(16);
			this.iSizeOf = 20;
		}
	}
}
condition_source_t g_condition_source_t;

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int max)
{
	g_gfAddCond = new GlobalForward("TF2_OnAddCond", ET_Hook, Param_Cell, Param_CellByRef, Param_FloatByRef, Param_CellByRef);
	g_gfRemoveCond = new GlobalForward("TF2_OnRemoveCond", ET_Hook, Param_Cell, Param_CellByRef, Param_FloatByRef, Param_CellByRef);
	RegPluginLibrary("tf2condhooks");
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_iOffset_m_pOuter = view_as<Address>(FindSendPropInfo("CTFPlayer", "m_nHalloweenBombHeadStage") - FindSendPropInfo("CTFPlayer", "m_Shared") + 4);
	g_iOffset_m_ConditionData = PointerSize + PointerSize; // 8 / 16. vfptr + 1(bool) + padding
	g_condition_source_t.Init();

	GameData gamedata = new GameData("tf2.condmgr");
	if (!gamedata)
		SetFailState("Failed to find gamedata/tf2.condmgr.txt");

	DynamicDetour detour = DynamicDetour.FromConf(gamedata, "CTFPlayerShared::AddCond()");
	if (!detour || !detour.Enable(Hook_Pre, CTFPlayerShared_AddCond))
		SetFailState("Could not load hook for CTFPlayerShared::AddCond()!");
	delete detour;

	detour = DynamicDetour.FromConf(gamedata, "CTFPlayerShared::RemoveCond()");
	if (!detour || !detour.Enable(Hook_Pre, CTFPlayerShared_RemoveCond))
		SetFailState("Could not load hook for CTFPlayerShared::RemoveCond()!");
	delete detour;

//	h = DHookCreateDetourEx(conf, "CTFConditionList::Remove", CallConv_THISCALL, ReturnType_Bool, ThisPointer_Address);
//	DHookAddParam(h, HookParamType_Int);
//	DHookAddParam(h, HookParamType_Bool);
//	if (!DHookEnableDetour(h, false, CTFConditionList_Remove))
//		SetFailState("Could not load hook for CTFConditionList::Remove!");

	delete gamedata;
}

public void OnMapStart()
{
	if (!g_iOffset_m_RefEHandle)
		g_iOffset_m_RefEHandle = view_as<Address>(FindDataMapInfo(0, "m_angRotation") + 12);
}

MRESReturn CTFPlayerShared_AddCond(Address pThis, DHookParam hParams)
{
	int client = LoadEntityFromHandleAddress(LoadAddressFromAddress(pThis + g_iOffset_m_pOuter) + g_iOffset_m_RefEHandle);

	if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))	// Sanity check
		return MRES_Ignored;

	TFCond cond = hParams.Get(1);
	float time = hParams.Get(2);
	int provider = hParams.IsNull(3) ? -1 : hParams.Get(3);

	Action action;
	Call_StartForward(g_gfAddCond);
	Call_PushCell(client);
	Call_PushCellRef(cond);
	Call_PushFloatRef(time);
	Call_PushCellRef(provider);
	Call_Finish(action);

	if (action == Plugin_Changed)
	{
		hParams.Set(1, cond);
		hParams.Set(2, time);
		hParams.Set(3, provider);
		return MRES_ChangedHandled;
	}
	else if (action >= Plugin_Handled)
		return MRES_Supercede;

	return MRES_Ignored;
}

MRESReturn CTFPlayerShared_RemoveCond(Address pThis, DHookParam hParams)
{
	int client = LoadEntityFromHandleAddress(LoadAddressFromAddress(pThis + g_iOffset_m_pOuter) + g_iOffset_m_RefEHandle);
	TFCond cond = hParams.Get(1);
//	bool ignore_duration = hParams.Get(2);	// Unused
	Action action;

	// Sanity checks
	if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client) || !TF2_IsPlayerInCondition(client, cond))
		return MRES_Ignored;

	Address m_ConditionData_m_Memory = LoadAddressFromAddress(pThis + g_iOffset_m_ConditionData);
	Address offset = view_as<Address>(view_as<int>(cond) * g_condition_source_t.iSizeOf);
	Address m_ConditionData_m_Memory_cond = m_ConditionData_m_Memory + offset;

	float timeleft = LoadFromAddress(m_ConditionData_m_Memory_cond + g_condition_source_t.m_flExpireTime, NumberType_Int32);
	int provider = LoadEntityFromHandleAddress(m_ConditionData_m_Memory_cond + g_condition_source_t.m_pProvider);

	// Have to baby these coders that assume what they do will actually work
	float oldtime = timeleft;
	TFCond oldcond = cond;

	Call_StartForward(g_gfRemoveCond);
	Call_PushCell(client);
	Call_PushCellRef(cond);
//	Call_PushCellRef(ignore_duration);
	Call_PushFloatRef(timeleft);
	Call_PushCellRef(provider);
	Call_Finish(action);

	if (action == Plugin_Changed)
	{
		if (cond != oldcond)
		{
			hParams.Set(1, cond);
			offset = view_as<Address>(view_as<int>(cond) * g_condition_source_t.iSizeOf);
			m_ConditionData_m_Memory_cond = m_ConditionData_m_Memory + offset;
		}

		// If cond was changed, make sure they're in this cond
		if (TF2_IsPlayerInCondition(client, cond))
		{
			StoreToAddress(m_ConditionData_m_Memory_cond + g_condition_source_t.m_flExpireTime, timeleft, NumberType_Int32);
			StoreEntityToHandleAddress(m_ConditionData_m_Memory_cond + g_condition_source_t.m_pProvider, provider);
		}

		// If they only changed the time and return Changed, supercede to prevent removal
		if (timeleft != oldtime && cond == oldcond)
			return MRES_Supercede;

		return MRES_ChangedHandled;
	}
	else if (action >= Plugin_Handled)
		return MRES_Supercede;

	return MRES_Ignored;
}

// #define ptr 				Address
// #define nullptr 			Address_Null
// #define int(%1) 			view_as<int>(%1)
// #define Address(%1) 		view_as<Address>(%1)

// Hours of my life I'm not getting back
#if 0
// Legacy condition manager. This is the main reason why condition removal forward doesn't pass
// conds by reference. I'm *not* dying on that hill
public MRESReturn CTFConditionList_Remove(Address pThis, Handle hReturn, Handle hParams)
{
	TFCond cond = DHookGetParam(hParams, 1);
	if (cond >= view_as< TFCond >(32))		// Conds >= 32 are handled earlier
		return MRES_Ignored;

	// ignore_duration doesn't even work?
//	bool ignore_duration = DHookGetParam(hParams, 2);
	Action action;

	// To get the client (and all the other shit), gotta pull some magic out of my ass
	int client, provider;
	float timeleft;
	int conditioncount = Dereference(pThis, 16);
	ptr _conditions = ptr(Dereference(pThis, 4));	// CUtlVector< CTFCondition* > _conditions

	ptr pCond;
//	float			_min_duration;
//	float			_max_duration;
//	const ETFCond	_type;
//	CTFPlayer*		_outer;
//	CHandle< CBaseEntity >	_provider;

	for (int i = 0; i < conditioncount; ++i)
	{
		pCond = ptr(Dereference(_conditions, i * 4));
		if (!pCond)
			continue;

		if (view_as< TFCond >(Dereference(pCond, 12)) == cond)	// If this cond is the cond
		{
			timeleft = view_as< float >(Dereference(pCond, 8));			// _max_duration
			client = GetEntityFromAddress(ptr(Dereference(pCond, 16)));	// _outer
			provider = Dereference(pCond, 20) & 0xFFF;					// _provider
			break;
		}
	}

	if (!client || !IsPlayerAlive(client))	// Sanity check
		return MRES_Ignored;

//	PrintToChatAll("Remove");
	// Can't trust people to do it themselves, so do it for them
	if (!TF2_IsPlayerInCondition(client, cond))
		return MRES_Ignored;

	// Keep accustom to all the regular sourcemod shiz and make NULL ents -1
	// 4095 provider is -1
	if (provider == 0xFFF || !provider)
		provider = -1;

	Call_StartForward(g_gfRemoveCond);
	Call_PushCell(client);
	Call_PushCell(cond);
//	Call_PushCellRef(ignore_duration);
	Call_PushFloatRef(timeleft);
	Call_PushCell(provider);
	Call_Finish(action);

	if (action == Plugin_Changed)
	{
		StoreToAddress(Transpose(pCond, 8), view_as< int >(timeleft), NumberType_Int32);
		StoreToAddress(Transpose(pCond, 20), view_as< int >(GetEHandle(provider)), NumberType_Int32);

		// If they changed the time and return Changed, supercede to prevent removal
		if (timeleft != 0.0)
		{
			// Return true to prevent CTFPlayerShared::RemoveCond from changing the bits
			DHookSetReturn(hReturn, true);
			return MRES_Supercede;
		}

		return MRES_Ignored;
	}
	else if (action >= Plugin_Handled)
	{
		// Return true to prevent CTFPlayerShared::RemoveCond from changing the bits
		DHookSetReturn(hReturn, true);
		return MRES_Supercede;
	}

	return MRES_Ignored;
}
#endif

// stock Handle DHookCreateDetourEx(GameData conf, const char[] name, CallingConvention callConv, ReturnType returntype, ThisPointerType thisType)
// {
// 	Handle h = DHookCreateDetour(Address_Null, callConv, returntype, thisType);
// 	if (h)
// 		if (!DHookSetFromConf(h, conf, SDKConf_Signature, name))
// 			SetFailState("Could not set %s from config!", name);
// 	return h;
// }

// Props to nosoop
// stock int GetEntityFromAddress(ptr pEntity)
// {
// 	return Dereference(pEntity, FindDataMapInfo(0, "m_angRotation") + 12) & 0xFFF;
// }

// stock Address GetEHandle(int entity)
// {
// 	if (entity == -1)
// 		return ptr(-1);
// 	return ptr(Dereference(GetEntityAddress(entity), FindDataMapInfo(0, "m_angRotation") + 12));
// }

// stock int ReadInt(ptr pAddr)
// {
// 	if (pAddr == nullptr)
// 		return -1;

// 	return LoadFromAddress(pAddr, NumberType_Int32);
// }
// stock ptr Transpose(ptr pAddr, int iOffset)
// {
// 	return ptr(int(pAddr) + iOffset);
// }
// stock int Dereference(ptr pAddr, int iOffset = 0)
// {
// 	if (pAddr == nullptr)
// 		return -1;

// 	return ReadInt(Transpose(pAddr, iOffset));
// }