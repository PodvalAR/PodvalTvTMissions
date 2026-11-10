/**
 * @brief Сетевой компонент управления сценой спасения и завершения миссии TvT_HostageOfTheDesert_Bagheera.
 * @context Hybrid (Server: авторитет победы, задач и таймера / Client: синхронизация анимаций игрока, узника, магнитофона и звука)
 * @entity tapeInteractionPoint / ChairDental_01
 */
[ComponentEditorProps(category: "GameScripted/TvT", description: "Interrogation rescue component for mission victory")]
class TvT_InterrogationRescueComponentClass : ScriptComponentClass
{
}

class TvT_InterrogationRescueComponent : ScriptComponent
{
	protected static TvT_InterrogationRescueComponent s_Instance;

	[Attribute("Офицер Сахир Авад найден! Запись допроса зафиксирована. Победа Иракских сил!", UIWidgets.EditBox, "Сообщение об окончании миссии для всех игроков")]
	protected string m_sEndMessage;

	[Attribute("15", UIWidgets.EditBox, "Задержка перед завершением миссии в секундах (длительность осмотра)")]
	protected float m_fEndDelaySeconds;

	[Attribute("{B420A82B5B32DB99}Sounds/VO/KS/CinematicScenes/VO_KS_SovietTorturerCO_Direct_TapeRecorder.acp", UIWidgets.ResourceNamePicker, "Звуковой файл записи допроса")]
	protected ResourceName m_sAudioFile;

	[Attribute("{15EB5E87B17220BE}anims/anm/NPC/male/Body/Dentist/cine_savior_dentist_Pt1_TapePlayer.anm", UIWidgets.ResourceNamePicker, "Анимация бобин магнитофона")]
	protected ResourceName m_sTapeAnimation;

	[Attribute("{47870B202CB3118A}anims/anm/NPC/male/Body/Dentist/cine_savior_dentist_recordloop_TapePlayer.anm", UIWidgets.ResourceNamePicker, "Анимация бобин в режиме записи")]
	protected ResourceName m_sTapeLoopAnimation;

	[Attribute("tapeRecorder", UIWidgets.EditBox, "Имя сущности магнитофона")]
	protected string m_sTapeRecorderName;

	[Attribute("victim", UIWidgets.EditBox, "Имя сущности замученного генерала")]
	protected string m_sVictimEntityName;

	[Attribute("pivot", UIWidgets.EditBox, "Имя точки привязки для кресла")]
	protected string m_sPivotEntityName;

	[Attribute("{F7C5319E76546C30}anims/anm/NPC/workspaces/Omega_NPCs.agr", UIWidgets.ResourceNamePicker, "Граф анимаций узника и спасителя")]
	protected ResourceName m_sVictimAnimGraph;

	[Attribute("{1AAF64456A5D3EDE}anims/anm/NPC/workspaces/Omega_NPCs.asi", UIWidgets.ResourceNamePicker, "Инстанс графа анимаций")]
	protected ResourceName m_sVictimAnimInstance;

	[RplProp()]
	protected bool m_bTriggered;

	protected int m_iVictimResolveAttempts;

	protected RplComponent m_RplComponent;

	static TvT_InterrogationRescueComponent GetInstance()
	{
		return s_Instance;
	}

	override void OnPostInit(IEntity owner)
	{
		super.OnPostInit(owner);
		s_Instance = this;
		m_RplComponent = RplComponent.Cast(owner.FindComponent(RplComponent));

		if (Replication.IsServer())
		{
			GetGame().GetCallqueue().CallLater(InitVictimLoitering_S, 400, false);
		}
	}

	override void OnDelete(IEntity owner)
	{
		if (s_Instance == this)
			s_Instance = null;

		if (GetGame() && GetGame().GetCallqueue())
		{
			GetGame().GetCallqueue().Remove(FinishMission_S);
			GetGame().GetCallqueue().Remove(InitVictimLoitering_S);
			GetGame().GetCallqueue().Remove(PlayVictimGesture_S);
			GetGame().GetCallqueue().Remove(SwitchTapeLoop_C);
		}

		super.OnDelete(owner);
	}

