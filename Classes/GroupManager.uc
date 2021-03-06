/*==============================================================================
   TrialGroup
   Copyright (C) 2010 - 2014 Eliot Van Uytfanghe

   This program is free software; you can redistribute and/or modify
   it under the terms of the Open Unreal Mod License version 1.1.
==============================================================================*/
class GroupManager extends Mutator
	dependson(GroupObjective)
	cacheexempt
	hidedropdown
	hidecategories(Lighting,LightColor,Karma,Mutator,Force,Collision,Sound)
	placeable;

/** The amount of members a group has to have. */
var() int MaxGroupSize;

/** The maximum distance a player can be away from its player spawn when using group commands such as JoinGroup. */
var() float GroupFunctionDistanceLimit;

/** The default group name to be given to wanderers. */
var() string GeneratedGroupName;

var(Modules) class<GroupLocalMessage>
	GroupMessageClass, PlayerMessageClass,
	TaskMessageClass, CounterMessageClass,
	GroupProgressMessageClass;
var(Modules) class<GroupInstance> GroupInstanceClass;
var(Modules) class<GroupInteraction> GroupInteractionClass;
var(Modules) class<GroupCounter> GroupCounterClass;
var(Modules) class<GroupRules> GroupRulesClass;
var(Modules) class<GroupPlayerLinkedReplicationInfo> GroupPlayerReplicationInfoClass;

struct sGroup
{
	var string GroupName;
	var array<Controller> Members;
	var transient float NextAllowedCountDownTime;
	var array<GroupTaskComplete> CompletedTasks;
	var GroupInstance Instance;
};

var editconst noexport array<sGroup> Groups;
var editconst noexport array<GroupTaskComplete> Tasks, OptionalTasks;
var editconst const noexport Color GroupColor;
var private editconst noexport int NextGroupId, CurrentWanderersGroupId;
var editconst int MaxCountDownTicks, MinCountDownTicks;

// Operator from ServerBTimes.u
static final operator(101) string $( coerce string A, Color B )
{
	return A $ (Chr( 0x1B ) $ (Chr( Max( B.R, 1 )  ) $ Chr( Max( B.G, 1 ) ) $ Chr( Max( B.B, 1 ) )));
}

// Operator from ServerBTimes.u
static final operator(102) string $( Color B, coerce string A )
{
	return (Chr( 0x1B ) $ (Chr( Max( B.R, 1 ) ) $ Chr( Max( B.G, 1 ) ) $ Chr( Max( B.B, 1 ) ))) $ A;
}

event PreBeginPlay()
{
	super.PreBeginPlay();
	Level.Game.BaseMutator.AddMutator( self );
}

event PostBeginPlay()
{
	local GroupRules gr;

	super.PostBeginPlay();
	SetTimer( 5, true );

	gr = Spawn( GroupRulesClass, self );
	gr.Manager = self;
	Level.Game.AddGameModifier( gr );
}

function RegisterTask( GroupTaskComplete task )
{
	if( task.bOptionalTask )
	{
		OptionalTasks[OptionalTasks.Length] = task;
		return;
	}
	Tasks[Tasks.Length] = task;
}

event Timer()
{
	// try clear groups that have became empty by leavers...
	ClearEmptyGroups();
}

final function int CreateWanderersGroup()
{
	local int groupIndex;

	groupIndex = CreateGroup( GeneratedGroupName $ "-" $ NextGroupId );
	if( groupindex == -1 )
	{
		Warn( "Failed to generate a Wanderers group" );
		return -1;
	}

	CurrentWanderersGroupId = Groups[groupIndex].Instance.GroupId;
	return groupIndex;
}

final function JoinWanderersGroup( PlayerController PC )
{
	local int groupIndex;

	groupIndex = GetGroupIndexById( CurrentWanderersGroupId );
	if( groupIndex == -1 )
	{
		groupIndex = CreateWanderersGroup();
		if( groupIndex == -1 )
		{
			Warn( "Failed to join a Wanderers group" );
			return;
		}
	}

	if( Groups[groupIndex].Members.Length == MaxGroupSize )
	{
		groupIndex = CreateWanderersGroup();
		if( groupIndex == -1 )
		{
			Warn( "Failed to generate a new Wanderers group" );
			return;
		}
	}
	JoinGroup( PC, Groups[groupIndex].GroupName );
}

