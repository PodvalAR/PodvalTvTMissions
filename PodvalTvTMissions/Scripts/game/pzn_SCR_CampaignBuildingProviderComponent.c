modded class SCR_CampaignBuildingProviderComponent : SCR_MilitaryBaseLogicComponent
{
	override bool IsEntityFactionSame(notnull IEntity ent1, notnull IEntity ent2)
	{
		if (m_bAnyFactionCanUse)
			return true;
		Faction ent1Faction = GetEntityFaction(ent1);
		if (!ent1Faction)
			return false;

		Faction ent2Faction = GetEntityFaction(ent2);
		if (!ent2Faction)
			return false;

		return ent1Faction == ent2Faction;
	}
}

modded class SCR_CampaignBuildingManagerComponent : SCR_BaseGameModeComponent
{
	protected override void OnEntityCoreBudgetUpdated(EEditableEntityBudget entityBudget, int originalBudgetValue, int budgetChange, int updatedBudgetValue, SCR_EditableEntityComponent entity)
	{
		if (IsProxy())
			return;

		if (entityBudget != m_BudgetType)
			return;

		// Continue with compositions placed in WB only when refund is about to happen.
		if (entity.GetOwner().IsLoaded() && budgetChange > 0)
			return;

		//CampaignBuildingManagerComponent should not do anything if there is no campaign
        const SCR_GameModeCampaign campaign = SCR_GameModeCampaign.GetInstance();
		

		// Do not react to changes during loading of session
		if (SCR_PersistenceSystem.IsLoadInProgress())
			return; 

		int propBudgetValue;
		array<ref SCR_EntityBudgetValue> budgets = {};
		entity.GetEntityAndChildrenBudgetCost(budgets);

		//get props budget value
		foreach (SCR_EntityBudgetValue budget : budgets)
		{
			if (budget.GetBudgetType() != EEditableEntityBudget.PROPS)
				continue;

			propBudgetValue = budget.GetBudgetValue();
			break;
		}

		IEntity entityOwner = entity.GetOwnerScripted();
		SCR_ResourceComponent resourceComponent;
		bool wasContainerSpawned;

		// If resource component was not found on deconstruction, spawn a custom one , find again the resource component at this spawned box and fill it with refund supply.
		if (!GetResourceComponent(entityOwner, resourceComponent))
		{
			//Spawn a resource holder only when the refunded object is a composition.
			SCR_CampaignBuildingCompositionComponent compositionComponent = SCR_CampaignBuildingCompositionComponent.Cast(entityOwner.FindComponent(SCR_CampaignBuildingCompositionComponent));
			if (compositionComponent && budgetChange < 0)
			{
				SpawnCustomResourceHolder(entityOwner, resourceComponent);
				wasContainerSpawned = true;
			}
		}

		if (!resourceComponent)
			return;

		//~ Supplies not enabled so no need to remove any
		if (!resourceComponent.IsResourceTypeEnabled())
			return;

		IEntity providerEntity = resourceComponent.GetOwner();

		if (!providerEntity)
			return;

		SCR_CampaignBuildingProviderComponent providerComponent = SCR_CampaignBuildingProviderComponent.Cast(providerEntity.FindComponent(SCR_CampaignBuildingProviderComponent));

		if (budgetChange < 0)
		{
			budgetChange = Math.Round(budgetChange * m_iCompositionRefundPercentage * 0.01);

			if (providerComponent)
				providerComponent.AddPropValue(-propBudgetValue);

			if (wasContainerSpawned)
			{
				SCR_ResourceContainer container = resourceComponent.GetContainer(EResourceType.SUPPLIES);

				if (container)
					container.SetResourceValue(-budgetChange);
			}
			else
			{
				SCR_ResourceGenerator generator = resourceComponent.GetGenerator(EResourceGeneratorID.DEFAULT, EResourceType.SUPPLIES);

				if (generator)
					generator.RequestGeneration(-budgetChange);
			}
		}
		else
		{
			if (providerComponent)
				providerComponent.AddPropValue(propBudgetValue);

			SCR_ResourceConsumer consumer = resourceComponent.GetConsumer(EResourceGeneratorID.DEFAULT, EResourceType.SUPPLIES);

			if (consumer)
				consumer.RequestConsumtion(budgetChange);
		}
	}
}



