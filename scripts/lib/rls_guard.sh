# Row-level-security guard (BACKUP_RLS_GUARD=TRUE), sourced by backup.sh. With
# pg_dump --enable-row-security, the policies decide what the login reads: a table
# no policy opens in full to it is dumped short, or empty, with no error at all.
# These two checks run before each dump; either finding a table fails that
# database and keeps its previous dump. SQL reused verbatim from Pharmakon's backup.sh.

# Tables with row-level security that no permissive policy opens in full to this login
# for SELECT — one that applies to it (PUBLIC, it, or a role whose privileges it has),
# for SELECT or ALL, USING (true). Empty when there are none.
RLS_UNREAD_TABLES="select coalesce(string_agg(format('%I.%I', n.nspname, c.relname), ' ' order by n.nspname, c.relname), '')
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relrowsecurity and c.relkind in ('r', 'p') and not exists (
  select 1 from pg_policy p
  where p.polrelid = c.oid and p.polpermissive and p.polcmd in ('r', '*')
    and pg_get_expr(p.polqual, p.polrelid) = 'true'
    and (0::oid = any (p.polroles)
         or exists (select 1 from unnest(p.polroles) r where r <> 0::oid and pg_has_role(current_user, r, 'USAGE'))))"

# Tables with row-level security that a restrictive policy may cut short for this login:
# SELECT or ALL, a USING other than true, applying to PUBLIC or to any role this login is
# a member of (MEMBER, broader than the USAGE row-level security applies: the guard errs
# towards failing). A restrictive policy without USING restricts no read. Empty when none.
RLS_RESTRICTED_TABLES="select coalesce(string_agg(format('%I.%I', n.nspname, c.relname), ' ' order by n.nspname, c.relname), '')
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relrowsecurity and c.relkind in ('r', 'p') and exists (
  select 1 from pg_policy p
  where p.polrelid = c.oid and not p.polpermissive and p.polcmd in ('r', '*')
    and p.polqual is not null and pg_get_expr(p.polqual, p.polrelid) <> 'true'
    and (0::oid = any (p.polroles)
         or exists (select 1 from unnest(p.polroles) r
                    where r <> 0::oid and pg_has_role(current_user, r, 'MEMBER'))))"

# Runs both checks in DB. 0 when the login reads every row; otherwise logs and returns 1.
# `|| exit 1` keeps a psql failure away from the ERR trap the $(…) inherits (set -E).
rls_guard_check() {
  local db="$1" unread restricted
  if ! unread=$(psql -X -d "${db}" -tAc "${RLS_UNREAD_TABLES}" || exit 1); then
    echo "❌ ${db}: could not check row-level security. Previous dump kept." >&2
    return 1
  fi
  if [ -n "${unread}" ]; then
    echo "❌ ${db}: row-level security without a full-read policy for ${PGUSER}: ${unread}. Previous dump kept." >&2
    return 1
  fi
  if ! restricted=$(psql -X -d "${db}" -tAc "${RLS_RESTRICTED_TABLES}" || exit 1); then
    echo "❌ ${db}: could not check row-level security. Previous dump kept." >&2
    return 1
  fi
  if [ -n "${restricted}" ]; then
    echo "❌ ${db}: a restrictive policy limits ${PGUSER}'s reads: ${restricted}. Previous dump kept." >&2
    return 1
  fi
}