function ModifyPlayer( Pawn other )
{
	local GroupPlayerLinkedReplicationInfo LRI;

	super.ModifyPlayer( other );
	if( other == none )
	{
		return;
	}

	if( ASPlayerReplicationInfo(other.PlayerReplicationInfo) != none && string(other.LastStartSpot.Class) != "BTServer_CheckPointNavigation" )
	{
		ASPlayerReplicationInfo(other.PlayerReplicationInfo).DisabledObjectivesCount = 0;
		ASPlayerReplicationInfo(other.PlayerReplicationInfo).DisabledFinalObjective = 0;
	}

	if( PlayerController(other.Controller) == none )
	{
		return;
	}

	other.bAlwaysRelevant = true;

	LRI = GetGroupPlayerReplicationInfo( other.Controller.PlayerReplicationInfo );
	if( LRI != none )
	{
		if( LRI.bIsWanderer )
		{
			JoinWanderersGroup( PlayerController(other.Controller) );
			LRI.bIsWanderer = false;
		}
		else if( LRI.PlayerGroup == none )
		{
			SendPlayerMessage( other.Controller, " Use console command 'JoinGroup <GroupName>' to join/create a group!" );
		}
	}
}

function Mutate( string cmd, PlayerController sender )
{
	local string reqGroupName;

	// lol this happens to be true sometimes...
	if( sender == none )
		return;

	if( Left( cmd, 9 ) ~= "JoinGroup" )
	{
		reqGroupName = Mid( cmd, 10 );
		if( reqGroupName != "" )
		{
			// Clear the groups of disconnected players.
			// Important to not use ClearEmptyGroup by index as it may destroy the group (about to be joined) as a result.
			ClearEmptyGroups();
			JoinGroup( sender, reqGroupName );
		}
		else
		{
			sender.ClientMessage( GroupColor $ "Please specifiy a group name!" );
		}
		return;
	}
	else if( cmd ~= "LeaveGroup" )
	{
		LeaveGroup( sender );
		return;
	}
	else if( Left( cmd, 14 ) ~= "GroupCountDown" )
	{
		CountDownGroup( sender, int(Mid( cmd, 15)) );
		return;
	}
	super.Mutate( cmd, sender );
}

final function JoinGroup( PlayerController PC, string groupName )
{
	local int groupindex;
	local string originalName;

	if( PC.Pawn == none )
	{
		PC.ClientMessage( GroupColor $ "Sorry you cannot join a group when you are dead!" );
		return;
	}

	if( VSize( PC.Pawn.LastStartSpot.Location - PC.Pawn.Location ) >= GroupFunctionDistanceLimit )
	{
		PC.ClientMessage( GroupColor $ "Sorry you can only join a group when you are near your spawn location" );
		return;
	}

	// Apply same rules as console command "SetName".
	originalName = groupName;
	if( Len( groupName ) > 20 )
		groupName = Left( groupName, 20 );

	ReplaceText( groupName, " ", "_" );
	ReplaceText( groupName, "\"", "" );

	if( originalName != groupName )
	{
		PC.ClientMessage( GroupColor $ "The name was changed to" @ groupName );
	}

    groupindex = GetGroupIndexByName( groupName );
	if( groupindex != -1 )
	{
		if( GetMemberIndexbyGroupIndex( PC, groupindex ) != -1 )
		{
			PC.ClientMessage( GroupColor $ "Sorry you're already in this group!" );
		}
		else
		{
			if( Groups[groupindex].Members.Length >= MaxGroupSize )
			{
				PC.ClientMessage( GroupColor $ "Sorry the group you tried to join is at its capacity!" );
			}
			else
			{
				if( !LeaveGroup( PC ) )
				{
					PC.ClientMessage( GroupColor $ "Cannot join group. Something went wrong when leaving your previous group!" );
					return;
				}

				// Get new index, because LeaveGroup may remove empty groups, moving the index.
				groupindex = GetGroupIndexByName( groupName );
				if( groupindex == -1 )
				{
					Warn( "This should never happen. Group not found after leaving previous group!" );
					return;
				}

				GroupSendMessage( groupindex, PC.PlayerReplicationInfo.PlayerName @ "joined your group!" );
				AddPlayerToGroup( PC, groupindex );
				SendPlayerMessage( PC, "You joined the \"" $ Groups[groupindex].GroupName $ "\" group" );
			}
		}
	}
	else
	{
		if( !LeaveGroup( PC ) )
		{
			PC.ClientMessage( GroupColor $ "Cannot create group. Something went wrong when leaving your previous group!" );
			return;
		}

		groupindex = CreateGroup( groupName, PC );
		if( groupindex == -1 )
		{
			PC.ClientMessage( GroupColor $ "Sorry something went wrong when creating the group!" );
			return;
		}
		SendPlayerMessage( PC, "You created the \"" $ Groups[groupindex].GroupName $ "\" group" );
	}
}

