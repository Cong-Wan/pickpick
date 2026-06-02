# Metal Resource Validation — 2026-06-02

## Goal

验证 rawViewer 的 Metal/CoreImage 资源生命周期修复是否生效，并确认 analysis 日志能解释 GPU 阶段耗时。

## Build

```bash
cmake -S cpp -B cpp/build -DRAWVIEWER_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build cpp/build --target rawViewer rawViewerTests -j
./cpp/build/rawViewerTests
```

Expected:

```text
Tests run: <N>, failures: 0
```

## Functional Run

```bash
./cpp/build/rawViewer /Users/wilbur/Downloads/LUMIX_Backup --resume 2>&1 | tee docs/perf/20260602_after_run.log
```

Expected:

- CLI prints phase progress.
- Summary still reports successful RAW conversion and successful analysis.
- `Context leak detected, CoreAnalytics returned false` should not appear. If it still appears, record exact count and timestamp.

## Analysis Log Check

```bash
python3 - <<'PY'
import pathlib, re, statistics
path = pathlib.Path('/Users/wilbur/Downloads/LUMIX_Backup/.cache/analysis.log')
rows = []
for line in path.read_text().splitlines():
    if not line.startswith('['):
        continue
    item = {}
    for key, value in re.findall(r'(\w+)=([^\s]+)', line):
        if value.endswith('ms'):
            item[key] = int(value[:-2])
        else:
            item[key] = value
    rows.append(item)
print('count', len(rows))
for key in ['elapsed', 'read_image', 'render_image', 'gray', 'laplacian', 'stats', 'histogram', 'gpu_encode', 'gpu_wait', 'total_wall']:
    values = [r[key] for r in rows if key in r]
    if values:
        print(key, 'avg', round(statistics.mean(values), 2), 'max', max(values), 'sum', sum(values))
PY
```

Expected:

- Output includes `gpu_wait` and `total_wall`.
- `elapsed` uses `total_wall` instead of synthetic CPU-only sum.
- The log can explain periods of GPU activity.

## Leak Smoke Check

```bash
MallocStackLogging=1 ./cpp/build/rawViewer /Users/wilbur/Downloads/LUMIX_Backup --resume 2>&1 | tee docs/perf/20260602_leak_smoke.log
```

Expected:

- No repeated `Context leak detected` lines.
- If macOS still prints one-off framework diagnostics, compare count against baseline and inspect with Instruments if needed.
