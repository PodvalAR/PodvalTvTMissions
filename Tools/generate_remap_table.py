#!/usr/bin/env python3
"""Bootstrap and bulk-fill remap_table.json from a tree of legacy missions.

The remap table answers "what replaces what". This script is how it learns an answer for
a reference nobody has decided yet: it scans a legacy mission tree, matches each broken
reference against the mod catalog, and proposes a replacement.

It is a DRY RUN by default. Pass --write to persist the proposals as empty stubs in the
_Unresolved_Pending group; they then get their real values in the editor's "База ремапа"
tab, which is the single source of truth for the table from that point on.

Existing assignments are never recomputed. Whatever the current table already declares
(filled or stub) is treated as decided and carried through untouched, so running the
bootstrap on a partially filled table is safe and idempotent.

Typical use:

    # See what would be proposed, touching nothing.
    python generate_remap_table.py --source-root "D:\\PodvalCommunityEvent\\Worlds"

    # Declare the unresolved ones as stubs.
    python generate_remap_table.py --source-root "D:\\..." --write
"""

import argparse
import json
import os
import re
import sys

DEFAULT_TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- input catalogs

def load_new_catalog(path):
    """The mod catalog: every prefab that exists today and is a legal replacement target."""
    with open(path, "r", encoding="utf-8-sig") as f:
        items = json.load(f)
    by_ref = {x["fullRef"]: x for x in items}
    by_guid = {x["guid"].upper(): x for x in items}
    return items, by_ref, by_guid


def load_existing_table(path):
    """Whatever the current table already declares. Keys are full refs, values are new refs or ''."""
    if not path or not os.path.isfile(path):
        return {}
    with open(path, "r", encoding="utf-8-sig") as f:
        root = json.load(f)
    leaves = {}

    def walk(node):
        if not isinstance(node, dict):
            return
        for key, value in node.items():
            if key in ("description", "status", "_note"):
                continue
            if isinstance(value, dict):
                walk(value)
            else:
                leaves[key] = value

    walk(root)
    return leaves


def load_curated_overrides(path):
    if not path or not os.path.isfile(path):
        return {}
    with open(path, "r", encoding="utf-8-sig") as f:
        doc = json.load(f)
    return doc.get("overrides", {}) or {}


# ---------------------------------------------------------------- legacy scan

REF_RE = re.compile(r'\{([0-9A-Fa-f]{16})\}([^"]+?\.et)')


def scan_legacy_refs(source_root):
    """Scan a legacy mission tree and return ref -> {'count': int, 'missions': [str]}.

    This is the same evidence the PowerShell sweep (Sync-LegacyRefsToRemapTable) uses;
    it is recomputed here instead of read from a catalog file, so the bootstrap never
    depends on a stale snapshot of somebody else's machine.
    """
    if not source_root or not os.path.isdir(source_root):
        raise SystemExit("Legacy source root not found: %s" % source_root)

    root = os.path.normpath(source_root)
    refs = {}
    missions = set()

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for filename in filenames:
            if not filename.endswith((".layer", ".ent")):
                continue
            full_path = os.path.join(dirpath, filename)
            try:
                with open(full_path, "r", encoding="utf-8-sig", errors="replace") as f:
                    text = f.read()
            except OSError:
                continue
            matches = REF_RE.findall(text)
            if not matches:
                continue
            rel = os.path.relpath(full_path, root).replace("\\", "/").split("/")
            missions.add("/".join(rel[:2]) if len(rel) > 1 else rel[0])
            for guid, path in matches:
                ref = "{%s}%s" % (guid.upper(), path)
                entry = refs.setdefault(ref, {"count": 0, "missions": set()})
                entry["count"] += 1
                entry["missions"].add("/".join(rel[:2]) if len(rel) > 1 else rel[0])

    for entry in refs.values():
        entry["missions"] = sorted(entry["missions"])
    return refs, sorted(missions)


# ---------------------------------------------------------------- matching