final function bool AddPlayerToGroup( PlayerController PC, int groupIndex )
{
	local GroupPlayerLinkedReplicationInfo LRI;

	// Log( "AddPlayerToGroup(" $ PC $ ", " $ Groups[groupindex].GroupName $ ")" );
	LRI = GetGroupPlayerReplicationInfo( PC.PlayerReplicationInfo );
	if( LRI != none )
	{
		LRI.PlayerGroup = Groups[groupIndex].Instance;
		LRI.PlayerGroupId = LRI.PlayerGroup.GroupId;
		if( LRI.PlayerGroup == none )
		{
			Warn( "PlayerGroup was none when adding player to group" );
		}
		else if( LRI.PlayerGroup.Commander == none )
		{
			LRI.PlayerGroup.Commander = LRI;
		}
		else
		{
			LRI.NextMember = LRI.PlayerGroup.Commander;
			LRI.PlayerGroup.Commander = LRI;
		}
	}
	else
	{
		Warn( "Couldn't find LRI when adding player to group" );
	}
	Groups[groupIndex].Members[Groups[groupIndex].Members.Length] = PC;
	return true;
}

final function bool RemoveMemberFromGroup( int memberIndex, int groupIndex )
{
	local GroupPlayerLinkedReplicationInfo LRI, member;
	local Controller player;
	local GroupInstance groupInstance;

	// Log( "RemoveMemberFromGroup(" $ Groups[groupIndex].Members[memberIndex].GetHumanReadableName() $ ", " $ Groups[groupindex].GroupName $ ")" );
	if( groupIndex >= Groups.Length || memberindex >= Groups[groupIndex].Members.Length )
	{
		return false;
	}

	// @player == none indicates a GAME leaver, all references are lost.
	// TODO: Fixup members link list in such cases.
	player = Groups[groupIndex].Members[memberindex];
	Groups[groupIndex].Members.Remove( memberIndex, 1 );
	-- memberIndex;	// To find NextMember without a Controller reference.
	if( Groups[groupIndex].Members.Length == 0 )
	{
		return true;
	}

	if( player != none )
	{
		LRI = GetGroupPlayerReplicationInfo( player.PlayerReplicationInfo );
		if( LRI != none )
		{
			groupInstance = LRI.PlayerGroup;
			LRI.PlayerGroup = none;
			LRI.PlayerGroupId = -1;
			LRI.NextMember = none;
		}
	}
	else
	{
		groupInstance = Groups[groupIndex].Instance;
	}

	if( groupInstance != none )
	{
		if( LRI != none )
		{
			// Bypass the broken link.
			if( groupInstance.Commander == LRI )
			{
				groupInstance.Commander = LRI.NextMember;
			}
			else
			{
				for( member = groupInstance.Commander; member != none; member = member.NextMember )
				{
					if( member.NextMember == LRI )
					{
						member.NextMember = LRI.NextMember;
						break;
					}
				}
			}
		}
		// If true then the group's members linked list is broken. Fix it. This happens if a player leaves the game without leaving any references to whom left (Leaver is only noticed after he/she is totally disconnected).
		else if( groupInstance.Commander == none )
		{
			// Commander left, move commander to the last player whom joined the group.
			LRI = GetGroupPlayerReplicationInfo( Groups[groupIndex].Members[Groups[groupIndex].Members.Length - 1].PlayerReplicationInfo );
			groupInstance.Commander = LRI;
		}
		// Member left and was not the commander, but a member inbetween, so fix the broken link.
		else if( Groups[groupIndex].Members.Length > 1 )
		{
			LRI = GetGroupPlayerReplicationInfo( Groups[groupIndex].Members[memberIndex + 1].PlayerReplicationInfo );
			LRI.NextMember = GetGroupPlayerReplicationInfo( Groups[groupIndex].Members[memberIndex].PlayerReplicationInfo );
		}
	}
	return true;
}

