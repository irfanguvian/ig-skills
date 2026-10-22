#!/usr/bin/env bash
# ponytail: one runnable check. Fails loud if tool logic breaks. Needs local postgres up.
# no set -e: guard tests expect nonzero exits, every check fails loud via fail()
X=~/bin/postgres-irfan-axi
DB=pgx_check_$$
PSQL="${PGX_PSQL:-/opt/homebrew/opt/libpq/bin/psql}"

# on fail: drop only this run's throwaway db + temp dirs, so a failed run leaves nothing behind
fail() {
  echo "FAIL: $1"
  "$PSQL" -h /tmp -U "${PGUSER:-postgres}" -d postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null 2>&1
  rm -rf "${R:-}" "${E:-}"
  exit 1
}

$X > /dev/null || fail "dashboard"
$X createdb "$DB" | grep -q "ok{" || fail "createdb"
$X createdb "$DB" | grep -q "noop" || fail "createdb idempotent"
$X exec "CREATE TABLE t(id int, v text)" -d "$DB" | grep -q "ok{" || fail "exec ddl"
$X exec "INSERT INTO t SELECT i,'x, y' FROM generate_series(1,30) i" -d "$DB" | grep -q "ok{" || fail "exec dml"
$X query "SELECT * FROM t" -d "$DB" | grep -q "+10 more rows" || fail "limit 20 truncation"
$X query "SELECT v FROM t LIMIT 1" -d "$DB" | grep -q '"x, y"' || fail "comma quoting"
$X tables -d "$DB" | grep -q "public.t" || fail "tables"
$X desc t -d "$DB" | grep -q "columns\[2\]" || fail "desc"
$X exec 'CREATE TABLE "Mixed"(id int)' -d "$DB" >/dev/null || fail "exec mixed-case ddl"
$X desc Mixed -d "$DB" | grep -q "fkeys\[0\]: none" || fail "desc MixedCase"
$X desc public.Mixed -d "$DB" | grep -q "fkeys\[0\]: none" || fail "desc schema.MixedCase"
$X exec 'DROP TABLE "Mixed"' -d "$DB" --yes >/dev/null || fail "drop mixed-case"

# names pasted into SQL must be plain identifiers (injection) → usage exit 4
$X desc "x' OR '1'='1" -d "$DB" >/dev/null 2>&1; [ $? -eq 4 ] || fail "desc injection must exit 4"
$X createdb "x\"; SELECT 1; --" >/dev/null 2>&1; [ $? -eq 4 ] || fail "createdb bad name must exit 4"
# sql errors on query / exec → exit 1, never ok
$X query "SELECT * FROM nope_missing" -d "$DB" >/dev/null 2>&1; [ $? -eq 1 ] || fail "query missing table must exit 1"
out=$($X exec "SELECT 1/0" -d "$DB" 2>&1); [ $? -eq 1 ] || fail "exec 1/0 must exit 1"
grep -q "ok{" <<<"$out" && fail "exec 1/0 must not print ok"

# run: failing file → error + nonzero, never ok (old false-ok bug); tags prove row counts
R=$(mktemp -d)
printf 'CREATE TABLE r(id int);\nINSERT INTO r_missing VALUES (1);\n' > "$R/bad.sql"
out=$($X run "$R/bad.sql" -d "$DB" 2>&1); [ $? -ne 0 ] || fail "run bad sql must exit nonzero"
grep -q "error{code:sql" <<<"$out" || fail "run bad sql must print error{code:sql"
grep -q "ok{" <<<"$out" && fail "run bad sql must not print ok"
printf 'CREATE TEMP TABLE g(id int);\nINSERT INTO g SELECT generate_series(1,3);\n' > "$R/good.sql"
out=$($X run "$R/good.sql" -d "$DB"); [ $? -eq 0 ] || fail "run good sql must exit 0"
grep -q "INSERT 0 3" <<<"$out" || fail "run must print tag INSERT 0 3"
# --no-tx failure: error names what was already committed + DETAIL line
printf 'CREATE TEMP TABLE n(id int primary key);\nINSERT INTO n VALUES (1),(2);\nINSERT INTO n VALUES (1);\n' > "$R/notx.sql"
out=$($X run "$R/notx.sql" -d "$DB" --no-tx 2>&1); [ $? -eq 1 ] || fail "run --no-tx bad sql must exit 1"
grep -q 'committed:"CREATE TABLE;INSERT 0 2"' <<<"$out" || fail "run --no-tx must list committed tags"
grep -q "DETAIL:  Key (id)=(1) already exists" <<<"$out" || fail "sql error must carry DETAIL"
rm -rf "$R"

