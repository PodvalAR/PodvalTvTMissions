import json
import re
import os

TOOLS_DIR = r"C:\Users\armen\Documents\GitHub\PodvalTvTMissions\Tools"
OLD_CATALOG_PATH = os.path.join(TOOLS_DIR, "catalog_old_prefabs.json")
NEW_CATALOG_PATH = os.path.join(TOOLS_DIR, "catalog_new_prefabs.json")
BAK_REMAP_PATH = os.path.join(TOOLS_DIR, "remap_table.json.bak")
OUTPUT_REMAP_PATH = os.path.join(TOOLS_DIR, "remap_table.json")

with open(OLD_CATALOG_PATH, "r", encoding="utf-8") as f:
    old_prefabs = json.load(f)

with open(NEW_CATALOG_PATH, "r", encoding="utf-8") as f:
    new_prefabs = json.load(f)

with open(BAK_REMAP_PATH, "r", encoding="utf-8") as f:
    bak_remap = json.load(f)

new_refs_set = {x["fullRef"]: x for x in new_prefabs}
new_by_guid = {x["guid"].upper(): x for x in new_prefabs}

# Extract leaves from bak_remap
bak_leaves = {}
def walk_bak(obj, p=""):
    for k, v in obj.items():
        if isinstance(v, dict):
            walk_bak(v, p + "/" + k if p else k)
        elif k not in ("description", "status", "_note"):
            bak_leaves[k] = (p, v)

walk_bak(bak_remap)

# Role and Scope matching patterns
ROLE_PATTERNS = {
    'squadleader': r'([_/\b](sl|squad[_\s]?leader)\b)',
    'teamleader': r'([_/\b](tl|team[_\s]?leader)\b)',
    'platoonleader': r'([_/\b](pl|platoon[_\s]?leader)\b)',
    'sapper': r'([_/\b](sapper|engineer|eod)\b)',
    'medic': r'([_/\b](medic|corpsman)\b)',
    'radioman': r'([_/\b](radioman|radio[_\s]?operator|rto)\b)',
    'machinegunner': r'([_/\b](mg|machine[_\s]?gunner|auto[_\s]?rifleman|automatic[_\s]?rifleman|ar|amg|mga|mgab)\b)',
    'antitank': r'([_/\b](at|anti[_\s]?tank|rpg|at[_\s]?gunner|aat|lat)\b)',
    'grenadier': r'([_/\b](grenadier|gl)\b)',
    'marksman': r'([_/\b](marksman|dmr)\b)',
    'sniper': r'([_/\b](sniper)\b)',
    'pilot': r'([_/\b](pilot|helipilot|helicopilot)\b)',
    'crew': r'([_/\b](crew|crewman|crewdriver|crewgunner)\b)',
    'commander': r'([_/\b](commander|officer|co)\b)',
    'rifleman': r'([_/\b](rifleman|rifl|rifle|sr)\b)',
    'scout': r'([_/\b](scout|recon)\b)'
}

