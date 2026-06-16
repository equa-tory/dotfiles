#!/bin/bash

SESSION="monitor"

# Запускаем сессию tmux в фоне
tmux new-session -d -s $SESSION "watch -n 1 nvidia-smi"

# Разделяем окно горизонтально и запускаем htop
tmux split-window -v -t $SESSION:0.0 "htop"

# return focus up
tmux select-pane -t $SESSTION:0.0

# vert
tmux split-window -h -t $SESSION:0.0 "watch -n 1 ollama ps"

# Подключаемся к сессии
tmux attach -t $SESSION