$X exec "DROP TABLE t" -d "$DB" >/dev/null 2>&1; [ $? -eq 2 ] || fail "drop table must exit 2"
$X exec "DROP DATABASE $DB" -d "$DB" >/dev/null 2>&1; [ $? -eq 3 ] || fail "drop database must exit 3"
$X dropdb "$DB" >/dev/null 2>&1; [ $? -eq 3 ] || fail "dropdb cmd must exit 3"
# guard reads through comments; '--' or '/*' inside a string hides nothing and still runs
$X exec "DROP/**/TABLE t" -d "$DB" >/dev/null 2>&1; [ $? -eq 2 ] || fail "DROP/**/TABLE must exit 2"
$X exec "DROP/**/DATABASE $DB" -d "$DB" >/dev/null 2>&1; [ $? -eq 3 ] || fail "DROP/**/DATABASE must exit 3"
$X exec "SELECT '--'; DROP TABLE t" -d "$DB" >/dev/null 2>&1; [ $? -eq 2 ] || fail "'--' in a string must not hide DROP TABLE"
$X exec "SELECT 'x" -d "$DB" >/dev/null 2>&1; [ $? -eq 4 ] || fail "unterminated string must exit 4"
$X exec "INSERT INTO t VALUES (99, 'a -- b /* c')" -d "$DB" | grep -q "ok{" || fail "exec string with -- and /*"
$X query "SELECT '--' AS a, '/*' AS b" -d "$DB" | grep -q -- '--,/\*' || fail "query string with -- and /*"
# psql backslash commands and server-side file writes never run: marker files must not appear
R=$(mktemp -d)
$X exec "\\! touch $R/pwned" -d "$DB" >/dev/null 2>&1; [ $? -eq 3 ] || fail "\\! must exit 3"
[ -e "$R/pwned" ] && fail "\\! ran a shell"
printf 'SELECT 1;\n\\! touch %s/pwned2\n' "$R" > "$R/meta.sql"
$X run "$R/meta.sql" -d "$DB" >/dev/null 2>&1; [ $? -eq 3 ] || fail "run file with \\! must exit 3"
[ -e "$R/pwned2" ] && fail "run \\! ran a shell"
# NUL byte: $(cat) drops it but psql cuts the line there, so \! after it would hide inside a fake string
printf "SELECT 1 AS x\000'\n\\\\! touch %s/pwned3\n';\n" "$R" > "$R/nul.sql"
$X run "$R/nul.sql" -d "$DB" >/dev/null 2>&1; [ $? -eq 4 ] || fail "run file with NUL byte must exit 4"
[ -e "$R/pwned3" ] && fail "run NUL file ran a shell"
$X exec "COPY t TO PROGRAM 'cat'" -d "$DB" >/dev/null 2>&1; [ $? -eq 3 ] || fail "COPY PROGRAM must exit 3"
$X exec "COPY t TO '$R/out.csv'" -d "$DB" >/dev/null 2>&1; [ $? -eq 3 ] || fail "COPY TO file must exit 3"
$X exec "COPY t TO U&'$R/u.csv'" -d "$DB" >/dev/null 2>&1; [ $? -eq 3 ] || fail "COPY TO U& file must exit 3"
$X exec $'COPY (SELECT \'a\nb\') TO \''"$R"$'/nl.csv\'' -d "$DB" >/dev/null 2>&1; [ $? -eq 3 ] || fail "COPY TO file with newline in string must exit 3"
$X exec $'SELECT 1; -- note\rDROP TABLE t' -d "$DB" >/dev/null 2>&1; [ $? -eq 2 ] || fail "CR ends a -- comment: DROP TABLE must exit 2"
$X exec "COPY t TO STDOUT" -d "$DB" | grep -q "ok{" || fail "COPY TO STDOUT"
$X query $'SELECT \'line1\nline2\' AS v' -d "$DB" | grep -q "line2" || fail "query one SELECT with multi-line string"
ls "$R"/*.csv >/dev/null 2>&1 && fail "COPY wrote a server file"
rm -rf "$R"
# query is read-only: writes and read-only escapes refused, row count proves nothing was written
out=$($X query "UPDATE t SET v='w'" -d "$DB" 2>&1); [ $? -eq 1 ] || fail "query UPDATE must exit 1"
grep -q "use exec for writes" <<<"$out" || fail "query UPDATE must point to exec"
$X query "SET transaction_read_only=off; UPDATE t SET v='w'" -d "$DB" >/dev/null 2>&1; [ $? -eq 4 ] || fail "query 2 statements must exit 4"
$X query "DO \$\$ BEGIN PERFORM set_config('default_transaction_read_only','off',false); COMMIT; UPDATE t SET v='w'; END \$\$" -d "$DB" >/dev/null 2>&1; [ $? -eq 4 ] || fail "query DO must exit 4"
$X query "SELECT count(*) FROM t WHERE v='w'" -d "$DB" | grep -qx "  0" || fail "query must not write"
# -d is a plain name: a URI or conninfo could reach another host and skip the remote --yes gate
$X query "SELECT 1" -d "postgresql:///$DB?host=/tmp" >/dev/null 2>&1; [ $? -eq 4 ] || fail "-d URI must exit 4"
$X query "SELECT 1" -d "host=/tmp dbname=$DB" >/dev/null 2>&1; [ $? -eq 4 ] || fail "-d conninfo must exit 4"
$X exec "DROP TABLE t" -d "$DB" --yes | grep -q "ok{" || fail "drop table --yes"
$X tables -d "$DB" | grep -q "tables\[0\]: none" || fail "empty state"
$X badcmd >/dev/null 2>&1; [ $? -eq 4 ] || fail "unknown cmd must exit 4"

# --env: local URL → socket/TCP, remote write needs --yes, no URL → exit 4
E=$(mktemp -d)
printf 'NODE_ENV=development\nDATABASE_URL="postgresql://%s:x@localhost:5432/postgres?schema=public"\n' "${PGUSER:-postgres}" > "$E/.env"
$X query "SELECT current_database()" --env "$E/.env" | grep -q "postgres" || fail "--env local url"
printf 'DATABASE_URL=postgres://u:p%%40ss@db.example.invalid:5432/app\n' > "$E/r.env"
$X exec "CREATE TABLE z(id int)" --env "$E/r.env" >/dev/null 2>&1; [ $? -eq 2 ] || fail "--env remote write must exit 2"
printf 'FOO=bar\n' > "$E/n.env"
$X dbs --env "$E/n.env" >/dev/null 2>&1; [ $? -eq 4 ] || fail "--env without url must exit 4"
rm -rf "$E"

conns=$("$PSQL" -h /tmp -U "${PGUSER:-postgres}" -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname='$DB'")
[ "$conns" = "0" ] || fail "lingering connections: $conns"

"$PSQL" -h /tmp -U "${PGUSER:-postgres}" -d postgres -c "DROP DATABASE $DB" >/dev/null
echo "PASS: all checks"