def parse_item(full_ref):
    norm = re.sub(r'^\{[0-9A-Fa-f]{16}\}', '', full_ref).replace('\\', '/')
    kind = 'other'
    if '/Characters/' in norm: kind = 'char'
    elif '/Groups/' in norm: kind = 'group'
    elif '/Vehicles/' in norm: kind = 'vehicle'
    elif '/Props/' in norm: kind = 'prop'
    elif '/System/' in norm: kind = 'system'

    fac = ''
    m = re.search(r'/(OPFOR|BLUFOR|INDFOR|CIV)(?:/|_|$)', norm, re.I)
    if m: fac = m.group(1).upper()

    sub = ''
    m = re.search(r'(RHS_AFRF|RHS_USAF|RHS_GREF|RHS_SAF|(?:Ses_)?CDF|(?:Ses_)?TKR|(?:Ses_)?TKA|(?:Ses_)?CHDKZ|NAPA|FIA|USSR|USMC|SOCOM)', norm, re.I)
    if m: sub = re.sub(r'^Ses_', '', m.group(1), flags=re.I).upper()
    if not sub:
        p_up = norm.upper()
        if 'CDF' in p_up: sub = 'CDF'
        elif 'TKR' in p_up: sub = 'TKR'
        elif 'TKA' in p_up: sub = 'TKA'
        elif 'CHDKZ' in p_up: sub = 'CHDKZ'
        elif 'NAPA' in p_up: sub = 'NAPA'
        elif 'FIA' in p_up: sub = 'FIA'
        elif 'AFRF' in p_up or 'RUS' in p_up or 'MSV' in p_up or 'VDV' in p_up: sub = 'RHS_AFRF'
        elif 'USAF' in p_up or 'USMC' in p_up: sub = 'RHS_USAF'

    role = ''
    norm_lower = norm.lower()
    for r_name, r_pat in ROLE_PATTERNS.items():
        if re.search(r_pat, norm_lower):
            role = r_name
            break

    scope = ''
    if kind == 'group':
        if 'platoon' in norm_lower or '_pl' in norm_lower: scope = 'platoon'
        elif 'squad' in norm_lower: scope = 'squad'
        elif 'team' in norm_lower or 'group' in norm_lower: scope = 'team'

    fn = norm.split('/')[-1]
    name_clean = re.sub(r'\.et$', '', fn).lower()
    tokens = set(re.split(r'[_/\W]+', name_clean)) - {'drg', 'dim', 'char', 'role', 'prefabs', 'et', 'v1', 'v2', 'v3', 'random'}

    return {
        'ref': full_ref,
        'norm': norm,
        'kind': kind,
        'fac': fac,
        'sub': sub,
        'role': role,
        'scope': scope,
        'tokens': tokens,
        'fn': fn
    }

new_parsed = [parse_item(x['fullRef']) for x in new_prefabs]

def score_match(s, c):
    if s['kind'] != c['kind']: return -100
    if s['fac'] and c['fac'] and s['fac'] != c['fac']: return -100

    score = 0
    if s['fac'] and c['fac'] and s['fac'] == c['fac']: score += 3

    if s['sub'] and c['sub']:
        if s['sub'] == c['sub']: score += 8
        else: return -100  # Do not cross subfactions! (CDF cannot be US, TKR cannot be AFRF)

    if s['role'] and c['role']:
        if s['role'] == c['role']: score += 12
        else: score -= 10

    if s['scope'] and c['scope']:
        if s['scope'] == c['scope']: score += 10
        else: score -= 8

    overlap = len(s['tokens'] & c['tokens'])
    union = len(s['tokens'] | c['tokens'])
    if union:
        score += 10.0 * overlap / union

    return score

# Process mod prefabs from old catalog
mod_prefabs = [x for x in old_prefabs if x.get('isModPrefab')]
print(f"Total mod prefabs in catalog_old: {len(mod_prefabs)}")

# Build mapping
final_mappings = {}