	bool IsTriggered()
	{
		return m_bTriggered;
	}

	/**
	 * @brief Серверная посадка генерала в кресло: отключение коллизии/мед.осмотра и loiter строго на якоре pivot.
	 */
	void InitVictimLoitering_S()
	{
		if (!Replication.IsServer())
			return;

		IEntity victimEnt = ResolveTargetEntity(m_sVictimEntityName);
		if (!victimEnt)
		{
			// SF-слот TorturedDudeSlot может заспавнить узника позже инициализации компонента
			if (m_iVictimResolveAttempts < 40)
			{
				m_iVictimResolveAttempts++;
				GetGame().GetCallqueue().CallLater(InitVictimLoitering_S, 500, false);
			}
			return;
		}

		IEntity propEntity = ResolveTargetEntity(m_sPivotEntityName);
		if (!propEntity)
			propEntity = GetOwner();

		// Отключаем физическую коллизию кресла, чтобы персонаж не выталкивался на его каркас/сиденье
		IEntity chairEnt = ResolveTargetEntity("ChairDental_01");
		if (!chairEnt && propEntity)
			chairEnt = propEntity.GetParent();
		if (chairEnt)
		{
			Physics chairPhys = chairEnt.GetPhysics();
			if (chairPhys)
			{
				chairPhys.SetActive(ActiveState.INACTIVE);
				chairPhys.SetInteractionLayer(0);
			}
		}

		SCR_ChimeraCharacter character = SCR_ChimeraCharacter.Cast(victimEnt);
		if (!character)
			return;

		// Отключаем коллизию капсулы узника, чтобы персонаж спасителя не выталкивался наверх
		Physics victimPhys = victimEnt.GetPhysics();
		if (victimPhys)
		{
			victimPhys.SetActive(ActiveState.INACTIVE);
			victimPhys.SetInteractionLayer(0);
		}

		// Отключаем все сторонние действия на узнике (включая ванильный медицинский осмотр SCR_InspectCasualtyUserAction)
		ActionsManagerComponent actionsManager = ActionsManagerComponent.Cast(victimEnt.FindComponent(ActionsManagerComponent));
		if (actionsManager)
		{
			array<BaseUserAction> outActions = {};
			actionsManager.GetActionsList(outActions);
			foreach (BaseUserAction act : outActions)
			{
				if (!act.IsInherited(TvT_InterrogationRescueAction))
					act.SetActionEnabled_S(false);
			}
		}

		// Полное излечение узника (false = удаление кровотечений и сброс blood hitzone в UNDAMAGED)
		SCR_CharacterDamageManagerComponent damageMan = SCR_CharacterDamageManagerComponent.Cast(character.GetDamageManager());
		if (damageMan)
		{
			damageMan.FullHeal(true);
			damageMan.RemoveAllBleedings();
			damageMan.EnableDamageHandling(false);
		}

		AIControlComponent aiControl = AIControlComponent.Cast(victimEnt.FindComponent(AIControlComponent));
		if (aiControl)
			aiControl.ActivateAI(false);

		SCR_CharacterControllerComponent controller = SCR_CharacterControllerComponent.Cast(character.GetCharacterController());
		if (!controller)
			return;

		CharacterAnimationComponent animComp = controller.GetAnimationComponent();
		if (!animComp)
			return;

		animComp.PhysicsEnableGravity(false);

		SCR_CharacterCommandHandlerComponent cmdHandler = SCR_CharacterCommandHandlerComponent.Cast(animComp.GetCommandHandler());
		if (!cmdHandler)
			return;

		cmdHandler.StartCommand_Move();

		SCR_ScriptedCommandsStaticTable staticTable = cmdHandler.GetScriptedStaticTable();
		if (!staticTable)
			return;

		vector vAnimationTransform[4] = { "1 0 0", "0 1 0", "0 0 1", "0 0 0" };
		if (propEntity)
		{
			propEntity.GetWorldTransform(vAnimationTransform);
			victimEnt.SetWorldTransform(vAnimationTransform);
		}

		// rootMotion выключен: переход сесть и луп играются на месте на якоре, тело не уезжает от кресла
		SCR_LoiterCustomAnimData customAnimData = SCR_LoiterCustomAnimData.CreateInstance(
			commandID: -1,
			commandValue: ELoiteringType.CUSTOM,
			commandName: "",
			graphName: m_sVictimAnimGraph,
			graphInstanceName: m_sVictimAnimInstance,
			controlVariableName: staticTable.CONTROL_VARIABLE_NAME,
			controlVariableID: staticTable.m_OfficerMissionSpeech,
			controlVariableValue: 1,
			allowRootMotion: false,
			allowEnvironmentalExit: false);

		controller.StartLoitering(propEntity, ELoiteringType.CUSTOM, false, false, false, vAnimationTransform, true, customAnimData);
	}

