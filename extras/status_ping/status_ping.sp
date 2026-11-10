/*
 * Client status/ping -> SMAC's sm_status/sm_ping; server console and rcon get
 * the engine's own output. Needs the hidecmds engine patch (docs/PATCHES.md),
 * otherwise the engine answers clients before the game sees the command;
 * ProtectCMDS' forward covers that case.
 */
#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>

public Plugin myinfo =
{
	name = "status/ping",
	author = "v34_server_base",
	description = "Client status/ping -> SMAC sm_status/sm_ping",
	version = "2.0",
	url = "https://github.com/fmu1337/v34_server_base"
};

public void OnPluginStart()
{
	RegConsoleCmd("status", Cmd_Status);
	RegConsoleCmd("ping", Cmd_Ping);
}

public Action Cmd_Status(int client, int args)
{
	return Redirect(client, "sm_status");
}

public Action Cmd_Ping(int client, int args)
{
	return Redirect(client, "sm_ping");
}

// Engine without hidecmds: ProtectCMDS sees the command before the engine.
public Action ProtectCMDS_OnClientCommand(int client, const char[] command)
{
	char cmd[16];
	BreakString(command, cmd, sizeof(cmd));
	if (StrEqual(cmd, "status", false))
		return Redirect(client, "sm_status");
	if (StrEqual(cmd, "ping", false))
		return Redirect(client, "sm_ping");
	return Plugin_Continue;
}

Action Redirect(int client, const char[] smcmd)
{
	if (client <= 0)
		return Plugin_Continue;
	if (IsClientInGame(client) && CommandExists(smcmd))
		FakeClientCommandEx(client, smcmd);
	return Plugin_Handled;
}