final function int CreateGroup( string groupName, optional PlayerController commander )
{
	local GroupInstance instance;
	local int groupIndex;

	// Log( "CreateGroup(" $ groupName $ ", " $ commander.GetHumanReadableName() $ ")" );
	if( GetGroupIndexByName( groupName ) != -1 )
	{
		return -1;
	}

	// Don't create a new group for commander if he/she can't leave its current group.
	if( commander != none && !LeaveGroup( commander ) )
	{
		return -1;
	}

	instance = Spawn( GroupInstanceClass, self );
	if( instance == none )
	{
		return -1;
	}

	groupIndex = Groups.Length;
	Groups.Length = groupIndex + 1;
	Groups[groupIndex].Instance = instance;
	Groups[groupIndex].GroupName = groupName;

	instance.GroupId = NextGroupId ++;
	instance.GroupName = groupName;

	if( commander != none )
	{
		AddPlayerToGroup( commander, groupindex );
	}
	return groupindex;
}

// Check if this player already is within a group in that case remove him and remove the group if it turns empty!.
final function bool LeaveGroup( PlayerController PC, optional bool bNoMessages )
{
	local int groupindex, memberindex;
	local bool vReturnValue;

	if( PC.Pawn == none )
	{
		if( !bNoMessages )
		{
			PC.ClientMessage( GroupColor $ "Sorry you cannot leave a group while you are dead!" );
		}
		return false;
	}

	if( VSize( PC.Pawn.LastStartSpot.Location - PC.Pawn.Location ) >= GroupFunctionDistanceLimit )
	{
		if( !bNoMessages )
		{
			PC.ClientMessage( GroupColor $ "Sorry you can only leave a group if you are near your spawn location" );
		}
		return false;
	}

	groupindex = GetGroupIndexByPlayer( PC, memberindex );
	if( groupindex != -1 && memberindex != -1 )
	{
		vReturnValue = RemoveMemberFromGroup( memberindex, groupindex );
		if( !bNoMessages )
		{
			SendPlayerMessage( PC, "You left the group \"" $ Groups[groupindex].GroupName $ "\"" );
			GroupSendMessage( groupindex, PC.PlayerReplicationInfo.PlayerName @ "left your group!" );
		}
		// Check if this group became empty, or whether the group has players that no longer exist, therefor clear those.
		ClearEmptyGroup( groupindex );
		return vReturnValue;
	}
	// else not in a group!
	return true;
}

final function CountDownGroup( PlayerController PC, int ticks )
{
	local int groupIndex;

	if( PC.Pawn == none )
	{
		PC.ClientMessage( GroupColor $ "Sorry you cannot start a countdown while you are dead!" );
		return;
	}

	groupIndex = GetGroupIndexByPlayer( PC );
	if( groupIndex != -1 )
	{
		if( Level.TimeSeconds - Groups[groupIndex].NextAllowedCountDownTime >= 0.0 )
		{
			ticks = Max( Min( ticks, MaxCountDownTicks ), MinCountDownTicks );
			GroupSendMessage( groupIndex, PC.GetHumanReadableName() @ "has started a countdown!" );
			Groups[groupIndex].NextAllowedCountDownTime = Level.TimeSeconds + ticks;
			Spawn( GroupCounterClass, self ).Start( groupIndex, ticks );
		}
		else
		{
			PC.ClientMessage( GroupColor $ "Sorry you cannot start a coundown when your group's counter is active!" );
		}
	}
	else
	{
		PC.ClientMessage( GroupColor $ "Sorry you cannot start a countdown when you're not in a group!" );
	}
}