	/**
	 * @brief Старт процесса осмотра спасителем на клиентах и запуск таймера завершения миссии.
	 */
	void TriggerRescue_S(IEntity rescuer)
	{
		if (!Replication.IsServer() || m_bTriggered)
			return;

		m_bTriggered = true;
		Replication.BumpMe();

		RplId rescuerRplId = RplId.Invalid();
		if (rescuer)
		{
			RplComponent rescuerRpl = RplComponent.Cast(rescuer.FindComponent(RplComponent));
			if (rescuerRpl)
				rescuerRplId = rescuerRpl.Id();
		}

		// Запуск анимаций спасителя, генерала, магнитофона и звука
		Rpc(RpcDo_PlayEffects, rescuerRplId);
		if (RplSession.Mode() != RplMode.Dedicated)
			RpcDo_PlayEffects(rescuerRplId);

		// Жест реакции узника только с сервера: аним-состояние серверного AI реплицируется движком
		GetGame().GetCallqueue().CallLater(PlayVictimGesture_S, 2000, false);

		// Таймер завершения миссии по окончании анимации осмотра (15 секунд)
		int delayMs = Math.Max(1000, (int)(m_fEndDelaySeconds * 1000));
		GetGame().GetCallqueue().CallLater(FinishMission_S, delayMs, false);
	}

	/**
	 * @brief Фиксация победы в задачах, вывод серверного сообщения и переход в дебрифинг.
	 */
	protected void FinishMission_S()
	{
		if (!Replication.IsServer())
			return;

		// 1. Глобальное серверное оповещение всем игрокам в чат (smsg)
		BroadcastServerMessage(m_sEndMessage);

		// 2. Завершение анимации спасителя
		Rpc(RpcDo_StopEffects);
		if (RplSession.Mode() != RplMode.Dedicated)
			RpcDo_StopEffects();

		// 3. Переход гейммода в финальное состояние (дебрифинг); виртуальный вызов дойдёт до логики лобби
		SCR_BaseGameMode gameMode = SCR_BaseGameMode.Cast(GetGame().GetGameMode());
		if (gameMode)
			gameMode.EndGameMode(null);
	}

	/**
	 * @brief Рассылка серверного сообщения в чат всем подключённым игрокам.
	 */
	protected void BroadcastServerMessage(string message)
	{
		SCR_ChatPanelManager chatManager = SCR_ChatPanelManager.GetInstance();
		if (!chatManager)
			return;

		ChatCommandInvoker invoker = chatManager.GetCommandInvoker("smsg");
		if (invoker)
			invoker.Invoke(null, message);
	}

	protected IEntity FindChildByName(IEntity parent, string name)
	{
		if (!parent || name == "")
			return null;

		IEntity child = parent.GetChildren();
		while (child)
		{
			if (child.GetName() == name)
				return child;
			child = child.GetSibling();
		}
		return null;
	}

