modded class PS_MissionDataManager
{
	override void InitData()
	{
		SCR_MissionHeader missionHeader = SCR_MissionHeader.Cast(GetGame().GetMissionHeader());
		if (missionHeader) {
			//m_Data.MissionPath = missionHeader.GetHeaderResourcePath();
			m_Data.WorldPath = missionHeader.GetWorldPath();
			
			m_Data.MissionName = missionHeader.m_sName;
			m_Data.MissionAuthor = missionHeader.m_sAuthor;
			m_Data.MissionDescription = missionHeader.m_sDescription;
		}
		
		ChimeraWorld world = GetGame().GetWorld();
		TimeAndWeatherManagerEntity timeAndWeatherManagerEntity = world.GetTimeAndWeatherManager();
		float time = timeAndWeatherManagerEntity.GetTimeOfTheDay();
		WeatherState weatherState = timeAndWeatherManagerEntity.GetCurrentWeatherState();
		m_Data.MissionWeather = weatherState.GetStateName();
		m_Data.MissionDayTime = time;
		m_Data.MissionWeatherIcon = weatherState.GetIconPath();
		
	
		PS_MissionDataStateChangeEvent missionDataStateChangeEvent = new PS_MissionDataStateChangeEvent();
		missionDataStateChangeEvent.State = SCR_EGameModeState.PREGAME;
		missionDataStateChangeEvent.Time = GetGame().GetWorld().GetWorldTime();
		missionDataStateChangeEvent.SystemTime = System.GetUnixTime();
		m_Data.StateEvents.Insert(missionDataStateChangeEvent);
		
		#ifdef PS_REPLAYS
		PS_ReplayWriter replayWriter = PS_ReplayWriter.GetInstance();
		m_Data.ReplayPath = replayWriter.m_sReplayFileName;
		#endif
		
		PS_MissionDescriptionManager missionDescriptionManager = PS_MissionDescriptionManager.GetInstance();
		array<PS_MissionDescription> descriptions = new array<PS_MissionDescription>();
		missionDescriptionManager.GetDescriptions(descriptions);
		foreach (PS_MissionDescription description : descriptions)
		{
			PS_MissionDataDescription descriptionData = new PS_MissionDataDescription();
			m_Data.Descriptions.Insert(descriptionData);
			
			descriptionData.Title = WidgetManager.Translate("%1", description.m_sTitle);
			descriptionData.DescriptionLayout = description.m_sDescriptionLayout;
			descriptionData.TextData = WidgetManager.Translate("%1", description.m_sTextData);
			descriptionData.VisibleForFactions = description.m_aVisibleForFactions;
			descriptionData.EmptyFactionVisibility = description.m_bEmptyFactionVisibility;
		}
		
		
		PS_PlayableManager playableManager = PS_PlayableManager.GetInstance();
		
		array<PS_PlayableContainer> playables = playableManager.GetPlayablesSorted();
		
		PS_MissionDataGroup groupData = new PS_MissionDataGroup();
		PS_MissionDataFaction factionData = new PS_MissionDataFaction();
		
		map<Faction, PS_MissionDataFaction> factionsMap = new map<Faction, PS_MissionDataFaction>();
		map<SCR_AIGroup, PS_MissionDataGroup> groupsMap = new map<SCR_AIGroup, PS_MissionDataGroup>();
		foreach (PS_PlayableContainer playable : playables)
		{
			IEntity character = playable.GetPlayableComponent().GetOwner();
			AIControlComponent aiComponent = AIControlComponent.Cast(character.FindComponent(AIControlComponent));
			AIAgent agent = aiComponent.GetAIAgent();
			SCR_AIGroup group = SCR_AIGroup.Cast(agent.GetParentGroup());
			if (!group)
				continue;
			
			SCR_Faction faction = SCR_Faction.Cast(group.GetFaction());
			if (!factionsMap.Contains(faction))
			{
				factionData = new PS_MissionDataFaction();
				m_Data.Factions.Insert(factionData);
				
				factionData.Name = WidgetManager.Translate("%1", faction.GetFactionName());
				factionData.Key = WidgetManager.Translate("%1", faction.GetFactionKey());
				
				Color color = faction.GetFactionColor();
				factionData.FactionColor = string.Format("%1,%2,%3,%4", color.A(), color.R(), color.G(), color.B());
				color = faction.GetOutlineFactionColor();
				factionData.FactionOutlineColor = string.Format("%1,%2,%3,%4", color.A(), color.R(), color.G(), color.B());
				
				factionsMap.Insert(faction, factionData);
			}
			factionData = factionsMap.Get(faction);
			if (!groupsMap.Contains(group))
			{
				groupData = new PS_MissionDataGroup();
				factionData.Groups.Insert(groupData);
				
				string customName = group.GetCustomName();
				string company, platoon, squad, t, format;
				group.GetCallsigns(company, platoon, squad, t, format);
				string callsign;
				callsign = WidgetManager.Translate(format, company, platoon, squad, "");
				
				groupData.Callsign = playableManager.GetGroupCallsignByPlayable(playable.GetRplId());
				groupData.CallsignName = callsign;
				groupData.Name = customName;
				
				groupsMap.Insert(group, groupData);
			}
			groupData = groupsMap.Get(group);
			
			array<AIAgent> outAgents = new array<AIAgent>();
			group.GetAgents(outAgents);
			
			PS_MissionDataPlayable missionDataPlayable = new PS_MissionDataPlayable();
			
			SCR_CharacterDamageManagerComponent damageManagerComponent = playable.GetPlayableComponent().GetCharacterDamageManagerComponent();
			
			damageManagerComponent.GetOnDamage().Insert(OnDamaged);
			m_RplToDamageManager.Insert(playable.GetRplId(), damageManagerComponent);
			missionDataPlayable.EntityId = playable.GetRplId();
			missionDataPlayable.GroupOrder = outAgents.Find(agent);
			missionDataPlayable.Name = WidgetManager.Translate("%1", playable.GetName());
			missionDataPlayable.RoleName = WidgetManager.Translate("%1", playable.GetRoleName());
			m_EntityToRpl.Insert(character.GetID(), playable.GetRplId());
			
			groupData.Playables.Insert(missionDataPlayable);
		}
	}
	
    override void LateInit()
    {
        m_GameModeCoop = PS_GameModeCoop.Cast(GetOwner());
        m_PlayerManager = GetGame().GetPlayerManager();
        m_PlayableManager = PS_PlayableManager.GetInstance();
        m_ObjectiveManager = PS_ObjectiveManager.GetInstance();
        m_FactionManager = GetGame().GetFactionManager();
        
        GetGame().GetCallqueue().CallLater(DelayedInit, 1000, false);
        
        m_GameModeCoop.GetOnGameStateChange().Insert(OnGameStateChanged);
        m_GameModeCoop.GetOnPlayerAuditSuccess().Insert(OnPlayerAuditSuccess);
        if (RplSession.Mode() != RplMode.Dedicated) 
            OnPlayerAuditSuccess(GetGame().GetPlayerController().GetPlayerId());
    }
    
    void DelayedInit()
    {
        if (!Replication.IsServer())
            return;
        
        PS_PlayableManager playableManager = PS_PlayableManager.GetInstance();
        if (!playableManager)
            return;
        
        array<PS_PlayableContainer> playables = playableManager.GetPlayablesSorted();
        foreach (PS_PlayableContainer playable : playables)
        {
            PS_PlayableComponent playableComp = playable.GetPlayableComponent();
            if (!playableComp)
                continue;
            
            SCR_CharacterDamageManagerComponent dmg = playableComp.GetCharacterDamageManagerComponent();
            if (dmg)
            {
                dmg.GetOnDamageStateChanged().Insert(OnPlayableDamageStateChanged);
            }
        }
    }
    
    // Сохраняем map для отслеживания уже записанных смертей
    protected ref set<RplId> m_RecordedDeaths = new set<RplId>();
    
    void OnPlayableDamageStateChanged(EDamageState state)
    {
        if (state != EDamageState.DESTROYED)
            return;
        
        PS_PlayableManager playableManager = PS_PlayableManager.GetInstance();
        if (!playableManager)
            return;
        
        array<PS_PlayableContainer> playables = playableManager.GetPlayablesSorted();
        foreach (PS_PlayableContainer playable : playables)
        {
            PS_PlayableComponent playableComp = playable.GetPlayableComponent();
            if (!playableComp)
                continue;
            
            SCR_CharacterDamageManagerComponent dmg = playableComp.GetCharacterDamageManagerComponent();
            if (!dmg || !dmg.IsDestroyed())
                continue;
            
            RplId playableRplId = playableComp.GetRplId();
            
            // Уже записали эту смерть
            if (m_RecordedDeaths.Contains(playableRplId))
                continue;
            
            int playerId = playableManager.GetPlayerByPlayable(playableRplId);
            if (playerId <= 0)
                continue;
            
            m_RecordedDeaths.Insert(playableRplId);
            
            // Получаем killer через Instigator из damage manager
            Instigator killer = dmg.GetInstigator();
            int killerId = -1;
            if (killer)
                killerId = killer.GetInstigatorPlayerID();
            
            Print(string.Format("PLAYER DIED: %1 (killed by %2)", playerId, killerId), LogLevel.WARNING);
            
            PS_MissionDataPlayerKill killData = new PS_MissionDataPlayerKill();
            killData.m_iPlayerId = playerId;
            killData.InstigatorId = killerId;
            killData.Time = GetGame().GetWorld().GetWorldTime();
            killData.SystemTime = System.GetUnixTime();
            m_Data.Kills.Insert(killData);
        }
    }
	
	override void OnGameStateChanged(SCR_EGameModeState state)
	{
		PS_MissionDataStateChangeEvent missionDataStateChangeEvent = new PS_MissionDataStateChangeEvent();
		missionDataStateChangeEvent.State = state;
		missionDataStateChangeEvent.Time = GetGame().GetWorld().GetWorldTime();
		missionDataStateChangeEvent.SystemTime = System.GetUnixTime();
		m_Data.StateEvents.Insert(missionDataStateChangeEvent);
		if (state == SCR_EGameModeState.GAME)
			SavePlayers();
		if (state == SCR_EGameModeState.DEBRIEFING)
		{
			GetGame().GetCallqueue().Call(DefineScenarioType);
			GetGame().GetCallqueue().Call(SaveObjectives);
			GetGame().GetCallqueue().Call(WriteToFile);
			GetGame().GetCallqueue().Call(SendToWebsite);
		}
	}
	
	void DefineScenarioType()
	{
		SCR_MissionHeader missionHeader = SCR_MissionHeader.Cast(GetGame().GetMissionHeader());
		if (missionHeader) {
			m_Data.WorldPath = missionHeader.GetWorldPath();
			
			m_Data.MissionName = missionHeader.m_sName;
			m_Data.MissionAuthor = missionHeader.m_sAuthor;
			m_Data.MissionDescription = missionHeader.m_sDescription;
			m_Data.ScenarioType = missionHeader.m_sGameMode;
		}
	}
	
	void SendToWebsite()
	{
		StatSender_Config config = new StatSender_Config();
		bool isLoaded = config.LoadFromFile("$profile:StatSender_Config.json");
		
		if (!isLoaded)
		{
			Print("PS_MissionDataManager: Can't open StatSender_Config.json", LogLevel.WARNING);
			return;
		}
		
		m_Data.Token = config.Token;
		
		SCR_JsonSaveContext missionSaveContext = new SCR_JsonSaveContext();
		missionSaveContext.WriteValue("", m_Data);
		
		RestContext context = GetGame().GetRestApi().GetContext(config.Address);
		string answer = context.POST_now("", missionSaveContext.ExportToString());
		Print(string.Format("PS_MissionDataManager: answer(%1)", answer));
	}
}

modded class PS_MissionDataConfig
{
	string ScenarioType;
	string Token;
}