# A ref matching this "looks like it should ship inside the mod". Mirrors SuspectRx in
# Restore-Core.ps1: bootstrap and the sweep must agree on what counts as broken.
SUSPECT_RE = re.compile(
    r"(drg_|dim_|Char_A2F|Char_RHS|Role_Character|/Group_RHS|/Group_A2F|Ses_|Group_Ses|Group_NAPA|Group_FIA|DRG_)",
    re.I,
)
IGNORE_RE = re.compile(r"(/System/|MissionEndTimer|/Logic/|GameMode|/Modes/|Manager\.et$|Trigger|PerceptionManager|AIWorld)", re.I)

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
    'scout': r'([_/\b](scout|recon)\b)',
}

FACTION_RE = re.compile(r'/(OPFOR|BLUFOR|INDFOR|CIV)(?:/|_|$)', re.I)
SUBFACTION_RE = re.compile(
    r'(RHS_AFRF|RHS_USAF|RHS_GREF|RHS_SAF|(?:Ses_)?CDF|(?:Ses_)?TKR|(?:Ses_)?TKA|(?:Ses_)?CHDKZ|NAPA|FIA|USSR|USMC|SOCOM)',
    re.I,
)


def classify_ref(full_ref):
    norm = re.sub(r'^\{[0-9A-Fa-f]{16}\}', '', full_ref).replace('\\', '/')
    kind = 'other'
    if '/Characters/' in norm:
        kind = 'char'
    elif '/Groups/' in norm:
        kind = 'group'
    elif '/Vehicles/' in norm:
        kind = 'vehicle'
    elif '/Props/' in norm:
        kind = 'prop'
    elif '/System/' in norm:
        kind = 'system'

    faction = ''
    m = FACTION_RE.search(norm)
    if m:
        faction = m.group(1).upper()

    sub = ''
    m = SUBFACTION_RE.search(norm)
    if m:
        sub = re.sub(r'^Ses_', '', m.group(1), flags=re.I).upper()

    role = ''
    lower = norm.lower()
    for role_name, pattern in ROLE_PATTERNS.items():
        if re.search(pattern, lower):
            role = role_name
            break

    scope = ''
    if kind == 'group':
        if 'platoon' in lower or '_pl' in lower:
            scope = 'platoon'
        elif 'squad' in lower:
            scope = 'squad'
        elif 'team' in lower or 'group' in lower:
            scope = 'team'

    stem = os.path.basename(norm)
    name_clean = re.sub(r'\.et$', '', stem).lower()
    tokens = set(re.split(r'[_/\W]+', name_clean)) - {
        'drg', 'dim', 'char', 'role', 'prefabs', 'et', 'v1', 'v2', 'v3', 'random'
    }

    return {
        'ref': full_ref, 'norm': norm, 'kind': kind, 'fac': faction, 'sub': sub,
        'role': role, 'scope': scope, 'tokens': tokens,
    }


def score_match(source, candidate):
    """Rank a candidate replacement for a broken reference. -100 means incompatible."""
    if source['kind'] != candidate['kind']:
        return -100
    if source['fac'] and candidate['fac'] and source['fac'] != candidate['fac']:
        return -100

    score = 0
    if source['fac'] and candidate['fac'] and source['fac'] == candidate['fac']:
        score += 3

    # Never cross subfactions: a CDF rifleman is not a US one.
    if source['sub'] and candidate['sub']:
        if source['sub'] != candidate['sub']:
            return -100
        score += 8

    if source['role'] and candidate['role']:
        if source['role'] == candidate['role']:
            score += 12
        else:
            score -= 10

    if source['scope'] and candidate['scope']:
        if source['scope'] == candidate['scope']:
            score += 10
        else:
            score -= 8

    union = len(source['tokens'] | candidate['tokens'])
    if union:
        score += 10.0 * len(source['tokens'] & candidate['tokens']) / union
    return score


# ---------------------------------------------------------------- proposal

