# Mac GPU Pipeline Benchmark Notes

## CPU Baseline

- Date: 2026-06-01
- Sample folder: `/Users/wilbur/Downloads/LUMIX_Backup`
- Input: 158 top-level `.RW2` files
- Command: `./build/rawViewer /Users/wilbur/Downloads/LUMIX_Backup --config config.yaml --resume`
- Result: 158 RAW conversions succeeded, 158 analyses succeeded
- Classifications: blurry 60, overexposed 27, underexposed 20, normal 111
- RAW conversion total: 188220ms
- RAW conversion average: 1191ms/photo

## Single RW2 Timing Probe

- Sample file: `P1000737.RW2`
- Conversion timing after phase logging: total 1072ms, open 1ms, unpack 244ms, process 642ms, make image 129ms, write JPG 54ms
- Analysis timing after phase logging: total 150ms, read 54ms, gray 5ms, laplacian 16ms, stats 43ms, histogram 32ms