final function int GetGroupIndexByPlayer( Controller C, optional out int foundMemberIndex )
{
	local int i, m;

	for( i = 0; i < Groups.Length; ++ i )
	{
		for( m = 0; m < Groups[i].Members.Length; ++ m )
		{
			if( Groups[i].Members[m] == C )
			{
				foundMemberIndex = m;
				return i;
			}
		}
	}
	return -1;
}

final function int GetGroupIndexById( int groupId )
{
	local int i;

	for( i = 0; i < Groups.Length; ++ i )
	{
		if( Groups[i].Instance.GroupId == groupId )
		{
			return i;
		}
	}
	return -1;
}

final function int GetGroupIndexByName( string groupName )
{
	local int i;

	for( i = 0; i < Groups.Length; ++ i )
	{
		if( Groups[i].GroupName ~= groupName )
		{
			return i;
		}
	}
	return -1;
}

final function int GetMemberIndexByPlayer( Controller C )
{
	local int m, groupindex;

	groupindex = GetGroupIndexByPlayer( C );
	if( groupindex != -1 && Groups.Length > 0 )
	{
		for( m = 0; m < Groups[groupindex].Members.Length; ++ m )
		{
			if( Groups[groupindex].Members[m] == C )
			{
				return m;
			}
		}
	}
	return -1;
}

final function int GetMemberIndexByGroupIndex( Controller C, int groupIndex )
{
	local int m;

	if( groupIndex != -1 && Groups.Length > 0 )
	{
		for( m = 0; m < Groups[groupIndex].Members.Length; ++ m )
		{
			if( Groups[groupIndex].Members[m] == C )
			{
				return m;
			}
		}
	}
	return -1;
}

final function GetMembersByGroupIndex( int groupIndex, out array<Controller> members )
{
	if( groupIndex != -1 && Groups.Length > 0 )
	{
		members = Groups[groupIndex].Members;
	}
}

final function GroupPlaySound( int groupIndex, Sound sound )
{
	local int m;
	local Controller C;

	for( m = 0; m < Groups[groupIndex].Members.Length; ++ m )
	{
		if( Groups[groupIndex].Members[m] != none )
		{
			PlayerController(Groups[groupIndex].Members[m]).ClientPlaySound( sound,,, SLOT_Talk );
			// Check all controllers whether they are spectating this member!
			for( C = Level.ControllerList; C != none; C = C.NextController )
			{
				// Hey not to myself(incase)
				if( C == Groups[groupIndex].Members[m] || PlayerController(C) == none )
				{
					continue;
				}

				if( PlayerController(C).RealViewTarget == Groups[groupIndex].Members[m] )
				{
					PlayerController(C).ClientPlaySound( sound,,, SLOT_Talk );
				}
			}
		}
	}
}

final function GroupSendMessage( int groupIndex, string groupMessage, optional class<GroupLocalMessage> messageClass )
{
	local int m;
	local Controller C;

	if( Groups.Length == 0 )
	{
		return;
	}

	// Group is no longer active?
	if( groupIndex >= Groups.Length )
	{
		return;
	}

	for( m = 0; m < Groups[groupIndex].Members.Length; ++ m )
	{
		if( Groups[groupIndex].Members[m] != none )
		{
			SendGroupMessage( Groups[groupIndex].Members[m], groupMessage, messageClass );
			// Check all controllers whether they are spectating this member!
			for( C = Level.ControllerList; C != none; C = C.NextController )
			{
				// Hey not to myself(incase)
				if( C == Groups[groupIndex].Members[m] || PlayerController(C) == none )
				{
					continue;
				}

				if( PlayerController(C).RealViewTarget == Groups[groupIndex].Members[m] )
				{
					SendGroupMessage( C, groupMessage, messageClass, Groups[groupIndex].Instance.GroupColor );
				}
			}
		}
	}
}