def propose(refs, new_by_ref, new_by_guid, existing, overrides):
    """Classify each scanned ref and decide what (if anything) to write for it.

    Priority order, strongest first:
      0. already decided in the current table  -> carry through, never recompute
      1. curated override that still resolves    -> use it
      2. same GUID under a different path        -> the engine already resolves it
      3. ranked match against the mod catalog    -> propose, subject to a score floor
    Everything else stays a stub for the operator to decide.
    """
    parsed_new = [classify_ref(x["fullRef"]) for x in new_by_ref.values()]

    kept = 0
    filled = []
    proposed = []
    skipped_overrides = []
    already_stubbed = 0
    alive = 0
    ignored = 0
    unresolved = 0

    for ref in sorted(refs):
        guid = re.match(r'^\{([0-9A-Fa-f]{16})\}', ref)
        guid = guid.group(1).upper() if guid else ''

        if guid in new_by_guid:
            alive += 1
            continue
        if IGNORE_RE.search(ref):
            ignored += 1
            continue
        if not SUSPECT_RE.search(ref):
            unresolved += 1
            continue

        # Priority 0: the operator already decided this one.
        if ref in existing:
            kept += 1
            if existing[ref]:
                filled.append(ref)
            else:
                already_stubbed += 1
            continue

        if ref in overrides:
            target = overrides[ref]
            if target in new_by_ref:
                filled.append(ref)
                continue
            # A curated override pointing at a prefab the mod no longer ships is a
            # stale override, not a reason to guess. Report it and fall through.
            skipped_overrides.append((ref, target))

        guid_entry = new_by_guid.get(guid)
        if guid_entry and guid_entry["fullRef"] != ref:
            proposed.append((ref, guid_entry["fullRef"], "same-guid"))
            continue

        source = classify_ref(ref)
        if source['kind'] in ('char', 'group', 'vehicle'):
            # A role match is what makes an automatic proposal defensible; a bare token
            # overlap is not. Both the score and the matched role travel together so the
            # borderline rule below cannot accidentally read another candidate's role.
            ranked = sorted(
                ((score_match(source, candidate), candidate['ref'], candidate['role'])
                 for candidate in parsed_new),
                key=lambda triple: (-triple[0], triple[1]),
            )
            best_score, best_ref, best_role = ranked[0]
            strong = best_score >= 20.0
            borderline = (best_score >= 15.0 and source['role'] and best_role == source['role'])
            if best_ref in new_by_ref and (strong or borderline):
                proposed.append((ref, best_ref, "ranked %.1f" % best_score))
                continue

        unresolved += 1

    return {
        'kept': kept, 'already_stubbed': already_stubbed, 'alive': alive,
        'ignored': ignored, 'unresolved': unresolved, 'filled': filled,
        'proposed': proposed, 'skipped_overrides': skipped_overrides,
    }


# ---------------------------------------------------------------- output

def group_path(ref):
    """Place an undecided reference under Category > Faction in the unresolved group."""
    norm = re.sub(r'^\{[0-9A-Fa-f]{16}\}', '', ref).replace('\\', '/')
    parts = norm.split('/')
    if parts[0] != 'Prefabs' or len(parts) < 2:
        return ['_Unresolved_Pending', 'Other']
    category = parts[1]
    rest = parts[2:]
    if len(rest) > 2 and rest[0] == 'Factions':
        return ['_Unresolved_Pending', category, rest[0]] + rest[1:-1]
    if len(rest) > 1:
        return ['_Unresolved_Pending', category] + rest[:-1]
    return ['_Unresolved_Pending', category]