# Specific curated domain overrides for roles/groups where official standard applies
DOMAIN_EXACT = {
    # 10 Broken entries from old remap table:
    '{4612D50C1FEF9520}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Mortar_Spotter.et': '{E5FAE060344FEA9D}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_ObserverMortor.et',
    '{604FADEAA6112C7A}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_SMAW_Gunner.et': '{5ED534ADC95D6EFA}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_LAT.et',
    '{908EF30550BE5428}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Spotter.et': '{E5FAE060344FEA9D}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_ObserverMortor.et',
    '{C8DD9F6ECC3F3EC1}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Sniper_cap.et': '{283076EBB65C44D9}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Sniper.et',
    '{D82203FB9DC2F6C6}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_RTO.et': '{680139B54800F449}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Rifle.et',
    '{F910309D8C211296}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_PL.et': '{D94B7ED60715A28D}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_PL.et',

    # Missing USAF roles
    '{67C97355F74099C5}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_TL.et': '{970A405D2BE6DE43}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_TL.et',
    '{0D86781BA3428115}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_AR.et': '{2DDD36502876310E}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_AR.et',
    '{0053063A54F5E83F}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_GL.et': '{20084871DFC15824}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_GL.et',
    '{600E890491C62306}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_SL.et': '{4055C74F1AF2931D}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_SL.et',
    '{74A02B02FD60CB8E}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Rifleman_LAT.et': '{5ED534ADC95D6EFA}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_LAT.et',
    '{893533817C25A8B0}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Medic.et': '{0D659E49AD2F5FF6}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Medic.et',
    '{26AD8B80E8C02793}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Marksman.et': '{AEC67AECA3B4E70F}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Marksman.et',
    '{C7543DBFCFDB9ACB}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Sniper.et': '{283076EBB65C44D9}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Sniper.et',
    '{741676D36040EA84}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Rifleman.et': '{680139B54800F449}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Rifle.et',
    '{36FE68EB81398B5C}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_MG_opt.et': '{4D661F7A740156C0}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_MG_Opt.et',
    '{5F91A601CD0D95F6}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_MG.et': '{C4D04C299FA248E5}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_MG.et',
    '{CFB9AD45454644A2}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_Pilot.et': '{E2C35369F43FD755}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_HeliPilot.et',
    '{9594A3E1D353897B}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_HeliCrew.et': '{0AFCD29486EE4F2A}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_HeliCrew.et',
    '{69A9873AE3BF8B1D}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_SMAW_AmmoBearer.et': '{680139B54800F449}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/Char_RHS_USAF_Regular_Rifle.et',
    '{FEA8A03109D0FC66}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/USAF/drg_Role_RHS_USAF_MGA.et': '{275B26E305C8FB31}Prefabs/Characters/Factions/BLUFOR/RHS_USAF/Regular/MARSOC/Char_Marpat_AMG.et',

    # CDF Army missing
    '{DC6EA865F186B3D1}Prefabs/Characters/Factions/BLUFOR/CDF_Army/drg_Character_CDF_Rifleman.et': '{7AB6CF75D8A31BEB}Prefabs/Characters/Factions/BLUFOR/CDF_Army/Char_A2F_CDF_Rifle_Random.et',
    '{E94CBA221C90E93D}Prefabs/Characters/Factions/BLUFOR/CDF_Army/drg_Character_CDF_Sniper.et': '{DF081FFC7A479F9B}Prefabs/Characters/Factions/BLUFOR/CDF_Army/Char_A2F_CDF_SR_Random.et',
    '{14B773656108F1C6}Prefabs/Characters/Factions/BLUFOR/CDF_Army/drg_Character_CDF_SL.et': '{98918C4F8902542E}Prefabs/Characters/Factions/BLUFOR/CDF_Army/Char_A2F_CDF_SL_Random.et',
    '{69AF9F9D049BCD5F}Prefabs/Characters/Factions/BLUFOR/CDF_Army/drg_Character_CDF_SR.et': '{DF081FFC7A479F9B}Prefabs/Characters/Factions/BLUFOR/CDF_Army/Char_A2F_CDF_SR_Random.et',
    '{8DA9CAFC7CEFC056}Prefabs/Characters/Factions/BLUFOR/CDF_Army/drg_Character_CDF_PL.et': '{1CA3533D910F8C24}Prefabs/Characters/Factions/BLUFOR/CDF_Army/Char_A2F_CDF_Officer_1.et',

    # Missing AFRF Army & Recon
    '{AA940AC4424CAB87}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Army/drg_Role_RHS_AFRF_Army_HeliPilot.et': '{AE405A08D166D42A}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Regular/Char_RHS_AFRF_Regular_HeliPilot.et',
    '{11B63393B80FDA1E}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Army/drg_Role_RHS_AFRF_Army_HeliCoPilot.et': '{897A446F00F48D65}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Regular/Char_RHS_AFRF_Regular_HeliCoPilot.et',
    '{C9B4F42D5A98C7A7}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Army/drg_Role_RHS_AFRF_Army_HeliCrew.et': '{205167CD55FE6B61}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Regular/Char_RHS_AFRF_Regular_HeliCrew.et',
    '{3E2F6230E4397D70}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Army/drg_Role_RHS_AFRF_Army_AR.et': '{0E72C07D7B1C9872}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Regular/Char_RHS_AFRF_Regular_AR.et',
    '{964F7C7E17A618E4}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Recon/drg_Role_RHS_AFRF_Recon_SquadLeader.et': '{4C46B416166D1A0E}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Recon/Char_RHS_AFRF_Recon_SL_Opt.et',
    '{89072075B73F4C52}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Recon/drg_Role_RHS_AFRF_Recon_SeniorRifleman.et': '{2504B4EAB8F9B6D6}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Recon/Char_RHS_AFRF_Recon_SR.et',
    '{FA87DB28ECBB88A4}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Recon/drg_Role_RHS_AFRF_Recon_Rifleman.et': '{A2EE828BDE9F8565}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Recon/Char_RHS_AFRF_Recon_Rifleman.et',
    '{1AB049064B53BD02}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Recon/drg_Role_RHS_AFRF_Recon_Grenadier.et': '{F23CE1E829569766}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Recon/Char_RHS_AFRF_Recon_GL.et',
    '{2BB6F9C635CFFE8B}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Recon/drg_Role_RHS_AFRF_Recon_Sniper.et': '{9F65B45FBF51D043}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Recon/Char_RHS_AFRF_Recon_Sniper.et',
    '{DF973A765CF4CE88}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Recon/drg_Role_RHS_AFRF_Recon_Rifle_GM94.et': '{F23CE1E829569766}Prefabs/Characters/Factions/OPFOR/RHS_AFRF/Recon/Char_RHS_AFRF_Recon_GL.et',

    # Vehicles exact matches
    '{6F963B40DE04868A}Prefabs/Vehicles/Wheeled/BTR70/BTR70_Ses_TKA.et': '{6F963B40DE04868B}Prefabs/Vehicles/Wheeled/BTR70/BTR70_Ses_TKA.et',
    '{6C98ACF4A2DA1970}Prefabs/Vehicles/Wheeled/Ural4320/Ses_TKA/Ural4320_Ses_TKA_transport.et': '{10BD77D4593B7366}Prefabs/Vehicles/Wheeled/Ural4320/Ses_TKA/Ural4320_Ses_TKA_transport.et',
    '{A36B7742CB4CC488}Prefabs/Vehicles/Wheeled/UAZ469/UAZ469_Ses_CDF.et': '{A36B7742CB4CC489}Prefabs/Vehicles/Wheeled/UAZ469/UAZ469_Ses_CDF.et',
    '{0EFFC9A8E672EF33}Prefabs/Vehicles/Wheeled/Ural4320/Ses_CDF/Ural4320_Ses_CDF_transport_covered.et': '{B3BE9258C89E8491}Prefabs/Vehicles/Wheeled/Ural4320/Ses_CDF/Ural4320_Ses_CDF_transport_covered.et',
    '{04B2A928ED8A2753}Prefabs/Vehicles/Wheeled/BTR70/BTR70_Ses_TKR.et': '{04B2A928ED8A2754}Prefabs/Vehicles/Wheeled/BTR70/BTR70_Ses_TKR.et',
    '{B73E5281A78D98D6}Prefabs/Vehicles/Wheeled/BTR70/BTR70_Ses_TKG.et': '{04B2A928ED8A2754}Prefabs/Vehicles/Wheeled/BTR70/BTR70_Ses_TKR.et',

    # Groups main formations
    '{02B7DC04CD35582D}Prefabs/Groups/BLUFOR/CDF/drg_CDF_PlatoonHQ.et': '{F2ABAC37E4537895}Prefabs/Groups/BLUFOR/Ses_CDF/Group_A2F_CDF_PL.et',
    '{D03F49D1589BABAD}Prefabs/Groups/BLUFOR/CDF/drg_CDF_RifleSquad.et': '{6449AAD99869C0D5}Prefabs/Groups/BLUFOR/Ses_CDF/Group_A2F_CDF_Squad.et',
    '{83A26C7CCCC5BC24}Prefabs/Groups/BLUFOR/CDF/DRG_Group_Ses_CDF_RifleSquad_P.et': '{6449AAD99869C0D5}Prefabs/Groups/BLUFOR/Ses_CDF/Group_A2F_CDF_Squad.et',
    '{817E13F5454DCF88}Prefabs/Groups/INDFOR/TKR/Group_Ses_TKR_PlatoonHQ.et': '{0217FB6BBEC0F7E1}Prefabs/Groups/INDFOR/TKR/Group_Ses_TKR_PL_1.et',
    '{281B7FA5A70021D5}Prefabs/Groups/INDFOR/TKR/Group_Ses_TKR_RifleSquad.et': '{FD47A0A8CE51D3BE}Prefabs/Groups/INDFOR/TGK/drg_TKR_RifleSquad.et',
    '{0223367D44716E7B}Prefabs/Groups/OPFOR/RHS_AFRF/MSV/VKPO_Summer/Group_RHS_RF_MSV_VKPO_S_PlatoonHQ.et': '{496070641528229D}Prefabs/Groups/OPFOR/RHS_AFRF/Regular/Group_RHS_AFRF_Regular_PL.et',
    '{256AEA338E84EC28}Prefabs/Groups/OPFOR/RHS_AFRF/MSV/VKPO_Summer/Group_RHS_RF_MSV_VKPO_S_RifleSquad.et': '{422F09FFC95B59ED}Prefabs/Groups/OPFOR/RHS_AFRF/Regular/Group_RHS_AFRF_Regular_RifS.et',
    '{D3940577D05FE450}Prefabs/Groups/OPFOR/RHS_AFRF/MSV/Flora/Group_RHS_RF_MSV_Flora_RifleSquad.et': '{B7B2B62ED87AE609}Prefabs/Groups/OPFOR/RHS_AFRF/2000s/New/Flora/Group_RHS_AFRF_2000s_Flora_Regular_Squad.et',
    '{52DBD8AD794AA412}Prefabs/Groups/OPFOR/drg_AFRF_CompanyHQ.et': '{496070641528229D}Prefabs/Groups/OPFOR/RHS_AFRF/Regular/Group_RHS_AFRF_Regular_PL.et',
    '{11FEE261D621348B}Prefabs/Groups/OPFOR/Ses_ChDKZ/Group_ChDKZ_PlatoonHQ.et': '{2046896265B5FE6B}Prefabs/Groups/OPFOR/Ses_ChDKZ/Group_ChDKZ_PL_1_Defend.et',
    '{382D76092628D3F8}Prefabs/Groups/OPFOR/Ses_ChDKZ/Group_ChDKZ_RifleSquad.et': '{6EE0420E77A6D884}Prefabs/Groups/OPFOR/Ses_ChDKZ/Group_ChDKZ_Squad.et',
    '{F84C950E55A7BD7E}Prefabs/Groups/OPFOR/Ses_TKA/Group_Ses_TKA_RifleSquad.et': '{8E998DBA2D3C77D5}Prefabs/Groups/OPFOR/Ses_TKA/Group_A2F_TKA_Squad.et',
    '{F21917B6C71E18E0}Prefabs/Groups/OPFOR/Ses_TKA/Group_Ses_TKA_PlatoonHQ.et': '{1DD86DF1B369B919}Prefabs/Groups/OPFOR/Ses_TKA/Group_A2F_TKA_PL_3.et',
    '{E085F8818A48E44C}Prefabs/Groups/INDFOR/Ses_NAPA/Group_NAPA_PlatoonHQ.et': '{DCD8228C4EDF1DC8}Prefabs/Groups/INDFOR/Ses_NAPA/Group_NAPA_PL_1.et',
    '{877F196BC06EF9B7}Prefabs/Groups/INDFOR/Ses_NAPA/Group_NAPA_RifleSquad.et': '{0C3DE10703CC223E}Prefabs/Groups/INDFOR/Ses_NAPA/Group_NAPA_Squad_3.et',
    '{00EE04014F213BCF}Prefabs/Groups/INDFOR/TKR/Group_Ses_TKR_LightFireTeam.et': '{3B79C4E047BE13BA}Prefabs/Groups/INDFOR/TKR/Group_Ses_TKR_FireTeam.et',
    '{4170F3A7E4137FDA}Prefabs/Groups/INDFOR/TKR/Group_Ses_TKR_ReconTeam.et': '{DF063547C351B291}Prefabs/Groups/INDFOR/TKR/Group_Ses_TKR_ReconTeam.et'
}