final function SendGroupMessage( Controller C, string message, optional class<GroupLocalMessage> messageClass, optional Color clr )
{
	local GroupPlayerLinkedReplicationInfo LRI;

	LRI = GetGroupPlayerReplicationInfo( C.PlayerReplicationInfo );
	if( LRI != none )
	{
		if( messageClass == none )
		{
			messageClass = GroupMessageClass;
		}

		if( clr.A == 0 )
		{
			clr = LRI.PlayerGroup.GroupColor;
		}
		LRI.ClientSendMessage( messageClass, clr $ message );
		// Groups[groupIndex].Instance.SetQueueMessage( message );
		//C.ReceiveLocalizedMessage( GroupMessageClass,,,, Groups[groupIndex].Instance );
	}
}

final function SendPlayerMessage( Controller C, string message, optional class<GroupLocalMessage> messageClass )
{
	local GroupPlayerLinkedReplicationInfo LRI;

	if( messageClass == none )
	{
		messageClass = PlayerMessageClass;
	}

	LRI = GetGroupPlayerReplicationInfo( C.PlayerReplicationInfo );
	if( LRI.PlayerGroup == none || LRI.PlayerGroup.GroupColor.A == 0 )
	{
		LRI.ClientSendMessage( messageClass, GroupColor $ message );
		return;
	}
	LRI.ClientSendMessage( messageClass, LRI.PlayerGroup.GroupColor $ message );
}

final function SendGlobalMessage( string message )
{
	Level.Game.Broadcast( self, GroupColor $ message );
}

final function int GetGroupCompletedTasks( int groupIndex, bool bOptional )
{
	local int i, numtasks;

	if( Groups.Length == 0 )
	{
		return 0;
	}

	if( bOptional )
	{
		for( i = 0; i < Groups[groupIndex].CompletedTasks.Length; ++ i )
		{
			if( Groups[groupIndex].CompletedTasks[i].bOptionalTask )
			{
        		++ numtasks;
        	}
		}
	}
	else
	{
		for( i = 0; i < Groups[groupIndex].CompletedTasks.Length; ++ i )
		{
			if( !Groups[groupIndex].CompletedTasks[i].bOptionalTask )
			{
        		++ numtasks;
        	}
		}
	}
	return numtasks;
}

final function RewardGroup( int groupIndex, int objectivesAmount )
{
	local int m;
	local ASPlayerReplicationInfo ASPRI;

 	if( Groups.Length == 0 )
	{
		return;
	}

   	for( m = 0; m < Groups[groupIndex].Members.Length; ++ m )
   	{
   		ASPRI = ASPlayerReplicationInfo(Groups[groupIndex].Members[m].PlayerReplicationInfo);
   		if( ASPRI != none )
   		{
			ASPRI.DisabledObjectivesCount += objectivesAmount;
			ASPRI.Score += 10 * objectivesAmount;
			Level.Game.ScoreObjective( ASPRI, 10 * objectivesAmount );
		}
	}
}

final function bool ShouldRemoveMember( int groupIndex, int memberIndex )
{
	local Controller c;

	c = Groups[groupIndex].Members[memberIndex];
	if( c == none || c.PlayerReplicationInfo.bOnlySpectator || c.PlayerReplicationInfo.bIsSpectator )
	{
		return true;
	}
	return false;
}

final function ClearEmptyGroups()
{
	local int groupIndex;

	for( groupIndex = 0; groupIndex < Groups.Length; ++ groupIndex )
	{
		if( ClearEmptyGroup( groupIndex ) )
		{
			-- groupIndex;
		}
	}
}

final function bool ClearEmptyGroup( int groupIndex )
{
	local int m;
	local Controller member;

	for( m = 0; m < Groups[groupIndex].Members.Length; ++ m )
	{
		member = Groups[groupIndex].Members[m];
		if( ShouldRemoveMember( groupIndex, m ) && RemoveMemberFromGroup( m, groupIndex ) )
		{
			-- m;
			if( member != none )
			{
				SendPlayerMessage( member, "You left the group \"" $ Groups[groupIndex].GroupName $ "\"" );
				GroupSendMessage( groupIndex, member.PlayerReplicationInfo.PlayerName @ "left your group!" );
			}
			else
			{
				GroupSendMessage( groupIndex, "A player has left your group!" );
			}
		}
	}

	if( Groups[groupIndex].Members.Length == 0 )
	{
		if( Groups[groupIndex].Instance != none )
		{
			Groups[groupIndex].Instance.Destroy();
		}
		Log( "Removing empty group" @ Groups[groupIndex].GroupName );
		Groups.Remove( groupIndex, 1 );
		return true;
	}
	return false;
}