	protected IEntity ResolveTargetEntity(string entityName)
	{
		if (entityName == "")
			return null;

		IEntity ent = GetGame().GetWorld().FindEntityByName(entityName);
		if (ent)
			return ent;

		IEntity owner = GetOwner();
		if (!owner)
			return null;

		ent = FindChildByName(owner, entityName);
		if (ent)
			return ent;

		IEntity parent = owner.GetParent();
		if (parent)
		{
			if (parent.GetName() == entityName)
				return parent;
			ent = FindChildByName(parent, entityName);
			if (ent)
				return ent;
		}

		return null;
	}

	/**
	 * @brief Клиентские эффекты: анимация бобин магнитофона, звук и анимация осмотра спасителя.
	 */
	[RplRpc(RplChannel.Reliable, RplRcver.Broadcast)]
	protected void RpcDo_PlayEffects(RplId rescuerRplId)
	{
		// 1. Анимация катушек магнитофона
		IEntity tapeEnt = ResolveTargetEntity(m_sTapeRecorderName);
		if (tapeEnt)
		{
			AnimationPlayerComponent animPlayer = AnimationPlayerComponent.Cast(tapeEnt.FindComponent(AnimationPlayerComponent));
			if (animPlayer)
			{
				if (m_sTapeAnimation != "")
					animPlayer.Prepare(m_sTapeAnimation, 0, 1.0, true);
				animPlayer.Play();
			}

			GetGame().GetCallqueue().CallLater(SwitchTapeLoop_C, 20000, false);
		}

		// 2. Отключаем коллизию кресла на клиенте
		IEntity propEntity = ResolveTargetEntity(m_sPivotEntityName);
		IEntity chairEnt = ResolveTargetEntity("ChairDental_01");
		if (!chairEnt && propEntity)
			chairEnt = propEntity.GetParent();
		if (chairEnt)
		{
			Physics chairPhys = chairEnt.GetPhysics();
			if (chairPhys)
			{
				chairPhys.SetActive(ActiveState.INACTIVE);
				chairPhys.SetInteractionLayer(0);
			}
		}

		// 3. Звук магнитофона / реплика допроса
		if (m_sAudioFile != "")
		{
			AudioSystem.PlayEventInitialize(m_sAudioFile);
			vector mat[4];
			GetOwner().GetWorldTransform(mat);
			AudioSystem.PlayEvent(m_sAudioFile, "SOUND_VOICE", mat);
		}

		// 4. Анимация осмотра спасителя (игрока, нажавшего кнопку F)
		IEntity rescuerEnt = null;
		if (rescuerRplId.IsValid())
		{
			RplComponent rescuerRpl = RplComponent.Cast(Replication.FindItem(rescuerRplId));
			if (rescuerRpl)
				rescuerEnt = rescuerRpl.GetEntity();
		}

		if (!rescuerEnt)
		{
			PlayerController pc = GetGame().GetPlayerController();
			if (pc)
				rescuerEnt = pc.GetControlledEntity();
		}

		if (rescuerEnt)
		{
			SCR_ChimeraCharacter rescuerChar = SCR_ChimeraCharacter.Cast(rescuerEnt);
			if (rescuerChar)
				StartRescuerAnimation(rescuerChar);
		}
	}

	/**
	 * @brief Переключение бобин на луп записи на каждом клиенте (в кампании — через 20 секунд).
	 */
	protected void SwitchTapeLoop_C()
	{
		IEntity tapeEnt = ResolveTargetEntity(m_sTapeRecorderName);
		if (!tapeEnt)
			return;

		AnimationPlayerComponent animPlayer = AnimationPlayerComponent.Cast(tapeEnt.FindComponent(AnimationPlayerComponent));
		if (!animPlayer)
			return;

		if (m_sTapeLoopAnimation != "")
			animPlayer.Prepare(m_sTapeLoopAnimation, 0, 1.0, true);
		animPlayer.Play();
	}

