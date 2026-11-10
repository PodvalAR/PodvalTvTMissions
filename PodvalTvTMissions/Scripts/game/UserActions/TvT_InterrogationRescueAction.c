/**
 * @brief Сетевое действие [F] осмотра генерала и завершения миссии в TvT_HostageOfTheDesert_Bagheera.
 * @context Client (отображение подсказки [F] и прогресс-бара) / Server (проверка условий и старт победы)
 * @entity victim (генерал) / tapeInteractionPoint (магнитофон)
 */
class TvT_InterrogationRescueAction : SCR_ScriptedUserAction
{
	[Attribute("Ses_TKA", UIWidgets.EditBox, "Фракция, которая может завершить задачу (оставить пустым для любой)")]
	protected FactionKey m_sTargetFaction;

	[Attribute("Осмотреть генерала", UIWidgets.EditBox, "Название действия на кнопке [F]")]
	protected string m_sActionTitle;

	override bool CanBeShownScript(IEntity user)
	{
		TvT_InterrogationRescueComponent comp = ResolveComponent();
		if (comp && comp.IsTriggered())
			return false;

		return true;
	}

	override bool CanBePerformedScript(IEntity user)
	{
		TvT_InterrogationRescueComponent comp = ResolveComponent();
		if (comp && comp.IsTriggered())
			return false;

		SCR_BaseGameMode gameMode = SCR_BaseGameMode.Cast(GetGame().GetGameMode());
		if (gameMode)
		{
			SCR_EGameModeState state = gameMode.GetState();
			// Разрешаем действие в стадии GAME и BRIEFING (для тестирования)
			if (state != SCR_EGameModeState.GAME && state != SCR_EGameModeState.BRIEFING)
				return false;
		}

		return true;
	}

	override void OnActionStart(IEntity pUserEntity)
	{
		super.OnActionStart(pUserEntity);

		SCR_ChimeraCharacter character = SCR_ChimeraCharacter.Cast(pUserEntity);
		if (!character)
			return;

		SCR_CharacterControllerComponent controller = SCR_CharacterControllerComponent.Cast(character.GetCharacterController());
		if (controller)
		{
			if (controller.CanPartialLower() && !controller.IsPartiallyLowered())
				controller.SetPartialLower(true);
			controller.SelectWeapon(null);
		}
	}

	override void PerformAction(IEntity pOwnerEntity, IEntity pUserEntity)
	{
		if (!Replication.IsServer())
			return;

		// Фракционный гейт только на сервере в момент выполнения: подсказка [F] видна всем, триггерит только Ирак
		if (m_sTargetFaction != "")
		{
			FactionAffiliationComponent affComp = FactionAffiliationComponent.Cast(pUserEntity.FindComponent(FactionAffiliationComponent));
			if (affComp)
			{
				Faction faction = affComp.GetAffiliatedFaction();
				if (!faction)
					faction = affComp.GetDefaultAffiliatedFaction();

				if (faction && faction.GetFactionKey() != m_sTargetFaction)
					return;
			}
		}

		TvT_InterrogationRescueComponent comp = ResolveComponent();
		if (comp)
			comp.TriggerRescue_S(pUserEntity);
	}

	override bool CheckOnServerFirstScript()
	{
		return true;
	}

	override bool GetActionNameScript(out string outName)
	{
		if (m_sActionTitle != "")
			outName = m_sActionTitle;
		else
			outName = "Осмотреть генерала";
		return true;
	}

	protected TvT_InterrogationRescueComponent ResolveComponent()
	{
		TvT_InterrogationRescueComponent comp = TvT_InterrogationRescueComponent.GetInstance();
		if (comp)
			return comp;

		IEntity owner = GetOwner();
		if (!owner)
			return null;

		comp = TvT_InterrogationRescueComponent.Cast(owner.FindComponent(TvT_InterrogationRescueComponent));
		if (comp)
			return comp;

		IEntity parent = owner.GetParent();
		if (parent)
		{
			comp = TvT_InterrogationRescueComponent.Cast(parent.FindComponent(TvT_InterrogationRescueComponent));
			if (comp)
				return comp;
		}

		return null;
	}
}