simulated event Tick( float deltaTime )
{
    local PlayerController PC;

    if( Level.NetMode == NM_DedicatedServer )
    {
    	Disable('Tick');
    	return;
    }

	PC = Level.GetLocalPlayerController();
	if( PC != none && PC.Player != none && PC.Player.InteractionMaster != none )
	{
		PC.Player.InteractionMaster.AddInteraction( string(GroupInteractionClass), PC.Player );
		Disable('Tick');
		return;
    }
}

function Reset()
{
	local int i;

	super.Reset();
	for( i = 0; i < Groups.Length; ++ i )
	{
		Groups[i].CompletedTasks.Length = 0;
	}
}

final static function GroupPlayerLinkedReplicationInfo GetGroupPlayerReplicationInfo( PlayerReplicationInfo PRI )
{
	local LinkedReplicationInfo LRI;

	if( PRI == none )
	{
		return none;
	}

	for( LRI = PRI.CustomReplicationInfo; LRI != none; LRI = LRI.NextReplicationInfo )
	{
		if( GroupPlayerLinkedReplicationInfo(LRI) == none )
		{
			continue;
		}
		return GroupPlayerLinkedReplicationInfo(LRI);
	}
	return none;
}

/** Returns the GroupManager mutator. Server only. */
final static function GroupManager Get( LevelInfo world )
{
	local Mutator m;

	for( m = world.Game.BaseMutator; m != none; m = m.NextMutator )
	{
		if( GroupManager(m) != none )
		{
			return GroupManager(m);
		}
	}
	return none;
}

simulated function GroupTaskComplete GetClosestTask( Vector loc )
{
	local GroupTaskComplete closestTask;
	local int i;
	local float dist, lastDist;

	for( i = 0; i < Tasks.Length; ++ i )
	{
		dist = VSize( loc - Tasks[i].Location );
		if( dist < lastDist || lastDist == 0 )
		{
			closestTask = Tasks[i];
			lastDist = dist;
		}
	}
	return closestTask;
}

function bool CheckReplacement( Actor other, out byte bSuperRelevant )
{
	local LinkedReplicationInfo LRI;

	if( PlayerReplicationInfo(other) != none )
	{
		if( other.Owner != none && MessagingSpectator(other.Owner) == none )
		{
			LRI = Spawn( GroupPlayerReplicationInfoClass, other.Owner );
			LRI.NextReplicationInfo = PlayerReplicationInfo(other).CustomReplicationInfo;
			PlayerReplicationInfo(other).CustomReplicationInfo = LRI;
		}
	}
	return true;
}

defaultproperties
{
    GroupName="TrialGroup"
    FriendlyName="Trial Group"
    Description="A set of tools to help you make group trial maps. More at http://eliotvu.com/portfolio/view/36/trialgroup"

	MaxGroupSize=2
	GeneratedGroupName="Explorers"
	GroupFunctionDistanceLimit=600
	MaxCountDownTicks=3
	MinCountDownTicks=1

	GroupColor=(R=182,G=89,B=73)

	RemoteRole=ROLE_SimulatedProxy
	bNoDelete=true
	bStatic=false

	GroupMessageClass=class'GroupLocalMessage'
	PlayerMessageClass=class'GroupPlayerLocalMessage'
	TaskMessageClass=class'GroupTaskLocalMessage'
	GroupInstanceClass=class'GroupInstance'
	GroupInteractionClass=class'GroupInteraction'
	GroupCounterClass=class'GroupCounter'
	GroupRulesClass=class'GroupRules'
	GroupPlayerReplicationInfoClass=class'GroupPlayerLinkedReplicationInfo'
	CounterMessageClass=class'GroupCounterLocalMessage'
	GroupProgressMessageClass=class'GroupProgressLocalMessage'
}
