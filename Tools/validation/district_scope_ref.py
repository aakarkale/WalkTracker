"""Checks the district-scoped totals SQL against a real built pack, mirroring
CityPackStore.totals(includeOptional:districtIDs:).

Scoping changes the denominator of the headline percentage, so an error here
does not crash anything, it just quietly reports the wrong number. The
property that matters is that districts partition the city: if scoped subsets
did not sum to the scoped whole, the figure would be incoherent and nobody
would be able to tell by looking at it.

Expects testville.v1.sqlite beside it, as built by e2e_pack.py's instructions.
"""
import sqlite3, sys, os

OPTIONAL = ("service", "track", "steps", "path")

def main():
    db = "testville.v1.sqlite"
    if not os.path.exists(db):
        print(f"SKIP no pack at {db}; build one first, see this directory's README")
        return 0

    con = sqlite3.connect(db)
    opt_list = ",".join(f"'{c}'" for c in OPTIONAL)

    def totals(include_optional, ids=None):
        clauses, params = [], []
        if not include_optional:
            clauses.append(f"class NOT IN ({opt_list})")
        if ids is not None:
            if not ids:
                return (0.0, 0)
            clauses.append("district_id IN (" + ",".join("?" for _ in ids) + ")")
            params = sorted(ids)
        sql = "SELECT COALESCE(SUM(length_m), 0), COUNT(*) FROM segment"
        if clauses:
            sql += " WHERE " + " AND ".join(clauses)
        return con.execute(sql, params).fetchone()

    districts = con.execute(
        "SELECT id, name, segment_count FROM district ORDER BY id"
    ).fetchall()
    if not districts:
        print("SKIP pack has no districts, nothing to scope")
        return 0

    fails = 0
    def check(name, cond, extra=""):
        nonlocal fails
        print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  " + extra))
        if not cond:
            fails += 1

    whole_len, whole_n = totals(False)
    print(f"pack: {len(districts)} districts, {whole_n} blocks in default classes")

    all_ids = {d[0] for d in districts}
    scoped_len, scoped_n = totals(False, all_ids)
    unassigned = con.execute(
        f"SELECT COUNT(*) FROM segment WHERE district_id IS NULL AND class NOT IN ({opt_list})"
    ).fetchone()[0]

    check("every district plus the unassigned blocks accounts for the whole city",
          scoped_n + unassigned == whole_n, f"{scoped_n} + {unassigned} vs {whole_n}")
    check("one district is a strict subset", 0 < totals(False, {districts[0][0]})[1] < whole_n)
    check("an empty scope counts nothing", totals(False, set()) == (0.0, 0))
    check("no scope counts everything", totals(False, None) == (whole_len, whole_n))
    check("districts partition cleanly, no block counted twice",
          sum(totals(False, {d[0]})[1] for d in districts) == scoped_n)
    check("optional classes are still excludable inside a scope",
          totals(True, {districts[0][0]})[1] >= totals(False, {districts[0][0]})[1])

    for did, name, stored in districts:
        n = totals(True, {did})[1]
        check(f"district {name} scoped count matches the stored count", n == stored, f"{n} vs {stored}")

    print(f"\n{'ALL PASS' if fails == 0 else str(fails) + ' FAILURES'}")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