modded class GUB_RandomizeMissionLogic
{
	
	
	void Updatestupidzones()
	{
		array<GUB_DefendPointEntity> defendPoints = GetRandomizeSpawnManager().GetDefendPoints();
		foreach (GUB_DefendPointEntity defendPoint : defendPoints)
		{
			if (defendPoint == m_eDefendLocation)
			{	
				Print("---m_eDefendLocation");
				SCR_FactionManager factionManager = SCR_FactionManager.Cast(GetGame().GetFactionManager());
				if (factionManager)
				{
					FactionKey flagFactionKey = GetRandomizeSpawnManager().GetDefendFaction().m_sFactionKey;
					FactionKey flagFactionKey2 = GetRandomizeSpawnManager().GetAttackFaction().m_sFactionKey;
					//SCR_Faction flagFaction = SCR_Faction.Cast(factionManager.GetFactionByKey(flagFactionKey));
					IEntity polyzone = GetGame().GetWorld().FindEntityByName(defendPoint.GetPolyzoneEntityName());
					//polyzone.Assignpolyzoneaction(flagFaction);
					if (polyzone)
					{
						Print("-1-polyzone" + polyzone);
						
						PS_PolyZone polyzone2zone = PS_PolyZone.Cast(polyzone.FindComponent(PS_PolyZone));
						polyzone2zone.SetVisibleForFaction(flagFactionKey, true);
						polyzone2zone.SetVisibleForFaction(flagFactionKey2, true);
						Print("---polyzone2zone" + polyzone2zone.m_aVisibleForFactions);
						//polyzone.m_LinePolygon.m_iColor = Color.FromSRGBA(0,0,0,255);
						for (IEntity child = polyzone.GetChildren(); child; child = child.GetSibling())
						{
							
							PS_PolyZoneTrigger polytrigger = PS_PolyZoneTrigger.Cast(child);
							if (polytrigger)
							{	
								Print("---polytrigger" + polytrigger);
								polytrigger.m_sFactionKey = flagFactionKey;
							}
						}
					}
					
				}
			} else {
				IEntity polyzone2 = GetGame().GetWorld().FindEntityByName(defendPoint.GetPolyzoneEntityName());
				PS_PolyZone polyzone2zone = PS_PolyZone.Cast(polyzone2.FindComponent(PS_PolyZone));
				Print("---polyzone2" + polyzone2zone);
				
				if (polyzone2zone)
				//if (polyzone2)
				{
					//Print("---polyzone2" + polyzone2zone);
					//SCR_MapEntity m_MapEntity = SCR_MapEntity.GetMapInstance();
					//polyzone2zone.DeleteMapWidget(m_MapEntity.GetMapConfig());
					polyzone2.SetOrigin("0 0 0");
					Print("---getpolyzone2" + polyzone2.GetOrigin());
					//polyzone2zone.UpdatePolygon();
					delete polyzone2;
					Print("---depolyzone2" + polyzone2);
					//polyzone2zone.UpdatePolygon();
				}
			}
		}
	}
	
	
}

modded class GUB_RandomizeMissionComponent : ScriptComponent
{
	
	
	override void OnGameStateChanged(int NewState)
	{
		if (!Replication.IsServer())
			return;
		
		if (NewState == SCR_EGameModeState.BRIEFING)
		{
			m_rLogic.Updatestupidzones();
			if (m_bMarkersOnlyOnBriefing)
				m_rLogic.GenerateMarkers();
		}
		if (NewState == SCR_EGameModeState.GAME)
		{
			m_rLogic.UpdateDefendEntities();
			m_rLogic.DeleteUselessFreezeZones();
		}
	}
}

modded class GUB_DefendPointEntity : GUB_LocationPointEntity
{
	[Attribute("", UIWidgets.EditBox, "Related polyzone")]
	private string m_sPolyzoneEntityName;
	string GetPolyzoneEntityName()
	{
		return m_sPolyzoneEntityName;
	}
}