for item in mod_prefabs:
    ref = item['fullRef']

    # If already verbatim alive in mod, skip (it's not broken)
    if ref in new_refs_set:
        continue

    # Priority 1: Domain Exact override
    if ref in DOMAIN_EXACT:
        target = DOMAIN_EXACT[ref]
        if target in new_refs_set:
            final_mappings[ref] = target
            continue

    # Priority 2: Exact same GUID renamed
    g = item['guid'].upper()
    if g in new_by_guid:
        n = new_by_guid[g]
        if n['fullRef'] != ref:
            final_mappings[ref] = n['fullRef']
            continue

    # Priority 3: Previous valid mapping from backup
    if ref in bak_leaves:
        prev_target = bak_leaves[ref][1]
        if prev_target and prev_target in new_refs_set:
            final_mappings[ref] = prev_target
            continue

    # Priority 4: Algorithm Rank-Candidates
    s = parse_item(ref)
    if s['kind'] in ('char', 'group', 'vehicle'):
        best = None
        best_sc = -99
        for c in new_parsed:
            sc = score_match(s, c)
            if sc > best_sc:
                best_sc = sc
                best = c

        # If score is sufficiently high (>= 20) and role/scope match, accept
        if best and best_sc >= 20.0 and best['ref'] in new_refs_set:
            final_mappings[ref] = best['ref']
            continue
        elif best and best_sc >= 15.0 and s['role'] and s['role'] == best['role'] and best['ref'] in new_refs_set:
            final_mappings[ref] = best['ref']
            continue

    # Otherwise leave as stub "" for user decision
    final_mappings[ref] = ""