	/**
	 * @brief Серверный жест реакции узника на осмотр: команды анимации на серверном AI реплицируются движком.
	 */
	protected void PlayVictimGesture_S()
	{
		if (!Replication.IsServer())
			return;

		IEntity victimEnt = ResolveTargetEntity(m_sVictimEntityName);
		SCR_ChimeraCharacter victimChar = SCR_ChimeraCharacter.Cast(victimEnt);
		if (!victimChar)
			return;

		SCR_CharacterControllerComponent controller = SCR_CharacterControllerComponent.Cast(victimChar.GetCharacterController());
		if (!controller)
			return;

		CharacterAnimationComponent animComp = controller.GetAnimationComponent();
		if (!animComp)
			return;

		TAnimGraphCommand cmdId = animComp.BindCommand("CMD_Gesture_NPC");
		if (cmdId != -1)
			animComp.CallCommand4I(cmdId, 0, 11, 0, 0, 0);
	}

	/**
	 * @brief Loiter осмотра на owner-клиенте спасителя: жёсткая установка на pivot, затем анимация
	 * без root motion — поза играется строго на якоре и не дрейфует от кресла и магнитофона.
	 */
	protected void StartRescuerAnimation(SCR_ChimeraCharacter rescuerChar)
	{
		if (!rescuerChar)
			return;

		RplComponent rplComp = rescuerChar.GetRplComponent();
		if (rplComp && !rplComp.IsOwner())
			return;

		IEntity propEntity = ResolveTargetEntity(m_sPivotEntityName);
		if (!propEntity)
			propEntity = GetOwner();

		vector vAnimationTransform[4] = { "1 0 0", "0 1 0", "0 0 1", "0 0 0" };
		if (propEntity)
		{
			propEntity.GetWorldTransform(vAnimationTransform);
			// Owner-клиент авторитетен по своему трансформу: установка на якор дойдёт до остальных потоком движения
			rescuerChar.SetWorldTransform(vAnimationTransform);
		}

		SCR_CharacterControllerComponent controller = SCR_CharacterControllerComponent.Cast(rescuerChar.GetCharacterController());
		if (!controller)
			return;

		CharacterAnimationComponent animComp = controller.GetAnimationComponent();
		if (!animComp)
			return;

		SCR_CharacterCommandHandlerComponent cmdHandler = SCR_CharacterCommandHandlerComponent.Cast(animComp.GetCommandHandler());
		if (!cmdHandler)
			return;

		cmdHandler.StartCommand_Move();

		SCR_ScriptedCommandsStaticTable staticTable = cmdHandler.GetScriptedStaticTable();
		if (!staticTable)
			return;

		SCR_LoiterCustomAnimData customAnimData = SCR_LoiterCustomAnimData.CreateInstance(
			commandID: staticTable.m_CustomCinematicCommand,
			commandValue: ELoiteringType.CUSTOM,
			commandName: SCR_CustomAnimData_Properties.BINDING_COMMAND_NAME,
			graphName: m_sVictimAnimGraph,
			graphInstanceName: m_sVictimAnimInstance,
			controlVariableName: staticTable.CONTROL_VARIABLE_NAME,
			controlVariableID: staticTable.m_OfficerMissionSpeech,
			controlVariableValue: 2,
			allowRootMotion: false,
			allowEnvironmentalExit: false);

		controller.SelectWeapon(null);
		controller.StartLoitering(propEntity, ELoiteringType.CUSTOM, true, false, false, vAnimationTransform, true, customAnimData);
	}

	/**
	 * @brief Завершение сцены при переходе в дебрифинг.
	 */
	[RplRpc(RplChannel.Reliable, RplRcver.Broadcast)]
	protected void RpcDo_StopEffects()
	{
		// Не прерываем анимацию через StopLoitering(true), чтобы не ломать ракурс камеры и позу перед экраном дебрифинга
	}
}
