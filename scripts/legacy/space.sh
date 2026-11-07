#!/usr/bin/env bash

echo "=== Filesystem Usage ==="
df -h

echo
echo "=== Top Directories Under / ==="
sudo du -xh / --max-depth=1 2>/dev/null | sort -hr | head -20

echo
echo "=== Top Directories Under /home ==="
sudo du -xh /home --max-depth=2 2>/dev/null | sort -hr | head -30

echo
echo "=== Top Directories Under /var ==="
sudo du -xh /var --max-depth=2 2>/dev/null | sort -hr | head -30

echo
echo "=== Largest Files (>1GB) ==="
sudo find / -xdev -type f -size +1G -printf '%s %p\n' 2>/dev/null \
| sort -nr \
| head -50 \
| awk '{printf "%.2f GB\t%s\n",$1/1024/1024/1024,$2}'

echo
echo "=== Docker Usage ==="
docker system df 2>/dev/null || echo "Docker not installed"

echo
echo "=== Journal Logs ==="
journalctl --disk-usage 2>/dev/null || true1~#!/usr/bin/env bash

echo "=== Filesystem Usage ==="
df -h

echo
echo "=== Top Directories Under / ==="
sudo du -xh / --max-depth=1 2>/dev/null | sort -hr | head -20

echo
echo "=== Top Directories Under /home ==="
sudo du -xh /home --max-depth=2 2>/dev/null | sort -hr | head -30

echo
echo "=== Top Directories Under /var ==="
sudo du -xh /var --max-depth=2 2>/dev/null | sort -hr | head -30

echo
echo "=== Largest Files (>1GB) ==="
sudo find / -xdev -type f -size +1G -printf '%s %p\n' 2>/dev/null \
| sort -nr \
| head -50 \
| awk '{printf "%.2f GB\t%s\n",$1/1024/1024/1024,$2}'

echo
echo "=== Docker Usage ==="
docker system df 2>/dev/null || echo "Docker not installed"

echo
echo "=== Journal Logs ==="
journalctl --disk-usage 2>/dev/null || true
