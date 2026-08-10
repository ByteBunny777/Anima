#!/bin/bash
# Автозапуск Anima: запускає Julia-сервер і відкриває браузер

cd "$(dirname "$0")"

echo "Запускаю Anima..."

# У фоновій підоболонці чекаємо, поки сервер підніметься, і відкриваємо браузер.
# Це НЕ заважає Julia REPL працювати у головному режимі.
(
  for i in $(seq 1 60); do
    if curl -s http://127.0.0.1:8088 > /dev/null 2>&1; then
      if [[ "$OSTYPE" == "darwin"* ]]; then
        open http://127.0.0.1:8088
      else
        xdg-open http://127.0.0.1:8088 2>/dev/null
      fi
      break
    fi
    sleep 1
  done
) &

# Запускаємо Julia У ГОЛОВНОМУ режимі (без &), щоб REPL нормально працював з клавіатурою
julia --project=. run_anima.jl