def write_table(path, entries, source_root, mission_count, stats):
    root = {
        "_meta": {
            "description": "Remap of removed DRG-mod prefab refs -> current equivalents. "
                           "Grouped Category > Faction > FactionKey > Type for manual reading. "
                           "Key = OLD full ref {GUID}Path.et, value = NEW full ref. "
                           "Empty value = stub awaiting a replacement; the restore script applies "
                           "only filled entries and skips/flags stubs. Grouping keys are ignored by the script.",
            "status": "Bootstrapped by generate_remap_table.py from %s (%d missions): "
                      "%d kept from the previous table, %d assigned, %d stubs need a decision."
                      % (source_root, mission_count, stats['kept'], len(stats['filled']), stats['unresolved']),
        }
    }
    for ref, target, _reason in entries:
        node = root
        for segment in group_path(ref):
            node = node.setdefault(segment, {})

    for ref, target, _reason in entries:
        node = root
        for segment in group_path(ref):
            node = node[segment]
        node[ref] = target

    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(root, f, indent=4, ensure_ascii=False)
        f.write("\n")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Bootstrap remap_table.json from a legacy mission tree (dry run by default).")
    parser.add_argument("--tools-dir", default=DEFAULT_TOOLS_DIR,
                        help="Directory holding the catalogs and the table (default: script directory).")
    parser.add_argument("--source-root", default=None,
                        help="Legacy mission tree to scan. Required.")
    parser.add_argument("--new-catalog", default=None,
                        help="Mod prefab catalog (default: <tools-dir>/catalog_new_prefabs.json).")
    parser.add_argument("--remap-table", default=None,
                        help="Remap table to read and (with --write) update (default: <tools-dir>/remap_table.json).")
    parser.add_argument("--overrides", default=None,
                        help="Curated overrides (default: <tools-dir>/curated_overrides.json).")
    parser.add_argument("--out", default=None, help="Write the proposed table here instead of --remap-table.")
    parser.add_argument("--write", action="store_true",
                        help="Actually write the table. Without it nothing is modified.")
    parser.add_argument("--limit", type=int, default=200, help="How many proposals to print (default: 200).")
    args = parser.parse_args(argv)

    tools_dir = os.path.abspath(args.tools_dir)
    new_catalog_path = args.new_catalog or os.path.join(tools_dir, "catalog_new_prefabs.json")
    table_path = args.remap_table or os.path.join(tools_dir, "remap_table.json")
    overrides_path = args.overrides or os.path.join(tools_dir, "curated_overrides.json")
    out_path = args.out or table_path

    if not args.source_root:
        parser.error("--source-root is required")

    new_items, new_by_ref, new_by_guid = load_new_catalog(new_catalog_path)
    existing = load_existing_table(table_path)
    overrides = load_curated_overrides(overrides_path)
    refs, missions = scan_legacy_refs(args.source_root)

    print("Legacy source : %s" % args.source_root)
    print("Missions      : %d" % len(missions))
    print("Mod catalog   : %s (%d prefabs)" % (new_catalog_path, len(new_items)))
    print("Remap table   : %s (%d declared)" % (table_path, len(existing)))
    print("Overrides     : %s (%d curated)" % (overrides_path, len(overrides)))
    print("")

    result = propose(refs, new_by_ref, new_by_guid, existing, overrides)

    print("  already decided (kept) : %d" % result['kept'])
    print("    of which assigned   : %d" % len(result['filled']))
    print("    of which stubs      : %d" % result['already_stubbed'])
    print("  alive in mod           : %d" % result['alive'])
    print("  logic/ignored          : %d" % result['ignored'])
    print("  needs a decision       : %d" % result['unresolved'])
    print("")

    if result['skipped_overrides']:
        print("Stale curated overrides (target missing from the mod catalog):")
        for ref, target in result['skipped_overrides']:
            print("   %s  ->  %s" % (ref, target))
        print("")

    entries = [(ref, target, reason) for ref, target, reason in result['proposed']]
    print("Proposals (%d):" % len(entries))
    for ref, target, reason in entries[:args.limit]:
        print("   [%s] %s\n        -> %s" % (reason, ref, target))
    if len(entries) > args.limit:
        print("   ... and %d more" % (len(entries) - args.limit))
    print("")

    # Everything the current table already declares is carried through verbatim, filled
    # or not. A bootstrap that dropped undecided stubs would silently delete the very
    # list of decisions the operator has not made yet.
    payload = [(ref, target, "existing") for ref, target in sorted(existing.items())]
    payload += entries

    if not args.write:
        print("DRY RUN: nothing was written. Re-run with --write to declare the proposals.")
        return 0

    write_table(out_path, payload, args.source_root, len(missions), result)
    print("Wrote %d entries to %s" % (len(payload), out_path))
    print("Assign the stubs in the editor before running a restore.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