print(f"Total mapped entries to write: {len(final_mappings)}")
filled_cnt = sum(1 for v in final_mappings.values() if v)
stub_cnt = sum(1 for v in final_mappings.values() if not v)
print(f"Filled: {filled_cnt}, Stubs: {stub_cnt}")

# Function to determine hierarchical placement
def get_trail(item):
    p = item['path'].replace('\\', '/')
    parts = p.split('/')
    cat = item.get('category', 'Other')

    if cat == 'Characters':
        if len(parts) >= 5 and parts[2] == 'Factions':
            fac = parts[3]
            sub = parts[4]
            rest = parts[5:-1]
            return ['Characters', fac, sub] + rest
        return ['Characters', 'Other']

    elif cat == 'Groups':
        if len(parts) >= 4:
            fac = parts[2]
            return ['Groups', fac] + parts[3:-1]
        elif len(parts) >= 3:
            return ['Groups', parts[2]]
        return ['Groups', 'Other']

    elif cat == 'Vehicles':
        if len(parts) >= 4:
            return ['Vehicles', parts[2]] + parts[3:-1]
        elif len(parts) >= 3:
            return ['Vehicles', parts[2]]
        return ['Vehicles', 'Other']

    elif cat == 'Props':
        if len(parts) >= 4:
            return ['Props', parts[2]] + parts[3:-1]
        elif len(parts) >= 3:
            return ['Props', parts[2]]
        return ['Props', 'Other']

    elif cat == 'System':
        return ['_Unresolved_Pending']

    return ['_Unresolved_Pending']

# Assemble nested dict
root = {
    "_meta": {
        "description": "Remap of removed DRG-mod prefab refs -> current equivalents. Grouped Category > Faction > FactionKey > Type for manual reading. Key = OLD full ref {GUID}Path.et, value = NEW full ref. Empty value = stub awaiting a replacement; the restore script applies only filled entries and skips/flags stubs. Grouping keys (Characters, OPFOR, RHS_AFRF, ...) are ignored by the script.",
        "status": f"All {filled_cnt} filled entries validated against catalog_new_prefabs.json (GUID and path match exactly). {stub_cnt} entries left as stubs for manual user review or specialized variant choice."
    }
}

for item in mod_prefabs:
    ref = item['fullRef']
    if ref not in final_mappings:
        continue
    target = final_mappings[ref]
    trail = get_trail(item)

    curr = root
    for seg in trail:
        if seg not in curr:
            curr[seg] = {}
        curr = curr[seg]

    curr[ref] = target

# Write to OUTPUT_REMAP_PATH
with open(OUTPUT_REMAP_PATH, "w", encoding="utf-8") as f:
    json.dump(root, f, indent=4, ensure_ascii=False)

print(f"Successfully generated new remap_table.json at {OUTPUT_REMAP_PATH}")
