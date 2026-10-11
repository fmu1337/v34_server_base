/*
 * Client "status" / "ping" are engine commands: the engine runs them before
 * the game DLL, so RegConsoleCmd("status") never sees them from a client.
 * ProtectCMDS hooks CGameClient::ExecuteStringCommand; here the two commands
 * are sent to SMAC's protected sm_status / sm_ping (smac_status.smx) instead.
 */
#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>

public Plugin myinfo =
{
	name = "ProtectCMDS: status/ping",
	author = "v34_server_base",
	description = "Routes client status/ping to SMAC Status Protect",
	version = "1.0",
	url = "https://github.com/fmu1337/v34_server_base"
};

public Action ProtectCMDS_OnClientCommand(int client, const char[] command)
{
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Continue;

	char cmd[16];
	int len = BreakString(command, cmd, sizeof(cmd));
	if (len == -1 && !cmd[0])
		return Plugin_Continue;

	if (StrEqual(cmd, "status", false))
	{
		if (CommandExists("sm_status"))
			FakeClientCommandEx(client, "sm_status");
		return Plugin_Handled;
	}
	if (StrEqual(cmd, "ping", false))
	{
		if (CommandExists("sm_ping"))
			FakeClientCommandEx(client, "sm_ping");
		return Plugin_Handled;
	}
	return Plugin_Continue;
}
