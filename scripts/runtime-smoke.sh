#!/bin/bash
# runtime-smoke.sh — start llama-server with a tiny GGUF, poll /health, run one
# /completion and one /v1/chat/completions call, then SIGTERM and require exit.
#
# Usage: runtime-smoke.sh <dir with llama-server> <model.gguf> [arch-prefix...]
# Extra args are a command prefix (e.g. `arch -x86_64` to run under Rosetta).
# Set EXTRA_ARGS to add server flags (e.g. "-ngl 0").
set -uo pipefail
DIR="${1:?dir}"; MODEL="${2:?model}"; shift 2
PREFIX=("$@")
PORT=18080
LOG="$(mktemp)"
# shellcheck disable=SC2086
"${PREFIX[@]}" "$DIR/llama-server" --model "$MODEL" --host 127.0.0.1 --port $PORT -c 256 ${EXTRA_ARGS:-} >"$LOG" 2>&1 &
PID=$!
ok=0
for i in $(seq 1 60); do
    kill -0 $PID 2>/dev/null || { echo "❌ llama-server exited early"; break; }
    if [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/health)" = "200" ]; then ok=1; break; fi
    sleep 1
done
rc=1
if [ $ok -eq 1 ]; then
    echo "✅ /health 200 after ~${i}s"
    C=$(curl -s -m 60 http://127.0.0.1:$PORT/completion -d '{"prompt":"Once upon a time","n_predict":8}')
    echo "completion: $C" | cut -c1-300
    CC=$(curl -s -m 60 http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' \
        -d '{"messages":[{"role":"user","content":"Hello"}],"max_tokens":8}')
    echo "chat: $CC" | cut -c1-300
    if echo "$C" | grep -q '"content"' && echo "$CC" | grep -q '"choices"'; then rc=0; else echo "❌ unexpected API response"; fi
fi
kill -TERM $PID 2>/dev/null
for i in $(seq 1 20); do kill -0 $PID 2>/dev/null || break; sleep 1; done
if kill -0 $PID 2>/dev/null; then echo "❌ did not exit after SIGTERM"; kill -KILL $PID; rc=1
else wait $PID; echo "server exit code after SIGTERM: $?"; fi
echo "── server log (tail)"; tail -40 "$LOG"
[ $rc -eq 0 ] && echo "✅ runtime smoke passed" || echo "❌ runtime smoke FAILED"
exit $rc