modded class PS_PolyZone
{
	void SetVisibleForFaction(FactionKey factionKey, bool visible)
	{
		Print("-1-SetVisibleForFaction called, factionKey=" + factionKey + ", visible=" + visible);
		Print("-1-SetVisibleForFaction m_ePolylineShapeEntity=" + m_ePolylineShapeEntity + ", name=" + m_ePolylineShapeEntity);
		if (Replication.IsServer())
		{
			PS_GameModeQuickTvT gameMode = PS_GameModeQuickTvT.Cast(GetGame().GetGameMode());
			if (gameMode)
				gameMode.BroadcastPolyZoneFactionChange(m_ePolylineShapeEntity, factionKey, visible);
			else
				Print("-1-ERROR: gameMode is null!");
		}
		else
		{
			Print("-1-SetVisibleForFaction called on CLIENT, skipping");
		}
	}

	void ApplyFactionVisiblity(FactionKey factionKey, bool visible)
	{
		Print("-1-ApplyFactionVisiblity called, factionKey=" + factionKey + ", visible=" + visible);
		Print("-1-ApplyFactionVisiblity m_aVisibleForFactions before: " + m_aVisibleForFactions);

		if (visible)
		{
			if (!m_aVisibleForFactions.Contains(factionKey))
				m_aVisibleForFactions.Insert(factionKey);
		}
		else
		{
			m_aVisibleForFactions.RemoveItem(factionKey);
		}

		Print("-1-ApplyFactionVisiblity m_aVisibleForFactions after: " + m_aVisibleForFactions);

		if (m_MapEntity && m_MapEntity.IsOpen())
		{
			if (IsCurrentVisibility())
			{
				if (!m_wCanvasWidget)
				{
					Print("-1-ApplyFactionVisiblity creating map widget");
					CreateMapWidget(m_MapEntity.GetMapConfig());
				}
			}
			else
			{
				if (m_wCanvasWidget)
				{
					Print("-1-ApplyFactionVisiblity deleting map widget");
					DeleteMapWidget(m_MapEntity.GetMapConfig());
				}
			}
		}
		else
		{
			Print("-1-ApplyFactionVisiblity map not open or m_MapEntity null, skipping widget refresh");
		}
	}
}


modded class PS_GameModeQuickTvT : PS_GameModeCoop
{
	void BroadcastPolyZoneFactionChange(IEntity targetEntity, FactionKey factionKey, bool visible)
	{
		Print("-2-BroadcastPolyZoneFactionChange called, entity=" + targetEntity + ", name=" + targetEntity.GetName() + ", factionKey=" + factionKey + ", visible=" + visible);
		if (!Replication.IsServer())
		{
			Print("-2-ERROR: BroadcastPolyZoneFactionChange called on client!");
			return;
		}

		PS_PolyZone polyZone = PS_PolyZone.Cast(targetEntity.FindComponent(PS_PolyZone));
		if (polyZone)
			polyZone.ApplyFactionVisiblity(factionKey, visible);
		else
			Print("-2-ERROR: polyZone is null on entity=" + targetEntity);

		string entityName = targetEntity.GetName();
		Print("-2-entityName=" + entityName);
		Rpc(RPC_BroadcastPolyZoneFactionChange, entityName, factionKey, visible);
	}

	[RplRpc(RplChannel.Reliable, RplRcver.Broadcast)]
	protected void RPC_BroadcastPolyZoneFactionChange(string entityName, FactionKey factionKey, bool visible)
	{
		Print("-3-RPC_BroadcastPolyZoneFactionChange received, entityName=" + entityName + ", factionKey=" + factionKey + ", visible=" + visible);
		IEntity targetEntity = GetGame().GetWorld().FindEntityByName(entityName);
		Print("-3-Found entity by name: " + targetEntity);
		if (!targetEntity)
		{
			Print("-3-ERROR: targetEntity is null for name=" + entityName);
			return;
		}

		PS_PolyZone polyZone = PS_PolyZone.Cast(targetEntity.FindComponent(PS_PolyZone));
		Print("-3-polyZone component: " + polyZone);
		if (polyZone)
			polyZone.ApplyFactionVisiblity(factionKey, visible);
		else
			Print("-3-ERROR: polyZone is null on found entity");
	}

}
